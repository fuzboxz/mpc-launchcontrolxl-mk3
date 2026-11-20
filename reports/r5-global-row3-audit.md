# R5 audit — reports/w5-global-row3.md (global row 3)

Method: every cited script/doc/dump/mock line read directly; logic re-derived from code.
Mock agreement was not counted as device evidence. Hardware-report verbatim was NOT
available; claims resting on it are marked.

## Verdict per section
- Summary table: ACCEPT-WITH-CORRECTIONS — "A: percent units (H2)" and "D2 dump-supported"
  overstate what repo evidence can prove (see below).
- BUG A: ACCEPT-WITH-CORRECTIONS — mechanism and probe design correct; "Decision: H2" is a
  working hypothesis, not decidable from the repo.
- BUG B: ACCEPT — elimination logic is sound; "works as scripted" follows from code.
- BUG C: ACCEPT — all claims verified; fix is degrade-safe.
- BUG D: ACCEPT-WITH-CORRECTIONS — code chain and degrade correct; "dump decisive /
  unbound placeholder" is an overclaim (empty-project dump).
- Cross-cutting: ACCEPT — mock circularity verified; note the premature [p0] flip.

## Verified anchors (confirmed)
- script/LaunchControlXL3.lua: :861 TIME_DIVISIONS; :886-892 get/setSwing (clamp 50..75);
  :894-900 strength (clamp 0..100); :902-915 cycleTimeDivision (exact `d == cur` match,
  default idx 1, clamp 1..6); :943-948 Advance per call; :950-959 masterTrack;
  :961-969 nudge (0.7 fallback :966, silent pcall :967-969); :972-974 masterVolume;
  ring col1 :1368-1369, col3 :1372-1379, col6 :1384-1385 ("no scalar getter" comment),
  col7 :1386-1387; handler col1 :1641-1643, col3 :1647-1649, col6 :1664-1668 (CW-only),
  col7 :1669-1671; delta = value-64 (:1994); H.call swallow :193-202; H.clamp :225-233;
  H.gainToDb "-inf" :256-262.
- docs/: MAPPING.md :40, :79-86 (swing "±1 %, 50-75" :80; filter :85; master :86);
  API-CONTRACT :38-40 (128-slot dv), :47 (masterTracks [p0]), :48-51 (banned free funcs,
  enumerated list), :56-59 (quantiser dv, Advance dv); MANUAL :57, :74-75;
  RECOMMENDATIONS :132-133, :140.
- tests/: mock-mpc.lua :96, :170-175, :184-189, :198-201 (Post→Pre 2-value), :309
  (bound master slot 0.8); test-encoders.lua :92-93 (54→56).
- ../mpc-launchpad-pro-mk3: LUA-API-DUMP :32 (Get/Set/GlobalAutomationFilterType +
  `GlobalAutomationFilterType=userdata(Read)`, no value printed), :35-36 (Count=userdata(0),
  SizeMasterTracks, SetTrackVolume), :560 (quantiser surface, no ranges/triplet API),
  :295-297/:424 (masterTracks 128 slots; slot 0 Volume=userdata(0.0), Type=userdata(Drum),
  Name empty), :426 (`masterTracks.0 = <cycle>`); MAPPING :136-145 (swing percent page);
  LIMITATIONS :46 (Advance device-verified); API-CONTRACT :83 (currentTrack Index/Name/Type),
  :85 (banned list — see error 2); script :1483-1489 (aperture follow = grid, not fader).

## Errors / weak claims
1. P1 — BUG D: "dump is decisive … unbound placeholder, D2 dump-supported" overclaims.
   The dump was captured with an empty project (MPC.tracks `Count=userdata(0)`, dump :35),
   and normalTracks.1 shows the IDENTICAL signature (Volume=userdata(0.0), Type=Drum,
   Name empty) and normalTracks slots also print `<cycle>` (:292-294). So `<cycle>` +
   defaults are empty-project artifacts, not proof slot 0 is dead; D1–D4 are not
   separable from this dump. D2 stays the best guess (device symptom), confidence "high"
   should be "probe-required". Fix: reword D2 as "consistent with dump, unproven".
