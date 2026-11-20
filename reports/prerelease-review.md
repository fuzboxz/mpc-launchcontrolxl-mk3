All verification is complete. I have no write-capable tool, so per protocol I'm returning the complete artifact below for persistence to `reports/prerelease-review.md`.

---

# Pre-Release Review — mpc-launchcontrolxl-mk3

**Scope:** squash-commit + push + merge + release of the working tree (17 modified tracked files + untracked session reports/tests). Review-only; no code was edited.
**Test evidence (supervisor-executed on this working tree, recorded):** `sh tests/run-tests.sh` → **exit 0**, final line `ALL TESTS PASS` (log: `/tmp/prerelease-t.log`; includes `luac5.4 -p`, check-ini gate, `gen-manual --check`, all `tests/test-*.lua`, and the minified-artifact leg). `luac5.4 -p script/LaunchControlXL3.lua` → **exit 0**.

## Verdict per area

| Area | Verdict |
|---|---|
| 1. Runtime safety on device host | **CLEAN** (P2 hardening notes) |
| 2. State-machine hazards | **MAJOR** (2× P1 stale-state-on-OnLoad; no crash paths) |
| 3. Lua 200-local limit | **MAJOR** (recommendation; compiles green, headroom ≈ 0) |
| 4. Loader gates | **CLEAN** |
| 5. Test suite health | **CLEAN** (exit 0 recorded) |
| 6. Docs consistency | **MINOR** (3 stale lines + changelog self-contradiction + dangling report refs) |
| 7. Release hygiene | **MINOR** (untracked scratch must stay out of the squash) |

## Review

### Correct (verified, with evidence)

