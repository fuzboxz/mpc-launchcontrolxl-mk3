# Limitations

Firmware: MPC 3.10.1.8. Device: Launch Control XL 3, programmer's reference v1.0.
Hard walls are marked with their source; script-specific limits are **[script]**.

## Hard walls (Lua cannot cross)

| Limit | Consequence for the XL 3 |
|---|---|
| No state dump (`GetState` nil) | everything is read through property listeners; no snapshot on load |
| No per-track MIDI input from Lua | track input routing must be set by hand in MPC |
| Cannot edit a non-selected track/clip | the row-3 track page acts on the *current* track only |
| `qlinks.SetPosition` does not reach the edit value; `GetPosition` lags | Q-Link control is script-side (`Touch` + `Twist`); hardware routing ships off (parser encoding unprobed) |
| No LED state for `mpc.force.*` / `controlSurface.*` virtual buttons | transport/navigation LEDs derive from readable state only |
| Script-emitted MIDI does not loop back through `dev.mappings` | screen/LED feedback is always computed by the script |
| Project-scoped native calls can abort under a popup | guarded on `engineMode.CurrentPopup` |
| No USB display access, no bitmap API on MPC side | the XL 3's bitmap screen feature has no MPC-generated art (yet) |

## Device-side walls

| Limit | Consequence |
|---|---|
| Faders are 7-bit absolute | volume steps of ~0.8 % of range; fine for levels, wrong for tuning |
| One blink mechanism only (channel-2 alternation, unverified) | blinking is rendered as timer-phase repaints |
| Screen text is ASCII 20h-7Eh, 16 chars/line | names are sanitised (`-` for non-ASCII) and truncated |
| Sysex-per-field text | a full repaint is 26+ messages; paced at 6 per 50 ms |
| Shift LED is not colourable | no shift feedback on the surface |
| No DIN output in DAW mode | the XL 3's DIN ports are dead while the script runs |
| Custom modes own the surface | in modes 6-29 the script keeps only transport/navigation |

## Script-specific limits (phase 1)

| Limit | Status |
|---|---|
| **Q-Link routing signature** | corrected to Akai's shipped `AddInfiniteCCToQLink(channel, cc, qlinkIndex)` / `RemoveInfiniteCCToQLink(channel, cc)` / `SetQLinkFineAdjust(bool)`; the MPC parser's expected encoding for the XL3 binary offset is still unprobed, so routing ships off and the rows use script-side `Twist` |
| **Q-Link knob order is set-dependent** | the loaded set is identified from its target names (no page/selection property exists); if a firmware renames the global parameters, detection falls back to the track order until the signature is updated |
| **Channel 16/15/7 delivery** | `AddCCToScript` on channels other than 0 is unproven on device — the whole input path is a Phase-0 item |
| **Fader pickup** | both the hardware pickup (fed by script-sent positions) and a software guard are armed; if the device ignores position CCs the software guard still protects jumps |
| **Send/pan encoder step** | fixed 1/64 (sends) and 1/127 (pan) per detent; no acceleration curve of our own (the device's encoder-curve feature CC 121 is set to medium) |
| **Row-3 track page** | acts on the current track only (MPC hard wall); the display names the track |
| **Stationary focus line** | no readable "selected Q-Link" on 3.10.1 → the line degrades to `-` |
| **Plugin presets** | `currentTrack.Next/PrevPluginPreset` used sight-unseen; logs once if missing |
| **No scene/clip launch** | the XL 3 has no grid; scenes could ride the bottom row in a future mode (see RECOMMENDATIONS) |
| **No blink** | timer-phase repaint is implemented for nothing yet (no blinking states in phase 1); the mechanism exists |
| **No bitmap art** | the 1216-byte bitmap path is documented but unused |
| **Single device** | device IDs 2-8 are not auto-detected; the port name in the `.ini` picks the unit |

## Current limitations (device findings 2026-11, probe pending)

| Limit | Consequence |
|---|---|
| Native Q-Link routing disabled by default | the MPC parser's expected encoding for the XL3 binary offset is unprobed (the earlier "inverted direction" reading was never verified), so all 16 Q-Links are driven script-side (`Touch` + `Twist`; row 1 via the absolute→delta path) until the direction/magnitude probe runs (`reports/00-FINAL-TRIAGE.md` §5) |
| fw 1.1.11 Q-Link writes | the method-form `q:Twist(delta)` corrupts the Q-Link page (targets vanish after a few calls; app restart restores). Only dot-form `H.call(q.Twist, d)` / `SetValue` / `SetPosition` are safe, per the LPP3-proven driver |
| fw 1.1.11 read-back lag | `GetPosition()`/`GetValueString()` lag one change - never verify a write synchronously |
| Master volume slot pending hardware probe | `masterTracks[0].Volume` is device-disproven as the master fader path; row-3 col 8 writes only over a real read (one-shot failure log, no blind default) and may do nothing until the master-surface probe runs |
| Row-1 encoders emit absolute CCs on fw 1.1.11 | the row-1 relative enable (CC 69) is dead; absolute values are converted to deltas (first sighting absorbed as the baseline) so nothing jumps |

## Degrade behaviour (implemented)

- Missing `mappings.controlSurface.qlinks` → Q-Link rows fall back to script `Twist`.
- Missing `mpc.controlSurface.qlinks` → Q-Link rows dark and inert; transport alive.
- Missing `sequencer` → transport buttons inert.
- No project / popup open → project-scoped actions refuse with one log line each.
- Zero tracks → faders/encoders/button rows inert; transport alive.
- Failing property write → one log line, handler continues.
