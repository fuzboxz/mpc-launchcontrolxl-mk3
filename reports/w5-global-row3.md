# W5 — Control mode row 3 (global page): hardware findings

Sources: hardware report (MPC Live III, XL3 fw 1.1.11, v1.0 script); `script/LaunchControlXL3.lua`;
this repo's docs; `tests/mock-mpc.lua`; sibling dump `../mpc-launchpad-pro-mk3/docs/LUA-API-DUMP.md`
("LPP3 dump"). Rule: degrade, never break. READ-ONLY investigation; no code changed.

| Bug | Verdict | Confidence |
|---|---|---|
| A Swing | Percent units, consistent (H2); symptom = the by-design `[50,75]` clamp reached via accelerated flick; probe needed to rule out H3 | med-high |
| B Division | String-mismatch hypotheses **disproven** by "max 1/32"; API round-trips canonical strings; behaviour is the scripted 6-stop list (UX complaint, not a wire bug) | high |
| C Auto filter | Per-detent `Advance…` over a short enum + CW-only branch; `Get/SetGlobalAutomationFilterType` exist unused in the dump | high |
| D Master | `masterTracks[0]` is an unbound slot (dump `Count=0`, `Volume=0.0`); API-CONTRACT [p0] **disproven**; master fader not reachable via tried path | high |

## BUG A — "Swing - seems to change swing to 75 and then does not make a change."

Code chain: `getSwing()` :886-888 (`tonumber(GetSwing()) or 50`); `setSwing()` :890-892
(`SetSwing(clamp(v, 50, 75))`); handler col 1 :1641-1643 (`setSwing(getSwing() + delta)`, overlay
`getSwing() .. "%"`); ring `globalParamT` col 1 :1368-1369.

