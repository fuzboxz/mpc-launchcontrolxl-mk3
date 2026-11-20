# RECOMMENDATIONS — a fully fledged Launch Control XL 3 ↔ MPC control script

Design document for taking the Phase-1 surface (implemented in
`script/LaunchControlXL3.lua`) to a complete integration. Everything here is grounded
in the verified facts of `LCXL3-LAYOUT.md` (device wire) and `API-CONTRACT.md` (MPC
Lua API); where a claim is still an inference it is marked **[p0]** and has a probe
item in `DEVICE-TEST-PLAN.md`.

Two decisions are already locked:

- **D1a** — Q-Link control prefers *hardware routing*
  (`AddInfiniteCCToQLink`), with script-side `Twist` as the fallback.
- **D2a** — mixer-mode encoder layout follows the Ableton convention: rows 1/2 =
  sends, row 3 = pan, Page cycles the send bank.

---

## 1. What DAW mode actually buys us

Treat the XL 3 as three output surfaces and four input surfaces, all on one USB pipe:

**Outputs (host → device)**

| Surface | Mechanism | Granularity | Cost |
|---|---|---|---|
| Button LEDs | palette CC on ch 1 | 1 msg/LED | trivial |
| Encoder LED rings | palette CC (abs index 13-36) or RGB sysex | 1 msg/encoder | trivial / 1 sysex |
| Screen: stationary | sysex configure + 3 text fields | 3-line page | 4 sysex |
| Screen: per control | sysex configure (once) + 3 text fields | 3-line page per control | 3 sysex |
| Screen: overlay | sysex text + trigger | 2-line toast | 3 sysex |
| Screen: bitmap | 1216-byte sysex + ack | 128×64 mono | 1 big sysex |

**Inputs (device → host)**

| Surface | Channel | Semantics |
|---|---|---|
| Buttons (16 + 10) | 1 | press = value > 0, release = 0 |
| Faders (8) | 16 | absolute 7-bit, hardware pickup optional |
| Encoders (24) | 16 | absolute *or* relative binary-offset per row |
| Touch (32) | 15 | 127/0 per control — including Shift+turn previews |
| Mode report | 7 (CC 30) | the user changed the surface mode |
| Feature replies | 7 | confirmations/queries for the CC 30/63/69-121 set |

The consequence: **the XL 3 is a display as much as an input**. A mapping that only
consumes inputs wastes half the device; a script that repaints naively floods it. Both
halves are already in place (state-driven LEDs, cached/paced screen).

## 2. Design principles (keep these as the script grows)

1. **One writer.** MPC owns project state; the script owns surface feedback. Never
   derive feedback from the echo of your own button press.
2. **Follow the device's mode machine.** The Mode button belongs to the user. The host
   selects a default on connect and then *follows* CC 30 reports — including stepping
   back in custom modes.
3. **Native routing beats emulation.** If MPC can own a control (`AddInfiniteCCToQLink`,
   `AddAbsoluteCCToQLink`, `AddNoteToTrackMute`, …), let it; keep emulation as the
   degrade path.
4. **Everything cached, everything paced.** LED palette by control index, screen text
   by `target:field`, ≤6 sysex per 50 ms tick, dedupe before send.
5. **Degrade, never break.** pcall + type check + one log line per missing feature.
6. **Probe before trust.** Any wire fact not in the vendor doc gets a probe-mode
   capture before it becomes a dependency.
7. **Column = track.** The hardware groups two buttons, a fader and three encoders per
   vertical strip; the UI should not fight that.

## 3. Mode architecture

The fully fledged script should treat the XL 3's two DAW modes plus a set of
*script-side pages* as one state machine:

```
surfaceMode (device)      = DAW Mixer | DAW Control | Custom 1-16
mixerPage                 = sendBank A|B                       (Page ▲▼)
controlPage               = global | track                     (Page ▲▼)
rowModes                  = top: solo|arm, bottom: mute|select (65 / 66)
overlays (transient)      = probe | clipOp | sceneSelect | ...
```

Rules that keep it legible:

