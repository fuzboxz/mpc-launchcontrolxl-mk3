# Mapping

The mapping this script implements, control by control. Wire facts live in
`LCXL3-LAYOUT.md`; MPC calls live in `API-CONTRACT.md`. The quick-reference table in
`MANUAL.md` is generated from the `ACTIONS` table in the script.

## Modes

The script follows the device's own surface mode (reported on MIDI ch 7 CC 30) and can
set it. On load it selects **DAW Mixer** (value 1), like Ableton does.

- **DAW Mixer (1)** — rows 1/2 = sends, row 3 = pan.
- **DAW Control (2)** — rows 1/2 = Q-Links, row 3 = global parameters.
- **Custom modes (6-29)** — the surface belongs to the device's custom mapping; the
  script keeps transport/navigation alive and shows `Custom mode <n>` on the overlay.

## Faders (MIDI ch 16, CC 5-12)

Volume of the track in that column: `mpc.tracks.normalTracks[bank+col].Volume.value`
(0..1). The bank follows the Track ◀▶ buttons.

**Pickup**: on load and on every bank move the script pushes each visible track's
volume to the device as CC 5-12 on ch 16 (the position channel), arming both the
hardware pickup and a software guard that ignores movement until the fader reaches or
crosses the track's value. Movement is otherwise direct (`value/127`).

## Encoders — DAW Mixer mode (ch 16)

| Row | CC (abs / rel) | Controls | LED |
|---|---|---|---|
| 1 | 13-20 / 77-84 | `Send 1` (bank A) or `Send 3` (bank B) per column | **track colour**, brightness = send level |
| 2 | 21-28 / 85-92 | `Send 2` (bank A) or `Send 4` (bank B) per column | **track colour**, brightness = send level |
| 3 | 29-36 / 93-100 | `Pan` per column | continuous, high contrast: dim white at the centre (distinct from the hues), blue L / orange R fading in from it, brightness = 0.12 + 0.88 · (distance from centre)^1.7, full-bright at the extremes |

**All knob rings follow one rule: hue says what, brightness says how much.**
`brightness = 0.07 + 0.93 · value^1.7` of the base colour — a subtle ~7% tint at
zero, full-bright at the top. Bases: sends → the track colour; pan → blue/orange
by direction with a dim-white centre; Q-Link rows → turquoise/purple scaled by
`GetValue`; row-3 global page → its colour scaled by the parameter readout (tempo
60-220, swing 50-75%, Q strength %, division index, metronome/loop on/off, master
volume); row-3 track page → pan readout, then per-param colours (Send 1-4 =
blue / purple / turquoise / green, volume trim = orange) scaled by value.
Q-Link/global values are polled every 200 ms in control mode (polled, no
listeners); mixer values repaint via their listeners.

Rows 1/2 ring in the column's actual track colour (`normalTracks[i].Colour`,
ARGB halved into the LED's 0-127 range; near-black falls back to dim white), so
the knob columns visually match the MPC's track colours and repaint live when a
colour changes. Tracks without clips go dark (HasClip poll, bounded to 128 rows).
The send bank (A/B) is announced by the overlay and screen instead of ring
colours.

- Relative deltas: `value - 64`; step = 1/64 of the send range, 1/127 of the pan range.
- Absolute CCs are converted to deltas — nothing is ever direct-written as
  `value/127`. Device findings 2026-11, probe pending (`reports/00-FINAL-TRIAGE.md`
  §5): row 1's relative enable is dead on fw 1.1.11, so row 1 keeps emitting
  absolute CCs 13-20. The first sighting after load/mode switch is absorbed as the
  baseline (no jump) and every further step nudges exactly like the relative path.
- Page ▲▼ switches the send bank A ↔ B.
- Screen: 3-line page per encoder — track name / parameter / value (`L16`, `45%`).
  Send values are shown as percent DELIBERATELY (user-confirmed 2026-11) — do not
  "restore" dB.

## Encoders — DAW Control mode (ch 16)

