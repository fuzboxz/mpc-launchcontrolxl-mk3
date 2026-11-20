-- tests/test-qlink-latency.lua: the knob-latency overhaul.
--   1. a turn drives its Twist IMMEDIATELY in the MIDI context (no 50 ms
--      timer wait),
--   2. an active spin (streak >= 2) uses the fast path: exactly one Twist,
--      no per-detent read-backs (no GetPosition/GetValueString storm),
--   3. the ring/display is settled (SetPosition) once the spin goes quiet,
--      without writing the parameter (no SetValue nudge),
--   4. isolated detents (streak 1) still use the full proven driver,
--      fallback included.
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
for _ = 1, 4 do
	L.HandleTimer()
end
mock.clearCalls()

-- 1 + 4: isolated detent: full driver, IMMEDIATE (no HandleTimer yet)
mock.qlinkPositions[12] = 60
L.HandleMIDICC(15, 77, 65) -- row 1 col 1, +1
assert_eq(mock.count("Twist"), 1, "isolated detent twists immediately (MIDI context)")
assert_eq(mock.qlinkPosition(12), 61, "the detent applied before any timer tick")
assert_eq(mock.count("SetPosition"), 1, "full driver syncs the ring inline")
assert_eq(mock.count("GetValueString") >= 1, true, "full driver performs its read-back")

-- 2 + 3: a spin: second+ detents take the fast path
mock.clearCalls()
L.HandleMIDICC(15, 77, 66) -- +2, streak 2: fast
L.HandleMIDICC(15, 77, 66) -- +2, streak 3: fast
assert_eq(mock.count("Twist"), 2, "each spin detent twists exactly once")
assert_eq(mock.count("GetPosition"), 0, "no read-backs during the spin")
assert_eq(mock.count("GetValueString"), 0, "no value-string reads during the spin")
assert_eq(mock.count("SetPosition"), 0, "no ring sync mid-spin")
assert_eq(mock.qlinkPosition(12), 61 + 4 + 4, "both spin detents applied immediately (streak doubling: +2 detents x2 each)")
-- quiet: settle fires within 2 ticks and syncs without a parameter write
local setposBefore = mock.count("SetPosition")
for _ = 1, 3 do
	L.HandleTimer()
end
assert_eq(mock.count("SetPosition"), setposBefore + 1, "the settle syncs the ring once after quiet")
assert_eq(mock.count("SetValue"), 0, "the settle never writes the parameter")
assert_eq(mock.count("Twist"), 2, "the settle does not twist")

L.OnUnload()
print("test-qlink-latency: PASS")
