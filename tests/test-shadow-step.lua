-- tests/test-shadow-step.lua: the T2 shadow-stepper regression file (task T2 §Tests).
-- Covers the eight contract items with the device's read lag armed (mock.setReadLag(3)):
--   1. mixer sends: 12 rapid CW detents = exactly 12 steps, screen shows the written
--      value, an external change is picked up after a quiet gap,
--   2. pan / control-mode track page / master volume: same contract; unreadable
--      master writes nothing and logs once,
--   3. swing: +1 % per detent, external re-sync after a quiet gap (no jump to max),
--      fraction-unit fixture still steps +1 % with NN% on screen; __LCXL3_SWING gone,
--   4. tempo/strength: an absolute-path delta of +12 moves exactly +1,
--   5. time division: 4 detents = 2 steps, saturating at both ends, flip resets,
--   6. automation filter: 2-type list sweep ends on the last/first type, the
--      enumeration under lag is complete and restores the start type, the Advance
--      degrade still steps once per two detents,
--   7. metronome/loop: a CW sweep sends Set(true) exactly once and never flips back,
--   8. rings: the send LED reflects the shadow in the same tick as the detent.
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
	if math.abs(a - b) > (eps or 1e-9) then
		error((msg or "") .. ": expected ~" .. tostring(b) .. ", got " .. tostring(a))
	end
end