2. P2 — BUG D: "tracks.SetTrackVolume … banned (API-CONTRACT :50-51) [dv]" extrapolates.
   LPP3 :85 enumerates GetMute/SetMute/GetSolo/GetTrackRecordArmed/GetTrackInputPort/
   GetTrackInputChannel/GetTrackMonitorState; SetTrackVolume/GetTrackVolume are NOT in the
   tested ban. The probe-first framing survives precisely because of this; mark the ban
   as per-method, not total.
3. P1 — BUG A: "Decision: H2" overstates. Swing units are unprovable from the repo: dump
   :560 prints no swing value; LPP3 MAPPING :136-145 carries no device-verified marker
   (unlike pads/SetPosition, which do); the mock is circular; the linchpin "setStrength
   works" rests on the hardware-report verbatim (unverifiable here) and only shows
   SetStrength's family, not SetSwing's. Keep H2 as the favoured hypothesis; the probe
   decides. Report's own "med-high + probe needed" is right; the table verdict isn't.
4. P2 — BUG D intent: no doc says "MAIN" or "Out 1/2"; MAPPING :86/API-CONTRACT :47 say
   "master fader"/"master volume". The MAIN/Out-1/2 equivalence is a reasonable inference,
   but it is the report's, not a citation.
5. P2 — BUG D: "Count=userdata(0), GetCount, SizeMasterTracks" are MPC.tracks members,
   not masterTracks members; masterTracks itself only shows the 128 slot tables. Minor
   misattribution; substance (128 preallocated slots) holds.
6. P2 — BUG B: B2's stall point is start-dependent (dies at 1/16T if the walk starts at
   1/16; the report's 1/4 start gives 1/8T). Conclusion (cannot reach 1/32) unaffected.
7. P2 — BUG A: "25 detents … under a second" assumes delta=±1/event; delta is
   `value-64` (:1994) and could exceed ±1 if the surface sends coarser steps. Probe
   should log delta magnitude too.
8. P2 — internal tension: the table/notes declare API-CONTRACT :47 and RECOMMENDATIONS
   :133 "disproven", while the BUG D section says "probe first". Flip the docs after the
   probe, and word the flip as "not the fader path", not "masterTracks is a 128-slot
   empty table" (that phrasing overreads the dump per error 1).
9. P2 — global caveat: all four diagnoses assume the user was in DAW Control row 3,
   global page; the verbatim doesn't confirm mode/page (symptoms strongly suggest so).
   Worth one line in the report.

## Missed items
- nudgeMasterVolume (:967-969) swallows write failures with no log — violates the
  repo's own §8 rule "a failing property write logs once". Even before any no-op
  decision, add the missing one-shot log; it doubles as the D2/D3 probe.
- BUG C supporting evidence missed: script :1385's own comment "no scalar getter" is
  contradicted by dump :32's GetGlobalAutomationFilterType — stale comment strengthens
  the fix case and should be cited.
- BUG D unexplored leads for the probe: `[0].VolumeDB` (dB write may differ from the
  0..1 gain prop), `IsTrackMaster`, `SetCurrentTrack(masterIndex)` + currentTrack
  readback, and the `MPC.force.master` table (dump :562).
- BUG A: if the probe confirms H2, consider clamping delta to ±1 per event (or scaling
  by 25/127) so an accelerated flick cannot jump multiple percent per CC burst — cheap
  polish consistent with the by-design range.

## Bottom line
Report is largely accurate and honestly hedged where it counts (probes specified
everywhere). Correct three things before acting on it: (1) soften BUG D's "dump
decisive/unbound" and the premature [p0] flip; (2) soften BUG A's "Decision: H2" to a
working hypothesis whose cross-check rests on unverifiable verbatim + same-author docs;
(3) mark the SetTrackVolume ban and the MAIN/Out-1/2 equivalence as unverified
extrapolations. BUG B and BUG C stand as written.
