-- tests/test-faders.lua: fader volume writes, software pickup after a bank move,
-- and the position sync the device needs for its own pickup.
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
local function assert_near(a, b, eps, msg)
	if math.abs(a - b) > (eps or 0.001) then
		error((msg or "") .. ": expected ~" .. tostring(b) .. ", got " .. tostring(a))
	end
end

local logs = {}
local realPrint = print
_G.print = function(msg)
	logs[#logs + 1] = tostring(msg)
end

local function sentCC(ch, cc, value)
	for _, c in ipairs(mock.find("SendMIDICC")) do
		if c.args[1] == ch and c.args[2] == cc and (value == nil or c.args[3] == value) then
			return true
		end
	end
	return false
end

L.OnLoad()
mock.reset()

-- Track 0 volume starts at 0.7 -> pickup reference 89. Movement that has not
-- reached the track's value is suppressed; crossing it engages the fader.
L.HandleMIDICC(15, 5, 40)
assert_near(mock.tracks[0].Volume.value, 0.7, 0.0001, "movement below the pickup value ignored")
L.HandleMIDICC(15, 5, 80)
assert_near(mock.tracks[0].Volume.value, 0.7, 0.0001, "approach near the reference still ignored")
L.HandleMIDICC(15, 5, 90)
assert_near(mock.tracks[0].Volume.value, 90 / 127, 0.0001, "crossing the reference engages the fader")
-- engaged: further movement tracks directly
L.HandleMIDICC(15, 5, 127)
assert_near(mock.tracks[0].Volume.value, 1.0, 0.0001, "fader at the top = full volume")
L.HandleMIDICC(15, 5, 0)
assert_near(mock.tracks[0].Volume.value, 0.0, 0.0001, "fader at the bottom = zero volume")

-- Bank move: the same fader now owns track 1, pickup re-arms and the device is
-- told where the new track's volume is.
mock.tracks[1].Volume:set(0.5)
L.HandleMIDICC(0, 102, 127) -- Track >
assert_eq(sentCC(15, 5, 64), true, "fader 1 re-synced to track 1 (0.5 -> 64)")
L.HandleMIDICC(15, 5, 10) -- far away: suppressed
assert_near(mock.tracks[1].Volume.value, 0.5, 0.0001, "pickup re-armed after the bank move")
L.HandleMIDICC(15, 5, 64)
L.HandleMIDICC(15, 5, 70)
assert_near(mock.tracks[1].Volume.value, 70 / 127, 0.0001, "bank move writes go to the new track")
assert_near(mock.tracks[0].Volume.value, 0.0, 0.0001, "track 0 untouched")

-- The bank clamps at the last page of tracks (16 tracks -> last bank starts at 8).
for _ = 1, 20 do
	L.HandleMIDICC(0, 102, 127)
end
L.HandleMIDICC(15, 5, 89) -- engage pickup on the clamped bank's first track
L.HandleMIDICC(15, 5, 100)
assert_near(mock.tracks[8].Volume.value, 100 / 127, 0.0001, "bank clamped: fader 1 owns track 9")
assert_near(mock.tracks[9].Volume.value, 0.7, 0.0001, "no overflow past the visible window")

-- The per-control display carries the track name, the parameter and a dB value.
-- A fresh load resets the text cache, so the fader map is (re)sent and pumped.
mock.tracks[0].Volume:set(0.7) -- "-inf" contains no "dB"; use an audible value
L.OnLoad()
for _ = 1, 3 do
	L.HandleTimer()
end
local sawName, sawParam, sawDb = false, false, false
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 5 then
		if s.field == 0 and s.text == "Track 0" then
			sawName = true
		end
		if s.field == 1 and s.text == "Volume" then
			sawParam = true
		end
		if s.field == 2 and s.text:find("dB", 1, true) then
			sawDb = true
		end
	end
end
assert_eq(sawName, true, "fader display shows the track name")
assert_eq(sawParam, true, "fader display shows the parameter name")
assert_eq(sawDb, true, "fader display shows a dB value")

L.OnUnload()
_G.print = realPrint
print("test-faders: PASS")
