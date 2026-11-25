-- tests/test-qlink-order.lua: the knob -> Q-Link order as shipped (column-major,
-- device-checked 2026-11-20) PLUS the set-dependent switch (device finding
-- 2026-11-27): on the MPC's GLOBAL/main Q-Link page the params sit at indices
-- 0..15 in order, so a loaded set matching that signature (TRACK LEVEL /
-- PLAYHEAD / TIME DIVISION) must flip the map to identity; plugin/TRACK sets
-- and unreadable names stay column-major. The page-interleaved variant was
-- tried and REJECTED on hardware 2026-11-25: with an OPx synth the plugin
-- macros landed reversed (knob (0,0) = Macro 4 ... knob (0,3) = Macro 1), so
-- the four row-1 knobs MUST reach Q-Links 13,9,5,1 (indices 12,8,4,0) for
-- macros 1-4 to come out ascending. Pins: the load-time map line, the table
-- being a permutation of 0..15, and driven anchors reading the Twist target.
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

local realPrint = print
local logs = {}
_G.print = function(m)
	logs[#logs + 1] = tostring(m)
end
local function logHas(needle)
	for _, l in ipairs(logs) do
		if l:find(needle, 1, true) then
			return true
		end
	end
	return false
end
local function logCount(needle)
	local n = 0
	for _, l in ipairs(logs) do
		if l:find(needle, 1, true) then
			n = n + 1
		end
	end
	return n
end

local QLINK_ORDER = { 12, 8, 4, 0, 13, 9, 5, 1, 14, 10, 6, 2, 15, 11, 7, 3 }

L.OnLoad()
for i = 0, 15 do
	mock.setQlinkTarget(i, "target" .. i)
end
L.HandleMIDICC(6, 30, 2) -- control mode: rel CCs stay script-owned
mock.runTicks(L, 4)

-- 0. the load-time journal names the shipped order (indices AND screen numbers)
assert_eq(
	logHas("qlink map: track index row1 [12,8,4,0,13,9,5,1] row2 [14,10,6,2,15,11,7,3]"),
	true,
	"OnLoad journals the active qlink map, labelled track (0-based indices)"
)
assert_eq(
	logHas("| screen Q-Link numbers row1 [13,9,5,1,14,10,6,2] row2 [15,11,7,3,16,12,8,4]"),
	true,
	"OnLoad journals the map in MPC screen numbering (1-based)"
)

-- 1. the table is a permutation of 0..15 --------------------------------------
local seen = {}
for p = 0, 15 do
	local q = QLINK_ORDER[p + 1]
	assert_eq(seen[q], nil, "table entry " .. p + 1 .. " repeats Q-Link index " .. q)
	assert_eq(q >= 0 and q <= 15, true, "table entry " .. p + 1 .. " out of range: " .. q)
	seen[q] = true
end

-- 2. driven anchors (OPx regression: row-1 knobs 1-4 -> indices 12,8,4,0 so
--    plugin macros 1-4 come out ascending, not reversed) ----------------------
local anchors = {
	{ 0, 0, 12, "OPx Macro 1" },
	{ 0, 1, 8, "OPx Macro 2" },
	{ 0, 2, 4, "OPx Macro 3" },
	{ 0, 3, 0, "OPx Macro 4" },
	{ 0, 4, 13, "row 1 k5" },
	{ 0, 7, 1, "row 1 k8" },
	{ 1, 0, 14, "row 2 k1" },
	{ 1, 4, 15, "row 2 k5" },
}
for _, a in ipairs(anchors) do
	local row, col, want = a[1], a[2], a[3]
	mock.clearCalls()
	mock.emitRel(row, col, 1) -- +1 detent on the knob
	local twists = mock.find("Twist")
	assert_eq(#twists, 1, "knob (" .. row .. "," .. col .. ") [" .. a[4] .. "] yields one Twist")
	assert_eq(twists[1].args[1], want,
		"knob (" .. row .. "," .. col .. ") [" .. a[4] .. "] twists Q-Link index " .. want)
	mock.runTicks(L, 4) -- drain the settle/screen pump before the next knob
end

-- 3. GLOBAL-page switch: with the global signature loaded (params at 0..15,
--    device dump 2026-11-27) the map must become IDENTITY and the change must
--    be journaled once -----------------------------------------------------
mock.setQlinkTarget(0, "TRACK LEVEL")
mock.setQlinkTarget(1, "PLAYHEAD")
mock.setQlinkTarget(4, "TIME DIVISION")
mock.runTicks(L, 12) -- guarantee a 500 ms refresh boundary (ticks % 10 == 5)
assert_eq(logCount("qlink order: global (identity, params at 0..15)"), 1,
	"global signature flips the order exactly once")
local globalAnchors = {
	{ 0, 0, 0, "GLOBAL knob 1 = TRACK LEVEL" },
	{ 0, 1, 1, "GLOBAL knob 2 = PLAYHEAD" },
	{ 1, 0, 8, "GLOBAL row 2 k1" },
}
for _, a in ipairs(globalAnchors) do
	mock.clearCalls()
	mock.emitRel(a[1], a[2], 1)
	local twists = mock.find("Twist")
	assert_eq(#twists, 1, "global knob (" .. a[1] .. "," .. a[2] .. ") yields one Twist")
	assert_eq(twists[1].args[1], a[3],
		"global knob (" .. a[1] .. "," .. a[2] .. ") [" .. a[4] .. "] twists index " .. a[3])
	mock.runTicks(L, 4)
end

-- 4. back to a plugin/TRACK set: names stop matching -> column-major again ---
for i = 0, 15 do
	mock.setQlinkTarget(i, "Macro " .. (i + 1))
end
mock.runTicks(L, 12)
assert_eq(logCount("qlink order: track (column-major, plugin slots)"), 1,
	"non-matching names flip back to column-major exactly once")
mock.clearCalls()
mock.emitRel(0, 0, 1)
assert_eq(mock.find("Twist")[1].args[1], 12, "knob (0,0) column-major again (index 12)")
mock.clearCalls()
mock.emitRel(0, 1, 1)
assert_eq(mock.find("Twist")[1].args[1], 8, "knob (0,1) column-major again (index 8)")
mock.runTicks(L, 4)

-- 5. unreadable/empty names: the flag must NOT flip (degrade keeps the order) -
local flipsBefore = logCount("qlink order:")
for i = 0, 15 do
	mock.setQlinkTarget(i, false) -- explicitly unassigned: names unreadable
end
mock.runTicks(L, 12)
assert_eq(logCount("qlink order:"), flipsBefore, "unreadable names never flip the order")
mock.clearCalls()
mock.emitRel(0, 0, 1)
assert_eq(mock.find("Twist")[1].args[1], 12, "unreadable names stay column-major (0,0 -> 12)")
mock.clearCalls()
mock.emitRel(0, 1, 1)
assert_eq(mock.find("Twist")[1].args[1], 8, "unreadable names stay column-major (0,1 -> 8)")
mock.runTicks(L, 4)

L.OnUnload()
_G.print = realPrint
print("test-qlink-order: PASS")