Unit hypotheses (probe = log `tostring(GetSwing())`, the clamped arg sent, and readback, for one CW
and one CCW detent from 50, with MPC's own swing display in view):

1. **H1 — Get 0..1 normalized, Set percent**: `getSwing()`=0.5 → `clamp(1.5,50,75)`=50 → writes 50
   forever ⇒ no visible change. Probe: Get logs `0.5`, Set arg 50, MPC stays 50%. **Does not match**
   the report (something did change, to 75).
2. **H2 — percent both ways (0..100; 50 = straight, 75 = max)**: CW walks 51…75 (25 detents — an
   accelerated flick emits that in under a second), then pins at 75; overlay literally shows `75%`
   frozen — the user watched our screen. Probe: Set args 51,52…,75,75…; MPC UI climbs 51→75.
   **Matches**: "changes to 75" then "no change" = pinned at ceiling CW (CCW untried per report).
3. **H3 — Set expects 0..1, we send 50..75**: every write ≥50 clamps to 1.0 ⇒ first detent slams
   MPC swing to max 75%, then *both directions* dead. Fits the verbatim most literally. Probe:
   `GetSwing()` flips 0.5→1.0 (or 50→100) after one detent.

**Decision: H2.** Cross-check: the sibling setter `setStrength` :898-900 (`clamp(v,0,100)`,
`SetStrength`) **works** per the report — with 0..1 setters strength would pin at max on detent 1
too, so H1/H3 require a units split inside one setter family. H2 also matches LPP3's device-
documented convention (LPP3 MAPPING.md :140-144 "MPC swing is percent-based … `SetSwing(50-75)`")
and the mock (mock-mpc.lua:96 `mockSwing = 54`; test-encoders.lua:92-93 asserts 54→56). Caveat:
sibling docs share our author — hence the probe.

Fix direction: if the probe confirms H2 this is the designed clamp (MAPPING.md :80 "±1 %, 50-75"),
not a defect — polish only: limit marker at 75 ("75% max"). If the probe shows H3, fix is confined
to `setSwing` :890-892: send `v / 100` (50→0.5 … 75→0.75), keep percent internally; degrade =
one-shot unit calibration (Set 50, read back, compare). Verify CCW explicitly.

On-hardware verification: probe-mode (Shift+Novation); temporary `H.log` around col 1; one slow CW
detent, then a fast flick, then CCW; compare journal numbers against MPC's swing display.

## BUG B — "Time division - minimum is 1/4, max is 1/32. It turns triplet on and off in between some values."

Code chain: `TIME_DIVISIONS` :861 `{1/4, 1/8, 1/8T, 1/16, 1/16T, 1/32}`; `cycleTimeDivision`
:902-915 (exact string match of `tostring(GetTimeDivision())`; no match ⇒ idx 1 ⇒ next CW write is
`1/8`); handler col 3 :1647-1649; ring :1372-1379. No triplet API exists anywhere in the dump
(`quantiser` :560 has only `Get/Set{Enabled,Shift,Strength,Swing,TimeDivision,Window}`).

Derived visible sequences (start 1/16 = idx 4) — every mismatch variant predicts the walk dies at
1/8 or 1/8T:

- **B1 — Get returns an unmatched form always** (number/userdata/`"1/8 t"`): idx resets to 1 every
  detent ⇒ CW always writes `1/8`, CCW always `1/4`; max 1/8. **Contradicts "max is 1/32".**
- **B2 — division + separate triplet flag; Set(`1/8T`) sets 1/8 + T, Get returns plain**: CW from
  1/4: `1/8`(T off) → `1/8T`(T on, Get `1/8`) → keeps writing `1/8T` (T pinned) ⇒ dies at 1/8T.
  **Contradicts "max is 1/32".**
- **B3 — Get returns a different T-spelling** (`1/8t`): T-states never match ⇒ from 1/8T the next CW
  resets to idx 1 and writes `1/8` (T off) ⇒ bounce 1/8 ↔ 1/8T forever; max 1/8T. **Contradicts.**

To ever *reach* idx 6 (`1/32`), `GetTimeDivision` must have returned exactly `1/16T` at that stop —
which proves canonical Get/Set round-tripping. Surviving reading: the walk is exactly the scripted
list — CW `1/4 → 1/8 → 1/8T → 1/16 → 1/16T → 1/32` and back, clamped both ends (min 1/4, max 1/32
= the clamps) — and "turns triplet on and off in between some values" is the user seeing stops 3
and 5 (the T entries *in between* plain values) flicker as they sweep. The probe would show Set
args and raw Get strings cycling canonically through the six strings.

Fix direction: none required for correctness. If the probe confirms canonical round-trip, this is a
mapping/UX expectation gap, not an API bug: document the six stops (MANUAL row-3 section) and, if
desired, gate the T entries behind Shift — a mapping-intent decision, escalate before changing
MAPPING.md behaviour. Only if the probe *does* show an off-form string: normalise before lookup
(lower-case, trim, canonical map) inside `cycleTimeDivision` :904-911.

On-hardware verification: probe-mode; log the Set argument and `tostring(GetTimeDivision())` per
detent; sweep CW to the ceiling and CCW to the floor; log the raw pcall error of `SetTimeDivision`
once (`H.call` :193-201 swallows errors).

## BUG C — "Automation filter - turns it on/off rapidly as encoder turned clockwise, does nothing anti clockwise."

Code chain: col 6 :1664-1668 — `cycleAutomationFilter()` only when `delta > 0`, overlay constant
`"cycle"`; `cycleAutomationFilter` :943-948 — `AdvanceGlobalAutomationFilterType()` **per detent**;
ring :1384-1385 fixed 0.7 (no state feedback, by design comment).

Evidence: `AdvanceGlobalAutomationFilterType` [dv] (API-CONTRACT :59; LPP3 LIMITATIONS :46,
device-verified). The LPP3 dump (:32) shows proven surface left unused: `Get/SetGlobalAutomation
FilterType` and a **read-only** `GlobalAutomationFilterType` prop exist on `mpc.project`; the dump
prints no value, so the enum contents are unproven. The mock invents a 2-value enum
(prop("Post") → Advance → "Pre", mock-mpc.lua:198-201) — shared-author guess, not evidence.

Mechanism: any short enum (2-4 values, at least one reading as "off") × per-detent advance × XL3
encoder acceleration ⇒ rapid on/off flicker CW. CCW is dead **by code** — no `delta <= 0` branch.

Fix direction (degrade-safe): read the real state with `GetGlobalAutomationFilterType()`, keep an
ordered list, step CW/CCW via `SetGlobalAutomationFilterType(t)`, display the actual type name in
the overlay (drop the constant `"cycle"`); fall back to CW-only `Advance…` if `Set…` errors on
hardware. Optionally accumulate detents (one step per ~4) if the probe shows >3 values. Degrade:
if only Advance works, keep CW stepping but show last known type.

On-hardware verification (probe): one-shot at load or first col-6 touch: `t0=Get()`; `Advance`;
`t1=Get()`; repeat until `t` repeats ⇒ enum enumerated in the journal; then `Set(t0)` and confirm
readback, watching the MPC's automation-filter indicator.

## BUG D — "Master volume - seems to do nothing. Is this supposed to be the out 1/2 fader?"

Intent answer: **yes** — MAPPING.md :86 (col 8 "Master volume … `masterTracks[0].Volume`"),
MANUAL.md :57,:74-76, RECOMMENDATIONS.md :140 row-3 ✅ and :132-133 ("master page … the
`masterTracks[0]` surface exists **[p0]**") all mean the MPC's MAIN/master fader, i.e. Out 1/2.

Code chain: `masterTrack()` :950-959 (`mpc.tracks.masterTracks[0]`); `nudgeMasterVolume` :961-969
(read `Volume` or default 0.7, `pcall`-swallowed `.value` write); `masterVolume()` :972-974 (prop
or 0); handler col 7 :1669-1671; ring :1386-1387 `clamp01(0)` = dark; `H.gainToDb` :256-262
returns `"-inf"` at 0.

Evidence: API-CONTRACT :47 marks `masterTracks[0].Volume` **[p0]** — the hardware report
**disproves it** (nothing moves, audible or visible). The LPP3 dump is decisive:
`MPC.tracks.masterTracks` (:295, :424, :426) is a 128-slot preallocated table (`Count=userdata(0)`,
`GetCount`, `SizeMasterTracks`; same pattern as `normalTracks`' 128 slots, API-CONTRACT :38-40);
slot 0 has a full track surface but `Volume=userdata(0.0)`, `Type=userdata(Drum)`, `Name` empty,
and printing the slot yields `<cycle>` — an **unbound placeholder**, not the master track.
mock-mpc.lua:309 hardcodes `{ [0] = { Volume = prop(0.8), … } }` — the mock shares the assumption,
so passing tests are no evidence.

Failure modes and what the user sees (all consistent with the report):

| Mode | Mechanism | Visible |
|---|---|---|
| D1 `masterTracks`/`[0]` nil | :951-959 returns nil; nudge no-ops | ring dark; overlay `Master / Volume / -inf` per detent |
| D2 `[0]` unbound slot (**dump-supported**) | reads 0.0; write into dead slot ignored | identical: `-inf`, dark ring, MPC MAIN fader unmoved — **matches report** |
| D3 write silently rejected | read-only/dead property, `pcall` swallowed (:967-969) | same as D2 |
| D4 prop unreadable/renamed | `nudge` falls back to 0.7 (:966), `masterVolume`→0 (:972-974) | same as D2 |

Reachability: no proven path to the master fader exists. `tracks.SetTrackVolume` free functions are
banned (API-CONTRACT :50-51, "error in every argument form" **[dv]**); `currentTrack` exposes only
Index/Name/Type (LPP3 API-CONTRACT :83); the aperture `SetActiveMatrix("Master")` path (LPP3 script
:1485) drives the clip grid, not the fader.

Fix direction: probe first. If every path fails, degrade per repo rule: make col 7 an explicit
no-op (dark ring, overlay `Master / Volume / n/a`), delete the misleading default-0.7 write (:966),
add a "Hard walls" row to LIMITATIONS.md ("master fader not exposed by the Lua API on 3.10.1;
`masterTracks` is a 128-slot empty table, `Count=0`"), and flip API-CONTRACT :47 / RECOMMENDATIONS
:133 from [p0] to disproven. Do not silently repurpose the slot — that is a mapping-intent decision
(RECOMMENDATIONS 4.3 reserves a master page for later).

On-hardware verification (probe, journal): `SizeMasterTracks()`, `masterTracks.Count.value` /
`GetCount()`, `[0].Type/.Name/.GetVolume()/.GetVolumeDB()`; `SetVolume(0.8)` + readback while
watching MPC's MAIN fader; `tracks.SetTrackVolume` once with logging; select the Master track in
MPC's UI and log `currentTrack.*`. Any mode where the MAIN fader moves ends the investigation.

## Cross-cutting notes

- mock-mpc.lua bakes in all four disputed assumptions (percent swing :96,:175; canonical division
  strings :98,:189; 2-value filter enum :198-201; bound master slot :309) — the suite validates
  script-vs-mock agreement only, never device behaviour.
- [p0]s resolved: API-CONTRACT :47 and RECOMMENDATIONS :133 (same claim) **disproven**;
  API-CONTRACT :57 quantiser [dv] stands for existence — units now evidenced as percent (pending
  the BUG A probe).
