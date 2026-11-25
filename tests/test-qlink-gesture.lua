-- tests/test-qlink-gesture.lua: the Q-Link gesture engine (task T1).
--   1. slow turn: one detent every two ticks (<= 2 detents / 150 ms) -> exactly
--      +1 position per detent, one Twist per detent, one Touch, gain stays 1;
--   2. fast flick: 12 detents in 2 ticks -> total within [12, 12 * maxMult] and
--      below the retired streak ramp (41 for 12 consecutive detents), exactly
--      one Twist per tick after the immediate first detent;
--   3. ceiling: detents past 127 send no Twist, CCW still works, the settle
--      trace line records "clamped";
--   4. display: with read lag on, no screen text for the knob's value line is
--      ever empty, and the settle shows the device string;
--   5. settle: no SetPosition/SetValue in the normal path; a device-side move
--      behind the shadow logs the drift line once per Q-Link per session and
--      the shadow adopts the device position;
--   6. abs path: the 0/127 wrap yields a small delta, the first sighting is
--      absorbed, absUnitsPerDetent carries the fractional remainder;
--   7. stream lock: rel then abs on the same knob -> one step per detent, the
--      ignored stream logged once;
--   8. __LCXL3_IMMEDIATE = false: nothing twists before HandleTimer;
--   9. degrade: a Twist that errors falls back to SetValue/SetPosition, logged
--      once per Q-Link;
--  10. knob order unchanged (QLINK_ORDER); an unassigned Q-Link drives, shows
--      "-" (never blank) and keeps a dark ring.
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
mock.setQlinkTarget(12, "Cutoff") -- knob (0,0) = row 1 k1 (cc 77) = Q-Link index 12
L.HandleMIDICC(6, 30, 2) -- control mode
mock.runTicks(L, 4)

-- 1: slow turn -- <= 2 detents per 150 ms window stays at gain 1
mock.qlinkPositions[12] = 60
mock.clearCalls()
for _ = 1, 10 do
	mock.emitRel(0, 0, 1)
	mock.tick(L)
	mock.tick(L)
end
assert_eq(mock.count("Twist"), 10, "slow turn: one Twist per detent")
for _, t in ipairs(mock.find("Twist")) do
	assert_eq(t.args[2], 1, "slow turn: gain stays 1")
end
assert_eq(mock.qlinkPosition(12), 70, "slow turn: exactly +1 position per detent")
assert_eq(mock.count("Touch"), 1, "one Touch per gesture (no settle yet)")

-- 2: fast flick -- 12 detents in 2 ticks
mock.runTicks(L, 4) -- quiet closes the slow gesture
mock.qlinkPositions[12] = 10
mock.clearCalls()
for _ = 1, 2 do
	mock.emitRel(0, 0, 1)
	mock.emitRel(0, 0, 1)
	mock.emitRel(0, 0, 1)
	mock.emitRel(0, 0, 1)
	mock.emitRel(0, 0, 1)
	mock.emitRel(0, 0, 1)
	mock.tick(L)
end
local total = mock.qlinkPosition(12) - 10
assert_eq(mock.count("Twist"), 3, "first detent immediate, then one coalesced Twist per tick")
assert(total >= 12, "the flick covers its detents")
assert(total <= 12 * 4, "the flick stays within 12 * maxMult")
assert(total < 41, "the flick stays under the retired ramp (12 consecutive detents = 41)")

-- 3: ceiling -- clamped at 127, CCW still works, trace says clamped
mock.runTicks(L, 4) -- settle the flick
mock.qlinkPositions[12] = 125
mock.clearCalls()
for _ = 1, 4 do
	mock.emitRel(0, 0, 1)
	mock.tick(L)
end
assert_eq(mock.qlinkPosition(12), 127, "the shadow clamps at 127")
assert_eq(mock.count("Twist"), 2, "detents past the ceiling send no Twist")
mock.runTicks(L, 4) -- settle logs the gesture trace
assert_eq(logCount(" clamped"), 1, "the trace line records the clamp")
mock.emitRel(0, 0, -1)
mock.tick(L)
assert_eq(mock.qlinkPosition(12), 126, "CCW still works from the ceiling")

-- 4: display never blanks, even with the device's one-change read lag
mock.setReadLag(1)
mock.qlinkPositions[12] = 20
mock.runTicks(L, 2)
mock.clearCalls()
for _ = 1, 2 do
	mock.emitRel(0, 0, 2)
	mock.emitRel(0, 0, 2)
	mock.tick(L)
