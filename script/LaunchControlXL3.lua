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
	{ group = "Encoders, control mode (MIDI ch 16)", cc = ENC0, ch = 16, label = "Rows 1-2", plain = "MPC Q-Links 0-15 (hardware-routed)", shift = "preview on screen" },
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
local blinkOn = false
local repaintDirty = true
local lastLog = {}
local ledCache = {} -- control index -> last palette index sent
local screenSent = {} -- "target:field" -> last text sent
local screenQueue = {} -- closures, pumped a few per timer tick
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
	local amt = math.floor(math.abs(d) * 200 + 0.5)
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

-- Queue one screen text field; identical content is skipped, and the queue is
-- pumped a few messages per timer tick so a repaint never floods the device.
local function scrText(target, field, text)
	text = H.screenText(text)
	local key = tostring(target) .. ":" .. tostring(field)
	if screenSent[key] == text then
		return
	end
	screenSent[key] = text
	screenQueue[#screenQueue + 1] = function()
		sendSysex(SYSEX_HDR .. string.char(0x06, target, field) .. text)
	end
end

local function pumpScreen()
	local budget = 6
	while budget > 0 and #screenQueue > 0 do
		local fn = table.remove(screenQueue, 1)
		fn()
		budget = budget - 1
	end
end

local function screenDirty()
	return #screenQueue > 0
end

-- Overlay: a two-line temporary message (mode/page/probe changes, refusals).
-- The overlay is trigger-driven: the trigger must reach the device AFTER the
-- new text, or it brings up the PREVIOUS contents and the late text never
-- re-renders (device-observed "shows the previous range/name"). Queue the text
-- and the trigger together, at the FRONT of the queue, so bulk repaints cannot
-- delay the overlay either.
local function showOverlay(line1, line2)
	local msgs = {}
	local function pushText(field, text)
		text = H.screenText(text)
		local key = tostring(SCR_TEMP) .. ":" .. tostring(field)
		if screenSent[key] ~= text then
			screenSent[key] = text
			msgs[#msgs + 1] = function()
				sendSysex(SYSEX_HDR .. string.char(0x06, SCR_TEMP, field) .. text)
			end
		end
	end
	pushText(0, line1)
	pushText(1, line2 or "")
	msgs[#msgs + 1] = function()
		sendSysex(SYSEX_HDR .. string.char(0x04, SCR_TEMP, CFG_TWOLINE))
	end
	msgs[#msgs + 1] = function()
		sendSysex(SYSEX_HDR .. string.char(0x04, SCR_TEMP, 0x7F))
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

local function requestSurfaceMode(m)
	sendCC(CH_FEATURE, FEAT.mode, m)
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
	if recordActive() and H.callable(mpc.sequencer, "RecordOff") then
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

local TIME_DIVISIONS = { "1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32" }

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

local function setSwing(v)
	H.call(H.callable(quantiser(), "SetSwing"), H.clamp(v, 50, 75))
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

local function cycleAutomationFilter()
	if not H.requireProject("autofilter") then
		return
	end
	H.call(H.callable(mpc.project, "AdvanceGlobalAutomationFilterType"))
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
	if tr == nil then
		return
	end
	local cur = tonumber(H.prop(tr, "Volume")) or 0.7
	pcall(function()
		tr.Volume.value = H.clamp01(cur + delta)
	end)
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

local function mpcQlinks()
	return mpc.controlSurface and mpc.controlSurface.qlinks
end

local function qlinkAt(i)
	local q = mpcQlinks()
	if q == nil then
		return nil
	end
	local ok, o = pcall(function()
		return q[i]
	end)
	if ok then
		return o
	end
	return nil
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

-- Drive Q-Link i by a relative delta (fallback path).
local function twistQlink(i, delta)
	local q = qlinkAt(i)
	if q == nil then
		return false
	end
	H.call(H.callable(q, "Touch"))
	local ok = pcall(function()
		q:Twist(delta)
	end)
	if not ok then
		ok = H.call(H.callable(q, "Twist"), delta)
	end
	if not ok then
		-- last resort: move the position directly (updates the value string only)
		local pos = tonumber(H.call(H.callable(q, "GetPosition")) or 0)
		H.call(H.callable(q, "SetPosition"), H.clamp(pos + delta, 0, 127))
		H.logOnce("twist", "qlink Twist missing: SetPosition fallback")
	end
	return true
end

local function scriptOwnsRelCC(cc)
	local m = dev.mappings and dev.mappings.script
	return H.call(H.callable(m, "IsCCMappedToScript"), CH_ANALOG, cc)
end

-- Hand rows 1-2 (relative CC 77-92) to the MPC Q-Links.
local function mapQlinks()
	local b = qlinkBank()
	if b == nil or H.callable(b, "AddInfiniteCCToQLink") == nil then
		qlinkFallback = true
		H.logOnce("qlinkroute", "AddInfiniteCCToQLink unavailable: script-side Twist fallback")
		return
	end
	local m = dev.mappings and dev.mappings.script
	local mapped = 0
	for i = 0, 15 do
		local cc = REL0 + i
		-- the script must not keep the CC while the MPC owns it
		H.call(m and m.RemoveCCToScript, CH_ANALOG, cc)
		local ok = pcall(b.AddInfiniteCCToQLink, CH_ANALOG, cc, i)
		if not ok then
			ok = pcall(b.AddInfiniteCCToQLink, i, CH_ANALOG, cc)
		end
		local confirmed = H.call(H.callable(b, "IsQLinkMappedInfinite"), CH_ANALOG, cc)
		if ok and H.truthy(confirmed) then
			mapped = mapped + 1
			H.call(H.callable(b, "SetInfiniteCCMagnitude"), CH_ANALOG, cc, 1)
			H.call(H.callable(b, "SetQLinkFineAdjust"), CH_ANALOG, cc, false)
		else
			-- undo a half-successful mapping attempt and give the CC back to the script
			H.call(H.callable(b, "RemoveInfiniteCCToQLink"), CH_ANALOG, cc)
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
		H.call(H.callable(b, "RemoveInfiniteCCToQLink"), CH_ANALOG, cc)
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
-- gamma (1.7): small offsets start almost black and only real panning lights
-- up, reaching the full-bright bases at the extremes -- high contrast end to end.
local PAN_BASE_L = { 24, 72, 127 }
local PAN_BASE_R = { 127, 60, 0 }

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
		return 0.7 -- filter type: no scalar getter; fixed mid level
	elseif col == 7 then
		return H.clamp01(masterVolume())
	end
	return 0
end

local function panPalette(v)
	v = H.clamp01(tonumber(v) or 0.5)
	local d = math.abs(v - 0.5)
	if d < 0.03 then
		return PAL.off -- dead zone: treat as centred
	end
	local t = math.min(1, d / 0.48) ^ 1.7
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
	PAL.blue, -- pan
	PAL.blue, -- send 1
	PAL.darkBlue, -- send 2
	PAL.turquoise, -- send 3
	PAL.green, -- send 4
	PAL.white, -- volume trim
	PAL.whiteDim,
	PAL.whiteDim,
}

local TRACK_PAGE_PARAMS = { "Pan", "Send1", "Send2", "Send3", "Send4", "Volume" }

local function paintControlEncoders()
	local n = qlinkCount()
	for i = 0, 15 do
		local row = math.floor(i / 8)
		local col = i % 8
		local pal = PAL.off
		if i < n and qlinkTargetName(i) ~= nil then
			-- Q-Link rows: hue marks the row, brightness follows the value
			pal = valueScaled((row == 0) and PAL.turquoise or PAL.purple, qlinkValue(i))
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
	if m == MODE_CONTROL then
		mapQlinks()
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
		setSwing(getSwing() + delta)
		showControl(encoderTarget(2, col), "Global", "Swing", getSwing() .. "%")
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
		if delta > 0 then
			cycleAutomationFilter()
		end
		showControl(encoderTarget(2, col), "Global", "Auto Filter", "cycle")
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
		local i = row * 8 + col
		if qlinkTargetName(i) == nil then
			return
		end
		twistQlink(i, delta)
		showControl(encoderTarget(row, col), "Q-Link " .. (i + 1), qlinkTargetName(i), qlinkValueString(i))
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

-- Absolute encoder values only arrive if the relative-row enable failed; treat
-- them as a direct set (the degrade path).
local function handleEncoderAbs(row, col, value)
	if surfaceMode ~= MODE_CONTROL or row < 2 then
		local idx = H.visibleIdx(col)
		local tr = H.trackAt(idx)
		if tr == nil then
			return
		end
		local name = mixerParamFor(row)
		setTrackValue(idx, name, value / 127)
		local v = tonumber(getTrackValue(idx, name)) or 0
		showControl(encoderTarget(row, col), H.prop(tr, "Name") or ("Track " .. idx + 1), name, (name == "Pan") and H.fmtPan(v) or H.fmtPercent(v))
		markDirty()
		return
	end
	local i = row * 8 + col
	if value == 64 then
		return
	end
	twistQlink(i, value > 64 and 1 or -1)
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
			local i = row * 8 + col
			showControl(encoderTarget(row, col), "Q-Link " .. (i + 1), qlinkTargetName(i) or "Unassigned", qlinkValueString(i))
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
	if isDoublePress(BTN.play) then
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
	if isDoublePress(BTN.record) then
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
		local i = lt.row * 8 + lt.col
		showControl(encoderTarget(lt.row, lt.col), "Q-Link " .. (i + 1), qlinkTargetName(i) or "Unassigned", qlinkValueString(i))
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
	if offsetPending then
		offsetPending = false
		learnTrackOffset()
	end
	if ticks % 10 == 0 then
		blinkOn = not blinkOn
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
	blinkOn = false
	repaintDirty = true
	lastLog = {}
	ledCache = {}
	screenSent = {}
	screenQueue = {}
	faderArmed = {}
	faderRef = {}
	faderLast = {}
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

	requestSurfaceMode(MODE_MIXER)
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
