-- tests/test-qlink-twist.lua: the gesture engine's dot-form Twist driver and
-- its degrade (task T1). Normal path: dot-form Twist only -- the method form
-- passes the qlink table into the C++ layer and corrupts the Q-Link page on
-- fw 1.1.11 -- with one Touch per gesture (+ one at settle) and no SetPosition.
-- The retired LPP3 read-verify-correct loop survives ONLY as the degrade:
-- when Twist is missing or errors, position-scaled SetValue + SetPosition
-- fire, logged once per Q-Link.
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

local logs = {}
local realPrint = print
_G.print = function(msg)
	logs[#logs + 1] = tostring(msg)
end

local function logCount(needle)
	local n = 0
	for _, l in ipairs(logs) do
		if l:find(needle, 1, true) then
			n = n + 1
		end
	end
	return n
end

L.OnLoad()
mock.reset()
mock.setQlinkTarget(12, "Cutoff") -- knob row 1 k1 (cc 77) = Q-Link index 12
L.HandleMIDICC(6, 30, 2) -- DAW Control
assert_eq(logCount("qlinks: count=16 first target 'target0'"), 1, "entering control mode logs the qlink inventory once")
mock.runTicks(L, 4)

-- A row-1 detent drives dot-form Twist; the first detent does not wait for
-- the timer, and the normal path never writes the knob position.
mock.clearCalls()
local p0 = mock.qlinkPosition(12)
mock.emitRel(0, 0, 1) -- +1 on row 1 col 1
local twists = mock.find("Twist")
assert_eq(#twists, 1, "one dot-form Twist drives the detent")
assert_eq(twists[1].args[1], 12, "row 1 knob 1 targets Q-Link 13 (MPC screen order)")
assert_eq(twists[1].args[2], 1, "an isolated detent steps exactly one position (gain 1)")
assert_eq(mock.qlinkPosition(12), p0 + 1, "the Q-Link moved by the detent")
assert_eq(mock.count("SetPosition"), 0, "no SetPosition in the normal path")
assert_eq(mock.count("Touch") >= 1, true, "Touch opens the gesture")

-- CCW turns back down (a fresh gesture after the quiet gap).
mock.runTicks(L, 4) -- let the gesture settle
mock.clearCalls()
mock.emitRel(0, 0, -1)
mock.tick(L)
assert_eq(mock.qlinkPosition(12), p0, "CCW applies one step back down")

-- A row-2 turn takes the same engine (QLINK_ORDER knob -> Q-Link mapping).
mock.clearCalls()
local p2 = mock.qlinkPosition(2)
mock.emitRel(1, 3, 1) -- row 2 knob 4 -> Q-Link index 2 (group order)
mock.tick(L)
assert_eq(mock.qlinkPosition(2), p2 + 1, "row 2 twists its Q-Link (group order)")
assert_eq(mock.count("Twist"), 1, "one Twist per detent")

-- An EMPTY-name Q-Link still drives; only the ring goes dark, and the value
-- line stays non-blank.
mock.setQlinkTarget(13, "") -- row 1 knob 5 (p4) = Q-Link 14 (index 13)
mock.clearCalls()
local p13 = mock.qlinkPosition(13)
mock.emitRel(0, 4, 1)
mock.runTicks(L, 40) -- drain the screen pump
assert_eq(mock.qlinkPosition(13), p13 + 1, "the unnamed Q-Link still moves (no input name gate)")
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 17 and s.field == 2 then
		assert(s.text ~= "", "the unnamed Q-Link never gets an empty value line")
	end
end

-- When Twist has no effect (a firmware without a working Twist), the degrade
-- fires: position-scaled SetValue + SetPosition, logged once per Q-Link.
mock.setTwistNoEffect(true)
mock.clearCalls()
local p0b = mock.qlinkPosition(12)
mock.emitRel(0, 0, 1)
mock.tick(L)
assert_eq(mock.count("SetValue"), 1, "no-effect Twist falls back to SetValue")
assert_eq(mock.count("SetPosition"), 1, "the degrade syncs the knob with SetPosition")
assert_eq(mock.qlinkPosition(12), p0b + 1, "the degrade moved the Q-Link")
assert_eq(logCount("SetValue/SetPosition fallback"), 1, "the degrade is logged once per Q-Link")
mock.setTwistNoEffect(false)

L.OnUnload()
_G.print = realPrint
print("test-qlink-twist: PASS")
