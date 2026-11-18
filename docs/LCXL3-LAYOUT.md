# Launch Control XL 3 — DAW-mode wire reference

Everything the script sends to and receives from the device. Channels are given
1-based (Novation convention); the script constants are 0-based (MPC convention).

Sources: **PRG** = Novation *Launch Control XL 3 programmer's reference guide* v1.0;
**UG** = Launch Control XL 3 user guide v1; **ABLETON** = Ableton Live 12.3
`Launch_Control_XL_3` remote script (decompiled, `references/`); **SPEC** =
`yutsdxg/launch-control-xl3` community spec. Items marked ⚠ are Phase-0 verification
points (`docs/DEVICE-TEST-PLAN.md`).

## 1. Interfaces

| Interface | Purpose |
|---|---|
| MIDI In/Out (1st USB pair) | custom modes, external MIDI |
| **DAW In/Out (2nd USB pair)** | everything in this document |
| To DIN Out / To DIN Out 2 (3rd/4th) | host → DIN forwarding |

- No DIN output in DAW mode (PRG).
- Windows names: `MIDIIN2` / `MIDIOUT2`; macOS: `LCXL3 DAW In/Out` (Novation setup
  articles). **MPC/Linux (device-verified 2026-11-18):** the kernel
  merges the DAW jack pair into one bidirectional seq port named `LCXL3 1 DAW In`,
  and the MPC app's JUCE ports carry the same name; the `.ini` ships
  `input=LCXL3 1 DAW In,MIDIIN2 (LCXL3 1)` (comma lists are factory style,
  cf. `mpkMiniMkIV.ini`). The name embeds the device ID.
- USB: vendor `4661` (0x1235), products `328-335` (**328 = 0x148 observed on device**),
  model `LCXL3 1..8` (device ID 1-8, set in bootloader). Identity reply family/model
  bytes `01 00 01` (ABLETON) — **firmware 1.1.11 observed**.

## 2. Channels

| Function | MIDI ch | 0-based | Source |
|---|---|---|---|
| Buttons | 1 | 0 | PRG, ABLETON |
| LED palette colour (`B0h`) | 1 | 0 | PRG, ABLETON (`colored_encoder._send_led_color`) |
| Shift, Mode, Edit, feature controls | 7 | 6 | PRG, ABLETON |
| Feature-control queries | 8 | 7 | PRG |
| Touch events | 15 | 14 | PRG, ABLETON (`channels=14`) |
| Faders + encoders (absolute & relative) | 16 | 15 | PRG, ABLETON (`channels=15`) |
| Blink channel | 2 ⚠ | 1 | ABLETON `BLINK_CHANNEL = 1` only (still unverified) |

## 3. Control indices (CCs)

| Control | CC | Channel | Notes |
|---|---|---|---|
| Faders 1-8 (L→R) | 5-12 | 16 | absolute 7-bit |
| Encoders row 1 (L→R) | 13-20 abs / 77-84 rel | 16 | |
| Encoders row 2 | 21-28 abs / 85-92 rel | 16 | |
| Encoders row 3 | 29-36 abs / 93-100 rel | 16 | |
| Track buttons 1-8 (top row) | 37-44 | 1 | Solo/Arm row |
| Track buttons 9-16 (bottom row) | 45-52 | 1 | Mute/Select row |
| Solo/Arm (far-left top) | 65 | 1 | cycles the top row; in mode-select = DAW Control |
| Mute/Select (far-left bottom) | 66 | 1 | cycles the bottom row; in mode-select = DAW Mixer |
| Track right / left | 102 / 103 | 1 | |
| Novation | 104 | 1 | "nothing… yet" (UG) |
| Page up / down | 106 / 107 | 1 | |
| Play | 116 | 1 | |
| Record | 118 | 1 | |
| Mode | 30 | 7 | mode select **and** mode report |
| Shift+Mode (Edit) | 31 | 7 | ABLETON `Encoder_User_Mode_Element` |
| Shift | 63 | 7 | double-press latches (UG) |
| Touch: faders / encoders | 5-12 / 77-100 | 15 | 127 = on, 0 = off |

Unassigned/unknown: 105, 108-115, 117, 53-64 — ⚠ probe.

### Relative encoding

- Binary offset (ABLETON `MapMode.LinearBinaryOffset`): pivot 64, `65` = +1 detent CW,
  `63` = −1. ⚠ fast-turn behaviour per encoder-curve setting (magnitude vs. rate).
- Enable per row: `B6h 69/72/73 7Fh` (feature CCs, ch 7).
- In relative mode the CC numbers shift by `+40h` per row: 77-84, 85-92, 93-100.

## 4. Surface modes (ch 7 CC 30)

