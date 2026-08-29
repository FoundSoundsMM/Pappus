-- Lanes, the wipe, and the encoder pushes.
--
--   * K2 / K3 walk the AUDIO lane and never land on a MODNI page
--   * K2 and K3 together drop to the modulators, and again come back
--   * the press that completes the pair does NOT also move a page
--   * each lane remembers where it was
--   * a page change starts a wipe that eases to zero and stops
--   * pushing E1 puts the selected parameter back to its default
--   * pushing E2 / E3 snaps to a round value

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local function tap(n)
  key(n, 1); key(n, 0)
end
local function both()
  key(2, 1); key(3, 1); key(3, 0); key(2, 0)
end

local function kind()
  return pappus.pages[current_page()].kind
end
local function name()
  return pappus.pages[current_page()].name
end

local MOD = { magna = true, envmod = true }

-- walk the whole audio lane forwards: never a modulator

-- Pages are found by KIND, never by index. Two granulators added two pages in
-- the middle of the list and every hardcoded index after them silently pointed
-- at the wrong page - the assertions still ran, they just tested nothing.
local function page_of(kind)
  for i, pg in ipairs(pappus.pages) do
    if pg.kind == kind then return i end
  end
  error("no page of kind " .. kind)
end

goto_page_index(1)
local seen = {}
for _ = 1, 30 do
  check(not MOD[kind()], "K3 landed on a modulator page: " .. name())
  seen[name()] = true
  tap(3)
end
check(seen["SIGNAL"], "K3 never reached SIGNAL")
check(seen["SNAPSHOTS"], "K3 never reached the end of the lane")
check(not seen["MODNI 1-2"], "K3 reached a MODNI page")

-- ...and back
for _ = 1, 30 do
  check(not MOD[kind()], "K2 landed on a modulator page: " .. name())
  tap(2)
end
check(name():match("GRAINSWARM"), "K2 did not come home, sitting on " .. name())

-- both keys: down to the modulators, and the page must NOT have moved sideways
tap(3); tap(3)                       -- park somewhere identifiable
local before = name()
both()
check(MOD[kind()], "K2+K3 did not reach the modulators, on " .. name())
local modpage = name()
both()
check(not MOD[kind()], "K2+K3 did not come back up, on " .. name())
check(name() == before,
  "the lane change moved the audio page: left " .. before .. ", returned to "
  .. name())

-- each lane remembers where it was
both()
check(name() == modpage,
  "the modulator lane forgot its page: " .. name() .. " not " .. modpage)
tap(3); tap(3)
local modpage2 = name()
both(); both()
check(name() == modpage2,
  "the modulator lane forgot again: " .. name() .. " not " .. modpage2)
both()

-- the wipe runs and settles
goto_page_index(1)
for _ = 1, 40 do wipe_advance(1 / 25) end
local x0, y0 = wipe_offset()
check(x0 == 0 and y0 == 0, "the wipe did not settle: " .. x0 .. "," .. y0)
tap(3)
local x1 = wipe_offset()
check(math.abs(x1) > 40, "a page change did not start a wipe: " .. x1)
local prev = math.abs(x1)
local moved = 0
for _ = 1, 20 do
  wipe_advance(1 / 25)
  local x = math.abs((wipe_offset()))
  if x < prev then moved = moved + 1 end
  prev = x
end
check(moved >= 3, "the wipe did not ease inwards")
check(prev == 0, "the wipe did not reach zero, stuck at " .. prev)
-- and a lane change wipes VERTICALLY, not sideways
for _ = 1, 40 do wipe_advance(1 / 25) end
both()
local wx, wy = wipe_offset()
check(wx == 0 and math.abs(wy) > 20,
  string.format("a lane change wiped %d,%d - wanted vertical", wx, wy))
both()