local logs = {}
local realPrint = print
_G.print = function(m)
	logs[#logs + 1] = tostring(m)
end

local function countLogs(needle)
	local n = 0
	for _, line in ipairs(logs) do
		if line:find(needle, 1, true) then
			n = n + 1
		end
	end
	return n
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

local function argsOf(name)
	local out = {}
	for _, c in ipairs(mock.find(name)) do
		out[#out + 1] = c.args[1]
	end
	return out
end

-- A fresh script session with the device read lag armed: every item runs in the
-- lagged world the XL3 fw 1.1.11 actually lives in. OnLoad resets the stepper
-- shadows (H.step/H.want/H.enum/H.swingUnit), so items stay isolated.
local function session()
	mock.reset()
	L.OnLoad()
	mock.reset()
	mock.setReadLag(3)
end

-- Mixer row r col c relative detent (rows 1/3 of the surface speak rel CC 77-100).
local function turnMixer(row, col, dir)
	L.HandleMIDICC(15, 77 + row * 8 + col, dir > 0 and 65 or 63)
end

-- Control-mode row 3 col c relative detent.
local function turnRow3(col, dir)
	L.HandleMIDICC(15, 93 + col, dir > 0 and 65 or 63)
end

local function enterControl()
	L.HandleMIDICC(6, 30, 2) -- DAW Control mode report
	mock.runTicks(L, 2)
end

-- 1. mixer sends --------------------------------------------------------------
session()
for _ = 1, 12 do
	turnMixer(0, 0, 1) -- row 1 col 0, rapid: no ticks between detents
end
mock.runTicks(L, 4) -- drain the 3-tick read lag
assert_near(mock.tracks[0].Send1.value, 12 / 64, 1e-9, "12 rapid CW detents apply exactly 12 steps of 1/64")
mock.runTicks(L, 20) -- drain the text queue (shadow may go stale: same value)
assert_eq(screenText(13, 2), "19%", "the screen shows the 12th written value, not a lagged read")
mock.runTicks(L, 3) -- quiet gap: the shadow ages past STEP_QUIET
mock.tracks[0].Send1:set(0.5) -- an external change (mouse/automation)
mock.runTicks(L, 4) -- external value readable now, shadow still stale
turnMixer(0, 0, 1)
mock.runTicks(L, 4)
assert_near(
	mock.tracks[0].Send1.value,
	0.5 + 1 / 64,
	1e-9,
	"after the quiet gap the next detent re-reads the device (external change picked up)"
)

-- 1b. refreshLastTouched reads through H.cur: the mid-turn 500 ms refresh
-- (ticks % 10 == 5) must show the written (shadow) value, not the lagged read.
-- The detent is phased 1 tick before the next refresh boundary: the shadow
-- (written W) is fresh for STEP_QUIET = 6 ticks, but the device read lags 3
-- ticks, so the discriminating window is exactly the 1-2 ticks after W --
-- any later and both paths read the caught-up device.
session()
mock.tracks[0].Send1:set(0) -- explicit start value (item 1 left its own)
local pumped, quiet, elapsed = #mock.screen(), 0, 0 -- elapsed = script ticks (OnLoad reset to 0)
for _ = 1, 60 do -- bounded probe: drain the OnLoad paint backlog (2 texts/tick)
	mock.runTicks(L, 1)
	elapsed = elapsed + 1
	local n = #mock.screen()
	if n == pumped then
		quiet = quiet + 1
		if quiet >= 3 then break end
	else
		quiet, pumped = 0, n
	end
end
local d = (5 - elapsed) % 10 -- ticks until the next refresh boundary (R % 10 == 5)
if d == 0 then
	d = 10
end
mock.runTicks(L, d - 1) -- tick W = R - 1: the detent lands one tick before the refresh
local seen13 = 0
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 13 and s.field == 2 then
		seen13 = seen13 + 1
	end
end
turnMixer(0, 0, 1) -- writes 1/64 and shadows it at tick W
mock.runTicks(L, 3) -- the refresh tick R + 2 pump ticks (2 texts/tick: all 3 fields flush)
local first13, i13, anyLagged = nil, 0, false
for _, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 13 and s.field == 2 then
		i13 = i13 + 1
		if i13 > seen13 then -- only texts sent after the detent
			if first13 == nil then
				first13 = s.text
			end
			if s.text == "0%" then
				anyLagged = true
			end
		end
	end
end
assert_eq(first13, "2%", "the idle refresh shows the written send value, not the lagged read")
assert_eq(anyLagged, false, "no lagged device value reaches the screen before the shadow value")

-- 2. pan / track page / master ------------------------------------------------
session()
for _ = 1, 12 do
	turnMixer(2, 0, 1) -- row 3 col 0 = pan, rapid
end
mock.runTicks(L, 4)
assert_near(mock.tracks[0].Pan.value, 0.5 + 12 / 127, 1e-9, "12 rapid pan detents apply exactly 12 steps of 1/127")
mock.runTicks(L, 20)
assert_eq(screenText(29, 2), "R9", "the pan screen shows the written pan (read lag would say C)")
mock.runTicks(L, 3)
mock.tracks[0].Pan:set(0.3)
mock.runTicks(L, 4)
turnMixer(2, 0, 1)
mock.runTicks(L, 4)
assert_near(mock.tracks[0].Pan.value, 0.3 + 1 / 127, 1e-9, "pan picks up an external change after the quiet gap")

enterControl()
L.HandleMIDICC(6, 31, 65) -- Edit: control-mode row 3 page 1 = track page
mock.runTicks(L, 2)
mock.tracks[0].Volume:set(0.7) -- explicit start value for the current track
mock.runTicks(L, 8) -- quiet: no shadow to trust
for _ = 1, 12 do
	turnRow3(5, 1) -- col 5 = Volume, 1/127 per detent, rapid
end
mock.runTicks(L, 4)
assert_near(mock.tracks[0].Volume.value, 0.7 + 12 / 127, 1e-9, "12 rapid track-page detents apply exactly 12 steps")
mock.runTicks(L, 20)
assert_eq(screenText(34, 2), "2.0 dB", "the track-page screen shows the written volume in dB")
mock.runTicks(L, 3)
mock.tracks[0].Volume:set(0.4)
mock.runTicks(L, 4)
turnRow3(5, 1)
mock.runTicks(L, 4)
assert_near(mock.tracks[0].Volume.value, 0.4 + 1 / 127, 1e-9, "track page picks up an external change after quiet")

L.HandleMIDICC(6, 31, 65) -- back to page 0 (globals)
mock.runTicks(L, 2)
mock.setMasterSlot("nilread") -- masterTracks[0].Volume cannot be read (device D4)
logs = {}
for _ = 1, 3 do
	turnRow3(7, 1) -- col 7 = master volume
end
assert_eq(countLogs("master volume read failed"), 1, "unreadable master: exactly one one-shot read log for 3 detents")
mock.makeMasterLive() -- a real read appears (0.8)
mock.runTicks(L, 8) -- quiet
turnRow3(7, 1)
assert_near(
	mock.mpc.tracks.masterTracks[0].Volume.value,
	0.8 + 1 / 127,
	1e-9,
	"master writes once the slot is readable (never a blind write)"
)

-- 3. swing --------------------------------------------------------------------
session()
enterControl()
mock.sequencer.quantiser.SetSwing(54) -- percent wire form, explicit start
mock.runTicks(L, 8) -- visible + quiet
mock.clearCalls()
for _ = 1, 5 do
	turnRow3(1, 1) -- col 1 = swing, rapid
end
mock.runTicks(L, 4)
local swingSets = argsOf("SetSwing")
assert_eq(#swingSets, 5, "5 CW detents send 5 SetSwing calls")
assert_eq(swingSets[5], 59, "5 CW detents step 54 to exactly 59 (+1 per detent)")
mock.runTicks(L, 20)
assert_eq(screenText(30, 2), "59%", "the swing screen shows the written percent")
mock.sequencer.quantiser.SetSwing(54) -- external change back to 54
mock.runTicks(L, 8) -- quiet gap AND the external value readable
mock.clearCalls() -- the external SetSwing itself is not under test
turnRow3(1, 1)
swingSets = argsOf("SetSwing")
assert_eq(#swingSets, 1, "after the quiet gap exactly one SetSwing is sent")
assert_eq(swingSets[1], 55, "the next CW detent steps the re-read 54 to 55 (no jump to the 75 ceiling)")

session()
mock.setSwingFraction(true) -- H3 fixture: the API speaks 0..1 fractions
mock.sequencer.quantiser.SetSwing(0.54) -- 54 % as a fraction
-- the unit auto-detect is sticky per session and runs on the FIRST swing read
-- (enterControl's paint included): flip the fixture BEFORE any read/paint.
enterControl()
mock.runTicks(L, 8)
mock.clearCalls()
for _ = 1, 3 do
	turnRow3(1, 1)
end
mock.runTicks(L, 4)
swingSets = argsOf("SetSwing")
assert_eq(#swingSets, 3, "fraction unit: one write per detent")
assert_near(swingSets[1], 0.58, 1e-6, "fraction unit: the first detent steps 54% to 55% (raw 0.58)")
assert_near(swingSets[3], 0.66, 1e-6, "fraction unit: still exactly +1% per detent")
mock.runTicks(L, 20)
assert_eq(screenText(30, 2), "67%", "fraction unit: the screen shows NN%")
assert_near(mock.sequencer.quantiser.GetSwing(), 0.66, 1e-6, "fraction unit: the device reached 66%")

-- the retired __LCXL3_SWING shadow must have no live (non-comment) reference left
local scriptPath = os.getenv("LCXL3_LUA") or "script/LaunchControlXL3.lua"
local fh = io.open(scriptPath, "r")
if fh ~= nil then
	local live = 0
	for line in fh:lines() do
		if line:find("__LCXL3_SWING", 1, true) ~= nil then
			local trimmed = (line:match("^%s*(.-)%s*$")) or ""
			if trimmed:sub(1, 2) ~= "--" then
				live = live + 1
			end
		end
	end
	fh:close()
	assert_eq(live, 0, "__LCXL3_SWING has no live (non-comment) reference")
end

-- 4. tempo and strength: sign-only stepping -----------------------------------
session()
enterControl()
mock.clearCalls()
L.HandleMIDICC(15, 93, 76) -- +12 absolute-path delta on tempo
mock.runTicks(L, 4) -- the BPM prop write drains the read lag
assert_near(mock.project.BPM.value, 121, 1e-9, "an absolute-path delta of +12 moves the tempo exactly +1")
L.HandleMIDICC(15, 93, 52) -- -12
mock.runTicks(L, 4)
assert_near(mock.project.BPM.value, 120, 1e-9, "an absolute-path delta of -12 moves the tempo exactly -1")
mock.clearCalls()
L.HandleMIDICC(15, 95, 76) -- strength +12
mock.runTicks(L, 4)
local strengthSets = argsOf("SetStrength")
assert_eq(#strengthSets, 1, "one +12 absolute detent writes the strength once")
assert_eq(strengthSets[1], 91, "strength moves exactly +1 (90 -> 91), sign-only")

-- 5. time division ------------------------------------------------------------
session()
enterControl()
mock.setTimeDivision("1/4")
mock.runTicks(L, 8) -- visible + quiet
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(3, 1) -- col 3 = division, rapid
end
mock.runTicks(L, 4)
local divSets = argsOf("SetTimeDivision")
assert_eq(#divSets, 2, "4 detents = exactly 2 list steps (one per two detents)")
assert_eq(divSets[1], "1/4T", "the first pair steps 1/4 -> 1/4T")
assert_eq(divSets[2], "1/8", "the second pair steps 1/4T -> 1/8")
mock.setTimeDivision("1/32T") -- jump to the list tail
mock.runTicks(L, 8)
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(3, 1)
end
mock.runTicks(L, 4)
assert_eq(#mock.find("SetTimeDivision"), 0, "saturation at the tail: 4 CW detents write nothing (no wrap)")
mock.setTimeDivision("1/4") -- back to the list head
mock.runTicks(L, 8)
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(3, -1)
end
mock.runTicks(L, 4)
assert_eq(#mock.find("SetTimeDivision"), 0, "saturation at the head: 4 CCW detents write nothing")
mock.setTimeDivision("1/16")
mock.runTicks(L, 8)
mock.clearCalls()
turnRow3(3, 1) -- odd CW detent: half a unit of residue
turnRow3(3, -1) -- direction flip: the residue must be discarded
turnRow3(3, -1) -- now a full CCW unit: one step
mock.runTicks(L, 4)
divSets = argsOf("SetTimeDivision")
assert_eq(#divSets, 1, "a direction flip resets the accumulator: one write, not zero, not two")
assert_eq(divSets[1], "1/8T", "the post-flip pair steps 1/16 -> 1/8T")

-- 6. automation filter --------------------------------------------------------
session()
enterControl()
mock.setFilterTypes({ "Off", "Latch" }) -- 2-type enum fixture
mock.runTicks(L, 8)
L.HandleMIDICC(15, 99, 65) -- first turn starts the asynchronous enumeration
mock.runTicks(L, 5) -- the scan completes under the read lag
assert_eq(mock.count("AdvanceGlobalAutomationFilterType"), 2, "2-type enum: one advance per discovered type")
assert_eq(countLogs("autofilter enum: 2 types"), 1, "the 2-type enumeration completes and logs")
mock.clearCalls()
for _ = 1, 8 do
	turnRow3(6, 1) -- the 8-detent CW sweep
	mock.tick(L)
end
mock.runTicks(L, 4)
local filterSets = argsOf("SetGlobalAutomationFilterType")
assert_eq(#filterSets, 1, "the 8-detent CW sweep sends exactly one perStep-divided write")
assert_eq(filterSets[1], "Latch", "the CW sweep ends on the LAST type")
assert_eq(mock.project.GlobalAutomationFilterType.value, "Latch", "the filter never flips back off the last type")
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(6, -1) -- the CCW sweep
	mock.tick(L)
end
mock.runTicks(L, 4)
filterSets = argsOf("SetGlobalAutomationFilterType")
assert_eq(#filterSets, 1, "the CCW sweep sends exactly one write")
assert_eq(filterSets[1], "Off", "the CCW sweep ends on the FIRST type")
assert_eq(mock.project.GlobalAutomationFilterType.value, "Off", "the filter sits on the first type")

session()
enterControl()
mock.setFilterTypes(nil) -- the default 4-value cycle
mock.runTicks(L, 8)
mock.clearCalls()
L.HandleMIDICC(15, 99, 65) -- start the scan
mock.runTicks(L, 6)
assert_eq(mock.count("AdvanceGlobalAutomationFilterType"), 4, "4-type enum: one advance per discovered type")
assert_eq(mock.count("SetGlobalAutomationFilterType"), 0, "the enumeration itself sends no Set")
assert_eq(countLogs("autofilter enum: 4 types"), 1, "the enumeration under lag yields the full list")
assert_eq(
	mock.project.GlobalAutomationFilterType.value,
	"Off",
	"the enumeration restores the start type by itself"
)
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(6, 1)
	mock.tick(L)
end
mock.runTicks(L, 4)
filterSets = argsOf("SetGlobalAutomationFilterType")
assert_eq(#filterSets, 2, "no duplicates: two units step onto two DISTINCT types")
assert_eq(filterSets[1], "Latch", "unit 1 lands on Latch")
assert_eq(filterSets[2], "Touch", "unit 2 lands on Touch (a duplicated list entry would land on Latch again)")

session()
enterControl()
mock.setFilterTypes(nil)
local savedSet = mock.project.SetGlobalAutomationFilterType
local savedGet = mock.project.GetGlobalAutomationFilterType
mock.project.SetGlobalAutomationFilterType = nil -- the Advance-only degrade fixture
mock.project.GetGlobalAutomationFilterType = nil
logs = {}
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(6, 1)
	mock.tick(L)
end
assert_eq(countLogs("CW-only Advance fallback"), 1, "the Advance degrade logs once")
assert_eq(
	mock.count("AdvanceGlobalAutomationFilterType"),
	2,
	"the Advance degrade still steps once per two detents"
)
assert_eq(mock.project.GlobalAutomationFilterType.value, "Touch", "two degrade steps moved two types")
mock.clearCalls()
for _ = 1, 4 do
	turnRow3(6, -1) -- CCW detents in the degrade
	mock.tick(L)
end
assert_eq(
	mock.count("AdvanceGlobalAutomationFilterType"),
	0,
	"the degrade is CW-only: CCW detents produce zero Advance calls"
)
assert_eq(mock.project.GlobalAutomationFilterType.value, "Touch", "the CCW detents leave the filter untouched")
mock.project.SetGlobalAutomationFilterType = savedSet
mock.project.GetGlobalAutomationFilterType = savedGet

-- 7. metronome and loop -------------------------------------------------------
session()
enterControl()
mock.clearCalls()
for _ = 1, 5 do
	turnRow3(4, 1) -- col 4 = metronome, CW sweep with lag, rapid
end
mock.runTicks(L, 4)
local metroSets = mock.find("SetMetronomeEnabled")
assert_eq(#metroSets, 1, "the CW sweep sends Set(true) exactly once")
assert_eq(metroSets[1].args[1], true, "CW asks for ON")
assert_eq(mock.mpc.sequencer.MetronomeEnabled.value, true, "the metronome is on")
for _ = 1, 3 do
	turnRow3(4, -1)
end
mock.runTicks(L, 4)
metroSets = mock.find("SetMetronomeEnabled")
assert_eq(#metroSets, 2, "the CCW sweep adds exactly one Set(false)")
assert_eq(metroSets[2].args[1], false, "CCW asks for OFF")
assert_eq(mock.mpc.sequencer.MetronomeEnabled.value, false, "the metronome is off")
mock.runTicks(L, 8) -- quiet gap: the stepper re-reads the device
turnRow3(4, 1) -- CW while off: a real difference, this one writes
mock.runTicks(L, 4)
assert_eq(#mock.find("SetMetronomeEnabled"), 3, "CW after the CCW sweep writes once (off -> on)")
assert_eq(mock.mpc.sequencer.MetronomeEnabled.value, true, "the metronome is on again")
mock.runTicks(L, 8) -- quiet gap, metronome already on
turnRow3(4, 1) -- CW again: the satisfied direction must stay silent
mock.runTicks(L, 4)
assert_eq(#mock.find("SetMetronomeEnabled"), 3, "a satisfied direction re-sends nothing after the quiet gap")
assert_eq(mock.mpc.sequencer.MetronomeEnabled.value, true, "the metronome never toggles back")
mock.clearCalls()
for _ = 1, 2 do
	turnRow3(5, 1) -- col 5 = loop
end
mock.runTicks(L, 4)
local loopSets = mock.find("SetLoop")
assert_eq(#loopSets, 1, "loop: the CW sweep sends Set(true) exactly once")
assert_eq(loopSets[1].args[1], true, "loop CW asks for ON")
mock.runTicks(L, 8)
turnRow3(5, 1)
mock.runTicks(L, 4)
assert_eq(#mock.find("SetLoop"), 1, "loop: the satisfied direction stays silent")
for _ = 1, 2 do
	turnRow3(5, -1)
end
mock.runTicks(L, 4)
loopSets = mock.find("SetLoop")
assert_eq(#loopSets, 2, "loop: CCW adds exactly one Set(false)")
assert_eq(loopSets[2].args[1], false, "loop CCW asks for OFF")
assert_eq(mock.mpc.sequencer.Loop.value, false, "the loop is off")

-- 8. rings: the send LED reflects the shadow in the same tick -----------------
session()
L.HandleMIDICC(15, 14, 64) -- abs encoder row 1 col 1: first sighting = baseline
for v = 65, 76 do
	L.HandleMIDICC(15, 14, v) -- 12 abs detents on track 1 Send 1
end
mock.tick(L) -- ONE tick: the paint runs now, the 3-tick read lag has NOT drained
-- the ring scales the track colour by the value: green = floor(127 * (0.07 + 0.93 * v^1.7) + 0.5)
local function ringGreen(v)
	local b = 0.07 + 0.93 * (v ^ 1.7)
	return math.floor(127 * b + 0.5)
end
local expected = "0," .. ringGreen(12 / 64) .. ",0"
assert_eq(mock.leds[14], expected, "the send ring reflects the shadow in the same tick as the detent")
assert_eq(
	mock.leds[14] ~= "0," .. ringGreen(0) .. ",0",
	true,
	"the ring must not show the lagged (still zero) read"
)

logs = {}
mock.setReadLag(0)
mock.reset()
L.OnUnload()
realPrint("test-shadow-step: PASS")
