# MPC 3.10.1 Lua Controller-Script API Contract (Launch Control XL 3)

Target: MPC 3.10.1.8 (build 38fdde70994), MPC Live III. The full contract with
per-claim citations lives in the sibling project
(`../mpc-launchpad-pro-mk3/docs/API-CONTRACT.md`); this file records the subset the
XL 3 script relies on, plus everything XL 3-specific. Facts proven on device by that
project are marked **[dv]**; XL 3-specific inferences that still need hardware are
marked **[p0]** (Phase-0 probe).

## 0. Script skeleton & loading

- Pair `.ini` + `.lua`; `.ini` starts with `[info]`, holds one `input=` and one
  `output=` port-name match (order = port index used by `midiOut.Send*`), `script=`,
  `scriptVersion=`, `checksum=`. **[dv]** Search dirs: `/usr/share/Akai/SME0/Devices`,
  `<user root>/MPC Documents/Devices`.
- `checksum = sha256(lua_bytes || 36-char salt)`; read the salt from the owner's own
  binary. **[dv]** Skipped when the hardware product code is 0.
- Lua 5.4 (sol2). Device table named after the file: `local dev = LaunchControlXL3`;
  MPC calls `.OnLoad`, `.OnUnload`, `.HandleMIDINoteOn(ch, note, vel)`,
  `.HandleMIDINoteOff`, `.HandleMIDICC(ch, cc, value)`, `.HandleMIDISysex(bytes)`,
  `.HandleTimer`. Channels and CCs are 0-based. **[dv]**
- Input routing: only CCs registered with `mappings.script.AddCCToScript(channel, cc)`
  reach `HandleMIDICC`; unregister with `Remove*`. **[dv]** Registration on channels
  other than 0 (the XL 3 needs 6, 14, 15) is **[p0]**.
- Sysex to the script needs `mappings.script.SetHandleSysex(true)`. **[dv]**
- `print()` → `journalctl -u acvs`. **[dv]**

## 1. Output

- `dev.midiOut.SendMIDICC(channel, cc, value, outputIndex)`,
  `.SendMIDINoteOn(channel, note, velocity, outputIndex)`,
  `.SendMIDISysex(payloadWithoutF0F7, outputIndex)`. **[dv]** The XL 3 accepts the
  Novation sysex payloads in that framing — **[p0]** (the script also sends the
  DAW-mode note form, so a framing surprise cannot strand the session).

## 2. Tracks

- `mpc.tracks.normalTracks[i]` (0-based; index = global clip-matrix column):
  `Volume` (0..1), `Pan` (0..1, 0.5 centre), `Send1-4` (0..1), `Mute`, `Solo`,
  `RecArm`, `Colour`, `Name`, `Type` — read/write via `.value`; setters
  `SetMute/SetSolo/SetRecArm(bool)`. **[dv]**
- Count: `mpc.tracks.Count.value` / `GetCount()` / `SizeNormalTracks()` (the table is
  allocated with 128 slots whatever the project holds). **[dv]**
- `mpc.tracks.currentTrack.Index` (counts normal tracks first, then master). **[dv]**
- `mpc.tracks.SetCurrentTrack(i)` moves MPC's current track. **[dv-ish: present in the
  binary dump; the launchpad project used the aperture's SelectTrack]**
- `mpc.tracks.masterTracks[0].Volume` — master fader. **[p0]** (present in the dump).
- DO NOT USE `mpc.tracks.Get*/Set*` free functions (`GetMute`, `SetMute`, `GetSolo`,
  `GetTrackRecordArmed`, `GetTrackInputPort`, …) — they error in every argument form.
  **[dv]**

> **Hardware findings 2026-11** (probe pending): the **[p0]** above did not survive
> first contact — `masterTracks[0].Volume` is **not** the master fader path as assumed
> (device-disproven on an MPC Live III, fw 1.1.11; the empty-table dump reading was an
> empty-project artifact). The **[p0]** stays unflipped until the master-surface probe
> runs. Probe list: `reports/00-FINAL-TRIAGE.md` §5.

## 3. Transport & tempo

- `sequencer.Play/Stop/TogglePlay/Record/RecordOff/Overdub`; props `Playing`,
  `RecordState`, `OverdubState`, `Loop`, `MetronomeEnabled`; setters `SetLoop`,
  `SetMetronomeEnabled`, `SetBPM`, `GetBPM`. **[dv]**
