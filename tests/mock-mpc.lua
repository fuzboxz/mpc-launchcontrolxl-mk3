-- tests/mock-mpc.lua: a minimal MPC 3.10.1 API mock for the Launch Control XL 3 script.
-- Records every call; decodes LED RGB sysex into M.leds[cc] = "r,g,b".

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

function M.reset()
	M.calls = {}
	M.leds = {}
	M.notes = {}
	M.sysex = {}
	twistNoEffect = false
end

function M.clearCalls()
	M.calls = {}
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

-----------------------------------------------------------------------------------------------
-- mpc.*
-----------------------------------------------------------------------------------------------

local NUM_TRACKS = 16
local tracks = {}
for i = 0, NUM_TRACKS - 1 do
	local t = {
		Volume = prop(0.7),
		Pan = prop(0.5),
		Send1 = prop(0),
		Send2 = prop(0),
		Send3 = prop(0),
		Send4 = prop(0),
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
		sequencer.OverdubState:set(1)
		sequencer.RecordState:set(1) -- device-observed: overdub-only raises recordActive()
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
		mockBpm = bpm
	end,
	GetBPM = function()
		return mockBpm
	end,
	quantiser = {
		Enabled = prop(true),
		GetSwing = function()
			if SWING_STALE then
				return 50 -- device emulation: the read lags every change (stuck-75 bug)
			end
			if SWING_IS_FRACTION then
				return mockSwing / 100
			end
			return mockSwing
		end,
		SetSwing = function(v)
			record("SetSwing", v)
			if SWING_IS_FRACTION then
				mockSwing = (tonumber(v) or 0) * 100
			else
				mockSwing = v
			end
		end,
		GetStrength = function()
			return mockStrength
		end,
		SetStrength = function(v)
			record("SetStrength", v)
			mockStrength = v
		end,
		GetTimeDivision = function()
			return mockDivision
		end,
		SetTimeDivision = function(v)
			record("SetTimeDivision", v)
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

local project -- same forward-declaration pattern
project = {
	BPM = prop(mockBpm),
	GlobalAutomationFilterType = prop(FILTER_TYPES[filterIndex]),
	GetGlobalAutomationFilterType = function()
		record("GetGlobalAutomationFilterType")
		return FILTER_TYPES[filterIndex]
	end,
	SetGlobalAutomationFilterType = function(t)
		record("SetGlobalAutomationFilterType", t)
		for i, name in ipairs(FILTER_TYPES) do
			if name == t then
				filterIndex = i
				project.GlobalAutomationFilterType:set(t)
				return
			end
		end
		error("unknown automation filter type: " .. tostring(t))
	end,
	AdvanceGlobalAutomationFilterType = function()
		record("AdvanceGlobalAutomationFilterType")
		filterIndex = (filterIndex % #FILTER_TYPES) + 1
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
local qlinkTargets = {}
local qlinkPositions = {}
local qlinkValueStrings = {}
M.qlinkPositions = qlinkPositions
local twistNoEffect = false -- setTwistNoEffect(true): Twist lands, nothing moves
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
			return qlinkPositions[i]
		end,
		SetPosition = function(pos)
			qlinkPositions[i] = math.max(0, math.min(127, pos))
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
			qlinkPositions[i] = math.max(0, math.min(127, qlinkPositions[i] + delta))
			qlinkValueStrings[i] = qlinkPercent(qlinkPositions[i])
		end,
		Touch = function()
			record("Touch", i)
		end,
		GetValue = function()
			return qlinkPositions[i] / 127
		end,
		SetValue = function(v)
			record("SetValue", i, v)
			qlinkPositions[i] = math.max(0, math.min(127, math.floor((tonumber(v) or 0) * 127 + 0.5)))
			qlinkValueStrings[i] = qlinkPercent(qlinkPositions[i])
		end,
		GetValueString = function()
			record("GetValueString")
			return qlinkValueStrings[i]
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
	mockDivision = v
end
M.setSwingStale = function(v)
	SWING_STALE = v and true or false
end
M.setTwistNoEffect = function(v)
	twistNoEffect = v and true or false
end
M.qlinkPosition = function(i)
	return qlinkPositions[i]
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
	-- Device-inferred (H4) argument order: the QLINK INDEX comes first, then
	-- the CC, then an optional channel. Keyed per qlink+cc so the script's
	-- query-flip self-verification gets a truthful counterpart: a legacy
	-- channel-first bind lands under the wrong key and the (qlink, cc) query
	-- fails it, instead of confirming the mis-bind like the old mock did.
	local key = function(qi, cc)
		return tostring(qi) .. ":" .. tostring(cc)
	end
	local CH_ANALOG = 15 -- the script's analog channel (faders + encoders)
	return {
		AddInfiniteCCToQLink = function(qi, cc, ch)
			record("AddInfiniteCCToQLink", qi, cc, ch)
			M.qlinkMapped[key(qi, cc)] = ch or CH_ANALOG
		end,
		RemoveInfiniteCCToQLink = function(qi, cc, ch)
			record("RemoveInfiniteCCToQLink", qi, cc, ch)
			M.qlinkMapped[key(qi, cc)] = nil
		end,
		IsQLinkMappedInfinite = function(qi, cc)
			return M.qlinkMapped[key(qi, cc)] ~= nil
		end,
		AddAbsoluteCCToQLink = function(qi, cc, ch)
			record("AddAbsoluteCCToQLink", qi, cc, ch)
		end,
		SetInfiniteCCMagnitude = function(qi, cc, mag)
			record("SetInfiniteCCMagnitude", qi, cc, mag)
		end,
		SetQLinkFineAdjust = function(qi, cc, fine)
			record("SetQLinkFineAdjust", qi, cc, fine)
		end,
	}
end

local now = 0

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
