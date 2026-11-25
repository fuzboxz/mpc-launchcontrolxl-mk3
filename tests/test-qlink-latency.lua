-- tests/test-qlink-latency.lua: the gesture engine's latency contract (task T1).
--   1. the FIRST detent of a gesture twists immediately in the MIDI context
--      (zero-wait first response): one Touch, one position read to seed the
--      shadow, no SetPosition, no SetValue anywhere in the normal path,
--   2. later detents coalesce: one Twist per Q-Link per timer tick, and no
--      GetPosition read-backs between the gesture start and the settle (the
--      device read lags one change and the old closed loop double-twisted),
--   3. the settle pass runs once the knob has been quiet: one position read,
--      one Touch, a display/ring refresh, and never a parameter write.
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

L.OnLoad()
mock.reset()
mock.setQlinkTarget(12, "Cutoff")
L.HandleMIDICC(6, 30, 2) -- control mode
mock.runTicks(L, 4)
mock.clearCalls()

-- 1: the isolated first detent is immediate and open loop
mock.qlinkPositions[12] = 60
mock.clearCalls()
mock.emitRel(0, 0, 1) -- row 1 col 1, +1
assert_eq(mock.count("Twist"), 1, "the first detent twists immediately (MIDI context)")
assert_eq(mock.qlinkPosition(12), 61, "applied before any timer tick")
assert_eq(mock.count("SetPosition"), 0, "no SetPosition in the normal path")
assert_eq(mock.count("SetValue"), 0, "no SetValue in the normal path")
assert_eq(mock.count("Touch"), 1, "one Touch opens the gesture")
assert_eq(mock.count("GetPosition"), 1, "one position read seeds the shadow, none after")

-- 2: a spin coalesces per tick with no read-backs
mock.clearCalls()
for _ = 1, 4 do
	mock.emitRel(0, 0, 1)
end
assert_eq(mock.count("Twist"), 0, "later detents do not twist inline")
assert_eq(mock.count("GetPosition"), 0, "no read-backs between detents")
assert_eq(mock.count("Touch"), 0, "no per-detent Touch bursts")
mock.tick(L)
assert_eq(mock.count("Twist"), 1, "one coalesced Twist per tick")
assert_eq(mock.count("GetPosition"), 0, "still no read-backs mid-gesture")
assert_eq(mock.count("SetPosition"), 0, "the knob position is not written mid-gesture")
assert_eq(mock.count("GetValueString") <= 2, true, "only display reads per tick (flush refresh + the 500 ms last-touched refresh)")
assert_eq(mock.count("GetTargetName") <= 2, true, "no name-read storm")
assert_eq(mock.qlinkPosition(12), 69, "the coalesced steps applied (+1 inline; the 4 queued detents gain through the rate window: 1+2+2+3)")

-- 3: the settle after the quiet window
mock.clearCalls()
mock.runTicks(L, 4)
assert_eq(mock.count("Twist"), 0, "the settle does not twist")
assert_eq(mock.count("GetPosition"), 1, "the settle re-reads the position once")
assert_eq(mock.count("SetPosition"), 0, "the settle never writes the knob position")
assert_eq(mock.count("SetValue"), 0, "the settle never writes the parameter")
assert_eq(mock.count("Touch"), 1, "one Touch closes the gesture")

L.OnUnload()
print("test-qlink-latency: PASS")
