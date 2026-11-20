# Final triage — XL3 hardware bug report (MPC Live III, fw 1.1.11, MPC 3.10.1)

Consolidation of 5 worker investigations + 5 audits. Where worker and audit conflict, the audit
wins; every code anchor below re-verified against the working tree. Reports: `w1..w5`, audits
`r1..r5`. Line refs = `script/LaunchControlXL3.lua` unless a doc is named.

## 1. Executive summary

The hardware report is the Phase-0 validation the repo deferred: of the script's `[p0]` gambles,
**most lost**. Confirmed on device: `AddInfiniteCCToQLink`'s probed argument orders are both wrong
(true order is Q-Link-first); `masterTracks[0].Volume` is not the master fader path; the relative-row
enable is honored per-row (CC 69 dead, 72/73 live); `recordActive()` is true during overdub-only and
`RecordOff` then stops playback; absolute encoder CCs arrive and are direct-written (jumps). Working
as designed: track buttons (1-track window scroll), send-percent display, the 6-stop time-division
list. The mock (`tests/mock-mpc.lua`) shares every wrong assumption (arg order, master slot, swing
units, filter enum, no device CC emitter), so the green suite validated nothing about the device.

## 2. Consolidated verdict table

| Symptom (verbatim, abridged) | Verdict | Root cause (one line) | Conf. |
|---|---|---|---|
| Play / Shift+Play / Record work | OK (latent: Shift+Play x2 <350ms rewinds, see T2) | — | high |
| Shift+Record "sometimes stops playback" | **BUG** | 2nd press of quick Shift+Record pair hits plain-Record double-press branch → `RecordOff` revert while overdub raised `recordActive()` → stop (w1, r1) | high |
| Track buttons "only move selection by 1 track" | **WAD + DOC-GAP** | `setBank(bank±1)` scrolls the 8-track window by 1; selection never moves; two unrecorded plan deviations (w1, r1) | high |
| Fader display desync after fast move | **BUG** | cache committed at queue-time + FIFO backlog plays stale texts; device drop of final text under burst sticks (no self-heal) (w2, r2) | high / med-high |
| Sends "jump to encoder position" | **BUG** | row-1 absolute CCs 13-20 direct-written `value/127` in `handleEncoderAbs` (w3, r3) | high |
| Sends show % not dB | **WAD** | documented (`MAPPING.md:55`); user prefers percent — mark deliberate | high |
| Pan shows ±100 vs MPC ±50 | **BUG** | `fmtPan` scales offset x200 (:275) | high |
| Control row 1 "still controls sends" | **BUG** | abs-path guard is mode-blind for rows 1-2 (`:1734`) | high |
| Only row-2-last encoder drives a Q-Link, backwards | **BUG** | arg-order H4 collapses 16 bindings onto QL15←cc92/ch15; MPC parser sign flipped vs XL3 binary offset (w4, r4) | high |
| Q-Link LEDs "sometimes respond" | **BUG (5 stacked)** | single bound QL + name gate + GetValue lag + 0..1/0..127 ambiguity + 200ms poll collapse (w4, r4) | med-high |
| Tempo / Q-strength / metronome / loop work | OK | — | — |
| Swing "changes to 75 then no change" | **PROBE-PENDING** | H2: percent units, by-design [50,75] ceiling via flick; H3: Set expects 0..1 (slam-then-dead). Probe decides (w5, r5) | med-high |
| Time division min 1/4, max 1/32, triplet flicker | **WAD + DOC-GAP** | reaching 1/32 proves canonical round-trip; the flicker IS the T stops (1/8T, 1/16T) in the 6-stop list (w5, r5) | high |
| Auto filter rapid CW, dead CCW | **BUG** | `AdvanceGlobalAutomationFilterType()` per detent, CW-only branch; `Get/Set...FilterType` exist unused (w5, r5) | high |
| Master volume "does nothing" | **BROKEN, remedy probe-pending** | `masterTracks[0].Volume` [p0] disproven on device; silent write-failure swallow violates repo §8 (w5, r5) | high/ open |

## 3. Unified wire/API model (device-proven vs inferred)

