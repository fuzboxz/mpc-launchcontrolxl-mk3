# W2 — Fader displays desync after fast movement (MPC state correct)

Read-only analysis; no code changed.

## Symptom (verbatim)

> "FADERS: Work, but display (on the LCXL) goes out of sync and shows the wrong value
> if you move the fader quickly. The actual volume on the MPC is correct though."

MPC Volume right; the XL3 per-fader OLED page stale/wrong after a FAST move and (per
the report) it does not recover on its own.

## Root cause (exact mechanism)

Two cooperating screen-path defects:

1. **Cache committed at QUEUE time + FIFO backlog → correction suppression and delayed
   playback (`LaunchControlXL3.lua:494-504`).** `scrText` writes
   `screenSent["<target>:<field>"]` when it *enqueues* (line 500), not when the sysex is
   pumped. `handleFader` (`:1577-1599`) enqueues one value text per incoming CC
   (`:1598`, text = `H.gainToDb(value/127)`, `:256`); a fast sweep delivers many CCs
   between 50 ms ticks, so N stale closures pile up for the same key (`5:2`…) while
   `screenSent` already holds the newest text. The pump drains FIFO at 6 per tick
   (`:506-513`) = 120 sysex/s max:
   - the device *plays back* the gesture late: every stale closure is still sent, so
     after release the OLED keeps stepping through mid-sweep dB values for
     `backlog/120 s` (mock trace: 128-CC sweep → wire showed "0.6 dB" one tick after
     the gesture with actual "6.0 dB"; converged ~7 ticks later);
   - every state-derived repaint (`paintTrackScreens :1496-1503`, `handleTouch :1765`,
     `refreshLastTouched :2052-2064`) recomputes the CORRECT text from `tr.Volume`,
     hits `screenSent[key] == text` at `:497` and returns **without queueing anything**
     — corrections swallowed while stale closures for the same key still sit in queue.
2. **Newest text can be lost on the wire while the cache claims delivery → permanent
   desync.** Pure script logic always converges (FIFO ends on the last-enqueued text;
   mock repro converges). The reported persistence therefore requires the newest text
   of the burst not to render — exactly the flood Ableton paces against: LCXL3-LAYOUT
   §6 documents Ableton "when >10 sysex are queued, dedupe by the first 9 bytes and
   space the survivors 10 ms apart"; bytes 1-9 are `…06 <target> <field>` — Ableton
   keeps only the LATEST text per target:field and spaces sends. The script neither
   dedupes per key inside the queue nor spaces the 6 sysex it emits back-to-back in one
   tick. If the display firmware drops text under such a burst, the final
   "6.0 dB" never renders while `screenSent["5:2"]` already says `"6.0 dB"`, so
   `refreshLastTouched` (500 ms), `handleTouch` and `paintTrackScreens` all compute the
   same string and are suppressed at `:497` forever. **Key/text collision**: device
   shows a mid-sweep value, cache holds the final value, nothing is ever re-queued.

MPC state stays correct because `handleFader` writes gain first (`setTrackValue
:665-677`, `tr.Volume.value = value/127` at `:671`) and only then paints; the display
pipe is the only divergence — matching the report.

## Evidence chain

- `script/LaunchControlXL3.lua:494-504` cache-at-queue-time; `:506-513` FIFO pump
  budget 6; `:1597-1598` motion text from the INCOMING CC; `:1500/:1765/:2060`
  state-derived texts hitting the `:497` suppression; `:2088-2095` tick order (pump
  before repaintDirty/refresh — corrections land at the queue tail, behind stale
  closures); `:525-547` showOverlay front-inserts only `54:*`, cannot reorder `5:2`;
  no queue trim exists (only `table.remove(screenQueue,1)`).
- docs/LCXL3-LAYOUT.md §6 (Ableton dedupe-by-first-9-bytes + 10 ms spacing when >10
  queued), §7 (CC 113 temporary-display timeout); docs/LIMITATIONS.md "Sysex-per-field
  text … paced at 6 per 50 ms"; docs/RECOMMENDATIONS.md §7.2 budget, §11 "if the device
  ever falls behind … drop the overlay first, then per-control values" (anticipated,
  never implemented).