- **Page ▲▼ always belongs to the current surface mode's page dimension.** Never
  overload it with a mode switch.
- **Shift+Page ▲▼ is the "next dimension" gesture** (plugin presets today; later:
  device/program selection, send-bank jump).
- **A modal overlay (clip ops, scene select) is armed by holding a button and disarmed
  on release** — the launchpad project's hold-to-arm pattern; it needs no new state
  beyond `heldButton`.
- **Custom modes are a hands-off zone**: transport + navigation stay alive, everything
  else stops painting (the device owns the surface).

## 4. Mapping matrix for the full script

Phase-1 rows are marked ✅. Everything else is the proposal.

### 4.1 Always-on layer

| Control | Action | Feedback | Phase |
|---|---|---|---|
| Faders 1-8 | track volume (bank) | position sync + screen | ✅ |
| Play / Record | transport | play/record LEDs | ✅ |
| Shift+Play / Record | stop / overdub | — | ✅ |
| Track ◀▶ | bank ±1 (Shift ±8) — *superseded 2026-11 by the shipped mapping: Track moves the visible 8-track window by ONE track per press, no Shift ±8, selection never moves* | edge LEDs | ✅ |
| Page ▲▼ | mode page | overlay | ✅ |
| Novation | status (Shift: probe) | white | ✅ |
| **Shift+Track ◀▶** | **select prev/next track** (`currentTrack.Previous/Next`) — *superseded 2026-11 by the shipped mapping: Shift+Track = undo/redo* | repaint | 2 |
| **Shift+Novation (hold 1 s)** | **save** (`controlSurface.save`) | — | 2 |
| **Shift+Page ▲▼ (hold 1 s)** | **undo / redo** (`commandManager`) | — | 2 |
| **Record (double press)** | count-in record (`SetCountInEnable` + `Record`) | blink red | 3 |

### 4.2 Button rows (16 buttons = 2 rows × 8 columns)

| Mode | Top row | Bottom row | Phase |
|---|---|---|---|
| default | Solo / Arm (65 cycles) | Mute / Select (66 cycles) | ✅ |
| **hold Mode** | (device-owned: mode select) | (device-owned) | — |
| **clip overlay** | scene launch 1-8 (`TriggerRow`) | clip stop per column (`StopTrackClips`) | 4 |
| **step overlay** | step-seq row select / mute | pad functions | 5 |

Hold-to-arm overlays reuse the same 16 LEDs with a distinct colour grammar (see §6),
so the user always knows which layer is live.

### 4.3 Encoders — DAW Mixer

| Row | Bank A | Bank B | Phase |
|---|---|---|---|
| 1 | Send 1 | Send 3 | ✅ |
| 2 | Send 2 | Send 4 | ✅ |
| 3 | Pan | Pan | ✅ |
| **3 (Shift held)** | **insert/return level of the current track** | | 3 |
| **any (touch)** | parameter page on screen | | ✅ |

Later: a **master page** (Shift+Page ▲▼ long-press) mapping row 3 to master sends /
cue / crossfader — the `masterTracks[0]` surface exists **[p0]**.

> 2026-11 device findings: **not the fader path as assumed** — `masterTracks[0].Volume`
> writes do not move the MPC's MAIN fader; probe pending
> (`reports/00-FINAL-TRIAGE.md` §5).

### 4.4 Encoders — DAW Control

| Row | Target | Phase |
|---|---|---|
| 1-2 | Q-Links 0-15 (hardware-routed) | ✅ |
| 3 (global page) | tempo, swing, Q strength, Q division, metronome, loop, auto-filter, master | ✅ |
| 3 (track page) | pan, Send 1-4, volume trim of the current track | ✅ |
| **3 (device page)** | **plugin parameters of the current track's selected device, banked by Page** | 4 |
| **Shift+rows 1-2** | **fine adjust** (`SetQLinkFineAdjust(true)` while Shift is held) | 2 |

The device page is the interesting one: MPC's Q-Links already point at the selected
device's parameters, so "device page" mostly means *screen content* (parameter names
+ values), not new routing — see §7.4.

