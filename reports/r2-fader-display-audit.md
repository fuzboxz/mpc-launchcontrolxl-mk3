# R2 — Audit of reports/w2-fader-display.md

## Verdict: ACCEPT-WITH-CORRECTIONS (overall)

### Per report section
- **Symptom**: ACCEPT. Quoted verbatim; scope (display-only, MPC correct) matches code split below.
- **Root cause 1 (cache-at-queue + FIFO backlog)**: ACCEPT. Code-confirmed (see anchors).
  handleFader writes `tr.Volume` (:1597) then enqueues text from the SAME incoming value (:1598);
  fields 0/1 of `showControl` are cache-suppressed after the first CC, so only field-2 closures
  pile up — "N stale closures for the same key" is exact. Pump 6/tick FIFO, no trim.
- **Root cause 2 (device-side drop of newest text → permanent desync)**: ACCEPT-WITH-CORRECTIONS.
  Mechanism is coherent and honestly conditioned, but (i) "PERMANENT"/"forever" overstates:
  any text-changing state move re-queues field 2 — bank remap (:1500/:1502 different track),
  external automation via the Volume listener → markDirty → paintTrackScreens (:1153-1189),
  a 1-CC nudge, track add/remove ("-" path :1502). True claim: no TIME-based self-heal exists
  (cache only cleared at init :2200; ticks%10==5 refresh re-computes the identical string) —
  matches "does not recover on its own". (ii) "Ableton keeps only the LATEST text per
  target:field" is NOT in the doc (see errors). The suppression half (state paths compute the
  same string, die at :497) is verified: all fader field-2 texts derive from tr.Volume read-back
  (:1500, :1765, :2060) == the motion text, so equality — and hence suppression — holds
  (%.1f dB swallows float32 noise; gainToDb :256).
- **Candidate verdicts (a)-(e)**: ACCEPT. Each elimination follows from the code:
  (b) read-back text would differ → queued → heals ≤500 ms; (d) displayTimeout=20 = 2.0 s
  (:652; LAYOUT §7 :142 0.1 s units), reverts to stationary page, cannot hold a wrong value;
  bit 6/5 set via CFG_THREELINE=98 (:2218-2221; LAYOUT §6 :123) so "stale text re-triggers the
  temp page" is consistent. (e) touch repaints actual Volume, suppressed at gesture end — sound.
- **Evidence chain**: ACCEPT-WITH-CORRECTIONS (one citation slip, below). Mock-gap verified:
  mock `prop:set` fires listeners (tests/mock-mpc.lua:37-52) while the script writes `.value`
  directly (:671) — suite blind to script-driven state flow; mock wire is lossless (every sysex
  recorded/rendered, mock-mpc.lua:432-434) so mock agreement ≠ device evidence. test-faders.lua
  asserts only name/param/dB PRESENCE (:83-98) — no pacing/final-value assertion; blind to both
  defects, as claimed. Note: I did not execute tests (no shell); "baseline PASS" is unverified
  by me, though irrelevant given suite blindness.
- **Fix direction**: ACCEPT-WITH-CORRECTIONS — see "Fix-pair scrutiny".
- **On-hardware steps**: ACCEPT. Probe 1 (touch → no change; nudge → renders) is decisive and
  consistent with :497; step 2 correctly deferred to a dev build.

### Verified anchors (all confirmed)
- scrText :494; early-return :497; cache commit at ENQUEUE :500; closure :501-503.
- pumpScreen :506-513, budget 6, FIFO `table.remove(...,1)`; no queue trim anywhere.
- showOverlay :525-547; front-insert `table.insert(screenQueue,1,...)` :546; keys 54:* only.
- handleFader :1577-1599 (setTrackValue :1597, showControl-from-CC :1598); setTrackValue
  :665-677 (raw `.value` write :671); gainToDb :256; handleTouch :1756 (fader showControl :1765);
  paintTrackScreens :1496-1504 (:1500, "-","-" :1502); refreshLastTouched :2052 (:2060).
- Tick order: pumpScreen :2088 → paintAll :2091 → refreshLastTouched/paintStatic at
  ticks%10==5 (500 ms) :2094-2097; timer `Start(50)` :2245 → 120 sysex/s math valid.