-- encoder pushes
goto_page_index(1)
-- The pushes under test here are the continuous ones - default and
-- snap-to-round - so find a cell with a controlspec and LAND ON IT by index.
-- Counting encoder clicks from an assumed starting cell is what broke this
-- twice: once when SRC arrived at the front of the page, and again when the
-- waveform became cell ZERO and the walk gained a step below one.
local ci, id, p = 0
repeat
  ci = ci + 1
  id = pappus.pages[current_page()].cells[ci].id
  p = params:lookup_param(id)
until p.controlspec ~= nil or ci >= #pappus.pages[current_page()].cells
assert(p.controlspec, "no continuous cell on page 1 to test the pushes on")
assert(goto_cell(ci), "could not select cell " .. ci)
local def = p.controlspec.default
params:set(id, (def == 0) and 5 or 0)
check(params:get(id) ~= def, "could not move the parameter off its default")
key(4, 1); key(4, 0)                      -- push E1
check(math.abs(params:get(id) - def) < 1e-9,
  string.format("push E1 gave %.4f, default is %.4f", params:get(id), def))

-- snap: put it somewhere untidy and push E2
params:set(id, def + 3.37)
local before_snap = params:get(id)
key(5, 1); key(5, 0)                      -- push E2
local after = params:get(id)
check(after ~= before_snap, "push E2 did not move anything")
local step = snap_step(p)
check(math.abs((after / step) - util.round(after / step)) < 1e-6,
  string.format("push E2 left %.6f, which is not a multiple of %.6f",
    after, step))
params:set(id, def)

-- an option cell is already round: pushing E2 must not scramble it
goto_page_index(page_of("spettru"))
assert(goto_cell(2), "could not select RESONATOR's FREQ cell")
local oid = "p_freqmode"
params:set(oid, 2)
-- select the FREQ cell, whose mode is p_freqmode, and push E3
key(6, 1); key(6, 0)
check(params:get(oid) == 2, "push E3 changed an option that was already round")
key(4, 1); key(4, 0)
-- ...and NOT with ==. A control param stores its position on the knob, so
-- get() is map(unmap(v)) and on a warped spec that comes back a whisker off
-- the number that went in. Hardware does this too; the mock used to hide it.
do
  local want = params:lookup_param("p_freq").controlspec.default
  check(math.abs(params:get("p_freq") - want) < 1e-9,
    "push E1 did not default FREQ: wanted " .. want .. ", got "
    .. params:get("p_freq"))
end

-- long K2 puts the selected parameter back AND takes the modulator off it
goto_page_index(page_of("shader"))      -- COLOUR
-- DRIVE by name, not "cell one". Cell one is the routing feed now, and the
-- LFO below is pointed at K.DRIVE - selecting the wrong cell made this pass
-- an assertion about a parameter nothing was modulating.
local ci = 1
for i, c in ipairs(pappus.pages[current_page()].cells) do
  if c.id == "drive" then ci = i end
end
assert(goto_cell(ci), "could not select DRIVE")
local cid = pappus.pages[current_page()].cells[ci].id
local cdef = params:lookup_param(cid).controlspec.default
params:set(cid, cdef + 0.4)
-- point an LFO at it
local dp = params:lookup_param("lfo1_d1")
local want
for i, n in ipairs(dp.options) do if n == "C.DRIVE" then want = i end end
check(want, "K.DRIVE is not in the destination list")
params:set("lfo1_d1", want)
params:set("lfo1_a1", 0.7)
key(2, 1); mock.advance_time(0.6); key(2, 0)
check(math.abs(params:get(cid) - cdef) < 1e-9,
  string.format("long K2 left %s at %.4f, default is %.4f",
    cid, params:get(cid), cdef))
check(params:get("lfo1_d1") == 1,
  "long K2 defaulted the parameter but left the LFO driving it, which "
  .. "means it moves straight back off the default")

-- and a SHORT K2 is still a page move
local was = current_page()
key(2, 1); key(2, 0)
check(current_page() ~= was, "short K2 stopped paging")

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("NAV TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("NAV TEST OK")
