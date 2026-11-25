-- tests/mock-mpc.lua: a minimal MPC 3.10.1 API mock for the Launch Control XL 3 script.
-- Records every call; decodes LED RGB sysex into M.leds[cc] = "r,g,b".
-- Optional read lag (device fact: Q-Link getters and mixer/quantiser/BPM/filter reads
-- report one change behind): mock.setReadLag(n), advanced by mock.tick(L) / mock.runTicks(L, n).

local M = { calls = {}, leds = {}, notes = {}, sysex = {}, scriptCCs = {}, qlinkMapped = {} }

local function record(name, ...)
	M.calls[#M.calls + 1] = { name = name, args = { ... } }
end
M.record = record

function M.find(name)
	local out = {}
	for _, c in ipairs(M.calls) do
		if c.name == name then
			out[#out + 1] = c
		end
	end
	return out
end

function M.count(name)
	return #M.find(name)
end

-----------------------------------------------------------------------------------------------
-- Read lag (device fact: property reads and the Q-Link getters report one change behind).
-- Default OFF: with lag 0 every read is instantaneous, which is the world the whole
-- existing suite assumes. mock.setReadLag(n) arms an n-tick delay: a write made at tick t
-- reaches readers at tick t + n. The lag clock advances only in mock.tick / mock.runTicks
-- -- a bare L.HandleTimer() does not move it, so old tests keep their exact behaviour.
-----------------------------------------------------------------------------------------------
local lagN = 0
local lagClock = 0
local lagReg = {} -- [owner table] = { [field] = { real = fn, visible = v, queue = {...} } }
local twistNoEffect = false -- setTwistNoEffect(true): Twist lands, nothing moves
local volUnreadable = false -- setVolumesUnreadable(true): track Volume reads return nil
local odToggleStopsPlayback = false -- T4: Overdub() od-off also stops playback (F10 defect)
-- (the F9 world: the loader cached the script before the project was readable)

local function lagSeal(owner, field, realGet)
	local o = lagReg[owner]
	if not o then
		o = {}
		lagReg[owner] = o
	end
	local e = o[field]
	if not e then
		e = { real = realGet, visible = realGet(), queue = {} }
		o[field] = e
	end
	return e
end

-- Record a write to a lagged observable. Call BEFORE mutating device truth: the entry
-- seeds its visible view with the pre-write value and, with a lag armed, the new value
-- reaches readers only after lagN ticks.
local function lagStage(owner, field, realGet, newValue)
	local e = lagSeal(owner, field, realGet)
	if lagN > 0 then
		e.queue[#e.queue + 1] = { due = lagClock + lagN, value = newValue }
	end
end

local function lagView(owner, field, realGet)
	if lagN <= 0 then
		return realGet()
	end
	local o = lagReg[owner]
	local e = o and o[field]
	if not e then
		return realGet()
	end
	return e.visible
end

-- Clear the lag model: drop pending writes and re-sync every visible view with truth
-- (used by setReadLag and reset).
local function lagReseed()
	lagClock = 0
	for _, o in pairs(lagReg) do
		for _, e in pairs(o) do
			e.visible = e.real()
			e.queue = {}
		end
	end
end

function M.setReadLag(n)
	lagN = math.max(0, math.floor(tonumber(n) or 0))
	lagReseed()
end

-- Hostile native-mapping host: AddInfiniteCCToQLink accepts anything and stores
-- nothing -- the mis-bind case the script's query-flip verification must detect.
function M.setNativeMappingHostile(v)
	M.nativeMappingHostile = v == true
end

function M.readLag()
	return lagN
end

function M.setVolumesUnreadable(b)
	volUnreadable = not not b
end

-- T4 (F10): arm the device-observed defect where Overdub() turning overdub off
-- also STOPS playback (only while overdub-only: a guard-armed full record holds).
-- Default off — the defect is modelled only when a test asks for it.
function M.setOverdubToggleStopsPlayback(b)
	odToggleStopsPlayback = not not b
end

local function lagAdvance()
	lagClock = lagClock + 1
	if lagN <= 0 then
		return
	end
	for _, o in pairs(lagReg) do
		for _, e in pairs(o) do
			while e.queue[1] and e.queue[1].due <= lagClock do
				e.visible = e.queue[1].value
				table.remove(e.queue, 1)
			end
		end
	end
end

-- dev.timer.Now() backing clock: one tick is the script's 50 ms timer interval
-- (dev.timer.Start(50)); mock.advanceMs adds extra ms for tests.
local now = 0

-- One timer tick: advance the lag clock and the device clock, then run the script timer.
function M.tick(L)
	lagAdvance()
	now = now + 50
	L.HandleTimer()
end

function M.runTicks(L, n)
	for _ = 1, (n or 0) do
		M.tick(L)
	end
end

function M.advanceMs(ms)
	now = now + (ms or 0)
end

function M.reset()
	M.calls = {}
	M.leds = {}
	M.notes = {}
	M.sysex = {}
	M.qlinkMapped = {} -- audit 2 M4: bindings must not leak across tests
	M.nativeMappingHostile = false
	twistNoEffect = false
	volUnreadable = false
	odToggleStopsPlayback = false
	lagReseed()
end

function M.clearCalls()
	M.calls = {}
end

function M.clearSysex()
	M.sysex = {}
end

local function prop(v)
	local p = { value = v, listeners = {} }
	function p:listen(fn, _name)
		record("listen")
		self.listeners[#self.listeners + 1] = fn
	end
	function p:stopListening(_name)
		record("stopListening")
		self.listeners = {}
	end
	function p:set(v)
		self.value = v
		for _, fn in ipairs(self.listeners) do
			pcall(fn, v)
		end
	end
	return p
end
M.prop = prop

-- A read-lagged property (Volume/Pan/Send1..4/project.BPM): :set keeps prop()'s exact
-- write semantics (device value moves, listeners fire immediately) and direct .value
-- writes (the script writes mixer/BPM props that way) keep their no-listener semantics
-- -- but while a read lag is armed the .value read returns the delayed view.
local function laggedProp(v, isVolume)
	local p = prop(v)
	local real = v
	local realGet = function()
		return real
	end
	p.value = nil -- reads must reach the metatable's lagged view
	function p:set(v2)
		lagStage(p, "value", realGet, v2)
		real = v2
		for _, fn in ipairs(p.listeners) do
			pcall(fn, v2)
		end
	end
	setmetatable(p, {
		__index = function(t, k)
			if k == "value" then
				if volUnreadable and isVolume then
					return nil -- device truth exists; it is just not readable right now
				end
				return lagView(t, "value", realGet)
			end
			return nil
		end,
		__newindex = function(t, k, v2)
			if k == "value" then
				lagStage(t, "value", realGet, v2)
				real = v2
				return
			end
			rawset(t, k, v2)
		end,
	})
	return p
end

-----------------------------------------------------------------------------------------------
-- mpc.*
-----------------------------------------------------------------------------------------------

local NUM_TRACKS = 16
local tracks = {}
for i = 0, NUM_TRACKS - 1 do
	-- Volume/Pan/Send1..4 are read-lagged observables (device reads report one change
	-- behind); the flags and metadata stay plain instant props.
	local t = {
		Volume = laggedProp(0.7, true),
		Pan = laggedProp(0.5),
		Send1 = laggedProp(0),
		Send2 = laggedProp(0),
		Send3 = laggedProp(0),
		Send4 = laggedProp(0),
		Mute = prop(false),
		Solo = prop(false),
		RecArm = prop(false),
		Colour = prop(0x00FF00),
		Name = prop("Track " .. i),
	}
	function t.SetMute(v)
		record("SetMute", i, v)
		t.Mute:set(v and true or false)
	end
	function t.SetSolo(v)
		record("SetSolo", i, v)
		t.Solo:set(v and true or false)
	end
	function t.SetRecArm(v)
		record("SetRecArm", i, v)
		t.RecArm:set(v and true or false)
	end
	tracks[i] = t
end
M.tracks = tracks

local currentTrack = { Index = prop(0), Name = prop("Track 0"), Type = prop("Audio") }
M.currentTrack = currentTrack

local mockBpm = 120
-- Swing units (triage H2 favoured, probe 6 pending): the API speaks PERCENT
-- (50..75). A one-line flip of SWING_IS_FRACTION switches the wire form to
-- 0..1 if the probe shows H3 (Set expects a fraction).
local SWING_IS_FRACTION = false
local SWING_STALE = false -- GetSwing never moves (device lag emulation)
local mockSwing = 54 -- percent; divided by 100 on the wire when SWING_IS_FRACTION
local mockStrength = 90
local mockDivision = "1/16"
local mockPulses = 0 -- playhead position, 960 pulses per quarter

-- Owner table for the closure-backed scalars' lag cells (the real storage is a local
-- upvalue, so the lag model keys the cell off this table instead).
local scalarLag = {}
local function getBpmRaw()
	return mockBpm
end
local function getSwingRaw()
	return mockSwing
end
local function getStrengthRaw()
	return mockStrength
end
local function getDivisionRaw()
	return mockDivision
end

local sequencer -- declared first: the closures below must capture the local, not a global
sequencer = {
	Play = function()
		record("Play")
		sequencer.Playing:set(true)
	end,
	TogglePlay = function()
		record("TogglePlay")
		sequencer.Playing:set(not sequencer.Playing.value)
	end,
	Stop = function()
		record("Stop")
		sequencer.Playing:set(false)
	end,
	Record = function()
		record("Record")
		sequencer.RecordState:set(1)
	end,
	RecordOff = function()
		record("RecordOff")
		sequencer.RecordState:set(0)
		-- device-observed (w1/r1): with overdub-only raised, RecordOff also
		-- STOPS playback; disarming a full record does not.
		if sequencer.OverdubState.value ~= 0 and sequencer.Playing.value then
			sequencer.Playing:set(false)
		end
	end,
	Overdub = function()
		record("Overdub")
		if sequencer.OverdubState.value ~= 0 then
			-- the real overdub key toggles: with overdub already raised, Overdub()
			-- drops it (the v1.1.0 guard exists exactly for that transition)
			sequencer.OverdubState:set(0)
			-- device-observed (w1/r1): dropping overdub-only while playing stops
			-- playback. Modelled only when a test arms the switch; a guard-armed
			-- full record (RecordState raised by Record() before the toggle) holds.
			if
				odToggleStopsPlayback
				and sequencer.RecordState.value == 0
				and sequencer.Playing.value
			then
				sequencer.Playing:set(false)
			end
		else
			sequencer.OverdubState:set(1)
			sequencer.RecordState:set(1) -- device-observed: overdub-only raises recordActive()
		end
	end,
	JumpToBeginning = function()
		record("JumpToBeginning")
		mockPulses = 0
	end,
	BarForward = function(n)
		record("BarForward", n)
		mockPulses = mockPulses + 3840 * (n or 1)
	end,
	BarBack = function(n)
		record("BarBack", n)
		mockPulses = math.max(0, mockPulses - 3840 * (n or 1))
	end,
	PlayheadPosition = function()
		return mockPulses
	end,
	IsPlaying = function()
		return sequencer.Playing.value == true
	end,
	IsRecording = function()
		return sequencer.RecordState.value ~= 0
	end,
	Playing = prop(false),
	RecordState = prop(0),
	OverdubState = prop(0),
	Loop = prop(false),
	MetronomeEnabled = prop(false),
	SetMetronomeEnabled = function(v)
		record("SetMetronomeEnabled", v)
		sequencer.MetronomeEnabled:set(v and true or false)
	end,
	SetLoop = function(v)
		record("SetLoop", v)
		sequencer.Loop:set(v and true or false)
	end,
	SetBPM = function(bpm)
		record("SetBPM", bpm)
		lagStage(scalarLag, "bpm", getBpmRaw, bpm)
		mockBpm = bpm
	end,
	GetBPM = function()
		return lagView(scalarLag, "bpm", getBpmRaw)
	end,
	quantiser = {
		Enabled = prop(true),
		GetSwing = function()
			if SWING_STALE then
				return 50 -- device emulation: the read lags every change (stuck-75 bug)
			end
			local raw = lagView(scalarLag, "swing", getSwingRaw)
			if SWING_IS_FRACTION then
				return raw / 100
			end
			return raw
		end,
		SetSwing = function(v)
			record("SetSwing", v)
			local nextRaw
			if SWING_IS_FRACTION then
				nextRaw = (tonumber(v) or 0) * 100
			else
				nextRaw = v
			end
			lagStage(scalarLag, "swing", getSwingRaw, nextRaw)
			mockSwing = nextRaw
		end,
		GetStrength = function()
			return lagView(scalarLag, "strength", getStrengthRaw)
		end,
		SetStrength = function(v)
			record("SetStrength", v)
			lagStage(scalarLag, "strength", getStrengthRaw, v)
			mockStrength = v
		end,
		GetTimeDivision = function()
			return lagView(scalarLag, "division", getDivisionRaw)
		end,
		SetTimeDivision = function(v)
			record("SetTimeDivision", v)
			lagStage(scalarLag, "division", getDivisionRaw, v)
			mockDivision = v
		end,
	},
}
M.sequencer = sequencer

-- Global automation filter: scalar Get/Set exist next to Advance (LPP3 dump
-- :32); the enum contents are unproven on the device (probe 8 enumerates), so
-- the mock models a 4-value cycle. Set refuses unknown types like the device.
local FILTER_TYPES = { "Off", "Latch", "Touch", "Write" }
local filterIndex = 1
local function getFilterRaw()
	return FILTER_TYPES[filterIndex]
end

local project -- same forward-declaration pattern
project = {
	-- BPM is a lagged prop: the script writes mpc.project.BPM.value directly, which the
	-- prop's __newindex routes through the same lag model (no listeners, as before).
	BPM = laggedProp(mockBpm),
	GlobalAutomationFilterType = prop(FILTER_TYPES[filterIndex]),
	GetGlobalAutomationFilterType = function()
		record("GetGlobalAutomationFilterType")
		return lagView(scalarLag, "filter", getFilterRaw)
	end,
	SetGlobalAutomationFilterType = function(t)
		record("SetGlobalAutomationFilterType", t)
		for i, name in ipairs(FILTER_TYPES) do
			if name == t then
				lagStage(scalarLag, "filter", getFilterRaw, name)
				filterIndex = i
				project.GlobalAutomationFilterType:set(t)
				return
			end
		end
		error("unknown automation filter type: " .. tostring(t))
	end,
	AdvanceGlobalAutomationFilterType = function()
		record("AdvanceGlobalAutomationFilterType")
		local nextIndex = (filterIndex % #FILTER_TYPES) + 1
		lagStage(scalarLag, "filter", getFilterRaw, FILTER_TYPES[nextIndex])
		filterIndex = nextIndex
		project.GlobalAutomationFilterType:set(FILTER_TYPES[filterIndex])
	end,
}
M.project = project

-- Device truth (triage r5): masterTracks[0] is NOT the master fader path.
-- Default "dead": Volume reads 0.0 and writes are silently ignored (device D2/D3
-- - a silent rejection is undetectable from Lua, so the script must not pretend
-- it succeeded). "readonly": the write raises (read-only sol2 property) so the
-- script logs it once. "nilread": Volume cannot be read (device D4), so the
-- script must not write blindly. Tests prove a live slot with makeMasterLive().
local masterSlot = { Name = prop("Master") }
local masterMode = "dead"

local function buildMasterVolume()
	if masterMode == "readonly" then
		return setmetatable({}, {
			__index = function(_t, k)
				if k == "value" then
					return 0.0
				end
				return nil
			end,
			__newindex = function()
				error("masterTracks[0].Volume is read-only")
			end,
		})
	elseif masterMode == "nilread" then
		return setmetatable({}, {
			__index = function()
				return nil
			end,
			__newindex = function()
				error("masterTracks[0].Volume is read-only")
			end,
		})
	end
	-- dead (default): the write is swallowed, the read stays 0.0
	return setmetatable({}, {
		__index = function(_t, k)
			if k == "value" then
				return 0.0
			end
			return nil
		end,
		__newindex = function() end,
	})
end
masterSlot.Volume = buildMasterVolume()

function M.setMasterSlot(mode)
	masterMode = mode or "dead"
	masterSlot.Volume = buildMasterVolume()
end

function M.makeMasterLive()
	masterMode = "live"
	masterSlot.Volume = prop(0.8)
end

local commandManager = {
	CanUndo = function()
		return true
	end,
	CanRedo = function()
		return true
	end,
	Undo = function()
		record("Undo")
	end,
	Redo = function()
		record("Redo")
	end,
}
M.commandManager = commandManager

local clipMatrix = {
	SelectTrack = function(i)
		record("SelectTrack", i)
	end,
	GetRows = function()
		return 4
	end,
	HasClip = function(col, row)
		record("HasClip", col, row)
		return col <= 1 -- tracks 0/1 have clips; the rest are empty
	end,
	StopAllClips = function()
		record("StopAllClips")
		for i = 0, 15 do
			sceneStates[i]:set(1)
		end
	end,
}
M.sceneStates = sceneStates

-- Q-Links (mpc.controlSurface.qlinks, 0-based, 16 knobs). Twist is the real
-- knob rotation: it moves the position AND the target value string.
-- SetPosition is the position-sync write: the knob moves, the value string
-- stays (that is how the script detects a no-effect Twist). Twist has a
-- plain dot-form signature: a method-form call passes the qlink table as the
-- delta and fails loudly, so the script falls through to the next form.
-- The getters read through the lag model: with a read lag armed they report
-- one write behind, like the device.
local qlinkTargets = {}
local qlinkPositions = {}
local qlinkValueStrings = {}
-- Exposed view: reads give device truth; test-side writes route through the lag
-- model too, so a device-side move also reads back with the armed lag.
M.qlinkPositions = setmetatable({}, {
	__index = function(_t, k)
		return qlinkPositions[k]
	end,
	__newindex = function(_t, k, v)
		lagStage(qlinkPositions, k, function()
			return qlinkPositions[k]
		end, v)
		qlinkPositions[k] = v
	end,
})
local function qlinkPercent(pos)
	return tostring(math.floor(pos / 127 * 100 + 0.5)) .. "%"
end
local qlinks = {}
for i = 0, 15 do
	qlinkPositions[i] = 64
	qlinkValueStrings[i] = qlinkPercent(64)
	qlinks[i] = {
		GetPosition = function()
			record("GetPosition")
			return lagView(qlinkPositions, i, function()
				return qlinkPositions[i]
			end)
		end,
		SetPosition = function(pos)
			local clamped = math.max(0, math.min(127, pos))
			lagStage(qlinkPositions, i, function()
				return qlinkPositions[i]
			end, clamped)
			qlinkPositions[i] = clamped
			record("SetPosition", i, pos)
		end,
		Twist = function(delta)
			if type(delta) ~= "number" then
				error("Twist expects a numeric delta, got " .. type(delta))
			end
			if twistNoEffect then
				error("Twist unavailable") -- simulates a firmware without a callable Twist
			end
			record("Twist", i, delta)
			local np = math.max(0, math.min(127, qlinkPositions[i] + delta))
			lagStage(qlinkPositions, i, function()
				return qlinkPositions[i]
			end, np)
			qlinkPositions[i] = np
			lagStage(qlinkValueStrings, i, function()
				return qlinkValueStrings[i]
			end, qlinkPercent(np))
			qlinkValueStrings[i] = qlinkPercent(np)
		end,
		Touch = function()
			record("Touch", i)
		end,
		GetValue = function()
			return lagView(qlinkPositions, i, function()
				return qlinkPositions[i]
			end) / 127
		end,
		SetValue = function(v)
			record("SetValue", i, v)
			local np = math.max(0, math.min(127, math.floor((tonumber(v) or 0) * 127 + 0.5)))
			lagStage(qlinkPositions, i, function()
				return qlinkPositions[i]
			end, np)
			qlinkPositions[i] = np
			lagStage(qlinkValueStrings, i, function()
				return qlinkValueStrings[i]
			end, qlinkPercent(np))
			qlinkValueStrings[i] = qlinkPercent(np)
		end,
		GetValueString = function()
			record("GetValueString")
			-- explicitly unassigned slots answer with an empty string (device
			-- behaviour unknown but plausible; this is what exercises the
			-- script's never-blank "-" fallback)
			if qlinkTargets[i] == false then
				return ""
			end
			return lagView(qlinkValueStrings, i, function()
				return qlinkValueStrings[i]
			end)
		end,
		GetTargetName = function()
			-- false marks an explicitly unassigned Q-Link (returns nil)
			if qlinkTargets[i] == false then
				return nil
			end
			return qlinkTargets[i] or "target" .. i
		end,
	}
end
qlinks.GetNumQLinks = function()
	return 16
end
M.setQlinkTarget = function(i, name)
	qlinkTargets[i] = name
end
M.setTimeDivision = function(v)
	lagStage(scalarLag, "division", getDivisionRaw, v)
	mockDivision = v
end
M.setSwingStale = function(v)
	SWING_STALE = v and true or false
end
-- Test fixture (task T2): flip the swing wire form to 0..1 fractions (the H3
-- hypothesis the script auto-detects). lagReseed drops pending swing writes so
-- the flip cannot leak a percent-form value into the fraction world.
M.setSwingFraction = function(v)
	SWING_IS_FRACTION = v and true or false
	lagReseed()
end
M.setTwistNoEffect = function(v)
	twistNoEffect = v and true or false
end
M.qlinkPosition = function(i)
	return qlinkPositions[i]
end

-- Test fixture (task T2): replace the automation-filter enum (nil restores the
-- default 4-value cycle). filterIndex restarts at the first entry and the lag
-- model is re-synced, so a pending filter write cannot leak into the new list.
function M.setFilterTypes(list)
	FILTER_TYPES = (list ~= nil and #list > 0) and list or { "Off", "Latch", "Touch", "Write" }
	filterIndex = 1
	project.GlobalAutomationFilterType:set(FILTER_TYPES[1])
	lagReseed()
end

local function button(name)
	return {
		Press = function()
			record(name .. ".Press")
		end,
		Release = function()
			record(name .. ".Release")
		end,
		Hold = function()
			record(name .. ".Hold")
		end,
		DoublePress = function()
			record(name .. ".DoublePress")
		end,
	}
end

M.mpc = {
	tracks = {
		normalTracks = tracks,
		masterTracks = { [0] = masterSlot },
		currentTrack = currentTrack,
		Count = prop(NUM_TRACKS),
		GetCount = function()
			return NUM_TRACKS
		end,
		SizeNormalTracks = function()
			return NUM_TRACKS
		end,
		SetCurrentTrack = function(i)
			record("SetCurrentTrack", i)
			currentTrack.Index:set(i)
			currentTrack.Name:set("Track " .. i)
		end,
	},
	sequencer = sequencer,
	project = project,
	commandManager = commandManager,
	engineMode = {
		CurrentMode = prop("Main Mode"),
		CurrentPopup = prop("No Popup"),
		RequestModeChange = function(name)
			record("RequestModeChange", name)
		end,
	},
	ui = {
		ShowTUIFeedback = function(s)
			record("ShowTUIFeedback", s)
		end,
	},
	features = {
		UseClipWorkflow = prop(true),
	},
	clipMatrix = clipMatrix,
	controlSurface = {
		qlinks = qlinks,
		quantizeApply = button("quantizeApply"),
		tapTempo = button("tapTempo"),
		metronome = button("metronome"),
	},
}

-----------------------------------------------------------------------------------------------
-- dev (the device table the MPC exposes, named after the script file)
-----------------------------------------------------------------------------------------------

local function scriptMappings()
	local ccKey = function(ch, cc)
		return tostring(ch) .. ":" .. tostring(cc)
	end
	return {
		AddCCToScript = function(ch, cc)
			record("AddCCToScript", ch, cc)
			M.scriptCCs[ccKey(ch, cc)] = true
		end,
		RemoveCCToScript = function(ch, cc)
			record("RemoveCCToScript", ch, cc)
			M.scriptCCs[ccKey(ch, cc)] = nil
		end,
		AddNoteToScript = function(ch, note)
			record("AddNoteToScript", ch, note)
		end,
		RemoveNoteToScript = function(ch, note)
			record("RemoveNoteToScript", ch, note)
		end,
		IsCCMappedToScript = function(ch, cc)
			return M.scriptCCs[ccKey(ch, cc)] == true
		end,
		SetHandleSysex = function(v)
			record("SetHandleSysex", v)
		end,
	}
end

local function qlinkMappings()
	-- Akai's shipped signatures (mpc310 kit scripts, mpkMiniMkIV.lua): bindings
	-- are keyed per (channel, cc) -- AddInfiniteCCToQLink(channel, cc, qlinkIndex),
	-- RemoveInfiniteCCToQLink(channel, cc), IsQLinkMappedInfinite(channel, cc),
	-- SetQLinkFineAdjust(fine). A channel-first bind lands under the wrong key
	-- and the honest (channel, cc) query fails it, so the script's query-flip
	-- verification cannot confirm a mis-bind. The stored value is the Q-Link
	-- index, so tests can assert the QLINK_ORDER slot a knob was bound to.
	local key = function(ch, cc)
		return tostring(ch) .. ":" .. tostring(cc)
	end
	return {
		AddInfiniteCCToQLink = function(ch, cc, qi)
			record("AddInfiniteCCToQLink", ch, cc, qi)
			if M.nativeMappingHostile then
				return -- accepts anything, stores nothing: the mis-bind case
			end
			M.qlinkMapped[key(ch, cc)] = qi
		end,
		RemoveInfiniteCCToQLink = function(ch, cc)
			record("RemoveInfiniteCCToQLink", ch, cc)
			M.qlinkMapped[key(ch, cc)] = nil
		end,
		IsQLinkMappedInfinite = function(ch, cc)
			record("IsQLinkMappedInfinite", ch, cc)
			return M.qlinkMapped[key(ch, cc)] ~= nil
		end,
		AddAbsoluteCCToQLink = function(ch, cc, qi)
			record("AddAbsoluteCCToQLink", ch, cc, qi)
		end,
		-- Call recorder only: the signature is unprobed and the honest script
		-- never calls it (test-native-routing.lua asserts the count stays 0).
		SetInfiniteCCMagnitude = function(...)
			record("SetInfiniteCCMagnitude", ...)
		end,
		SetQLinkFineAdjust = function(fine)
			record("SetQLinkFineAdjust", fine)
		end,
	}
end

M.dev = {
	mappings = {
		script = scriptMappings(),
		controlSurface = { qlinks = qlinkMappings() },
	},
	midiOut = {
		SendMIDICC = function(ch, cc, value, _port)
			record("SendMIDICC", ch, cc, value)
			if ch == 0 then
				M.leds[cc] = value
			end
		end,
		SendMIDINoteOn = function(ch, note, vel, _port)
			record("SendMIDINoteOn", ch, note, vel)
			M.notes[#M.notes + 1] = { ch = ch, note = note, vel = vel }
		end,
		SendMIDINoteOff = function(ch, note, vel, _port)
			record("SendMIDINoteOff", ch, note, vel)
		end,
		SendMIDISysex = function(payload, _port)
			record("SendMIDISysex", payload)
			M.sysex[#M.sysex + 1] = payload
			-- custom RGB LED colour: header + 01 53 <ctrl> <R> <G> <B>
			if
				#payload >= 11
				and payload:sub(1, 5) == string.char(0x00, 0x20, 0x29, 0x02, 0x15)
				and payload:byte(6) == 0x01
				and payload:byte(7) == 0x53
			then
				M.leds[payload:byte(8)] = payload:byte(9) .. "," .. payload:byte(10) .. "," .. payload:byte(11)
			end
		end,
	},
	timer = {
		Start = function(ms)
			record("timer.Start", ms)
		end,
		Stop = function()
			record("timer.Stop")
		end,
		Now = function()
			return now
		end,
	},
}

-- Fake device CC emitter: drives the loaded script the way the surface streams
-- input on the analog channel (faders 5-12, abs encoders 13-36, rel 77-100).
-- Only CCs the script registered are delivered - the device never sends
-- unregistered input, so a routing bug shows up as silence, not a wrong write.
local function emitCC(ch, cc, value)
	if not M.dev.mappings.script.IsCCMappedToScript(ch, cc) then
		return
	end
	_G.LaunchControlXL3.HandleMIDICC(ch, cc, value)
end

function M.emitFader(col, value)
	emitCC(15, 5 + col, value)
end

function M.emitAbs(row, col, value)
	emitCC(15, 13 + row * 8 + col, value)
end

function M.emitRel(row, col, delta)
	emitCC(15, 77 + row * 8 + col, 64 + delta)
end

-- Test helper: decode the screen sysex stream into {op=..., target=..., ...}.
function M.screen()
	local out = {}
	for _, s in ipairs(M.sysex) do
		if #s >= 7 and s:sub(1, 5) == string.char(0x00, 0x20, 0x29, 0x02, 0x15) then
			local op = s:byte(6)
			if op == 0x04 then
				out[#out + 1] = { op = "configure", target = s:byte(7), config = s:byte(8) }
			elseif op == 0x06 then
				out[#out + 1] = { op = "text", target = s:byte(7), field = s:byte(8), text = #s > 8 and s:sub(9) or "" }
			elseif op == 0x02 then
				out[#out + 1] = { op = "daw", value = s:byte(7) }
			end
		end
	end
	return out
end

return M
