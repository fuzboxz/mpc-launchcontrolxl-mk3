# W4 — Encoder control mode / Q-Link routing findings

Hardware: MPC Live III, LCXL3 fw 1.1.11, MPC 3.10.1. Script: `script/LaunchControlXL3.lua`.
Method: hardware report = Phase-0 evidence resolving [p0] assumptions; `tests/mock-mpc.lua` is NOT
evidence (it implements the same argument-order guess as the script — see below).

## Shared core: the argument-order arithmetic (drives BUG A and BUG B)

`mapQlinks` (script:1074) calls, per `i = 0..15`, `cc = REL0 + i = 77..92` (rows 1-2 only):

```
pcall(b.AddInfiniteCCToQLink, CH_ANALOG, cc, i)        -- (15, 77+i, i)   script:1087
  fallback only if that *errors*: (i, 15, 77+i)        -- script:1089
confirmed = IsQLinkMappedInfinite(CH_ANALOG, cc)      -- (15, 77+i)      script:1091
```
A C binding receiving three numbers type-checks, so pcall does not error on a wrong order →
**the fallback at :1089 never runs on device**; only the triple (15, 77+i, i) matters.
Assume the C layer stores silently (no range validation), keyed per Q-Link:

| true order | A=15 | B=77+i | C=i | stored result | live on real MIDI (ch 15, CC 77-92) |
|---|---|---|---|---|---|
| H1 (ch, cc, qlink) | ch 15 | cc 77+i | QL i | 16 distinct, correct | 16/16 work — contradicts A+B |
| H2 (cc, ch, qlink) | cc 15 | ch 77+i (unreachable) | QL i | distinct keys, channel dead | 0 rel CCs; only abs CC 15 (row1 enc2) could — not observed |
| H3 (qlink, ch, cc) | QL 15 | ch 77+i (dead) | cc i (0..15) | 16 writes → QL15 only, last wins: QL15←(ch 92, cc 15) | nothing reachable — contradicts B |
| **H4 (qlink, cc, ch)** | QL 15 | cc 77+i | ch i (0..15) | 16 writes → QL15 only, last wins: **QL15←(cc 92, ch 15)** | **exactly CC 92 → Q-Link 16; 77-91 dead** ✓ |

H4 uniquely reproduces "only the last encoder on the 2nd row controls a Q-Link": `ch i` is a valid
MIDI channel only at i=15 (CH_ANALOG=15), and per-Q-Link keying collapses all 16 writes onto QL15.