### 4.5 Faders — alternative layers

| Layer | Assignment | Phase |
|---|---|---|
| volume (default) | track volume | ✅ |
| **sends layer** | Send N of each track (choose N by Page) | 3 |
| **master layer** | master + returns | 3 |
| **Q-Link layer** | `AddAbsoluteCCToQLink` on CC 5-12 → 8 absolute Q-Links | 4 |

Switch layers with **Shift+Mute/Select (66)**: it is the one button whose plain
function is a mode cycle, so a shifted cycle reads naturally.

## 5. Clip, scene and sequencer integration

The XL 3 has no grid, but MPC's clip API is column-shaped and the XL 3 is column-shaped:

- **Scene launch**: `clipMatrix.TriggerRow(row)` — 8 rows fit the top button row in a
  clip overlay. Row state via `aperture.sceneProperties[row].State` (same enum as
  clips) for LED feedback.
- **Clip stop**: `StopTrackClips(col)` / `StopAllClips()` on the bottom row of the
  same overlay.
- **Clip window**: an `clipMatrixAperture` of 8 columns × 1 row anchored to the track
  bank makes "column = track" true for clips too; Track ◀▶ then moves both surfaces
  together, and `CanMoveLeft/Right` drives the arrow LEDs.
- **Launch/stop state LEDs**: `aperture.clipProperties[col][0].State` per column —
  dark = empty, track colour = stopped, green = playing, red = recording; blink via
  the timer phase (the channel-2 blink trick stays unverified).
- **Step sequencer**: `controlSurface.stepSeq.Press()` opens the view; row 3 encoder 1
  can scrub bars (`JumpByBar`), buttons can step-toggle via
  `controlSurface.stepSeqSet` **[p0]**. This is the most speculative area — probe
  first.
- **Pad perform / keyboard**: `controlSurface.padPerform` / `keyboardControl` presses
  open the pages; there is no scale/root readback (hard wall), so the screen must not
  pretend to know.

## 6. LED grammar

One colour per *meaning*, never per button:

| Meaning | Colour (palette idx) |
|---|---|
| transport running | green 21 / dim 27 |
| record armed or recording | red 5 / dim 7 |
| solo | blue 41 / dim 43 |
| arm (row mode) | red 5 / dim 7 |
| mute | orange 96 / dim 83 |
| selection | white 3 / dim 1 |
| sends | blue 41, purple 53, turquoise 39, green 21 (Send 1-4, track page) |
| track-page volume trim | orange 96 |
| pan position | blue L / dim white C / orange R |
| Q-Link rows | turquoise 39 (row 1), purple 53 (row 2) |
| global params | orange = tempo, yellow = swing/loop, white = rest, green = metronome |
| overlay active | white 3 on the armed button, everything else dimmed one step |
| unknown/unassigned | off 0 |

Add **blink** only for states that are genuinely transitional (queued clip, armed
record count-in), rendered as a 2 Hz alternation with `off` on the timer phase.

## 7. Screen design system

### 7.1 Targets and roles

| Target | Role | Refresh |
|---|---|---|
| 53 stationary | identity line: mode+bank / current track / focus | on change |
| 5-36 per control | title / parameter / value | on touch + on change of last touched |
| 54 overlay | toasts (mode, page, bank, refusals) | on event, device times out |

### 7.2 Pacing budget

- 6 sysex per 50 ms tick = 120 msg/s; a full-surface repaint (26 targets × 3 fields)
  costs ~13 ticks ≈ 650 ms — acceptable *only* on mode changes.
- Per-turn updates touch exactly 3 fields on one target: 1 tick. Never repaint the
  stationary line on encoder turns.
- The 500 ms `refreshLastTouched` poll is the only periodic text source; extend it,
  don't add more polls.
- If the device ever falls behind (watch for the bitmap ack pattern), drop the overlay
  first, then per-control values, then the stationary line (PATTERNS §10).

### 7.3 Content conventions

- Line 1 is *context* (track, Q-Link n, Global, Master), line 2 is *parameter*,
  line 3 is *value with units* (`L32`, `45 %`, `-12.0 dB`, `1/16T`, `On`).
