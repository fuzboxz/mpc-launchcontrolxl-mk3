-- tests/test-qlink-twist.lua: the LPP3-exact Q-Link driver (dot-form calls
-- only -- the method form corrupts the Q-Link page on fw 1.1.11). A turn is
-- deferred to the timer context, drives to an absolute target with dot-Twist,
-- falls back to position-scaled SetValue when the value string does not
-- change, and syncs the knob with SetPosition; Touch wraps the burst.
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

local function drain(n)
	for _ = 1, (n or 3) do
		L.HandleTimer()
	end
end

L.OnLoad()
mock.reset()
mock.setQlinkTarget(12, "Cutoff") -- row 1 col 1 = screen top-left = Q-Link 13 (index 12)
L.HandleMIDICC(6, 30, 2) -- DAW Control
assert_eq(logCount("qlinks: count=16 first target 'target0'"), 1, "entering control mode logs the qlink inventory once")
for _ = 1, 40 do
	L.HandleTimer()
end

-- A row-1 turn defers and the timer drains it: dot-form Twist with the
-- acceleration-scaled delta, position moved, SetPosition sync, Touch wrapped.
mock.clearCalls()
local p0 = mock.qlinkPosition(12)
L.HandleMIDICC(15, 77, 66) -- +2 detent on Q-Link 1 (accel 1: streak <= 3)
drain()
local twists = mock.find("Twist")
assert_eq(#twists, 1, "one dot-form Twist drives the detent")
assert_eq(twists[1].args[1], 12, "row 1 col 1 targets Q-Link 13 (MPC screen order)")
assert_eq(twists[1].args[2], 2, "the Twist delta is the target delta")
assert_eq(mock.qlinkPosition(12), p0 + 2, "the Q-Link moved by the detent")
assert_eq(mock.count("SetPosition"), 1, "the knob position is synced")
assert_eq(mock.count("Touch") >= 1, true, "Touch wraps the drive")

-- CCW turns back down.
L.HandleMIDICC(15, 77, 63)
drain()
assert_eq(mock.qlinkPosition(12), p0, "CCW applies immediately; streak-2 detent doubles under the quicker ramp (+2 then -2)")

-- A row-2 turn takes the same path (Q-Link 9+).
mock.clearCalls()
local p11 = mock.qlinkPosition(2) -- row 2 col 4 = group 3 bottom = Q-Link 3 (index 2)
L.HandleMIDICC(15, 88, 66) -- row 2 col 4 -> Q-Link index 2 (group order)
drain()
assert_eq(mock.qlinkPosition(2), p11 + 2, "row 2 twists its Q-Link (group order)")
assert_eq(mock.count("Twist"), 1, "one Twist per detent (retry loop sees the move)")

-- An EMPTY-name Q-Link still drives; only the ring goes dark.
mock.setQlinkTarget(13, "") -- row 1 col 5 = group 2 top = Q-Link 14 (index 13)
mock.clearCalls()
local p4 = mock.qlinkPosition(13)
L.HandleMIDICC(15, 81, 65)
drain()
assert_eq(mock.qlinkPosition(13), p4 + 1, "the unnamed Q-Link still moves (no input name gate)")

-- When the value string does not change (Twist has no effect), the
-- position-scaled SetValue fallback fires.
mock.setTwistNoEffect(true)
mock.clearCalls()
local p0b = mock.qlinkPosition(12)
L.HandleMIDICC(15, 77, 65)
drain()
assert_eq(mock.count("SetValue"), 1, "no-effect Twist falls back to SetValue")
assert_eq(mock.qlinkPosition(12), p0b + 1, "the SetValue path moved the Q-Link")
assert_eq(logCount("SetValue path used"), 0, "the LPP3 driver needs no fallback log")
mock.setTwistNoEffect(false)

L.OnUnload()
_G.print = realPrint
print("test-qlink-twist: PASS")