**Rows 1-2 (16 encoders) = MPC Q-Links 0-15**, script-driven: every movement is
translated into `qlinks[i].Touch()` + `Twist(delta)` by the script (`SetPosition`
only as a last resort — it does not reach the edit value). The knob ORDER mirrors the MPC's Q-Link
screen (device-confirmed 2026-11-20): the screen lists four groups read top-to-bottom —
group 1 = Q-Links 13,9,5,1, group 2 = 14,10,6,2, group 3 = 15,11,7,3, group 4 =
16,12,8,4 — so **XL3 row 1 = groups 1+2 and row 2 = groups 3+4**, each group's four
slots left-to-right on the knob row: row 1 `{12,8,4,0,13,9,5,1}` / row 2
`{14,10,6,2,15,11,7,3}`. Turning the top-left knob moves the screen's group-1 top slot
(Q-Link 13). Native hardware routing
(`AddInfiniteCCToQLink`) is **disabled by default**: on XL3 fw 1.1.11 the MPC's
infinite-CC parser runs inverted vs the XL3 binary offset, so knobs turn parameters
the wrong way. Device findings 2026-11, probe pending
(`reports/00-FINAL-TRIAGE.md` §5). When the direction/magnitude probe allows
re-enabling, it binds in the device-inferred `(qlink, cc, channel)` order and
self-verifies per encoder non-circularly (remove/rebind query-flip) before trusting
it; the routing sequence stays:

| Step | Call |
|---|---|
| give the CC up | `mappings.script.RemoveCCToScript(15, 77+i)` |
| route it | `AddInfiniteCCToQLink(i, 77+i, 15)` (arg order: Q-Link first — device-inferred [H4]; verified non-circularly) |
| tune it | `SetInfiniteCCMagnitude(i, 77+i, 1)`, `SetQLinkFineAdjust(i, 77+i, false)` |

LED: turquoise (row 1) / purple (row 2) when the Q-Link has a target name,
dark when unassigned. Screen: `Q-Link n` / target name / value string.

**Row 3 = global parameters** (page 0, the default):

| Col | Function | Range / call | LED |
|---|---|---|---|
| 1 | Tempo | ±1 BPM per detent (`project.BPM`, `sequencer.SetBPM` fallback) | orange |
| 2 | Swing | ±1 %, 50-75 (`quantiser.SetSwing`) | yellow |
| 3 | Quantize strength | ±1 % (`quantiser.SetStrength`) | white |
| 4 | Quantize division | cycle 1/4, 1/4T, 1/8, 1/8T, 1/16, 1/16T, 1/32, 1/32T | white |
| 5 | Metronome | CW = on, CCW = off (`SetMetronomeEnabled`) | green |
| 6 | Loop | CW = on, CCW = off (`SetLoop`) | yellow |
| 7 | Automation filter | CW/CCW steps the real filter type (`Get/SetGlobalAutomationFilterType`, enum enumerated lazily; CW-only `Advance` as the degrade); the screen shows the actual type | white |
| 8 | Master volume | ±1/127 (`masterTracks[0].Volume`) | white |

**Row 3, track-utility page** (Page ▲▼ cycles): pan, Send 1-4, volume trim of the
**current** track (the MPC cannot edit a non-selected track).

Shift + Page ▲▼ walks the current track's plugin presets
(`currentTrack.Next/PrevPluginPreset`).

## Buttons (MIDI ch 1)

| CC | Control | Press | Shift + press |
|---|---|---|---|
| 37-44 | top row | Solo (or Arm after cycling) of that column's track | — |
| 45-52 | bottom row | Mute (or Select) of that column's track | — |
| 65 | Solo/Arm | cycle the top row solo ↔ arm | — |
| 66 | Mute/Select | cycle the bottom row mute ↔ select | — |
| 102 / 103 | Track ▶ / ◀ | moves the visible 8-track window by ONE track per press (+1 / −1); the current track is never changed — use the bottom Select row | **`commandManager.Redo` / `Undo`** |
| 106 / 107 | Page ▲ / ▼ | mixer: send bank; control: row-3 page | mixer: `BarForward` / `BarBack`; control: plugin preset next/prev |
| 116 | Play | `TogglePlay` (stop when playing); **double-press: `JumpToBeginning`** | `Stop`; when stopped: `StopAllClips` |
| 118 | Record | `Record` / `RecordOff`; **double-press: tap tempo** (reverts the accidental arm) | `Overdub` |
| 104 | Novation | log the surface state | probe mode on/off |