- Docs: LAYOUT §6 :128-130 (Ableton >10 queued → dedupe by first 9 bytes, 10 ms spacing) and
  §7 :142 (CC 113) — as quoted; §6 wire format confirms first-9-bytes == target:field key.
  API-CONTRACT :32-33 SendMIDISysex acceptance **[p0]** — as quoted. LIMITATIONS :26
  "paced at 6 per 50 ms". RECOMMENDATIONS §7.2 :216-219 budget/120 msg/s; :224-225 drop-order
  quote ("overlay first, then per-control, then stationary").

### Errors / weak claims
1. P2 — "suppressed at :497 forever"/"PERMANENT": overstated (see Root-cause-2 correction).
   Say "no self-heal; persists until a text-changing state move".
2. P2 — "Ableton keeps only the LATEST text per target:field": unsupported. LAYOUT §6 says
   only "dedupe by the first 9 bytes"; survivor unspecified; references/ contains no Ableton
   dump (grep: no matches). Must be marked inference. Rest of mechanism 2 IS properly labeled
   (conditional "if the display firmware drops text…", medium-high, wire probe required).
3. P2 — citation slip: the drop-order quote is RECOMMENDATIONS.md:224-225 (§7.2 block), not
   §11; §11 (:293-325) only says "drop-order defined". Also PATTERNS.md:71 states the REVERSE
   order ("per-control first, the overlay second") — docs-internal contradiction the report
   silently resolves by quoting the friendlier one.
4. P1 (fix design) — the key→queueIndex "replace in place" sketch is unsafe as written:
   showOverlay front-inserts (:546) and pumpScreen removes from the front (:509), so positional
   indices shift/stale. A stale index can overwrite a FOREIGN slot — worst case displacing an
   overlay text/trigger closure, which re-creates the documented "overlay shows previous
   contents" failure, i.e. violates "degrade, never break" — or miss the key's real closure
   (duplicate + stale text both sent). Fix guidance: tag closures with key and scan the pending
   queue (bounded, small) or keep per-key node references; do not cache positional indices.

### Fix-pair scrutiny (asked explicitly)
- Does commit-at-send reintroduce duplicate sends for identical queued text? YES — without
  fix 1. Cache no longer suppresses pre-send, so refreshLastTouched (500 ms), handleTouch and
  paintAll re-enqueue the same string during a backlog window; each becomes a send after the
  first commits the cache. With fix 1's per-key dedupe the duplicates collapse; the pair is
  coherent, but the report should state that (2) is only safe WITH (1). Minor residual:
  showOverlay keeps its own enqueue-time cache (:530-531) and would not get fix 2's benefit —
  same drop-bug class remains for overlay text; one line needed.
- Does in-place replacement break showOverlay's front-insertion ordering? Overlay ordering
  itself is untouched (overlay uses pushText, not scrText), but the index-map implementation
  hazard (error 4) can corrupt OTHER slots including overlay closures. With key-tagged scanning
  replacement, ordering is preserved and safe.
- Fixes 1+2+3 do NOT close the desync class: with cache committed at send, a device-side drop
  of a single sysex still leaves cache==text==device-stale and every path suppressed at :497;
  the report's optional "force-queue while a closure is pending" never triggers post-drop
  (nothing pending). Missed fix: post-burst single re-assert — flag any key sent in a
  multi-message tick and re-queue its text once on the next empty-queue/refresh tick (≤1 sysex
  per suspect key per 500 ms). That, not 1+2 alone, removes permanence.

### Additional observations the worker missed
- A track rename changes field 0 only; fields are independent on the wire, so renames do NOT
  heal a desynced field 2 — reinforces mechanism 2 and narrows the recovery paths to value-
  changing ones (bank remap, external change, 1-CC nudge). Worth one sentence.
- Text-equality between motion and read-back assumes tr.Volume stores the exact written float.
  Plausible (and %.1f makes sub-0.1 dB drift invisible), but unproven on hardware; if the API
  quantizes coarser than 0.1 dB, verdict (b) fires instead and the bug self-heals — the report's
  probe 1 already covers this fork. No change needed; state the assumption.

### Commands for supervisor
- `sh tests/run-tests.sh` (baseline green check; report claims test-faders/test-screen pass —
  not independently executed here).

### Merge verdict (audit of the report, not code): OK with the four corrections above;
no factual anchor failed verification.
