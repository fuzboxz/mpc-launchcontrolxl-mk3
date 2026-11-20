# Changelog

## Unreleased

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
