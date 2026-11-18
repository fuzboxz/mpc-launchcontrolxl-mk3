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
local mockSwing = 54
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
	end,
	Overdub = function()
		record("Overdub")
		sequencer.OverdubState:set(1)
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
			return mockSwing
		end,
		SetSwing = function(v)
			record("SetSwing", v)
			mockSwing = v
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

local project -- same forward-declaration pattern
project = {
	BPM = prop(mockBpm),
	GlobalAutomationFilterType = prop("Post"),
	AdvanceGlobalAutomationFilterType = function()
		record("AdvanceGlobalAutomationFilterType")
		project.GlobalAutomationFilterType:set("Pre")
	end,
}
M.project = project

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

-- Q-Links (mpc.controlSurface.qlinks, 0-based, 16 knobs)
local qlinkTargets = {}
local qlinkPositions = {}
M.qlinkPositions = qlinkPositions
local qlinks = {}
for i = 0, 15 do
	qlinkPositions[i] = 64
	qlinks[i] = {
		GetPosition = function()
			return qlinkPositions[i]
		end,
		SetPosition = function(pos)
			qlinkPositions[i] = pos
			record("SetPosition", i, pos)
		end,
		Twist = function(delta)
			qlinkPositions[i] = math.max(0, math.min(127, qlinkPositions[i] + delta))
			record("Twist", i, delta)
		end,
		Touch = function()
			record("Touch", i)
		end,
		GetValue = function()
			return qlinkPositions[i] / 127
		end,
		GetValueString = function()
			return tostring(math.floor(qlinkPositions[i] / 127 * 100 + 0.5)) .. "%"
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
		masterTracks = { [0] = { Volume = prop(0.8), Name = prop("Master") } },
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
	local key = function(ch, cc)
		return tostring(ch) .. ":" .. tostring(cc)
	end
	return {
		AddInfiniteCCToQLink = function(ch, cc, idx)
			record("AddInfiniteCCToQLink", ch, cc, idx)
			M.qlinkMapped[key(ch, cc)] = idx
		end,
		RemoveInfiniteCCToQLink = function(ch, cc)
			record("RemoveInfiniteCCToQLink", ch, cc)
			M.qlinkMapped[key(ch, cc)] = nil
		end,
		IsQLinkMappedInfinite = function(ch, cc)
			return M.qlinkMapped[key(ch, cc)] ~= nil
		end,
		AddAbsoluteCCToQLink = function(ch, cc, idx)
			record("AddAbsoluteCCToQLink", ch, cc, idx)
		end,
		SetInfiniteCCMagnitude = function(ch, cc, mag)
			record("SetInfiniteCCMagnitude", ch, cc, mag)
		end,
		SetQLinkFineAdjust = function(ch, cc, fine)
			record("SetQLinkFineAdjust", ch, cc, fine)
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
