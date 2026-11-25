-- tests/test-native-routing.lua: T5 -- the dormant native Q-Link routing path.
-- Akai's shipped signatures (mpc310 kit scripts, mpkMiniMkIV.lua):
-- AddInfiniteCCToQLink(channel, cc, qlinkIndex), RemoveInfiniteCCToQLink(channel, cc),
-- IsQLinkMappedInfinite(channel, cc), SetQLinkFineAdjust(bool). The script binds
-- (CH_ANALOG, cc, QLINK_ORDER slot), verifies each binding non-circularly
-- (query-flip: mapped -> removed -> gone -> re-added -> mapped), falls back per
-- encoder to the script-side Twist driver when verification fails, never calls
-- SetInfiniteCCMagnitude (signature unprobed), and ships OFF (__LCXL3_NATIVE,
-- default false, pending the direction probe 10).
package.path = "./tests/?.lua;" .. package.path
local mock = require("mock-mpc")
_G.mpc = mock.mpc
_G.dev = mock.dev
_G.LaunchControlXL3 = mock.dev
dofile(os.getenv("LCXL3_LUA") or "script/LaunchControlXL3.lua")
local L = LaunchControlXL3
L.OnLoad()

local QLINK_ORDER = { 12, 8, 4, 0, 13, 9, 5, 1, 14, 10, 6, 2, 15, 11, 7, 3 } -- column-major (matches script QLINK_ORDER)

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

-- 1. shipped default: the flag is false and the rel CCs stay script-side ------
assert_eq(__LCXL3_NATIVE, false, "shipped default: native routing off")
mock.reset()
L.HandleMIDICC(6, 30, 2) -- enter control mode
assert_eq(mock.count("AddInfiniteCCToQLink"), 0, "flag off: no native binds")
assert_eq(mock.dev.mappings.script.IsCCMappedToScript(15, 77), true, "flag off: rel CCs stay script-owned")
mock.setQlinkTarget(12, "Cutoff")
L.HandleMIDICC(15, 77, 65)
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "flag off: script-side Twist drives the knob")

-- 2. flag on, honest mock: 16/16 bind, verified, fine adjust, no magnitude ----
mock.reset()
__LCXL3_NATIVE = true -- test-only; the shipped default above stays false
L.HandleMIDICC(6, 30, 1) -- section 1 left control mode: force a real transition
L.HandleMIDICC(6, 30, 2)
assert_eq(mock.count("AddInfiniteCCToQLink"), 32, "bind + query-flip re-add: 2 Adds per encoder")
assert_eq(mock.count("RemoveInfiniteCCToQLink"), 16, "one flip-remove per encoder")
assert_eq(mock.count("IsQLinkMappedInfinite"), 48, "3 queries per encoder: the non-circular flip ran")
for knob = 0, 15 do
	local cc = 77 + knob
	assert_eq(mock.qlinkMapped["15:" .. cc], QLINK_ORDER[knob + 1],
		"knob " .. knob .. " (cc " .. cc .. ") is bound to its QLINK_ORDER slot")
end
local fa = mock.find("SetQLinkFineAdjust")
assert_eq(#fa == 1 and #fa[1].args == 1 and fa[1].args[1] == false, true,
	"SetQLinkFineAdjust(false): called once, with a single bool argument")
assert_eq(mock.count("SetInfiniteCCMagnitude"), 0, "SetInfiniteCCMagnitude is never called")
assert_eq(mock.count("RemoveCCToScript"), 16, "the script drops every rel CC it handed over")
assert_eq(mock.count("AddCCToScript"), 0, "no CC fell back")
assert_eq(logHas("qlinks routed: 16/16 encoders"), true, "journal names the routed count")
assert_eq(logHas("SetInfiniteCCMagnitude not called"), true, "journal says the magnitude setter is unprobed")

-- routed knobs swallow both input streams: rel is the MPC's, abs must not double-step
mock.setQlinkTarget(12, "Cutoff")
mock.clearCalls()
L.HandleMIDICC(15, 77, 65) -- rel stream, knob 0
L.HandleMIDICC(15, 13, 60) -- abs stream, same knob
L.HandleTimer()
assert_eq(mock.count("Twist"), 0, "routed knob: both streams are swallowed by the script")