- **No uncaught-error path in the new code.** Every new MPC API touch is call-guarded: `twistQlink` fast path (`H.call(q.Twist, d)`, script/LaunchControlXL3.lua:1370), `settleQlink` (`H.call(H.callable(q,"GetPosition"))` :1353), `drainQlinkPending` (pure Lua + twistQlink, :1416), `clearNativeQLinkBindings` (early-out when API missing :1447-1449, inner calls pcalled :1456), `doOverdub`/`doRecord` guards (all `H.call`/`H.callable`, :879-912), swing shadow (`setSwing` clamped + guarded, :1025-1028), automation-filter enumeration (bounded 12, all `H.call`, restore-on-no-repeat, :1088-1119). `pcall(q.Touch)` with a nil member degrades (pcall of a non-callable returns false); a nil `q.Twist` is no-op'd by `H.call`'s type check.
- **No `os.*` / `io.*` / `require` in the script** (grep-verified) — the os.time failure class cannot recur.
- **Lua 5.4 host is documented** (docs/API-CONTRACT.md:18) so the `knob // 8` integer division in `settleQlink` (:1354) is safe on-device, and `luac5.4 -p` exit 0 confirms parseability.
- **No double-application of twists:** the immediate drain empties `qlinkPending` before twisting (:1419-1421); `HandleTimer` drains *before* the QDIRTY settle sweep (:2560-2567), and settle only writes back the position it just read (no parameter write). test-qlink-latency proves exactly-one Twist per detent and one settle after quiet.
- **`setSurfaceMode` unconditional `lastAbs = {}`** (:1990) is correct and tested (test-global-fixes #4: control-mode baseline never jumps a mixer send).
- **OnLoad query-only change is correct:** no forced mixer request; ch-8 query at :2645, re-ask at :2588, adoption via `onModeReport`; asserted by test-load.lua:62.
- **Screen re-assert retry bound:** `__LCXL3_SCRETRIES[key] < 2` gate (:575-579), forced records never re-arm (:613-616); test-global-fixes #5 proves ≤4 sends/key/burst.
- **Swing shadow stepping with per-detent clamp** (:2084-2089) — tested against the stale-GetSwing device behavior (test-global-fixes #1).
- **Loader gates green:** `script/LaunchControlXL3.ini.in:6` `scriptVersion=1.0` exactly; tools/check-ini.sh allows only `1.0` and refuses PLACEHOLDER checksums in artifact mode; script/build.sh:13 hard-requires `MPC_BIN` with a pointer to CONTRIBUTING.md:39-42 (also documents `MPC_SALT`); the suite runs check-ini (template) and gen-manual --check before the tests.
- **Minified-artifact parity:** tools/minify-lua.sh is comment/whitespace-only (no semantic change; no long strings per its safety note), and run-tests.sh:31-40 runs the entire suite against the artifact.
- **Suite gating is real:** `set -eu`; every test asserts via `error()` and prints PASS; no TODO/skip/pending assertions (grep-verified — only comments mention them).
- **Globals are collision-safe:** only `__LCXL3_SCRETRIES` (:189), `__LCXL3_SWING` (:1023), `__LCXL3_IMMEDIATE`/`__LCXL3_QDIRTY` (:1336-1337) plus `LaunchControlXL3.ACTIONS/.PALETTE/.SURFACE_CC` fields on the host-provided device table; all other top-level assignments target forward-declared locals (:167-170).
- **Hygiene:** no secrets/credentials/tokens in tracked files (grep-verified; the `/home/fuzboxz` paths exist only in *untracked* reports/workflow-*.js scratch); `.gitignore` correctly ignores `build/`, `*.zip`, `*.ini` (template excepted), `references/*`; no build artifacts tracked.

### Findings

**P1-1 — Stale swing shadow survives OnLoad re-entry → parameter jump.**
`__LCXL3_SWING` is initialized only at chunk load (:1023) and is absent from the OnLoad reset block (:2596-2723). The script's own reset discipline (OnLoad resets `ticks=0` :2607, `lastPressTick` "pre-reload" handling :981-991) proves OnLoad re-entry without chunk re-execution is expected. After a reload into a project whose real swing differs, the first swing detent applies `SetSwing(stale + delta)` (:2085-2088) — e.g. real 50% → jumps to ~72%. Unwanted parameter write on hardware; violates DEGRADE, NEVER BREAK in spirit. **Smallest fix:** add `__LCXL3_SWING = nil` to the OnLoad reset block.

**P1-2 — Stale acceleration streak survives OnLoad (`ticks` reset defeats the staleness gate).**
`qlinkAccel` (:1290) is not reset in OnLoad. `accelDelta`'s staleness gate `(ticks - a.tick) > 4` (:1295) sees a *negative* diff after the tick reset and treats the pre-reload entry as fresh, so a pre-reload streak (up to 32, ×8 multiplier) is continued on the first post-reload detent — an 8-step parameter jump on the first turn after reload/acvs restart. **Smallest fix:** `qlinkAccel = {}` in OnLoad (or also treat `a.tick > ticks` as stale in accelDelta).

**P2-1 — `qlinkPending` not reset in OnLoad.** With `__LCXL3_IMMEDIATE=false`, detents queued in the last ≤50 ms before unload are drained into the *new* session's Q-Links at the first timer tick (:1317, drained at :2560). Fix: one reset line. (Task-flagged: leftovers when IMMEDIATE=false — confirmed.)

**P2-2 — `__LCXL3_QDIRTY` stale entries never settle after the tick reset** (`(ticks - act) >= 2` is negative forever for pre-reload entries; bounded by qlink count, cleared on that qlink's next fast twist) (:1337, :2562-2566). Fix: reset in OnLoad. Cosmetic.

**P2-3 — Eager-index hardening in the new hot paths.** `pcall(q.Touch)` (:1362 fast, :1356/:1413 slow) and `H.call(q.Twist, d)` (:1370) / `H.call(q.SetPosition, pos)` (:1356) index `q` *outside* the guard; the script's own H.safeIndex doc (:276-277) says sol2 userdata can throw on missing members. Today's members are device-proven and nil-degrades cleanly, but a throwing index would be uncaught in HandleMIDICC/HandleTimer. Smallest fix: `H.call(H.callable(q, "Touch"))` / `H.call(H.callable(q, "Twist"), d)` in the fast path and settleQlink.

**P2-4 — Automation-filter restore failure is silent.** `enumerateAutomationFilterTypes` ends with `H.call(set, t0)` (:1117); if the restore errors, the user's filter type is left advanced with no journal line. Fix: log-once on restore failure.

**P2-5 — Sweep log may miscount.** `clearNativeQLinkBindings` counts a removal only if the call returns truthy (:1453-1459); if the device returns nil on success the "removed" line under-reports. Cosmetic; path is dormant (`QLINK_NATIVE_ROUTING = false`).

**P2-6 — Five dead top-level locals burn scarce cap slots:** `screenDirty` (:620), `requestSurfaceMode` (:773, orphaned by this session's OnLoad change), `touchQlink` (:1271), `qlinkValueSnapshot` (:1277), `TWIST_FORMS` (:1320 — never iterated; the driver went dot-form-direct). Also `blinkOn` (:182) is write-only. Deleting frees 5 of ~200 slots.

**P2-7 — Mock gaps (test-infra only):** mock-mpc.lua never emulates sol2 missing-member *throws* (plain tables return nil), so P2-3's class is untestable in CI; `clipMatrix.StopAllClips` references an undefined `sceneStates` (mock-mpc.lua:335, :339) — `record()` lands first so call-counts still pass, but the call aborts mid-function (swallowed by `H.call`) and `M.sceneStates` is nil.

**P2-8 — CHANGELOG self-contradiction.** The "Q-Links (fw 1.1.11 resolution)" bullet says twists are *deferred to the timer context*; the shipped behavior is *immediate* (the later "Knob latency overhaul" bullet is right, `__LCXL3_IMMEDIATE` defaults true, :1336). Amend the older bullet so release notes don't contradict the code.

**P2-9 — docs/INSTALL.md §7 stale.** "The script selects DAW Mixer mode (surface mode 1) on load, like Ableton does" contradicts the new query-only OnLoad (script comment :2629-2639; test-load asserts the query). One-sentence fix.

**P2-10 — docs/MAPPING.md quantize-division list stale.** Row-3 global table lists 6 divisions; `TIME_DIVISIONS` now has 8 (adds 1/4T, 1/32T; script:994, exercised by test-global-fixes #2).

**P2-11 — Committed docs reference untracked reports.** CHANGELOG/MAPPING/LIMITATIONS/API-CONTRACT all cite `reports/00-FINAL-TRIAGE.md` and CHANGELOG cites `reports/oracle-rootcause.md`; both are untracked. After squash+push those links dangle for any clone. Decide: commit those two reports or strip the references before release.

**Lua-cap note (per supervisor instruction):** `luac5.4 -p` passes (exit 0, recorded). Static inventory: 197 top-level `local` statements ≈ 199 named main-chunk locals (verified three ways: full grep walk, sequential file walk, 115 `local function` + 82 others + 2 extra names on :168), i.e. the chunk sits effectively *at* the 200-local ceiling with ~zero headroom — the session hit the cap four times today and mitigated via `__LCXL3_*` globals and the `buildSurfaceCC` wrapper (:2626). **MAJOR (non-blocking) recommendation:** document the 200-local ceiling and the globals/wrapper mitigation pattern in CONTRIBUTING.md/release notes so the next contributor doesn't discover it as a red suite. P2-6 recovers 5 slots immediately.

**Hygiene note:** the untracked scratch (reports/w*.md, r*.md, workflow-*.js, 9 new test files, oracle/q-order reports) must be deliberately chosen in the squash commit — do not blanket-add. The salt-extraction recipe in docs/INSTALL.md:35 (offset + XOR key) is pre-existing committed history, not introduced by this diff — flagging for the release owner's awareness only.

### Merge verdict

**GO with notes.** No P0: no uncaught-error path was found in any new code reachable from `HandleMIDICC`/`HandleTimer`/`OnLoad`; the suite, the loader gate, the manual-freshness check, and the minified-artifact leg are all green with recorded exit code 0. Strongly recommended before the squash (both are one-line OnLoad resets): **P1-1** (`__LCXL3_SWING = nil`) and **P1-2** (`qlinkAccel = {}`) — they are the only findings that write unwanted parameter movement on real hardware. P2 items are optional hardening/doc fixes; P2-8/9/10 (docs) are cheap enough to fold into the same commit.

---
*Note: no write-capable tool was available in this session, so the above artifact is returned complete for persistence to `reports/prerelease-review.md`. No code was modified; no `progress.md` was written (review-only).*