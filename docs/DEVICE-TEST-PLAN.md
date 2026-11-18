# Device test plan

Run order matters: Phase 0 validates the assumptions the rest depends on. Keep a
journal tail open in a second terminal:

```sh
journalctl -u acvs -o cat --no-pager -f | grep LaunchControlXL3
```

## Phase 0 — wire validation (before trusting anything)

| # | Test | Expected | Covers |
|---|---|---|---|
| 0.1 | Install, reboot, check the journal | `LaunchControlXL3: loaded` appears | `.ini` port names, checksum |
| 0.2 | `aconnect -l` before/after install | the DAW interface is the 2nd port pair; its exact name goes into `input=`/`output=` | LCXL3-LAYOUT §1 |
| 0.3 | Shift + Novation → probe mode; touch every control once | each logs `probe ch=… cc=… value=…` and lights white; channels: 0 buttons, 6 shift/mode/edit, 14 touch, 15 faders/encoders | LCXL3-LAYOUT §2-3; fills in CCs 105, 108-115, 117 |
| 0.4 | Turn an encoder slowly and fast, each curve setting (feature CC 121 = 0/1/2) | log shows per-detent deltas; note whether magnitude or rate grows | relative encoding |
| 0.5 | Watch the screen after load | stationary 3-line page appears (`MIX 1-8` / track / `-`) | sysex framing, display config |
| 0.6 | Press Mode on the device | journal logs the mode report; the script follows (overlay `DAW Control` / `DAW Mixer` / `Custom mode n`) | mode report path |
| 0.7 | Move a fader after a bank change | no jump until the fader reaches the track's value | pickup (both layers) |
| 0.8 | Enter control mode | journal logs `qlinks routed: 16/16 encoders` (or the fallback line); turning row 1 knob 1 moves the MPC's Q-Link 1 on screen | `AddInfiniteCCToQLink` signature + channel |
| 0.9 | Measure a full repaint burst | screen stays responsive; no visible lag on the device | sysex pacing |
| 0.10 | Identity probe | journal logs `firmware: <ver>` from the inquiry reply | `HandleMIDISysex` framing |

Record every deviation in `docs/LCXL3-LAYOUT.md` (⚠ items) and `docs/REVIEW.md`.

## Phase 0 results (2026-11-18, on-device, XL 3 fw 1.1.11)

| # | Result |
|---|---|
| 0.1 | **PASS** — `LaunchControlXL3: loaded` in the journal |
| 0.2 | **PASS** — DAW port = `LCXL3 1 DAW In` (seq graph); `.ini` ships the verified name + factory-style comma fallbacks |
| 0.5 | **PASS** — display sysex framing accepted (screen config + text sent at load) |
| 0.6 | **PASS** — feature query on ch 8 answered on ch 7 CC 30: `surface mode report 1` (DAW Mixer) — proves output→device→reply→`HandleMIDICC`, and that DAW mode + our mode select took effect |
| 0.10 | **PASS** — `firmware: 1.1.11` from the identity reply (`HandleMIDISysex` input path works) |
| 0.3 (partial) | **PASS for ch 1** — user presses on Solo/Arm, Mute/Select and Page ▲▼ arrived and acted (`top row: …`, `send bank …`). ch 16 (faders/encoders) + ch 14 (touch) still need a knob/fader wiggle |
| 0.4, 0.7, 0.8, 0.9 | pending physical interaction |

Note: the device was sitting on the **New Project** popup during the first session, so
project-scoped actions correctly refused (the popup guard fired).

## Phase 2 checks (transport depth — added after first deploy; scene launch removed again)

