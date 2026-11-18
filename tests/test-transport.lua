-- tests/test-transport.lua: play/stop, record, overdub, and the LED feedback
-- driven by the sequencer's own state.
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

L.OnLoad()
mock.reset()

-- Play: TogglePlay while stopped.
L.HandleMIDICC(0, 116, 127)
assert_eq(mock.count("TogglePlay"), 1, "play pressed TogglePlay")
assert_eq(mock.count("Play"), 0, "Play not needed when TogglePlay exists")
-- The Playing listener marks a repaint; the timer paints it.
L.HandleTimer()
assert_eq(mock.leds[116], "8,127,20", "play LED green while playing")

-- Play while playing -> Stop (ticks first: not a double-press).
for _ = 1, 10 do
	L.HandleTimer()
end
L.HandleMIDICC(0, 116, 127)
assert_eq(mock.count("Stop"), 1, "play while playing stops")
L.HandleTimer()
assert_eq(mock.leds[116], "0,22,5", "play LED dim green while stopped")

-- Shift + play = stop (explicit).
for _ = 1, 10 do
	L.HandleTimer()
end
mock.mpc.sequencer.Playing:set(true)
L.HandleTimer()
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 116, 127)
assert_eq(mock.count("Stop"), 2, "shift+play stops")
L.HandleMIDICC(6, 63, 0)

-- Record: arms via Record, disarms via RecordOff (ticks between presses).
mock.reset()
for _ = 1, 10 do
	L.HandleTimer()
end
L.HandleMIDICC(0, 118, 127)
assert_eq(mock.count("Record"), 1, "record armed")
L.HandleTimer()
assert_eq(mock.leds[118], "127,4,4", "record LED red while armed")
for _ = 1, 10 do
	L.HandleTimer()
end
L.HandleMIDICC(0, 118, 127)
assert_eq(mock.count("RecordOff"), 1, "record disarmed")
L.HandleTimer()
assert_eq(mock.leds[118], "24,0,0", "record LED dim red while unarmed")

-- Shift + record = overdub (ticks first).
for _ = 1, 10 do
	L.HandleTimer()
end
L.HandleMIDICC(6, 63, 127)
L.HandleMIDICC(0, 118, 127)
assert_eq(mock.count("Overdub"), 1, "shift+record overdubs")
L.HandleMIDICC(6, 63, 0)

-- Record LED follows RecordState even when changed elsewhere.
mock.mpc.sequencer.RecordState:set(1)
L.HandleTimer()
assert_eq(mock.leds[118], "127,4,4", "record LED follows an external record state")

L.OnUnload()
_G.print = realPrint
print("test-transport: PASS")
