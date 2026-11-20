-----------------------------------------------------------------------------------------------
-- LaunchControlXL3.lua
-- Novation Launch Control XL 3 as a control surface for Akai MPC 3.10.1 (Gen2, MPC Live III).
--
-- DAW mode. The XL3's DAW USB interface is a two-way surface: the script owns a UI state
-- machine, paints the encoder LEDs and the OLED, and translates input into MPC calls.
--
-- Wire map (programmer's reference v1.0 + Ableton's Live 12.3 remote script):
--   MIDI channels (0-based, as the MPC script layer passes them)
--     0  (ch 1)  surface buttons + LED colour CCs (B0h <control index> <palette>)
--     6  (ch 7)  Shift (CC 63), Mode (CC 30), Edit (CC 31), feature controls
--     14 (ch 15) touch events (CC = control index, 127/0)
--     15 (ch 16) faders (CC 5-12) + encoders: absolute 13-36, relative 77-100
--   buttons     37-44 Solo/Arm row, 45-52 Mute/Select row, 65 Solo/Arm cycle,
--               66 Mute/Select cycle, 102/103 Track > / <, 104 Novation,
--               106/107 Page up/down, 116 Play, 118 Record
--   encoders    row 1 = 13-20 / 77-84, row 2 = 21-28 / 85-92, row 3 = 29-36 / 93-100
--   relative    binary offset, pivot 64 (65 = +1 detent CW, 63 = -1)
--   LEDs        palette CC on ch 1 (control index; encoders use the ABSOLUTE index),
--               RGB via F0 00 20 29 02 15 01 53 <idx> <R> <G> <B> F7 (unused in phase 1)
--   screen      F0 00 20 29 02 15 04 <target> <config> F7  (configure; 97 = 2-line,
--               98 = 3-line, 0 = cancel, 127 = trigger)
--               F0 00 20 29 02 15 06 <target> <field> <text...> F7 (ASCII 20h-7Eh)
--               targets: 5-12 faders, 13-36 encoders, 53 stationary, 54 overlay
--   DAW mode    note 12 on ch 16 vel 127/0, or F0 00 20 29 02 15 02 <7Fh|00h> F7
--
-- Surface modes (the device reports them on ch 7 CC 30; the script follows and can set):
--   1 DAW Mixer   rows 1/2 = Send 1/2 per track, row 3 = Pan; Page cycles the send bank
--   2 DAW Control rows 1/2 = MPC Q-Links 0-15 (hardware-routed, see mapQlinks),
--                 row 3 = global parameters; Page cycles row 3 global/track-utility
--
-- Degrade, never break: every optional API is guarded; a missing feature disables its
-- surface, never crashes the host app.
-----------------------------------------------------------------------------------------------

local deviceName = "LaunchControlXL3" -- must match the file name
local port = 0 -- index of the output= line in the .ini (the DAW interface)

local dev = LaunchControlXL3

-- MIDI channels, 0-based
local CH_BUTTON = 0 -- MIDI channel 1: buttons, LED palette CCs
local CH_FEATURE = 6 -- MIDI channel 7: Shift/Mode/Edit + feature controls
local CH_TOUCH = 14 -- MIDI channel 15: touch events
local CH_ANALOG = 15 -- MIDI channel 16: faders + encoders
local CH_QUERY = 7 -- MIDI channel 8: feature-control queries (replies on ch 7)

-- Control indices
local FADER0 = 5 -- CC 5-12, left to right
local ENC0 = 13 -- absolute CC 13-36: row r col c = 13 + r*8 + c
local REL0 = 77 -- relative CC 77-100: row r col c = 77 + r*8 + c
local BTN_ROW1 = 37 -- CC 37-44 (Solo/Arm row), left to right
local BTN_ROW2 = 45 -- CC 45-52 (Mute/Select row), left to right
local BTN = {
	soloArm = 65,
	muteSelect = 66,
	trackRight = 102,
	trackLeft = 103,
	novation = 104,
	pageUp = 106,
	pageDown = 107,
	play = 116,
	record = 118,
}
local FEAT = {
	mode = 30,
	edit = 31,
	shift = 63,
	relRow = { 69, 72, 73 },
	pickup = 70,
	touch = 71,
	ledBrightness = 111,
	screenBrightness = 112,
	displayTimeout = 113,
	encoderCurve = 121,
}
local DAW_NOTE = 12 -- note on CH_ANALOG whose velocity toggles DAW mode

-- Surface-mode values reported/selected on ch 7 CC 30
local MODE_MIXER = 1
local MODE_CONTROL = 2

-- Q-Link native routing (mapQlinks): fw 1.1.11 device evidence - MPC's infinite-CC
-- parser sign is inverted vs the XL3 binary offset (CW moves parameters CCW), so
-- native routing ships OFF; all 16 Q-Links are driven script-side (Twist fallback:
-- rel row 2 direct, abs-only row 1 via the P0-2 abs-delta path). Re-enable only
-- after the direction/magnitude probe (reports/00-FINAL-TRIAGE.md section 5 probe 10).
-- Q-Link knob order (device-confirmed on the user's MPC 3.10.1, 2026-11-20,
-- once the abs-path/screen fixes made row 1 observable): the Q-Link screen
-- lists the 16 slots as four groups read top-to-bottom -- group 1 is Q-Links
-- 13,9,5,1 (indices 12,8,4,0), group 2 is 14,10,6,2, group 3 is 15,11,7,3,
-- group 4 is 16,12,8,4 -- the column-major page groups LPP3/LPMK3 verified.
-- The XL3 mirrors the groups in order: knob row 1 = groups 1+2, row 2 =
-- groups 3+4, each group's four slots read left-to-right on the knob row.
local QLINK_ORDER = { 12, 8, 4, 0, 13, 9, 5, 1, 14, 10, 6, 2, 15, 11, 7, 3 }

-- diagnostic build: bounded turn tracing (global to dodge the 200-local cap)

local function qlinkIndexOfKnob(row, col)
	local p = row * 8 + col
	return QLINK_ORDER[p + 1] or p
end

local QLINK_NATIVE_ROUTING = false

-- Novation 128-colour palette indices used by this script (Launch family palette;
-- indices confirmed by Ableton's Launch_Control_XL_3 skin).
-- LED colours as custom RGB (sysex op 01 53h, components 0-127). The DAW-mode
-- palette indices had too little on/off contrast; custom RGB lets the dim
-- states be genuinely dark (visible in a dark room, clearly off vs active).
local PAL = {
	off = { 0, 0, 0 },
	whiteDim = { 16, 16, 16 },
	white = { 127, 127, 127 },
	redDim = { 24, 0, 0 },
	red = { 127, 4, 4 },
	greenDim = { 0, 22, 5 },
	green = { 8, 127, 20 },
	blueDim = { 2, 9, 24 },
	blue = { 16, 60, 127 },
	darkBlue = { 6, 22, 60 },
	turquoise = { 0, 108, 108 },
	purple = { 118, 16, 118 },
	orangeDim = { 26, 10, 0 },
	orange = { 127, 52, 0 },
	yellow = { 127, 100, 0 },
}

-- One colour per send so Send 1-4 are distinguishable (mixer mode, rows 1/2).
local SEND_NAMES = { "Send 1", "Send 2", "Send 3", "Send 4" }

-- Reference data for the generated manual (docs/MANUAL.md, tools/gen-manual.lua).
-- Every control the dispatch tables handle has an entry; a test enforces that both
-- directions stay complete.
local ACTIONS = {
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.play, ch = 1, label = "Play", plain = "play / stop toggle (double-press: rewind to start)", shift = "stop (again: stop all clips)" },
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.record, ch = 1, label = "Record", plain = "record toggle (double-press: tap tempo)", shift = "overdub" },
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.trackLeft, ch = 1, label = "Track <", plain = "track bank -1", shift = "undo" },
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.trackRight, ch = 1, label = "Track >", plain = "track bank +1", shift = "redo" },
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.pageUp, ch = 1, label = "Page up", plain = "mixer: send bank A/B, control: row 3 page", shift = "bar forward (mixer) / plugin preset previous (control)" },
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.pageDown, ch = 1, label = "Page down", plain = "mixer: send bank A/B, control: row 3 page", shift = "bar back (mixer) / plugin preset next (control)" },
	{ group = "Transport and navigation (MIDI ch 1)", cc = BTN.novation, ch = 1, label = "Novation", plain = "log the current state", shift = "probe mode (log every message)" },
	{ group = "Button rows (MIDI ch 1)", cc = BTN.soloArm, ch = 1, label = "Solo/Arm", plain = "cycle the top row: solo / record arm", shift = "-" },
	{ group = "Button rows (MIDI ch 1)", cc = BTN.muteSelect, ch = 1, label = "Mute/Select", plain = "cycle the bottom row: mute / select", shift = "-" },
	{ group = "Button rows (MIDI ch 1)", cc = BTN_ROW1, ch = 1, label = "Top row 1-8", plain = "solo (or record arm) of that column's track", shift = "-" },
	{ group = "Button rows (MIDI ch 1)", cc = BTN_ROW2, ch = 1, label = "Bottom row 1-8", plain = "mute (or select) of that column's track", shift = "-" },
	{ group = "Faders (MIDI ch 16)", cc = FADER0, ch = 16, label = "Faders 1-8", plain = "volume of the track in that column", shift = "preview on screen (device-side)" },
	{ group = "Encoders, mixer mode (MIDI ch 16)", cc = ENC0, ch = 16, label = "Row 1", plain = "Send 1 (bank A) / Send 3 (bank B)", shift = "preview on screen" },
	{ group = "Encoders, mixer mode (MIDI ch 16)", cc = ENC0 + 8, ch = 16, label = "Row 2", plain = "Send 2 (bank A) / Send 4 (bank B)", shift = "preview on screen" },
	{ group = "Encoders, mixer mode (MIDI ch 16)", cc = ENC0 + 16, ch = 16, label = "Row 3", plain = "Pan", shift = "preview on screen" },
	{ group = "Encoders, control mode (MIDI ch 16)", cc = ENC0, ch = 16, label = "Rows 1-2", plain = "MPC Q-Links 0-15 (script-driven; native routing pending hardware probe)", shift = "preview on screen" },
	{ group = "Encoders, control mode (MIDI ch 16)", cc = ENC0 + 16, ch = 16, label = "Row 3 (global page)", plain = "tempo, swing, quantize strength, quantize division, metronome, loop, automation filter, master volume", shift = "preview on screen" },
	{ group = "Encoders, control mode (MIDI ch 16)", cc = ENC0 + 16, ch = 16, label = "Row 3 (track page)", plain = "pan, Send 1-4, volume trim of the selected track", shift = "preview on screen" },
	{ group = "Feature buttons (MIDI ch 7)", cc = FEAT.shift, ch = 7, label = "Shift", plain = "hold for the shift functions (double press latches)", shift = "-" },
	{ group = "Feature buttons (MIDI ch 7)", cc = FEAT.mode, ch = 7, label = "Mode", plain = "surface mode select/report (DAW Mixer / DAW Control / custom)", shift = "-" },
	{ group = "Feature buttons (MIDI ch 7)", cc = FEAT.edit, ch = 7, label = "Edit", plain = "cycle the control-mode row 3 page", shift = "-" },
}

-----------------------------------------------------------------------------------------------
-- State
-----------------------------------------------------------------------------------------------

local loaded = false
local surfaceMode = MODE_MIXER -- device surface mode we last saw/selected
local topMode = "solo" -- "solo" | "arm" (top button row)
local bottomMode = "mute" -- "mute" | "select" (bottom button row)
local markDirty -- forward declarations: defined with the listener layer below
local isPlaying, recordActive, getBpm -- transport accessors, defined with the actions
local paintTrackScreens -- fader-display track map, defined with the paint layer
local mixerParamFor -- mixer encoder row -> parameter name, defined with the input layer
local lastPressTick = {} -- [cc] -> tick of the last press (double-press window)
local loggedTrackCount = -1 -- window diagnostic: re-log when the project changes
local pressState = {} -- [cc] -> transport flags before the first press of a pair
local bank = 0 -- index of the first visible normal track
local sendBank = 0 -- mixer mode: 0 = Send 1/2, 1 = Send 3/4
local controlPage = 0 -- control mode row 3: 0 = global, 1 = track utility
local shiftHeld = false
local probeMode = false
local qlinkRouted = false -- rows 1/2 hardware-routed into MPC Q-Links
local qlinkFallback = false -- routing missing: the script emulates with Twist
local ticks = 0
local repaintDirty = true
local lastLog = {}
local ledCache = {} -- control index -> last palette index sent
local screenSent = {} -- "target:field" -> last text committed at SEND time
local screenQueue = {} -- tagged records ({kind="text",key,target,field,text} / {kind="raw",fn}), pumped a few per timer tick
local screenReassert = {} -- set of keys to force-queue once on a quiet tick after a multi-text burst
__LCXL3_SCRETRIES = {} -- re-assert attempts per key per burst (max 2; global: local budget)
local lastAbs = {} -- [row*8+col] -> last absolute encoder value seen (abs converted to deltas)
local faderArmed = {} -- col -> software pickup pending
local faderRef = {} -- col -> last position the MPC had (0-127)
local faderLast = {} -- col -> last incoming position
local props = {} -- listenable properties bound at load {obj, unbind}
local boundTracks = {} -- [col] = track object currently bound
local lastTouched = nil -- {kind="fader"|"encoder", row, col}

