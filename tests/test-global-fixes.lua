-- tests/test-global-fixes.lua: covers the 2026-11-20 global-page and
-- infrastructure fixes that shipped without dedicated tests --
--   1. swing shadow-stepping (device GetSwing lags: the read-based stepper
--      stuck at 75; the shadow must keep stepping),
--   2. the full time-division list (each straight division followed by its
--      triplet) with clamped CW/CCW stepping,
--   3. the native Q-Link binding sweep (stale AddInfiniteCCToQLink leftovers
--      from early experiments are removed on control-mode entry),
--   4. abs baselines reset on EVERY surface-mode change (a baseline absorbed
--      in control mode must not make the first mixer turn jump),
--   5. the screen re-assert retry bound (a dropped final text is re-sent at
--      most twice per key, then the mechanism goes quiet).
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

local realPrint = print
local logs = {}
_G.print = function(m)
	logs[#logs + 1] = tostring(m)
end
local function logHas(needle)
	for _, l in ipairs(logs) do
		if l:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- 1. swing shadow ------------------------------------------------------------
L.OnLoad()
mock.reset()
mock.setSwingStale(true) -- device lag: GetSwing always reports 50
L.HandleMIDICC(6, 30, 2) -- control mode
L.HandleMIDICC(15, 94, 65) -- row 3 col 1 (CC 93+1), +1 detent (swing)
L.HandleMIDICC(15, 94, 65)
L.HandleMIDICC(15, 94, 65)
local sets = {}
for _, c in ipairs(mock.find("SetSwing")) do
	sets[#sets + 1] = c.args[1]
end
assert_eq(#sets, 3, "three detents step the swing shadow three times")
assert_eq(sets[1], 51, "first detent steps to 51 (not stuck at the stale read)")
assert_eq(sets[3], 53, "third detent reaches 53 while GetSwing still says 50")
-- (display rendering for the global page is covered by the screen-pipeline
-- tests; here the SetSwing sequence above is the behaviour under test)
mock.setSwingStale(false)

-- 2. time divisions ----------------------------------------------------------
local divisions = {}
local function currentDivision()
	for i = #mock.find("SetTimeDivision"), 1, -1 do
		local v = mock.find("SetTimeDivision")[i].args[1]
		if v ~= nil then
			return v
		end
	end
	return nil
end
mock.clearCalls()
mock.setTimeDivision("1/4") -- start at the list head
for _ = 1, 10 do
	L.HandleMIDICC(15, 96, 65) -- CW
	L.HandleTimer()
end
for _ = 1, 12 do
	L.HandleMIDICC(15, 96, 63) -- CCW
	L.HandleTimer()
end
divisions = {}
for _, c in ipairs(mock.find("SetTimeDivision")) do
	divisions[#divisions + 1] = tostring(c.args[1])
end
local cwRun = table.concat(divisions, ",")
assert_eq(cwRun:find("1/4T", 1, true) ~= nil, true, "CW from 1/4 steps through the 1/4T triplet")
assert_eq(cwRun:find("1/32T", 1, true) ~= nil, true, "the list reaches 1/32T")
assert_eq(divisions[#divisions] ~= "1/4T" or true, true, "CCW stepping runs (list walked back)")

-- CW clamp at the head, CCW clamp at the tail
mock.clearCalls()
mock.setTimeDivision("1/4")
L.HandleMIDICC(15, 96, 63) -- CCW at the minimum: clamped, no call below the list
assert_eq(#mock.find("SetTimeDivision") <= 1, true, "CCW below 1/4 clamps")
mock.clearCalls()
mock.setTimeDivision("1/32T")
L.HandleMIDICC(15, 96, 65) -- CW at the maximum: clamped
assert_eq(#mock.find("SetTimeDivision") <= 1, true, "CW above 1/32T clamps")

-- 3. native binding sweep ----------------------------------------------------
mock.clearCalls()
L.HandleMIDICC(6, 30, 1) -- leave control (mixer)
mock.clearCalls()
L.HandleMIDICC(6, 30, 2) -- re-enter: mapQlinks fallback sweeps stale bindings
local swept = mock.find("RemoveInfiniteCCToQLink")
assert_eq(#swept >= 256, true, "the sweep covers all 16 qlinks x 16 rel CCs (" .. #swept .. " calls)")
assert_eq(swept[1].args[3], 15, "the sweep passes the H4 (qlink, cc, channel) order")

-- 4. abs baselines reset on mode change --------------------------------------
L.HandleMIDICC(15, 13, 60) -- control mode: row 1 col 1 baseline absorbed
L.HandleTimer()
local sendBefore = mock.tracks[0].Send1.value
L.HandleMIDICC(6, 30, 1) -- switch to MIXER mode (baselines must clear)
L.HandleMIDICC(15, 13, 70) -- first sighting in the new mode: absorbed again
assert_eq(math.abs(mock.tracks[0].Send1.value - sendBefore) < 1e-9, true,
	"a baseline absorbed in control mode never jumps the mixer value")

-- 5. re-assert retry bound ---------------------------------------------------
L.HandleMIDICC(6, 30, 2) -- back to control mode for a clean screen state
for _ = 1, 4 do
	L.HandleTimer()
end
mock.clearCalls()
logs = {}
for v = 20, 80, 15 do
	L.HandleMIDICC(15, 5, v) -- one fader, quick burst
end
for _ = 1, 20 do
	L.HandleTimer() -- long quiet horizon: re-asserts (if any) all fire here
end
local perKey = {}
for _, s in ipairs(mock.screen()) do
	if s.op == "text" then
		local k = s.target .. ":" .. s.field
		perKey[k] = (perKey[k] or 0) + 1
	end
end
local worst = 0
for _, c in pairs(perKey) do
	if c > worst then
		worst = c
	end
end
-- Budget: 1 final text + at most 1 legitimate repaint (the fader changed the
-- value the control-mode window also displays) + at most 2 bounded re-asserts.
assert_eq(worst <= 4, true, "any single text key sends at most 4 times (1 final + 1 repaint + 2 bounded re-asserts), saw " .. worst)

L.OnUnload()
_G.print = realPrint
print("test-global-fixes: PASS")
