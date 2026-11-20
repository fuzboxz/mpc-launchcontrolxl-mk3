# R1 — Audit of reports/w1-transport.md

Method: read-only. Verified report anchors against script/LaunchControlXL3.lua (working tree),
docs/*, and tests/mock-mpc.lua (circularity check only). Report's `@98d9421` ref is not
verifiable from the working tree (no git); all anchors below are working-tree lines and match
the report's substance. No claim in the report rests on mock evidence — correct.

## Verdict per report section
- Evidence basis preamble — ACCEPT-WITH-CORRECTIONS. Tick math sound: `dev.timer.Start(50)` at
  2245 (docs/RECOMMENDATIONS.md:297), so `d > 7` ≈ 350 ms holds. But "Play / Shift+Play …
  Confirmed working, no action" is wrong for quick pairs (E1).
- BUG A root cause — ACCEPT. Mechanism verified end-to-end, deterministic in code.
- BUG A fix direction — ACCEPT-WITH-CORRECTIONS. Part 1 as specified is incomplete and does
  not deliver its claimed outcome (E2).
- ITEM B "works-as-designed" — ACCEPT-WITH-CORRECTIONS. WAD holds for the plain press; the
  unrecorded plan deviation is larger than reported (E3).
- On-hardware verification steps — ACCEPT with notes (E4).

## Verified anchors (spot-checked, substance + line)
- isDoublePress keyed by CC only; `d < 0 or d > 7` gate; pressState captured in the false
  branch before handler side effects: 848-858 (850, 852, 853). Declarations 148/150; cleared
  only on reload 2208-2209.
- Dispatch: CH_BUTTON, `fn and value > 0`, handlers arg-less 2016-2019 → branch order inside
  each handler is decisive.
- BP[BTN.record] 1883-1899: double-press branch 1884-1893 precedes `if shiftHeld` 1894;
  revert condition `st ~= nil and not st.rec and recordActive()` 1887 → RecordOff 1888 →
  doTap 1891. BTN play=116 / record=118 (62-63). Both cited patterns (shift+shift,
  shift+plain) route into this branch — confirmed.
- BP[BTN.play] 1868-1881: double-press → doJumpStart 1869-1872 precedes shift branch 1873
  (doStop/doStopAll). pressState[116] written at 853 but never read (sole read site is 1886).
- recordActive 758-760 = `RecordState` prop OR `IsRecording()`; no OverdubState term → the
  report's "recordActive ⇔ armed-via-Record is an assumption" flag is correct and honest.
- doOverdub 774-780; doRecord toggle 766-767 (RecordOff whenever recordActive()); doTap
  782-793; doJumpStart 795-802; logStatus already logs OverdubState at 1186.
- Item B: setBank 1526-1545 with clamp `max(0, n-8)` + no-op return 1528-1533; H.visibleIdx =
  bank+col 370-372; trackAt → normalTracks[idx] 355-368; trackCount = SizeNormalTracks
  301-318; setBank called only from 1904/1911; selectTrack only from bottom Select row 1944
  (SetCurrentTrack 710/712); paintTrackScreens 1497-1505; showTrackOverlay 1508-1524.
- Docs all match the quotes: MANUAL.md:21-24; MAPPING.md:19, 102, 104-105, 139;
  RECOMMENDATIONS.md:102, 105, 107, 297; API-CONTRACT.md:54-56 (Record/RecordOff/Overdub +
  RecordState/OverdubState all [dv]).

## Errors / weak claims
- E1 (P1, missed same-class bug): Shift+Play ×2 <350 ms → press 1 shift = doStop; press 2 hits
  the double-press branch → doJumpStart (rewind), not the documented "again: stop all clips"
  (MANUAL.md:21, MAPPING.md:104). Identical root cause: isDoublePress keyed by CC, branch
  precedes shift. The Play "no action" line is an overclaim; any fix must gate 1869 too.
- E2 (P1, fix spec incomplete/self-contradictory): re-keying lastPressTick/pressState by
  `shiftHeld and cc+128 or cc` does NOT give "two distinct overdub presses (clean toggle, no
  revert/tap/stop)". The second shifted press still returns true (same effective key ≤7 ticks)
  → the record double-press branch still runs → doTap() still fires; and the branch reads the
  UNKEYED `pressState[BTN.record]` (1886). pressState[118] is written by every plain press
  (853) and only cleared on reload (2208-2209), so a stale {rec=false} from an earlier plain
  arm + overdub-raised recordActive() fires RecordOff → the STOP survives the fix. Smallest
  complete fix: gate the double-press branches on `not shiftHeld` at 1884 and 1869 (one line
  each), plus fix part 2 for the mixed pair (gate alone leaves it: a shift press no longer
  registers cc 118, so plain press → doRecord toggle → RecordOff). Tap-tempo question
  answered: plain-Record double-press keeps working under both schemes (plain presses key by
  cc).
- E3 (P2, Item B incomplete): RECOMMENDATIONS.md:105 (Phase 2) planned Shift+Track =
  "select prev/next track (`currentTrack.Previous/Next`)" and :107 planned undo/redo on
  Shift+Page hold. Shipped Shift+Track = Undo/Redo therefore deviates from TWO plan lines
  (:102 "Shift ±8" and :105), both unrecorded; :105 is the in-repo root of the user's
  "selection" expectation — stronger than "DAW convention". WAD for the 1-track plain scroll
  still stands (MANUAL.md:23-24, MAPPING.md:102/139 match code exactly; no doc promises
  selection movement).
- E4 (P2): verification step 7 needs no code extension — plain Novation → logStatus (1186)
  already journals RecordState/OverdubState/Playing.
- E5 (P2): fix-2 fallback "plain Record arm-only" silently contradicts MANUAL.md:22 /
  MAPPING.md:105 "record toggle"; needs a doc update if taken.
- E6 (P2, cosmetic): "(Shift ±8) — a page-of-8 jump with an 8-bank shift jump" is a garbled
  gloss; the doc means Shift = ±8 tracks. Minor line drift: setBank no-op is 1528-1533
  (report 1531-1533); SetCurrentTrack 710/712 (report 711); showTrackOverlay 1508-1524
  (report 1511-1525). Substance unaffected.

## Circularity / evidence discipline
- Clean: the report cites no mock/test agreement. Note for implementers: tests/mock-mpc.lua
  117-125/145-150 models Overdub as OverdubState-only (RecordState untouched) and RecordOff
  as not stopping Playing — the mock contradicts the report's hardware assumption in step 2
  and would mask the bug; it evidences neither side. The report's split (stop = hardware-
  observed; chain = code-deterministic; which prop flips = unverified assumption) is
  epistemically honest.

## Missed by the worker (additions)
- M1 = E1: BTN.play latent misroute (Shift+Play ×2 → rewind instead of stop-all-clips).
- M2: even under a correct fix, two rapid Shift+Record presses = overdub on then off (both
  presses dispatch doOverdub); no doc defines shifted double-press semantics — decide and
  document (degrade-never-break: acceptable, but should be intentional).
- M3: nothing in docs/LIMITATIONS.md records "RecordOff while merely overdubbing stops
  playback (MPC 3.10.1)" — once step 7 confirms, add it; it is the hard-wall-class fact that
  justifies fix part 2.

## Merge verdict
OK with notes. BUG A diagnosis and ITEM B WAD classification verified against code and docs;
apply E1-E3 corrections before anyone implements (implement the shift-gate + OverdubState
guard, not the bare re-key).