| Value | Mode |
|---|---|
| 1 | DAW Mixer |
| 2 | DAW Control |
| 6-9 | Custom modes 1-4 |
| 18-29 | Custom modes 5-16 (⚠ the PDF's 5-8/8-16 split is self-inconsistent; the online article's 18-29 reading is used) |

The device reports user-driven changes on this CC; the host must follow (PRG). Ableton
selects DAW Mixer after identification.

## 5. LEDs

| Mechanism | Message | Notes |
|---|---|---|
| Palette | `B0h <control index> <palette 0-127>` | works for buttons and encoders; encoders are addressed by their **absolute** index (13-36) in either mode |
| RGB | `F0 00 20 29 02 15 01 53 <idx> <R> <G> <B> F7` | R/G/B 0-127 |
| Blink | palette CC on MIDI ch 2 alternating with 0 | ⚠ ABLETON-only |
| Shift | excluded from colouring (feature-control tied) | PRG |

**This script uses the RGB mechanism, not the palette** (device-verified choice):
the palette's dim variants sat too close to their bright twins, so on/off contrast
was poor. Custom RGB gives true dark dims (~1/6 luminance) with full-bright actives:

| Name | RGB | | Name | RGB |
|---|---|---|---|---|
| off | 0,0,0 | | green / dim | 8,127,20 / 0,22,5 |
| white / dim | 127,127,127 / 16,16,16 | | blue / dim | 16,60,127 / 2,9,24 |
| red / dim | 127,4,4 / 24,0,0 | | dark blue | 6,22,60 |
| orange / dim | 127,52,0 / 26,10,0 | | turquoise | 0,108,108 |
| yellow | 127,100,0 | | purple | 118,16,118 |

A test (`test-manual`) enforces ≥4x luminance ratio between every bright/dim pair.
The palette remains a documented fallback: `B0h <ctrl> <index>` with ABLETON's
`colors.py` indices (off 0, white 3/1, red 5/7, green 21/27, blue 41/43,
darkBlue 47, turquoise 39, purple 53, orange 96/83, yellow 97).

## 6. Screen

| Message | Format |
|---|---|
| Configure | `F0 00 20 29 02 15 04 <target> <config> F7` |
| Set text | `F0 00 20 29 02 15 06 <target> <field> <text…> F7` (ASCII 20h-7Eh) |
| Bitmap | `F0 00 20 29 02 15 09 <target> <1216 bytes> 7F F7` (19 B × 64 rows, 128 px wide, MSB = leftmost); ack `…09 7F` |

- Targets: **5-12** faders, **13-36** encoders (absolute indices), **53** stationary,
  **54** overlay/temporary.
- Config: `0` cancel, `127` trigger-with-current-contents, `97` 2-line,
  `98` 3-line; bit 6 = auto temp display on change, bit 5 = on touch (PRG + ABLETON
  `Config` enum).
- 16 characters per line (ABLETON `DisplayText(max_width=16)`).
- Arrangements (PRG): 1 = name+text, 2 = title+name+text, 3 = title + 8 names,
  4 = name + numeric.
- Host pacing (ABLETON `Launch_Control_XL_3.__init__`): delay display flush ~1 s after
  identification; when >10 sysex are queued, dedupe by the first 9 bytes and space the
  survivors 10 ms apart.

## 7. Feature controls (ch 7; queries ch 8; replies ch 7)

| CC | Feature | Range |
|---|---|---|
| 30 | surface mode select/report | see §4 |
| 63 | Shift | on/off |
| 69 / 72 / 73 | encoder rows 1/2/3 relative output | on/off |
| 70 | DAW fader pickup | on/off |
| 71 | continuous-control touch events | on/off |
| 111 / 112 | LED / screen brightness | 0-127 |
| 113 | temporary display timeout | 0-99 (0.1 s units, min 1 s at 0) |
| 120 | Out2 MIDI thru | on/off |
| 100 | global MIDI channel | 0-15 |
| 121 | encoder curve | 0 slow / 1 medium / 2 fast |

`*` = non-volatile; `#` = always fully enabled in DAW mode (PRG).

## 8. Session lifecycle

| Step | Messages |
|---|---|
| Enter DAW mode | `9Fh 0Ch 7Fh` (note 12, ch 16, vel 127) or `F0 00 20 29 02 15 02 7F F7` |
| Leave DAW mode | same with value 0 |
| Hello (ABLETON) | connection sysex + `B6h 47h 7Fh` (enable touch) |
| On identify (ABLETON) | set relative rows 69/72/73 = 127, default surface mode = DAW Mixer, delay display flush 1 s |
| Goodbye (ABLETON) | connection sysex with 0 |

The script sends both enable forms and both disable forms (idempotent), so a framing
surprise on either path cannot strand the device.
