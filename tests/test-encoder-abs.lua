-- tests/test-encoder-abs.lua: absolute encoder CCs (13-36) are converted to
-- deltas, never direct-written. First sighting baselines (no jump), later
-- values nudge by delta*step (sends 1/64, pan 1/127), a spike re-baselines
-- without moving, and nothing is ever written as value/127. Control mode routes
-- row 1/2 abs to the Q-Link Twist path and row 3 abs to the global/track-page
-- handlers.
package.path = "./tests/?.lua;" .. package.path
local mock = require("mock-mpc")
_G.mpc = mock.mpc
_G.dev = mock.dev
_G.LaunchControlXL3 = mock.dev
dofile(os.getenv("LCXL3_LUA") or "script/LaunchControlXL3.lua")
local L = LaunchControlXL3

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
	end
end
local function assert_near(a, b, eps, msg)
	if math.abs(a - b) > (eps or 0.001) then
		error((msg or "") .. ": expected ~" .. tostring(b) .. ", got " .. tostring(a))
	end
end

local logs = {}
local realPrint = print
_G.print = function(msg)
	logs[#logs + 1] = tostring(msg)
end

local function clearTrack0()
	mock.tracks[0].Send1:set(0)
	mock.tracks[0].Send2:set(0)
	mock.tracks[0].Pan:set(0.5)
end

-- Mixer mode: row 1/2 absolute CCs are deltas, row 3 absolute CCs are pan.
L.OnLoad()
mock.reset()
clearTrack0()

-- First sighting is absorbed as the baseline: a direct value/127 write would
-- have set Send 1 to 100/127 here.
mock.emitAbs(0, 0, 100)
assert_near(mock.tracks[0].Send1.value, 0, 1e-9, "first absolute value is absorbed (no jump)")

-- Second sighting nudges by delta * 1/64.
mock.emitAbs(0, 0, 102)
assert_near(mock.tracks[0].Send1.value, 2 / 64, 1e-9, "second absolute value nudges Send 1 by delta/64")
assert_eq(mock.tracks[0].Send1.value ~= 102 / 127, true, "Send 1 is never direct-written as value/127")

-- A cross-seam jump is a 7-bit wrap, not a spike: 102 -> 10 reads as +36 CW
-- (the retired |delta|>32 spike rule also ate real fast turns).
local beforeWrap = mock.tracks[0].Send1.value
mock.emitAbs(0, 0, 10) -- delta -92 from 102 -> +36 after the wrap rule
assert_near(mock.tracks[0].Send1.value, beforeWrap + 36 / 64, 1e-9, "a cross-seam jump wraps to a small delta")
mock.emitAbs(0, 0, 12)
assert_near(mock.tracks[0].Send1.value, beforeWrap + 38 / 64, 1e-9, "movement resumes after the wrap")

-- |delta| == 64 is exactly half a revolution: ambiguous, re-baseline only.
mock.emitAbs(0, 0, 12 + 64) -- delta +64: absorbed without action
assert_near(mock.tracks[0].Send1.value, beforeWrap + 38 / 64, 1e-9, "an ambiguous half-revolution is re-baselined without moving")
mock.emitAbs(0, 0, 78)
assert_near(mock.tracks[0].Send1.value, beforeWrap + 40 / 64, 1e-9, "movement resumes after the ambiguous baseline")

-- Row 3 (pan) uses the 1/127 step and also baselines first.
mock.tracks[0].Pan:set(0.5)
mock.emitAbs(2, 0, 100)
assert_near(mock.tracks[0].Pan.value, 0.5, 1e-9, "pan baseline absorbed (no jump)")
mock.emitAbs(2, 0, 99)
assert_near(mock.tracks[0].Pan.value, 0.5 - 1 / 127, 1e-9, "pan nudges by delta/127")

-- Control mode: row 1 absolute CCs drive the Q-Link Twist path.
L.OnLoad() -- resets lastAbs so the first value is a baseline again
mock.reset()
clearTrack0()
mock.setQlinkTarget(12, "Cutoff") -- knob row 1 k1 (abs cc 13) = index 12
L.HandleMIDICC(6, 30, 2) -- control mode
mock.clearCalls()
mock.emitAbs(0, 0, 100)
L.HandleTimer()
assert_eq(mock.count("Twist"), 0, "first control-mode abs sighting does not twist")
mock.emitAbs(0, 0, 103)
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "row-1 abs drives the Q-Link through the deferred dot-form Twist")
assert_eq(mock.find("Twist")[1].args[1], 12, "Twist targets the screen-order Q-Link (index 12)")
assert_eq(mock.find("Twist")[1].args[2], 3, "Twist delta is the abs delta (a >= 2-detent event uses its magnitude at gain 1)")
assert_near(mock.tracks[0].Send1.value, 0, 1e-9, "control-mode row 1 never writes a send")

-- Control-mode wrap: a fresh knob baselines at 2; 127 then reads as -3 CCW.
mock.setQlinkTarget(9, "Wrap") -- knob (0,5) = row 1 k6 = Q-Link index 9
mock.emitAbs(0, 5, 2) -- first sighting: baseline
L.HandleTimer()
mock.clearCalls()
mock.emitAbs(0, 5, 127) -- delta +125 over the seam
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "the 0/127 wrap crossing yields one small detent group")
assert_eq(mock.find("Twist")[1].args[2], -3, "125 counts over the seam wrap to -3")

-- F12: the abs path sets lastTouched -- the 500 ms refresh follows this knob
-- and picks up external value changes; the old script kept targeting whatever
-- the rel path had touched (here: nothing).
for _ = 1, 40 do
	L.HandleTimer() -- drain gesture/settle text and let the knob go fully idle
end
mock.clearCalls()
mock.mpc.controlSurface.qlinks[9].SetValue(64 / 127) -- external value change
for _ = 1, 12 do
	L.HandleTimer() -- a 500 ms refresh must fire in here
end
local followed = false
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 18 and s.field == 2 and s.text == "50%" then
		followed = true
	end
end
assert_eq(followed, true, "the last-touched refresh follows the abs-driven Q-Link (F12)")

-- Row 2 absolute CCs take the same Twist path (target index row*8+col).
mock.setQlinkTarget(14, "Resonance") -- knob (1,0) = row 2 k1 = index 14
mock.emitAbs(1, 0, 100)
L.HandleTimer()
mock.emitAbs(1, 0, 102)
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "row-2 abs drives its Q-Link too (baseline + move, counted since the F12 clear)")
assert_near(mock.tracks[0].Send1.value, 0, 1e-9, "control-mode row 2 never writes a send")

-- Row 3 absolute CCs reach the global handler (tempo, col 0).
local bpm0 = mock.mpc.project.BPM.value
mock.emitAbs(2, 0, 100)
mock.emitAbs(2, 0, 101)
assert_eq(mock.mpc.project.BPM.value, bpm0 + 1, "row-3 abs reaches the global tempo handler")

-- ... and the track-page handler once the page is flipped (col 1 = Send 1).
L.HandleMIDICC(0, 107, 127) -- control page global -> track
mock.tracks[0].Send1:set(0)
mock.emitAbs(2, 1, 50)
assert_near(mock.tracks[0].Send1.value, 0, 1e-9, "track-page abs baseline absorbed")
mock.emitAbs(2, 1, 52)
assert_near(mock.tracks[0].Send1.value, 2 / 96, 1e-9, "track-page abs reaches the Send 1 handler")

L.OnUnload()
_G.print = realPrint
print("test-encoder-abs: PASS")
