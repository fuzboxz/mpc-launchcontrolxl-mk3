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

-- 2. time divisions (T2 contract): ONE list step per TWO detents, saturating
--    at 1/4 and 1/32T (never a wrap), and a direction flip resets the
--    accumulator. Each phase opens with 7 quiet ticks (> STEP_QUIET = 6) so
--    the stepper drops any stale shadow and re-anchors from the device state
--    the phase sets; inside the quiet window the shadow legitimately wins.
local divisions
local function writtenDivisions()
	divisions = {}
	for _, c in ipairs(mock.find("SetTimeDivision")) do
		divisions[#divisions + 1] = tostring(c.args[1])
	end
	return divisions
end
local function detents(n, cc)
	for _ = 1, n do
		L.HandleMIDICC(15, 96, cc) -- row 3 col 3 (division), +-1 detent
		L.HandleTimer()
	end
end
mock.clearCalls()
mock.setTimeDivision("1/4") -- start at the list head
mock.runTicks(L, 7)
detents(5, 65) -- CW
writtenDivisions()
assert_eq(#divisions, 2, "five CW detents apply exactly two list steps (one per two detents)")
assert_eq(divisions[1], "1/4T", "the first full pair steps 1/4 -> 1/4T")
assert_eq(divisions[2], "1/8", "the second pair steps 1/4T -> 1/8")

detents(12, 65) -- saturate at the tail: four more pairs, then silent
writtenDivisions()
assert_eq(#divisions, 7, "twelve more detents add five steps then clamp at the tail")
assert_eq(divisions[#divisions], "1/32T", "the list saturates at 1/32T")
local tailSeen = 0
for _, d in ipairs(divisions) do
	if d == "1/32T" then
		tailSeen = tailSeen + 1
	end
end
assert_eq(tailSeen, 1, "1/32T is written once: saturation never wraps")

-- a direction flip resets the accumulator: after an odd CW detent a full CCW
-- pair still steps back (without the reset it would only cancel the residue)
mock.clearCalls()
mock.setTimeDivision("1/16")
mock.runTicks(L, 7)
detents(2, 65) -- full CW pair: write 1/16T
L.HandleMIDICC(15, 96, 65) -- fresh CW residue 1/2, no write
L.HandleMIDICC(15, 96, 63) -- flip: residue discarded, no write
L.HandleMIDICC(15, 96, 63) -- full CCW pair: write 1/16
writtenDivisions()
assert_eq(#divisions, 2, "the flip test writes once per full pair in each direction")
assert_eq(divisions[1], "1/16T", "the CW pair steps 1/16 -> 1/16T")
assert_eq(divisions[2], "1/16", "the CCW pair steps back to 1/16 (flip reset the accumulator)")

-- saturation is a NO-WRITE clamp at both ends (two full pairs each way)
mock.clearCalls()
mock.setTimeDivision("1/4")
mock.runTicks(L, 7)
detents(4, 63) -- CCW below 1/4
assert_eq(#mock.find("SetTimeDivision"), 0, "CCW below 1/4 clamps without a write")
mock.clearCalls()
mock.setTimeDivision("1/32T")
mock.runTicks(L, 7)
detents(4, 65) -- CW above 1/32T
assert_eq(#mock.find("SetTimeDivision"), 0, "CW above 1/32T clamps without a write")

-- 3. native binding sweep ----------------------------------------------------
mock.clearCalls()
L.HandleMIDICC(6, 30, 1) -- leave control (mixer)
mock.clearCalls()
L.HandleMIDICC(6, 30, 2) -- re-enter: mapQlinks fallback sweeps stale bindings
local queried = mock.find("IsQLinkMappedInfinite")
assert_eq(#queried == 24, true, "the sweep queries every honest (channel, cc) key, cc 77..100 (" .. #queried .. ")")
assert_eq(queried[1].args[1], 15, "the sweep uses Akai's channel-first (channel, cc) key")
assert_eq(queried[1].args[2], 77, "the sweep starts at the first relative CC")
assert_eq(mock.count("RemoveInfiniteCCToQLink"), 0, "nothing stored: the query-gated sweep removes only real bindings")

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
mock.clearSysex() -- measure THIS window only: earlier sections' display texts are not the re-assert contract
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
