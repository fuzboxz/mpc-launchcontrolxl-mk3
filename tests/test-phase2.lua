-- tests/test-phase2.lua: scene launch, window scroll, tap/rewind double-presses,
-- stop-all, bar navigation, undo/redo and the position readout.
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

local function lastLog()
	return logs[#logs] or ""
end

local function ticks(n)
	for _ = 1, n do
		L.HandleTimer()
	end
end

L.OnLoad()
mock.reset()

-- Bottom row cycles only mute <-> select (scene launch was removed).
L.HandleMIDICC(0, 66, 127)
assert_eq(lastLog(), "LaunchControlXL3: bottom row: select", "bottom row cycles to select")
L.HandleMIDICC(0, 66, 127)
assert_eq(lastLog(), "LaunchControlXL3: bottom row: mute", "bottom row cycles back to mute")
assert_eq(#mock.find("TriggerRow"), 0, "no scene launch calls")

-- Double-press Record: reverts the record toggle, then taps tempo.
L.HandleMIDICC(0, 118, 127)
ticks(3)
L.HandleMIDICC(0, 118, 127)
assert_eq(mock.count("tapTempo.Press"), 1, "double Record taps tempo")
assert_eq(mock.count("tapTempo.Release"), 1, "tap releases the button")
assert_eq(mock.count("RecordOff"), 1, "the accidental arm is reverted")
assert_eq(mock.mpc.sequencer.RecordState.value, 0, "record is off after the tap")

-- A single Record press still toggles record (no revert, no tap).
ticks(10) -- outside the double-press window
local recBefore = mock.count("Record")
L.HandleMIDICC(0, 118, 127)
assert_eq(mock.count("Record"), recBefore + 1, "single record press records")
assert_eq(mock.count("RecordOff"), 1, "a single press is not reverted")
assert_eq(mock.count("tapTempo.Press"), 1, "a single press does not tap")

-- Double-press Play: rewind to start.
mock.mpc.sequencer.BarForward(3)
ticks(10)
L.HandleMIDICC(0, 116, 127)
ticks(3)
L.HandleMIDICC(0, 116, 127)
assert_eq(mock.count("JumpToBeginning"), 1, "double Play rewinds")
assert_eq(mock.count("Play") + mock.count("TogglePlay"), 1, "first press played, second only rewound")
assert_eq(mock.count("Stop"), 0, "the double-press does not stop playback")

-- Shift+Play while stopped: stop all clips.
mock.mpc.sequencer.Playing:set(false)
ticks(10)
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 116, 127)
L.HandleMIDICC(6, 63, 0)
assert_eq(mock.count("StopAllClips"), 1, "Shift+Play stops all clips when stopped")

-- Shift+Page in the mixer: bar navigation.
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 106, 127)
L.HandleMIDICC(6, 63, 0)
local bars = mock.find("BarForward")
assert_eq(#bars, 2, "Shift+Page up moves a bar forward (script call)")
assert_eq(bars[2].args[1], 1, "the script asks for exactly one bar")
assert_eq(#mock.find("send bank 1"), 0, "Shift+Page does not cycle sends here")

-- The fader displays name the track each column controls (the track map):
-- a rename must propagate to the fader display (the cache dedups unchanged text).
mock.tracks[0].Name:set("Kick")
for _ = 1, 12 do
	L.HandleTimer()
end
local sawKick = false
for _, m in ipairs(mock.screen()) do
	if m.op == "text" and m.target == 5 and m.field == 0 and m.text == "Kick" then
		sawKick = true
	end
end
assert_eq(sawKick, true, "fader 1 display follows its track's name")
L.HandleMIDICC(0, 102, 127) -- bank +1
for _ = 1, 12 do
	L.HandleTimer()
end
local sawBank = false
for _, m in ipairs(mock.screen()) do
	if m.op == "text" and m.target == 5 and m.field == 0 and m.text == "Track 1" then
		sawBank = true
	end
	if m.op == "text" and m.target == 54 and m.field == 1 and m.text:find("Track 1", 1, true) then
		sawBank = true
	end
end
assert_eq(sawBank, true, "bank move updates the fader display and overlay names tracks")

-- Novation press shows the track map overlay.
mock.reset()
L.HandleMIDICC(0, 104, 127)
for _ = 1, 3 do
	L.HandleTimer()
end
local nov = false
for _, m in ipairs(mock.screen()) do
	-- identical text may be cache-skipped, but the 7Fh re-show configure always fires
	if m.op == "configure" and m.target == 54 then
		nov = true
	end
end
assert_eq(nov, true, "Novation press re-shows the track overlay")
mock.reset()
L.HandleMIDICC(0, 104, 127) -- same content again: the overlay must still re-show
for _ = 1, 3 do
	L.HandleTimer()
end
local again = false
for _, m in ipairs(mock.screen()) do
	if m.op == "configure" and m.target == 54 and m.config == 127 then
		again = true
	end
end
assert_eq(again, true, "repeated identical overlays re-trigger (7Fh)")
mock.tracks[0].Name:set("Track 0")
L.HandleMIDICC(0, 103, 127) -- back to bank 0

-- Offset race regression: Index updates before Name (async on the device).
-- Learning must wait a tick; a stale Name must not flip the offset.
mock.currentTrack.Index:set(3) -- fires with Name still "Track 0" (stale)
mock.currentTrack.Name:set("Track 3") -- settles the pair
L.HandleTimer()
L.HandleMIDICC(0, 104, 127) -- status log carries the learned offset
local raceOk = false
for _, l in ipairs(logs) do
	if l:find("status: mode=mixer bank=0(ui 1-8)", 1, true) then
		raceOk = true
	end
end
assert_eq(raceOk, true, "stale-Name race does not corrupt the offset")

-- Global/normal track offset: when the UI numbers tracks with an offset
-- (project track 1 not mixable), labels and selections follow the UI numbers.
L.HandleMIDICC(0, 103, 127) -- back to bank 0 (the Novation block left it at 1)
mock.currentTrack.Index:set(1) -- global index 1 = normal 0 ("Track 0")
mock.currentTrack.Name:set("Track 0")
L.HandleMIDICC(0, 66, 127) -- select mode
L.HandleTimer()
assert_eq(mock.leds[45], "127,127,127", "highlight lands on the selected column, not one early")
L.HandleMIDICC(0, 45, 127) -- select column 1
local sel1 = mock.find("SetCurrentTrack")
assert_eq(#sel1 >= 1 and sel1[#sel1].args[1], 1, "select col 1 uses the GLOBAL index (offset 1)")

-- Overlay ordering: the trigger (config 7Fh) must come AFTER the overlay text,
-- otherwise the device shows the previous contents.
mock.reset()
L.HandleMIDICC(0, 102, 127) -- bank +1 -> overlay "tracks ..."
for _ = 1, 4 do
	L.HandleTimer()
end
local textPos, trigPos = nil, nil
for i, m in ipairs(mock.screen()) do
	if m.op == "text" and m.target == 54 and m.field == 0 and m.text:find("tracks", 1, true) then
		textPos = textPos or i
	end
	if m.op == "configure" and m.target == 54 and m.config == 127 then
		trigPos = trigPos or i
	end
end
assert_eq(textPos ~= nil and trigPos ~= nil and textPos < trigPos, true, "overlay text precedes its trigger")
L.HandleMIDICC(0, 103, 127) -- back to bank 0

-- The stationary screen shows the position and the transport state.
L.OnLoad() -- fresh caches so the screen lines are (re)sent, not deduped
ticks(12)
local sawPos, sawBpm = false, false
for _, m in ipairs(mock.screen()) do
	if m.op == "text" and m.target == 53 then
		if m.text:find("bar 2", 1, true) then
			sawPos = true
		end
		if m.text:find("120", 1, true) then
			sawBpm = true
		end
	end
end
assert_eq(sawPos, true, "screen shows the bar.beat position")
assert_eq(sawBpm, true, "screen shows the BPM/transport state")

L.OnUnload()
_G.print = realPrint
print("test-phase2: PASS")
