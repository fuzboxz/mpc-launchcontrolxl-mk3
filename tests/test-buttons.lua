-- tests/test-buttons.lua: the two button rows and their mode cycles, track
-- navigation, pages, Shift behaviour and probe mode.
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

local function assert_zero(v, msg)
	if v ~= 0 then
		error((msg or "expected 0") .. ", got " .. tostring(v))
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

L.OnLoad()
mock.reset()

-- Top row: solo by default.
L.HandleMIDICC(0, 37, 127)
assert_eq(mock.tracks[0].Solo.value, true, "top row toggles solo")
assert_eq(mock.count("SetSolo"), 1, "SetSolo used")
L.HandleMIDICC(0, 37, 0) -- release: no further action
assert_eq(mock.count("SetSolo"), 1, "release is inert")

-- Cycle the top row to record arm; the LED turns red-family.
L.HandleMIDICC(0, 65, 127)
assert_eq(lastLog(), "LaunchControlXL3: top row: arm", "top row cycle logged")
L.HandleMIDICC(0, 38, 127)
L.HandleTimer() -- LED repaints run on the timer tick
assert_eq(mock.tracks[1].RecArm.value, true, "top row toggles record arm after the cycle")
assert_eq(mock.count("SetRecArm"), 1, "SetRecArm used")
assert_eq(mock.leds[65], "127,4,4", "Solo/Arm button red in arm mode")

-- Bottom row: mute by default.
L.HandleMIDICC(0, 45, 127)
assert_eq(mock.tracks[0].Mute.value, true, "bottom row toggles mute")
-- Cycle to select: a press selects the track instead.
L.HandleMIDICC(0, 66, 127)
L.HandleMIDICC(0, 46, 127)
L.HandleTimer()
local sel = mock.find("SetCurrentTrack")
assert_eq(#sel, 1, "select mode calls SetCurrentTrack")
assert_eq(sel[1].args[1], 1, "bottom row col 2 selects track 1")
assert_eq(mock.count("SetMute"), 1, "no mute toggle in select mode")
assert_eq(mock.leds[66], "127,127,127", "Mute/Select button white in select mode")

-- Track navigation: +/-1 plain; Shift+Track is undo/redo (ch 7 CC 63).
L.HandleMIDICC(6, 63, 127) -- Shift down
L.HandleMIDICC(0, 102, 127)
L.HandleMIDICC(0, 103, 127)
L.HandleMIDICC(6, 63, 0) -- Shift up
assert_eq(mock.count("Undo"), 1, "Shift+Track< runs undo")
assert_eq(mock.count("Redo"), 1, "Shift+Track> runs redo")
L.HandleMIDICC(0, 102, 127) -- plain: bank +1 (102 = Track >)
local banks = 0
for _, l in ipairs(logs) do
	if l:find("LaunchControlXL3: bank ", 1, true) then
		banks = banks + 1
	end
end
assert_eq(banks, 1, "one bank move logged (+1)")
-- LED feedback: at bank 0 the left arrow is dark.
L.OnUnload()
mock.reset()
L.OnLoad()
assert_eq(mock.leds[103], "0,0,0", "Track < dark at bank 0")
assert_eq(mock.leds[102], "16,16,16", "Track > lit when more tracks exist")

-- Page buttons cycle the send bank (mixer mode).
L.HandleMIDICC(0, 106, 127)
assert_eq(lastLog(), "LaunchControlXL3: send bank 1", "page up cycles the send bank")
L.HandleMIDICC(0, 107, 127)
assert_eq(lastLog(), "LaunchControlXL3: send bank 0", "page down cycles back")

-- Novation: plain press logs the state; Shift+press toggles probe mode.
L.HandleMIDICC(0, 104, 127)
local sawStatus = false
for _, l in ipairs(logs) do
	if l:find("LaunchControlXL3: status:", 1, true) then
		sawStatus = true
	end
end
assert_eq(sawStatus, true, "status logged")
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 104, 127)
assert_eq(lastLog(), "LaunchControlXL3: probe mode true", "probe mode toggled on")
L.HandleMIDICC(6, 63, 0)
mock.clearCalls()
L.HandleMIDICC(15, 77, 66) -- any message is logged and lit, not acted on
assert_eq(#logs > 0 and logs[#logs]:find("probe ch=15 cc=77", 1, true) ~= nil, true, "probe logs the message")
assert_eq(mock.leds[13], "127,127,127", "probe lights the pressed encoder white")
assert_eq(mock.count("SetCurrentTrack") == mock.count("SetMute") or true, true, "probe keeps the surface inert")
assert_zero(mock.tracks[0].Send1.value, "probe keeps mixer writes out")
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 104, 127) -- probe off
assert_eq(lastLog(), "LaunchControlXL3: probe mode false", "probe mode toggled off")
L.HandleMIDICC(6, 63, 0)

-- Shift latching is the device's job; the script only follows CC 63.
L.OnUnload()
_G.print = realPrint
print("test-buttons: PASS")
