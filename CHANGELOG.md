# Changelog

## 1.1.1 — 2026-11-25

Fixes for the bug report from the 2026-11 hardware session (MPC Live III 3.10.1.8, XL3 fw 1.1.11).
Every item is covered by the host suite (`cd tests && sh run-tests.sh`: 26 test files, run against
both the source and the minified shipped artifact, ending `ALL TESTS PASS`); hardware confirmation
is called out where it exists. Root-cause analysis for the v1.1.0 behaviour is in
`reports/00-FINAL-TRIAGE.md`.

### Q-Links (control mode, rows 1-2)

- **Encoder feel**: gain now comes from the measured turn rate, 1x..**4x** (v1.1.0 ramped to 8x, so
  a half sweep ran the whole range); a slow turn moves exactly one position per detent. Tunable via
  `__LCXL3_QFEEL{gapTicks, rateTicks, maxMult, settleTicks, absUnitsPerDetent, traceGestures}`.
- **No more closed-loop twisting**: detents coalesce to one `Twist` per knob per tick, the first one
  still fires immediately in the MIDI context; the shadow position is clamped 0..127 and the normal
  path issues no `GetPosition`/`GetValueString` read-backs and no `SetPosition`/`SetValue` writes
  (the v1.1.0 loop double-twisted under the device's one-change read lag, then "corrected" the ring).
- **Value never disappears**: the value line is never blank (cached device string, `-` fallback);
  the settle pass re-reads once, adopts the device position and **logs drift** instead of writing.
- **Settle re-arms on every detent**, so a steady 150 ms cadence still gets its closing pass (drift
  check, closing `Touch`, final re-read).
- **Knob order follows the loaded Q-Link set** — the device exposes no page/selection property
  (`API-CONTRACT.md:78`), so the set is identified from its target names and logged:
  - track/plugin pages keep the column-major table `{12,8,4,0,13,9,5,1}` / `{14,10,6,2,15,11,7,3}`
    (OPx macros come out 1-4 ascending);
  - the global/main page uses identity, because its parameters sit at indices 0..15 in order
    (0 `TRACK LEVEL`, 1 `PLAYHEAD`, 4 `TIME DIVISION`, …);
  - a page-interleaved variant (4 pages x 4 slots) was tried on hardware and **rejected** (plugin
    macros came out reversed); it must not be reintroduced without new device evidence.
  - unreadable names (project still loading) keep the current order — the default is column-major,
    i.e. the shipped behaviour.
- **Per-knob stream lock**: a device that emits absolute *and* relative on the same knob cannot
  double-step; the first stream wins and the ignored one is logged once. The row-1 absolute path
  handles the 0/127 wrap and carries the fractional remainder (`absUnitsPerDetent`).

### Continuous parameters (shadow steppers)

- Sends, pan, track page, tempo, strength, swing and master now step from the last value the script
  wrote and only re-read after 300 ms of quiet — a 12-detent flick applies 12 steps instead of 3
  (the v1.1.0 read-modify-write stalled on lagging reads).
- **Swing** no longer jumps to max: the shadow re-syncs after quiet, the unit (percent vs fraction)
  is auto-detected, and the display always reads `NN%`.
- **Timing division** advances one step per **two** detents, saturating, with the flip resetting the
  accumulator (was one list step per message off a lagging read).
- **Automation filter** no longer flips on/off: saturating two-detent steps (CW ends on the last
  type, CCW on the first), enumeration that survives read lag across timer ticks, and the CW-only
  `Advance` path as the degrade.
- **Metronome and loop** are *set* to the direction's state instead of toggling a stale read.

### Faders

- Pickup references are re-read after load, every 2 s, and on a track-count change for faders that
  were never picked — so a fader no longer needs a trip to minimum first. No blind writes while a
  fader is off-reference; `__LCXL3_HWPICKUP = false` restores the old behaviour.
- Hardware evidence: `fader 1 reference 0 -> 90 (project readable after load)`.

### Transport / overdub

- The raw transport numbers are journaled before and after every overdub toggle (`overdub: before
  …/after …`), which is what makes the LED behaviour diagnosable from the field.
- Opt-in `__LCXL3_OD_CLEAN = true`: no `Record` pre-arm, playback verified for two ticks with an
  automatic fallback. The **default sequence is unchanged** — the Record LED still flashes briefly
  when overdub turns off (cosmetic; the flash is the pre-arm, not a transport change).

### Native Q-Link routing

- Corrected to Akai's shipped signatures — `AddInfiniteCCToQLink(channel, cc, qlinkIndex)`,
  `RemoveInfiniteCCToQLink(channel, cc)`, `SetQLinkFineAdjust(bool)` — with per-encoder verification
  via a non-circular remove/rebind query flip, an honest CC sweep, and per-encoder fallback.
- Ships **off** (`__LCXL3_NATIVE = false`): the MPC parser's expected encoding for the XL3's binary
  offset is still unprobed, and the comments now say so instead of asserting a direction.

### Tests and tooling

- The mock gained the device's read-lag behaviour (`mock.setReadLag(n)`, ticked by
  `mock.tick`/`runTicks`), plus unreadable-volume and overdub-toggle switches.
