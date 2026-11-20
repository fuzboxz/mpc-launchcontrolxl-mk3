-- tests/test-screen.lua: display configuration, text fields, sanitising,
-- caching and the overlay path.
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

local function texts(target, field)
	local out = {}
	for _, s in ipairs(mock.screen()) do
		if s.op == "text" and s.target == target and s.field == field then
			out[#out + 1] = s.text
		end
	end
	return out
end

L.OnLoad()

-- The stationary display is 3-line: range, current track, current target.
-- (the fader track map queues first; the pump sends 2 texts per tick, so the
-- initial load map plus its one-shot re-asserts need ~28 ticks to drain)
for _ = 1, 40 do
	L.HandleTimer()
end
local static = texts(53, 0)
assert_eq(static[#static], "MIX 1-8  | 120.0", "stationary line 1 shows mode, bank, transport and BPM")
local trackLine = texts(53, 1)
assert_eq(trackLine[#trackLine], "Track 0", "stationary line 2 shows the current track")

-- A bank move repaints the stationary line 1 and announces it on the overlay.
L.HandleMIDICC(0, 102, 127)
for _ = 1, 40 do
	L.HandleTimer()
end
local static2 = texts(53, 0)
assert_eq(static2[#static2], "MIX 2-9  | 120.0", "stationary range follows the bank")
local overlay = texts(54, 0)
assert_eq(overlay[#overlay], "tracks 2-9", "overlay announces the bank move")

-- Text is sanitised: ASCII 20h-7Eh only, 16 chars per line.
L.HandleMIDICC(0, 103, 127) -- back to bank 0 so track 0 is visible again
mock.tracks[0].Name:set("Tr\xffack\xf0 with a very long name")
L.HandleMIDICC(15, 77, 65) -- turn the Send 1 encoder for track 0
for _ = 1, 40 do
	L.HandleTimer()
end
local sawSanitised = false
for _, t in ipairs(texts(13, 0)) do
	if t == "Tr-ack- with a v" then
		sawSanitised = true
	end
end
assert_eq(sawSanitised, true, "non-ASCII replaced, truncated to 16")

-- Identical content is not resent (cache), new content is.
local before = #texts(13, 2)
L.HandleMIDICC(15, 77, 65) -- same value text
L.HandleTimer()
assert_eq(#texts(13, 2) <= before + 1, true, "no duplicate resend of unchanged text")

-- Mode change overlay.
L.HandleMIDICC(6, 30, 2)
L.HandleTimer()
local ov = texts(54, 0)
assert_eq(ov[#ov], "DAW Control", "mode change announced on the overlay")
local ov2 = texts(54, 1)
assert_eq(ov2[#ov2], "Q-Links (script)", "overlay line 2 shows the routing (native routing disabled by default)")

-- Control mode stationary line 3 shows the focused Q-Link target.
mock.setQlinkTarget(0, "Cutoff")
L.HandleMIDICC(15, 93, 65) -- tempo encoder: marks the surface dirty
for _ = 1, 6 do
	L.HandleTimer()
end
local line3 = texts(53, 2)
assert_eq(line3[#line3], "-", "stationary line 3 falls back to '-' without a focus API")

-- Unload cancels both global displays.
L.OnUnload()
local cancels = 0
for _, s in ipairs(mock.screen()) do
	if s.op == "configure" and s.config == 0 and (s.target == 53 or s.target == 54) then
		cancels = cancels + 1
	end
end
assert_eq(cancels, 2, "stationary + overlay cancelled on unload")
print("test-screen: PASS")
