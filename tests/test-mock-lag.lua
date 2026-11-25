-- tests/test-mock-lag.lua: the mock's read-lag facility (task T0).
--   1. the default is lag 0: reads are instantaneous (the old suite's world),
--   2. lag 1: a prop read right after a write returns the old value and the
--      new one after one mock.tick,
--   3. lag 3: two writes then a read -- the read stays on the pre-write value
--      until three ticks have passed, then shows the last write,
--   4. the Q-Link getters lag: Twist then GetPosition/GetValueString/GetValue,
--   5. the quantiser/BPM/automation-filter getters lag,
--   6. listeners still fire immediately on a lagged prop write,
--   7. mock.reset() clears the lag model (pending writes vanish, views
--      re-sync with device truth),
--   8. dev.timer.Now() advances 50 ms per tick (mock.advanceMs adds extra).
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

L.OnLoad()
mock.reset()

-- 1: the default at load is lag 0 and reads are immediate (regression guard)
assert_eq(mock.readLag(), 0, "default read lag")
mock.tracks[0].Volume:set(0.1)
assert_eq(mock.tracks[0].Volume.value, 0.1, "lag 0 read is immediate")
local q0 = mock.mpc.controlSurface.qlinks[0]
q0.Twist(1)
assert_eq(q0.GetPosition(), 65, "lag 0 GetPosition is immediate")
mock.reset()

-- 2: lag 1 on a mixer prop
mock.setReadLag(1)
assert_eq(mock.readLag(), 1, "setReadLag arms the lag")
local vol = mock.tracks[0].Volume
vol:set(0.9) -- pre-write truth is 0.1 (set by the lag-0 check above)
assert_eq(vol.value, 0.1, "lag 1: the read right after a write is the pre-write value")
mock.tick(L)
assert_eq(vol.value, 0.9, "lag 1: one tick later the read shows the write")

-- 6: listeners fire immediately even though the read lags
local seen = nil
vol:listen(function(v)
	seen = v
end, "lagtest")
vol:set(0.2)
assert_eq(seen, 0.2, "lagged prop listener fires immediately with the new value")
assert_eq(vol.value, 0.9, "the listener fired while the read still lags")
mock.tick(L)
assert_eq(vol.value, 0.2, "the listener's write becomes readable one tick later")
vol:stopListening("lagtest")

-- 3: lag 3 with two writes
mock.reset()
mock.setReadLag(3)
local send = mock.tracks[1].Send1
send:set(0.25)
send:set(0.75)
assert_eq(send.value, 0, "lag 3: read after two writes is still the initial value")
mock.runTicks(L, 2)
assert_eq(send.value, 0, "lag 3: two ticks are not enough")
mock.tick(L)
assert_eq(send.value, 0.75, "lag 3: after three ticks the last write is visible")

-- 4: the Q-Link getters lag behind Twist
mock.reset()
mock.setReadLag(1)
local q = mock.mpc.controlSurface.qlinks[2]
q.Twist(3)
assert_eq(q.GetPosition(), 64, "lag 1: GetPosition right after Twist is the old position")
assert_eq(q.GetValueString(), "50%", "lag 1: GetValueString lags too")
assert_eq(mock.qlinkPosition(2), 67, "device truth moved immediately")
mock.tick(L)
assert_eq(q.GetPosition(), 67, "lag 1: GetPosition one tick after Twist")
assert_eq(q.GetValueString(), "53%", "lag 1: the value string caught up")
assert_eq(math.floor(q.GetValue() * 127 + 0.5), 67, "lag 1: GetValue lags with the position")

-- a SetPosition ring sync also lags its read-back
mock.qlinkPositions[2] = 40 -- device-side move: reads lag it like any write
assert_eq(mock.qlinkPosition(2), 40, "device truth accessor reads the moved position")
assert_eq(q.GetPosition(), 67, "lag 1: the device-side move is not visible yet")
mock.tick(L)
assert_eq(q.GetPosition(), 40, "lag 1: the device-side move is visible one tick later")

-- 5: the quantiser / BPM / automation-filter getters lag
mock.reset()
mock.setReadLag(1)
local quant = mock.mpc.sequencer.quantiser
quant.SetSwing(58)
assert_eq(quant.GetSwing(), 54, "lag 1: GetSwing right after SetSwing is old")
mock.tick(L)
assert_eq(quant.GetSwing(), 58, "lag 1: GetSwing one tick later")
quant.SetStrength(80)
assert_eq(quant.GetStrength(), 90, "lag 1: GetStrength lags")
mock.tick(L)
assert_eq(quant.GetStrength(), 80, "lag 1: strength caught up")
quant.SetTimeDivision("1/8")
assert_eq(quant.GetTimeDivision(), "1/16", "lag 1: GetTimeDivision lags")
mock.tick(L)
assert_eq(quant.GetTimeDivision(), "1/8", "lag 1: division caught up")
mock.sequencer.SetBPM(126)
assert_eq(mock.sequencer.GetBPM(), 120, "lag 1: GetBPM lags")
mock.tick(L)
assert_eq(mock.sequencer.GetBPM(), 126, "lag 1: BPM caught up")
mock.project.SetGlobalAutomationFilterType("Latch")
assert_eq(mock.project.GetGlobalAutomationFilterType(), "Off", "lag 1: the filter Get lags")
mock.tick(L)
assert_eq(mock.project.GetGlobalAutomationFilterType(), "Latch", "lag 1: filter caught up")

-- the script's direct .value write path (mpc.project.BPM.value = bpm) lags too
-- (note: SetBPM does not touch the BPM prop -- a pre-existing mock quirk -- so the
-- prop's pre-write value here is its own real, 120)
mock.project.BPM.value = 130
assert_eq(mock.project.BPM.value, 120, "lag 1: a direct .value write stays unread one tick")
mock.tick(L)
assert_eq(mock.project.BPM.value, 130, "lag 1: the direct write is readable one tick later")

-- 7: reset clears the lag model
mock.setReadLag(2)
mock.tracks[2].Pan:set(0.3)
mock.reset()
assert_eq(mock.tracks[2].Pan.value, 0.3, "reset re-syncs the lagged view with device truth")

-- 5b: lag 0 is immediate again after arming (regression guard for the old tests)
mock.setReadLag(0)
mock.tracks[2].Pan:set(0.6)
assert_eq(mock.tracks[2].Pan.value, 0.6, "lag 0 reads are immediate")
mock.qlinkPositions[2] = 64
assert_eq(mock.mpc.controlSurface.qlinks[2].GetPosition(), 64, "lag 0 GetPosition is immediate")

-- 8: the timer clock advances 50 ms per tick
mock.reset()
local t0 = mock.dev.timer.Now()
mock.runTicks(L, 2)
assert_eq(mock.dev.timer.Now() - t0, 100, "two ticks advance the clock 100 ms")
mock.advanceMs(40)
assert_eq(mock.dev.timer.Now() - t0, 140, "advanceMs adds on top")

mock.setReadLag(0)
mock.reset()
L.OnUnload()
print("test-mock-lag: PASS")
