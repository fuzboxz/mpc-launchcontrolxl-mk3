# Oracle root-cause report — top-row dead + dark screens (LCXL3 / MPC 3.10.1)

Mandate: find THE root cause of "top row doesn't work / screens dark in both modes"
after three failed mapping attempts, protecting inherited decisions.

## 0. Executive summary

**The turn diagnostics have been silently broken on the device since they were
added — every `TURN` log is a no-op — so three "fix" cycles were deployed on
inference, not evidence. Separately, the abs (row-1) branch never paints the
LCXL3 screens, which fully explains "screen empty when I turn the top row."
The abs→Twist code path itself is CORRECT (proven in harness for both source
and minified artifact); whether it executed on the device could not be
observed because the instrumentation was blind. The raw tap's `os.time`
fallback also degenerates on the device to once-per-(ch,cc)-per-instance,
which HID a mode-report event and manufactured a false "button only sends v=1"
narrative.**

Three concrete defects (all fixable in one build) + one unknown (mode state at
burst time) that the fixed diagnostics will resolve in one user round.

## 1. The reproduction-analyzed divergence — it was a false negative

`/tmp/minif-test.lua` reported `hits: 0`. Cause: it captured logs via
`mock.logSink`, which **does not exist** in `tests/mock-mpc.lua` (the suite
captures via `_G.print` override; `H.log` calls `print`). The `logs` table
stayed empty; the RAW lines that printed came from real `print`. "hits: 0" was
meaningless.

Instrumented rerun (`/tmp/repro3.lua`, upvalues read via `debug.getupvalue`
on `handleEncoderAbs`):

```
after cc30 v=2    surfaceMode=2 qlinkRouted=false
after abs 60      lastAbs[0]=60     (baseline absorbed, by design)
after abs 62      lastAbs[0]=62
twist calls: 2    (Twist 12 +2, Twist 12 +2)   ← q13, screen order
```

`/tmp/repro4.lua` (correct `_G.print` capture, both legs):
**source and minified artifact behave identically** — abs→`qlinkPending`→
`HandleTimer` drain (script line 2479-2487)→`twistQlink` fires Twist(12, 2)
twice, RAW logs 3, screen ops 6. The minifier (line-based sed/grep, `luac -p`)
is exonerated; behavior parity verified.

**Contradiction resolved:** `tests/test-encoder-abs.lua` passes because the
code is right; the repro "failed" because its log capture was broken.

## 2. Root-cause chain (evidence per link)

### RC-1 (PROVEN): `__LCXL3_LOGTURN` cannot log — global function, local `H`
- `script/LaunchControlXL3.lua:100-106`: `function __LCXL3_LOGTURN(msg)` is a
  GLOBAL; it guards on `type(H) == "table"`. `H` is declared `local H = {}`
  (line 209). A global function sees only `_G.H` — **nil** in the harness AND
  on the device (the MPC host defines no global H; it also has no `os` — see
  the earlier `lua call failed ... global 'os'` crash).
- Effect: every TURN line (rel entry :2061, abs entry :2117, twist tail :1362)
  is a silent no-op **everywhere**. Zero TURN lines in every device capture
  was interpreted as "the path doesn't run"; actually "the logger can't log."
- The test suite never caught it because no test asserts diagnostic emission.

### RC-2 (PROVEN): abs branch paints nothing — "screen is empty/dark"
- REL path (`handleControlEncoder`, ~:2096) queues the twist THEN calls
  `showControl(encoderTarget(row, col), "Q-Link " .. (i+1), ...)`.
- ABS path (`handleEncoderAbs`, :2113-2120) queues the twist and `return`s —
  **no `showControl`**. Row 1 speaks abs only (device wire tap: CC 13-20
  ch 15), so every row-1 turn leaves both LCXL3 screens dark. This is exactly
  the user's report: "when I turn the top row the screen on the lcxlmk3 is
  empty."

### RC-3 (PROVEN): raw tap's `os.time` fallback hides mode events on device
- Tap (:2364-2381): non-encoder events log 1/sec per (ch,cc) using
  `(type(os)=="table" ...) and os.time() or 0`. On the device `os` is absent →
  `now` is always 0 → the once-per-key condition fires exactly ONCE per
  (ch,cc) per script instance.
- Device journal: `RAW ch=6 cc=30 v=1` appears, but a LATER `surface mode
  report 2` line (from `onModeReport`, :1918) appears with NO matching RAW
  line — the v=2 event was throttled away. This manufactured the parent's
  false lead "the real button sends v=1 (not 2)!"
- Truth: cc=30 v=1 at boot is the DEVICE's reply to the script's own
  `requestSurfaceMode(MODE_MIXER)` (OnLoad :2638, `sendCC(CH_FEATURE,
  FEAT.mode, MODE_MIXER)`; reply logged by onModeReport). v=2 later = real
  CONTROL entry. The mode-entry semantics are NOT buggy.

### RC-4 (UNKNOWN — the one thing left to measure): `surfaceMode` at burst time
- Mode is CONTROL only between a `surface mode report 2` and any later
  `report 1`. The journal proves CONTROL was entered (`qlinks:` inventory +
  `control row 3 page 1`, which is control-gated at :2192-2200), but the
  CC-13 burst's position relative to mode lines was never captured in one
  interleaved view.