**Why the confirmation lied (H4):** the getter is called with two args, `IsQLinkMappedInfinite(15, 77+i)`
(script:1091). Under the mirrored getter form (qlink, cc) the query is QL15/cc(77+i); at iteration i the
just-written QL15 binding has cc = 77+i → truthy *every* iteration. So `mapped = 16`, `qlinkRouted = true`
(script:1102), CCs 77-92 stay removed from the script (script:1086) and magnitude/fine are applied 16×
(script:1094-1095) — against bindings that don't exist after the loop except CC 92. The mock
(`tests/mock-mpc.lua:388-400`) stores `key(ch,cc) → idx` and reads the same key — the *same* assumed
order — so the suite is circularly green. **[p0] disproved** (API-CONTRACT.md:66-71, "signatures
unproven"): neither probed order is correct; true order is Q-Link-first, CC second (H4).
`RemoveCCToScript` + `IsQLinkMappedInfinite` is a false-positive, not a verification.

---

## BUG A — "the top row still controls sends."

**Symptom (verbatim):** "the top row still controls sends."

**Root cause:** in control mode the XL3's *absolute* CCs 13-28 (rows 1-2) still reach the script and
`handleEncoderAbs` (script:1733) deliberately sends rows 1-2 down the mixer branch:
`if surfaceMode ~= MODE_CONTROL or row < 2 then` (script:1734) → `setTrackValue(idx,
mixerParamFor(row), value/127)` (script:1741) = Send 1/2. No `qlinkRouted` guard exists on this path
(the guard at script:1705 covers only the relative path). `mapQlinks` removes only REL CCs 77-92
(script:1084-1086); SURFACE_CC keeps abs 13-36 registered (script:2137-2146), so abs CCs always flow
into `HandleMIDICC` (script:1998-2000) → `handleEncoderAbs`. The comment at script:1731-1732
("Absolute encoder values only arrive if the relative-row enable failed") is the **[p0] assumption
disproved by hardware**: the observed mixer-mode "send levels jump to knob position" is exactly the
`setTrackValue(value/127)` absolute path (the relative path only nudges by `delta*step`,
script:1621-1625), proving abs CCs arrive even with relRow enabled (`surfaceConfigure` script:645-647,
CC 69/72 = 127; LCXL3-LAYOUT.md:69-70,138,156 notes curve caveats but not abs suppression).

**Evidence chain:** script:1734/1741; script:2137-2146; script:1998-2000; script:645-647;
LCXL3-LAYOUT.md:48-50 (abs + rel per row); LCXL3-LAYOUT.md:67-70; [p0] script:1731-1732 disproved.

**Fix direction:** change the guard at script:1734 to `if surfaceMode ~= MODE_CONTROL then`, and in
the tail (script:1748-1750) add `if qlinkRouted then return end` before `twistQlink(i, value > 64 and
1 or -1)`: control-mode rows 1-2 abs CCs are swallowed while MPC owns them (a knob emitting both
streams must not double-step) and never written to sends; when not routed, the existing tail already
maps `i = row*8 + col` to the right Q-Link.

**Confidence:** high.

---

## BUG B — "Only the last encoder on the 2nd row controls a q-link, and it works backwards (anti-clockwise changes the parameter clockwise)."

**Root cause (binding):** true signature H4 `(qlink, cc, ch)`; script passes `(15, 77+i, i)`; the 16
writes collapse onto QL15 and the only one with a valid channel is the last (i=15): QL15 ← CC 92 on
ch 15. Rel CCs 77-91 are neither MPC-routed nor script-registered (removed at script:1086, never
re-added because `mapped=16`) → dead. See arithmetic table above.

**Root cause (inversion):** XL3 emits binary offset — pivot 64, 65=+1 CW, 63=−1 CCW
(LCXL3-LAYOUT.md:67-70, `MapMode.LinearBinaryOffset`); the script decodes it the same way
(script:2004 `delta = value - 64`, script:1750). The routed knob moves the *wrong way*, so MPC's
infinite-CC parser uses the opposite sign convention: value<64 = +k (CW), value>64 = −k, i.e. it
expects `value = 64 − delta` (sign-flipped offset). Alternative candidate — 7-bit two's complement
(63→+63, 65→−63) — would slam the parameter per detent; the report shows inverted *direction* with
normal step size, so flipped-offset is the consistent reading (exact magnitude per detent needs a
probe capture). `SetInfiniteCCMagnitude(15, cc, 1)` (script:1094) is a gain (detents per event), not a
sign; `SetQLinkFineAdjust(..., false)` likewise — neither corrects the flip. **[p0] resolved:** MPC's
parser convention is inverted relative to Novation's binary offset.

**Evidence chain:** script:1087-1095; script:2004; script:1750; LCXL3-LAYOUT.md:67-70,138,156;
API-CONTRACT.md:63 (GetPosition lags) and 66-71 ([p0] signature); mock circularity tests/mock-mpc.lua:388-400.

**Fix direction:** (1) bind with the hardware-correct order `AddInfiniteCCToQLink(i, REL0+i, CH_ANALOG)`
first so all 16 bind (H4); (2) treat direction as a *measured* property: if a routed encoder's first
twist moves its Q-Link opposite the sent delta, stop routing rows 1-2 and use the script-side
`twistQlink` fallback for all 16 (decodes binary offset correctly, already implemented). Optionally
probe `SetInfiniteCCMagnitude(…, -1)` as a sign control once, only after the fallback is in place.

**Confidence:** high on H4 (uniquely reproduces the observation) and high on the inversion direction;
medium on exact per-detent magnitude semantics.

---

## BUG C — "The LEDs on the LCXL sometimes respond to changes."

**Root cause:** `paintControlEncoders` (script:1443-1454) paints rows 1-2 from `qlinkTargetName(i)`
(script:1448) and `qlinkValue(i)` (script:1451), refreshed only by the control-mode 200 ms poll
(`ticks % 4 == 0 and surfaceMode == MODE_CONTROL`, script:2121-2123 → `markDirty`; repaint only when
`repaintDirty`). Intermittency is five stacked effects:
1. Only QL15's value ever changes (BUG B) → 15 rings are static by construction; visible response is rare.
2. Name gate script:1448 — an unassigned Q-Link stays dark even while its value changes; targets change
   as pads/parameters are selected, so rings light/darken unpredictably.
3. Read lag — API-CONTRACT.md:63 `GetPosition()` "lags one change" **[dv]**; `qlinkValue`
   (script:1353-1363) reads `GetValue` from the same model, so a ring shows the previous value and
   catches up a poll later.
4. Scale ambiguity script:1359-1361 (`v > 1 → /127 else 0..1`): a parameter whose `GetValue` switches
   convention produces full-scale brightness jumps on small moves.
5. Poll granularity: `repaintDirty` collapses intermediate values between 200 ms polls, so some twists
   never render. The mock returns `position/127` (`tests/mock-mpc.lua:262-264`) → always the 0..1
   branch; lag and the 0..127 branch are never exercised by tests.

**Fix direction:** after routing is honest (BUG A/B fixes) most of this disappears. Additionally:
skip identical `ledSet` writes; read the value from the field the screen uses (`GetValueString` when
`GetValue` is ambiguous); treat `GetTargetName() == nil` as a deliberate dark state, logged once.

**Confidence:** medium-high.

---

## Self-verifying routing (so it cannot silently mis-bind again)

Script-emitted MIDI does not loop back through `dev.mappings` (API-CONTRACT.md hard limit 5 **[dv]**),
so a synthetic-CC probe is impossible; verification must use real input + observed Q-Link motion.

1. **Order discovery, non-circular:** per candidate order: bind → query with the getter form derived
   from the *same* order → `RemoveInfiniteCCToQLink` → require the query to flip to false → rebind.
   Prefer `(i, REL0+i, CH_ANALOG)` (H4) first; try the current `(15, cc, i)` last.
2. **Movement check (the real self-check):** mark each encoder "unverified" at bind time; on its first
   physical twist in control mode compare `qlinkValue(i)` across the next poll. No movement → unbind,
   `AddCCToScript` back, set `qlinkFallback` for that encoder, drive it via `twistQlink` (direction
   correct). Log once per encoder: a silent mis-bind becomes a logged, working degrade.
3. **Direction calibration:** if a routed encoder moves opposite the sent delta, route nothing and use
   the Twist fallback for all 16 — "native routing beats emulation, but degrade, never break"
   (RECOMMENDATIONS.md:55, 321).
4. Keep the existing degrade chain (no mappings → Twist; no qlinks → dark/inert).

## On-hardware verification steps

- **Probe mode** (Shift + Novation): in control mode turn row-1 enc 1 one detent CW then CCW; capture
  whether rel CC 77 (65/63) *and* abs CC 13 both arrive (BUG A proof). Repeat row-2 enc 8 (92/28).
- **BUG A:** select a track with 4 sends; turn row-1 enc 1 → Send 1 jumps to knob position. After fix:
  no send movement; Q-Link path or logged fallback instead.
- **BUG B:** before fix, only enc 8 moves a Q-Link and anti-clockwise moves it clockwise. After fix:
  `qlinks routed: 16/16` only if the remove/rebind check passed; each knob drives QL1-16 1:1 correctly,
  or logs "unverified → Twist fallback" and still works.
- **Magnitude/sign probe:** with only CC 92 bound, apply `SetInfiniteCCMagnitude(15, 92, -1)` in a
  probe build; record whether one CCW detent moves the parameter CCW and by how much (+1 vs ±63),
  discriminating flipped-offset from two's complement.
- **BUG C:** assign targets to QL1-16; twist QL16 and confirm its ring tracks 1:1 at 200 ms; twist an
  unrouted knob and confirm its ring stays dark while the parameter moves via the script path; leave
  one Q-Link unassigned and confirm its ring stays dark (name gate).