- docs/API-CONTRACT.md §1: `SendMIDISysex` acceptance is itself **[p0]**;
  ordered/lossless rendering of back-to-back display sysex is an unproven assumption
  this report disproves at the flood point (persistence on fw 1.1.11). Mock gap:
  tests/mock-mpc.lua renders EVERY text sysex and fires listeners only via `prop:set`,
  while the script writes `.value` directly (`:671`); the suite sees neither the
  backlog playback nor a dropped send ("tests pass" is not evidence; baseline
  test-faders/test-screen PASS).
- Mock repro (/tmp/repro-fader.lua, repro2, repro3): 40-CC gesture in one interval →
  1 tick later the wire shows "1.0 dB" vs actual "6.0 dB"; 128-CC sweep → 40 same-key
  texts over 7 ticks. Script-logic convergence holds, so mechanism 1 alone cannot
  explain permanence; mechanism 2 is required.

### Candidate verdicts

- (a) motion-text vs listener/refresh-text race: both compute the same number
  (`:1598` writes `value/127`, text uses the same value; `:1500` reads it back) — no
  permanent divergence; real only as FIFO lag. Partly confirmed.
- (b) quantization/taper: disproved as persistent — the read-back text differs from
  cache, so `paintTrackScreens`/`refreshLastTouched` queue it; self-heals ≤500 ms
  (repro3 converged to the stored-gain text "4.9 dB").
- (c) pump drops the final text: split. The pump never drops; the cache IS superseded
  by later `scrText` while old closures wait — but FIFO sends newest last, so
  script-side it converges. "Older text, nothing queued" exists only via device-side
  loss of the final sysex, which the cache makes uncorrectable.
- (d) displayTimeout=20 (2 s, `:652`, §7): cannot leave a wrong value — it reverts to
  the stationary page; it only prolongs visibility (each stale text re-triggers the
  temporary page, config bit 6, §6). Not the cause.
- (e) touch mid-gesture (`:1756-1766`): repaints from ACTUAL Volume (correct text) but
  lands behind stale closures and is cache-suppressed at gesture end. Harmless; also
  the decisive probe (below).

## Fix direction (minimal, "degrade, never break")

1. **Dedupe the queue per key, keeping the newest** (Ableton's rule): in `scrText`, if
   a pending closure for `key` exists, replace it in place (a `key → queueIndex` map,
   overwrite the captured text). Removes the stale playback; a gesture costs ≤3 texts.
2. **Commit the cache at SEND time** (`pumpScreen` sets `screenSent[key] = text` as the
   closure goes out), so a replaced/dropped message can be re-queued by the state paths.
3. **Space display sysex** (~10 ms, or ≤1-2 text sysex per 50 ms tick — Ableton's
   documented pacing) if the budget stays 6/tick; optionally `refreshLastTouched`
   force-queues its text while a closure for that key is still pending. All behind
   existing pcall/type guards; no new API surface.

1+2 are the minimal pair: without (2), replacing queued closures reopens a "cache says
sent, device never rendered" window; without (1), the flood persists.

## Confidence

- Mechanism 1 (cache-at-queue-time suppression + FIFO lag/playback): **high** —
  reproducible in the mock; line-exact code paths.
- Mechanism 2 (device drops newest text under burst → permanent stale + cache block):
  **medium-high** — the only read consistent with "stays wrong" + "MPC correct";
  supported by the Ableton pacing fact, needs the wire probe below.

## On-hardware verification steps

1. **Cache-block proof (no code change):** make one fader display stale (fast sweep),
   wait >2 s — it will NOT self-correct per the analysis — then **touch (not move)**
   that fader. `handleTouch :1765` recomputes the correct text; if the OLED does not
   change, `screenSent[key] == text` while the device shows stale: cache proven to
   block the correction. Then nudge 1 CC step: a new distinct text must render,
   proving the pipe works outside bursts.
2. **Burst capture:** probe mode logs incoming only; temporarily journal each
   `SendMIDISysex` op-06 payload in a dev build (repo is read-only today). Sweep fast,
   compare the last journaled text for the target vs the OLED: correct final text on
   the wire but a stale OLED = device-side drop proven.
3. **Post-fix A/B:** same sweep; expect ≤3 texts per control per gesture, no mid-sweep
   values after release, 2 s temporary-page reversion intact.
4. Regression: `tests/run-tests.sh` green; a new mock assertion — 40 CCs between two
   `HandleTimer` calls emit exactly one op-06 per changed `target:field`, carrying the
   final value — would have caught this (out of scope, read-only).
