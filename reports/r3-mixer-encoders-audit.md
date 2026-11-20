# R3 — Audit of reports/w3-mixer-encoders.md (read-only; evidence cited from script/, docs/, sibling reports)

## Verdict per section
- BUG A (mechanism, code paths): ACCEPT. The jump can only be produced by the direct write; verified below.
- BUG A (wire theory): REJECT as stated. "Rows 1/2 absolute-only, CCs 69/72 ineffective" is contradicted by
  w4 BUG B, which requires REL CC 92 to reach the MPC. Narrow to: row 1 absolute-only (CC 69 dead),
  row 3 relative-only (CC 73 live), row 2 emits relative (CC 92); row-2 abs emission unproven.
- BUG A (fix direction): ACCEPT — layers 1-2 are theory-independent; layer 3 correctly gated on probe.
- BUG B (pan scale): ACCEPT. BUG/ITEM C: ACCEPT. Probe section: ACCEPT-WITH-CORRECTIONS (add row-2 discriminator).

## Verified anchors (spot-checked, exact)
- script: ENC0=13/REL0=77 :49-50; FEAT.relRow={69,72,73} :69; surfaceConfigure :644-653 (relRow loop 645-647);
  mixerParamFor :1607-1615; handleMixerEncoder :1617 (step :1624, nudge :1626); handleGlobalEncoder ~:1636
  (delta-only); handleControlEncoder ~:1701 (row<2 → qlinkRouted return / twistQlink); handleEncoderRel :1722;
  handleEncoderAbs :1733, guard :1734 `surfaceMode ~= MODE_CONTROL or row < 2`, setTrackValue :1741, abs tail
  twistQlink :1751 (no qlinkRouted guard); dispatch: abs CC 13-36 → handleEncoderAbs :1989-1991, rel 77-100 →
  handleEncoderRel :1992-1997, delta = value-64 :1994; SURFACE_CC registers abs 13-36 :2141-2143; mapQlinks :1074
  (RemoveCCToScript :1086, AddInfiniteCCToQLink(15,77+i,i) :1087, fallback :1089, IsQLinkMappedInfinite :1091,
  magnitude/fine :1094-1095, qlinkRouted = mapped>0 :1102); probe toggle :1848, log :1854; H.gainToDb :256,
  H.fmtPercent :264-266, H.fmtPan :269-277 with `* 200` :275; fmtPan sites 1628/1694/1743/2074; panPalette :1392.
- docs: LCXL3-LAYOUT.md rows :47-49 (13-20/77-84, 21-28/85-92, 29-36/93-100), binary offset :68, enable
  `B6h 69/72/73 7Fh` :70, +40h shift :71, §7 "69/72/73 = rows 1/2/3 relative output"; no doc says rel enable
  suppresses abs, and none promises ±100 or ±50 pan. MAPPING.md:52-55 (rel steps; "Absolute values (only if the
  relative-row enable failed)"; screen `L32`,`45%`). RECOMMENDATIONS.md:232. API-CONTRACT.md:63, 66-71 ([p0]
  signatures unproven). Sibling LUA-API-DUMP.md:968 lists the qlink mappers without signatures — w4's H4 stays a
  hypothesis, but the observation it explains is hardware fact. tests/test-load.lua:77 only asserts registration;
  no device CC emitter exists — w3's "green tests say nothing" is correct.

## Errors / weak claims (w3)
- E1 (P1): Row-2 conclusion contradicted by w4. "Only row-2 enc 8 drives a Q-Link, backwards" requires the MPC to
  receive REL CC 92: the only Q-Link bindings created are mapQlinks :1087 over 77-92, and under w4's surviving
  order H4 the single live one is QL15←(cc 92, ch 15). The script fallback cannot explain it: twistQlink
  (:1705-1710) forwards Twist(delta) with correct sign and iterates every non-nil target, so it is neither
  inverted nor single-knob. ⇒ CC 92 arrives ⇒ row 2 emits relative ⇒ "rows 1/2 absolute-only" is false.
- E2 (P2): The "eliminated alternatives" argument only kills "both abs+rel on EVERY row" (row-3 abs would jump
  pans, per guard :1734). It does not kill "rows 1/2 emit both, row 3 rel-only". Overread of its own evidence.
- E3 (P2): Anchor drift (substance verified): abs dispatch :1989-1991 (not 1985-1988), rel :1992-1997 (not
  1989-1994), nudge :1626, mixerParamFor :1607-1615, panPalette :1392, LAYOUT.md enable :70 / rows :47-49.
- E4 (P2): "Confidence: high on rows 1/2 absolute" is overclaimed — inference, not capture; also the "disproven
  [p0]" on MAPPING.md:53 / comment :1731-1732 only holds under T4: under T3 the enable did fail on row 1, so
  "abs only arrive if the enable failed" is technically vindicated (for row 1).
- E5 (P2): Probe plan never probes row 2 and never cross-references w4's concurrent finding.

## Theory adjudication (observations O1 mixer send jump; O2 control row 1 writes sends; O3 pans work/no jump;
## O4 row-3 globals per-detent; O5 only row-2 enc 8 moves a Q-Link, inverted)
- T-w3 (rows 1/2 abs-only): fails O5 (CC 92 never fires ⇒ no Q-Link motion). REJECTED.
- T4 (rows 1/2 emit both, row 3 rel-only): fits O1-O5; predicts unreported control-mode row-2 Send2/4 leak.
  Not eliminated by w3's argument.
- T3 (BEST FIT): CC 69 failed ⇒ row 1 abs-only; CC 72/73 live ⇒ rows 2/3 rel-only. Fits O1 (row-1 jump), O2
  ("the top row" — verbatim names only row 1), O3/O4, O5 (92 arrives → H4's single binding). Fewest firmware
  exotica. Evidence best supports: row 1 absolute, rows 2-3 relative; row-2 abs unknown (T3 vs T4).
- Discriminating probe (add): probe mode; row-2 col-8 slow single detents in CONTROL then MIXER. T3: only
  `cc=92 value=65/63` (control: Q-Link 16 inverted via mis-bind; mixer: Send2 nudges 1/64, no jump). T4:
  additionally `cc=28` per detent (control: Send4 also jumps; mixer: Send2 jumps). Repeat row-1 col-1
  (expect `cc=13` only; any `cc=77` ⇒ row-1 both). Then ch-8 query `B7 69` and the 69/72 ordering swap, per w3.

## Missed by the worker
- M1: fix 1 (abs→delta cache) must absorb the FIRST abs value per control (no baseline ⇒ store, don't nudge) or
  it re-creates a one-step jump after load/mode switch.
- M2: fix 2 should adopt w4's exact `if qlinkRouted then return end` before twistQlink :1751 — the abs tail has
  no guard today, so under T4 control-mode row-2 abs would double-step Q-Links 17-24 while the MPC owns 9-16.
- M3: under T3 the root fix is only CC 69 (re-send/repair once probed); w3's "don't touch enable CCs pre-probe"
  stands. Layers 1-2 + the rel-seen gate remain belt-and-braces under all theories.
- M4: tests gap confirmed (no device emitter); a wire fixture needs both 13-36 and 77-100 streams.

Merge verdict: OK WITH CORRECTIONS. Mechanism, BUG B, ITEM C stand. Correct E1/E2 before the wire theory is used
to change enable CCs or rewrite MAPPING.md:53 / comment :1731-1732; row-2 status must stay "open pending probe".
