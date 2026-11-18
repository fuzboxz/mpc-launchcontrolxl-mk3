-- tests/test-manual.lua: the ACTIONS table (the generated manual's source of
-- truth) stays complete: every dispatched control has an entry.
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

local A = L.ACTIONS
assert_eq(type(A), "table", "ACTIONS exposed")

-- index the entries by cc
local byCC = {}
for _, a in ipairs(A) do
	assert_eq(type(a.group), "string", "entry has a group")
	assert_eq(type(a.label), "string", "entry has a label")
	assert_eq(type(a.plain), "string", "entry has a plain description")
	assert_eq(type(a.shift), "string", "entry has a shift description")
	assert_eq(type(a.cc), "number", "entry has a CC")
	assert_eq(type(a.ch), "number", "entry has a channel")
	assert_eq(a.cc >= 0 and a.cc <= 127, true, "CC in range")
	assert_eq(a.ch >= 1 and a.ch <= 16, true, "channel in range (1-based)")
	byCC[a.cc] = true
end

-- every dispatched button has an entry
local expected = { 65, 66, 102, 103, 104, 106, 107, 116, 118, 30, 31, 63, 5, 13, 21, 29, 37, 45 }
for _, cc in ipairs(expected) do
	assert_eq(byCC[cc], true, "ACTIONS covers CC " .. cc)
end

-- the palette exposes the named RGB colours the paint functions use, with a
-- clear on/off contrast: every bright colour is far brighter than its dim twin
local P = L.PALETTE
local function lum(c)
	return 0.3 * c[1] + 0.5 * c[2] + 0.2 * c[3]
end
for _, name in ipairs({ "off", "whiteDim", "white", "red", "redDim", "green", "greenDim", "blue", "blueDim", "orange", "orangeDim", "yellow", "purple", "turquoise", "darkBlue" }) do
	assert_eq(type(P[name]), "table", "palette has " .. name)
	for i = 1, 3 do
		assert_eq(type(P[name][i]), "number", "palette " .. name .. " component " .. i)
		assert_eq(P[name][i] >= 0 and P[name][i] <= 127, true, "palette " .. name .. " component in range")
	end
end
for _, pair in ipairs({ { "white", "whiteDim" }, { "red", "redDim" }, { "green", "greenDim" }, { "blue", "blueDim" }, { "orange", "orangeDim" } }) do
	local ratio = lum(P[pair[1]]) / math.max(lum(P[pair[2]]), 1)
	assert_eq(ratio >= 4, true, pair[1] .. " is at least 4x brighter than " .. pair[2])
end

-- the registered input set is exactly the surface map
local expectedPairs = {}
for cc = 5, 12 do
	expectedPairs["15:" .. cc] = true
end
for cc = 13, 36 do
	expectedPairs["15:" .. cc] = true
end
for cc = 77, 100 do
	expectedPairs["15:" .. cc] = true
end
for cc = 5, 12 do
	expectedPairs["14:" .. cc] = true
end
for cc = 77, 100 do
	expectedPairs["14:" .. cc] = true
end
for cc = 37, 52 do
	expectedPairs["0:" .. cc] = true
end
for _, cc in ipairs({ 65, 66, 102, 103, 104, 106, 107, 116, 118 }) do
	expectedPairs["0:" .. cc] = true
end
for _, cc in ipairs({ 30, 31, 63 }) do
	expectedPairs["6:" .. cc] = true
end
local gotPairs = {}
for _, pair in ipairs(L.SURFACE_CC) do
	gotPairs[pair[1] .. ":" .. pair[2]] = true
end
for k in pairs(expectedPairs) do
	assert_eq(gotPairs[k], true, "SURFACE_CC covers " .. k)
end
for k in pairs(gotPairs) do
	assert_eq(expectedPairs[k], true, "SURFACE_CC has no extra " .. k)
end
print("test-manual: PASS")