- `sequencer.quantiser.{Get,Set}{Swing,Strength,TimeDivision,Window,Shift,Enabled}`. **[dv]**
- `mpc.project.BPM` (prop) with `sequencer.SetBPM` fallback. **[dv]**
- `mpc.project.AdvanceGlobalAutomationFilterType()`. **[dv]**

## 4. Q-Links

- `mpc.controlSurface.qlinks[i]` (0-based, 16): `GetPosition()` (lags one change),
  `SetPosition()` (**does not reach the edit value**), `Twist(delta)`, `Touch()`,
  `GetValue()`, `GetValueString()`, `GetTargetName()`. **[dv]**
- `dev.mappings.controlSurface.qlinks`: `AddInfiniteCCToQLink`,
  `RemoveInfiniteCCToQLink`, `IsQLinkMappedInfinite`, `AddAbsoluteCCToQLink`,
  `SetInfiniteCCMagnitude`, `SetQLinkFineAdjust`. Present in the binary dump.
  Signatures follow Akai's shipped scripts — `AddInfiniteCCToQLink(channel, cc,
  qlinkIndex)`, `RemoveInfiniteCCToQLink(channel, cc)`, `SetQLinkFineAdjust(bool)` —
  and the script verifies each binding non-circularly (remove/rebind query flip). **[p0]**
  Hardware input *does* flow through `dev.mappings` (only script-emitted MIDI does not
  loop back). **[dv]**
- `mpc.controlSurface.qlink.Selected` / a `LastTouchedQlink` helper do **not** exist in
  the dump — the stationary screen's focus line degrades to `-`.

> **Hardware findings 2026-11** (probe pending): the MPC parser's expected encoding for
> the XL3's binary offset is unprobed — an earlier "argument order" and "inverted sign"
> reading was not verified against the shipped signatures above. The script therefore
> ships native routing **disabled** (script-side `Twist` for all 16). Probe list:
> `reports/00-FINAL-TRIAGE.md` §5.

## 5. Virtual MPC buttons

`mpc.controlSurface.<name>.{Press,Release,Hold,DoublePress}` for `quantizeApply`,
`tapTempo`, `metronome`, `undo`, `save`, `copy`, `erase`, `barBack/barForward`,
`stepForward/Back`, `trackInc/Dec`, `matrix`, `mix`, `main`, `song`, `browser`,
`padPerform`, `keyboardControl`, `nextSeq`, `fullLevel`, `noteRepeat`,
`sixteenLevel`, … (full list in the launchpad project's `LUA-API-DUMP.md`). No LED
state is readable for any of them. **[dv]**

## 6. Misc

- `mpc.engineMode.{CurrentMode,CurrentPopup,RequestModeChange}`,
  `mpc.ui.ShowTUIFeedback(str)`, `mpc.ui.popups.*`. **[dv]**
- `dev.timer.Start(ms)` / `.Stop()` — `HandleTimer` cadence. **[dv]**
- Property listeners: `prop:listen(fn, deviceName)` / `prop:stopListening(deviceName)`;
  re-register on every OnLoad. **[dv]**

## 7. Hard limits (design around)

1. No state dump (`GetState` nil) — read everything through listeners. **[dv]**
2. No per-track MIDI input from Lua; no track input routing. **[dv]**
3. Cannot edit a non-selected track/clip — select first. **[dv]**
4. `qlinks.GetPosition()` lags one change; `SetPosition` doesn't reach the edit value
   → drive Q-Links script-side with `Touch` + `Twist`. **[dv]**
5. Script-emitted MIDI does not loop back through `dev.mappings`. **[dv]**
6. Project-scoped native calls can abort the app while a popup owns the UI → guard on
   `engineMode.CurrentPopup`. **[dv]**
7. Loader-silent `.ini` failure modes (wrong port name, semver `scriptVersion`,
   comment lines) → `tools/check-ini.sh` gates them. **[dv]**

## 8. Degrade rules (implemented)

- Missing `mappings.controlSurface.qlinks` → Q-Link rows fall back to script-side
  `Twist`, one log line.
- Missing `mpc.controlSurface.qlinks` → Q-Link rows dark and inert.
- Missing `sequencer` → transport buttons inert.
- No project / popup open → project-scoped actions refuse with one log line each.
- Zero tracks → faders/encoders/rows inert; transport alive.
- A failing property write logs once (`track <name> write failed`) and continues.
