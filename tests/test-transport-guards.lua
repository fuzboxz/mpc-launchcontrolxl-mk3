-- tests/test-transport-guards.lua: the double-press gates and the doRecord
-- overdub guard. Quick Shift+Record / Shift+Play pairs must never fall into the
-- plain double-press branches (no RecordOff, no rewind, playback untouched),
-- while the plain pairs keep their documented tap-tempo/rewind behaviour. A
-- record press while overdub-only is active must not call RecordOff.
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

-- Sequencer state outlives OnLoad; reset it so each scenario starts clean.
local function resetSeq()
	mock.mpc.sequencer.Playing:set(false)
	mock.mpc.sequencer.RecordState:set(0)
	mock.mpc.sequencer.OverdubState:set(0)
end

-- Shift+Record twice inside the 350 ms window: two overdub presses, never the
-- plain double-press branch (which would RecordOff and, with overdub raised,
-- stop playback).
L.OnLoad()
mock.reset()
resetSeq()
mock.mpc.sequencer.Playing:set(true)
L.HandleMIDICC(6, 63, 127) -- Shift down
L.HandleMIDICC(0, 118, 127) -- Shift+Record = overdub
ticks(3) -- inside the double-press window
L.HandleMIDICC(0, 118, 127) -- second Shift+Record
L.HandleMIDICC(6, 63, 0) -- Shift up
assert_eq(mock.count("RecordOff"), 0, "quick Shift+Record pair never calls RecordOff")
assert_eq(mock.count("Overdub"), 2, "both shift presses overdub")
assert_eq(mock.mpc.sequencer.Playing.value, true, "quick Shift+Record pair does not stop playback")

-- Shift+Play twice inside the window: two shift-presses (stop all clips), never
-- the plain rewind branch.
L.OnLoad()
mock.reset()
resetSeq()
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 116, 127) -- Shift+Play while stopped = stop all clips
ticks(3)
L.HandleMIDICC(0, 116, 127) -- second Shift+Play
L.HandleMIDICC(6, 63, 0)
assert_eq(mock.count("JumpToBeginning"), 0, "quick Shift+Play pair never rewinds")
assert_eq(mock.count("StopAllClips"), 2, "both shift presses stop all clips")

-- Plain Record twice >= 350 ms apart still toggles: Record then RecordOff.
L.OnLoad()
mock.reset()
resetSeq()
L.HandleMIDICC(0, 118, 127) -- arm
ticks(8) -- outside the double-press window
L.HandleMIDICC(0, 118, 127) -- disarm
assert_eq(mock.count("RecordOff"), 1, "a slow second Record press toggles record off")
assert_eq(mock.mpc.sequencer.RecordState.value, 0, "record is off after the slow toggle")

-- Plain Record double-press still taps tempo and reverts the accidental arm.
L.OnLoad()
mock.reset()
resetSeq()
L.HandleMIDICC(0, 118, 127) -- arm
ticks(3)
L.HandleMIDICC(0, 118, 127) -- double-press
assert_eq(mock.count("tapTempo.Press"), 1, "quick Record pair taps tempo")
assert_eq(mock.count("RecordOff"), 1, "quick Record pair reverts the accidental arm")
assert_eq(mock.mpc.sequencer.RecordState.value, 0, "record is off after the tap")

-- Shift+Record while overdub-only recording (OverdubState=1, RecordState=0,
-- playing): dropping overdub directly can STOP PLAYBACK (device-observed).
-- The guard arms full record first, then toggles overdub.
mock.reset()
resetSeq()
mock.mpc.sequencer.Playing:set(true)
mock.mpc.sequencer.OverdubState:set(1)
mock.mpc.sequencer.RecordState:set(0)
L.HandleMIDICC(6, 63, 127) -- Shift down
L.HandleMIDICC(0, 118, 127) -- Shift+Record = overdub
L.HandleMIDICC(6, 63, 0) -- Shift up
assert_eq(mock.count("Record") >= 1, true, "overdub-only guard arms full record")
assert_eq(mock.count("Overdub") >= 1, true, "then toggles overdub (playback held)")
resetSeq()
mock.clearCalls()

-- doRecord while overdub-only (OverdubState=1, Playing=1, RecordState=1) must
-- not call RecordOff (it would stop playback); the guard arms full record.
L.OnLoad()
mock.reset()
resetSeq()
mock.mpc.sequencer.OverdubState:set(1)
mock.mpc.sequencer.RecordState:set(1)
mock.mpc.sequencer.Playing:set(true)
ticks(10) -- outside the double-press window
mock.clearCalls()
L.HandleMIDICC(0, 118, 127)
assert_eq(mock.count("RecordOff"), 0, "overdub-only record press never calls RecordOff")
assert_eq(mock.count("Record"), 1, "overdub-only record press arms full record instead")
assert_eq(mock.mpc.sequencer.Playing.value, true, "overdub-only record press keeps playback running")

L.OnUnload()
_G.print = realPrint
print("test-transport-guards: PASS")