-----------------------------------------------------------------------------------------------
-- Utilities
-----------------------------------------------------------------------------------------------

local H = {}

function H.log(msg)
	pcall(function()
		print(deviceName .. ": " .. tostring(msg))
	end)
end

function H.logOnce(key, msg)
	if lastLog[key] then
		return
	end
	lastLog[key] = true
	H.log(msg)
end

-- Call f(...) when it is callable; swallow errors, return nil on failure.
function H.call(f, ...)
	if type(f) ~= "function" then
		return nil
	end
	local ok, r = pcall(f, ...)
	if ok then
		return r
	end
	return nil
end

-- Read obj[name].value safely (mpc state properties are sol2 userdata).
function H.prop(obj, name)
	local p = obj and obj[name]
	if p == nil then
		return nil
	end
	local ok, v = pcall(function()
		return p.value
	end)
	if ok then
		return v
	end
	return nil
end

-- Boolean view of a property value: MPC state properties are numbers (0 = off) and
-- Lua treats 0 as true -- never test them directly.
function H.truthy(v)
	return v ~= nil and v ~= false and v ~= 0
end

function H.clamp(v, lo, hi)
	v = tonumber(v) or lo
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

function H.clamp01(v)
	return H.clamp(v, 0, 1)
end

-- The member when it exists with the expected type, else nil.
function H.member(obj, key, kind)
	if obj == nil then
		return nil
	end
	local v = obj[key]
	if v ~= nil and (kind == nil or type(v) == kind) then
		return v
	end
	return nil
end

-- obj[key] when readable, else nil. Sol2 userdata can throw on missing
-- members, so every speculative API probe goes through here.
function H.safeIndex(obj, key)
	if obj == nil then
		return nil
	end
	local ok, v = pcall(function()
		return obj[key]
	end)
	if ok then
		return v
	end
	return nil
end

function H.callable(obj, key)
	return H.member(obj, key, "function")
end

-- MPC volume fader curve, measured on 3.10.1: dB = 40*log10(gain) + 6.
function H.gainToDb(gain)
	gain = tonumber(gain)
	if gain == nil or gain <= 0.0001 then
		return "-inf"
	end
	return string.format("%.1f dB", 40 * math.log(gain, 10) + 6)
end

function H.fmtPercent(v)
	return string.format("%d%%", math.floor(H.clamp01(v) * 100 + 0.5))
end

-- Pan formatting follows the device convention: L..C..R.
function H.fmtPan(v)
	v = H.clamp01(tonumber(v) or 0.5)
	local d = v - 0.5
	if math.abs(d) < 0.02 then
		return "C"
	end
	local amt = math.floor(math.abs(d) * 100 + 0.5)
	return string.format("%s%d", d < 0 and "L" or "R", amt)
end

