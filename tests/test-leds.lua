-- tests/test-leds.lua: LED palette outputs (buttons + absolute encoder indices)
-- and the full dark on unload. The script caches palette writes, so unchanged
-- LEDs are never resent: assertions target LEDs whose state actually changed.
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

L.OnLoad()

-- Initial mixer paint: rows 1/2 = track colour (green) scaled by the send
-- level (0 -> subtle 7% tint), row 3 dark at pan centre.
assert_eq(mock.leds[13], "0,9,0", "row 1 = track colour at send level 0")
assert_eq(mock.leds[21], "0,9,0", "row 2 = track colour at send level 0")
assert_eq(mock.leds[29], "0,0,0", "row 3 encoder LED dark at pan centre")

-- Raising the send level brightens the ring toward the full track colour.
mock.tracks[0].Send1:set(1.0)
L.HandleTimer()
assert_eq(mock.leds[13], "0,127,0", "row 1 reaches full colour at send 100%")
assert_eq(mock.leds[21], "0,9,0", "row 2 unaffected")
mock.tracks[0].Send1:set(0.0)

-- A track colour change repaints the rings.
mock.tracks[0].Colour:set(0xFF0000)
L.HandleTimer()
assert_eq(mock.leds[13], "9,0,0", "rings follow the track colour (dim at 0)")
mock.tracks[0].Colour:set(0x00FF00)

-- State changes repaint: solo/mute on the button rows.
mock.tracks[0].Solo:set(true)
mock.tracks[0].Mute:set(true)
L.HandleTimer()
assert_eq(mock.leds[37], "16,60,127", "solo on = blue")
assert_eq(mock.leds[45], "127,52,0", "mute on = orange")

-- Pan ring: continuous brightness with directional hue. Empty tracks (mock:
-- track 2+) stay dark even when panned.
mock.tracks[2].Pan:set(0.9)
L.HandleTimer()
assert_eq(mock.leds[31], "0,0,0", "empty track pan ring dark")
mock.tracks[2].Pan:set(0.5)

-- Steep curve: small offsets start near-black, extremes reach full base.
mock.tracks[0].Pan:set(0.55)
L.HandleTimer()
assert_eq(mock.leds[29], "3,1,0", "pan 0.55 = almost black")
mock.tracks[0].Pan:set(0.6)
L.HandleTimer()
assert_eq(mock.leds[29], "9,4,0", "pan 0.6 = very dim orange")
mock.tracks[0].Pan:set(0.9)
L.HandleTimer()
assert_eq(mock.leds[29], "93,44,0", "pan 0.9 = bright orange")
mock.tracks[0].Pan:set(1.0)
L.HandleTimer()
assert_eq(mock.leds[29], "127,60,0", "pan hard right = full base")
mock.tracks[0].Pan:set(0.1)
L.HandleTimer()
assert_eq(mock.leds[29], "18,53,93", "pan 0.1 = mirrored blue")
mock.tracks[0].Pan:set(0.5)
L.HandleTimer()
assert_eq(mock.leds[29], "0,0,0", "centred pan ring dark")

-- Send bank B keeps the track colours, still scaled by its own send levels.
L.HandleMIDICC(0, 106, 127) -- page up -> send bank B
L.HandleTimer()
assert_eq(mock.leds[13], "0,9,0", "bank B row 1 = track colour at send 0")
mock.tracks[0].Send3:set(1.0)
L.HandleTimer()
assert_eq(mock.leds[13], "0,127,0", "bank B row 1 full at send 3 = 100%")
mock.tracks[0].Send3:set(0.0)

-- Control mode: unassigned Q-Links stay dark; assigned ones take a row colour.
mock.reset()
for i = 0, 15 do
	mock.setQlinkTarget(i, false) -- explicitly unassigned
end
L.HandleMIDICC(6, 30, 2)
L.HandleTimer()
assert_eq(mock.leds[13], "0,0,0", "unassigned Q-Link 1 dark")
assert_eq(mock.leds[20] == nil or mock.leds[20] == "0,0,0", true, "unassigned Q-Link 8 dark (nil = already off, cache-skipped)")
mock.setQlinkTarget(0, "Cutoff")
mock.setQlinkTarget(8, "Resonance")
mock.qlinkPositions[0] = 127 -- Q-Link 1 at 100%: full turquoise
mock.qlinkPositions[8] = 64 -- Q-Link 9 mid: scaled purple
mock.tracks[0].Solo:set(false) -- any state change marks a repaint
L.HandleTimer()
assert_eq(mock.leds[13], "0,108,108", "assigned Q-Link row 1 full at value 1")
assert_eq(mock.leds[21], "42,6,42", "assigned Q-Link row 2 scaled at value ~0.5")
mock.qlinkPositions[0] = 0
mock.tracks[0].Solo:set(true) -- force a repaint
L.HandleTimer()
assert_eq(mock.leds[13], "0,8,8", "Q-Link row 1 subtle tint at value 0")
mock.tracks[0].Solo:set(false)
mock.qlinkPositions[0] = 64
mock.qlinkPositions[8] = 64

-- Unload: every surface LED goes dark.
L.OnUnload()
-- dark means 0 or never-sent-in-this-window (the cache suppresses redundant 0s)
local function dark(cc, what)
	local v = mock.leds[cc]
	if v ~= nil and v ~= "0,0,0" then
		error(what .. " " .. cc .. " not dark after unload: " .. tostring(v))
	end
end
for _, cc in ipairs({ 37, 40, 45, 50, 65, 66, 102, 103, 104, 106, 107, 116, 118 }) do
	dark(cc, "button LED")
end
for cc = 13, 36 do
	dark(cc, "encoder LED")
end
print("test-leds: PASS")
