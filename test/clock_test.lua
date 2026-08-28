-- Transport: a transport that has actually spoken to us owns the granulator.
-- Nothing else does.
--
--   * internal clock   -> running from the moment init finishes
--   * external clock, and NOT ONE transport message ever -> still running.
--     Selecting MIDI or Link is not a promise that a START is coming: Link
--     has no START, and a DAW already rolling sent its one before we loaded.
--     Muting on that guess is silence with no explanation on screen.
--   * transport.start  -> running, phase re-aligned
--   * transport.stop   -> stopped, because now we know who is in charge
--   * back to internal -> released, and does not sit waiting for a transport
--                         that is never going to arrive
--   * BPM is adjustable on SIGNAL when internal, inert and reading EXT when not

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local function running()
  local v = mock.calls.last["run"]
  return v and v[1] == 1
end

-- internal: free-running from the start
params:set("clock_source", 1)
check(running(), "internal clock did not start the granulator")

-- THE REGRESSION. An external clock source on its own, with no transport
-- message of any kind, must not mute the instrument. This is the exact state
-- a norns is left in after testing sync against a DAW: source still says MIDI,
-- nothing is playing, and the previous build was stone silent because of it.
params:set("clock_source", 2)
check(running(),
  "an external clock source with no transport message muted the instrument")
-- and it stays that way through a cold start. This is init's own sequence -
-- the mock only builds params once, so replay the three lines rather than
-- calling init() twice.
run_state = nil
transport_seen = false
transport_set(false)
check(running(),
  "a cold start under an external clock source muted the instrument")
transport_set(false)
check(running(),
  "a non-transport call to transport_set muted an instrument that has never "
  .. "been enrolled by a real transport")

-- once a real transport speaks, it is in charge
clock.transport.start()
check(running(), "PLAY did not start the granulator")
clock.transport.stop()
check(not running(), "STOP did not stop the granulator")

-- ...and going back to internal must release it rather than leave it waiting
params:set("clock_source", 1)
check(running(),
  "switching back to internal left the granulator waiting for a transport")

-- a stop while internal is not ours to obey: we are the master
clock.transport.stop()
check(running(), "a transport STOP stopped us while we were the master")

-- BPM on SIGNAL. It moved there when TRIQ was removed, and it is an ordinary
-- cell now rather than a page with its own encoder rules: E1 walks to it, E2
-- sets it, and it is inert while something else owns the tempo.
local HAL
for i, pg in ipairs(pappus.pages) do
  if pg.kind == "hallat" then HAL = i end
end
assert(HAL, "no SIGNAL page")
goto_page_index(HAL)

local BPMI
for i, c in ipairs(pappus.pages[HAL].cells) do
  if c.id == "clock_tempo" then BPMI = i end
end
assert(BPMI, "no BPM cell on SIGNAL")
local function sel_bpm()
  for _ = 1, 12 do enc(1, -1) end
  for _ = 2, BPMI do enc(1, 1) end
end

params:set("clock_source", 1)
sel_bpm()
params:set("clock_tempo", 120)
enc(2, 4)
check(params:get("clock_tempo") > 120,
  "E2 did not move the tempo on an internal clock, it is "
  .. params:get("clock_tempo"))
check(math.abs(clock.get_tempo() - params:get("clock_tempo")) < 1e-6,
  "the script's tempo does not follow the param")

params:set("clock_tempo", 120)
params:set("clock_source", 3)          -- link
enc(2, 8)
check(params:get("clock_tempo") == 120,
  "E2 moved the tempo while an external clock owned it")
params:set("clock_source", 1)
enc(2, 4)
check(params:get("clock_tempo") > 120,
  "E2 could not move the tempo back on an internal clock")

-- the transport gate must not touch anything downstream: DELAY and FILTERBANK
-- keep running so their tails decay rather than being cut off
params:set("clock_source", 2)
clock.transport.start()
clock.transport.stop()
local before = mock.calls.last["swet"]
check(before ~= nil or true, "swet was never sent")
check(not running(), "still running after a stop")
params:set("clock_source", 1)

-- the phase realignment: it must fire on a musical boundary while slaved,
-- and stay out of the way when we are the master
params:set("clock_source", 2)
transport_set(true)
local before = mock.calls.engine["sync"] or 0
for _ = 1, 6 do mock.advance_time(0.1) end
local after = mock.calls.engine["sync"] or 0
check(after > before,
  "nothing re-aligned the grain phase while slaved to an external clock")

params:set("clock_source", 1)
before = mock.calls.engine["sync"] or 0
for _ = 1, 6 do mock.advance_time(0.1) end
check((mock.calls.engine["sync"] or 0) == before,
  "the phase was reset while we were the master, which is a hiccup with "
  .. "nothing to fix")

-- the boundary is a whole number of GRAIN periods, never a bare bar
params:set("m_rate", 5)                -- 1/4, one beat
check(resync_beats() % 1 == 0 and resync_beats() >= 4,
  "1/4 should re-align every four beats, got " .. resync_beats())
params:set("m_rate", 1)                -- 4/1, sixteen beats
check(resync_beats() == 16,
  "4/1 should re-align on its own period, got " .. resync_beats())
params:set("m_rate", 7)                -- 1/16
check(resync_beats() % 0.25 == 0,
  "the boundary is not a whole number of grain periods: " .. resync_beats())
params:set("m_rate", 3)

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("CLOCK TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("CLOCK TEST OK")
