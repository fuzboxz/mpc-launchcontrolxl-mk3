# W3 — Mixer-mode encoders (hardware report, Phase 0)

Source: real hardware — MPC Live III, Launch Control XL 3 fw 1.1.11, MPC 3.10.1.
Script refs = `script/LaunchControlXL3.lua` (main file, 2271 lines). Read-only audit; no code changed.

## BUG A — Send values jump to the encoder's absolute position

**Symptom (verbatim):** "Sends (both pages) work. Send values jump to encoder position if they do not
match the MPC." Turning an encoder whose knob position differs from the MPC's stored level makes the
level JUMP to the knob's absolute position.

**Root cause:** The device emits **absolute** CCs 13-28 for encoder rows 1/2 (its relative-row enable
for those rows is not taking effect). `HandleMIDICC` (1985-1988) dispatches CC 13-36 to
`handleEncoderAbs` (1733), whose guard `surfaceMode ~= MODE_CONTROL or row < 2` (1734) routes **every**
mixer-mode encoder to the direct write `setTrackValue(idx, name, value / 127)` (1741). One CC moves the
send from its stored level to the knob's internal counter: a jump by construction. The intended path —
per-detent nudges via `handleMixerEncoder` (1618; step 1/64 sends / 1/127 pan at 1624; `nudgeTrackValue`
719-722) fed by REL CCs 77-100 (1989-1994) — never sees rows 1/2, because the device never shifted
their CC numbers to the relative range.

**Evidence chain (one wire theory consistent with all observations):**

- Wire facts: enable per row is `B6h 69/72/73 7Fh` on ch 7 (`docs/LCXL3-LAYOUT.md:71`); in relative mode
  CC numbers shift +40h per row → 77-84 / 85-92 / 93-100 (`LCXL3-LAYOUT.md:72`, rows at :48/:50). The
  script sends exactly that enable (`surfaceConfigure` 644-647, `FEAT.relRow = {69,72,73}` at 69) plus
  touch/pickup/brightness/curve (648-653).
- Observation 1 — mixer sends jump: only the direct write at 1741 can move a send more than one step
  per message → abs CCs 13-28 arrive in mixer mode → rows 1/2 emit **absolute** → their enable CCs
  (69, 72) are ineffective and the +40h shift did not happen for those rows.
- Observation 2 — control-mode row 3 globals respond per-detent (tempo etc. work): `handleGlobalEncoder`
  (1636) acts on delta ±1 only and is reachable solely via `handleEncoderRel` (1722 → 1715) → REL CCs
  93-100 **do** arrive → row 3's enable (CC 73) **worked** and the device does implement the +40h
  shift. Under the abs path row-3 control-mode events would go to `twistQlink(16..23, ±1)` (1747-1752),
  i.e. Q-Links 17-24, not tempo — so per-detent tempo proves the relative path is live on row 3.
- Observation 3 — control-mode row 1 still writes sends: the 1734 guard is true for `row < 2` in *any*
  mode, so abs CCs 13-20 in control mode write `Send1`/`Send3` via `mixerParamFor` (1608-1614, 1740-1741).
  REL row-1 CCs in control mode can never write sends (`handleControlEncoder` 1700-1710 routes to
  Q-Link twist / hardware routing) → the observed send writes must be abs-driven → abs CCs also arrive
  in **control** mode. Pans (row 3, mixer) work without jumping, which closes the loop.
- Eliminated alternatives: "device always emits both abs+rel per detent on every row" is inconsistent
  with pans working — mixer row-3 abs (29-36) would hit the same 1741 write with `mixerParamFor(2) = "Pan"`
  and jump too. "Enable failed entirely" is inconsistent with row 3 being per-detent.
- Conclusion: **partial enable — CC 73 effective, CCs 69/72 not**. Rows 1/2 stayed absolute; row 3
  shifted to 93-100. Not timing/framing: 73 succeeded inside the same message run (645-647).
  Disproven [p0]s: `LCXL3-LAYOUT.md:71` (PRG's enable CC set 69/72/73 at best partially correct on
  fw 1.1.11) and the script's inertness comment at 1731-1732 / `MAPPING.md:53` ("abs only arrive if
  the relative-row enable failed") — the degrade path is **active** on rows 1/2. Why 69/72 fail while
  73 works is unresolved (wrong PRG CC numbers for rows 1/2, or fw quirk): do **not** change enable
  CCs until the probe below identifies what the firmware honors.
- Note: `tests/` never exercise this. `mock-mpc.lua` mocks the MPC host API only; no simulated LCXL3
  emits CCs, so green tests say nothing about which wire messages the real device sends.

**Fix direction (degrade, never break; layers 1-2 independent of the enable mystery):**

