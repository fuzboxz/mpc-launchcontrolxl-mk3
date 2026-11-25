-- tests/test-overdub-clean.lua: T4 (F10 record-LED flash on overdub off).
-- The default doOverdub sequence stays byte-identical (guarded Record+Overdub
-- for overdub-only, plain Overdub otherwise); the F10 journal logs the raw
-- transport numbers before every toggle and two ticks after (one pending
-- toggle max); the opt-in __LCXL3_OD_CLEAN path toggles plainly without the
-- Record pre-arm, verifies playback two ticks later, resumes once and latches
-- __LCXL3_OD_GUARD so later presses take the proven guarded path. The mock
-- defect (Overdub() od-off also stops playback) is opt-in via
-- mock.setOverdubToggleStopsPlayback(true).
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

local function logsCount(pat)
	local n = 0
	for _, l in ipairs(logs) do
		if string.find(l, pat, 1, true) then
			n = n + 1
		end
	end
	return n
end

local function ticks(n)
	for _ = 1, n do
		mock.runTicks(L, 1)
	end
end

-- Names of every sequencer call since the last clearCalls, in order.
local function seq()
	local out = {}
	for _, c in ipairs(mock.calls) do
		out[#out + 1] = c.name
	end
	return out
end

local function assertSeq(want, msg)
	local got = table.concat(seq(), ",")
	local exp = table.concat(want, ",")
	if got ~= exp then
		error((msg or "") .. ": expected calls [" .. exp .. "], got [" .. got .. "]")
	end
end

-- Each scenario starts from a fresh load and clean sequencer state.
local function fresh()
	L.OnLoad()
	mock.reset()
	logs = {}
	mock.mpc.sequencer.Playing:set(false)
	mock.mpc.sequencer.RecordState:set(0)
	mock.mpc.sequencer.OverdubState:set(0)
end

local function shiftDown()
	L.HandleMIDICC(6, 63, 127)
end

local function shiftUp()
	L.HandleMIDICC(6, 63, 0)
end

-- overdub-only recording (device-observed defect state: OverdubState=1,
-- RecordState=0) with playback running.
local function odOnlyPlaying()
	mock.mpc.sequencer.Playing:set(true)
	mock.mpc.sequencer.OverdubState:set(1)
	mock.mpc.sequencer.RecordState:set(0)
end

-- 1. Default path byte-identical: guarded Record+Overdub for overdub-only,
--    plain Overdub otherwise, whatever __LCXL3_OD_CLEAN's absence.
fresh()
odOnlyPlaying()
mock.clearCalls()
shiftDown()
L.HandleMIDICC(0, 118, 127) -- Shift+Record = overdub
shiftUp()
assertSeq({ "Record", "Overdub" }, "default od-only toggle arms record first")
assert_eq(mock.count("Play"), 0, "default path never calls Play")
assert_eq(mock.mpc.sequencer.Playing.value, true, "default guarded path holds playback")
assert_eq(mock.mpc.sequencer.RecordState.value, 1, "default guarded path leaves full record armed")
assert_eq(mock.mpc.sequencer.OverdubState.value, 0, "default path drops overdub")

fresh()
mock.clearCalls()
shiftDown()
L.HandleMIDICC(0, 118, 127) -- overdub off -> plain toggle raises it (no record state)
shiftUp()
assertSeq({ "Overdub" }, "default path from a clean state is one plain Overdub")
assert_eq(mock.count("Record"), 0, "clean-state toggle never pre-arms record")

fresh()
mock.mpc.sequencer.Playing:set(true)
mock.mpc.sequencer.OverdubState:set(1)
mock.mpc.sequencer.RecordState:set(1) -- full record already armed: no guard needed
mock.clearCalls()
shiftDown()
L.HandleMIDICC(0, 118, 127)
shiftUp()
assertSeq({ "Overdub" }, "overdub+record state toggles plainly by default")

-- 2. F10 journal: before line at the toggle, after line two ticks later,
--    bound to one pending toggle.
fresh()
odOnlyPlaying()
shiftDown()
L.HandleMIDICC(0, 118, 127)
shiftUp()
assert_eq(logsCount("overdub: before rec=0 od=1 play=true"), 1, "before line logs the raw numbers")
assert_eq(logsCount("overdub: after"), 0, "after line waits two ticks")
ticks(3)
assert_eq(
	logsCount("overdub: after  rec=1 od=0 play=true"),
	1,
	"after line logs the raw numbers two ticks later"
)
-- one pending toggle max: a quick second toggle re-arms, only one after line.
shiftDown()
L.HandleMIDICC(0, 118, 127) -- overdub raises again
L.HandleMIDICC(0, 118, 127) -- and drops again before any tick
shiftUp()
ticks(3)
assert_eq(logsCount("overdub: before"), 3, "every toggle logs its before line")
assert_eq(logsCount("overdub: after"), 2, "a re-armed watch logs exactly one after line")

-- 3. Opt-in clean path, mock defect OFF: one plain Overdub, no Record, no
--    Play, guard never latches.
fresh()
_G.__LCXL3_OD_CLEAN = true
odOnlyPlaying()
mock.setOverdubToggleStopsPlayback(false)
mock.clearCalls()
shiftDown()
L.HandleMIDICC(0, 118, 127)
shiftUp()
assertSeq({ "Overdub" }, "clean path toggles overdub only")
assert_eq(mock.count("Record"), 0, "clean path never pre-arms record")
ticks(3)
assert_eq(mock.count("Play"), 0, "clean path without the defect never resumes playback")
assert_eq(_G.__LCXL3_OD_GUARD, false, "guard stays unlatched without the defect")
assert_eq(mock.mpc.sequencer.Playing.value, true, "playback untouched without the defect")
assert_eq(mock.mpc.sequencer.OverdubState.value, 0, "clean path still drops overdub")

-- 4. Opt-in clean path, mock defect ON: playback drops, the two-tick check
--    resumes it once and latches the guard; the next press takes the guarded
--    path.
fresh()
_G.__LCXL3_OD_CLEAN = true
odOnlyPlaying()
mock.setOverdubToggleStopsPlayback(true)
shiftDown()
L.HandleMIDICC(0, 118, 127)
shiftUp()
assert_eq(mock.count("Record"), 0, "clean path never pre-arms record (defect on)")
assert_eq(mock.count("Play"), 0, "the resume waits for the two-tick check")
assert_eq(mock.mpc.sequencer.Playing.value, false, "the defect stops playback before the check")
ticks(3)
assert_eq(mock.count("Play"), 1, "the two-tick check resumes playback exactly once")
assert_eq(_G.__LCXL3_OD_GUARD, true, "the proven drop latches the guard")
assert_eq(mock.mpc.sequencer.Playing.value, true, "playback is running again")
assert_eq(logsCount("latched __LCXL3_OD_GUARD"), 1, "the resume logs once")

-- second press with the guard latched: proven guarded path, playback held.
-- (calls recorded before the clear are gone, so assert on NEW calls only.)
mock.mpc.sequencer.OverdubState:set(1)
mock.mpc.sequencer.RecordState:set(0)
mock.clearCalls()
shiftDown()
L.HandleMIDICC(0, 118, 127)
shiftUp()
assertSeq({ "Record", "Overdub" }, "latched guard takes the guarded path")
ticks(3)
assert_eq(mock.count("Play"), 0, "the guarded path needs no resume (no new Play)")
assert_eq(mock.mpc.sequencer.Playing.value, true, "the guarded path holds playback")
assert_eq(logsCount("latched __LCXL3_OD_GUARD"), 1, "the resume log stays one-shot")

-- 5. Ambiguous states go straight to the guarded path even when CLEAN is on:
--    overdub-only but stopped.
fresh()
_G.__LCXL3_OD_CLEAN = true
mock.mpc.sequencer.Playing:set(false)
mock.mpc.sequencer.OverdubState:set(1)
mock.mpc.sequencer.RecordState:set(0)
mock.clearCalls()
shiftDown()
L.HandleMIDICC(0, 118, 127)
shiftUp()
assertSeq({ "Record", "Overdub" }, "stopped overdub-only state stays guarded")
assert_eq(_G.__LCXL3_OD_GUARD, false, "the guarded path never latches the guard")

-- 6. OnLoad resets both globals and the pending watches.
_G.__LCXL3_OD_CLEAN = true
_G.__LCXL3_OD_GUARD = true
L.OnLoad()
assert_eq(_G.__LCXL3_OD_CLEAN, false, "OnLoad resets __LCXL3_OD_CLEAN")
assert_eq(_G.__LCXL3_OD_GUARD, false, "OnLoad resets __LCXL3_OD_GUARD")

L.OnUnload()
_G.print = realPrint
print("test-overdub-clean: PASS")
