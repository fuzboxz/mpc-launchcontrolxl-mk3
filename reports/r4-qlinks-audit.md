# R4 — Audit of reports/w4-qlinks.md (encoder control mode / Q-Link routing)

Verdicts below. Line refs = script/LaunchControlXL3.lua unless noted. Mock/doc agreement treated as
non-device evidence throughout.

## Verdicts per section

**Shared core (argument-order arithmetic): ACCEPT-WITH-CORRECTIONS.**
Independently re-derived H1-H4 from the code. H4 confirmed uniquely: writes (QL15, cc=77+i, ch=i),
per-Q-Link keying → 16 overwrites of QL15; ch=i valid only at i=15 (CH_ANALOG=15, :45) →
QL15←(cc 92, ch 15) = "last encoder of row 2 drives Q-Link 16, backwards-only candidate". H1 (all 16
work), H2 (bound ch 77+i unreachable → mapped=0 via else-branch → re-add, fallback Twist), H3 (dead
ch 77+i) all correctly eliminated. Corrections: (1) "pcall does not error → fallback :1089 never runs
on device" is stated as fact; it holds under H4 (all three args in range under *any* reading → no
type/arity/range error) but not unconditionally — under H2/H3 range validation could error and reroute
via :1089; say "under H4". (2) "mapped = 16" requires the mirrored getter (qlink, cc); a (ch, cc)
getter yields mapped=1 — same outcome (routed=true), different log ("1/16"); w4's on-hardware
expectation "qlinks routed: 16/16" is contingent on an unverified getter form. (3) The no-validation /
per-Q-Link-keying assumptions are flagged inline — good, keep them flagged as assumptions.

**BUG A: ACCEPT-WITH-CORRECTIONS.** All anchors verified (see below); mechanism follows from code:
guard :1734 `surfaceMode ~= MODE_CONTROL or row < 2` routes control-mode rows 1-2 abs CCs into
setTrackValue(value/127) :1740-1741; no qlinkRouted guard on the abs path; mapQlinks removes only REL
77-92 (:1084-1086); SURFACE_CC keeps abs 13-36 (:2141-2143, ENC0=13 :50; registration :2172-2175);
comment :1731-1732 verbatim. Correction: the evidence proves abs on **row 1 only** ("the top row");
see wire-theory adjudication — scope the claim, and see Finding 2 on the fix.

**BUG B (binding, H4): ACCEPT-WITH-CORRECTIONS.** Arithmetic verified; matches the symptom. But the
report never confronts reports/w3-mixer-encoders.md, whose "rows 1/2 emit absolute ONLY" would make
CC 92 — and thus BUG B — impossible. See adjudication; H4 must be paired with the partial-enable
theory, not the implied "rel on both rows 1/2".

**BUG B (inversion): ACCEPT.** Flipped-offset vs two's-complement reasoning is sound: 7-bit two's
complement (65→−63) would slam the parameter per detent; the symptom (reversed direction, normal step
size) is only consistent with sign-flipped binary offset. Magnitude honestly marked unprobed/medium,
and a discriminating probe (SetInfiniteCCMagnitude −1, +1 vs ±63) is specified. Correct that
Magnitude/FineAdjust (:1094-1095) are gain/flag, not sign.

**BUG C: ACCEPT-WITH-CORRECTIONS.** All five mechanisms verified: paintControlEncoders :1443,
name gate :1449, qlinkValue :1451/:1459-1361 (v>1 → /127), control poll :2121-2124 + tick 50 ms
(:2245) = 200 ms, repaintDirty collapse, API-CONTRACT.md:63 [dv] lag; mock GetValue returns
position/127 → 0..1 branch only (tests/mock-mpc.lua ~:262-269). Correction: "15 rings static by
construction" overstates — MPC-side activity still moves them (the report's own item 2 concedes it);
say "static absent MPC-side changes".

**Self-verifying routing: ACCEPT-WITH-CORRECTIONS.** Circularity correctly identified and verified:
mock stores key(ch,cc)→idx and reads the same key (tests/mock-mpc.lua:388-400) — assumption-sharing,
not device evidence. Hard limit 5 (no loop-back) verified at API-CONTRACT.md:99. Movement-first
verification is the right non-circular design. Corrections: GetValue "lags one change" [dv] means the
first-twist check must compare across ≥2 polls; and the per-encoder fallback is under-specified — see
Finding 2.

**On-hardware verification: ACCEPT.** Probe mode = Shift+Novation verified (:1922-1924, probe
swallow :1980-1983). Add an explicit row-2-enc-8 capture (expect cc=92 present/absent, and whether
cc=28 accompanies) — this is the single probe that adjudicates w3 vs w4.

## Verified anchors (spot-checked, exact unless noted)
:45 CH_ANALOG=15; :50 ENC0=13; :51 REL0=77; :69 FEAT.relRow={69,72,73}; :644-654 surfaceConfigure;
:1074 mapQlinks; :1086 RemoveCCToScript; :1087 (15,cc,i); :1089 fallback (i,15,cc); :1091 confirm
(15,cc); :1094-1095 magnitude/fine; :1102 qlinkRouted=mapped>0; :1443/:1449/:1451 paintControlEncoders
gate+value; :1704-1705 rel-only qlinkRouted guard; :1731-1732 comment; :1733-1741 abs guard+direct
write; :1747-1751 abs tail; :2121-2124 poll; :2141-2143 abs SURFACE_CC; :2245 timer 50 ms;
tests/mock-mpc.lua:388-400 circular keying; API-CONTRACT.md:63, 66-71, 99; LCXL3-LAYOUT.md:48-50,
69-70; RECOMMENDATIONS.md:55, ~:321. Off-but-in-tolerance in w4: ":1998-2000" is :1989-1991;
":2004" is :1994; ":1448" is :1449; ":1451" exact. Wrong-content cites: see Finding 5.