- Seven new regression files — `test-mock-lag`, `test-qlink-gesture`, `test-shadow-step`,
  `test-fader-pickup-resync`, `test-overdub-clean`, `test-native-routing`, `test-qlink-order` — each
  proven to fail against the v1.1.0 script at the intended defect.
- The suite runs the whole set twice: against the source and against the minified artifact that is
  actually shipped.

### Signing

- The salt provenance is documented in the script header: `checksum = sha256(lua_bytes .. salt)`,
  salt read from the MPC 3.10.0.49 Gen2 firmware update image `MPC-3.10.0.49-gen2`
  (md5 `15a664f6b6ae591c8b78baae8b376f02`, build id `2209920bc0a`) at offset `0x5287C10` with XOR
  key `0x5F694973D3C78945`, plus the tooling and the `MPC_SALT` override.

### Known limitations

- The overdub Record-LED flash remains in the default path (opt-in clean path only).

## 1.1.0 — hardware-hardening pass

Fixes from the 2026-11 hardware session (MPC Live III, XL3 fw 1.1.11); full triage in
`reports/00-FINAL-TRIAGE.md`. The hardware-probe session is still pending (triage §5),
so probe-gated claims stay annotated, not flipped.

- **Transport**: the double-press branches (rewind, tap tempo) are plain-press-only —
  a quick Shift+Play pair can no longer rewind, and Shift+Record can no longer fall
  into the tap-tempo path. The record guard no longer sends `RecordOff` while
  overdub-only is raised (on device it stops playback); full record is armed instead.
- **Encoders**: absolute CCs are converted to deltas (first value absorbed as the
  baseline — no jumps after load or mode switch; row 1 stays absolute on fw 1.1.11),
  and the absolute path is mode-aware, so control-mode rows 1-2 can no longer leak
  writes into the mixer sends.
- **Q-Links**: native hardware routing (`AddInfiniteCCToQLink`) ships disabled by
  default — fw 1.1.11 inverts the MPC parser's direction; all 16 Q-Links are driven
  script-side (`Touch` + `Twist`) until the direction/magnitude probe.
- **Screen pipeline**: per-key queue dedupe keeping the newest text, cache committed
  at send time (not queue time), and a one-shot post-burst re-assert so a
  device-dropped text cannot stick permanently; the overlay path got the same
  hardening.
- **Automation filter**: bidirectional CW/CCW stepping through the real
  `Get/SetGlobalAutomationFilterType` pair (enum enumerated lazily), with the actual
  type shown on screen; the CW-only `Advance` path remains as the degrade.
- **Q-Links (fw 1.1.11 resolution)**: rows 1-2 drive Q-Links 1-16 through the
  sibling project's device-proven driver, ported exactly - dot-form calls only
  (`H.call(q.Twist, d)` with a <=2-retry loop, position-scaled `SetValue` when
  the value string does not change, `SetPosition` ring sync, `pcall(q.Touch)`).
  The method form (`q:Twist(d)`) passes the qlink table where a delta belongs
  and progressively CORRUPTS the Q-Link page (targets vanish, positions freeze;
  app restart restores) - it is never used. Twists carry a turn-velocity
  acceleration ramp (x1 -> x8) so the raw one-position detent is usable on
  wide-range parameters; turns twist immediately in the MIDI context with a
  post-spin settle (see the latency overhaul bullet below).
- **Q-Link knob order (device-confirmed)**: the 16 knobs mirror the MPC's Q-Link
  screen groups — group 1 = Q-Links 13,9,5,1 (indices 12,8,4,0), group 2 =
  14,10,6,2, group 3 = 15,11,7,3, group 4 = 16,12,8,4 — so XL3 row 1 = groups 1+2,
  row 2 = groups 3+4: `{12,8,4,0,13,9,5,1}` / `{14,10,6,2,15,11,7,3}`. Two earlier
  tables (linear and a screen-mirror fold) were validated against a top row that
  was silently dead — the row-1 absolute-CC path never painted the LCXL3 screens
  and a blind diagnostic logger masked the state — so both "failures" were
  instrumentation artifacts, not mapping verdicts (see
  `reports/oracle-rootcause.md`).