-- Screen text: ASCII 20h-7Eh only, 16 characters per line.
function H.screenText(s, width)
	s = tostring(s or "")
	local out = {}
	for i = 1, math.min(#s, width or 16) do
		local b = s:byte(i)
		if b >= 0x20 and b <= 0x7E then
			out[#out + 1] = s:sub(i, i)
		else
			out[#out + 1] = "-"
		end
	end
	return table.concat(out)
end

function H.argb(c)
	c = tonumber(c) or 0
	return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

-- Number of normal tracks. The table is allocated with 128 slots whatever the
-- project holds, so the count comes from Count/SizeNormalTracks, never from #.
function H.trackCount()
	local t = mpc and mpc.tracks
	-- NORMAL tracks only: Count includes MIDI/non-mixable tracks that the
	-- surface cannot address, inflating the bank range with phantom pages.
	local n = H.call(H.callable(t, "SizeNormalTracks"))
	if type(n) == "number" then
		return n
	end
	n = H.call(H.callable(t, "GetCount"))
	if type(n) == "number" then
		return n
	end
	n = H.prop(t, "Count")
	if type(n) == "number" then
		return n
	end
	return 0
end

-- The MPC UI numbers ALL tracks (mpc.tracks.Count); normalTracks is the
-- mixable subset the surface addresses. globalIndex = normalIndex + offset,
-- with the offset learned passively: whenever the current track is a normal
-- track, its global Index minus its position in normalTracks is the offset.
local globalOffset = 0
local offsetPending = false -- Index and Name update asynchronously: learn on
-- the next tick, when both have settled, instead of inside a listener with a
-- stale Name (which produced an oscillating wrong offset on the device).

local function learnTrackOffset()
	local t = mpc and mpc.tracks
	local cur = t and t.currentTrack
	local name = H.prop(cur, "Name")
	local gidx = tonumber(H.prop(cur, "Index"))
	if type(name) ~= "string" or name == "" or type(gidx) ~= "number" then
		return
	end
	local n = H.trackCount()
	for i = 0, n - 1 do
		local tr = H.trackAt(i)
		if tr ~= nil and H.prop(tr, "Name") == name then
			if gidx - i ~= globalOffset then
				globalOffset = gidx - i
				H.log("track offset " .. globalOffset)
			end
			return
		end
	end
	-- current track is not mixable (e.g. a MIDI track): keep the last offset
end

function H.uiNumberOf(normalIdx)
	return normalIdx + globalOffset + 1
end

function H.trackAt(idx)
	local t = mpc and mpc.tracks
	local nt = t and t.normalTracks
	if nt == nil or idx < 0 then
		return nil
	end
	local ok, tr = pcall(function()
		return nt[idx]
	end)
	if ok then
		return tr
	end
	return nil
end

function H.visibleIdx(col)
	return bank + col
end

function H.trackForCol(col)
	return H.trackAt(H.visibleIdx(col))
end

function H.currentTrackIndex()
	return H.prop(mpc and mpc.tracks and mpc.tracks.currentTrack, "Index")
end

-- Is a project loaded / is it safe to touch project-scoped state? A popup that
-- owns the UI blocks project-scoped native calls (the native side can abort in
-- ways pcall cannot catch), so an open dialog counts as "not loaded".
function H.currentPopup()
	local em = mpc and mpc.engineMode
	local p = H.prop(em, "CurrentPopup")
	if p == nil then
		p = H.call(H.callable(em, "GetCurrentPopup"))
	end
	return tostring(p or "")
end

function H.popupOpen()
	local p = H.currentPopup()
	return p ~= "" and p ~= "No Popup"
end

function H.projectLoaded()
	if H.popupOpen() then
		return false
	end
	if mpc.currentSequence ~= nil then
		return true
	end
	if mpc.tracks ~= nil and mpc.tracks.currentTrack ~= nil then
		return true
	end
	local bpm = H.call(H.callable(mpc.sequencer, "GetBPM"))
	if type(bpm) == "number" and bpm > 0 then
		return true
	end
	return false
end

function H.requireProject(label)
	if H.projectLoaded() then
		return true
	end
	if H.popupOpen() then
		H.logOnce(label .. "-popup", label .. ": dialog open (" .. H.currentPopup() .. ")")
	else
		H.logOnce(label .. "-noproject", label .. ": no project loaded")
	end
	return false
end

-----------------------------------------------------------------------------------------------
-- MIDI output, LEDs, screen
-----------------------------------------------------------------------------------------------

local SYSEX_HDR = string.char(0x00, 0x20, 0x29, 0x02, 0x15) -- Novation / LCXL3

local function sendCC(ch, cc, value)
	H.call(dev.midiOut and dev.midiOut.SendMIDICC, ch, cc, value, port)
end

local function sendNoteOn(ch, note, vel)
	H.call(dev.midiOut and dev.midiOut.SendMIDINoteOn, ch, note, vel, port)
end

-- payload WITHOUT the F0/F7 framing (the MPC adds them)
local function sendSysex(payload)
	H.call(dev.midiOut and dev.midiOut.SendMIDISysex, payload, port)
end

-- Paint one control's LED with a palette index. Works for buttons (their own CC)
-- and encoders (their ABSOLUTE index, valid in relative mode too).
local function ledSet(controlIndex, rgb)
	local cached = ledCache[controlIndex]
	if cached ~= nil and cached[1] == rgb[1] and cached[2] == rgb[2] and cached[3] == rgb[3] then
		return
	end
	ledCache[controlIndex] = { rgb[1], rgb[2], rgb[3] }
	-- custom RGB colour: F0 00 20 29 02 15 01 53 <control> <R> <G> <B> F7
	sendSysex(SYSEX_HDR .. string.char(0x01, 0x53, controlIndex, rgb[1], rgb[2], rgb[3]))
end

local function clearSurface()
	for cc = FADER0, 12 do
		ledSet(cc, PAL.off) -- faders have no LEDs; harmless if the device ignores it
	end
	for cc = ENC0, ENC0 + 23 do
		ledSet(cc, PAL.off)
	end
	local buttons = {}
	for cc = BTN_ROW1, BTN_ROW1 + 7 do
		buttons[#buttons + 1] = cc
	end
	for cc = BTN_ROW2, BTN_ROW2 + 7 do
		buttons[#buttons + 1] = cc
	end
	for _, k in ipairs({ "soloArm", "muteSelect", "trackRight", "trackLeft", "novation", "pageUp", "pageDown", "play", "record" }) do
		buttons[#buttons + 1] = BTN[k]
	end
	for _, cc in ipairs(buttons) do
		ledSet(cc, PAL.off)
	end
end

-- Screen ----------------------------------------------------------------------

local SCR_STATIC = 53 -- stationary display
local SCR_TEMP = 54 -- overlay / temporary display
local CFG_TWOLINE = 97
local CFG_THREELINE = 98

local function scrConfigure(target, config)
	sendSysex(SYSEX_HDR .. string.char(0x04, target, config))
end

-- Queue one screen text field. Dedupe is per KEY over the pending queue,
-- keeping the NEWEST text in its queue position (a positional index map would
-- go stale: the overlay front-inserts and the pump removes from the front).
-- The cache commits at SEND time (pumpScreen), so a queued-but-unsent text
-- never blocks a newer one; the queue is pumped a few messages per timer tick
-- so a repaint never floods the device.
local function scrText(target, field, text)
	text = H.screenText(text)
	local key = tostring(target) .. ":" .. tostring(field)
	for _, rec in ipairs(screenQueue) do
		if rec.kind == "text" and rec.key == key then
			rec.text = text -- already pending: replace its text, newest wins
			return
		end
	end
	if screenSent[key] == text then
		return
	end
	screenQueue[#screenQueue + 1] = { kind = "text", key = key, target = target, field = field, text = text }
end

-- Display pacing (fw 1.1.11): the device needs spacing between display sysex
-- (Ableton spaces them ~10 ms), so one 50 ms tick carries at most 2 text and
-- 4 raw records. Queue order is preserved: a text record at the head whose
-- budget is spent waits for the next tick instead of being reordered.
local SCREEN_TEXTS_PER_TICK = 2
local SCREEN_RAWS_PER_TICK = 4

local function pumpScreen()
	-- post-burst re-assert: any tick that pumped text can lose trailing sysex
	-- on the device (a single-key fader sweep included); on the first tick
	-- with an empty queue afterwards, force-queue each remembered key's
	-- last-sent text exactly once (cache bypass) and send it, so a device-side
	-- drop cannot stick permanently.
	if next(screenReassert) ~= nil and #screenQueue == 0 then
		local reassert = screenReassert
		screenReassert = {}
		for key in pairs(reassert) do
			local t, f = key:match("^(%d+):(%d+)$")
			local text = screenSent[key]
			if t ~= nil and text ~= nil then
				__LCXL3_SCRETRIES[key] = (__LCXL3_SCRETRIES[key] or 0) + 1
				if __LCXL3_SCRETRIES[key] < 2 then
					-- up to 2 re-asserts: a device drop of the final text (or of
					-- the first re-assert itself) must not stick as a wrong value
					screenReassert[key] = true
				end
				screenQueue[#screenQueue + 1] = { kind = "text", key = key, target = tonumber(t), field = tonumber(f), text = text, forced = true }
			end
		end
	end
	local texts, raws = 0, 0
	local pumped = nil -- keys of this tick's non-forced text sends
	while #screenQueue > 0 and (texts < SCREEN_TEXTS_PER_TICK or raws < SCREEN_RAWS_PER_TICK) do
		local rec = screenQueue[1]
		if rec.kind == "text" then
			if texts >= SCREEN_TEXTS_PER_TICK then
				break -- text budget spent: the head record waits for the next tick
			end
			table.remove(screenQueue, 1)
			sendSysex(SYSEX_HDR .. string.char(0x06, rec.target, rec.field) .. rec.text)
			-- commit at SEND time: a queued-but-unsent text must not block a
			-- newer one, and a dropped send must not look delivered
			screenSent[rec.key] = rec.text
			texts = texts + 1
			if not rec.forced then
				pumped = pumped or {}
				pumped[#pumped + 1] = rec.key
			end
		else
			if raws >= SCREEN_RAWS_PER_TICK then
				break
			end
			table.remove(screenQueue, 1)
			H.call(rec.fn)
			raws = raws + 1
		end
	end
	if pumped ~= nil then
		-- every non-forced text re-arms (single-key sweeps included); the
		-- re-assert itself stays one-shot and never re-arms (forced records)
		for _, key in ipairs(pumped) do
			screenReassert[key] = true
		end
	end
end

-- Overlay: a two-line temporary message (mode/page/probe changes, refusals).
-- The overlay is trigger-driven: the trigger must reach the device AFTER the
-- new text, or it brings up the PREVIOUS contents and the late text never
-- re-renders (device-observed "shows the previous range/name"). Queue the text
-- and the trigger together, at the FRONT of the queue, so bulk repaints cannot
-- delay the overlay either.
local function showOverlay(line1, line2)
	local msgs = {}
	local key0, key1 -- the overlay's two text keys
	local function pushText(field, text)
		text = H.screenText(text)
		local key = tostring(SCR_TEMP) .. ":" .. tostring(field)
		if field == 0 then
			key0 = key
		else
			key1 = key
		end
		if screenSent[key] ~= text then
			msgs[#msgs + 1] = { kind = "text", key = key, target = SCR_TEMP, field = field, text = text }
		end
	end
	pushText(0, line1)
	pushText(1, line2 or "")
	msgs[#msgs + 1] = { kind = "raw", fn = function()
		sendSysex(SYSEX_HDR .. string.char(0x04, SCR_TEMP, CFG_TWOLINE))
	end }
	msgs[#msgs + 1] = { kind = "raw", fn = function()
		sendSysex(SYSEX_HDR .. string.char(0x04, SCR_TEMP, 0x7F))
	end }
	-- the overlay texts are the newest for their keys: drop any pending record
	-- for the same key deeper in the queue, or the pump would send the older
	-- text AFTER the trigger and overwrite the overlay
	for i = #screenQueue, 1, -1 do
		local rec = screenQueue[i]
		if rec.kind == "text" and (rec.key == key0 or rec.key == key1) then
			table.remove(screenQueue, i)
		end
	end
	for i = #msgs, 1, -1 do
		table.insert(screenQueue, 1, msgs[i])
	end
end

-- Per-control display: faders use targets 5-12, encoders 13-36 (absolute index).
local function showControl(target, title, name, value)
	scrText(target, 0, title)
	scrText(target, 1, name)
	scrText(target, 2, value)
end

local function faderTarget(col)
	return FADER0 + col
end

local function encoderTarget(row, col)
	return ENC0 + row * 8 + col
end

local function currentTrackName()
	local n = H.prop(mpc and mpc.tracks and mpc.tracks.currentTrack, "Name")
	if type(n) == "string" and n ~= "" then
		return n
	end
	local tr = H.trackAt(H.currentTrackIndex())
	return H.prop(tr, "Name") or "-"
end

-- Transport state for the screen: glyph + BPM, and a bar.beat position.
-- MPC 3 pulses are 960 per quarter; the raw value is logged once so a wrong
-- assumption is visible in the journal and trivially correctable.
local PULSES_PER_QUARTER = 960

local function positionText()
	local sq = mpc and mpc.sequencer
	local pos = tonumber(H.call(H.callable(sq, "PlayheadPosition")))
	if pos == nil then
		return ""
	end
	H.logOnce("playhead", string.format("playhead raw=%d", pos))
	local perBar = PULSES_PER_QUARTER * 4 -- assume 4/4 until a TS getter is proven
	local bar = math.floor(pos / perBar) + 1
	local beat = math.floor((pos % perBar) / PULSES_PER_QUARTER) + 1
	return string.format("bar %d.%d", bar, beat)
end

local function transportText()
	local glyph = "|"
	if recordActive() then
		glyph = "REC"
	elseif isPlaying() then
		glyph = ">"
	end
	return string.format("%s %5.1f", glyph, getBpm())
end

-- Stationary display: mode + bank / current track / current target.
local function paintStaticScreen()
	local modeName = (surfaceMode == MODE_CONTROL) and "CTL" or "MIX"
	local n = H.trackCount()
	local last = math.min(bank + 7, math.max(n - 1, bank))
	local range
	if n <= 0 then
		range = "no tracks"
	else
		range = string.format("%s %d-%d", modeName, H.uiNumberOf(bank), H.uiNumberOf(last))
	end
	local line0 = range
	scrText(SCR_STATIC, 1, currentTrackName())
	local target = "-"
	if surfaceMode == MODE_CONTROL then
		target = tostring(H.qlinkFocusName and H.qlinkFocusName() or "-")
	else
		-- mixer: carry the transport state on line 0 and the position on line 2
		line0 = string.format("%-8s %s", range, transportText())
		local pos = positionText()
		local sb = (sendBank == 0) and "sA" or "sB"
		target = (pos ~= "") and (pos .. " " .. sb) or (transportText() .. " " .. sb)
	end
	scrText(SCR_STATIC, 0, line0)
	scrText(SCR_STATIC, 2, target)
end

-----------------------------------------------------------------------------------------------
-- Device session: DAW mode, feature controls
-----------------------------------------------------------------------------------------------

local function dawEnter()
	-- both forms are idempotent; sending both covers a framing surprise
	sendNoteOn(CH_ANALOG, DAW_NOTE, 127)
	sendSysex(SYSEX_HDR .. string.char(0x02, 0x7F))
end

local function dawLeave()
	sendNoteOn(CH_ANALOG, DAW_NOTE, 0)
	sendSysex(SYSEX_HDR .. string.char(0x02, 0x00))
end

local function surfaceConfigure()
	for _, cc in ipairs(FEAT.relRow) do
		sendCC(CH_FEATURE, cc, 127) -- relative encoders, all three rows
	end
	sendCC(CH_FEATURE, FEAT.touch, 127) -- touch events on ch 15
	sendCC(CH_FEATURE, FEAT.pickup, 127) -- fader pickup against script-sent positions
	sendCC(CH_FEATURE, FEAT.ledBrightness, 100)
	sendCC(CH_FEATURE, FEAT.screenBrightness, 100)
	sendCC(CH_FEATURE, FEAT.displayTimeout, 20) -- 2 s temporary displays
	sendCC(CH_FEATURE, FEAT.encoderCurve, 1) -- medium
end

-----------------------------------------------------------------------------------------------
-- MPC actions
-----------------------------------------------------------------------------------------------

-- Write a mixer property (Volume/Pan/Send1..4) on a normal track.
local function setTrackValue(idx, name, v)
	local tr = H.trackAt(idx)
	if tr == nil then
		return false
	end
	local ok = pcall(function()
		tr[name].value = v
	end)
	if not ok then
		H.logOnce("set-" .. name, "track " .. name .. " write failed")
	end
	return ok
end

local function getTrackValue(idx, name)
	return H.prop(H.trackAt(idx), name)
end

-- Toggle Mute/Solo/RecArm via the setter, falling back to the property write.
local function toggleTrackFlag(idx, flag)
	local tr = H.trackAt(idx)
	if tr == nil then
		return
	end
	local cur = H.truthy(H.prop(tr, flag))
	local setter = H.callable(tr, "Set" .. flag)
	local ok = false
	if setter then
		ok = pcall(setter, not cur)
	end
	if not ok then
		pcall(function()
			tr[flag].value = not cur
		end)
	end
	H.log(string.format("%s %d: %s", flag, idx, (cur and "off" or "on")))
end

local function selectTrack(idx)
	if not H.requireProject("select") then
		return
	end
	-- SetCurrentTrack takes the GLOBAL index (launchpad-proven) and returns
	-- nothing: gate on the API's presence, never on its (void) result.
	local fn = H.callable(mpc.tracks, "SetCurrentTrack")
	if fn ~= nil then
		H.call(fn, idx + globalOffset)
	else
		H.logOnce("selecttrack", "SetCurrentTrack unavailable")
	end
	-- the matrix select is column-relative and takes the normal index
	H.call(mpc.clipMatrix and mpc.clipMatrix.SelectTrack, idx)
end

local function nudgeTrackValue(idx, name, delta, lo, hi)
	local cur = tonumber(getTrackValue(idx, name)) or 0
	return setTrackValue(idx, name, H.clamp(cur + delta, lo or 0, hi or 1))
end

-- Transport ------------------------------------------------------------------

isPlaying = function()
	local p = H.truthy(H.prop(mpc.sequencer, "Playing"))
	if p then
		return true
	end
	return H.truthy(H.call(H.callable(mpc.sequencer, "IsPlaying")))
end

local function doPlay()
	if not H.requireProject("play") then
		return
	end
	if isPlaying() then
		H.call(H.callable(mpc.sequencer, "Stop"))
		H.log("stop")
	else
		-- prefer TogglePlay; the call's return value is meaningless on this API
		local tp = H.callable(mpc.sequencer, "TogglePlay")
		if tp ~= nil then
			H.call(tp)
		else
			H.call(H.callable(mpc.sequencer, "Play"))
		end
		H.log("play")
	end
end

local function doStop()
	H.call(H.callable(mpc.sequencer, "Stop"))
	H.log("stop")
end

recordActive = function()
	return H.truthy(H.prop(mpc.sequencer, "RecordState")) or H.truthy(H.call(H.callable(mpc.sequencer, "IsRecording")))
end

local function doRecord()
	if not H.requireProject("record") then
		return
	end
	if recordActive() and H.truthy(H.prop(mpc.sequencer, "OverdubState")) then
		-- device-observed: with overdub-only raised, recordActive() is true and
		-- RecordOff STOPS PLAYBACK. Arm full record instead of toggling off
		-- (conservative shape until the transport probe decides the real one).
		H.call(H.callable(mpc.sequencer, "Record"))
		H.logOnce("recguard", "record: overdub-only state, RecordOff skipped (it stops playback); full record armed instead")
	elseif recordActive() and H.callable(mpc.sequencer, "RecordOff") then
		H.call(mpc.sequencer.RecordOff)
	else
		H.call(H.callable(mpc.sequencer, "Record"))
	end
	H.log("record: " .. ((not recordActive()) and "armed" or "off"))
end

local function doOverdub()
	if not H.requireProject("overdub") then
		return
	end
	if H.truthy(H.prop(mpc.sequencer, "OverdubState"))
		and not H.truthy(H.prop(mpc.sequencer, "RecordState")) then
		-- overdub-only recording: dropping overdub can stop playback
		-- (device-observed; mirrors the record guard). Arm full record
		-- first so playback is held, then toggle overdub off.
		H.call(H.callable(mpc.sequencer, "Record"))
		H.call(H.callable(mpc.sequencer, "Overdub"))
		H.logOnce("odguard", "overdub: overdub-only state guarded (full record armed before overdub off)")
		return
	end
	H.call(H.callable(mpc.sequencer, "Overdub"))
	H.log("overdub")
end

local function doTap()
	-- emulate the MPC's tap-tempo button: press+release taps once
	local cs = mpc and mpc.controlSurface
	local btn = cs and cs.tapTempo
	if btn == nil then
		H.logOnce("tap", "tap tempo unavailable: controlSurface.tapTempo missing")
		return
	end
	H.call(H.callable(btn, "Press"))
	H.call(H.callable(btn, "Release"))
	showOverlay("Tap tempo")
end

local function doJumpStart()
	if not H.requireProject("rewind") then
		return
	end
	H.call(H.callable(mpc.sequencer, "JumpToBeginning"))
	showOverlay("Rewind", "to start")
	H.log("jump to beginning")
end

local function doStopAll()
	H.call(H.callable(mpc.clipMatrix, "StopAllClips"))
	showOverlay("Stop all clips")
	H.log("stop all clips")
end

local function doBar(dir)
	local sq = mpc.sequencer
	local fn = H.callable(sq, dir > 0 and "BarForward" or "BarBack")
	H.call(fn, 1)
	showOverlay(dir > 0 and "Bar forward" or "Bar back")
end

local function doUndo()
	local cm = mpc and mpc.commandManager
	local can = H.callable(cm, "CanUndo")
	if can == nil then
		H.logOnce("undo", "Undo unavailable: commandManager missing")
		showOverlay("Undo", "unavailable")
	elseif not H.call(can) then
		showOverlay("Undo", "nothing to undo") -- empty stack: not an error
	else
		H.call(H.callable(cm, "Undo"))
		showOverlay("Undo")
	end
end

local function doRedo()
	local cm = mpc and mpc.commandManager
	local can = H.callable(cm, "CanRedo")
	if can == nil then
		H.logOnce("redo", "Redo unavailable: commandManager missing")
		showOverlay("Redo", "unavailable")
	elseif not H.call(can) then
		showOverlay("Redo", "nothing to redo") -- empty stack: not an error
	else
		H.call(H.callable(cm, "Redo"))
		showOverlay("Redo")
	end
end

-- Double-press detection: true when this cc was also pressed within the window.
-- pressState (declared with the state above) records the transport flags before
-- the first press so a double-press can revert the side effect of that press.
local function isDoublePress(cc)
	local last = lastPressTick[cc]
	lastPressTick[cc] = ticks
	local d = ticks - (last or -100)
	if d < 0 or d > 7 then -- stale (pre-reload) or outside the 350 ms window
		pressState[cc] = { rec = recordActive(), play = isPlaying() }
		return false
	end
	return true
end

-- Global parameters (control mode, row 3 global page) -------------------------

local TIME_DIVISIONS = { "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T" }

local function quantiser()
	return mpc.sequencer and mpc.sequencer.quantiser
end

getBpm = function()
	local v = H.prop(mpc.project, "BPM")
	if type(v) == "number" then
		return v
	end
	return tonumber(H.call(H.callable(mpc.sequencer, "GetBPM")) or H.call(H.callable(mpc.currentSequence, "GetBPM"))) or 120
end

local function setBpm(bpm)
	bpm = H.clamp(bpm, 20, 500)
	local ok = pcall(function()
		mpc.project.BPM.value = bpm
	end)
	if not ok then
		H.call(H.callable(mpc.sequencer, "SetBPM"), bpm)
		H.call(H.callable(mpc.currentSequence, "SetBPM"), bpm)
	end
end

local function getSwing()
	return tonumber(H.call(H.callable(quantiser(), "GetSwing"))) or 50
end

__LCXL3_SWING = nil -- device GetSwing lags (like the qlinks): step a shadow (global: main chunk is at its 200-local limit)

local function setSwing(v)
	__LCXL3_SWING = H.clamp(v, 50, 75)
	H.call(H.callable(quantiser(), "SetSwing"), __LCXL3_SWING)
end

local function getStrength()
	return tonumber(H.call(H.callable(quantiser(), "GetStrength"))) or 100
end

local function setStrength(v)
	H.call(H.callable(quantiser(), "SetStrength"), H.clamp(v, 0, 100))
end

local function cycleTimeDivision(dir)
	local q = quantiser()
	local cur = tostring(H.call(H.callable(q, "GetTimeDivision")) or "1/16")
	local idx = 1
	for i, d in ipairs(TIME_DIVISIONS) do
		if d == cur then
			idx = i
			break
		end
	end
	idx = H.clamp(idx + (dir > 0 and 1 or -1), 1, #TIME_DIVISIONS)
	H.call(H.callable(q, "SetTimeDivision"), TIME_DIVISIONS[idx])
	return TIME_DIVISIONS[idx]
end

local function toggleMetronome()
	local cur = H.truthy(H.prop(mpc.sequencer, "MetronomeEnabled"))
	local setter = H.callable(mpc.sequencer, "SetMetronomeEnabled")
	if setter then
		H.call(setter, not cur)
	else
		pcall(function()
			mpc.sequencer.MetronomeEnabled.value = not cur
		end)
	end
	return not cur
end

local function toggleLoop()
	local cur = H.truthy(H.prop(mpc.sequencer, "Loop"))
	local setter = H.callable(mpc.sequencer, "SetLoop")
	if setter then
		H.call(setter, not cur)
	else
		pcall(function()
			mpc.sequencer.Loop.value = not cur
		end)
	end
	return not cur
end

-- Global automation filter type (control mode, row 3 col 6). The scalar
-- Get/Set pair exists (LPP3 dump): the enum is enumerated lazily with restore
-- on the first use - Advance until the type repeats (bounded), remember the
-- order, then Set the original back - so CW/CCW stepping uses Set(list[...])
-- and the overlay can show the ACTUAL type. If Get or Set are missing or
-- erroring, the old CW-only Advance path stays as the degrade.
local autoFilterTypes = nil -- enumerated type strings (lazy, first col-6 use)
local autoFilterTried = false -- enumeration attempted once

local function enumerateAutomationFilterTypes()
	local p = mpc and mpc.project
	local get = H.callable(p, "GetGlobalAutomationFilterType")
	local set = H.callable(p, "SetGlobalAutomationFilterType")
	local adv = H.callable(p, "AdvanceGlobalAutomationFilterType")
	if get == nil or set == nil or adv == nil then
		return nil
	end
	local t0 = H.call(get)
	if t0 == nil then
		H.logOnce("afnil", "autofilter enum: Get returned nothing")
		return nil
	end
	local list = { t0 } -- RAW values for stepping; display via tostring
	for _ = 1, 12 do
		H.call(adv)
		local t = H.call(get)
		if t == nil then
			H.logOnce("afnil2", "autofilter enum: Get returned nothing mid-cycle")
			return nil
		end
		if t == t0 then
			H.log(string.format("autofilter enum: %d types", #list))
			return list
		end
		list[#list + 1] = t
	end
	if not pcall(set, t0) then -- no repeat within the bound: restore, treat as unavailable
		H.logOnce("afrestore", "autofilter enum: restore failed; type left advanced")
	end
	H.logOnce("afbound", "autofilter enum: no cycle repeat within 12 advances")
	return nil
end

local function cycleAutomationFilter(dir)
	if not H.requireProject("autofilter") then
		return nil
	end
	local p = mpc and mpc.project
	if not autoFilterTried then
		autoFilterTried = true
		autoFilterTypes = enumerateAutomationFilterTypes()
		if autoFilterTypes == nil then
			H.logOnce("autofilter", "automation filter Get/Set unavailable: CW-only Advance fallback")
		end
	end
	if autoFilterTypes ~= nil and #autoFilterTypes > 0 then
		local cur = H.call(H.callable(p, "GetGlobalAutomationFilterType"))
		local set = H.callable(p, "SetGlobalAutomationFilterType")
		if cur ~= nil and set ~= nil then
			local n = #autoFilterTypes
			local idx = 1
			for i, t in ipairs(autoFilterTypes) do
				if t == cur then
					idx = i
					break
				end
			end
			idx = ((idx - 1 + (dir > 0 and 1 or -1)) % n) + 1
			local nextType = autoFilterTypes[idx]
			if pcall(set, nextType) then
				return tostring(nextType)
			end
			H.logOnce("autofilter", "automation filter Set failed: CW-only Advance fallback")
		end
	end
	-- degrade: CW-only Advance per detent, no type readout
	H.call(H.callable(p, "AdvanceGlobalAutomationFilterType"))
	return nil
end

local function masterTrack()
	local mt = mpc.tracks and mpc.tracks.masterTracks
	local ok, tr = pcall(function()
		return mt and mt[0]
	end)
	if ok then
		return tr
	end
	return nil
end

local function nudgeMasterVolume(delta)
	local tr = masterTrack()
	-- only write over a REAL read: masterTracks[0].Volume is not the proven
	-- fader path (device-disproven, probe pending), so no blind default write
	local cur = tonumber(H.prop(tr, "Volume"))
	if cur == nil then
		H.logOnce("master-read", "master volume read failed (masterTracks[0].Volume path probe pending): no write")
		return
	end
	local ok = pcall(function()
		tr.Volume.value = H.clamp01(cur + delta)
	end)
	if not ok then
		H.logOnce("master-write", "master volume write failed on masterTracks[0].Volume")
	end
end

local function masterVolume()
	return tonumber(H.prop(masterTrack(), "Volume")) or 0
end

-----------------------------------------------------------------------------------------------
-- Q-Link integration (control mode, rows 1-2)
--
-- Preferred path (decision 1a): hardware-route the 16 relative encoder CCs straight
-- into the MPC's own Q-Links with mappings.controlSurface.qlinks.AddInfiniteCCToQLink.
-- The MPC then treats the XL3 knobs as native Q-Link knobs (real acceleration, real
-- parameter writes). The script only paints LEDs and the screen.
-- Fallback: when the mapping API is missing, the CCs stay on the script and are
-- translated into qlinks[i].Twist(delta) (SetPosition does not reach the edit value).
-----------------------------------------------------------------------------------------------

local function qlinkBank()
	return dev.mappings and dev.mappings.controlSurface and dev.mappings.controlSurface.qlinks
end

-- Q-Link table access, guarded fallback chain: mpc.controlSurface.qlinks
-- (proven path), else mpc.force.qlinks, else mpc.qlinks. A build that exposes
-- the table nowhere is logged once so an inert Q-Link row explains itself in
-- the journal.
local function mpcQlinks()
	local q = H.safeIndex(H.safeIndex(mpc, "controlSurface"), "qlinks")
	if q ~= nil then
		return q
	end
	q = H.safeIndex(H.safeIndex(mpc, "force"), "qlinks")
	if q ~= nil then
		return q
	end
	q = H.safeIndex(mpc, "qlinks")
	if q == nil then
		H.logOnce("qlinksapi", "qlinks API missing")
	end
	return q
end

local function qlinkAt(i)
	local q = mpcQlinks()
	if q == nil then
		return nil
	end
	return H.safeIndex(q, i)
end

local function qlinkCount()
	local n = H.call(H.callable(mpcQlinks(), "GetNumQLinks"))
	if type(n) == "number" then
		return n
	end
	return 16
end

local function qlinkTargetName(i)
	local q = qlinkAt(i)
	local n = H.call(H.callable(q, "GetTargetName"))
	if type(n) == "string" and n ~= "" then
		return n
	end
	n = H.prop(q, "TargetName")
	if type(n) == "string" and n ~= "" then
		return n
	end
	return nil
end

function H.qlinkFocusName()
	local i = H.prop(mpc.controlSurface and mpc.controlSurface.qlink, "Selected")
	if type(i) == "number" then
		return qlinkTargetName(i)
	end
	local n = tonumber(H.call(H.callable(mpc.controlSurface, "LastTouchedQlink")))
	if n then
		return qlinkTargetName(n)
	end
	return nil
end

local function qlinkValueString(i)
	return tostring(H.call(H.callable(qlinkAt(i), "GetValueString")) or "")
end

-- Twist call forms, tried in order. Sol2 userdata exposes Twist as a method;
-- other builds return a plain function (dot form); fw 1.1.11 may also accept
-- a second fine-adjust argument. A form that errors or leaves the value
-- string unchanged falls through to the next one.
-- Q-Link turn acceleration (fw 1.1.11 device feedback 2026-11-19): a script-side
-- Twist of the raw +/-1 detent moves a Q-Link by ONE position of 128 (~0.16 dB
-- on track level) -- imperceptible. Native MPC knobs accelerate; emulate that:
-- sustained turning ramps the per-detent multiplier 1 -> 2 -> 4 -> 8, a pause
-- of >200 ms resets it, so slow turns stay fine-grained.
local qlinkAccel = {} -- [i] -> { tick = last detent tick, streak = consecutive detents }

local function accelDelta(i, delta)
	local a = qlinkAccel[i]
	if a == nil or (ticks - (a.tick or -99)) > 4 then
		a = { tick = ticks, streak = 0 }
		qlinkAccel[i] = a
	end
	a.tick = ticks
	a.streak = math.min(a.streak + 1, 32)
	local mult = 1
	if a.streak > 1 then
		mult = 2
	end
	if a.streak > 5 then
		mult = 4
	end
	if a.streak > 11 then
		mult = 8
	end
	return delta * mult
end

-- Q-Link twists are DEFERRED to the timer context: the self-test proved Twist
-- moves parameters from HandleTimer, while the same call from the MIDI input
-- callback appears to be silently dropped on fw 1.1.11 (device session
-- 2026-11-19: "Twist accepted" logged from a knob turn, parameter unmoved).
local qlinkPending = {} -- { {i=..., delta=...}, ... } drained immediately (timer as backup)


-- Drive Q-Link i by a relative delta (fallback path). Never errors: every
-- form is pcalled, and when no Twist form moves the target the knob position
-- is synced with SetPosition instead, with a one-line journal note -- this is
-- the diagnostic the next hardware round needs.
__LCXL3_IMMEDIATE = (__LCXL3_IMMEDIATE == nil) and true or __LCXL3_IMMEDIATE
__LCXL3_QDIRTY = {} -- [i] = ticks of the last FAST twist (settle pending)

local function settleQlink(i)
	-- post-spin sync only: refresh the ring/display from the real position.
	-- No parameter write, no SetValue nudge.
	local q = qlinkAt(i)
	if q == nil then
		return
	end
	local pos = tonumber(H.call(H.callable(q, "GetPosition"))) or 0
	H.call(H.callable(q, "SetPosition"), pos)
	H.call(H.callable(q, "Touch"))
	for knob = 0, 15 do -- find the knob that drives this Q-Link for the display
		if QLINK_ORDER[knob + 1] == i then
			showControl(encoderTarget(knob // 8, knob % 8), "Q-Link",
				qlinkTargetName(i) or "Unassigned", qlinkValueString(i))
			break
		end
	end
end

local function twistQlink(i, delta, fast)
	local q = qlinkAt(i)
	if q == nil then
		return false
	end
	if fast then
		-- hot path for active spins: 2 calls, no read-backs (they lag one
		-- change on device and were the per-detent latency). The settle pass
		-- in HandleTimer refreshes the ring once the spin goes quiet.
		__LCXL3_QDIRTY[i] = ticks
		H.call(H.callable(q, "Touch"))
		local d = delta
		if d > 127 then
			d = 127
		elseif d < -127 then
			d = -127
		end
		H.call(H.callable(q, "Twist"), d)
		return true
	end
	-- LPP3-exact Q-Link driver (LaunchpadProMK3 setQlinkPosition, device-proven
	-- on MPC 3.10.1): every call is DOT-form. The method form passes the qlink
	-- table into the C++ layer -- fw 1.1.11 page-corruption suspect -- and is
	-- never used. Drive to an absolute target: dot-Twist (<=2 retries against
	-- the GetPosition lag), then position-scaled SetValue when the value string
	-- did not change, then SetPosition for the knob display.
	local posBefore = tonumber(H.call(H.callable(q, "GetPosition"))) or 0
	local target = H.clamp(posBefore + delta, 0, 127)
	local before = tostring(H.call(H.callable(q, "GetValueString")) or "")
	H.call(H.callable(q, "Touch"))
	if type(q.Twist) == "function" then
		for _ = 1, 2 do
			local d = target - (tonumber(H.call(H.callable(q, "GetPosition")) or 0))
			if d == 0 then
				break
			end
			if d > 127 then
				d = 127
			elseif d < -127 then
				d = -127
			end
			H.call(H.callable(q, "Twist"), d)
		end
	end
	local after = tostring(H.call(H.callable(q, "GetValueString")) or "")
	if after == before and type(q.SetValue) == "function" then
		local v = tonumber(H.call(H.callable(q, "GetValue")))
		if type(v) == "number" and posBefore ~= 0 then
			H.call(H.callable(q, "SetValue"), v * target / posBefore)
		end
		H.call(H.callable(q, "SetPosition"), target)
	elseif type(q.SetPosition) == "function" then
		H.call(q.SetPosition, target)
	end
	H.call(H.callable(q, "Touch"))
	return true
end

local function drainQlinkPending()
	if #qlinkPending == 0 then
		return
	end
	local batch = qlinkPending
	qlinkPending = {}
	for _, t in ipairs(batch) do
		local a = qlinkAccel[t.i]
		twistQlink(t.i, t.delta, a ~= nil and (a.streak or 0) >= 2)
	end
end

-- One-line journal diagnostic on entering control mode: proves the qlinks
-- table was found and names what the first knob drives.
local function logQlinkInventory()
	if mpcQlinks() == nil or qlinkCount() <= 0 then
		H.logOnce("qlinksnone", "qlinks: none exposed")
		return
	end
	H.logOnce("qlinksinv", string.format("qlinks: count=%d first target '%s'", qlinkCount(), tostring(qlinkTargetName(0) or "")))
end

local function scriptOwnsRelCC(cc)
	local m = dev.mappings and dev.mappings.script
	return H.call(H.callable(m, "IsCCMappedToScript"), CH_ANALOG, cc)
end

-- Hand rows 1-2 (relative CC 77-92) to the MPC Q-Links.
local function clearNativeQLinkBindings()
	-- early experiments bound some rel CCs to Q-Links natively; the bindings
	-- persist in the project and keep driving Q-Links (backwards, via the
	-- inverted fw 1.1.11 parser) behind the script's back. Sweep them.
	local b = qlinkBank()
	if b == nil or H.callable(b, "RemoveInfiniteCCToQLink") == nil then
		return
	end
	local removed = 0
	for i = 0, 15 do
		for cc = REL0, REL0 + 15 do
			if pcall(b.RemoveInfiniteCCToQLink, i, cc, CH_ANALOG) then
				removed = removed + 1
			end
		end
	end
	if removed > 0 then
		H.log(string.format("native qlink bindings swept: %d removed", removed))
	end
end

local function mapQlinks()
	if not QLINK_NATIVE_ROUTING then
		qlinkFallback = true
		clearNativeQLinkBindings()
		H.logOnce("qlinkroute", "qlink native routing disabled (fw 1.1.11 direction inversion): script-side Twist active")
		return
	end
	local b = qlinkBank()
	if b == nil or H.callable(b, "AddInfiniteCCToQLink") == nil then
		qlinkFallback = true
		H.logOnce("qlinkroute", "AddInfiniteCCToQLink unavailable: script-side Twist fallback")
		return
	end
	local m = dev.mappings and dev.mappings.script
	local mapped = 0
	for knob = 0, 15 do
		local i = QLINK_ORDER[knob + 1] or knob -- MPC screen order
		local cc = REL0 + knob
		-- the script must not keep the CC while the MPC owns it
		H.call(m and m.RemoveCCToScript, CH_ANALOG, cc)
		-- H4 order first (device-inferred: qlink, cc, channel); the two legacy
		-- orders stay as error-fallbacks only
		local bound = pcall(b.AddInfiniteCCToQLink, i, cc, CH_ANALOG)
			or pcall(b.AddInfiniteCCToQLink, CH_ANALOG, cc, i)
			or pcall(b.AddInfiniteCCToQLink, i, CH_ANALOG, cc)
		-- NON-circular proof per encoder (query-flip): mapped after bind, gone
		-- after remove, back after rebind. The old check trusted the same call
		-- that mis-bound (mirrored argument forms), so it confirmed garbage.
		local qmap = H.callable(b, "IsQLinkMappedInfinite")
		local qrm = H.callable(b, "RemoveInfiniteCCToQLink")
		local ok = bound and H.truthy(H.call(qmap, i, cc))
		if ok then
			H.call(qrm, i, cc)
			ok = not H.truthy(H.call(qmap, i, cc))
		end
		if ok then
			H.call(H.callable(b, "AddInfiniteCCToQLink"), i, cc, CH_ANALOG)
			ok = H.truthy(H.call(qmap, i, cc))
		end
		if ok then
			H.call(H.callable(b, "SetInfiniteCCMagnitude"), i, cc, 1)
			H.call(H.callable(b, "SetQLinkFineAdjust"), i, cc, false)
			mapped = mapped + 1
		else
			-- undo any half-successful mapping attempt (all known argument
			-- orders, so nothing stays hardware-bound unverified) and give the
			-- CC back to the script: per-encoder fallback to twistQlink
			H.call(qrm, i, cc)
			H.call(qrm, CH_ANALOG, cc)
			H.call(qrm, cc, CH_ANALOG)
			H.call(m and m.AddCCToScript, CH_ANALOG, cc)
		end
	end
	qlinkRouted = mapped > 0
	if qlinkRouted then
		H.log(string.format("qlinks routed: %d/16 encoders", mapped))
	else
		qlinkFallback = true
		H.logOnce("qlinkroute0", "qlink routing failed for all 16 encoders: Twist fallback")
	end
end

-- Take rows 1-2 back (mixer mode / unload).
local function unmapQlinks()
	if not qlinkRouted then
		return
	end
	local b = qlinkBank()
	local m = dev.mappings and dev.mappings.script
	for i = 0, 15 do
		local cc = REL0 + i
		-- the argument form mapQlinks verified (qlink, cc)
		H.call(H.callable(b, "RemoveInfiniteCCToQLink"), i, cc)
		H.call(m and m.AddCCToScript, CH_ANALOG, cc)
	end
	qlinkRouted = false
end

-----------------------------------------------------------------------------------------------
-- Property listeners
-----------------------------------------------------------------------------------------------

local function listen(propObj, fn)
	if propObj == nil then
		return
	end
	local ok = pcall(function()
		propObj:listen(fn, deviceName)
	end)
	if ok then
		props[#props + 1] = propObj
	else
		H.logOnce("listen", "property listen failed for one binding")
	end
end

local function stopProps()
	for _, p in ipairs(props) do
		pcall(function()
			p:stopListening(deviceName)
		end)
	end
	props = {}
end

markDirty = function()
	repaintDirty = true
end

-- Bind the visible tracks' mixer properties. Re-run after every bank move.
local function bindTracks()
	for col = 0, 7 do
		local tr = H.trackForCol(col)
		if tr ~= boundTracks[col] then
			boundTracks[col] = tr
		end
		if tr ~= nil then
			for _, name in ipairs({ "Volume", "Pan", "Send1", "Send2", "Send3", "Send4", "Mute", "Solo", "RecArm", "Colour", "Name" }) do
				local c = col
				listen(H.member(tr, name), function()
					markDirty()
				end)
			end
		end
	end
end

local function bindGlobal()
	local t = mpc.tracks
	listen(H.member(t and t.currentTrack, "Index"), function()
		offsetPending = true
		markDirty()
	end)
	listen(H.member(t and t.currentTrack, "Name"), function()
		offsetPending = true
		markDirty()
	end)
	local seq = mpc.sequencer
	for _, name in ipairs({ "Playing", "RecordState", "OverdubState", "Loop", "MetronomeEnabled" }) do
		listen(H.member(seq, name), markDirty)
	end
	listen(H.member(mpc.project, "BPM"), markDirty)
end

-----------------------------------------------------------------------------------------------
-- Fader position sync (pickup)
-----------------------------------------------------------------------------------------------

-- Tell the device where each fader's track volume is, so its hardware pickup can
-- suppress jumps. Called on load, on bank moves and on external volume changes.
local function syncFader(col)
	local tr = H.trackForCol(col)
	local v = tonumber(H.prop(tr, "Volume"))
	if v == nil then
		return
	end
	local pos = math.floor(H.clamp01(v) * 127 + 0.5)
	faderRef[col] = pos
	sendCC(CH_ANALOG, FADER0 + col, pos)
end

local function syncAllFaders()
	for col = 0, 7 do
		syncFader(col)
	end
end

-- Arm software pickup: after a bank move the physical fader is wherever the user
-- left it; ignore movement until it reaches or crosses the track's value.
local function armPickup(col)
	local tr = H.trackForCol(col)
	local v = tonumber(H.prop(tr, "Volume"))
	if v == nil then
		faderArmed[col] = false
		return
	end
	faderRef[col] = math.floor(H.clamp01(v) * 127 + 0.5)
	faderLast[col] = nil
	faderArmed[col] = true
end

local function armAllPickup()
	for col = 0, 7 do
		armPickup(col)
	end
end

-----------------------------------------------------------------------------------------------
-- Painting
-----------------------------------------------------------------------------------------------

local function paintTransport()
	local playing = isPlaying()
	ledSet(BTN.play, playing and PAL.green or PAL.greenDim)
	local rec = recordActive()
	ledSet(BTN.record, rec and PAL.red or PAL.redDim)
end

local function paintNav()
	local n = H.trackCount()
	ledSet(BTN.trackLeft, bank > 0 and PAL.whiteDim or PAL.off)
	ledSet(BTN.trackRight, (bank + 8 < n) and PAL.whiteDim or PAL.off)
	ledSet(BTN.pageUp, PAL.whiteDim)
	ledSet(BTN.pageDown, PAL.whiteDim)
	ledSet(BTN.novation, probeMode and PAL.white or PAL.whiteDim)
end

local function paintModeButtons()
	ledSet(BTN.soloArm, topMode == "arm" and PAL.red or PAL.blue)
	ledSet(BTN.muteSelect, bottomMode == "select" and PAL.white or PAL.orange)
end

-- Clip emptiness: a track is "empty" when it has no clips in the (global)
-- clip matrix. Polled during paints (no listener exists); the loop is bounded
-- and the LED/screen caches keep the wire quiet.
local MAX_CLIP_ROWS = 128

local function trackHasClips(gi)
	local cm = mpc and mpc.clipMatrix
	local hasClip = H.callable(cm, "HasClip")
	if hasClip == nil then
		return true -- no matrix API: never darken the surface on a guess
	end
	local rows = tonumber(H.call(H.callable(cm, "GetRows"))) or MAX_CLIP_ROWS
	rows = math.min(rows, MAX_CLIP_ROWS)
	for r = 0, rows - 1 do
		if H.truthy(H.call(hasClip, gi, r)) then
			return true
		end
	end
	return false
end

-- Light only what means something: empty tracks are dark, and inactive flags
-- (not soloed/arm/muted, not selected) are dark too instead of dim.
local function paintTopRow()
	for col = 0, 7 do
		local tr = H.trackForCol(col)
		local pal = PAL.off
		if tr ~= nil and trackHasClips(bank + col) then
			local flag = (topMode == "arm") and "RecArm" or "Solo"
			pal = H.truthy(H.prop(tr, flag)) and ((topMode == "arm") and PAL.red or PAL.blue) or PAL.off
		end
		ledSet(BTN_ROW1 + col, pal)
	end
end

local function paintBottomRow()
	local cur = tonumber(H.currentTrackIndex())
	if type(cur) == "number" then
		cur = cur - globalOffset -- global -> normal index
	else
		cur = -1
	end
	for col = 0, 7 do
		local tr = H.trackForCol(col)
		local pal = PAL.off
		if tr ~= nil and trackHasClips(bank + col) then
			if bottomMode == "mute" then
				pal = H.truthy(H.prop(tr, "Mute")) and PAL.orange or PAL.off
			else
				local selected = (cur == H.visibleIdx(col))
				pal = selected and PAL.white or PAL.off
			end
		end
		ledSet(BTN_ROW2 + col, pal)
	end
end

-- Track colour as an LED RGB triple (0-127 per component). Near-black or
-- missing colours fall back to dim white so a column is never invisible.
function H.trackColourRGB(tr)
	local c = tonumber(H.prop(tr, "Colour"))
	if c == nil or c <= 0 then
		return PAL.whiteDim
	end
	local r, g, b = H.argb(c)
	r = math.floor(r / 2)
	g = math.floor(g / 2)
	b = math.floor(b / 2)
	if r + g + b < 18 then
		return PAL.whiteDim
	end
	return { r, g, b }
end

-- Pan ring: a continuous readout, not discrete categories. Direction sets the
-- hue (blue L / orange R), distance from centre sets brightness with a steep
-- gamma (1.7) on a 12% floor: the centre is a visible dim WHITE (distinct from
-- both hues, device feedback 2026-11: black-at-centre was unreadable) and the
-- hues fade in from it, reaching the full-bright bases at the extremes.
local PAN_BASE_L = { 24, 72, 127 }
local PAN_BASE_R = { 127, 60, 0 }
local PAN_CENTRE = { 44, 44, 44 } -- centred pan: visible white, never black

-- Value-scaled ring colour: every knob ring works the same way now -- a subtle
-- dark tint of its base colour at zero, brighter as the value rises, full at
-- the top (same ^1.7 curve family as the pan rings).
local function valueScaled(base, t, floorPct)
	t = H.clamp01(tonumber(t) or 0)
	local lo = floorPct or 0.07
	local b = lo + (1 - lo) * (t ^ 1.7)
	return { math.floor(base[1] * b + 0.5), math.floor(base[2] * b + 0.5), math.floor(base[3] * b + 0.5) }
end

-- Q-Link value, normalised 0..1 (GetValue may be 0..1 or 0..127 depending on
-- the parameter; anything above 1 is treated as a 0..127 position).
local function qlinkValue(i)
	local v = tonumber(H.call(H.callable(qlinkAt(i), "GetValue")))
	if v == nil then
		return 0
	end
	if v > 1 then
		v = v / 127
	end
	return H.clamp01(v)
end

-- Normalised 0..1 readouts for the control-mode row 3 global page.
local function globalParamT(col)
	if col == 0 then
		return H.clamp01((getBpm() - 60) / 160) -- musical span 60..220
	elseif col == 1 then
		return H.clamp01((getSwing() - 50) / 25)
	elseif col == 2 then
		return H.clamp01((getStrength() - 0) / 100)
	elseif col == 3 then
		local cur = tostring(H.call(H.callable(quantiser(), "GetTimeDivision")) or "")
		for i, d in ipairs(TIME_DIVISIONS) do
			if d == cur then
				return (i - 1) / math.max(1, #TIME_DIVISIONS - 1)
			end
		end
		return 0.5
	elseif col == 4 then
		return H.truthy(H.prop(mpc.sequencer, "MetronomeEnabled")) and 1 or 0
	elseif col == 5 then
		return H.truthy(H.prop(mpc.sequencer, "Loop")) and 1 or 0
	elseif col == 6 then
		-- ring follows the enumerated filter-type position; the fixed mid level
		-- stays as the degrade (not enumerated yet / type unreadable)
		local cur = tostring(H.call(H.callable(mpc.project, "GetGlobalAutomationFilterType")) or "")
		if autoFilterTypes ~= nil and cur ~= "" then
			for i, t in ipairs(autoFilterTypes) do
				if t == cur then
					return (i - 1) / math.max(1, #autoFilterTypes - 1)
				end
			end
		end
		return 0.7
	elseif col == 7 then
		return H.clamp01(masterVolume())
	end
	return 0
end

local function panPalette(v)
	v = H.clamp01(tonumber(v) or 0.5)
	local d = math.abs(v - 0.5)
	if d < 0.03 then
		return PAN_CENTRE -- dead zone: centred = visible white, distinct from the L/R hues
	end
	local t = 0.12 + 0.88 * math.min(1, d / 0.48) ^ 1.7 -- floor: fade in from the white, never black
	local base = (v < 0.5) and PAN_BASE_L or PAN_BASE_R
	return { math.floor(base[1] * t + 0.5), math.floor(base[2] * t + 0.5), math.floor(base[3] * t + 0.5) }
end

local function paintMixerEncoders()
	-- rows 1/2: the track colour as the base hue, brightness = the send level
	-- of that row (bank A: sends 1/2, bank B: sends 3/4); empty tracks go dark.
	-- Row 3 stays the continuous pan readout.
	for col = 0, 7 do
		local tr = H.trackForCol(col)
		local live = tr ~= nil and trackHasClips(bank + col)
		local base = live and H.trackColourRGB(tr) or PAL.off
		local s1 = mixerParamFor(0)
		local s2 = mixerParamFor(1)
		ledSet(encoderTarget(0, col), live and valueScaled(base, getTrackValue(H.visibleIdx(col), s1)) or PAL.off)
		ledSet(encoderTarget(1, col), live and valueScaled(base, getTrackValue(H.visibleIdx(col), s2)) or PAL.off)
		ledSet(encoderTarget(2, col), live and panPalette(H.prop(tr, "Pan")) or PAL.off)
	end
end

local GLOBAL_COLOURS = {
	PAL.orange, -- tempo
	PAL.yellow, -- swing
	PAL.white, -- quantize strength
	PAL.white, -- quantize division
	PAL.green, -- metronome
	PAL.yellow, -- loop
	PAL.white, -- automation filter
	PAL.white, -- master volume
}

local TRACK_PAGE_COLOURS = {
	PAL.white, -- pan (col 0 paints the pan readout, not this base)
	PAL.blue, -- send 1
	PAL.purple, -- send 2 (device feedback 2026-11: dark blue was indistinguishable from blue)
	PAL.turquoise, -- send 3
	PAL.green, -- send 4
	PAL.orange, -- volume trim (was white: clashed with the white pan centre)
	PAL.whiteDim,
	PAL.whiteDim,
}

local TRACK_PAGE_PARAMS = { "Pan", "Send1", "Send2", "Send3", "Send4", "Volume" }

local function paintControlEncoders()
	local n = qlinkCount()
	for knob = 0, 15 do
		local row = math.floor(knob / 8)
		local col = knob % 8
		local i = qlinkIndexOfKnob(row, col) -- MPC screen order (QLINK_ORDER)
		local pal = PAL.off
		if i < n then
			local nm = qlinkTargetName(i)
			if nm == nil or nm == "" then
				-- an unassigned Q-Link (nil OR empty-string name on fw 1.1.11)
				-- cannot be labelled: the ring stays dark and the journal
				-- explains it once (the input path still drives it)
				H.logOnce("qlinkname" .. i, "qlink " .. i .. " has no target name: ring dark")
			else
				-- Q-Link rows: hue marks the row, brightness follows the value
				pal = valueScaled((row == 0) and PAL.turquoise or PAL.purple, qlinkValue(i))
			end
		end
		ledSet(encoderTarget(row, col), pal)
	end
	local cur = H.currentTrackIndex()
	for col = 0, 7 do
		local pal
		if controlPage == 0 then
			pal = valueScaled(GLOBAL_COLOURS[col + 1], globalParamT(col))
		elseif col == 0 then
			pal = panPalette(getTrackValue(cur, "Pan"))
		elseif col <= 5 then
			pal = valueScaled(TRACK_PAGE_COLOURS[col + 1], getTrackValue(cur, TRACK_PAGE_PARAMS[col + 1]))
		else
			pal = TRACK_PAGE_COLOURS[col + 1] -- unused slots stay dim
		end
		ledSet(encoderTarget(2, col), pal)
	end
end

local function paintAll()
	if not loaded then
		return
	end
	paintTransport()
	paintNav()
	paintModeButtons()
	paintTopRow()
	paintBottomRow()
	paintTrackScreens()
	if surfaceMode == MODE_CONTROL then
		paintControlEncoders()
	else
		paintMixerEncoders()
	end
	paintStaticScreen()
end

-----------------------------------------------------------------------------------------------
-- Input handling
-----------------------------------------------------------------------------------------------

-- Track map: the fader displays permanently identify which track each column
-- controls (name + live volume). The screen cache dedups, so this only sends
-- when a name, bank or volume actually changes.
paintTrackScreens = function()
	for col = 0, 7 do
		local tr = H.trackForCol(col)
		if tr ~= nil then
			showControl(faderTarget(col), H.prop(tr, "Name") or "-", "Volume", H.gainToDb(H.prop(tr, "Volume")))
		else
			showControl(faderTarget(col), "-", "-", "-")
		end
	end
end

-- Overlay naming the tracks the surface currently controls.
local function showTrackOverlay()
	local n = H.trackCount()
	if n <= 0 then
		showOverlay("Tracks", "none")
		return
	end
	local last = math.min(bank + 7, n - 1)
	local first = H.trackAt(bank)
	local lastTr = H.trackAt(last)
	local line2 = ""
	if first ~= nil and lastTr ~= nil then
		line2 = (H.prop(first, "Name") or "-") .. " - " .. (H.prop(lastTr, "Name") or "-")
	elseif first ~= nil then
		line2 = H.prop(first, "Name") or "-"
	end
	showOverlay(string.format("tracks %d-%d", H.uiNumberOf(bank), H.uiNumberOf(last)), line2)
end

local function setBank(newBank)
	local n = H.trackCount()
	local maxBank = math.max(0, n - 8)
	newBank = H.clamp(newBank, 0, maxBank)
	if newBank == bank then
		return
	end
	bank = newBank
	stopProps()
	bindTracks()
	bindGlobal() -- stopProps clears ALL listeners, including the global ones
	offsetPending = true
	armAllPickup()
	syncAllFaders()
	markDirty()
	showTrackOverlay()
	H.log("bank " .. bank)
end

local function setSurfaceMode(m)
	if m == surfaceMode then
		return
	end
	local wasControl = (surfaceMode == MODE_CONTROL)
	surfaceMode = m
	lastAbs = {} -- fresh abs baselines on ANY mode change: a stale baseline
	-- (e.g. absorbed during control mode) makes the first mixer turn JUMP
	if m == MODE_CONTROL then
		mapQlinks()
		logQlinkInventory()
	elseif wasControl then
		unmapQlinks()
	end
	markDirty()
	if m == MODE_CONTROL then
		showOverlay("DAW Control", qlinkRouted and "Q-Links 1-16" or "Q-Links (script)")
	else
		showOverlay("DAW Mixer", sendBank == 0 and "Send 1 + 2, Pan" or "Send 3 + 4, Pan")
	end
end

local function onModeReport(value)
	H.log(string.format("surface mode report %d", value))
	if value == MODE_MIXER or value == MODE_CONTROL then
		setSurfaceMode(value)
	elseif value >= 6 then
		-- custom modes 1-16: the surface belongs to the device; keep transport
		showOverlay("Custom mode", tostring(value))
		H.logOnce("custommode", "custom surface mode " .. value)
	end
end

-- Faders ----------------------------------------------------------------------

local function handleFader(col, value)
	lastTouched = { kind = "fader", row = nil, col = col }
	if faderArmed[col] then
		local ref = faderRef[col] or 64
		local prev = faderLast[col]
		if prev == nil then
			prev = value
		end
		local crossed = (prev < ref and value >= ref) or (prev > ref and value <= ref)
		faderLast[col] = value
		if not crossed and math.abs(value - ref) > 1 then
			return -- still catching up with the track's value
		end
		faderArmed[col] = false
	end
	local idx = H.visibleIdx(col)
	local tr = H.trackAt(idx)
	if tr == nil then
		return
	end
	setTrackValue(idx, "Volume", value / 127)
	showControl(faderTarget(col), H.prop(tr, "Name") or ("Track " .. idx + 1), "Volume", H.gainToDb(value / 127))
end

-- Encoders --------------------------------------------------------------------

-- "Send1" -> "Send 1" for the display.
local function displayName(name)
	return tostring(name):gsub("(%d)$", " %1")
end

mixerParamFor = function(row)
	-- decision 2a: rows 1/2 = sends, row 3 = pan
	if row == 0 then
		return "Send" .. (sendBank * 2 + 1)
	elseif row == 1 then
		return "Send" .. (sendBank * 2 + 2)
	end
	return "Pan"
end

local function handleMixerEncoder(row, col, delta)
	local idx = H.visibleIdx(col)
	local tr = H.trackAt(idx)
	if tr == nil then
		return
	end
	local name = mixerParamFor(row)
	local step = (name == "Pan") and (1 / 127) or (1 / 64)
	nudgeTrackValue(idx, name, delta * step, 0, 1)
	local v = tonumber(getTrackValue(idx, name)) or 0
	local valueText = (name == "Pan") and H.fmtPan(v) or H.fmtPercent(v)
	showControl(encoderTarget(row, col), H.prop(tr, "Name") or ("Track " .. idx + 1), displayName(name), valueText)
	if name == "Pan" then
		ledSet(encoderTarget(row, col), panPalette(v))
	end
end

local function handleGlobalEncoder(col, delta)
	local idx = H.visibleIdx(col)
	if col == 0 then
		local bpm = getBpm()
		setBpm(math.floor(bpm) + delta)
		showControl(encoderTarget(2, col), "Global", "Tempo", string.format("%.1f", getBpm()))
	elseif col == 1 then
		-- step the shadow (GetSwing lags one change on device and once made the
		-- knob stick at 75); the shadow is the source of truth while stepping
		if __LCXL3_SWING == nil then
			__LCXL3_SWING = H.clamp(getSwing(), 50, 75)
		end
		setSwing(__LCXL3_SWING + H.clamp(delta, -1, 1)) -- per-detent clamp: a flick must not jump percent steps
		showControl(encoderTarget(2, col), "Global", "Swing", __LCXL3_SWING .. "%")
	elseif col == 2 then
		setStrength(getStrength() + delta)
		showControl(encoderTarget(2, col), "Global", "Q Strength", getStrength() .. "%")
	elseif col == 3 then
		local d = cycleTimeDivision(delta)
		showControl(encoderTarget(2, col), "Global", "Q Division", d)
	elseif col == 4 then
		local on = (delta > 0)
		local cur = H.truthy(H.prop(mpc.sequencer, "MetronomeEnabled"))
		if on ~= cur then
			toggleMetronome()
		end
		showControl(encoderTarget(2, col), "Global", "Metronome", on and "On" or "Off")
	elseif col == 5 then
		local on = (delta > 0)
		local cur = H.truthy(H.prop(mpc.sequencer, "Loop"))
		if on ~= cur then
			toggleLoop()
		end
		showControl(encoderTarget(2, col), "Global", "Loop", on and "On" or "Off")
	elseif col == 6 then
		local t = cycleAutomationFilter(delta)
		showControl(encoderTarget(2, col), "Global", "Auto Filter", t or "cycle")
	elseif col == 7 then
		nudgeMasterVolume(delta / 127)
		showControl(encoderTarget(2, col), "Master", "Volume", H.gainToDb(masterVolume()))
	end
	markDirty()
end

local function handleTrackPageEncoder(col, delta)
	local cur = H.currentTrackIndex()
	local tr = H.trackAt(cur)
	if tr == nil then
		return
	end
	local params = { "Pan", "Send1", "Send2", "Send3", "Send4", "Volume" }
	local name = params[col + 1]
	if name == nil then
		return
	end
	local step = (name == "Volume") and (1 / 127) or (1 / 96)
	nudgeTrackValue(cur, name, delta * step, 0, 1)
	local v = tonumber(getTrackValue(cur, name)) or 0
	local valueText
	if name == "Volume" then
		valueText = H.gainToDb(v)
	elseif name == "Pan" then
		valueText = H.fmtPan(v)
	else
		valueText = H.fmtPercent(v)
	end
	showControl(encoderTarget(2, col), H.prop(tr, "Name") or ("Track " .. cur + 1), name, valueText)
end

local function handleControlEncoder(row, col, delta)
	lastTouched = { kind = "encoder", row = row, col = col }
	if row < 2 then
		if qlinkRouted then
			return -- the MPC owns these CCs; nothing reaches the script
		end
		local i = qlinkIndexOfKnob(row, col)
		if qlinkAt(i) == nil then
			return -- no Q-Link object behind this knob
		end
		-- Twist even when the target has no name: the name gate lives only in
		-- the LED painter (which logs the dark ring); the display falls back
		-- to "Unassigned". Deferred to the timer context (see qlinkPending).
		qlinkPending[#qlinkPending + 1] = { i = i, delta = accelDelta(i, delta) }
		if __LCXL3_IMMEDIATE then
			drainQlinkPending() -- zero-wait twists (flag-off = timer-drain only)
		end
		local spinning = qlinkAccel[i] ~= nil and (qlinkAccel[i].streak or 0) >= 2
		showControl(encoderTarget(row, col), "Q-Link", qlinkTargetName(i) or "Unassigned",
			spinning and "" or qlinkValueString(i)) -- mid-spin values lag one change anyway
		return
	end
	if controlPage == 0 then
		handleGlobalEncoder(col, delta)
	else
		handleTrackPageEncoder(col, delta)
	end
end

local function handleEncoderRel(row, col, delta)
	if surfaceMode == MODE_CONTROL then
		handleControlEncoder(row, col, delta)
	else
		lastTouched = { kind = "encoder", row = row, col = col }
		handleMixerEncoder(row, col, delta)
	end
end

-- Device-observed (fw 1.1.11): row 1 never enables its relative mode and keeps
-- emitting absolute CCs, while the enabled rows emit relative ones. Absolute
-- input is therefore converted to deltas everywhere: a first sighting is
-- absorbed as the baseline (no action), an impossible jump re-baselines
-- (no action), and every other value nudges like the relative path - nothing
-- is ever direct-written as value/127 again.
local function handleEncoderAbs(row, col, value)
	local i = row * 8 + col -- PHYSICAL knob key for the lastAbs baseline cache
	local last = lastAbs[i]
	lastAbs[i] = value
	if last == nil then
		return -- first sighting: absorb as the baseline, no action
	end
	local delta = value - last
	if delta == 0 then
		return
	end
	if math.abs(delta) > 32 then
		return -- spike (stream mismatch): re-baseline only, no action
	end
	if surfaceMode == MODE_CONTROL then
		if row < 2 then
			if qlinkRouted then
				return -- the MPC owns the rel CCs; abs must not double-step
			end
			local qi = qlinkIndexOfKnob(row, col) -- MPC screen order
			qlinkPending[#qlinkPending + 1] = { i = qi, delta = accelDelta(qi, delta) }
			if __LCXL3_IMMEDIATE then
				drainQlinkPending() -- zero-wait twists (flag-off = timer-drain only)
			end
			local spinning = qlinkAccel[qi] ~= nil and (qlinkAccel[qi].streak or 0) >= 2
			showControl(encoderTarget(row, col), "Q-Link",
				qlinkTargetName(qi) or "Unassigned",
				spinning and "" or qlinkValueString(qi)) -- mid-spin values lag one change anyway
			return
		end
		if controlPage == 0 then
			handleGlobalEncoder(col, delta)
		else
			handleTrackPageEncoder(col, delta)
		end
		return
	end
	handleMixerEncoder(row, col, delta) -- same steps/text/LED as the rel path
	markDirty()
end

-- Touch events (ch 15) --------------------------------------------------------

local function handleTouch(cc, on)
	if not on then
		return
	end
	-- a touch is a good moment to refresh that control's display
	if cc >= FADER0 and cc <= 12 then
		local col = cc - FADER0
		local tr = H.trackForCol(col)
		if tr ~= nil then
			showControl(cc, H.prop(tr, "Name") or ("Track " .. H.visibleIdx(col) + 1), "Volume", H.gainToDb(H.prop(tr, "Volume")))
		end
		return
	end
	local rel = cc - REL0
	if rel >= 0 and rel <= 23 then
		local row = math.floor(rel / 8)
		local col = rel % 8
		if surfaceMode == MODE_CONTROL and row < 2 then
			local i = qlinkIndexOfKnob(row, col)
			showControl(encoderTarget(row, col), "Q-Link", qlinkTargetName(i) or "Unassigned", qlinkValueString(i))
		end
	end
end

-- Buttons (ch 1) --------------------------------------------------------------

local function cycleTopMode()
	topMode = (topMode == "solo") and "arm" or "solo"
	showOverlay("Top row", topMode == "solo" and "Solo" or "Record Arm")
	markDirty()
	H.log("top row: " .. topMode)
end

local function cycleBottomMode()
	bottomMode = (bottomMode == "mute") and "select" or "mute"
	showOverlay("Bottom row", bottomMode == "mute" and "Mute" or "Select")
	markDirty()
	H.log("bottom row: " .. bottomMode)
end

local function doPluginPreset(forward)
	if not H.requireProject("preset") then
		return
	end
	local ct = mpc.tracks and mpc.tracks.currentTrack
	local f = H.callable(ct, forward and "NextPluginPreset" or "PrevPluginPreset")
	if f then
		H.call(f)
		H.log("plugin preset " .. (forward and "next" or "prev"))
	else
		H.logOnce("preset", "plugin preset navigation unavailable on currentTrack")
	end
end

local function cyclePage(dir)
	if surfaceMode == MODE_CONTROL then
		if shiftHeld then
			doPluginPreset(dir > 0)
			return
		end
		controlPage = (controlPage + (dir > 0 and 1 or -1)) % 2
		showOverlay("Row 3", controlPage == 0 and "Global" or "Track")
		markDirty()
		H.log("control row 3 page " .. controlPage)
	elseif shiftHeld then
		doBar(dir)
	else
		sendBank = (sendBank + (dir > 0 and 1 or -1)) % 2
		showOverlay("Sends", sendBank == 0 and "1 + 2" or "3 + 4")
		markDirty()
		H.log("send bank " .. sendBank)
	end
end

local function logStatus()
	H.log(
		string.format(
			"status: mode=%s bank=%d(ui %d-%d) sendBank=%d top=%s bottom=%s qlinks=%s shift=%s",
			surfaceMode == MODE_CONTROL and "control" or "mixer",
			bank,
			H.uiNumberOf(bank),
			H.uiNumberOf(math.min(bank + 7, math.max(H.trackCount() - 1, bank))),
			sendBank,
			topMode,
			bottomMode,
			qlinkRouted and "routed" or (qlinkFallback and "script" or "n/a"),
			tostring(shiftHeld)
		)
	)
end

local function toggleProbe()
	probeMode = not probeMode
	showOverlay("Probe", probeMode and "on" or "off")
	H.log("probe mode " .. tostring(probeMode))
	markDirty()
end

local function probe(channel, cc, value)
	H.log(string.format("probe ch=%d cc=%d value=%d", channel, cc, value))
	-- relative CCs light their control's ABSOLUTE index; buttons light themselves
	local idx = cc
	if cc >= REL0 and cc <= REL0 + 23 then
		idx = cc - 64
	end
	if idx >= FADER0 and idx <= ENC0 + 23 or (cc >= BTN_ROW1 and cc <= BTN_ROW2 + 7) then
		ledSet(idx, value > 0 and PAL.white or PAL.off)
	end
end

-- Plain press actions (all fire on value > 0; Shift variants branch inside).
local BP = {}
BP[BTN.play] = function()
	-- the rewind double-press is plain-only: a quick Shift+Play pair must act
	-- as two shift-presses (stop / stop-all-clips), never rewind
	if not shiftHeld and isDoublePress(BTN.play) then
		doJumpStart()
		return
	end
	if shiftHeld then
		if isPlaying() then
			doStop()
		else
			doStopAll()
		end
	else
		doPlay()
	end
end
BP[BTN.record] = function()
	-- the tap-tempo double-press is plain-only: a quick Shift+Record pair must
	-- always take the overdub branch, never the RecordOff revert + tap path
	if not shiftHeld and isDoublePress(BTN.record) then
		-- the first press of the pair toggled record; undo that side effect
		local st = pressState[BTN.record]
		if st ~= nil and not st.rec and recordActive() then
			H.call(H.callable(mpc.sequencer, "RecordOff"))
			H.log("record disarmed (double-press)")
		end
		doTap()
		return
	end
	if shiftHeld then
		doOverdub()
	else
		doRecord()
	end
end
BP[BTN.trackLeft] = function()
	if shiftHeld then
		doUndo()
	else
		setBank(bank - 1)
	end
end
BP[BTN.trackRight] = function()
	if shiftHeld then
		doRedo()
	else
		setBank(bank + 1)
	end
end
BP[BTN.pageUp] = function()
	cyclePage(1)
end
BP[BTN.pageDown] = function()
	cyclePage(-1)
end
BP[BTN.soloArm] = cycleTopMode
BP[BTN.muteSelect] = cycleBottomMode
BP[BTN.novation] = function()
	if shiftHeld then
		toggleProbe()
	else
		logStatus()
		showTrackOverlay()
	end
end
for col = 0, 7 do
	local c = col
	BP[BTN_ROW1 + c] = function()
		local idx = H.visibleIdx(c)
		if H.trackAt(idx) == nil then
			return
		end
		toggleTrackFlag(idx, topMode == "arm" and "RecArm" or "Solo")
		markDirty()
	end
	BP[BTN_ROW2 + c] = function()
		local idx = H.visibleIdx(c)
		if bottomMode == "select" then
			if H.trackAt(idx) ~= nil then
				selectTrack(idx)
			end
		else
			if H.trackAt(idx) ~= nil then
				toggleTrackFlag(idx, "Mute")
			end
		end
		markDirty()
	end
end

local function setShift(on)
	if shiftHeld == on then
		return
	end
	shiftHeld = on
end

-----------------------------------------------------------------------------------------------
-- MIDI entry points
-----------------------------------------------------------------------------------------------

function LaunchControlXL3.HandleMIDINoteOn(_channel, _note, _velocity) end

function LaunchControlXL3.HandleMIDINoteOff(_channel, _note, _velocity) end

function LaunchControlXL3.HandleMIDICC(channel, cc, value)
	if not loaded then
		return
	end
	-- probe mode swallows the surface, but Shift and the Novation button stay live
	-- so probe can be armed/disarmed from the device itself.
	local escape = (channel == CH_FEATURE and cc == FEAT.shift) or (channel == CH_BUTTON and cc == BTN.novation)
	if channel == CH_FEATURE and cc == FEAT.shift then
		setShift(value > 64)
	end
	if probeMode then
		if not escape then
			probe(channel, cc, value)
			return
		end
	end
	if channel == CH_ANALOG then
		if cc >= FADER0 and cc <= FADER0 + 7 then
			handleFader(cc - FADER0, value)
		elseif cc >= ENC0 and cc <= ENC0 + 23 then
			local i = cc - ENC0
			handleEncoderAbs(math.floor(i / 8), i % 8, value)
		elseif cc >= REL0 and cc <= REL0 + 23 then
			local i = cc - REL0
			local delta = value - 64
			if delta ~= 0 then
				handleEncoderRel(math.floor(i / 8), i % 8, delta)
			end
		end
		return
	end
	if channel == CH_TOUCH then
		handleTouch(cc, value > 64)
		return
	end
	if channel == CH_FEATURE then
		if cc == FEAT.shift then
			-- already tracked above (probe mode needs it live)
		elseif cc == FEAT.mode then
			onModeReport(value)
		elseif cc == FEAT.edit then
			if value > 64 then
				cyclePage(1)
			end
		end
		return
	end
	if channel == CH_BUTTON then
		local fn = BP[cc]
		if fn and value > 0 then
			fn()
		end
		return
	end
end

function LaunchControlXL3.HandleMIDISysex(bytes)
	if type(bytes) ~= "string" then
		return
	end
	if bytes:byte(1) == 0xF0 then
		bytes = bytes:sub(2)
	end
	if bytes:byte(-1) == 0xF7 then
		bytes = bytes:sub(1, -2)
	end
	-- device identity reply: 7E <dev> 06 02 <00 20 29> <family 2> <model 2> <version...>
	if bytes:byte(1) == 0x7E and bytes:byte(3) == 0x06 and bytes:byte(4) == 0x02 and bytes:sub(5, 7) == string.char(0x00, 0x20, 0x29) then
		local ver = {}
		for i = 12, math.min(14, #bytes) do
			ver[#ver + 1] = tostring(bytes:byte(i))
		end
		H.logOnce("firmware", "firmware: " .. (#ver > 0 and table.concat(ver, ".") or "unknown"))
	end
end

-----------------------------------------------------------------------------------------------
-- Timer
-----------------------------------------------------------------------------------------------

-- Refresh the display of the last touched control; external changes (screen,
-- automation, other surfaces) otherwise never reach the device.
local function refreshLastTouched()
	local lt = lastTouched
	if lt == nil then
		return
	end
	if lt.kind == "fader" then
		local tr = H.trackForCol(lt.col)
		if tr ~= nil then
			showControl(faderTarget(lt.col), H.prop(tr, "Name") or "-", "Volume", H.gainToDb(H.prop(tr, "Volume")))
		end
		return
	end
	if surfaceMode == MODE_CONTROL and lt.row < 2 then
		local i = qlinkIndexOfKnob(lt.row, lt.col)
		showControl(encoderTarget(lt.row, lt.col), "Q-Link", qlinkTargetName(i) or "Unassigned", qlinkValueString(i))
		return
	end
	if surfaceMode == MODE_MIXER then
		local tr = H.trackForCol(lt.col)
		if tr ~= nil then
			local name = mixerParamFor(lt.row)
			local v = tonumber(getTrackValue(H.visibleIdx(lt.col), name)) or 0
			showControl(encoderTarget(lt.row, lt.col), H.prop(tr, "Name") or "-", displayName(name), (name == "Pan") and H.fmtPan(v) or H.fmtPercent(v))
		end
	end
end

function LaunchControlXL3.HandleTimer()
	ticks = ticks + 1
	drainQlinkPending() -- leftovers if immediate mode is off (device-proven path)
	for i, act in pairs(__LCXL3_QDIRTY) do
		if (ticks - act) >= 2 then
			__LCXL3_QDIRTY[i] = nil
			settleQlink(i) -- post-spin ring/display sync (no parameter write)
		end
	end
	if offsetPending then
		offsetPending = false
		learnTrackOffset()
	end
	pumpScreen()
	if repaintDirty then
		repaintDirty = false
		paintAll()
	end
	if ticks % 10 == 5 then
		refreshLastTouched()
		paintStaticScreen()
	end
	if ticks % 40 == 0 then
		-- clip emptiness has no listener: re-evaluate every ~2 s. The caches
		-- keep this wire-silent unless something actually changed.
		markDirty()
		local n = H.trackCount()
		if n ~= loggedTrackCount then
			loggedTrackCount = n
			learnTrackOffset()
			local names = {}
			for col = 0, 7 do
				local tr = H.trackForCol(col)
				names[col + 1] = tr ~= nil and (tostring(H.prop(tr, "Name")) or "-") or "."
			end
			H.log(string.format(
				"window: tracks=%d offset=%d ui=%d-%d current=%s first8=[%s]",
				n,
				globalOffset,
				H.uiNumberOf(bank),
				H.uiNumberOf(math.min(bank + 7, math.max(n - 1, bank))),
				tostring(H.currentTrackIndex()),
				table.concat(names, ",")
			))
		end
	end
	if ticks % 4 == 0 and surfaceMode == MODE_CONTROL then
		-- Q-Link/global values are hardware-routed: no listeners, so poll
		-- every 200 ms in control mode (again wire-silent thanks to caches).
		markDirty()
	end
	if ticks == 20 and loaded then
		-- re-ask once the device has had a second to settle after the handshake
		sendCC(CH_QUERY, FEAT.mode, MODE_MIXER)
	end
end


-----------------------------------------------------------------------------------------------
-- Load / unload
-----------------------------------------------------------------------------------------------

-- (channel, cc) pairs the script registers; the MPC only delivers registered input.
local SURFACE_CC = {}
local function buildSurfaceCC() -- wrapper frees main-chunk for-loop locals (200 cap)
for cc = FADER0, FADER0 + 7 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_ANALOG, cc }
end
for cc = ENC0, ENC0 + 23 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_ANALOG, cc }
end
for cc = REL0, REL0 + 23 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_ANALOG, cc }
end
for cc = FADER0, FADER0 + 7 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_TOUCH, cc }
end
for cc = REL0, REL0 + 23 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_TOUCH, cc }
end
for cc = BTN_ROW1, BTN_ROW1 + 7 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_BUTTON, cc }
end
for cc = BTN_ROW2, BTN_ROW2 + 7 do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_BUTTON, cc }
end
for _, k in ipairs({ "soloArm", "muteSelect", "trackRight", "trackLeft", "novation", "pageUp", "pageDown", "play", "record" }) do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_BUTTON, BTN[k] }
end
for _, cc in ipairs({ FEAT.mode, FEAT.edit, FEAT.shift }) do
	SURFACE_CC[#SURFACE_CC + 1] = { CH_FEATURE, cc }
end
end
buildSurfaceCC()

local function routeSurface(toScript)
	local m = dev.mappings and dev.mappings.script
	if m == nil then
		H.logOnce("mappings", "mappings.script missing: no input reaches the script")
		return
	end
	for _, pair in ipairs(SURFACE_CC) do
		local ch, cc = pair[1], pair[2]
		if toScript then
			H.call(m.AddCCToScript, ch, cc)
		else
			H.call(m.RemoveCCToScript, ch, cc)
		end
	end
	H.call(m.SetHandleSysex, toScript)
end

function LaunchControlXL3.OnLoad()
	loaded = false
	surfaceMode = MODE_MIXER
	topMode = "solo"
	bottomMode = "mute"
	bank = 0
	sendBank = 0
	controlPage = 0
	shiftHeld = false
	probeMode = false
	qlinkRouted = false
	qlinkFallback = false
	ticks = 0
	repaintDirty = true
	lastLog = {}
	ledCache = {}
	screenSent = {}
	screenQueue = {}
	faderArmed = {}
	faderRef = {}
	faderLast = {}
	lastAbs = {} -- absolute-encoder baselines: first sighting per control is absorbed
	autoFilterTried = false -- automation-filter enum: re-enumerate on load
	autoFilterTypes = nil
	screenReassert = {} -- post-burst re-assert set: nothing pending on a fresh load
	__LCXL3_SWING = nil -- P1-1: a stale shadow would jump the real swing on re-entry
	qlinkAccel = {} -- P1-2: pre-reload streaks must not continue (ticks reset)
	qlinkPending = {} -- P2-1: detents queued before unload never leak into the new session
	__LCXL3_QDIRTY = {} -- P2-2: pre-reload settle entries are meaningless after a tick reset
	__LCXL3_SCRETRIES = {}
	props = {}
	boundTracks = {}
	lastTouched = nil
	lastPressTick = {}
	pressState = {}

	dawEnter()
	surfaceConfigure()
	routeSurface(true)

	-- displays: stationary 3-line, per-control 3-line, overlay 2-line
	scrConfigure(SCR_STATIC, CFG_THREELINE)
	for target = FADER0, FADER0 + 7 do
		scrConfigure(target, CFG_THREELINE)
	end
	for target = ENC0, ENC0 + 23 do
		scrConfigure(target, CFG_THREELINE)
	end
	scrConfigure(SCR_TEMP, CFG_TWOLINE)

	-- No forced mixer request: after an acvs re-init the hardware may still be
	-- in the DAW Control template, and the query below makes the device REPORT
	-- its real mode (the reply adopts it via onModeReport) instead of us
	-- stomping it to mixer and leaving the user's knob rows misrouted.
	-- feature-control query (ch 8): the reply arrives on ch 7 CC 30 and is
	-- logged by onModeReport -- an end-to-end proof that the session is live
	sendCC(CH_QUERY, FEAT.mode, MODE_MIXER)

	-- firmware probe (universal device inquiry; reply parsed in HandleMIDISysex)
	pcall(function()
		dev.midiOut.SendMIDISysex(string.char(0x7E, 0x7F, 0x06, 0x01), port)
	end)

	bindTracks()
	bindGlobal()
	learnTrackOffset()

	armAllPickup()
	syncAllFaders()

	loaded = true
	paintAll()
	pumpScreen()
	H.call(dev.timer and dev.timer.Start, 50)
	H.log("loaded")
	H.log(
		"engine mode: "
			.. tostring(H.prop(mpc.engineMode, "CurrentMode") or H.call(H.callable(mpc.engineMode, "GetCurrentMode")))
			.. " popup: "
			.. H.currentPopup()
	)
end

function LaunchControlXL3.OnUnload()
	loaded = false
	H.call(dev.timer and dev.timer.Stop)
	unmapQlinks()
	stopProps()
	routeSurface(false)
	clearSurface()
	scrConfigure(SCR_STATIC, 0)
	scrConfigure(SCR_TEMP, 0)
	dawLeave()
	H.log("unloaded")
end

-- Reference data for the generated manual (docs/MANUAL.md).
LaunchControlXL3.ACTIONS = ACTIONS
LaunchControlXL3.PALETTE = PAL
LaunchControlXL3.SURFACE_CC = SURFACE_CC