end
mock.runTicks(L, 40) -- through the settle and the 2-texts-per-tick pump backlog
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 13 and s.field == 2 then
		if s.text == "" then
			error("display: an empty value line was sent for the Q-Link knob")
		end
	end
end
local lastVal
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 13 and s.field == 2 then
		lastVal = s.text
	end
end
assert_eq(
	lastVal,
	math.floor(mock.qlinkPosition(12) / 127 * 100 + 0.5) .. "%",
	"the settle shows the device value string"
)
mock.setReadLag(0)

-- 5: settle -- no parameter writes; device-side drift reported once, adopted
mock.clearCalls()
mock.qlinkPositions[12] = 60
mock.emitRel(0, 0, 1)
mock.tick(L)
mock.emitRel(0, 0, 1)
mock.tick(L)
mock.emitRel(0, 0, 1)
mock.tick(L)
mock.qlinkPositions[12] = 30 -- the device jumps behind the shadow while quiet
mock.runTicks(L, 3) -- the settle re-read lands on the moved device
assert_eq(mock.count("SetPosition"), 0, "no SetPosition in the normal path")
assert_eq(mock.count("SetValue"), 0, "no SetValue in the normal path")
assert_eq(logCount("drift"), 1, "the drift line is logged once for this Q-Link")
mock.clearCalls()
mock.emitRel(0, 0, 1)
mock.tick(L)
assert_eq(mock.qlinkPosition(12), 31, "the settle adopted the device position as the new base")