- **Knob latency overhaul (Q-Links)**: turns now twist IMMEDIATELY in the
  MIDI context (previously every detent waited for the next 50 ms timer
  tick); active spins (2nd+ detent) take a 2-call fast path - one Touch, one
  dot-form Twist, no read-backs (GetPosition/GetValueString lag one change
  and were costing 3+ round-trips per detent, partly from the now-removed
  diagnostic taps themselves); a settle pass 2 quiet ticks after the spin
  syncs the ring and refreshes the value text once (no parameter write);
  isolated detents keep the full proven driver including the SetValue
  fallback; the acceleration ramp engages earlier (x2 after 2 detents, x4
  after 6, x8 after 12). `__LCXL3_IMMEDIATE = false` reverts to
  timer-drained twists if a device session ever shows MIDI-context drops.
- **LED colours**: pan ring shows a dim WHITE at centre (was off; distinct from
  the blue/orange hues, which now fade in from it), and the control-mode track
  page separates Send 1-4 as blue/purple/turquoise/green with volume trim
  orange (dark blue was indistinguishable from blue).
- **Deployment (device-learned)**: the loader caches scripts from app start -
  every deploy needs an `acvs` restart; `scriptVersion` must stay `1.0`;
  signing uses the 3.10.0.49-gen2 kit binary (the on-device firmware's salt
  obfuscation changed, but it validates the same salt).
- **Pan scale**: the display now spans L50..R50 (offset × 100), matching the MPC's
  ±50 scale — the old readout went to ±100.
- **Polish**: master volume writes only over a real read (no blind 0.7 default,
  one-shot failure logs), and swing deltas are clamped per detent so a flick cannot
  jump percent steps.

## 1.0 — initial release

Novation **Launch Control XL 3** controller script for Akai MPC 3.10.1 (Gen2),
device-verified on an MPC Live III with XL 3 firmware 1.1.11.

- **DAW-mode session**: dual-form enter/leave, relative encoder rows, touch
  events, fader pickup, brightness/timeout/curve configuration, surface-mode
  select + follow, firmware identity probe. DAW port name verified
  (`LCXL3 1 DAW In`; the `.ini` ships factory-style candidate lists).
- **Mixer surface**: faders = track volume (hardware + software pickup),
  encoder rows = Send 1/2 and 3/4 (Page ▲▼ bank) + Pan. All knob rings follow
  one rule — hue says what, brightness says how much
  (`0.07 + 0.93 · value^1.7`): sends ring in the track colour scaled by level,
  pan is a continuous blue/orange readout, empty tracks go dark.
- **Control surface**: rows 1-2 hardware-routed into the MPC's 16 Q-Links
  (`AddInfiniteCCToQLink`, script-side `Twist` fallback); row 3 = global page
  (tempo, swing, quantise strength/division, metronome, loop, automation
  filter, master volume) with a track-utility page; Shift+Page walks plugin
  presets. Rings scale with live parameter values.
- **Buttons**: Solo/Arm and Mute/Select cycle rows, Track ◀▶ bank moves
  (Shift = undo/redo), Page ▲▼ (Shift = bar steps), Play (double-press =
  rewind, Shift = stop / stop all clips), Record (double-press = tap tempo,
  Shift = overdub), Novation = track-map overlay (Shift = probe mode).
- **Screen**: stationary 3-line page (bank + transport + bar.beat), per-control
  pages, a fader-display track map (name + dB per column) and a named overlay
  announcing bank moves; content-addressed cache, ≤ 6 sysex per 50 ms tick,
  overlay text strictly before its trigger.
- **LEDs**: custom RGB with a calm palette — genuinely dark inactive states
  (≥ 4x on/off luminance contrast, enforced by test).
- **Track numbering**: global↔normal offset learned passively so page labels,
  select highlight and selection follow the MPC UI's own track numbers.
- **Robustness**: every optional API is pcall-guarded and gates on API
  presence (never on void/false returns); missing facilities disable their
  surface and log once instead of failing.

`scriptVersion` in the ini stays `1.0` — the MPC loader silently refuses
semver strings there (see `tools/check-ini.sh`).
