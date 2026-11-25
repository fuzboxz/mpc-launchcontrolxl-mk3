-- tests/test-encoders.lua: mixer-mode sends/pan, the send-bank page, control-mode
-- Q-Link routing (hardware path + script fallback) and the global row.
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
local function lastLog(logs)
	return logs[#logs] or ""
end

local logs = {}
local realPrint = print
_G.print = function(msg)
	logs[#logs + 1] = tostring(msg)
end

local function screenText(target, field)
	local out = nil
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" and s.target == target and s.field == field then
			out = s.text -- the latest write wins
		end
	end
	return out
end

L.OnLoad()
mock.reset()

-- Mixer mode: row 1 = Send 1, row 2 = Send 2, row 3 = Pan (decision 2a).
L.HandleMIDICC(15, 77, 66) -- row 1 col 0, +2
assert_near(mock.tracks[0].Send1.value, 2 / 64, 0.0001, "row 1 nudges Send 1")
L.HandleMIDICC(15, 85 + 3, 65) -- row 2 col 3, +1
assert_near(mock.tracks[3].Send2.value, 1 / 64, 0.0001, "row 2 nudges Send 2")
mock.tracks[5].Pan:set(0.5)
L.HandleMIDICC(15, 93 + 5, 63) -- row 3 col 5, -1
assert_near(mock.tracks[5].Pan.value, 0.5 - 1 / 127, 0.0001, "row 3 nudges Pan")
-- reverse direction clamps at 0
for _ = 1, 20 do
	L.HandleMIDICC(15, 77, 63)
end
assert_near(mock.tracks[0].Send1.value, 0, 0.0001, "sends clamp at 0")
for _ = 1, 40 do -- 2 texts/tick pacing: drain the queue plus its re-asserts
	L.HandleTimer()
end
assert_eq(screenText(13, 1), "Send 1", "encoder display names the parameter")
assert_eq(screenText(13, 2), "0%", "encoder display shows the value")

-- Page up flips the send bank: row 1 becomes Send 3, row 2 becomes Send 4.
L.HandleMIDICC(0, 106, 127) -- Page up
L.HandleMIDICC(15, 77, 65)
assert_near(mock.tracks[0].Send3.value, 1 / 64, 0.0001, "bank B row 1 nudges Send 3")
assert_near(mock.tracks[0].Send1.value, 0, 0.0001, "Send 1 untouched on bank B")
L.HandleMIDICC(15, 85, 65)
assert_near(mock.tracks[0].Send4.value, 1 / 64, 0.0001, "bank B row 2 nudges Send 4")

-- Control mode: the device reports mode 2. Native Q-Link routing ships OFF
-- (pending the direction probe, __LCXL3_NATIVE): the rel CCs stay script-owned
-- and rows 1-2 drive the Q-Links through the script-side Twist fallback.
mock.reset()
L.HandleMIDICC(6, 30, 2)
assert_eq(mock.count("AddInfiniteCCToQLink"), 0, "native routing disabled by default")
assert_eq(mock.dev.mappings.script.IsCCMappedToScript(15, 77), true, "rel CCs stay script-owned")
mock.setQlinkTarget(12, "Cutoff") -- row 1 k1 (cc 77) = index 12 (screen order)
L.HandleMIDICC(15, 77, 66) -- +2 on row 1 k1 (Q-Link index 12)
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "the fallback drives the Q-Link through dot-form Twist")
assert_near(mock.tracks[0].Send3.value, 1 / 64, 0.0001, "script-owned CCs never touch the mixer")
for _ = 1, 40 do -- 2 texts/tick pacing: drain the queue plus its re-asserts
	L.HandleTimer()
end
assert_eq(screenText(13, 1), "Cutoff", "fallback display names the Q-Link target")

-- Global row (row 3) is still script-driven: tempo, swing, metronome, loop.
L.HandleMIDICC(15, 93, 65) -- tempo +1
assert_eq(mock.mpc.project.BPM.value, 121, "tempo nudged")
L.HandleMIDICC(15, 93 + 1, 66) -- accelerated CC (+2 raw): clamped to one percent step
assert_eq(mock.mpc.sequencer.quantiser.GetSwing(), 55, "swing nudged (per-event clamp)")
L.HandleMIDICC(15, 93 + 4, 65) -- metronome on
assert_eq(mock.mpc.sequencer.MetronomeEnabled.value, true, "metronome on via CW turn")
L.HandleMIDICC(15, 93 + 4, 63) -- metronome off
assert_eq(mock.mpc.sequencer.MetronomeEnabled.value, false, "metronome off via CCW turn")
L.HandleMIDICC(15, 93 + 5, 65) -- loop on
assert_eq(mock.mpc.sequencer.Loop.value, true, "loop on via CW turn")

-- Page down in control mode cycles the row-3 page (global -> track).
L.HandleMIDICC(0, 107, 127)
mock.tracks[0].Pan:set(0.5)
L.HandleMIDICC(15, 93, 65) -- track page col 0 = pan of the CURRENT track
assert_near(mock.tracks[0].Pan.value, 0.5 + 1 / 96, 0.0001, "track page col 0 nudges the current track's pan")

-- Back to mixer mode: nothing was ever routed, so nothing is unmapped and the
-- CCs never left the script.
mock.reset()
L.HandleMIDICC(6, 30, 1)
assert_eq(mock.count("RemoveInfiniteCCToQLink"), 0, "nothing to unmap (routing was never armed)")
assert_eq(mock.count("AddCCToScript"), 0, "CCs never left the script")
L.HandleMIDICC(15, 93 + 5, 63)
assert_near(mock.tracks[5].Pan.value, 0.5 - 2 / 127, 0.0001, "mixer encoders work again")

-- Even without the mapping API at all, rows 1-2 keep the Twist path and the
-- per-Q-Link display (a fresh target key so the screen cache cannot hide it).
mock.dev.mappings.controlSurface = nil
L.HandleMIDICC(6, 30, 2) -- enter control mode without any mapping API
mock.clearCalls()
assert_eq(mock.count("Twist"), 0, "no Twist before any movement")
mock.setQlinkTarget(4, "Drive") -- row 1 k3 (cc 79) = Q-Link 5 (index 4)
L.HandleMIDICC(15, 79, 65) -- +1 on row 1 k3 -> Q-Link 5
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "no Twist-callable fallback still drives via the same path")
for _ = 1, 40 do -- 2 texts/tick pacing: drain the queue plus its re-asserts
	L.HandleTimer()
end
assert_eq(screenText(15, 1), "Drive", "fallback display names the Q-Link target")
L.OnUnload()
_G.print = realPrint
print("test-encoders: PASS")
