-- MIDI notes drive the GRAINSWARM voices.
--
-- Asserts, through the script's own params and the mock device:
--   * with MODE off, notes do nothing
--   * VOICES: a note lights a voice at the right pitch; a chord lights one
--     voice per note; note-off silences only that voice
--   * a ninth note steals a voice rather than being dropped
--   * releasing everything leaves the swarm silent
--   * switching MODE back to off hands the grid chord back untouched
--   * TRANSPOSE moves PITCH and leaves the chord alone
--   * the channel filter actually filters

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local function on(note, vel, ch)
  mock.midi.send({ type = "note_on", note = note, vel = vel or 100, ch = ch or 1 })
end
local function off(note, ch)
  mock.midi.send({ type = "note_off", note = note, ch = ch or 1 })
end

-- what the engine was last told
local function gates()
  return mock.calls.last["gates"] or {}
end
local function pitches()
  return mock.calls.last["pitches"] or {}
end
local function live()
  local n = 0
  for _, v in ipairs(gates()) do if v > 0 then n = n + 1 end end
  return n
end

-- a known grid chord to protect: rows 1 and 2, C and E
params:set("mi_mode", 1)
mock.grid.key(3, 1, 1); mock.grid.key(3, 1, 0)     -- row 1, semitone 2
mock.grid.key(5, 2, 1); mock.grid.key(5, 2, 0)     -- row 2, semitone 4
local grid_pitches = {}
for i, v in ipairs(pitches()) do grid_pitches[i] = v end
local grid_live = live()
check(grid_live >= 2, "grid chord did not take: " .. grid_live .. " voices live")

-- MODE off: notes are ignored
on(67)
check(live() == grid_live, "notes moved the chord while MODE was off")
off(67)

-- VOICES
params:set("mi_mode", 2)
params:set("mi_vel", 1)          -- level fixed, so gates are comparable
check(live() == 0, "switching to VOICES did not start from silence")

on(60)
check(live() == 1, "one note gave " .. live() .. " live voices")
local base = params:get("m_pitch")
local p1
for i, v in ipairs(gates()) do if v > 0 then p1 = pitches()[i] end end
check(p1 ~= nil and math.abs(p1 - base) < 0.001,
  string.format("middle C gave pitch %s, expected %s", tostring(p1), base))

on(64); on(67)
check(live() == 3, "a triad gave " .. live() .. " live voices")

off(64)
check(live() == 2, "one note off left " .. live() .. " live voices")

-- fill to eight and then steal
on(64)
for _, n in ipairs({ 69, 71, 72, 74, 76 }) do on(n) end
check(live() == 8, "eight notes gave " .. live() .. " live voices")
on(79)
check(live() == 8, "a ninth note gave " .. live() .. " live voices, want 8")

for _, n in ipairs({ 60, 64, 67, 69, 71, 72, 74, 76, 79 }) do off(n) end
check(live() == 0, "all notes off left " .. live() .. " live voices")

-- octaves either side of middle C
on(48)
local lo
for i, v in ipairs(gates()) do if v > 0 then lo = pitches()[i] end end
check(lo ~= nil and math.abs(lo - (base - 12)) < 0.001,
  string.format("C below middle gave %s, expected %s", tostring(lo), base - 12))
off(48)

-- channel filter
params:set("mi_ch", 4)           -- "3"
on(60, 100, 1)
check(live() == 0, "a note on the wrong channel got through")
on(60, 100, 3)
check(live() == 1, "a note on the right channel was filtered out")
off(60, 3)
params:set("mi_ch", 1)

-- velocity
params:set("mi_vel", 2)
on(60, 32)
local g = gates()
local soft
for _, v in ipairs(g) do if v > 0 then soft = v end end
check(soft ~= nil and soft < 0.4,
  "velocity 32 gave gate " .. tostring(soft) .. ", expected quiet")
off(60)

-- back to OFF: the grid chord returns exactly as it was
params:set("mi_mode", 1)
check(live() == grid_live,
  "leaving MIDI gave " .. live() .. " voices, grid had " .. grid_live)
for i, v in ipairs(grid_pitches) do
  check(math.abs((pitches()[i] or -999) - v) < 0.001,
    string.format("voice %d came back as %s, was %s",
      i, tostring(pitches()[i]), v))
end

-- TRANSPOSE leaves the chord alone and moves PITCH
params:set("m_pitch", 0)
params:set("mi_mode", 3)
on(67)
check(params:get("m_pitch") == 7,
  "G above middle C gave PITCH " .. params:get("m_pitch") .. ", expected 7")
check(live() == grid_live, "TRANSPOSE changed how many voices are live")
off(67)
check(params:get("m_pitch") == 7, "note-off undid the transposition")
params:set("mi_mode", 1)
params:set("m_pitch", 0)

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("MIDI TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("MIDI TEST OK")