| Fact | Status | Settling probe |
|---|---|---|
| Row 3 relative enable (CC 73) works; rows emit +40h shift | device-proven (per-detent globals) | row-3 capture |
| Row 2 relative enable (CC 72) works (REL 85-92 arrive) | device-proven (CC 92 drove QL16) | row-2 enc 8 capture |
| Row 1 enable (CC 69) dead → row 1 emits ABS 13-20 only | device-proven (jumps + control-row-1 sends) | row-1 enc 1 capture |
| Row 2 also emits ABS (T4) or not (T3) | **open** | row-2 enc 8: does cc=28 accompany cc=92? |
| `AddInfiniteCCToQLink` true order = (qlink, cc, channel) [H4] | inferred — uniquely fits observation | remove/rebind query-flip + movement |
| `IsQLinkMappedInfinite` mirrored form (qlink, cc) — false-positive source | inferred | same |
| MPC infinite-CC sign convention flipped vs XL3 binary offset | direction device-proven; magnitude open | `SetInfiniteCCMagnitude(-1)` probe |
| Overdub raises `recordActive()`; `RecordOff` during overdub-only stops playback | device-observed; which prop flips open | transport journal probe |
| Screen text sysex can drop under burst → cache-blocked stale | inferred (med-high) | touch-no-move proof |
| Swing percent units (H2) | hypothesis | unit readback |
| `GetTimeDivision` round-trips canonical strings | proven by reaching 1/32 (logic) | division sweep |
| `Get/SetGlobalAutomationFilterType` exist; enum contents unknown | repo evidence (LPP3 dump :32) | enum enumeration |
| `masterTracks[0].Volume` is not the master fader path | device-disproven; dump reading softened (empty-project artifact) | master surface dump |

## 4. Prioritized fix plan

### P0 — user-visible correctness

1. **Transport double-press gates** (`BP[BTN.play]` :1869, `BP[BTN.record]` :1884): gate BOTH
   double-press branches on `not shiftHeld` (r1-E2: the bare `cc+128` re-key fails — stale unkeyed
   `pressState` still fires; mixed Shift/plain pair still ends in doRecord). Then guard `doRecord`
   (:766-770): no `RecordOff` when overdub-only (OverdubState term), shape decided by probe 5.
   Covers the reported stop AND the latent Shift+Play x2 rewind (r1-E1).
2. **Encoder abs path** (`handleEncoderAbs` :1733-1753): (a) branch mode-first — control-mode rows
   1-2 must NEVER write sends; (b) convert abs→delta via a `lastAbs[row*8+col]` cache, FIRST value
   absorbed as baseline (r3-M1: no jump after load/mode switch); (c) `if qlinkRouted then return
   end` before the abs tail (:1747-1751) to stop double-stepping (r3-M2, r4-8); (d) fix the
   sign-of-64 tail (direction-wrong above center — r4).
3. **Q-Link routing** (`mapQlinks` :1074-1108): bind in H4 order `(i, REL0+i, CH_ANALOG)` first;
   self-verify non-circularly — remove/rebind with query-flip check, then first-twist movement
   check across >=2 polls (GetValue lags [dv]); on failure or inverted direction, per-encoder
   fallback to script-side `twistQlink` fed by abs→delta (r4-2: swallowing abs on an abs-only row
   without this makes QL1-8 permanently dead). Never silently mis-bind again.
4. **Screen pipeline** (`scrText` :494-504, `pumpScreen` :506-513, `showOverlay` :525-547):
   per-key queue dedupe keeping NEWEST via key-tagged scan (NOT a positional index map — unsafe
   with front-inserting overlays, r2-E4); commit cache at SEND time (only safe together with the
   dedupe); post-burst single re-assert (re-queue keys sent in a multi-message tick once on a
   quiet tick — 1+2 alone do not remove permanence, r2). Apply the same class of fix to the
   overlay path.
5. **Automation filter** (:943-948, handler :1664-1668): read state via
   `GetGlobalAutomationFilterType`, step CW/CCW via `Set...`, overlay shows the real type (drop
   constant "cycle"); keep CW-only `Advance` as degrade if `Set` errors. Cites LPP3 dump :32; the
   script's "no scalar getter" comment (:1385) is stale — remove it.
6. **Pan scale** (`fmtPan` :275): `*200` → `*100` (keep 0.02 dead zone); update `MAPPING.md:55`
   example `L32`→`L16`.

### P1 — robustness / polish

- `nudgeMasterVolume` (:961-969): add the missing one-shot write-failure log (repo §8 requires it;
  doubles as the master probe); delete the misleading default-0.7 write; pending probe, degrade
  col 7 to explicit no-op (`Master / Volume / n/a`, dark ring).
- Swing: clamp per-event delta to ±1 (or scale by 25/127) so a flick cannot jump percent-steps —
  correct under both H2 and H3 (r5-M).
- LED polish after routing is honest: prefer `GetValueString`-derived scaling; log-once the
  deliberate dark state for unnamed Q-Links (w4 BUG C).
- `recordActive`/`doRecord`: doc-note the RecordOff-during-overdub hard wall once probe 5
  confirms (r1-M3).

### P2 — docs (gated on probes where marked)

- MANUAL/MAPPING: Track ◀▶ scrolls the window by 1 track, never moves selection (use bottom-row
  Select); annotate RECOMMENDATIONS.md:102 ("bank ±1 (Shift ±8)") and :105 (Shift+Track =
  select prev/next) as superseded — both deviations currently unrecorded (r1-E3).
- MANUAL: document the 6 time-division stops; T-gating behind Shift is a design decision to
  escalate, not a fix.
