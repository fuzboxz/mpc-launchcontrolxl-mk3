-- tests/test-master.lua: row-3 col-7 master volume on the device-disproven
-- masterTracks[0] path (triage w5/r5). The default mock slot is dead: reads
-- 0.0, writes silently swallowed - indistinguishable from the device (D2/D3),
-- and a silent rejection is undetectable from Lua, so the script must not
-- pretend the write landed. The two detectable failures are covered with
-- explicit fixtures: a read-only property (write raises -> one "master-write"
-- log, logOnce) and an unreadable Volume (nil read -> one "master-read" log,
-- no write attempted).
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

local function countLogs(needle)
	local n = 0
	for _, line in ipairs(logs) do
		if line:find(needle, 1, true) then
			n = n + 1
		end
	end
	return n
end

-- Row-3 global page, col 7 = master volume (relative CC 100, delta +-1).
local function turnMaster(dir)
	L.HandleMIDICC(15, 100, dir > 0 and 65 or 63)
end

L.OnLoad()
L.HandleMIDICC(6, 30, 2) -- DAW Control mode
logs = {}

-- (1) default dead slot: no blind write, no failure log, no crash. The read
-- back stays 0.0 because the slot swallows writes.
local before = mock.mpc.tracks.masterTracks[0].Volume.value
turnMaster(1)
turnMaster(-1)
local after = mock.mpc.tracks.masterTracks[0].Volume.value
assert_eq(before, 0.0, "dead master slot reads 0.0 before the turn")
assert_eq(after, 0.0, "dead master slot stays 0.0 (no blind write landed)")
assert_eq(countLogs("master volume write failed"), 0, "silent dead slot logs nothing (undetectable)")
assert_eq(countLogs("master volume read failed"), 0, "dead slot read succeeds, so no read log")

-- (2) read-only fixture: the write raises -> exactly one log, then logOnce
-- suppresses the second turn's line. The quiet gap makes the stepper re-read
-- the device (the shadow only lives for STEP_QUIET ticks).
mock.setMasterSlot("readonly")
for _ = 1, 8 do
	L.HandleTimer()
end
turnMaster(1)
assert_eq(countLogs("master volume write failed"), 1, "read-only master logs one write failure")
turnMaster(1)
assert_eq(countLogs("master volume write failed"), 1, "second turn does not log again (logOnce)")

-- (3) nil-read fixture: Volume cannot be read -> one read log, and no write is
-- even attempted (the write failure count must not grow). The quiet gap first
-- is what sends the stepper back to the read path (a fresh shadow would
-- legitimately step without any read).
mock.setMasterSlot("nilread")
for _ = 1, 8 do
	L.HandleTimer()
end
turnMaster(1)
assert_eq(countLogs("master volume read failed"), 1, "unreadable master logs one read failure")
assert_eq(countLogs("master volume write failed"), 1, "no blind write attempted on an unreadable slot")

-- (4) live slot sanity: the same turn path really can move a live slot, so the
-- fixture above is a slot property, not a broken handler.
mock.makeMasterLive()
mock.mpc.tracks.masterTracks[0].Volume:set(0.5)
for _ = 1, 8 do
	L.HandleTimer()
end
turnMaster(1)
assert_eq(mock.mpc.tracks.masterTracks[0].Volume.value > 0.5, true, "live master slot moves on a turn")

L.OnUnload()
_G.print = realPrint
print("test-master: PASS")
