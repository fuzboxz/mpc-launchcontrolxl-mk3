-- tests/test-screen-pipeline.lua: the screen queue must collapse a fast fader
-- gesture to the FINAL value per changed target:field (no stale mid-sweep text),
-- pump at most 6 messages per timer tick, and send a single post-burst
-- re-assert per key once on a later quiet tick. The 2-line overlay text must
-- also precede its 7Fh trigger in the pumped order.
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

local function ticks(n)
	for _ = 1, n do
		L.HandleTimer()
	end
end

local function textOf(target, field)
	local last = nil
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" and s.target == target and s.field == field then
			last = s.text -- the latest write wins
		end
	end
	return last
end

L.OnLoad()
ticks(40) -- drain the initial fader track map

-- Engage software pickup on every fader (0 first, then 127 crosses the ref).
for col = 0, 7 do
	L.HandleMIDICC(15, 5 + col, 0)
	L.HandleMIDICC(15, 5 + col, 127)
end
ticks(40)

-- Capture the FINAL value text per fader with one slow move, then park each
-- fader on a different start value and let the cache settle there.
local final, finalText, startText = {}, {}, {}
for col = 0, 7 do
	final[col] = 90 + col
	L.HandleMIDICC(15, 5 + col, final[col])
end
ticks(40)
for col = 0, 7 do
	finalText[col] = textOf(5 + col, 2)
end
for col = 0, 7 do
	L.HandleMIDICC(15, 5 + col, 20 + col)
end
ticks(40)
for col = 0, 7 do
	startText[col] = textOf(5 + col, 2)
	assert_eq(finalText[col] ~= nil and finalText[col] ~= startText[col], true, "fader " .. (col + 1) .. " final text differs from its start text")
end

-- Fast gesture: many values for every fader between two HandleTimer calls.
mock.sysex = {}
for step = 0, 7 do
	for col = 0, 7 do
		L.HandleMIDICC(15, 5 + col, 20 + col + step * 10)
	end
end

-- Pump tick by tick. Each tick may send at most 2 texts (4 raws), every
-- field-2 fader text must already be the FINAL value (never a mid-sweep
-- value), and each changed key is sent exactly twice: once normally, once as
-- the re-assert.
local perKey = {}
local stale = {}
for t = 1, 14 do
	mock.sysex = {}
	L.HandleTimer()
	local count = 0
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" then
			count = count + 1
			local key = s.target .. ":" .. s.field
			perKey[key] = (perKey[key] or 0) + 1
			if s.field == 2 and s.target >= 5 and s.target <= 12 then
				local col = s.target - 5
				if s.text ~= finalText[col] then
					stale[#stale + 1] = key .. "=" .. s.text
				end
			end
		end
	end
	assert_eq(count <= 2, true, "tick " .. t .. " respects the 2-text screen budget (sent " .. count .. ")")
end
assert_eq(#stale, 0, "no stale mid-sweep text after the gesture (" .. table.concat(stale, ", ") .. ")")
for col = 0, 7 do
	local key = (5 + col) .. ":2"
	assert_eq(perKey[key], 2, "fader " .. (col + 1) .. " final text sent once + a single re-assert")
end

-- Overlay ordering: the two text lines are pumped before the 7Fh trigger.
mock.sysex = {}
L.HandleMIDICC(0, 102, 127) -- bank +1 -> "tracks ..." overlay
ticks(4)
local textPos, trigPos = nil, nil
for i, s in ipairs(mock.screen()) do
	if s.op == "text" and s.target == 54 and s.field == 0 then
		textPos = textPos or i
	end
	if s.op == "configure" and s.target == 54 and s.config == 127 then
		trigPos = trigPos or i
	end
end
assert_eq(textPos ~= nil and trigPos ~= nil and textPos < trigPos, true, "overlay text precedes its 7Fh trigger")

-- (d) single-key fast fader burst: the queue collapses the whole sweep to the
-- FINAL text, it is sent exactly twice (drain + ONE re-assert on a later
-- quiet tick), and no stale mid-sweep text is ever pumped. A single-key
-- gesture must arm the re-assert exactly like a multi-key burst.
for _ = 1, 40 do
	L.HandleTimer() -- settle: drain everything above incl. its re-asserts
end
mock.sysex = {}
L.HandleMIDICC(15, 5, 105) -- slow move first: cache the baseline text
for _ = 1, 40 do
	L.HandleTimer()
end
local baselineText = textOf(5, 2)
for v = 20, 100, 4 do
	L.HandleMIDICC(15, 5, v) -- the burst: many values between two ticks
end
L.HandleMIDICC(15, 5, 60) -- a DIFFERENT final value
local expected = string.format("%.1f dB", 40 * math.log(60 / 127, 10) + 6)
assert_eq(baselineText ~= expected, true, "the burst final text differs from the baseline")
local seenAt = {}
for t = 1, 12 do
	mock.sysex = {}
	L.HandleTimer()
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" and s.target == 5 and s.field == 2 then
			assert_eq(s.text == expected, true, "tick " .. t .. " carries only the final text (got " .. s.text .. ")")
			seenAt[#seenAt + 1] = t
		end
	end
end
assert_eq(#seenAt, 2, "the single-key burst sends the final text exactly twice (got " .. #seenAt .. ")")
assert_eq(seenAt[1] < seenAt[2], true, "the re-assert fires on a LATER quiet tick")

-- (e) raw pacing: three stacked overlays queue 6 raw records (2 each); a tick
-- sends at most 2 texts AND at most 4 raws, and every 7Fh trigger still lands
-- after overlay text.
mock.sysex = {}
L.HandleMIDICC(0, 102, 127) -- bank +1: overlay "tracks 1-8"
L.HandleMIDICC(0, 66, 127) -- bottom row: overlay "Bottom row"/"Select"
L.HandleMIDICC(0, 65, 127) -- top row: overlay "Top row"/"Record Arm"
local stream = {}
local maxTexts, maxRaws = 0, 0
for _ = 1, 10 do
	mock.sysex = {}
	L.HandleTimer()
	local nText, nRaw = 0, 0
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" then
			nText = nText + 1
		elseif s.op == "configure" then
			nRaw = nRaw + 1
		end
		stream[#stream + 1] = s
	end
	maxTexts = math.max(maxTexts, nText)
	maxRaws = math.max(maxRaws, nRaw)
end
assert_eq(maxTexts <= 2, true, "at most 2 texts per tick (peak " .. maxTexts .. ")")
assert_eq(maxRaws <= 4, true, "at most 4 raws per tick (peak " .. maxRaws .. ")")
-- per-overlay ordering: the frontmost overlay's trigger must be preceded by
-- BOTH of its texts; older stacked overlays may have their texts legitimately
-- deduped away (same 54:0/54:1 keys, newest wins), so their triggers re-show
-- the committed content. The budget must delay, never reorder.
local textsSinceTrig = 0
local groups = {}
for _, s in ipairs(stream) do
	if s.op == "text" and s.target == 54 then
		textsSinceTrig = textsSinceTrig + 1
	elseif s.op == "configure" and s.target == 54 and s.config == 127 then
		groups[#groups + 1] = textsSinceTrig
		textsSinceTrig = 0
	end
end
assert_eq(#groups, 3, "all three stacked overlay triggers flushed (got " .. #groups .. ")")
assert_eq(groups[1] >= 2, true, "the frontmost overlay trigger is preceded by both of its texts (got " .. groups[1] .. ")")
assert_eq(maxRaws == 4, true, "the 4-raw budget is exercised in one tick (peak " .. maxRaws .. ")")

L.OnUnload()
_G.print = realPrint
print("test-screen-pipeline: PASS")