- Mark sends-as-percent deliberate (user-confirmed 2026-11) so nobody "restores" dB.
- AFTER probes: LIMITATIONS hard walls (master fader path; RecordOff-during-overdub; row-1 abs
  emission); flip API-CONTRACT :47 worded "`masterTracks[0]` is not the fader path" (not "empty
  table" — dump was an empty-project artifact, r5-E1); annotate LCXL3-LAYOUT.md:71 enable-CC row.
- Fix the docs-internal drop-order contradiction (PATTERNS.md:71 vs RECOMMENDATIONS.md:224-225,
  r2-E3).

### Test/mock guards (fix alongside, they are circular today)

Mock currently bakes in: H1 arg order (:388-400), bound master slot (:309), percent swing (:96),
2-value filter enum (:198-201), and models Overdub as OverdubState-only + RecordOff as
non-stopping (:117-125) — the transport bug is invisible to it. Add: a fake device CC emitter
(abs 13-36 + rel 77-100 streams, per-row configurable) to regression-test the dispatch guards;
a screen-pacing assertion (40 CCs between ticks → exactly one op-06 per changed `target:field`
carrying the final value); double-press timing tests including Shift pairs; a mis-bind rejection
test (self-verification must fall back, not report routed).

## 5. Hardware probe session (single, ordered; each decides one fact)

1. **Row-2 enc 8, one slow detent, control then mixer mode** (probe mode on): cc=92 only → T3;
   cc=28 also → T4 (row-2 abs emission). THE deciding capture for the wire theory.
2. Row-1 enc 1: expect cc=13 only; any cc=77 → row 1 emits both. Row-3: expect 93-100 only.
3. ch-8 query `B7 69` (+ manual `B6 69 7F` / `01`, neighbors 68/6A, ordering swap with 73):
   why CC 69 is dead; whether any CC repairs row-1 enable.
4. Fader desync proof (no code change): fast sweep → wait 2 s → **touch, don't move** the fader.
   No repaint = cache-block proven. Nudge 1 step → must render (pipe alive outside bursts).
5. Transport journal (needs a temporary `H.log` — **correction: `logStatus` :1830 does NOT print
   transport state**; r1-E4's "already journals" misread bindGlobal's listener list at :1186):
   Shift+Rec x2 <350 ms (expect stop + "record disarmed"), >400 ms (clean toggle), Shift+Rec then
   plain Rec; log RecordState/OverdubState/Playing after each; same states with Record properly
   armed. Decides the doRecord guard shape.
6. Swing units: log `GetSwing()` before/after one `SetSwing`, the clamped arg, and per-event delta
   magnitudes; CW slow, CW flick, CCW. H2 (args 51..75, MPC climbs) vs H3 (slam to max, dead).
7. Division sweep: log Set arg + raw `tostring(GetTimeDivision())` per detent, CW to ceiling,
   CCW to floor; one-shot log of any `SetTimeDivision` pcall error.
8. Filter enum: `Get` → `Advance` → `Get`, loop until repeat (enumerates the enum); `Set(t0)` +
   readback; watch MPC's filter indicator.
9. Master surface dump: `SizeMasterTracks()`, `[0].Type/.Name/.Volume/.VolumeDB` (+`GetVolume/
   GetVolumeDB()`), `SetVolume(0.8)`+readback vs the MAIN fader, `IsTrackMaster`, select Master
   in MPC UI → log `currentTrack.*`, `MPC.force.master` (LPP3 dump :562); one logged
   `tracks.SetTrackVolume` try (ban is per-method, untested for it — r5-E2).
10. `SetInfiniteCCMagnitude(…, -1)` sign/magnitude probe — only AFTER the Twist fallback is in
    place (never probe without a safety net).
11. Post-fix A/B: routing logs 16/16 or per-encoder fallbacks; no send writes in control mode;
    fader sweep emits <=3 texts and no stale playback; double-press patterns never stop playback.

## 6. Consistency check vs repo decisions

- **"Degrade, never break"**: every P0 fix degrades (fallbacks, no new API surface, pcall-guarded);
  the two places the reviewed fix sketches violated it are corrected in this plan — r2-E4
  (positional index map could corrupt overlay ordering) → key-tagged scan; r4-2 (swallowing abs on
  an abs-only row kills QL1-8) → abs→delta fallback.
- **§8 logging rule**: the plan FIXES the one live violation (`nudgeMasterVolume` silent swallow).
- **Escalation required (design changes, not fixes)**: track-button granularity (±8 pages or
  selection-follow — supersedes RECOMMENDATIONS :102/:105); T-stop gating behind Shift; ANY
  repurposing of the row-3 col-8 slot is FORBIDDEN without a decision (RECOMMENDATIONS 4.3
  reserves a master page; w5 explicitly defers).
- **Evidence discipline**: no `[p0]`/doc flip happens before its probe runs (items marked
  AFTER-probe in P2); "audit wins" was applied throughout, and one audit error itself was caught
  and corrected (r1-E4 / logStatus, section 5 note).
- Mock circularity is treated as a first-class defect: no fix ships without its mock/fixture
  update, or the suite stays theater.
