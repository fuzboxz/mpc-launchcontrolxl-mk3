# Install + signing

Target: MPC 3.10.1.8 (build 38fdde70994), MPC Live III Gen2.
Device: Novation Launch Control XL 3 (any device ID 1-8), firmware ≥ v1.0.

## 1. The pair

A controller script is a `.ini` + `.lua` pair:

- `LaunchControlXL3.ini` — `[info]` first line, `input=` / `output=` port-name matches
  (order = port index used by `midiOut.Send*`), `script=`, `scriptVersion=`,
  `checksum=`.
- `LaunchControlXL3.lua` — the script.

The `.ini` must start with `[info]`; otherwise MPC reads it but ignores it and never opens
the `.lua` — silently.

## 2. Pick the DAW port (device-verified on the target MPC)

All DAW-mode traffic (everything this script does) lives on the XL 3's **second** USB
MIDI interface. On Windows it is `MIDIIN2`/`MIDIOUT2`, on macOS `LCXL3 DAW In/Out`.

On the MPC (Linux/ALSA) the kernel merges the XL 3's DAW In/Out jack pair into **one
bidirectional port named after the IN jack**, and the MPC app's JUCE ports are named
after it too (from `/proc/asound/seq/clients` on the target):

```
Client 20 "LCXL3 1"
  Port 1 "LCXL3 1 DAW In" (RWeX) [In/Out]     <- the DAW interface
Client 129 "MPC 3"
  Port 3 "LCXL3 1 DAW In" (-we-) [Out]        <- app -> device
  Port 10 "LCXL3 1 DAW In" (r-e-) [In]        <- device -> app
```

So the `.ini.in` ships:

```
input=LCXL3 1 DAW In,MIDIIN2 (LCXL3 1)
output=LCXL3 1 DAW In,MIDIOUT2 (LCXL3 1)
```

The comma lists follow Akai's own shipped scripts (`mpkMiniMkIV.ini` on 3.10.x uses
`input=MPK mini IV DAW Port,MIDIIN2 (MPK mini IV)`, observed on this device): the
loader tries each candidate. To re-derive the name on another unit:

```sh
cat /proc/asound/seq/clients | grep -iA4 lcxl   # or: amidi -l | grep -i lcxl
```

The name embeds the **device ID** (`LCXL3 1` = ID 1, set in the XL 3 bootloader); a
unit with another ID needs the name adjusted. A fully wrong name means the loader
matches nothing — no log, no load — and the script's `journalctl` lines never appear.

## 3. Sign

`checksum = sha256(lua_bytes || 36-char salt)`. The salt lives XOR-obfuscated in the MPC
binary; read it from your own copy, never publish it.

```sh
MPC_BIN=/path/to/your/MPC ./script/build.sh
```

`tools/sign_script.py` reads the salt from the 3.10.0.49 Gen2 binary at file offset
`0x5287C10` (build id `2209920bc0a`), XOR-decodes it with key `0x5F694973D3C78945`, and
rewrites the `checksum=` line. The same salt gives the correct checksum for Akai's
shipped `mpkMiniMkIV.lua` on 3.10.1.8 (verified by the sibling launchpad project). If
you have a different build, pass `MPC_SALT` (36 chars) instead of a binary.

## 4. Copy to the device

The release zip (`mpc-launchcontrolxl-mk3-v<version>.zip`) contains the signed `.ini`,
the minified `.lua`, this guide, the README and the generated `MANUAL.md`.

Search dirs:

- `/usr/share/Akai/SME0/Devices` (read-only rootfs; not for user scripts)
- `<user root>/MPC Documents/Devices` — user root is `/storage`, `/data/UserData`,
  `/nvme` or `/sdcard` depending on the device. On the Live III it is normally
  `/nvme/MPC Documents/Devices/`.

```sh
mkdir -p "/nvme/MPC Documents/Devices/LaunchControlXL3"
cp LaunchControlXL3.ini LaunchControlXL3.lua "/nvme/MPC Documents/Devices/LaunchControlXL3/"
```

**Then restart the app** - the loader caches scripts from app start and silently
keeps the last valid copy otherwise (`systemctl restart acvs` over SSH; a script
whose ini checksum does not match is silently ignored, and `scriptVersion` must
stay `1.0` - other values are rejected by this loader). Signing needs the
3.10.0.49-gen2 kit binary: the on-device firmware's salt obfuscation moved, but
it still validates the same salt (`MPC_BIN=<kit>/MPC-3.10.0.49-gen2
./script/build.sh`).

## 5. Verify it loaded

```sh
journalctl -u acvs -o cat --no-pager | grep LaunchControlXL3
```

Expected first lines: `loaded`, `engine mode: ...`, and (in control mode)
`qlink native routing disabled (fw 1.1.11 direction inversion): script-side Twist active`
(native routing ships off until the direction probe; the 16 Q-Links are driven
script-side, so no `qlinks routed: 16/16` line is expected). If nothing appears, the `.ini` did not match a port
(step 2) or the checksum is wrong (step 3).

Then run the Phase-0 probe (Shift + Novation, then touch every control once) from
`docs/DEVICE-TEST-PLAN.md` and fix any CC that logs differently from
`docs/LCXL3-LAYOUT.md`.

## 6. Rollback

Remove the folder and restart MPC:

```sh
rm -rf "/nvme/MPC Documents/Devices/LaunchControlXL3"
```

On unload the script leaves DAW mode, so the XL 3 returns to its standalone/custom-mode
behaviour on its own.

## 7. Notes

- The XL 3 boots into standalone (custom) mode. `OnLoad` sends the DAW-mode enable in
  both wire forms (note 12 on MIDI ch 16 vel 127 and the sysex
  `F0 00 20 29 02 15 02 7F F7`); `OnUnload` sends both disable forms. Journal lines:
  `loaded` / `unloaded`.
- On load the script QUERIES the surface mode (it no longer forces DAW Mixer), so an app restart while the surface sits in the DAW Control template keeps your mode instead of stomping it back to mixer. If you
  press the XL 3's Mode button, the device reports the change on `ch 7 CC 30` and the
  script follows it (including into custom modes, where the surface belongs to the
  device but transport/navigation stay alive).
- The checksum is skipped when the hardware product code is 0 (desktop MPC software).
- Never commit the salt or Akai binaries.
