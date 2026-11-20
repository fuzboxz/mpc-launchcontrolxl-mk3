-- tests/test-pan-scale.lua: fmtPan renders the device convention L..C..R with
-- a 50-point half-scale (not +/-100). The script does not export the helper, so
-- the assertion drives the mixer pan encoder to each extreme and reads the
-- encoder display text.
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

local function ticks(n)
	for _ = 1, n do
		L.HandleTimer()
	end
end

local function textOf(target, field)
	local last = nil
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" and s.target == target and s.field == field then
			last = s.text -- the latest write wins
		end
	end
	return last
end

L.OnLoad()
ticks(20) -- drain the initial display map
mock.reset()

-- Row 3 col 0 is the mixer pan encoder (target 29 = 13 + 2*8 + 0). Pan starts
-- centred at 0.5; each detent is 1/127.
assert_eq(mock.tracks[0].Pan.value, 0.5, "pan starts centred")

for _ = 1, 70 do
	L.HandleMIDICC(15, 93, 63) -- CCW
end
ticks(12)
assert_eq(mock.tracks[0].Pan.value, 0, "pan clamps hard left")
assert_eq(textOf(29, 2), "L50", "hard-left pan renders L50 (half-scale, not L100)")

for _ = 1, 140 do
	L.HandleMIDICC(15, 93, 65) -- CW
end
ticks(12)
assert_eq(mock.tracks[0].Pan.value, 1, "pan clamps hard right")
assert_eq(textOf(29, 2), "R50", "hard-right pan renders R50 (half-scale, not R100)")

L.OnUnload()
_G.print = realPrint
print("test-pan-scale: PASS")