## Errors / weak claims
1. **P1 — unadjudicated wire-theory contradiction.** w4 BUG B needs rel CC 92 on the wire; w3
   concludes rows 1/2 emit absolute ONLY. Both cannot hold. w3's evidence proves abs on row 1 + no abs
   on row 3, NOT rel-absence on rows 1/2; w4 never confronts this. Fix: state the contradiction and the
   surviving theory (Finding below).
2. **P1 — BUG A fix can break row 1 Q-Links (violates "degrade, never break").** If row 1 is abs-only,
   swallowing control-mode row-1 abs whenever `qlinkRouted` makes QL1-8 permanently dead: the per-encoder
   fallback (§2) re-adds/drives via REL CCs 77-84, which never arrive on an abs-only row — an undrivable
   fallback. Smallest fix: swallow abs per encoder only when that encoder's rel binding is
   movement-verified; otherwise convert abs→delta (cached lastAbs, w3's fix 1) into twistQlink — the
   sign-of-64 tail (:1751) is direction-wrong above center when turning down.
3. **P2 — pcall claim overstated** (see Shared core correction 1). Under H4 it is sound; as written it
   is unconditional.
4. **P2 — "mapped = 16" / "16/16 log" contingent** on mirrored getter form (see Shared core
   correction 2).
5. **P2 — wrong doc cites:** LCXL3-LAYOUT.md:138 is the feature row "69/72/73 encoder rows 1/2/3
   relative output", not a curve caveat; :156 is the ABLETON-Goodbye row. Curve caveats are :70 and
   ~:146. Worse, :138 bears directly on the disputed semantics (per-row rel-output *toggle* → suggests
   rel replaces abs) and cuts against w4's unstated "both streams" rationale; citing it as a curve note
   misses that.
6. **P2 — "CC 69/72 = 127"** in BUG A omits CC 73 (FEAT.relRow :69); 73 evidently worked (row 3), so
   the omission matters to the argument.
7. **P2 — minor:** "15 rings static by construction" overstatement (see BUG C); H2 table cell "only
   abs CC 15 could fire" — under H2 bound channels 77+i are unreachable so CC 15 cannot fire either
   (elimination still holds via mapped=0), and CC 15 is row-1 enc 3 (ENC0=13), not enc2; "native
   routing beats emulation, but degrade, never break" is a paraphrase-fusion of
   RECOMMENDATIONS.md:55 + degrade rules, not a verbatim quote (:321 does exist — risk row).
8. **P2 — fallback double-step:** after the fix, when routing fails and a row emits abs+rel, the abs
   tail (±1) and rel handler (delta) both drive twistQlink → double-step. Needs a rel-seen gate per
   row (w3's fix 3). Under the surviving theory this is latent (row 1 abs-only), not moot.

## Wire-theory adjudication (w3 vs w4)
Surviving theory consistent with ALL evidence in both reports: **partial enable — CC 69 (row 1)
ineffective → row 1 absolute-only; CC 72 (row 2) and CC 73 (row 3) effective → rows 2/3 relative-only.**
- w3 BUG A jump: row-1 abs via :1741 ✓ (its "both pages" = send banks A/B, both on row 1: Send1/Send3).
- w4 BUG A: "top row still controls sends" = row-1 abs ✓.
- w3 Obs 2 per-detent globals: row-3 rel 93-100 ✓. Its pans argument kills only row-3 abs, not row-2 abs.
- w4 BUG B: row-2 rel CC 92 exists → H4 binding QL15←(92, ch15) ✓. CC 92 arriving is direct wire
  evidence that 72 worked — this is what kills w3's "rows 1/2 absolute".
Neither w3's "rows 1/2 absolute" nor w4's implied "rel on rows 1/2" survives alone. Corrections
required on both sides; the single deciding capture is probe mode on row-2 enc 8 (cc=92? cc=28 too?).

## Missed root cause / fixes
- Unifying root cause neither report states: per-row enable is honored selectively on fw 1.1.11
  (69 dead, 72/73 live). Ch-8 feature query + re-send per row (w3's layer 3) covers it; w4 should
  reference it instead of assuming both rows go rel after the H4 rebind.
- Movement check: require ≥2 polls (GetValue [dv] lag) and treat "no movement" on an abs-only row as
  "switch that encoder to abs-delta fallback", not just "rel fallback" (drivability, Finding 2).
- Abs→delta conversion must cache lastAbs; sign-of-64 is wrong above center (pre-existing tail flaw
  the fix would newly expose to row 1).

Overall: ACCEPT-WITH-CORRECTIONS — blockers are the unadjudicated w3 contradiction (add adjudication +
partial-enable theory) and the row-1-abs swallow gap in the BUG A fix; arithmetic, anchors, mock
circularity, and inversion reasoning are verified and sound.
