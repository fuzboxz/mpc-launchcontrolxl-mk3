# mpc-launchcontrolxl-mk3

A Novation **Launch Control XL 3** controller script for Akai MPC 3.10.1 (Gen2, MPC Live III).

The XL 3 is driven through its **DAW mode** (the DAW In/Out USB interface): the script
enters DAW mode on load, configures the surface (relative encoders, touch events, fader
pickup, brightness), and then owns a two-way surface — MPC state is painted onto the
XL 3's encoder LEDs and its OLED, while faders, endless encoders and buttons drive MPC
tracks, Q-Links and transport.

Built on the documented Lua controller-script layer proven by the sibling
[mpc-launchpad-pro-mk3](https://github.com/fuzboxz/mpc-launchpad-pro-mk3) project
(same firmware, same loader, same signing rule). The device-side wire facts come from Novation's Launch Control XL 3
programmer's reference v1.0 and from Ableton's Live 12.3 remote script for the same
hardware (see `docs/LCXL3-LAYOUT.md` for the full citation map).

## Status — v1.0 (device-verified on MPC Live III, XL 3 firmware 1.1.11)

- **Session**: DAW mode enter/leave (both wire forms), relative encoder rows, touch
  events, fader pickup, LED/screen brightness, display timeout, encoder curve, surface
  mode select + follow (`ch 7 CC 30`), firmware identity probe. The DAW port name is
  device-verified (`LCXL3 1 DAW In`; the `.ini` ships factory-style candidate lists).
- **Mixer mode** (DAW Mixer): faders = track volume with hardware + software pickup;
  encoder rows = Send 1 / Send 2 / Pan (Page ▲▼ switches the send bank 1+2 ↔ 3+4).
  **All knob rings follow one rule — hue says what, brightness says how much**
  (`0.07 + 0.93 · value^1.7`): sends ring in the track's colour scaled by level, pan
  is a continuous blue/orange readout by distance from centre, empty tracks go dark.
- **Control mode** (DAW Control): encoder rows 1-2 are **hardware-routed into the
  MPC's 16 Q-Links** via `AddInfiniteCCToQLink` (script-side `Twist` fallback); row 3 =
  global parameters (tempo, swing, quantize strength, division, metronome, loop,
  automation filter, master volume) with a Page-cycled track-utility alternative;
  Shift+Page ▲▼ walks plugin presets. Rings scale with the live parameter values.
- **Buttons**: top row Solo/Arm (cycle button), bottom row Mute/Select (cycle button),
  Track ◀▶ bank moves (**Shift = undo/redo**), Page ▲▼ (Shift = bar forward/back),
  Play (double-press = rewind to start; Shift = stop / stop all clips), Record
  (double-press = tap tempo with accidental-arm revert; Shift = overdub), Novation =
  track-map overlay + status (Shift = probe mode).
- **Screen**: stationary 3-line page (mode + bank + transport/BPM / bar.beat /
  focus), per-control 3-line pages, a **fader-display track map** (name + dB per
  column) and a named overlay announcing bank moves; content-addressed cache,
  ≤ 6 sysex per 50 ms tick, overlay text strictly before its `7Fh` trigger.
- **State-driven feedback**: transport, mute/solo/arm, sends, pan, names, colours,
  clip emptiness — the surface repaints from listeners (plus bounded polls where the
  API has none); nothing is lit from the button press alone, and LEDs are custom RGB
  with ≥ 4x on/off luminance contrast (test-enforced).
- **Track numbering**: the MPC UI numbers all tracks while the surface addresses the
  mixable subset; the global↔normal offset is learned passively (debounced against
  the asynchronous Index/Name update) so labels, highlight and selection follow the
  MPC's own numbers.
- **Degrade, never break**: every optional API is pcall-guarded; missing Q-Link
  mappings, sequencer, tracks or a popup-owned UI disable their surface and log once.

Not implemented (roadmap in `docs/RECOMMENDATIONS.md`): step-sequencer and pad-perform
pages, bitmap screen art, custom-mode awareness, multi-device/bank link, automation
write modes.

## Layout

| Path | What |
|---|---|
| `docs/RECOMMENDATIONS.md` | **the design document**: full integration analysis + phased roadmap |
| `docs/MANUAL.md` | generated quick reference (regenerate with `tools/gen-manual.sh`) |
| `docs/LCXL3-LAYOUT.md` | XL 3 DAW-mode wire map: channels, CCs, sysex, palette, screen |
| `docs/MAPPING.md` | the mapping this script implements, control by control |
| `docs/API-CONTRACT.md` | the MPC 3.10.1 Lua API surface this script relies on |
| `docs/PATTERNS.md` | reusable patterns from the reference controllers |
| `docs/INSTALL.md` | install + signing procedure (incl. the port-name probe) |
| `docs/DEVICE-TEST-PLAN.md` | on-hardware test steps (Phase 0 first!) |
| `docs/LIMITATIONS.md` | what the script cannot do |
| `docs/REVIEW.md` | implementation review against the contract |
| `script/` | `LaunchControlXL3.lua`, `.ini.in`, `build.sh` |
| `tools/` | build/sign/verify/manual tooling |
| `tests/` | Lua mock harness + wire assertions |
| `references/` | non-committed reference material (gitignored) |

## Quick start

```sh
# 1. Build + sign (salt read from your own MPC binary; never written)
MPC_BIN=/path/to/MPC ./script/build.sh

# 2. Host tests (no hardware)
./tests/run-tests.sh

# 3. Copy LaunchControlXL3.ini + LaunchControlXL3.lua to the MPC's Devices folder
#    (see docs/INSTALL.md; the input=/output= port name must be verified first)
```

## Verification

- `luac5.4 -p script/LaunchControlXL3.lua` — syntax.
- `./tests/run-tests.sh` — mock MPC + wire assertions (also runs the whole suite
  against the minified artifact, which is the deployed form).
- `tools/gen-manual.sh --check` — the committed manual matches the script.
- On hardware: `docs/DEVICE-TEST-PLAN.md`, plus the script's probe mode
  (Shift + Novation logs every incoming message and lights the pressed control).

## Ground rules

- Akai binaries and the signing salt are never committed. The signer reads the salt
  from the owner's own MPC binary at run time.
- Claims are firmware-specific: MPC 3.10.1.8 (build 38fdde70994) unless stated.
- Device-side claims are Launch Control XL 3, programmer's reference v1.0; anything
  only corroborated by Ableton's script is marked as such and listed in
  `docs/DEVICE-TEST-PLAN.md` for Phase-0 verification.
- Degrade, never break: a missing feature disables its surface, never crashes the host.
