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
--
-- Signing / build provenance. checksum = sha256(lua_bytes .. salt); the salt is 36 chars,
-- XOR-obfuscated in the MPC application binary. The salt is read from the MPC 3.10.0.49
-- Gen2 firmware update image (`MPC-3.10.0.49-gen2`, md5 15a664f6b6ae591c8b78baae8b376f02,
-- build id 2209920bc0a): 36 chars at file offset 0x5287C10, XOR key 0x5F694973D3C78945.
-- That image is the reference because the on-device firmware's salt obfuscation moved while
-- the loader still validates the same salt; it reproduces Akai's shipped checksums for the
-- 3.10.1.8 device scripts (mpkMiniMkIV, mpkMiniPlusII). Tools: tools/make-release.sh
-- (minify + sign + zip), tools/sign_script.py (writes checksum=), tools/verify_salt.py
-- (proves the salt against Akai's shipped pairs); MPC_SALT overrides it (36 chars only,
-- never falls back silently). Deployment and rollback: docs/INSTALL.md sections 3-4.
-- The salt is never printed or written to disk by any of these tools.
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

-- Q-Link native routing (mapQlinks): OFF pending the direction probe. The BINDING
-- API signatures are proven from Akai's shipped 3.10 kit scripts (mpkMiniMkIV.lua
-- lines 991-1099/1204-1230): AddInfiniteCCToQLink(channel, cc, qlinkIndex),
-- RemoveInfiniteCCToQLink(channel, cc), SetQLinkFineAdjust(bool). What is NOT
-- proven is the encoding the MPC's infinite-CC parser expects: Akai's own
-- controllers speak 7-bit two's complement, the XL3 speaks binary offset, and
-- v1.0's "moves backwards" observation fits BOTH readings (a sign-flipped offset
-- or two's complement) -- the parser's sign/magnitude is unprobed
-- (reports/00-FINAL-TRIAGE.md section 5 probe 10). Routing stays disabled until
-- that probe runs; it is not known to be unviable. v1.0's "only the last encoder
-- worked" is also consistent with a CORRECT binding (a reconstruction, not
-- device-proven: row 1 speaks absolute only and Q-Links without a target are
-- invisible, so a fully-bound bank can look dead). Until the probe, all 16
-- Q-Links are driven script-side (Twist fallback: rel row 2 direct, abs-only
-- row 1 via the P0-2 abs-delta path).
-- Q-Link knob order (column-major; device-checked on the user's MPC 3.10.1,
-- 2026-11-20): the Q-Link screen lists the 16 slots as four groups of four read
-- top-to-bottom -- group 1 is Q-Links 13,9,5,1 (indices 12,8,4,0), group 2 is
-- 14,10,6,2, group 3 is 15,11,7,3, group 4 is 16,12,8,4. The XL3 mirrors the
-- groups in order: knob row 1 = groups 1+2, row 2 = groups 3+4, each group's
-- four slots left-to-right on the knob row. The page-interleaved variant
-- (4 pages of 4) was tried and REJECTED on hardware 2026-11-25 (owner: OPx
-- plugin macros came out reversed on row-1 knobs 1-4), so this table must not
-- be "fixed" again without new device evidence.
local QLINK_ORDER = { 12, 8, 4, 0, 13, 9, 5, 1, 14, 10, 6, 2, 15, 11, 7, 3 }

-- diagnostic build: bounded turn tracing (global to dodge the 200-local cap)

-- Two knob orders exist (owner device findings, 2026-11-20 + 2026-11-27): the
-- column-major QLINK_ORDER above is right for TRACK/plugin pages (OPx macros
-- 1-4 ascend on row-1 knobs 1-4), but on the MPC's GLOBAL/main Q-Link page the
-- params sit at indices 0..15 in order, so knob p must drive index p (identity
-- order; state + accessors on the H table below). qlinkIndexOfKnob is assigned
-- once H exists; it is first called from the input/paint paths only.
local qlinkIndexOfKnob -- knob (row,col) -> active Q-Link index (assigned below, after H)

-- Native routing master switch: a GLOBAL (not a local) so the test suite can arm
-- the path. Default and shipped state: false -- off pending the direction probe.
__LCXL3_NATIVE = false

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
local qlinkScriptCC = {} -- knobs whose native bind failed verification: script-side per encoder
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
local faderSync = {} -- col -> pickup record { pos = position CC last sent to the
-- device, picked = a fader message was accepted since the last arm (F9: the user
-- is driving it, never re-reference), tick = tick of the last fader message }
local props = {} -- listenable properties bound at load {obj, unbind}
local boundTracks = {} -- [col] = track object currently bound
local lastTouched = nil -- {kind="fader"|"encoder", row, col}

-----------------------------------------------------------------------------------------------
-- Utilities
-----------------------------------------------------------------------------------------------

local H = {}

-- Active knob-order state. Default false = the column-major TRACK order
-- (QLINK_ORDER), exactly the shipped behaviour; H.qlinkSetIsGlobal() flips it
-- when the loaded Q-Link set matches the GLOBAL page's target-name signature.
H.qlinkOrderGlobal = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
H.qlinkGlobalSet = false

-- The one place the active order is read: every knob -> Q-Link mapping goes
-- through here so a GLOBAL-page set swaps the whole map at once.
local function qlinkOrderAt(k)
	if H.qlinkGlobalSet then
		return H.qlinkOrderGlobal[k]
	end
	return QLINK_ORDER[k]
end
qlinkIndexOfKnob = function(row, col)
	local p = row * 8 + col
	return qlinkOrderAt(p + 1) or p