| # | Check |
|---|---|
| 2.3 | Shift+Track ◀/▶ = undo/redo (`Undo unavailable` log would mean the API shape differs) |
| 2.4 | Record double-press = tap tempo; verify BPM actually follows tapping |
| 2.5 | Play double-press = rewind; Shift+Play while stopped = stop all clips |
| 2.6 | Shift+Page ▲▼ in mixer = bar forward/back; screen line 1 shows `>`/`REC` + BPM |
| 2.9 | Track-coloured encoder rings: change a track's colour on the MPC — rows 1/2 rings should follow within ~100 ms; near-black track colours fall back to dim white |
| 2.10 | Fader displays show track name + dB per column; Novation press and bank moves overlay the controlled range with first/last names |
| 2.11 | Empty-track darkness: columns without clips stay dark (buttons + rings); record a clip onto an empty track — the column lights within ~2 s |
| 2.12 | Value-scaled rings: turn a send up — its ring brightens from a subtle tint to the full track colour; Q-Link rows and the control row-3 pages scale the same way |
| 2.13 | Track numbering: with a project whose track 1 is non-mixable, the journal shows `track offset N`; page labels, select highlight and column selects all follow the MPC's UI numbers (journal `window:` line shows `ui=a-b`) |
| 2.7 | `playhead raw=…` journal value vs the MPC's own bar counter — correct `PULSES_PER_QUARTER` if bar.beat is off |

## Verified during the 2026-11-18 device sessions

Beyond the Phase-0 results above, live journal evidence confirmed: ch 1 button
delivery and actions (solo/arm/mute/select cycles, send-bank pages, bank moves),
ch 16 fader/encoder delivery (pickup re-sync observed), Q-Link routing
(`qlinks routed: 16/16 encoders`), surface-mode select/follow (multiple
`surface mode report 1` follows), the global↔normal track-offset learning
(`track offset N`), project-load window logging, and the overlay ordering fix
(bank overlays announce the new range/names). User-confirmed on v1.0.1 (2026-11-18):
track selection highlight lands on the pressed column, page labels follow bank
moves correctly, general operation "works fine". Items still worth a deliberate
pass: 2.4-2.7 (tap/rewind/bar/playhead unit), 2.9-2.12.

## Phase 1 — surface function

| # | Test | Expected |
|---|---|---|
| 1.1 | Fader 1..8 | track volumes follow; screen shows name/Volume/dB; MPC mixer matches |
| 1.2 | Encoders, mixer mode | rows nudge Send 1/2 and Pan of their column; LEDs show send colours and pan position; Page ▲▼ swaps to Send 3/4 |
| 1.3 | Buttons | top row solo (blue), cycle 65 → arm (red); bottom row mute (orange), cycle 66 → select (white on the current track) |
| 1.4 | Track ◀▶ | bank moves ±1, Shift ±8; the stationary range line follows; faders re-sync |
| 1.5 | Play / Record | play LED green while playing, dim green stopped; record red/dim; Shift+Play = Stop; Shift+Record = overdub |
| 1.6 | Control mode, row 3 | tempo (orange), swing (yellow), strength, division cycle, metronome CW/CCW, loop, automation filter, master volume |
| 1.7 | Control mode, Page | row 3 flips global ↔ track page; Shift+Page walks plugin presets on the current track |
| 1.8 | Q-Link fallback | delete/rename `mappings.controlSurface` (or use a firmware without it) → rows 1-2 still move Q-Links via `Twist`, journal logs the fallback once |

## Phase 2 — robustness

| # | Test | Expected |
|---|---|---|
| 2.1 | No project loaded | project-scoped actions refuse with one log line each; transport alive |
| 2.2 | Dialog open (e.g. New Project) | same refusals, `dialog open (<name>)` in the log |
| 2.3 | 0-track project | faders/encoders/rows inert, no crash |
| 2.4 | Unplug mid-session | MPC logs the device loss; replug + device reload re-runs `OnLoad` cleanly |
| 2.5 | Unload (remove the script / power off the XL 3 last) | all LEDs dark, both displays cancelled, DAW mode left |
| 2.6 | Long soak | 30 min of mixing: no journal spam (caches), no screen lag, no stuck LEDs |

## Phase 3 — regressions after any change

- `./tests/run-tests.sh` on the host (includes the minified artifact).
- Re-run 0.3 (probe) and the Phase 1 list.
