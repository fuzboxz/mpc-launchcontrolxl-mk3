-- tests/test-automation-filter.lua: control-mode row 3 col 6 (task T2).
-- The enumeration is ASYNCHRONOUS and lag-proof: the first turn of the knob
-- kicks off a scan (one Advance per discovered type, the read polled every
-- tick, complete when the read returns to the start type -- the advances
-- restored it by themselves); detents are ignored while scanning and the
-- display shows "scanning". After the scan, stepping is two detents per list
-- step and SATURATES at both ends (the old per-detent wrap-around cycling is
-- retired). A missing Set degrades to the detent-divided CW-only Advance path
-- without erroring.
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

local function pump(n)
	for _ = 1, (n or 12) do
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

-- 1: the FIRST turn starts the asynchronous scan; the detent itself does not
-- step, the scan advances the cycle but never writes Set.
turn(1)
assert_eq(mock.count("AdvanceGlobalAutomationFilterType") == 1, true,
	"the first turn kicks off the scan with exactly one Advance")
assert_eq(mock.count("SetGlobalAutomationFilterType"), 0, "the scan never writes Set")
assert_eq(filter(), "Latch", "the scan has advanced to the second type")
pump(3)
assert_eq(overlayText(), "scanning", "the display shows 'scanning' while the enum is scanned")
pump(20)
assert_eq(filter(), "Off", "the scan restores the start type by itself (full cycle)")
assert_eq(overlayText(), "Off", "after the scan the display follows the restored type")

-- 2: after the scan, a CW detent steps the enum with Set (two detents per
-- step: the second detent completes the unit, so turn twice per step).
turn(1)
turn(1)
assert_eq(mock.count("SetGlobalAutomationFilterType"), 1, "a CW step uses SetGlobalAutomationFilterType")
local cw1Arg = mock.find("SetGlobalAutomationFilterType")[1].args[1]
assert_eq(ENUM[cw1Arg] == true, true, "CW Set arg is a member of the 4-value enum")
assert_eq(filter(), "Latch", "CW from Off lands on the NEXT type")
assert_eq(filter(), cw1Arg, "CW step applied the Set type")
pump()
assert_eq(overlayText(), "Latch", "overlay shows the actual type after CW")
assert_eq(overlayText() ~= "cycle", true, "overlay is not the constant 'cycle'")

-- 3: CCW steps back through the same enum (not the CW-only Advance path).
turn(-1)
turn(-1)
assert_eq(mock.count("SetGlobalAutomationFilterType"), 1, "a CCW step uses SetGlobalAutomationFilterType")
assert_eq(filter(), "Off", "CCW steps back to the previous type")
pump()
assert_eq(overlayText(), "Off", "overlay follows the CCW type")

-- 4: CCW from the start of the cycle SATURATES (the old build wrapped to the
-- last type -- the deliberate F8 change: enumerated stepping never wraps).
mock.mpc.project.SetGlobalAutomationFilterType("Off")
pump(2)
turn(-1)
turn(-1)
assert_eq(filter(), "Off", "CCW from the first type saturates (no wrap)")
assert_eq(mock.count("SetGlobalAutomationFilterType"), 0, "the saturated turn sends no write")

-- 5: Degrade: with SetGlobalAutomationFilterType removed, the first turn
-- starts the CW-only Advance fallback (logged once) and it is
-- detent-divided: one Advance per two CW detents; a CCW detent is a no-op
-- (the scan cannot run backwards).
L.OnLoad()
mock.reset()
logs = {}
local savedSet = mock.mpc.project.SetGlobalAutomationFilterType
mock.mpc.project.SetGlobalAutomationFilterType = nil
local ok = pcall(function()
	L.HandleMIDICC(6, 30, 2) -- control mode
	L.HandleMIDICC(15, 99, 65) -- CW detent 1: enters the degrade (half a unit)
	L.HandleMIDICC(15, 99, 65) -- CW detent 2: completes the unit -> one Advance
end)
assert_eq(ok, true, "missing Set degrades without erroring")
assert_eq(mock.count("SetGlobalAutomationFilterType"), 0, "no Set call when the API is missing")
assert_eq(mock.count("AdvanceGlobalAutomationFilterType"), 1, "the degrade advances once per two detents")
local fallbackLines = 0
for _, l in ipairs(logs) do
	if l:find("CW-only Advance fallback", 1, true) then
		fallbackLines = fallbackLines + 1
	end
end
assert_eq(fallbackLines, 1, "the degrade is logged exactly once")
-- Further detents keep advancing on the same cadence and do not log again.
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
L.HandleMIDICC(15, 99, 65) -- CW advances (the only direction the degrade has)
L.HandleMIDICC(15, 99, 63) -- CCW is a no-op in the degrade: the scan cannot run backwards
L.HandleMIDICC(15, 99, 63)
assert_eq(mock.count("AdvanceGlobalAutomationFilterType"), 1, "the degrade advances CW only (a CCW detent is a no-op)")
assert_eq(nonRaw(#logs), before, "the degrade log is not repeated")
mock.mpc.project.SetGlobalAutomationFilterType = savedSet

L.OnUnload()
_G.print = realPrint
print("test-automation-filter: PASS")