end

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
		local keys = {}
		for key in pairs(reassert) do
			keys[#keys + 1] = key
		end
		table.sort(keys) -- pairs order varies per session (hash seed): force the device order
		for _, key in ipairs(keys) do
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

-- Hardware fader pickup (default on): the device holds its own fader still until
-- the physical fader reaches the script-sent position. Turn it off only if faders
-- STILL demand a trip to the bottom after this build — that would mean the
-- device-side pickup holds a stale reference of its own; then only the software
-- guard protects against jumps.
__LCXL3_HWPICKUP = (__LCXL3_HWPICKUP == nil) and true or __LCXL3_HWPICKUP

local function surfaceConfigure()
	for _, cc in ipairs(FEAT.relRow) do
		sendCC(CH_FEATURE, cc, 127) -- relative encoders, all three rows
	end
	sendCC(CH_FEATURE, FEAT.touch, 127) -- touch events on ch 15
	sendCC(CH_FEATURE, FEAT.pickup, __LCXL3_HWPICKUP and 127 or 0) -- fader pickup against script-sent positions
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

-- Shadow stepping (finding F5): every mixer/row-3 read-modify-write used to
-- compute new = read + delta against reads that lag the writes, so a fast turn
-- applied only a fraction of its detents (12 CW detents landed ~3 steps).
-- These helpers step a per-key shadow instead: within STEP_QUIET of our own
-- write the shadow IS the truth; after the quiet gap the next detent re-reads
-- the device (an external change shows up then). Displays and rings read
-- through H.cur, so a turn shows the value it wrote and an idle repaint
-- follows the device.
H.STEP_QUIET = 6 -- 300 ms of shadow trust (six 50 ms timer ticks)
H.step = {} -- [key] = { v = value written, tick = tick of the write }

-- Step a numeric parameter by delta. readFn answers the live value (nil =
-- unreadable); writeFn answers false when the write was refused/failed. A
-- failed write records no shadow (the next detent retries from the same
-- base). Returns the value WRITTEN -- the display shows it -- or nil.
function H.stepped(key, readFn, writeFn, delta, lo, hi)
	local s = H.step[key]
	local base
	if s ~= nil and s.v ~= nil and (ticks - s.tick) <= H.STEP_QUIET then
		base = s.v
	else
		base = tonumber(readFn())
		if base == nil and s ~= nil and s.v ~= nil then
			base = s.v -- unreadable now: the last written value beats a blind default
		end
		if base == nil then
			H.logOnce("step-" .. key, "stepper: " .. key .. " has no readable value and no shadow: no write")
			return nil
		end
	end
	local v = H.clamp(base + delta, lo, hi)
	if writeFn(v) == false then
		return nil
	end
	H.step[key] = { v = v, tick = ticks }
	return v
end

-- The current value of a stepped parameter: the fresh shadow (a turn just
-- wrote it) or the live read (idle). For displays and rings.
function H.cur(key, readFn)
	local s = H.step[key]
	if s ~= nil and s.v ~= nil and (ticks - s.tick) <= H.STEP_QUIET then
		return s.v
	end
	return readFn()
end

H.want = {} -- [key] = { want = bool, tick } of the last setWanted request

-- Switch-style stepping for metronome/loop (finding F8): the direction
-- decides the wanted state (CW = on, CCW = off) and the setter is idempotent
-- (Set, never toggle), so a lagging read can never flip the state back. A
-- repeated request in the same direction within STEP_QUIET sends nothing;
-- after the quiet gap the device is re-read and only a real difference writes.
function H.setWanted(key, want, readFn, setFn)
	local w = H.want[key]
	if w ~= nil and w.want == want and (ticks - (w.tick or 0)) <= H.STEP_QUIET then
		w.tick = ticks -- the same request is still in flight: stay silent
		return
	end
	local cur = readFn()
	if cur ~= nil and H.truthy(cur) == want then
		H.want[key] = { want = want, tick = ticks } -- already there (lag settled or external change)
		return
	end
	setFn(want)
	H.want[key] = { want = want, tick = ticks }
end

H.enum = {} -- [key] = { dir, acc, tick, idx, cur } per enumerated stepper

-- Step an enumerated parameter (a list index) with a detent divider: the
-- fractional accumulator takes dir/perStep per detent and one whole unit is
-- one list step (perStep = 2 halves the "too quick" list scrolling). The
-- index comes from the fresh shadow, else from read(); stepping SATURATES at
-- both ends (no wrap -- the automation filter used to cycle per detent). A
-- direction change or a gap > STEP_QUIET resets the accumulator and
-- re-anchors the index from the device. Without a list (opts.list nil) the
-- degrade advances CW only, still detent-divided.
function H.enumStep(key, dir, opts)
	dir = (dir > 0) and 1 or -1
	local per = tonumber(opts.perStep) or 1
	if per <= 0 then
		per = 1
	end
	local st = H.enum[key]
	if st == nil or st.dir ~= dir or (ticks - (st.tick or 0)) > H.STEP_QUIET then
		st = { dir = dir, acc = 0, tick = ticks, idx = nil, cur = nil }
		H.enum[key] = st
	end
	st.tick = ticks
	st.acc = st.acc + dir / per
	local steps = 0
	if st.acc >= 1 then
		steps = math.floor(st.acc)
	elseif st.acc <= -1 then
		steps = math.ceil(st.acc)
	end
	if steps == 0 then
		return nil -- half a unit: wait for the next detent
	end
	st.acc = st.acc - steps
	local list = opts.list and opts.list() or nil
	if list == nil or #list == 0 then
		-- degrade: CW ONLY (a CCW detent is a no-op -- the scan cannot run
		-- backwards), still detent-divided
		for _ = 1, (dir > 0) and steps or 0 do
			H.call(opts.advance)
		end
		return nil
	end
	local n = #list
	if st.idx == nil then
		local cur = opts.read and opts.read() or nil
		if cur ~= nil then
			for i = 1, n do
				if list[i] == cur then
					st.idx = i
					break
				end
			end
		end
		if st.idx == nil then
			st.idx = 1 -- unknown current: anchor at the list head
		end
	end
	local target = H.clamp(st.idx + steps, 1, n)
	if target == st.idx then
		return nil -- saturated: no wrap, no write
	end
	local item = list[target]
	if opts.write(item) == false then
		return nil -- the write refused: the shadow stays on the old index
	end
	st.idx = target
	st.cur = item
	return item
end

-- The value an enumerated stepper last wrote, while its shadow is fresh.
function H.enumSeen(key)
	local st = H.enum[key]
	if st ~= nil and st.cur ~= nil and (ticks - (st.tick or 0)) <= H.STEP_QUIET then
		return st.cur
	end
	return nil
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

-- F10 journal: raw transport state codes around an overdub toggle (device facts:
-- numeric properties, 0 off / 1 recording / 2 armed). "after " keeps the two-space
-- alignment of the task's log spec.
function H.odState(when)
	H.log(string.format(
		"overdub: %s rec=%d od=%d play=%s",
		when,
		tonumber(H.prop(mpc.sequencer, "RecordState")) or -1,
		tonumber(H.prop(mpc.sequencer, "OverdubState")) or -1,
		tostring(isPlaying())
	))
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

-- T4 (F10): opt-in clean overdub-off path (default off — today's guarded
-- sequence stays the default). __LCXL3_OD_GUARD latches per session once the
-- clean path is proven to stop playback; OnLoad resets both globals.
__LCXL3_OD_CLEAN = (__LCXL3_OD_CLEAN == nil) and false or __LCXL3_OD_CLEAN
__LCXL3_OD_GUARD = false

local function doOverdub()
	if not H.requireProject("overdub") then
		return
	end
	-- F10 diagnostics: journal the raw transport numbers around every toggle;
	-- the matching "after" line fires two ticks later from HandleTimer (one
	-- pending toggle max: a newer toggle re-arms the watch).
	H.odState("before")
	H.odAfter = ticks + 2
	if H.truthy(H.prop(mpc.sequencer, "OverdubState"))
		and not H.truthy(H.prop(mpc.sequencer, "RecordState")) then
		if __LCXL3_OD_CLEAN and not __LCXL3_OD_GUARD and isPlaying() then
			-- opt-in clean path: unambiguous overdub-only playing state. Plain
			-- toggle — no Record() pre-arm, so no record LED flash. The playback
			-- drop check runs two ticks later (HandleTimer) and latches the guard.
			H.call(H.callable(mpc.sequencer, "Overdub"))
			H.odVerify = ticks + 2
			H.log("overdub")
			return
		end
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
	return tonumber(H.call(H.callable(quantiser(), "GetSwing")))
end

-- Swing units (open H2/H3 question, auto-detected on the first read): raw
-- >= 10 is the percent form (50..75); raw <= 1 is a 0..1 fraction spanning
-- the same range (displayed as 50 + raw*25); anything between assumes
-- percent and says so once. Stepping always happens in percent (one detent =
-- one percent, sign-only), so the unit lives only in this read/write pair --
-- and the retired __LCXL3_SWING shadow moved into H.step["swing"], which
-- re-syncs from the device after a quiet gap (no more jump-to-max on a
-- stale ceiling).
function H.swingRead()
	local raw = getSwing()
	if raw == nil then
		return nil
	end
	if H.swingUnit == nil then
		if raw >= 10 then
			H.swingUnit = "pct"
		elseif raw <= 1 then
			H.swingUnit = "frac"
		else
			H.swingUnit = "pct"
			H.logOnce("swingunit", string.format("swing unit ambiguous at %g: assuming percent", raw))
		end
	end
	if H.swingUnit == "frac" then
		return 50 + raw * 25
	end
	return raw
end

local function swingWrite(pct)
	local raw = pct
	if H.swingUnit == "frac" then
		raw = (pct - 50) / 25
	end
	-- return whether the write actually happened without error: H.call hides
	-- both a missing callable and a thrown error behind nil, and setters
	-- return nothing on success, so check the callable and pcall directly.
	-- H.stepped refuses a shadow only on an explicit false.
	local f = H.callable(quantiser(), "SetSwing")
	if f == nil then
		return false
	end
	return pcall(f, raw) == true
end

local function getStrength()
	return tonumber(H.call(H.callable(quantiser(), "GetStrength")))
end

local function setStrength(v)
	-- same contract as swingWrite: explicit false when the write never
	-- happened (no callable) or threw, so H.stepped records no shadow
	local f = H.callable(quantiser(), "SetStrength")
	if f == nil then
		return false
	end
	return pcall(f, H.clamp(v, 0, 100)) == true
end

-- Time-division read, normalised to TIME_DIVISIONS: an unknown device string
-- anchors at 1/16 (logged once) so stepping stays meaningful; nil = unreadable.
local function readDivision()
	local cur = H.call(H.callable(quantiser(), "GetTimeDivision"))
	if cur == nil then
		return nil
	end
	cur = tostring(cur)
	for _, d in ipairs(TIME_DIVISIONS) do
		if d == cur then
			return d
		end
	end
	H.logOnce("divunit", string.format("unknown time division '%s': assuming 1/16", cur))
	return "1/16"
end

-- Global automation filter type (control mode, row 3 col 6). The scalar
-- Get/Set pair exists (LPP3 dump); on 3.10.1 GlobalAutomationFilterType is
-- also a listenable property (Akai's own script reads it), so the read
-- prefers the property and falls back to Get. The enum is enumerated
-- ASYNCHRONOUSLY on the first turn of the knob (never at mode entry: cycling
-- the filter during a recording take could matter): one Advance per
-- discovered type, the read polled every tick, the list complete when the
-- read returns to the start type -- the advances restored it by themselves.
-- A read that lags the writes repeats the last type and is just waited out
-- (bounded polls); it never appends a duplicate, which is what corrupted the
-- old synchronous Advance+Get-in-one-tick enumeration. While scanning,
-- detents are ignored and the display shows "scanning". Without Set/Advance
-- or a readable type, the CW-only Advance degrade stays (one step per two
-- detents).
local autoFilter = { phase = "idle", list = nil, t0 = nil, polls = 0 }

local function filterRead()
	local p = mpc and mpc.project
	local v = H.prop(p, "GlobalAutomationFilterType")
	if v ~= nil and v ~= "" then
		return tostring(v)
	end
	return H.call(H.callable(p, "GetGlobalAutomationFilterType"))
end

local function filterDetent(delta)
	if not H.requireProject("autofilter") then
		return
	end
	local p = mpc and mpc.project
	local set = H.callable(p, "SetGlobalAutomationFilterType")
	local adv = H.callable(p, "AdvanceGlobalAutomationFilterType")
	if autoFilter.phase == "idle" then
		if set == nil or adv == nil then
			autoFilter.phase = "degrade"
			H.logOnce("autofilter", "automation filter Get/Set unavailable: CW-only Advance fallback")
		else
			local t0 = filterRead()
			if t0 == nil then
				autoFilter.phase = "degrade"
				H.logOnce("afnil", "autofilter enum: filter type unreadable: CW-only Advance fallback")
			else
				autoFilter.phase = "scan"
				autoFilter.list = { t0 }
				autoFilter.t0 = t0
				autoFilter.polls = 0
				H.call(adv) -- kick: one advance per discovered type
			end
		end
	end
	if autoFilter.phase == "scan" then
		return -- detents are ignored while scanning
	end
	if autoFilter.phase == "degrade" or autoFilter.list == nil or #autoFilter.list == 0 or set == nil then
		H.enumStep("autofilter", delta, { list = nil, advance = adv, perStep = 2 })
		return
	end
	H.enumStep("autofilter", delta, {
		list = function()
			return autoFilter.list
		end,
		read = filterRead,
		write = function(v)
			if not pcall(set, v) then
				H.logOnce("afset", "automation filter Set failed: CW-only Advance fallback")
				return false
			end
			return true
		end,
		perStep = 2,
	})
end

-- One tick of the scan state machine (called from HandleTimer every tick).
local function filterTick()
	if autoFilter.phase ~= "scan" then
		return
	end
	local p = mpc and mpc.project
	local v = filterRead()
	local last = autoFilter.list[#autoFilter.list]
	if v ~= nil and v ~= last then
		if v == autoFilter.t0 then
			autoFilter.phase = "ready" -- the advances walked the cycle and restored the start type
			H.log(string.format("autofilter enum: %d types", #autoFilter.list))
			return
		end
		autoFilter.list[#autoFilter.list + 1] = v
		if #autoFilter.list >= 12 then
			-- no repeat within the bound: restore the start type, step blind
			H.call(H.callable(p, "SetGlobalAutomationFilterType"), autoFilter.t0)
			H.logOnce("afbound", "autofilter enum: no cycle repeat within 12 advances: Advance fallback")
			autoFilter.phase = "degrade"
			autoFilter.list = nil
			return
		end
		autoFilter.polls = 0
		H.call(H.callable(p, "AdvanceGlobalAutomationFilterType"))
		return
	end
	autoFilter.polls = autoFilter.polls + 1
	if autoFilter.polls > 6 then
		-- no change within the poll bound: a single-type enum (or a dead Advance)
		autoFilter.phase = "ready"
		H.logOnce("afsingle", "autofilter enum: single type (Advance shows no change)")
	end
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

-- Master volume read/write for the stepped path: only a REAL read allows a
-- write (masterTracks[0].Volume is not the proven fader path, probe pending),
-- and a failed write records no shadow (the guard fires again next detent).
local function readMasterVolume()
	local v = tonumber(H.prop(masterTrack(), "Volume"))
	if v == nil then
		H.logOnce("master-read", "master volume read failed (masterTracks[0].Volume path probe pending): no write")
	end
	return v
end

local function writeMasterVolume(v)
	local tr = masterTrack()
	if tonumber(H.prop(tr, "Volume")) == nil then
		return false -- no blind write over an unreadable slot (device D2/D3/D4)
	end
	local ok = pcall(function()
		tr.Volume.value = v
	end)
	if not ok then
		H.logOnce("master-write", "master volume write failed on masterTracks[0].Volume")
		return false
	end
	return true
end

-----------------------------------------------------------------------------------------------
-- Q-Link integration (control mode, rows 1-2)
--
-- Preferred path: hardware-route the 16 relative encoder CCs into the MPC's own
-- Q-Links with mappings.controlSurface.qlinks.AddInfiniteCCToQLink, using the
-- signatures proven by Akai's shipped kit scripts: Add(channel, cc, qlinkIndex),
-- Remove(channel, cc), IsQLinkMappedInfinite(channel, cc), SetQLinkFineAdjust(bool).
-- The MPC then treats the XL3 knobs as native Q-Link knobs (real acceleration, real
-- parameter writes); the script only paints LEDs and the screen. Whether the
-- parser's direction/magnitude matches the XL3's binary-offset encoding is UNPROBED
-- (see the header note near QLINK_ORDER): the path stays behind __LCXL3_NATIVE
-- (default false) until the probe runs.
-- Fallback: when the mapping API is missing or a per-encoder verification fails,
-- that CC stays on the script and is translated into qlinks[i].Twist(delta)
-- (SetPosition does not reach the edit value).
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


-- One-line journal diagnostic on entering control mode: proves the qlinks
-- table was found and names what the first knob drives.
local function logQlinkInventory()
	if mpcQlinks() == nil or qlinkCount() <= 0 then
		H.logOnce("qlinksnone", "qlinks: none exposed")
		return
	end
	H.logOnce("qlinksinv", string.format("qlinks: count=%d first target '%s'", qlinkCount(), tostring(qlinkTargetName(0) or "")))
	-- owner-visible index -> target-name inventory (bounded, once per session):
	-- settles which Q-Link slot holds which parameter (e.g. plugin macros) so the
	-- knob order can be checked against the screen instead of guessed.
	local inv = {}
	for i = 0, math.min(qlinkCount(), 16) - 1 do
		inv[#inv + 1] = string.format("%d='%s'", i, tostring(qlinkTargetName(i) or ""):sub(1, 14))
	end
	H.logOnce("qlinksdump", "qlinks inv: " .. table.concat(inv, " "))
end

-- Detect which Q-Link set is loaded. The MPC exposes no page/selection property
-- (API-CONTRACT.md:78 -- qlink.Selected does not exist), so the GLOBAL/main page
-- is identified by its target names alone: device dump 2026-11-27 shows
-- 0='TRACK LEVEL' 1='PLAYHEAD' 4='TIME DIVISION' sitting at indices 0..15 in
-- order. Names can truncate (the dump caps at 14 chars) and are unreadable while
-- a project loads: judge >= 2 of the 3 signature names with an 8-char-minimum
-- prefix test; on an unreadable/empty read keep the current flag (the default
-- false stays column-major, i.e. today's behaviour). Cheap: 3 reads per refresh,
-- no allocation beyond the trimmed name string.
function H.qlinkSetIsGlobal()
	local sig = { [0] = "TRACK LEVEL", [1] = "PLAYHEAD", [4] = "TIME DIVISION" }
	local matches = 0
	local readable = 0
	for k = 0, 4 do
		local nm = qlinkTargetName(k)
		if type(nm) == "string" and nm ~= "" then
			readable = readable + 1
			local want = sig[k]
			if want ~= nil then
				local up = nm:upper()
				up = up:gsub("^%s+", "")
				up = up:gsub("%s+$", "")
				-- prefix of at least 8 chars: exact when fully readable, prefix
				-- when the device truncated the name
				if #up >= 8 and want:sub(1, #up) == up then
					matches = matches + 1
				end
			end
		end
	end
	if readable == 0 then
		return H.qlinkGlobalSet -- unreadable/empty: keep the current flag
	end
	local global = matches >= 2
	if global ~= H.qlinkGlobalSet then
		H.qlinkGlobalSet = global
		H.log(global and "qlink order: global (identity, params at 0..15)" or "qlink order: track (column-major, plugin slots)")
		markDirty() -- LEDs/screen must follow the new order on the next tick
	end
	return global
end

local function scriptOwnsRelCC(cc)
	local m = dev.mappings and dev.mappings.script
	return H.call(H.callable(m, "IsCCMappedToScript"), CH_ANALOG, cc)
end

-- Hand rows 1-2 (relative CC 77-92) to the MPC Q-Links.
local function clearNativeQLinkBindings()
	-- Earlier versions bound rel CCs with unverified argument orders; those
	-- bindings persist in the project and keep driving Q-Links behind the
	-- script's back. Akai's key is (channel, cc): the legacy mis-bind forms
	-- collapse onto the same cc keys, so one Remove per cc covers them. The
	-- on-device behaviour of the legacy 3-argument forms is unknown; this
	-- sweep only claims what it can verify.
	local b = qlinkBank()
	if b == nil or H.callable(b, "RemoveInfiniteCCToQLink") == nil then
		return
	end
	local qmap = H.callable(b, "IsQLinkMappedInfinite")
	if qmap == nil then
		for cc = REL0, REL0 + 23 do
			H.call(b.RemoveInfiniteCCToQLink, CH_ANALOG, cc)
		end
		H.logOnce("nativesweep", "native bindings swept cc 77-100 blind (query API missing: count unverified)")
		return
	end
	local removed = 0
	for cc = REL0, REL0 + 23 do
		-- gate on the query so the count is real, not "the call did not throw"
		if H.truthy(H.call(qmap, CH_ANALOG, cc)) then
			H.call(b.RemoveInfiniteCCToQLink, CH_ANALOG, cc)
			removed = removed + 1
		end
	end
	if removed > 0 then
		H.log(string.format("native qlink bindings swept: %d removed (cc 77-100)", removed))
	end
end

local function mapQlinks()
	if not __LCXL3_NATIVE then
		qlinkFallback = true
		clearNativeQLinkBindings()
		H.logOnce("qlinkroute", "qlink native routing off (pending the direction probe): script-side Twist active")
		return
	end
	local b = qlinkBank()
	local qadd = H.callable(b, "AddInfiniteCCToQLink")
	local qrm = H.callable(b, "RemoveInfiniteCCToQLink")
	local qmap = H.callable(b, "IsQLinkMappedInfinite")
	if qadd == nil or qrm == nil or qmap == nil then
		qlinkFallback = true
		H.logOnce("qlinkroute", "native mapping API incomplete (Add/Remove/query): script-side Twist fallback")
		return
	end
	local m = dev.mappings and dev.mappings.script
	local mapped = 0
	for knob = 0, 15 do
		local i = qlinkOrderAt(knob + 1) or knob -- active order (QLINK_ORDER / H.qlinkOrderGlobal)
		local cc = REL0 + knob
		-- the script must not keep the CC while the MPC owns it
		H.call(m and m.RemoveCCToScript, CH_ANALOG, cc)
		-- Akai's shipped signature (mpc310 kit scripts): (channel, cc, qlinkIndex)
		H.call(qadd, CH_ANALOG, cc, i)
		-- Non-circular proof per encoder: mapped after bind, gone after remove,
		-- back after re-add. Every step asks the MPC's own state, so a host that
		-- accepts binds but stores nothing fails here instead of confirming garbage.
		local ok = H.truthy(H.call(qmap, CH_ANALOG, cc))
		if ok then
			H.call(qrm, CH_ANALOG, cc)
			ok = not H.truthy(H.call(qmap, CH_ANALOG, cc))
		end
		if ok then
			H.call(qadd, CH_ANALOG, cc, i)
			ok = H.truthy(H.call(qmap, CH_ANALOG, cc))
		end
		if ok then
			qlinkScriptCC[knob] = nil
			mapped = mapped + 1
		else
			-- undo the attempt and hand the CC back to the script:
			-- per-encoder fallback to the script-side driver
			H.call(qrm, CH_ANALOG, cc)
			H.call(m and m.AddCCToScript, CH_ANALOG, cc)
			qlinkScriptCC[knob] = true
		end
	end
	qlinkRouted = mapped > 0
	if qlinkRouted then
		-- a global toggle in Akai's API: one bool, no (channel, cc) key
		H.call(H.callable(b, "SetQLinkFineAdjust"), false)
		-- SetInfiniteCCMagnitude is deliberately never called: no shipped Akai
		-- caller proves its signature
		H.logOnce("qlinkmag", "SetInfiniteCCMagnitude not called (signature unprobed)")
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
	for knob = 0, 15 do
		local cc = REL0 + knob
		-- the (channel, cc) form mapQlinks verified
		H.call(H.callable(b, "RemoveInfiniteCCToQLink"), CH_ANALOG, cc)
		H.call(m and m.AddCCToScript, CH_ANALOG, cc)
		qlinkScriptCC[knob] = nil
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
-- suppress jumps. Called on load and on bank moves; resyncFaders() re-runs it for
-- idle columns once the project turns out to be readable after load (F9).
local function syncFader(col)
	local tr = H.trackForCol(col)
	local v = tonumber(H.prop(tr, "Volume"))
	if v == nil then
		return
	end
	local pos = math.floor(H.clamp01(v) * 127 + 0.5)
	faderRef[col] = pos
	sendCC(CH_ANALOG, FADER0 + col, pos)
	local rec = faderSync[col]
	if rec == nil then
		rec = {}
		faderSync[col] = rec
	end
	rec.pos = pos -- what we sent: resyncFaders() must not duplicate it
end

local function syncAllFaders()
	for col = 0, 7 do
		syncFader(col)
	end
end

-- Arm software pickup: after a bank move the physical fader is wherever the user
-- left it; ignore movement until it reaches or crosses the track's value. Every
-- arm also clears the picked flag (load, bank move, track-count change): the
-- fader must earn the pickup again on the new reference.
local function armPickup(col)
	local tr = H.trackForCol(col)
	local v = tonumber(H.prop(tr, "Volume"))
	local rec = faderSync[col]
	if rec == nil then
		rec = {}
		faderSync[col] = rec
	end
	rec.picked = false
	rec.tick = nil
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

-- F9: at OnLoad the loader may have cached the script before the project exposed
-- track volumes, so the references taken then are absent or wrong and nothing
-- re-synced them until a bank move. While a column is idle AND never picked up,
-- keep following the real volume: arm it when readable, send the position CC
-- only when the reference actually moved. Picked-up columns are never touched
-- (the user is driving them). Wire-silent when nothing changed.
local function resyncFaders()
	for col = 0, 7 do
		local rec = faderSync[col]
		if rec == nil or not rec.picked then
			if rec == nil or rec.tick == nil or (ticks - rec.tick) > H.STEP_QUIET then
				local tr = H.trackForCol(col)
				local v = tonumber(H.prop(tr, "Volume"))
				if v ~= nil then
					local pos = math.floor(H.clamp01(v) * 127 + 0.5)
					if not faderArmed[col] then
						armPickup(col) -- arms and takes faderRef from the same volume
					end
					if pos ~= (rec and rec.pos or nil) then
						sendCC(CH_ANALOG, FADER0 + col, pos)
						faderRef[col] = pos
						if rec == nil then
							rec = {}
							faderSync[col] = rec
						end
						local sent = rec.pos
						rec.pos = pos
						if sent ~= nil then
							-- the journal line that makes F9 quantitative on hardware
							H.logOnce("fadersync" .. (col + 1), string.format(
								"fader %d reference %d -> %d (project readable after load)",
								col + 1, sent, pos))
						end
					end
				end
			end
		end
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

-- Normalised 0..1 readouts for the control-mode row 3 global page. Stepped
-- parameters read through H.cur: a turn paints the ring from the value it
-- just wrote, an idle poll follows the device.
local function globalParamT(col)
	if col == 0 then
		return H.clamp01(((H.cur("bpm", getBpm) or 120) - 60) / 160) -- musical span 60..220
	elseif col == 1 then
		return H.clamp01(((H.cur("swing", H.swingRead) or 50) - 50) / 25)
	elseif col == 2 then
		return H.clamp01(((H.cur("strength", getStrength) or 100) - 0) / 100)
	elseif col == 3 then
		local cur = tostring(H.enumSeen("division") or readDivision() or "")
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
		-- stays as the degrade (not enumerated / scanning / type unreadable)
		if autoFilter.phase ~= "ready" or autoFilter.list == nil then
			return 0.7
		end
		local cur = tostring(H.enumSeen("autofilter") or filterRead() or "")
		if cur ~= "" then
			for i, t in ipairs(autoFilter.list) do
				if t == cur then
					return (i - 1) / math.max(1, #autoFilter.list - 1)
				end
			end
		end
		return 0.7
	elseif col == 7 then
		return H.clamp01(H.cur("master", readMasterVolume) or 0)
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
	-- Row 3 stays the continuous pan readout. Values come through H.cur with
	-- the same keys the steppers write, so a ring follows a turn immediately
	-- (the shadow) and the device when idle (the read lags one change).
	for col = 0, 7 do
		local tr = H.trackForCol(col)
		local live = tr ~= nil and trackHasClips(bank + col)
		local base = live and H.trackColourRGB(tr) or PAL.off
		local idx = H.visibleIdx(col)
		local function curVal(name)
			return H.cur(string.format("send:%d:%d:%s", sendBank, idx, name), function()
				return tonumber(getTrackValue(idx, name))
			end)
		end
		ledSet(encoderTarget(0, col), live and valueScaled(base, curVal(mixerParamFor(0))) or PAL.off)
		ledSet(encoderTarget(1, col), live and valueScaled(base, curVal(mixerParamFor(1))) or PAL.off)
		ledSet(encoderTarget(2, col), live and panPalette(curVal("Pan")) or PAL.off)
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

-- Q-Link gesture engine (the one driver for BOTH encoder paths).
-- A run of detents on one Q-Link is a gesture: the first detent twists
-- immediately (zero-wait first response; __LCXL3_IMMEDIATE = false keeps the
-- all-timer fallback), later detents coalesce into ONE Twist per Q-Link per
-- timer tick. Gain follows the measured turn rate (1..maxMult) instead of the
-- retired per-detent streak ramp (x8 sent a half-turn flick from min to max).
-- Open loop by design: no read-verify-correct Twist and no SetPosition in the
-- normal path -- the device's one-change read lag made the old closed loop
-- double-twist and the ring lag behind. The settle pass re-reads the position
-- once the knob is quiet and REPORTS drift instead of writing. Twist stays
-- dot-form (method form corrupts the Q-Link page on fw 1.1.11); when Twist is
-- missing or errors, the LPP3 SetValue/SetPosition tail survives as the
-- qlinkFallbackSet degrade only.
-- Turn-rate tunables: one table so a device session can retune without
-- hunting through the code. Pre-set __LCXL3_QFEEL before load to override a
-- key; missing keys fall back to these defaults (and survive OnLoad).
__LCXL3_QFEEL = __LCXL3_QFEEL or {}
__LCXL3_QFEEL.gapTicks = __LCXL3_QFEEL.gapTicks or 3 -- detents closer than 150 ms belong to one gesture
__LCXL3_QFEEL.rateTicks = __LCXL3_QFEEL.rateTicks or 3 -- gain is chosen from detents counted in this window
__LCXL3_QFEEL.maxMult = __LCXL3_QFEEL.maxMult or 4 -- ceiling (v1.1.0 ramped to 8: a half-turn flick ran min -> max)
__LCXL3_QFEEL.settleTicks = __LCXL3_QFEEL.settleTicks or 3 -- quiet time before the settle pass re-reads the knob
__LCXL3_QFEEL.absUnitsPerDetent = __LCXL3_QFEEL.absUnitsPerDetent or 1 -- row-1 absolute units per detent (device-unknown; measured by the trace)
__LCXL3_QFEEL.traceGestures = __LCXL3_QFEEL.traceGestures or 40 -- per-gesture journal lines per session, then silent
__LCXL3_IMMEDIATE = (__LCXL3_IMMEDIATE == nil) and true or __LCXL3_IMMEDIATE
__LCXL3_QTRACE = 0 -- bounded per-session gesture-trace counter

-- Per-Q-Link gesture state:
--   pos       shadow position the ring paints (clamped 0..127, re-synced at settle)
--   lastTick  tick of the last detent (gesture boundary + settle timer)
--   events    detents in the current gesture (trace)
--   devDelta  raw device deltas summed this gesture (trace: "dev %+d")
--   sent      total Twist delta queued/sent this gesture (trace + drift log)
--   pending   Twist delta awaiting the per-tick flush
--   startTick/startRead  gesture start tick and shadow start position (trace)
--   recent    detent ticks inside the rate window (gain input)
--   acc       fractional abs units carried between detents (row-1 remainder)
--   name/val  cached target name / value string (the display never blanks)
--   settled   settle pass ran for this gesture
--   clamped   the shadow hit 0 or 127 this gesture (trace suffix)
--   trace     this gesture logs its bounded trace line
--   src       "rel" or "abs" (trace)
local qlinkGest = {}

-- Degrade path (the LPP3 driver tail, kept ONLY for a missing/failing Twist):
-- position-scaled SetValue drives the value, SetPosition syncs the knob
-- display. Never reached from the normal path; logged once per Q-Link so a
-- firmware without a working Twist explains itself in the journal.
local function qlinkFallbackSet(i, target)
	local q = qlinkAt(i)
	if q == nil then
		return
	end
	H.logOnce(
		"qdegrade" .. i,
		string.format("qlink %d: Twist missing or ineffective, SetValue/SetPosition fallback", i)
	)
	target = H.clamp(target or 0, 0, 127)
	local pos = tonumber(H.call(H.callable(q, "GetPosition")))
	if type(q.SetValue) == "function" and pos ~= nil and pos > 0 then
		local v = tonumber(H.call(H.callable(q, "GetValue")))
		if v ~= nil then
			H.call(q.SetValue, v * target / pos)
		end
	end
	if type(q.SetPosition) == "function" then
		H.call(q.SetPosition, target)
	end
end

-- Q-Link panel text with the never-blank rule: the value line comes from the
-- per-QLink cache; a getter that answers ""/nil (read lag, unassigned slot)
-- keeps the previous text and a cold cache shows "-". An empty value line is
-- what made knobs "lose" their value on the screen (finding F2), so no Q-Link
-- display path writes "" any more.
function H.qlinkShow(i)
	local g = qlinkGest[i]
	if g == nil then
		g = {}
		qlinkGest[i] = g
	end
	local v = qlinkValueString(i)
	if v ~= nil and v ~= "" then
		g.val = v
	end
	local nm = qlinkTargetName(i)
	if nm ~= nil and nm ~= "" then
		g.name = nm
	end
	for knob = 0, 15 do
		if qlinkOrderAt(knob + 1) == i then
			showControl(
				encoderTarget(math.floor(knob / 8), knob % 8),
				"Q-Link",
				(g.name ~= nil and g.name ~= "") and g.name or "Unassigned",
				(g.val ~= nil and g.val ~= "") and g.val or "-"
			)
			return
		end
	end
end

-- Ring during a gesture and its settle window: paint the SHADOW (g.pos) with
-- one direct ledSet per detent -- paintAll polls clip emptiness for 8 tracks
-- and must not run per detent. Unassigned Q-Links stay dark (unchanged).
function H.qlinkRing(i)
	local g = qlinkGest[i] or {}
	for knob = 0, 15 do
		if qlinkOrderAt(knob + 1) == i then
			local row = math.floor(knob / 8)
			local col = knob % 8
			local pal = PAL.off
			if g.name ~= nil and g.name ~= "" then
				pal = valueScaled((row == 0) and PAL.turquoise or PAL.purple, (g.pos or 0) / 127)
			end
			ledSet(encoderTarget(row, col), pal)
			return
		end
	end
end

-- Coalesced send: ONE Twist per Q-Link per tick. HandleTimer calls it without
-- an argument (every pending gesture); qlinkDetent calls it with the index for
-- the zero-wait first detent. This bounds the MIDI-context load to <= 20
-- native calls/s per knob instead of per-detent bursts.
local function flushQlinkPending(i)
	local function flushOne(idx)
		local g = qlinkGest[idx]
		local d = g ~= nil and g.pending or 0
		if d == 0 then
			return
		end
		g.pending = 0
		local q = qlinkAt(idx)
		if q == nil then
			return
		end
		if d > 127 then
			d = 127
		elseif d < -127 then
			d = -127
		end
		if type(q.Twist) == "function" and pcall(q.Twist, d) then
			H.qlinkShow(idx) -- per-tick value-line refresh (cached, never blank)
			return
		end
		qlinkFallbackSet(idx, g.pos or 0) -- degrade: Twist missing or errored
		H.qlinkShow(idx)
	end
	if i ~= nil then
		flushOne(i)
		return
	end
	for idx = 0, 15 do
		flushOne(idx)
	end
end

-- The one detent entry point (src = "rel" or "abs"). Computes the rate window,
-- the gain and the clamped shadow step, then either twists now (gesture start,
-- __LCXL3_IMMEDIATE) or queues for the per-tick flush. No GetPosition here:
-- reads lag one change and were the heart of the double-twist bug.
local function qlinkDetent(i, rawDelta, src)
	local q = qlinkAt(i)
	if q == nil or rawDelta == 0 then
		return
	end
	local feel = __LCXL3_QFEEL
	local g = qlinkGest[i]
	if g == nil then
		g = {}
		qlinkGest[i] = g
	end
	if g.lastTick == nil or (ticks - g.lastTick) > feel.gapTicks then
		-- gesture start: seed the shadow from the device (reads have settled
		-- while idle; the previous shadow survives a failed read), cache the
		-- name, one Touch, bounded trace slot, then this detent applies below.
		local nm = qlinkTargetName(i)
		if nm ~= nil and nm ~= "" then
			g.name = nm
		end
		local pos = tonumber(H.call(H.callable(q, "GetPosition")))
		if pos ~= nil then
			g.pos = H.clamp(pos, 0, 127)
		elseif g.pos == nil then
			g.pos = 64 -- no read and no shadow: start mid-range
		end
		g.startRead = g.pos
		g.startTick = ticks
		g.src = src
		g.events = 0
		g.devDelta = 0
		g.sent = 0
		g.pending = 0
		g.recent = nil
		g.clamped = false
		g.trace = __LCXL3_QTRACE < feel.traceGestures
		if g.trace then
			__LCXL3_QTRACE = __LCXL3_QTRACE + 1
		end
		H.call(H.callable(q, "Touch"))
	end
	g.lastTick = ticks
	-- every detent re-arms the settle pass: a detent inside gapTicks joins a
	-- gesture the timer may already have settled, and its tail detents must
	-- still get the quiet-time drift check, the closing Touch and the final
	-- display/ring sync
	g.settled = false
	-- rate window: detents on this Q-Link within rateTicks ticks (incl. this one)
	local recent = {}
	for _, t in ipairs(g.recent or {}) do
		if (ticks - t) <= feel.rateTicks then
			recent[#recent + 1] = t
		end
	end
	recent[#recent + 1] = ticks
	g.recent = recent
	g.events = (g.events or 0) + 1
	g.devDelta = (g.devDelta or 0) + rawDelta
	-- device units -> detents: the absolute stream counts absUnitsPerDetent
	-- units per detent, the fractional remainder carried in acc so slow row-1
	-- turns lose no distance. A single event of >= 2 detents is speed the
	-- device already encoded: use that magnitude (capped) at gain 1.
	local unit = (src == "abs") and (feel.absUnitsPerDetent or 1) or 1
	g.acc = (g.acc or 0) + rawDelta / (unit ~= 0 and unit or 1)
	local dets = 0
	if g.acc >= 1 then
		dets = math.floor(g.acc)
	elseif g.acc <= -1 then
		dets = math.ceil(g.acc)
	end
	if dets ~= 0 then
		g.acc = g.acc - dets
	end
	local step = 0
	if dets >= 2 or dets <= -2 then
		step = H.clamp(dets, -feel.maxMult, feel.maxMult)
	elseif dets ~= 0 then
		local n = #recent
		local gain = 1
		if n > 2 and n <= 4 then
			gain = 2
		elseif n > 4 and n <= 7 then
			gain = 3
		elseif n > 7 then
			gain = feel.maxMult
		end
		step = dets * gain
	end
	if step ~= 0 then
		local np = H.clamp((g.pos or 0) + step, 0, 127) -- ceiling: only the fitting part is sent
		if np ~= (g.pos or 0) + step then
			g.clamped = true
		end
		step = np - (g.pos or 0)
		if step ~= 0 then
			g.pos = np
			g.sent = (g.sent or 0) + step
			g.pending = (g.pending or 0) + step
			H.qlinkRing(i) -- the ring tracks the shadow immediately, per detent
		end
	end
	if g.events == 1 then
		H.qlinkShow(i) -- the panel names the target from the first detent on
		if __LCXL3_IMMEDIATE then
			flushQlinkPending(i) -- zero-wait first response
		end
	end
end


-- Settle pass (replaces the old SetPosition ring sync): once the knob has
-- been quiet for settleTicks, re-read the position ONCE. A >= 2-position gap
-- between the shadow and the device is logged once per Q-Link per session --
-- the diagnostic that separates a real device-side drop from a wrong Twist
-- unit. The shadow adopts the device value, the display/ring refresh, one
-- Touch closes the gesture, the first traceGestures gestures leave a bounded
-- trace line. No parameter write, no SetPosition, ever.
local function settleQlink(i)
	local g = qlinkGest[i]
	if g == nil or g.settled then
		return
	end
	g.settled = true
	g.recent = nil
	local q = qlinkAt(i)
	if q == nil then
		return
	end
	local dev = tonumber(H.call(H.callable(q, "GetPosition")))
	if dev ~= nil then
		dev = H.clamp(dev, 0, 127)
		if math.abs(dev - (g.pos or dev)) >= 2 then
			H.logOnce(
				"qdrift" .. i,
				string.format(
					"qlink %d drift: expected %d, device %d (sent %+d over %d detents)",
					i,
					g.pos or 0,
					dev,
					g.sent or 0,
					g.events or 0
				)
			)
		end
		g.pos = dev
	end
	local v = qlinkValueString(i)
	if v ~= nil and v ~= "" then
		g.val = v
	end
	local nm = qlinkTargetName(i)
	if nm ~= nil and nm ~= "" then
		g.name = nm
	end
	H.call(H.callable(q, "Touch"))
	if g.trace then
		H.log(
			string.format(
				"qlink %d [%s]: %d detents in %d ticks (%s), dev %+d, sent %+d, pos %d->%d%s, val %s",
				i,
				tostring((g.name ~= nil and g.name ~= "") and g.name or "-"),
				g.events or 0,
				(g.lastTick or ticks) - (g.startTick or ticks) + 1,
				g.src or "rel",
				g.devDelta or 0,
				g.sent or 0,
				g.startRead or 0,
				g.pos or 0,
				g.clamped and " clamped" or "",
				tostring((g.val ~= nil and g.val ~= "") and g.val or "-")
			)
		)
		g.trace = false
	end
	-- reset the gesture counters; pos/name/val/acc survive for the display
	g.events = 0
	g.devDelta = 0
	g.sent = 0
	g.pending = 0
	g.clamped = false
	H.qlinkRing(i)
	H.qlinkShow(i)
end

local function paintControlEncoders()
	local n = qlinkCount()
	for knob = 0, 15 do
		local row = math.floor(knob / 8)
		local col = knob % 8
		local i = qlinkIndexOfKnob(row, col) -- column-major order (QLINK_ORDER)
		local pal = PAL.off
		if i < n then
			local nm = qlinkTargetName(i)
			if nm == nil or nm == "" then
				-- an unassigned Q-Link (nil OR empty-string name on fw 1.1.11)
				-- cannot be labelled: the ring stays dark and the journal
				-- explains it once (the input path still drives it)
				H.logOnce("qlinkname" .. i, "qlink " .. i .. " has no target name: ring dark")
			else
				-- Q-Link rows: hue marks the row, brightness follows the value.
				-- While a gesture (or its settle window) is live, paint the
				-- shadow: the device GetValue lags one change and would drag
				-- the ring backwards mid-turn.
				local g = qlinkGest[i]
				local t
				if g ~= nil and g.lastTick ~= nil and not g.settled then
					t = (g.pos or 0) / 127
				else
					t = qlinkValue(i)
				end
				pal = valueScaled((row == 0) and PAL.turquoise or PAL.purple, t)
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
			pal = panPalette(H.cur(string.format("tp:%d:%s", cur, "Pan"), function()
				return tonumber(getTrackValue(cur, "Pan"))
			end))
		elseif col <= 5 then
			local name = TRACK_PAGE_PARAMS[col + 1]
			pal = valueScaled(TRACK_PAGE_COLOURS[col + 1], H.cur(string.format("tp:%d:%s", cur, name), function()
				return tonumber(getTrackValue(cur, name))
			end))
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
	armAllPickup() -- also resets the picked flags of the new window
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
	lastAbs = {} -- fresh abs baselines + stream locks on ANY mode change: a
	-- stale baseline (e.g. absorbed during control mode) makes the first mixer
	-- turn JUMP, and a stale latch would swallow the other stream
	if m == MODE_CONTROL then
		mapQlinks()
		logQlinkInventory()
		H.qlinkSetIsGlobal() -- fresh order detection on (re)entry
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
	local rec = faderSync[col]
	if rec == nil then
		rec = {}
		faderSync[col] = rec
	end
	rec.tick = ticks -- any message (even a swallowed one) holds resyncFaders() off
	if not rec.picked and not faderArmed[col] then
		-- audit M1: a volume unreadable at load left the column disarmed and the
		-- next message jumped the track blindly. Arm if the volume is readable
		-- now; while it is not, never write.
		armPickup(col)
		if not faderArmed[col] then
			return
		end
	end
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
	rec.picked = true -- accepted: the user owns this fader until the next arm
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
	-- shadow-stepped: under the device's read lag, read + delta stalls (12 CW
	-- detents landed ~3 steps); the shadow applies exactly one step per detent
	local v = H.stepped(
		string.format("send:%d:%d:%s", sendBank, idx, name),
		function()
			return tonumber(getTrackValue(idx, name))
		end,
		function(nv)
			return setTrackValue(idx, name, nv)
		end,
		delta * step,
		0,
		1
	)
	if v == nil then
		return -- nothing written (unreadable or refused): the logOnce explains it
	end
	showControl(
		encoderTarget(row, col),
		H.prop(tr, "Name") or ("Track " .. idx + 1),
		displayName(name),
		(name == "Pan") and H.fmtPan(v) or H.fmtPercent(v)
	)
	if name == "Pan" then
		ledSet(encoderTarget(row, col), panPalette(v))
	end
end

-- Row-3 control display (control mode, global and track pages), shared by
-- the detent handlers and the idle refresh: values come through H.cur (and
-- H.enumSeen), so a turn shows the value it just wrote and an idle refresh
-- follows the device. boolHint (metronome/loop) lets a turn name the state
-- the direction asked for before a lagging read would.
local function showRow3(col, boolHint)
	local target = encoderTarget(2, col)
	if controlPage ~= 0 then
		local cur = H.currentTrackIndex()
		local tr = H.trackAt(cur)
		if tr == nil then
			return
		end
		local name = TRACK_PAGE_PARAMS[col + 1]
		if name == nil then
			return
		end
		local v = H.cur(string.format("tp:%d:%s", cur, name), function()
			return tonumber(getTrackValue(cur, name))
		end)
		local valueText
		if name == "Volume" then
			valueText = H.gainToDb(v)
		elseif name == "Pan" then
			valueText = H.fmtPan(v)
		else
			valueText = H.fmtPercent(v)
		end
		showControl(target, H.prop(tr, "Name") or ("Track " .. cur + 1), name, valueText)
		return
	end
	if col == 0 then
		showControl(target, "Global", "Tempo", string.format("%.1f", H.cur("bpm", getBpm) or 0))
	elseif col == 1 then
		local pct = H.cur("swing", H.swingRead) or 50
		showControl(target, "Global", "Swing", math.floor(pct + 0.5) .. "%")
	elseif col == 2 then
		local v = H.cur("strength", getStrength) or 100
		showControl(target, "Global", "Q Strength", math.floor(v + 0.5) .. "%")
	elseif col == 3 then
		showControl(target, "Global", "Q Division", tostring(H.enumSeen("division") or readDivision() or "-"))
	elseif col == 4 then
		local on = boolHint
		if on == nil then
			on = H.truthy(H.prop(mpc.sequencer, "MetronomeEnabled"))
		end
		showControl(target, "Global", "Metronome", on and "On" or "Off")
	elseif col == 5 then
		local on = boolHint
		if on == nil then
			on = H.truthy(H.prop(mpc.sequencer, "Loop"))
		end
		showControl(target, "Global", "Loop", on and "On" or "Off")
	elseif col == 6 then
		local text
		if autoFilter.phase == "scan" then
			text = "scanning"
		else
			text = tostring(H.enumSeen("autofilter") or filterRead() or "cycle")
		end
		showControl(target, "Global", "Auto Filter", text)
	elseif col == 7 then
		showControl(target, "Master", "Volume", H.gainToDb(H.cur("master", readMasterVolume) or 0))
	end
end

local function handleGlobalEncoder(col, delta)
	if col == 0 then
		-- sign-only: a big absolute-path delta must not jump the tempo
		H.stepped("bpm", getBpm, setBpm, H.clamp(delta, -1, 1), 20, 500)
		showRow3(col)
	elseif col == 1 then
		-- sign-only +-1 percent per detent (the per-detent clamp kept); the
		-- shadow lives in H.step["swing"] and re-syncs after a quiet gap, so a
		-- stale ceiling can no longer pin the knob at 75
		H.stepped("swing", H.swingRead, swingWrite, H.clamp(delta, -1, 1), 50, 75)
		showRow3(col)
	elseif col == 2 then
		H.stepped("strength", getStrength, setStrength, H.clamp(delta, -1, 1), 0, 100)
		showRow3(col)
	elseif col == 3 then
		H.enumStep("division", delta, {
			list = function()
				return TIME_DIVISIONS
			end,
			read = readDivision,
			write = function(v)
				H.call(H.callable(quantiser(), "SetTimeDivision"), v)
				return true
			end,
			perStep = 2, -- one list step per two detents (the "too quick" fix)
		})
		showRow3(col)
	elseif col == 4 then
		local want = delta > 0
		H.setWanted("metro", want, function()
			return H.prop(mpc.sequencer, "MetronomeEnabled")
		end, function(w)
			local setter = H.callable(mpc.sequencer, "SetMetronomeEnabled")
			if setter then
				H.call(setter, w)
			else
				pcall(function()
					mpc.sequencer.MetronomeEnabled.value = w
				end)
			end
		end)
		showRow3(col, want)
	elseif col == 5 then
		local want = delta > 0
		H.setWanted("loop", want, function()
			return H.prop(mpc.sequencer, "Loop")
		end, function(w)
			local setter = H.callable(mpc.sequencer, "SetLoop")
			if setter then
				H.call(setter, w)
			else
				pcall(function()
					mpc.sequencer.Loop.value = w
				end)
			end
		end)
		showRow3(col, want)
	elseif col == 6 then
		filterDetent(delta)
		showRow3(col)
	elseif col == 7 then
		H.stepped("master", readMasterVolume, writeMasterVolume, delta / 127, 0, 1)
		showRow3(col)
	end
	markDirty()
end

local function handleTrackPageEncoder(col, delta)
	local cur = H.currentTrackIndex()
	local tr = H.trackAt(cur)
	if tr == nil then
		return
	end
	local name = TRACK_PAGE_PARAMS[col + 1]
	if name == nil then
		return
	end
	local step = (name == "Volume") and (1 / 127) or (1 / 96)
	H.stepped(
		string.format("tp:%d:%s", cur, name),
		function()
			return tonumber(getTrackValue(cur, name))
		end,
		function(nv)
			return setTrackValue(cur, name, nv)
		end,
		delta * step,
		0,
		1
	)
	showRow3(col)
end

local function handleControlEncoder(row, col, delta)
	lastTouched = { kind = "encoder", row = row, col = col }
	if row < 2 then
		if qlinkRouted and not qlinkScriptCC[row * 8 + col] then
			return -- the MPC owns these CCs; nothing reaches the script
		end
		local i = qlinkIndexOfKnob(row, col)
		if qlinkAt(i) == nil then
			return -- no Q-Link object behind this knob
		end
		-- Twist even when the target has no name: the name gate lives only in
		-- the LED painter (which logs the dark ring); the display falls back
		-- to "Unassigned". One gesture engine for both paths (see qlinkDetent).
		qlinkDetent(i, delta, "rel")
		return
	end
	if controlPage == 0 then
		handleGlobalEncoder(col, delta)
	else
		handleTrackPageEncoder(col, delta)
	end
end

local function handleEncoderRel(row, col, delta)
	local knob = row * 8 + col
	-- Stream lock (finding F13): a row emitting BOTH abs and rel streams would
	-- double-step every detent. Latch the first stream that produces an
	-- actionable event and ignore the other until the latch is cleared (where
	-- lastAbs is cleared: mode change, OnLoad). lastAbs keys 100+knob hold the
	-- lock; 0..23 stay the abs baselines (no extra local: the 200-local cap).
	if lastAbs[100 + knob] == "abs" then
		H.logOnce(
			"enclock" .. knob,
			string.format("encoder r%dc%d: rel stream ignored (abs locked)", row + 1, col + 1)
		)
		return
	end
	lastAbs[100 + knob] = "rel"
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
-- absorbed as the baseline (no action), a cross-seam jump is a 7-bit wrap
-- (small delta), a value exactly half a revolution away is ambiguous
-- (re-baseline only), and every other value nudges like the relative path --
-- nothing is ever direct-written as value/127 again. The per-knob stream lock
-- ignores a second stream that would double-step (see handleEncoderRel).
local function handleEncoderAbs(row, col, value)
	local knob = row * 8 + col -- PHYSICAL knob key for the lastAbs baseline cache
	local last = lastAbs[knob]
	lastAbs[knob] = value
	if last == nil then
		return -- first sighting: absorb as the baseline, no action
	end
	local delta = value - last
	-- 7-bit absolute encoders wrap once per revolution: treat the jump over
	-- the 0/127 seam as a small delta instead of a spike (the old |delta|>32
	-- spike rule ate every real fast turn as well).
	if delta == 64 or delta == -64 then
		return -- exactly half a revolution: ambiguous direction, re-baseline only
	end
	if delta > 64 then
		delta = delta - 128
	elseif delta < -64 then
		delta = delta + 128
	end
	if delta == 0 then
		return
	end
	if lastAbs[100 + knob] == "rel" then
		H.logOnce(
			"enclock" .. knob,
			string.format("encoder r%dc%d: abs stream ignored (rel locked)", row + 1, col + 1)
		)
		return
	end
	lastAbs[100 + knob] = "abs" -- latch: this knob speaks absolute until a mode change
	lastTouched = { kind = "encoder", row = row, col = col } -- F12: the abs path sets it too
	if surfaceMode == MODE_CONTROL then
		if row < 2 then
			if qlinkRouted and not qlinkScriptCC[row * 8 + col] then
				return -- the MPC owns the rel CCs; abs must not double-step
			end
			qlinkDetent(qlinkIndexOfKnob(row, col), delta, "abs")
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
			H.qlinkShow(qlinkIndexOfKnob(row, col)) -- cached text: never blank
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
	if surfaceMode == MODE_CONTROL then
		if lt.row < 2 then
			H.qlinkShow(qlinkIndexOfKnob(lt.row, lt.col)) -- cached text: never blank
		else
			showRow3(lt.col) -- row 3: the shadow covers a fresh turn, the device when idle
		end
		return
	end
	if surfaceMode == MODE_MIXER then
		local tr = H.trackForCol(lt.col)
		if tr ~= nil then
			local name = mixerParamFor(lt.row)
			local idx = H.visibleIdx(lt.col)
			-- displays read through H.cur (the same key handleMixerEncoder steps
			-- under): a mid-turn 500 ms refresh shows the written value, not a
			-- lagged read
			local v = H.cur(string.format("send:%d:%d:%s", sendBank, idx, name), function()
				return tonumber(getTrackValue(idx, name))
			end) or 0
			showControl(encoderTarget(lt.row, lt.col), H.prop(tr, "Name") or "-", displayName(name), (name == "Pan") and H.fmtPan(v) or H.fmtPercent(v))
		end
	end
end

function LaunchControlXL3.HandleTimer()
	ticks = ticks + 1
	flushQlinkPending() -- coalesced twists: ONE per Q-Link per tick
	filterTick() -- automation-filter scan polling (asynchronous, lag-proof)
	if H.odVerify ~= nil and ticks >= H.odVerify then
		-- T4 clean-path drop check: if the plain od-off toggle stopped playback,
		-- resume once, log once and latch the guard (later presses then take the
		-- proven guarded path for the rest of the session).
		H.odVerify = nil
		if not isPlaying() then
			H.call(H.callable(mpc.sequencer, "Play"))
			__LCXL3_OD_GUARD = true
			H.logOnce("odclean-stop", "overdub: clean toggle stopped playback; resumed and latched __LCXL3_OD_GUARD")
		end
	end
	if H.odAfter ~= nil and ticks >= H.odAfter then
		H.odAfter = nil
		H.odState("after ") -- F10 journal: post-toggle transport numbers
	end
	for i, g in pairs(qlinkGest) do
		if
			(g.pending or 0) == 0
			and g.lastTick ~= nil
			and not g.settled
			and (ticks - g.lastTick) >= __LCXL3_QFEEL.settleTicks
		then
			settleQlink(i) -- quiet-time re-read: drift report + display/ring sync
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
		-- re-detect which Q-Link set is loaded (a GLOBAL page must switch the
		-- knob order to identity): 3 name reads, no wire traffic
		if surfaceMode == MODE_CONTROL then
			H.qlinkSetIsGlobal()
		end
		-- Q-Link names are often unreadable at OnLoad (the project is still
		-- loading). Retry the index -> name inventory here once the project is
		-- live: it is the ground truth for checking the knob order on screen.
		if not H.qlinkInvDone and qlinkCount() > 0 then
			local inv = {}
			local any = false
			for i = 0, math.min(qlinkCount(), 16) - 1 do
				local nm = tostring(qlinkTargetName(i) or "")
				if nm ~= "" then
					any = true
				end
				inv[#inv + 1] = string.format("%d='%s'", i, nm:sub(1, 14))
			end
			if any then
				H.qlinkInvDone = true
				H.log("qlinks inv: " .. table.concat(inv, " "))
			end
		end
	end
	if ticks % 40 == 0 then
		-- clip emptiness has no listener: re-evaluate every ~2 s. The caches
		-- keep this wire-silent unless something actually changed.
		markDirty()
		local n = H.trackCount()
		if n ~= loggedTrackCount then
			loggedTrackCount = n
			learnTrackOffset()
			-- project loaded late / real track-count change: fresh pickup state
			-- (armPickup clears the picked flags), resyncFaders() below then
			-- re-references the idle columns. Gated on H.faderSyncCount because
			-- loggedTrackCount starts at -1: the first window tick is not a change.
			if H.faderSyncCount ~= n then
				H.faderSyncCount = n
				armAllPickup()
			end
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
		resyncFaders() -- F9: idle, never-picked-up columns follow the readable project
	end
	if ticks % 4 == 0 and surfaceMode == MODE_CONTROL then
		-- Q-Link/global values are hardware-routed: no listeners, so poll
		-- every 200 ms in control mode (again wire-silent thanks to caches).
		markDirty()
	end
	if ticks == 20 and loaded then
		-- re-ask once the device has had a second to settle after the handshake
		sendCC(CH_QUERY, FEAT.mode, MODE_MIXER)
		resyncFaders() -- F9: first re-reference once the project had a second to settle
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
	faderSync = {} -- pickup records (sent pos / picked / last msg tick): a new
	-- session must not inherit a previous session's references
	lastAbs = {} -- absolute-encoder baselines AND per-knob stream locks:
	-- first sighting per control is absorbed; a stale baseline (or a stale
	-- stream latch, e.g. absorbed during control mode) would jump the first
	-- mixer turn or swallow the other stream
	autoFilter = { phase = "idle", list = nil, t0 = nil, polls = 0 } -- filter enum: re-scan on the first turn
	H.step = {} -- shadow values: a new session must not trust pre-reload writes
	H.want = {} -- metronome/loop wanted-state requests
	H.enum = {} -- enumerated-parameter steppers (division, automation filter)
	H.swingUnit = nil -- swing unit auto-detection re-runs per session
	screenReassert = {} -- post-burst re-assert set: nothing pending on a fresh load
	qlinkGest = {} -- P1-2/P2-1/P2-2 folded: pre-reload gestures, shadows and
	-- pending detents never leak into a new session (ticks reset to 0).
	-- __LCXL3_QFEEL keeps owner tunings across reloads by design.
	__LCXL3_OD_CLEAN = false -- T4: the opt-in re-arms explicitly after each load
	__LCXL3_OD_GUARD = false -- T4: the clean-path latch is per-session
	H.odAfter = nil -- F10 journal watches die with the session
	H.odVerify = nil
	__LCXL3_QTRACE = 0 -- the bounded gesture-trace budget restarts per session
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
	H.faderSyncCount = H.trackCount() -- %40 arm/resync only on a real count change

	loaded = true
	paintAll()
	pumpScreen()
	H.call(dev.timer and dev.timer.Start, 50)
	H.log("loaded")
	-- owner-visible order proof: the ACTIVE Q-Link knob order (QLINK_ORDER,
	-- column-major, for TRACK/plugin pages; H.qlinkOrderGlobal identity when the
	-- GLOBAL page set is loaded, see H.qlinkSetIsGlobal). Both numberings,
	-- because the journal traces are 0-based indices while the MPC screen
	-- numbers its Q-Links 1-16.
	local mapOrder = H.qlinkGlobalSet and H.qlinkOrderGlobal or QLINK_ORDER
	local screen1, screen2 = {}, {}
	for k = 1, 8 do
		screen1[k] = tostring(mapOrder[k] + 1)
	end
	for k = 9, 16 do
		screen2[k - 8] = tostring(mapOrder[k] + 1)
	end
	H.log(
		"qlink map: "
			.. (H.qlinkGlobalSet and "global" or "track")
			.. " index row1 ["
			.. table.concat(mapOrder, ",", 1, 8)
			.. "] row2 ["
			.. table.concat(mapOrder, ",", 9, 16)
			.. "] | screen Q-Link numbers row1 ["
			.. table.concat(screen1, ",")
			.. "] row2 ["
			.. table.concat(screen2, ",")
			.. "]"
	)
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