Solo/Arm/Mute/Select write `normalTracks[i]:Set{Solo,RecArm,Mute}(bool)` with a
`.value` fallback; Select calls `mpc.tracks.SetCurrentTrack(i + offset)` — the API
takes the **global** index — plus the column-relative `clipMatrix.SelectTrack(i)`.

**Track numbering.** The MPC UI numbers *all* tracks (`mpc.tracks.Count`, including
MIDI/non-mixable ones); the surface addresses the *mixable* subset
(`normalTracks`/matrix columns). When the two differ, the script learns the
global↔normal offset passively (current track's global `Index` − its position in
`normalTracks`, re-derived on every selection/project change) and uses it for the
screen/overlay page numbers, the select-row highlight and `SetCurrentTrack`, so
"tracks 2-9" means the MPC's own tracks 2-9. `trackCount` uses
`SizeNormalTracks` (never `Count`) so phantom pages cannot appear.

## Feature buttons (MIDI ch 7)

| CC | Control | Behaviour |
|---|---|---|
| 63 | Shift | tracked (127/0); the device itself previews values on Shift+turn |
| 30 | Mode | device mode report/select — the script follows 1/2, announces custom modes |
| 31 | Edit | cycles the control-mode row-3 page (same as Page ▲) |

## LED semantics (state-driven, never press-driven)

All LEDs are custom RGB (sysex `01 53`): bright = active, genuinely dark (~1/6
luminance) = inactive, off = unavailable. A test enforces ≥4x contrast per pair.

| LED | Source |
|---|---|
| Play | `sequencer.Playing` (green / dim green) |
| Mixer rows 1/2 | track colour per column (`Colour` listener) |
| Record | `RecordState` (red / dim red) |
| Track ◀ / ▶ | bank > 0 / bank+8 < track count (dim white) |
| Top row | Solo (blue) or RecArm (red) — lit only when the flag is active; otherwise dark |
| Bottom row | Mute (orange when muted) or Select (white = current track); otherwise dark |
| Empty tracks | no clips in the clip matrix → the whole column (button rows + encoder rings) goes dark; re-evaluated every ~2 s |
| Solo/Arm 65 | blue in solo mode, red in arm mode |
| Mute/Select 66 | orange in mute mode, white in select mode |
| Novation 104 | dim white; solid white while probe mode is on |
| Encoders | see the mode tables above |

## Screen semantics

The fader displays form a **track map**: each of the 8 columns permanently shows
its track's name + live volume (dB), updated on bank moves and renames. The
Novation button overlays the controlled range plus first/last track names; bank
moves show the same overlay. Identical overlays re-trigger via config `7Fh`, so
the screen never stays dark on a repeat.

Mixer mode carries the transport on the stationary display: line 1 ends with
`|` stopped / `>` playing / `REC` recording plus the BPM (`| 120.0`); line 3 shows
`bar N.M` + send bank. Position assumes 960 pulses per quarter in 4/4; the raw
playhead is logged once (`playhead raw=…`) so a wrong unit is trivially spotted
and `PULSES_PER_QUARTER` corrected.

| Target | Content |
|---|---|
| 53 (stationary, 3-line) | `MIX 2-9` / current track name / Q-Link focus (control mode) or `-` |
| 5-36 (per control, 3-line) | title (track/Q-Link/global) / parameter / value |
| 54 (overlay, 2-line) | mode, bank, page and probe announcements |

Text is sanitised to ASCII 20h-7Eh, truncated to 16 chars, cached by content, and
pumped at most 6 sysex per 50 ms timer tick.

## Probe mode

Shift + Novation toggles it. Every incoming message is logged
(`probe ch=<ch> cc=<cc> value=<v>`) and the pressed control lights white (relative CCs
light their absolute index). Shift and the Novation button stay live so probe mode can
be exited from the device.