- The script RELOADS 2-4× per 15 min (journal `loaded` repeats; cause unknown
  — likely USB rebinds). Every reload: OnLoad re-requests MIXER (report 1),
  wipes `lastAbs` and reverts surfaceMode. If a reload or mode flap occurred
  between control entry and the knob turns, row-1 abs events fall to
  `handleMixerEncoder` (or get absorbed as fresh baselines) — "nothing works,
  screen dark" with zero errors. **This is the leading candidate for the
  user-visible failure and it is unobservable until RC-1/RC-3 are fixed.**

### Non-causes (adjudicated)
- Minifier: exonerated (repro4 parity).
- `qlinkRouted`: false everywhere (native routing disabled; logged).
- `accelDelta`: sound (:2-8 multipliers).
- Timer: provably runs on device (`playhead raw=0` is a `logOnce` from
  HandleTimer context).
- QLINK_ORDER / dot-form Twist driver: inherited decisions untouched — the
  harness run confirms the order table routes row-1-col-1 → index 12 exactly
  as designed.

## 3. Exact minimal fix (diff-ready)

### Fix A — make the turn logger work (kills RC-1; zero new locals — the chunk
is at the 200-local limit). In the H utilities block (after `H.logOnce`,
~:217):

```lua
function H.logTurn(msg)          -- was global __LCXL3_LOGTURN (blind: no H in scope)
	if __LCXL3_TURNS < 300 and type(H.log) == "function" then
		__LCXL3_TURNS = __LCXL3_TURNS + 1
		H.log("TURN " .. msg)
	end
end
```

Delete the global `function __LCXL3_LOGTURN` block (:99-106). Replace the
four call sites `__LCXL3_LOGTURN(` → `H.logTurn(` (:1362, :2061, :2117, and
the abs one). Keep `__LCXL3_TURNS` global (counter survives, harmless).

### Fix B — abs branch paints the screen (kills RC-2). In `handleEncoderAbs`,
control-mode row<2 branch, after the `qlinkPending[#qlinkPending+1]` line
(:2120), before `return`:

```lua
		showControl(encoderTarget(row, col), "Q-Link " .. (qi + 1),
			qlinkTargetName(qi) or "Unassigned", qlinkValueString(qi))
```

(Mirrors the rel path :2096-2097. Row-1 turns now light the LCXL3 screens
with the Q-Link label/value — instant user-visible feedback.)

### Fix C — stop hiding mode reports (kills RC-3). In the raw tap, extend the
unthrottled class:

```lua
		local encoderEvent = (channel == 14 or channel == 15) and cc >= 13 and cc <= 100
			or (channel == CH_FEATURE and cc == FEAT.mode)
```

(Mode flaps are precisely what the verification round must see interleaved
with turns. `CH_FEATURE`/`FEAT` are in scope of `HandleMIDICC`.)

### Fix D (optional, recommended) — reload-storm resilience for baselines:
in `setSurfaceMode`, when entering MODE_CONTROL, clear `lastAbs` (fresh
baselines; first detent after a mode change absorbs — already the post-reload
behavior, now also after deliberate re-entry). One line, no semantics change.

Do NOT touch: QLINK_ORDER, twistQlink, cc=30 semantics, the minifier.

## 4. Verification

Existing tests that prove the path: `tests/test-encoder-abs.lua` (Twist from
abs in control mode), `tests/test-qlink-twist.lua` (driver), full gate
`sh tests/run-tests.sh` with exit-code discipline (a `| tail` pipe once
masked a failure — keep gating on `$?`).

New tests to add (describe-only):
1. **Diagnostic-emission regression**: override `_G.print`, run the repro4
   flow, assert ≥1 line matching `"TURN abs row=1"` and ≥1 matching
   `"TURN done q13"` — would have caught RC-1 the day it shipped.
2. **Abs paints the screen**: after a row-1 abs turn in control mode,
   `mock.screen()` contains a text op for `encoderTarget(0,0)` with "Q-Link 13".

**One decisive device round** (user): deploy the fixed build; press DAW
Control; slowly turn top-left 3-4 detents, then a row-2 knob. Read the
interleaved journal:
- `TURN abs row=1 ... -> q13 '<name>'` + `TURN done q13 pos X->Y` appear,
  LCXL3 screen shows "Q-Link 13 ..." → path confirmed live; remaining
  complaints are slot-content (utility page vs assignments), not routing.
- RAW cc13 stream but NO `TURN abs`, plus a nearby `surface mode report 1`
  → mode-flap confirmed (RC-4); fix = re-press DAW Control after reloads
  (and hunt the reload cause: `journalctl -k | grep -i usb`).
- `TURN done` shows `pos X->X` (no movement) → twistQlink device regression
  (would contradict the A/B probe; escalate).

## 5. Residual risks
- The reload storm's cause is unknown (USB rebinds suspected); until fixed,
  every reload silently reverts mode+baselines mid-session.
- Q-Link slot content is MPC-mode-dependent and assignments proved volatile
  across restarts ('TRACK LEVEL' default page returned); "bottom rows only
  work in track mode" is consistent with slot content, not a script bug —
  defer to the probe session with working diagnostics.
- Row-3 Global page semantics (tempo/swing/master) remain open inherited
  questions; out of scope here.