- 16 chars, ASCII only; sanitise with `-`. Prefer `Send 3` over `Send3`.
- Values format through one helper each (dB, percent, pan, division) so the whole
  surface speaks one language.

### 7.4 The Q-Link name/value problem

`GetTargetName()`/`GetValueString()` exist per Q-Link **[dv]**, so the per-control
pages can always show real names. The stationary "focus" line has no selected-Q-Link
API — options:

1. keep `-` (today);
2. track the *last touched* encoder via ch-15 touch events and show its target
   (cheap, honest, recommended);
3. poll `controlSurface.qlink` props if they turn out to be listenable **[p0]**.

### 7.5 Bitmap (later, optional)

A 128×64 mono bitmap could render a real meter bridge: 8 columns × level bars from
`normalTracks[i].Volume`, peak-hold included. Cost: one 1216-byte sysex per frame —
budget ≤ 4 fps and only while the stationary page is "meters". The ack message gives
a natural frame gate. This is the highest-bling-per-risk item and stays last.

## 8. Q-Link integration deep-dive

1. **Routing**: `AddInfiniteCCToQLink(ch, cc, idx)` per encoder; verify with
   `IsQLinkMappedInfinite`; set `SetInfiniteCCMagnitude(ch, cc, 1)` and leave fine
   adjust off. Probe both argument orders (implemented).
2. **Fine adjust**: while Shift is held, call `SetQLinkFineAdjust(ch, cc, true)` and
   revert on release — the device already suppresses value writes on Shift+turn, so
   this composes cleanly with preview.
3. **Banking**: MPC has 16 Q-Links and the XL 3 has exactly 16 upper encoders — no
   banking needed today. If a future firmware exposes more (Force has 8+8?), Page ▲▼
   becomes the bank dimension and the screen lists the bank name.
