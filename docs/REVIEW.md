# Review — implementation vs contract

Reviewed after Phase 1. Each row: what the code does, against which contract clause
(`API-CONTRACT.md` §n, `LCXL3-LAYOUT.md` §n).

## Input path

| Clause | Implementation | Verdict |
|---|---|---|
| §0 register-before-deliver | `SURFACE_CC` table → `routeSurface(true/false)` in OnLoad/OnUnload; symmetric | PASS |
| §0 channels 6/14/15 registration | registered alongside channel 0; **unproven on device** | PASS (host), P0 |
| §0 sysex to script | `SetHandleSysex(true)`, `HandleMIDISysex` parses the identity reply | PASS |

## Output path

| Clause | Implementation | Verdict |
|---|---|---|
| §1 LED palette CC | `ledSet(controlIndex, palette)` on ch 1, cached | PASS |
| LCXL3 §5 encoder LED index | absolute indices 13-36 used even in relative mode | PASS |
| LCXL3 §6 screen sysex | configure/text builders; payload without F0/F7 | PASS |
| LCXL3 §6 pacing | queue + 6-per-tick pump; content cache | PASS |
| LCXL3 §8 DAW mode | both enable/disable forms sent on load/unload | PASS |

## State

| Clause | Implementation | Verdict |
|---|---|---|
| §2 track props | read/write via `.value`, setters first for flags | PASS |
| §2 count | Count → GetCount → SizeNormalTracks chain | PASS |
| §2 do-not-use list | no `mpc.tracks.Get*/Set*` free functions anywhere | PASS |
| §3 transport | `Playing`/`RecordState` props with `IsPlaying`/`IsRecording` fallbacks | PASS |
| §4 Q-Links | hardware routing first (probed arg order + verification), `Twist` fallback, `SetPosition` last resort | PASS |
| §7 popup guard | `requireProject` on every project-scoped action | PASS |
| §7 listeners | `prop:listen(fn, name)`; all stopped in `OnUnload` | PASS |

## Degrade matrix (host-tested in `tests/test-degrade.lua`)

| Missing | Behaviour | Verdict |
|---|---|---|
| `mappings.controlSurface` | Q-Link rows via script `Twist`; one log line | PASS |
| `mpc.controlSurface` | Q-Link rows inert; transport alive | PASS |
| `sequencer` | transport buttons inert | PASS |
| project / popup | refusals logged once, no native calls | PASS |
| 0 tracks | mixer surface inert | PASS |
| read-only prop | one log line, handler continues | PASS |

## Known gaps (deliberate, phase 1)

- No scene/clip launch, no step-seq/pad-perform pages (see RECOMMENDATIONS).
- Stationary focus line degrades to `-` (no readable selected-Q-Link API).
- Blink mechanism exists but nothing blinks yet.
- Bitmap screen path unused.
- Device IDs 2-8 need a hand-edited port name.

## Device verification (2026-11-18, on-device, XL 3 fw 1.1.11)

| Item | Verdict |
|---|---|
| `.ini` port-name match + checksum | PASS — script loaded |
| Sysex framing (payload without F0/F7) | PASS — identity reply parsed (`firmware: 1.1.11`) |
| Output path (host → device) | PASS — feature query on ch 8 answered |
| ch 7 CC delivery to the script | PASS — `surface mode report 1` reached `HandleMIDICC` |
| DAW mode entry + mode select | PASS — device reported surface mode 1 (DAW Mixer) |
| ch 1 button delivery | PASS — Solo/Arm, Mute/Select, Page ▲▼ presses acted |
| Popup guard | PASS — refused while the New Project dialog owned the UI |
| ch 16 / ch 14 delivery, Q-Link routing, pickup, pacing | pending physical interaction |

## Open verification items (Phase 0)

From `DEVICE-TEST-PLAN.md`: port name (0.2), channel delivery (0.3), relative
fast-turn behaviour (0.4), sysex framing (0.5), mode report values (0.6), pickup
interplay (0.7), `AddInfiniteCCToQLink` signature (0.8), repaint pacing (0.9).
