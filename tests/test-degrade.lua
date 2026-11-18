-- tests/test-degrade.lua: missing APIs must disable their surface, never crash.
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

-- 1. No mappings.controlSurface at all: control mode falls back to script-side
--    Twist, and everything else keeps working.
L.OnLoad()
mock.dev.mappings.controlSurface = nil
L.HandleMIDICC(6, 30, 2)
L.HandleMIDICC(15, 77, 66)
assert_eq(mock.count("Twist"), 1, "Twist fallback without the mapping API")
L.HandleMIDICC(6, 30, 1)

-- 2. No qlinks object: the Q-Link rows go dark and inert; transport survives.
local savedCS = mock.mpc.controlSurface
mock.mpc.controlSurface = nil
L.HandleMIDICC(6, 30, 2)
L.HandleMIDICC(15, 77, 66)
assert_eq(mock.count("Twist"), 1, "no Q-Link writes without mpc.controlSurface")
L.HandleMIDICC(0, 116, 127)
assert_eq(mock.count("TogglePlay") >= 1, true, "transport still works")
L.HandleMIDICC(6, 30, 1)
mock.mpc.controlSurface = savedCS

-- 3. No sequencer: transport buttons are inert, no crash.
local savedSeq = mock.mpc.sequencer
mock.mpc.sequencer = nil
L.HandleMIDICC(0, 116, 127)
L.HandleMIDICC(0, 118, 127)
mock.mpc.sequencer = savedSeq

-- 4. No project: project-scoped actions refuse with one log line, no calls.
local savedSeq2 = mock.mpc.sequencer
local savedTracks = mock.mpc.tracks
local savedCurSeq = mock.mpc.currentSequence
mock.mpc.currentSequence = nil
mock.mpc.tracks = nil
mock.mpc.sequencer = nil
mock.reset()
L.OnUnload()
L.OnLoad()
mock.clearCalls()
L.HandleMIDICC(0, 116, 127)
local refused = false
for _, l in ipairs(logs) do
	if l:find("play: no project loaded", 1, true) then
		refused = true
	end
end
assert_eq(refused, true, "play refuses without a project")
mock.mpc.currentSequence = savedCurSeq
mock.mpc.tracks = savedTracks
mock.mpc.sequencer = savedSeq2

-- 5. A popup that owns the UI blocks project-scoped actions (native crash guard).
-- (ticks advance first: the scenario-4 play press must not read as a double-press)
for _ = 1, 10 do
	L.HandleTimer()
end
mock.mpc.engineMode.CurrentPopup:set("New Project")
mock.clearCalls()
local before = mock.count("TogglePlay")
L.HandleMIDICC(0, 116, 127)
assert_eq(mock.count("TogglePlay"), before, "no transport call while a dialog is open")
local blocked = false
for _, l in ipairs(logs) do
	if l:find("play: dialog open (New Project)", 1, true) then
		blocked = true
	end
end
assert_eq(blocked, true, "the refusal is logged once")
mock.mpc.engineMode.CurrentPopup:set("No Popup")

-- 6. Zero tracks: faders/encoders/buttons are inert, the script stays alive.
local savedCount = mock.mpc.tracks.Count
mock.mpc.tracks.Count = mock.prop(0)
L.HandleMIDICC(15, 5, 100)
L.HandleMIDICC(15, 77, 66)
L.HandleMIDICC(0, 37, 127)
L.HandleTimer()
mock.mpc.tracks.Count = savedCount

-- 7. Broken writes (read-only property) log once and continue.
L.OnUnload()
L.OnLoad()
local tr = mock.tracks[0]
tr.Volume = { value = tr.Volume.value } -- a plain table: listen/write will fail
local ok = pcall(function()
	L.HandleMIDICC(15, 5, 64)
	L.HandleMIDICC(15, 5, 100)
end)
assert_eq(ok, true, "a failing property write does not crash the handler")
tr.Volume = mock.prop(0.7)

L.OnUnload()
_G.print = realPrint
print("test-degrade: PASS")
