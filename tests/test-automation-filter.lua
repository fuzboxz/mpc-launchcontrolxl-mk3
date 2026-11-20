-- tests/test-automation-filter.lua: control-mode row 3 col 6 steps the global
-- automation filter through the mock's 4-value enum via
-- SetGlobalAutomationFilterType (CW and CCW), the overlay shows the actual type
-- name (never the constant "cycle"), and removing Set degrades to the CW-only
-- Advance path without erroring.
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

local ENUM = { Off = true, Latch = true, Touch = true, Write = true }

local function filter()
	return mock.mpc.project.GlobalAutomationFilterType.value
end

local function overlayText()
	local last = nil
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" and s.target == 35 and s.field == 2 then
			last = s.text
		end
	end
	return last
end

-- One row-3 col-6 detent: relative CC 93+6=99, pivot 64.
local function turn(delta)
	mock.clearCalls()
	mock.sysex = {}
	L.HandleMIDICC(15, 99, 64 + delta)
end

local function pump()
	for _ = 1, 12 do
		L.HandleTimer()
	end
end

L.OnLoad()
mock.reset()
for _ = 1, 40 do
	L.HandleTimer() -- settle: drain the load-time display backlog (2 texts/tick)
end
mock.mpc.project.SetGlobalAutomationFilterType("Off") -- deterministic start
L.HandleMIDICC(6, 30, 2) -- control mode

local start = filter()
assert_eq(start, "Off", "filter starts at a known type")

-- CW: SetGlobalAutomationFilterType steps the enum forward.
turn(1)
assert_eq(mock.count("SetGlobalAutomationFilterType"), 1, "CW step uses SetGlobalAutomationFilterType")
local cw1Arg = mock.find("SetGlobalAutomationFilterType")[1].args[1]
assert_eq(ENUM[cw1Arg] == true, true, "CW Set arg is a member of the 4-value enum")
assert_eq(filter(), "Latch", "CW from Off lands on the NEXT type (the cycle includes its start)")
assert_eq(filter(), cw1Arg, "CW step applied the Set type")
assert_eq(filter() ~= start, true, "CW step changed the filter type")
local afterCW1 = filter()
pump()
assert_eq(overlayText(), afterCW1, "overlay shows the actual type after CW")
assert_eq(overlayText() ~= "cycle", true, "overlay is not the constant 'cycle'")

-- CW again: another distinct enum member.
turn(1)
assert_eq(mock.count("SetGlobalAutomationFilterType"), 1, "second CW step uses SetGlobalAutomationFilterType")
local cw2Arg = mock.find("SetGlobalAutomationFilterType")[1].args[1]
assert_eq(ENUM[cw2Arg] == true, true, "second CW Set arg is a member of the 4-value enum")
assert_eq(filter(), cw2Arg, "second CW step applied the Set type")
assert_eq(filter() ~= afterCW1, true, "second CW step moved to a different type")
local afterCW2 = filter()
pump()
assert_eq(overlayText(), afterCW2, "overlay follows the second CW type")

-- CCW: steps back through the same enum (not the CW-only Advance path).
turn(-1)
assert_eq(mock.count("SetGlobalAutomationFilterType"), 1, "CCW step uses SetGlobalAutomationFilterType")
local ccwArg = mock.find("SetGlobalAutomationFilterType")[1].args[1]
assert_eq(ENUM[ccwArg] == true, true, "CCW Set arg is a member of the 4-value enum")
assert_eq(filter(), ccwArg, "CCW step applied the Set type")
assert_eq(filter(), afterCW1, "CCW steps back to the previous type")
pump()
assert_eq(overlayText(), afterCW1, "overlay follows the CCW type")

-- CCW from the start of the cycle wraps to the LAST type (Off -> Write), which
-- also proves the enumerated list is the full cycle, not a truncated one.
mock.mpc.project.SetGlobalAutomationFilterType("Off")
turn(-1)
assert_eq(filter(), "Write", "CCW from Off wraps to the last type in the cycle")

-- Degrade: with SetGlobalAutomationFilterType removed, the script keeps CW-only
-- Advance stepping and does not error.
L.OnLoad()
mock.reset()
local savedSet = mock.mpc.project.SetGlobalAutomationFilterType
mock.mpc.project.SetGlobalAutomationFilterType = nil
logs = {}
local ok = pcall(function()
	L.HandleMIDICC(6, 30, 2) -- control mode
	L.HandleMIDICC(15, 99, 65) -- CW detent
end)
assert_eq(ok, true, "missing Set degrades without erroring")
assert_eq(mock.count("SetGlobalAutomationFilterType"), 0, "no Set call when the API is missing")
assert_eq(mock.count("AdvanceGlobalAutomationFilterType") >= 1, true, "CW turn falls back to Advance")
local fallbackLines = 0
for _, l in ipairs(logs) do
	if l:find("CW-only Advance fallback", 1, true) then
		fallbackLines = fallbackLines + 1
	end
end
assert_eq(fallbackLines, 1, "the degrade is logged exactly once")
-- A second turn still advances and does not log again (logOnce). RAW lines
-- from the (temporary) wire-tap diagnostic are ignored.
local function nonRaw(n)
	local c = 0
	for i = 1, n do
		if not (logs[i]:find("RAW ch=", 1, true)) then
			c = c + 1
		end
	end
	return c
end
local before = nonRaw(#logs)
L.HandleMIDICC(15, 99, 63)
assert_eq(mock.count("AdvanceGlobalAutomationFilterType") >= 2, true, "the degrade keeps advancing per detent")
assert_eq(nonRaw(#logs), before, "the degrade log is not repeated")
mock.mpc.project.SetGlobalAutomationFilterType = savedSet

L.OnUnload()
_G.print = realPrint
print("test-automation-filter: PASS")
