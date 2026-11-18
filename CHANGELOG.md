# Changelog

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
