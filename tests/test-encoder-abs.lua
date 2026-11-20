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

-- A spike (|delta| > 32) re-baselines without moving; the next move resumes.
local beforeSpike = mock.tracks[0].Send1.value
mock.emitAbs(0, 0, 10) -- delta -92 from 102
assert_near(mock.tracks[0].Send1.value, beforeSpike, 1e-9, "a spike re-baselines without moving")
mock.emitAbs(0, 0, 12)
assert_near(mock.tracks[0].Send1.value, beforeSpike + 2 / 64, 1e-9, "movement resumes after the spike baseline")

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
mock.setQlinkTarget(12, "Cutoff") -- row 1 col 1 = index 12
L.HandleMIDICC(6, 30, 2) -- control mode
mock.clearCalls()
mock.emitAbs(0, 0, 100)
L.HandleTimer()
assert_eq(mock.count("Twist"), 0, "first control-mode abs sighting does not twist")
mock.emitAbs(0, 0, 103)
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "row-1 abs drives the Q-Link through the deferred dot-form Twist")
assert_eq(mock.find("Twist")[1].args[1], 12, "Twist targets the screen-order Q-Link (index 12)")
assert_eq(mock.find("Twist")[1].args[2], 3, "Twist delta is the abs delta")
assert_near(mock.tracks[0].Send1.value, 0, 1e-9, "control-mode row 1 never writes a send")

-- Row 2 absolute CCs take the same Twist path (target index row*8+col).
mock.setQlinkTarget(14, "Resonance") -- row 2 col 1 = group 3 top = index 14
mock.emitAbs(1, 0, 100)
L.HandleTimer()
mock.emitAbs(1, 0, 102)
L.HandleTimer()
assert_eq(mock.count("Twist"), 2, "row-2 abs drives its Q-Link too (baseline + move)")
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