4. **Fallback ladder**: hardware routing → `Twist(delta)` with `Touch()` brackets →
   `SetPosition` (display-only; log that values won't move).
5. **Never** write `SetPosition` and pretend it edits audio (hard wall).

## 9. Fader layer & pickup

- Push positions on: load, bank move, external volume change (listener), mode
  changes that repurpose faders.
- Software guard: ignore movement until the fader reaches/crosses the track's value;
  engage on crossing, then track directly. One guard per column, armed whenever the
  *meaning* of the fader changes.
- 7-bit is fine for levels; never map faders to tuning parameters (94 cents/step).
- Alternative layers (§4.5) must each maintain their own pickup reference set.

## 10. MPC-side opportunities worth wiring

| API | What it buys | Where |
|---|---|---|
| `controlSurface.tapTempo` | a real tap-tempo button (Shift+Play long-press?) | 2 |
| `controlSurface.undo` | undo/redo with the MPC's own semantics | 2 |
| `controlSurface.barBack/barForward`, `sequencer.JumpByBar` | arrangement scrub on encoder | 3 |
| `controlSurface.tc/tcOnOff`, `sequencer.GetTCPeriod` | time-division feedback on screen | 3 |
| `engineMode.RequestModeChange` | open Main/Mix/Matrix/Song views from Novation+Page | 3 |
| `ui.ShowTUIFeedback` | mirror MPC's own toasts on the XL 3 overlay | 2 |
| `ui.popups.PushButton` | answer dialogs from the surface | 4 |
| `mappings.tracks.mutes.AddNoteToTrackMute` | hardware-route a mute row (custom mode) | 4 |
| `clipMatrix.Create*Track` | add tracks from the surface (long-press Track ▶) | 5 |
| `commandManager.CanUndo/CanRedo` | light the undo gesture only when available | 3 |

## 11. Performance & robustness budget

| Item | Budget | Notes |
|---|---|---|
| Timer | 50 ms | blink 2 Hz, screen pump 6, repaint-on-dirty |
| Repaint | only on marked-dirty | listeners set one flag; timer coalesces |
| Screen | ≤ 120 sysex/s sustained, ≤ 6/tick | content cache in front |
| LEDs | diffs only | palette cache |
| Listeners | 8 tracks × 11 props + 8 globals | rebind on bank move; stop all on unload |
| Logs | one line per unique failure | `logOnce` |
| Memory | caches keyed by ints/short strings | cleared on unload |

## 12. Testing strategy as the script grows

1. **Mock suite first**: every new mapping gets a wire assertion (call recorded,
   value asserted). The mock already fakes the mapping APIs, qlinks, props, timer.
2. **Minified artifact**: the suite runs against the deployed form (already the case).
3. **Golden captures**: Phase-0 probe output becomes a fixture — a table of
   (control → channel/CC) asserted by a test, so a device capture can be diffed.
4. **Manual doc**: `ACTIONS` is the single source; the test fails when it drifts.
5. **Device passes**: each phase has a DEVICE-TEST-PLAN section; ⚠ items in
   LCXL3-LAYOUT get resolved or promoted to facts.

## 13. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| MPC does not deliver ch 14/15/6 CCs to scripts | whole input path dead | Phase-0 0.3 first; fallback: run the surface on ch 1 via a custom mode (ugly but possible) |
| `AddInfiniteCCToQLink` signature differs | Q-Link routing fails | probe two orders, verify, per-CC fallback to `Twist` (implemented) |
| Device ignores script-sent position CCs | hardware pickup unarmed | software guard always armed (implemented) |
| Screen floods on big repaints | laggy surface | queue + cache + budget (implemented); drop-order defined |
| Relative fast-turn sends growing magnitudes | over-shot parameters | clamp accumulated delta per message; optionally scale by encoder-curve setting |
| Mode report values differ (custom 5-16) | wrong overlay text | treat unknown values as "custom" (implemented); fix after probe |
| Port name wrong in `.ini` | silent no-load | INSTALL step 2 + check-ini gate + journal check |
| Firmware update changes the wire | surface breaks | identity probe logs firmware; keep the wire tables in one place |
| Two XL 3s on one MPC | port ambiguity | device ID 1-8 changes the port name; one `.ini` per unit |

## 14. Phased roadmap

| Phase | Scope | Exit criteria |
|---|---|---|
| **0 (done in code, pending device)** | wire validation | DEVICE-TEST-PLAN Phase 0 all green; LCXL3-LAYOUT ⚠ items resolved |
| **1 (implemented)** | session, mixer, control, Q-Links, transport, screen, LEDs | host suite + device Phase 1 green |
| **2 — interaction polish** | track select gestures, undo/redo/save gestures, fine adjust, focus line via touch tracking, `ShowTUIFeedback` mirror | daily-driver usable |
| **3 — mixer depth** | fader layers (sends/master), insert/return page, master page, bar scrub, view switching, `CanUndo`-lit gestures | mixer work without touching the screen |
| **4 — clip/scene overlay** | hold-Mode clip overlay (scene launch, clip stop, state LEDs), device page on row 3, absolute-CC Q-Link fader layer | clip workflow from the surface |
| **5 — sequencing & flash** | step-seq overlay (probe first), pad-perform/keyboard opens, track creation, bitmap meter bridge | full integration |

## 15. Non-goals

- No pretending to know pad-perform scale/root (hard wall).
- No per-track MIDI input routing from Lua (hard wall).
- No editing note data on non-selected clips (hard wall).
- No DIN output while in DAW mode (device wall).
- No multi-MPC / network anything.
- No bundling of Novation or Akai assets in the repo.

## 16. References

- Novation, *Launch Control XL 3 programmer's reference guide* v1.0 (PDF) — the wire.
- Novation, *Launch Control XL 3 user guide* v1 — surface behaviour, modes, Shift.
- Ableton Live 12.3 `Launch_Control_XL_3` remote script (decompiled) — element map,
  palette, display pacing, connection lifecycle.
- `yutsdxg/launch-control-xl3` SPEC — community corroboration of channels/CCs/display.
- Sibling project `../mpc-launchpad-pro-mk3` — the MPC-side contract, signing, loader
  behaviour, and the patterns this script reuses.
