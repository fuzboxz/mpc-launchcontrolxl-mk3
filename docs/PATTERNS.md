# PATTERNS — reusable patterns for MPC↔XL 3 work

Extracted from the reference controllers (nanoKontrol, APC mini mk2, ForceLink — see
the sibling launchpad project's `PATTERNS.md` for the full set with citations) and from
Ableton's own XL 3 remote script. Reuse the logic, not the wire format.

## 1. Register what you handle, unregister what you don't

Only (channel, CC) pairs registered via `AddCCToScript` reach the script. Keep the set
in one table (`SURFACE_CC`) and route/unroute it in one function so load/unload stay
symmetric. When a CC must be handed to another consumer (Q-Links, an MPC control),
`RemoveCCToScript` first and re-add on the way back — the launchpad tap-tempo pattern.

## 2. One writer, state-driven feedback

MPC is the single writer of project state; the script is the only writer of surface
feedback. Never light an LED from the button press: register listeners on the
properties the button changes and repaint from there. The XL 3 adds a second surface
(the screen) — same rule: the screen shows state, and its content-addressed cache
makes repaints cheap.

## 3. Cache every outbound message

The XL 3 is fed over one USB pipe: an uncached repaint floods it. Cache LED palette by
control index, screen text by `target:field`, and only send diffs. Ableton dedupes
queued display sysex by their first 9 bytes and spaces survivors 10 ms apart; the
script's equivalent is a ≤6-sysex-per-tick pump on the 50 ms timer.

## 4. Pick a tempo, then a curve

Faders: absolute, with pickup. Push the MPC's value to the device (CC on ch 16) so the
hardware pickup has a reference, and keep a software guard for the case where that
push is ignored. Encoders: relative, deltas applied to the current value with a fixed
step per detent — never an absolute jump.

## 5. Prefer native routing over emulation

When MPC can own the control (`AddInfiniteCCToQLink`), let it: real acceleration, real
parameter writes, no lag. Emulation (`Twist` loops) is the fallback, not the design.
Verify the routing succeeded (`IsQLinkMappedInfinite`) and fall back per-CC, not
all-or-nothing.

## 6. Follow the device's own mode machine

The XL 3 reports surface-mode changes on ch 7 CC 30 whenever the user presses Mode. A
host that ignores this desynchronises its screen from the hardware. Select a default
on connect (Ableton picks DAW Mixer), then follow reports — including into custom
modes, where the correct behaviour is to step back and keep only transport alive.

## 7. Guard, log once, continue

Every optional API behind `pcall` + a type check; first failure per label logged once
(`logOnce`). A missing feature disables its surface, never the script. Keep the guard
list in the API contract so reviews can check it.

## 8. Probe mode before trust

Ship a probe that logs every incoming message and lights the pressed control. It turns
"the mapping is wrong" from a debugging session into a 30-second check, and it is the
only way to fill in the CCs Novation does not document (105, 108-115, 117).

## 9. Blink in the host, dimly

The only blink mechanism corroborated for the XL 3 is Ableton's alternate-colour-on-
channel-2 trick. Until it is verified, render blinking as a repaint that alternates the
palette with `off`/dim on the timer phase (2 Hz reads well), exactly like the launchpad
script does for clip states.

## 10. Degrade the screen last

When the sysex budget is tight, drop the overlay first, then per-control refreshes,
and the stationary line last (design doc wins — RECOMMENDATIONS §7.2; a stale toast
is the cheapest loss). The timer's `refreshLastTouched` (every 500 ms) is the only
periodic text source; nothing else polls.