-- leaving control mode hands every CC back with the verified (channel, cc) form
mock.clearCalls()
L.HandleMIDICC(6, 30, 1) -- mixer
assert_eq(mock.count("RemoveInfiniteCCToQLink"), 16, "unmap removes all 16 bindings")
for _, r in ipairs(mock.find("RemoveInfiniteCCToQLink")) do
	assert_eq(r.args[1], 15, "unmap uses the (channel, cc) form")
end
assert_eq(mock.count("AddCCToScript"), 16, "unmap gives every CC back to the script")
assert_eq(mock.dev.mappings.script.IsCCMappedToScript(15, 77), true, "rel CCs are script-owned again")

-- 3. hostile host: accepts anything, stores nothing -> every encoder falls back
mock.reset()
mock.setNativeMappingHostile(true)
__LCXL3_NATIVE = true
L.HandleMIDICC(6, 30, 2)
assert_eq(#mock.qlinkMapped, 0, "the hostile host stored nothing")
assert_eq(mock.count("AddCCToScript"), 16, "every encoder fell back to the script")
assert_eq(logHas("qlink routing failed for all 16 encoders"), true, "the journal says so")
mock.setQlinkTarget(12, "Cutoff")
L.HandleMIDICC(15, 77, 65)
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "the script-side driver still works after the fallback")

-- 4. per-encoder fallback: one knob's verification fails, the rest route --------
mock.reset()
local qmap = mock.dev.mappings.controlSurface.qlinks
local honestQuery = qmap.IsQLinkMappedInfinite
qmap.IsQLinkMappedInfinite = function(ch, cc) -- the host lies about exactly one key
	if cc == 78 then
		return false
	end
	return honestQuery(ch, cc)
end
__LCXL3_NATIVE = true
L.HandleMIDICC(6, 30, 1) -- section 3 left control mode: force a real transition
L.HandleMIDICC(6, 30, 2)
assert_eq(mock.qlinkMapped["15:77"], 12, "knob 0 still routes to its QLINK_ORDER slot")
assert_eq(mock.qlinkMapped["15:78"], nil, "knob 1's binding failed verification and was undone")
assert_eq(mock.dev.mappings.script.IsCCMappedToScript(15, 78), true, "knob 1's CC is back on the script")
assert_eq(mock.dev.mappings.script.IsCCMappedToScript(15, 77), false, "knob 0's CC is hardware-owned")
mock.setQlinkTarget(12, "Cutoff")
mock.clearCalls()
L.HandleMIDICC(15, 77, 65) -- knob 0: routed, swallowed
L.HandleMIDICC(15, 78, 65) -- knob 1: fell back, script-side
L.HandleTimer()
assert_eq(mock.count("Twist"), 1, "only the failed knob twists script-side")

-- 5. the sweep removes stale leftovers and logs the real count -----------------
mock.reset()
__LCXL3_NATIVE = false -- the shipped path: sweep-only
mock.qlinkMapped["15:95"] = 5 -- a stale native binding outside the routed rel range (77-92)
L.HandleMIDICC(6, 30, 1) -- section 4 left control mode: force a real transition
L.HandleMIDICC(6, 30, 2)
assert_eq(mock.qlinkMapped["15:95"], nil, "the sweep removes the stale binding")
assert_eq(logHas("native qlink bindings swept: 1 removed"), true, "the sweep logs the real count")
assert_eq(mock.count("AddInfiniteCCToQLink"), 0, "flag off: the sweep never binds")

-- without the query API the sweep degrades to a blind sweep and says the count
-- is unverified instead of inventing one
qmap.IsQLinkMappedInfinite = nil
L.HandleMIDICC(6, 30, 1) -- mixer
mock.clearCalls() -- measure only the blind-sweep window
L.HandleMIDICC(6, 30, 2) -- control again: sweep with no query API
assert_eq(mock.count("RemoveInfiniteCCToQLink"), 24, "blind sweep still covers cc 77..100")
assert_eq(logHas("count unverified"), true, "the blind sweep does not claim a verified count")

L.OnUnload()
_G.print = realPrint
print("test-native-routing: PASS")
