-- tests/test-fader-pickup-resync.lua: T3/F9 — fader pickup references follow the
-- project instead of being taken once at load. Contract (work/TASKS.md T3):
--   1. load with volumes unreadable -> the guard is disarmed (audit M1) and a fader
--      message writes NOTHING; once the volume is readable, the resync tick sends
--      each column's position CC exactly once, arms the column at the volume
--      position, and a message at that position controls immediately,
--   2. a fader in use (picked up) is never re-referenced,
--   3. 200 idle ticks send no duplicate position CC,
--   4. an external volume change on an idle unpicked column is followed at the
--      next resync (one-shot journal line), wire-silent afterwards,
--   5. __LCXL3_HWPICKUP off sends FEAT.pickup = 0 and the software guard still
--      blocks a jump; the default sends 127.
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

local function findLog(needle)
	for _, line in ipairs(logs) do
		if line:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- count SendMIDICC calls on a fader column (ch 15, cc 5..12), optionally a value
local function faderCCs(cc, value)
	local n = 0
	for _, c in ipairs(mock.find("SendMIDICC")) do
		if c.args[1] == 15 and (cc == nil or c.args[2] == cc) and (value == nil or c.args[3] == value) then
			n = n + 1
		end
	end
	return n
end

local function posOf(v)
	return math.floor(v * 127 + 0.5)
end

-- 1. M1: unreadable at load -> no blind write; readable -> resync re-references.
assert_eq(__LCXL3_HWPICKUP, true, "hardware pickup default is on")
mock.setVolumesUnreadable(true)
L.OnLoad()
mock.reset()
mock.setVolumesUnreadable(true) -- mock.reset clears the switch; keep the F9 world
L.HandleMIDICC(15, 5, 100) -- disarmed column: the old script jumped the track here
mock.setVolumesUnreadable(false)
assert_near(mock.tracks[0].Volume.value, 0.7, 0.0001, "no blind write while the volume is unreadable")
assert_eq(faderCCs(5, 100), 0, "no position echo for the swallowed message")

mock.clearCalls()
mock.runTicks(L, 20) -- tick 20: first resyncFaders()
for col = 0, 7 do
	assert_eq(faderCCs(5 + col, 89), 1, "column " .. col .. " position CC sent exactly once at the resync tick")
end
L.HandleMIDICC(15, 5, 100) -- armed now: far movement is suppressed
assert_near(mock.tracks[0].Volume.value, 0.7, 0.0001, "resynced guard suppresses far movement")
L.HandleMIDICC(15, 5, 89) -- at the resynced reference: controls immediately
assert_near(mock.tracks[0].Volume.value, 89 / 127, 0.0001, "message at the resynced reference controls immediately")

-- 2. A fader in use (picked) is never re-referenced.
mock.clearCalls()
mock.tracks[0].Volume:set(0.1)
mock.runTicks(L, 60) -- several resync windows
assert_eq(faderCCs(5), 0, "picked-up column gets no resync position CC")
assert_near(mock.tracks[0].Volume.value, 0.1, 0.0001, "picked-up column's track is untouched by resync")

-- 3. Idle ticks are wire-silent (no duplicate position CCs).
mock.clearCalls()
mock.runTicks(L, 220)
assert_eq(faderCCs(nil), 0, "200+ idle ticks send no fader position CC")

-- 4. External volume change on an idle unpicked column is followed once.
mock.clearCalls()
logs = {}
mock.tracks[1].Volume:set(0.2)
mock.runTicks(L, 40) -- guaranteed to cross a %40 resync tick
local p2 = posOf(0.2)
assert_eq(faderCCs(6, p2), 1, "idle unpicked column follows the external volume change")
assert_eq(faderCCs(6), 1, "and only once (no duplicates)")
assert_eq(findLog("fader 2 reference 89 -> " .. p2 .. " (project readable after load)"), true,
	"one-shot reference-move journal line")
mock.clearCalls()
mock.runTicks(L, 40)
assert_eq(faderCCs(6), 0, "no duplicate CC after the reference settled")
L.HandleMIDICC(15, 6, p2) -- the moved reference engages the fader directly
assert_near(mock.tracks[1].Volume.value, p2 / 127, 0.0001, "moved reference controls immediately")

-- 5. __LCXL3_HWPICKUP off: FEAT.pickup = 0, software guard still blocks.
mock.clearCalls()
__LCXL3_HWPICKUP = false
L.OnLoad()
local pickupOff, pickupOn = false, false
for _, c in ipairs(mock.find("SendMIDICC")) do
	if c.args[1] == 6 and c.args[2] == 70 then
		if c.args[3] == 0 then
			pickupOff = true
		end
		if c.args[3] == 127 then
			pickupOn = true
		end
	end
end
assert_eq(pickupOff, true, "HWPICKUP off sends FEAT.pickup = 0")
assert_eq(pickupOn, false, "HWPICKUP off sends no pickup = 127")
L.HandleMIDICC(15, 5, 5) -- far below track 1's current volume (0.1 -> ref 13)
assert_near(mock.tracks[0].Volume.value, 0.1, 0.0001, "software guard still blocks a jump with HW pickup off")
L.HandleMIDICC(15, 5, posOf(0.1))
assert_near(mock.tracks[0].Volume.value, posOf(0.1) / 127, 0.0001, "reference crossing still engages")

-- restore the default for the final load (owner tunables persist by design)
__LCXL3_HWPICKUP = true
mock.clearCalls()
L.OnLoad()
pickupOn = false
for _, c in ipairs(mock.find("SendMIDICC")) do
	if c.args[1] == 6 and c.args[2] == 70 and c.args[3] == 127 then
		pickupOn = true
	end
end
assert_eq(pickupOn, true, "default load sends FEAT.pickup = 127 again")

L.OnUnload()
_G.print = realPrint
print("test-fader-pickup-resync: PASS")
