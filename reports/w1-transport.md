# W1 — Transport findings (XL3 fw 1.1.11 on MPC Live III, MPC 3.10.1)

Evidence basis: hardware observations are Phase-0 ground truth; script lines against
`script/LaunchControlXL3.lua` @ 98d9421. Timer tick = 50 ms (docs/RECOMMENDATIONS.md:297),
so the double-press window `d > 7` is 350 ms. Confirmed working, no action: Play / Shift+Play
(`BP[BTN.play]` 1868–1881 → `doPlay` 734–751; shift branch `isPlaying()` → `doStop` 753–756
else `doStopAll`), plain Record arm (`doRecord` 762–772), and the Shift+Record overdub toggle
itself (`doOverdub` 774–780 → `sequencer.Overdub()`, confirming API-CONTRACT.md §3 **[dv]**).

## BUG A — Shift+Record intermittently stops playback

**Symptom (verbatim):** "Shift + Record - turns overdub on/off, sometimes stops playback".
Overdub toggling is correct; the intermittent STOP is the defect.

**Root cause (exact mechanism):** the CC 118 double-press detector is keyed by CC only and its
branch runs **before** the shift branch, so the second press of a quick Shift+Record pair is
misread as a plain-Record double-press whose "revert the accidental arm" logic fires against
a record state actually raised by **overdub**.

1. Press 1 (Shift held): `isDoublePress(BTN.record)` (848–857) → false; captures
   `pressState[118] = { rec = recordActive(), play = isPlaying() }` (853) BEFORE the branch
   side effects run (1894–1898) — capture timing is correct. `shiftHeld` → `doOverdub()`
   (1895 → 774–780) → `sequencer.Overdub()`.
2. Hardware fact (Phase-0): overdub ON raises the sequencer's record state, so
   `recordActive()` (758–760) now returns true although Record was never armed.
3. Press 2 within 350 ms (`d > 7` gate, 852): `isDoublePress` → true; the double-press branch
   at 1884–1893 precedes `if shiftHeld` at 1894, so Shift is ignored. `st ~= nil and not
   st.rec and recordActive()` (1887) is true → `sequencer.RecordOff()` (1888) + `doTap()` (1891).
4. On MPC 3.10.1, `RecordOff` issued while merely overdubbing ends the record-state transport
   → **playback stops** (observed). The script's wrong assumption is `recordActive() ⇔ "armed
   via Record"` (the prop is `RecordState` OR `IsRecording`; which flips during overdub-only
   is unverified — either way the script sees "record active").

**Timing interleavings:**
- (1) Shift+Record, Shift+Record < 350 ms: press 2 = revert+tap → STOP.
- (2) Shift+Record then plain Record < 350 ms: same CC 118 pair → same double-press branch
  (`st.rec` false, `recordActive()` true from overdub) → revert → STOP + tap.
- (3) Second press ≥ 350 ms later: `d > 7` → normal branch → clean overdub toggle, no stop.
  This timing dependence is the reported "sometimes".
- Secondary hazard, same assumption: `doRecord` (766–770) takes its toggle branch (`RecordOff`)
  whenever `recordActive()` — a plain Record press while merely overdubbing also calls
  `RecordOff` (potential stop) instead of arming full record.

**Evidence chain:** code 848–857 (window + capture), 1883–1899 (branch order, revert
condition), 774–780 (`Overdub`), 758–760 (`recordActive`), 762–772 (`doRecord` toggle),
782–793 (`doTap`). API-CONTRACT.md §3:54–56 lists `Record/RecordOff/Overdub` + props
`RecordState`/`OverdubState` as **[dv]**-existing — disproven here is the script's semantic
[p0]-class assumption "RecordState true ⇔ Record armed" (hardware: overdub ON also satisfies
it); "Overdub callable" is confirmed. MANUAL.md:22 / MAPPING.md:105 promise "double-press:
tap tempo (reverts the accidental arm)" — designed only for the plain Record path; the
branch ordering makes Shift pairs hit it too (hardware-confirmed by the stop symptom).

**Fix direction (minimal, degrade-never-break):** two parts, both required.
1. Key the double-press state by the *effective* button, not the CC: in `isDoublePress`
   (848–857) index `lastPressTick`/`pressState` by `shiftHeld and cc + 128 or cc`. Then
   Shift+Record twice = two distinct overdub presses (clean toggle, no revert/tap/stop);
   plain Record twice keeps the documented revert+tap. A `pressState` shift flag alone would
   NOT fix case (2), since the mixed pair still ends in `doRecord`.