-- 5b: settle re-arm -- a detent inside gapTicks joins a gesture the timer may
-- already have settled (cadence == settleTicks == gapTicks == 3): every tail
-- detent must re-arm the settle pass, or the gesture's final detents never
-- get the drift check, the closing Touch and the final display sync.
mock.runTicks(L, 4) -- age the previous gesture out
mock.clearCalls()
mock.qlinkPositions[12] = 40
mock.emitRel(0, 0, 1) -- detent 1: fresh gesture (seed read + Touch)
mock.runTicks(L, 3) -- exactly the settle gap: the timer settles between detents
mock.emitRel(0, 0, 1) -- detent 2 joins the already-settled gesture (gap == gapTicks)
mock.runTicks(L, 3)
mock.emitRel(0, 0, 1) -- detent 3 at the same 3-tick cadence
mock.runTicks(L, 3) -- one settle must run after the FINAL detent
assert_eq(mock.count("GetPosition"), 4, "each tail detent re-arms the settle (3 settles + 1 seed read)")
assert_eq(mock.count("Touch"), 4, "each settle closes with a Touch (3 closes + 1 gesture start)")
assert_eq(mock.qlinkPosition(12), 43, "the three-detent turn moved the device 3 positions")
-- the tail settle adopts the device position (fresh knob: the drift log is
-- once per Q-Link per session and qlink 12's was spent in section 5)
mock.setQlinkTarget(6, "Pan") -- knob (1,2) = row 2 k3 = Q-Link index 6
mock.qlinkPositions[6] = 50
mock.emitRel(1, 2, 1)
mock.runTicks(L, 3)
mock.emitRel(1, 2, 1) -- tail detent joins the already-settled gesture
mpc.controlSurface.qlinks[6].SetValue(20 / 127) -- the device jumps behind the tail detent
mock.runTicks(L, 3) -- the re-armed settle reads and adopts the device
assert_eq(logCount("qlink 6 drift"), 1, "the tail detent's settle re-ran and reported the drift")
mock.runTicks(L, 3) -- drain the screen pump
local lastVal6
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 23 and s.field == 2 then
		lastVal6 = s.text
	end
end
assert_eq(lastVal6, "16%", "the tail settle adopted the device position (device value string on screen)")

-- 6: absolute path -- wrap rule and the fractional remainder
mock.setQlinkTarget(4, "Drive") -- knob (0,2) = row 1 k3 = Q-Link index 4
mock.qlinkPositions[4] = 10
mock.clearCalls()
mock.emitAbs(0, 2, 2) -- first sighting: absorbed as the baseline
mock.tick(L)
assert_eq(mock.count("Twist"), 0, "abs first sighting is absorbed")
mock.emitAbs(0, 2, 127) -- delta +125 -> wraps to -3
mock.tick(L)
assert_eq(mock.count("Twist"), 1, "the wrap crossing 127 yields one small detent group")
assert_eq(mock.find("Twist")[1].args[2], -3, "125 counts over the seam wrap to -3 (no +125 spike)")
mock.emitAbs(0, 2, 1) -- delta -126 -> wraps to +2
mock.tick(L)
assert_eq(mock.find("Twist")[#mock.find("Twist")].args[2], 2, "126 counts under the seam wrap to +2")
-- fractional remainder: 2 abs units per detent, deltas of 1 accumulate
mock.setQlinkTarget(14, "Reso") -- knob (1,0) = row 2 k1 = Q-Link index 14
__LCXL3_QFEEL.absUnitsPerDetent = 2
mock.clearCalls()
mock.emitAbs(1, 0, 50) -- baseline
mock.tick(L)
mock.emitAbs(1, 0, 51) -- 0.5 detents: waits
mock.tick(L)
assert_eq(mock.count("Twist"), 0, "half a detent waits for the remainder")
mock.emitAbs(1, 0, 52) -- completes the detent
mock.tick(L)
assert_eq(mock.count("Twist"), 1, "the carried remainder completes the detent")
assert_eq(mock.find("Twist")[1].args[2], 1, "the completed remainder is one position")
__LCXL3_QFEEL.absUnitsPerDetent = 1

-- 7: stream lock -- rel first, abs ignored on the same physical knob
mock.setQlinkTarget(10, "Locky") -- knob (1,1) = row 2 k2 = Q-Link index 10
mock.qlinkPositions[10] = 64
mock.clearCalls()
mock.emitRel(1, 1, 1) -- rel acts and latches the knob
mock.tick(L)
assert_eq(mock.count("Twist"), 1, "the rel detent steps once")
local p10 = mock.qlinkPosition(10)
mock.emitAbs(1, 1, 90) -- first abs sighting: baseline only
mock.tick(L)
mock.emitAbs(1, 1, 93) -- would be +3 if the abs stream were followed
mock.tick(L)
assert_eq(mock.count("Twist"), 1, "one step per detent: the abs stream is ignored")
assert_eq(mock.qlinkPosition(10), p10, "the ignored abs event moved nothing")
assert_eq(logCount("abs stream ignored"), 1, "the ignored stream is logged once")

-- 8: the proven fallback timing -- nothing twists before HandleTimer
_G.__LCXL3_IMMEDIATE = false
dofile(os.getenv("LCXL3_LUA") or "script/LaunchControlXL3.lua")
L.OnLoad()
mock.reset()
mock.setQlinkTarget(12, "Cutoff")
mock.qlinkPositions[12] = 30
L.HandleMIDICC(6, 30, 2)
mock.runTicks(L, 4)
mock.clearCalls()
mock.emitRel(0, 0, 1)
mock.emitRel(0, 0, 1)
assert_eq(mock.count("Twist"), 0, "IMMEDIATE=false: nothing twists before the timer")
mock.tick(L)
assert_eq(mock.count("Twist"), 1, "the timer flush coalesces both detents")
assert_eq(mock.find("Twist")[1].args[2], 2, "the coalesced delta is +2")

-- 9: degrade -- a Twist that errors falls back, logged once per Q-Link
mock.setTwistNoEffect(true)
mock.qlinkPositions[12] = 50
mock.clearCalls()
mock.emitRel(0, 0, 1)
mock.tick(L)
mock.emitRel(0, 0, 1)
mock.tick(L)
assert_eq(mock.count("SetValue") >= 1, true, "no-effect Twist falls back to SetValue")
assert_eq(mock.count("SetPosition") >= 1, true, "the degrade syncs the knob with SetPosition")
assert_eq(logCount("SetValue/SetPosition fallback"), 1, "the degrade is logged once per Q-Link")
mock.setTwistNoEffect(false)

-- 10: knob order unchanged; unassigned Q-Link drives, shows "-", ring dark
mock.clearCalls()
mock.setQlinkTarget(8, false) -- explicitly unassigned Q-Link
mock.emitRel(0, 1, 1) -- knob (0,1) = row 1 k2 = QLINK_ORDER[2] = 8
mock.runTicks(L, 40) -- let the settle and the screen pump drain
local t10 = mock.find("Twist")
assert_eq(#t10, 1, "the unassigned Q-Link still drives (no input name gate)")
assert_eq(t10[1].args[1], 8, "row 1 k2 targets Q-Link 9 (QLINK_ORDER unchanged)")
local dash = false
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 14 and s.field == 2 and s.text == "-" then
		dash = true
	end
end
assert_eq(dash, true, "an unassigned Q-Link shows '-' (never an empty value line)")
assert_eq(mock.leds[14], "0,0,0", "an unassigned Q-Link ring stays dark")

mock.setReadLag(0)
mock.reset()
L.OnUnload()
_G.print = realPrint
print("test-qlink-gesture: PASS")