1. Make the abs path non-jumping. In the mixer branch (1734-1746), convert the absolute into a delta
   against the last abs value seen for that control (cache `lastAbs[row * 8 + col]`) and apply
   `nudgeTrackValue(idx, name, delta * step)` with the same steps as 1624; skip/clamp spikes. This
   reuses the repo's own degrade pattern — control row-3 abs already degrades to
   `twistQlink(i, value > 64 and 1 or -1)` (1747-1752) instead of a direct set. Result: mismatches
   nudge instead of teleporting.
2. Contain the control-mode leak: rows < 2 in MODE_CONTROL must not take the mixer branch. Route them to
   the row-3-style delta/qlink path (nothing when `qlinkRouted`), so control-mode row 1 stops writing
   sends — the 1734 condition should branch on mode first, row second.
3. Repair the enable per probe results: keep `B6h 69/72/73 = 127` only if validated; add a ch-8 feature
   query + re-send on session resume as self-heal. Optionally also ignore abs CCs for a row once REL
   traffic is observed on it (belt-and-braces for a "device emits both" fw variant).

**Confidence:** high on the mechanism (abs applied via 1733-1746; rows 1/2 absolute, row 3 relative);
medium on *why* 69/72 fail.

**On-hardware verification:**

- Arm probe mode (Novation button; toggle at 1848-1850; `probe` logs `ch=%d cc=%d value=%d`, 1854-1856).
  Turn a row-1 encoder one detent slowly: today expect only `ch=15 cc=13..20` lines. If `cc=77..84`
  lines also appear, the device emits both abs+rel per detent and fix 3's ignore-abs-when-rel-seen gate
  becomes the primary fix. Turn row 3: expect only `cc=93..100` (confirms CC 73 + the +40h shift).
- From a MIDI debugger on the DAW port, one at a time: `B6 69 7F`, turn row 1, watch for abs vs rel;
  repeat with value `01`; then neighbors 68/6A (wrong-CC hypothesis). Query state with `B7 69` on ch 8
  and read the ch-7 reply (`LCXL3-LAYOUT.md` §7: queries ch 8, replies ch 7) to see what mode the device
  believes row 1 is in. Re-test after `B6 73 7F` was sent first vs last (ordering hypothesis).

## BUG B — Pan screen shows ±100 instead of the MPC's ±50

**Symptom (verbatim):** "Pans - work. Screen on LCXL shows values of -100 to 100, whereas MPC itself
shows -50 to 50."

**Root cause:** `H.fmtPan` (269-276) scales the offset by 200: `amt = math.floor(math.abs(d) * 200 + 0.5)`
(275), so hard L/R render as "L100"/"R100". The MPC UI pan convention is L50..C..R50. Formatting-only:
the value written to the track (0..1, centre 0.5) and the LED ring (`panPalette` 1395-1402, geometry
based) are unaffected; `fmtPan` is the single helper used at 1628, 1694, 1743, 2074.

**Evidence chain:** `H.fmtPan` 275 (`* 200`); `MAPPING.md:55` shows the old-scale example (`L32`); no
doc states the device should display ±100 — the MPC convention (-50..50) is the observed reference.

**Fix direction:** one line — change `* 200` to `* 100` at 275 (keep the 0.02 centre dead zone).
Update the doc example to stay truthful: `MAPPING.md:55` `L32` → `L16` (pan 0.34 at half scale).
`RECOMMENDATIONS.md:232` already describes pan as a helper; no further doc change needed.

**Confidence:** high.

**On-hardware verification:** select a track, turn pan fully left: LCXL screen must read `L50` while
the MPC UI shows -50; centre still reads `C` on both; sweep and confirm no gap at extremes.

## ITEM C — Send screen shows percent, not dB — confirm and document (no fix)

**Symptom (verbatim):** "Screen on LCXL shows a percentage rather than the dB (I quite like this!)"

**Finding:** This is `H.fmtPercent` (264-266) applied to sends at 1628, 1696, 1743, 2074. The docs
already specify percent for sends — `MAPPING.md:55` shows the value field as `45%`; dB was never
promised for sends (dB is reserved for volume paths via `H.gainToDb` 258-263: faders, master, track
volume). So there is **no docs-vs-code conflict to reconcile**; the user preference matches the
documented intent.

**Recommendation:** Keep percent. Explicitly: percent is confirmed as intended and user-preferred —
no change to code or docs is required for correctness. Suggested (optional, next docs pass): one line
in `docs/MANUAL.md`/`RECOMMENDATIONS.md` marking percent-on-screen for sends as deliberate (user
confirmed 2026-11), so a future edit does not "restore" dB. `MAPPING.md:55` is the authoritative line
to point at.

**Confidence:** high.

---

## Residual risks / open questions

- Why CCs 69/72 are ignored (wrong PRG CC numbers vs fw 1.1.11 quirk) is unknown; probe captures are
  the prerequisite for fix layer 3. If the probe shows abs+rel are emitted together on enabled rows,
  priority shifts to the rel-seen gate over the enable repair.
- Tests cannot regress-check any of this: the mock has no device-side CC emitter; a wire-level fixture
  would need a fake device emitting both the 13-36 and 77-100 ranges.
