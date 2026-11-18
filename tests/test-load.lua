-- tests/test-load.lua: session bring-up. DAW mode entry, feature controls, CC
-- registration per channel, display configuration, mode request, initial paint.
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

local function sentCC(ch, cc, value)
	for _, c in ipairs(mock.find("SendMIDICC")) do
		if c.args[1] == ch and c.args[2] == cc then
			if value == nil or c.args[3] == value then
				return true
			end
		end
	end
	return false
end

L.OnLoad()

-- DAW mode: both enable forms are sent (note 12 on ch 16 vel 127 + sysex 02 7F).
local noteOk = false
for _, n in ipairs(mock.notes) do
	if n.ch == 15 and n.note == 12 and n.vel == 127 then
		noteOk = true
	end
end
assert_eq(noteOk, true, "DAW-mode enable note sent")
local dawSysex = false
for _, s in ipairs(mock.screen()) do
	if s.op == "daw" and s.value == 127 then
		dawSysex = true
	end
end
assert_eq(dawSysex, true, "DAW-mode enable sysex sent")

-- Feature controls: relative rows, touch, pickup, brightness, curve.
for _, cc in ipairs({ 69, 72, 73, 71, 70 }) do
	assert_eq(sentCC(6, cc, 127), true, "feature CC " .. cc .. " enabled")
end
assert_eq(sentCC(6, 111, 100), true, "LED brightness set")
assert_eq(sentCC(6, 112, 100), true, "screen brightness set")
assert_eq(sentCC(6, 121, 1), true, "encoder curve medium")

-- Mode request: the script selects DAW Mixer (value 1) on ch 7 CC 30.
assert_eq(sentCC(6, 30, 1), true, "surface mode requested")

-- Input registration covers every channel the surface speaks on.
local function registered(ch, cc)
	for _, c in ipairs(mock.find("AddCCToScript")) do
		if c.args[1] == ch and c.args[2] == cc then
			return true
		end
	end
	return false
end
assert_eq(registered(15, 5), true, "fader CC on ch 16")
assert_eq(registered(15, 13), true, "absolute encoder CC on ch 16")
assert_eq(registered(15, 77), true, "relative encoder CC on ch 16")
assert_eq(registered(14, 77), true, "encoder touch CC on ch 15")
assert_eq(registered(14, 5), true, "fader touch CC on ch 15")
assert_eq(registered(0, 37), true, "top row button CC on ch 1")
assert_eq(registered(0, 45), true, "bottom row button CC on ch 1")
assert_eq(registered(0, 116), true, "play CC on ch 1")
assert_eq(registered(6, 63), true, "shift CC on ch 7")
assert_eq(registered(6, 30), true, "mode CC on ch 7")
assert_eq(mock.count("SetHandleSysex") >= 1, true, "sysex handling enabled")

-- Timer started at 50 ms.
local starts = mock.find("timer.Start")
assert_eq(#starts >= 1, true, "timer started")
assert_eq(starts[#starts].args[1], 50, "timer period 50 ms")

-- Displays configured: stationary 3-line, overlay 2-line, per-control targets.
local function configured(target, config)
	for _, s in ipairs(mock.screen()) do
		if s.op == "configure" and s.target == target and s.config == config then
			return true
		end
	end
	return false
end
assert_eq(configured(53, 98), true, "stationary display 3-line")
assert_eq(configured(54, 97), true, "overlay display 2-line")
assert_eq(configured(5, 98), true, "fader display configured")
assert_eq(configured(13, 98), true, "encoder display configured")

-- Firmware probe: the universal device inquiry went out.
local inquiry = false
for _, s in ipairs(mock.sysex) do
	if s == string.char(0x7E, 0x7F, 0x06, 0x01) then
		inquiry = true
	end
end
assert_eq(inquiry, true, "device inquiry sent")

-- Initial paint: transport LEDs reflect the stopped transport; Q-Link routing is
-- NOT active in mixer mode.
assert_eq(mock.leds[116], "0,22,5", "play LED dim green while stopped")
assert_eq(mock.leds[118], "24,0,0", "record LED dim red while unarmed")
assert_eq(mock.count("AddInfiniteCCToQLink"), 0, "no Q-Link routing in mixer mode")
assert_eq(mock.leds[65], "16,60,127", "Solo/Arm button blue in solo mode")
assert_eq(mock.leds[66], "127,52,0", "Mute/Select button orange in mute mode")

-- Fader positions were pushed to the device for pickup (0.7 -> 89).
assert_eq(sentCC(15, 5, 89), true, "fader 1 position synced for pickup")

-- Firmware identity reply is logged once.
L.HandleMIDISysex(string.char(0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x20, 0x29, 0x01, 0x01, 0x00, 0x01, 0x01, 0x02, 0x03, 0xF7))
assert_eq(lastLog(), "LaunchControlXL3: firmware: 1.2.3", "firmware version logged")

L.OnUnload()
assert_eq(mock.count("SendMIDINoteOn") >= 2, true, "DAW-mode disable note sent on unload")
local dawOff = false
for _, s in ipairs(mock.screen()) do
	if s.op == "daw" and s.value == 0 then
		dawOff = true
	end
end
assert_eq(dawOff, true, "DAW-mode disable sysex sent on unload")
_G.print = realPrint
print("test-load: PASS")