2. Guard `doRecord`: no `RecordOff` when the record state came from overdub-only —
   approximate with `not OverdubState` alongside `recordActive()`, but first probe whether
   Record-armed also sets `OverdubState` (verification step 7). If the states are
   indistinguishable, prefer degrade: make plain Record arm-only (no RecordOff toggle)
   rather than risk RecordOff-during-overdub.

**Confidence:** high — branch order + condition are deterministic and match the symptom's
intermittency exactly; the stop itself is hardware-observed. Med only on which underlying
prop (`RecordState` vs `IsRecording`) flips during overdub.

**On-hardware verification:**
1. Probe mode (Shift+Novation): shift = ch7 cc63 v127/0 (1977–1979); record = ch1 cc118 v127.
2. Play; hold Shift; press Record once → journal `overdub`; stationary display glyph flips
   to REC (594–596); playback continues.
3. Repeat with presses > 400 ms apart → overdub toggles, playback continues (case 3).
4. Repeat with presses < 350 ms apart → journal `record disarmed (double-press)` (1889) +
   `Tap tempo` overlay and playback STOPS — reproduces the bug; capture probe lines.
5. Variant: Shift+Record then plain Record quickly → same stop (case 2).
6. After fix: repeat 3–5 → overdub toggles, playback never stops, plain-Record double-press
   still reverts the arm and taps.
7. OverdubState probe: playing with overdub only, log `H.prop(mpc.sequencer, "OverdubState")`
   and `RecordState` (or extend `logStatus`); compare with a Record-armed project, to pick
   fix-2's guard.

## ITEM B — Track ◀▶ move by only 1 track

**Symptom (verbatim):** "Track buttons - work but only move selection by 1 track"
(Shift+Track = undo/redo works).

**What the code does:** `BP[BTN.trackLeft/Right]` (1900–1913) → `setBank(bank ± 1)` (1526–1544).
`bank` is the first visible normal track index (MAPPING.md:19, `normalTracks[bank+col]`), so
each press slides the 8-column window by **one track**, clamped to `[0, n-8]` — with ≤ 8
normal tracks it is a silent no-op (`newBank == bank` → return, 1531–1533). The MPC current
track is never touched: `selectTrack` (703–717, `SetCurrentTrack` at 711) is called only from
the bottom Select row (1940–1945). The observed 1-track movement is exactly the code's behavior.

**Docs comparison:** MANUAL.md:23–24 "track bank -1/+1" and MAPPING.md:102 "bank +1 / −1"
literally match the code (bank = window start). But DAW convention reads "bank" as next group
of 8, and RECOMMENDATIONS.md:102 originally planned "bank ±1 (Shift ±8)" — a page-of-8 jump
with an 8-bank shift jump. The shipped script instead made Shift+Track = Undo/Redo
(MAPPING.md:102 right column) and bank = 1-track scroll, without recording that deviation.
The user's word "selection" is also unmet: nothing in this path changes the current track.

**Classification: works-as-designed** (code implements the docs' literal "bank +1"); the gap
is documentation, not code. Docs should clarify: (1) MANUAL.md/MAPPING.md: Track ◀▶ scroll
the visible 8-track window by **one track per press**; they never change the current track —
use bottom-row Select (CC 66 cycles mute↔select) for that; with ≤ 8 tracks the buttons are a
no-op. (2) RECOMMENDATIONS.md:102 "bank ±1 (Shift ±8)" should be annotated as superseded
(Shift+Track = Undo/Redo; scroll granularity = 1 track). If the intended UX was DAW-style ±8
page jumps, that is a design change, not a bug fix — escalate before touching code.

**Confidence:** high — behavior is fully determined by code; doc text verified.

**On-hardware verification:**
1. Project with ≥ 10 normal tracks: press Track ▶ twice → the fader track map
   (`paintTrackScreens`, 1497–1506) and `tracks N-M` overlay (`showTrackOverlay`, 1511–1525)
   advance by exactly one track per press.
2. MPC screen's current track unchanged throughout; then cycle bottom row to Select (CC 66)
   and press a column → `SetCurrentTrack` fires (1944).
3. Project with exactly 8 tracks: Track ▶ → no overlay, no movement (clamped no-op).
4. Shift+Track → Undo/Redo overlays (1901–1909) — already confirmed working.
5. Probe-mode capture: ch1 cc102/cc103 v127 per press.
