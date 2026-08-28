-- MACHINE: the Turing machine on the sample and hold, and its reveal.
--
-- The behaviour that has to be true:
--   MACHINE 0    every slot rewritten every lap - the free random it replaced
--   MACHINE 1    nothing rewritten: a sixteen step loop, repeating exactly
--   in between    some slots hold and some do not
--
-- and the cell it lives in:
--   it TAKES the middle cell on STEP and GLIDE, where PHASE lives otherwise
--   PHASE is what that cell holds on the other three shapes
--   the cell widens to fit the longer word, and the row still fills 128

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local mmod = mock.metros[2]
assert(mmod and mmod.event, "no modulation metro")

-- Collect the next n held values of LFO 1 by running the modulation tick.
-- The rate is set so a step lands well inside a tick, and rpos is watched
-- rather than the value, because a locked machine can hold the same number
-- twice in a row quite legitimately.
local function steps(n)
  local l = pappus.lfos[1]
  local out, last = {}, l.rpos
  local guard = 0
  while #out < n and guard < 200000 do
    guard = guard + 1
    mock.advance_time(1 / 60)
    mmod.event()
    if l.rpos ~= last then
      last = l.rpos
      out[#out + 1] = l.sh
    end
  end
  check(#out == n, "only collected " .. #out .. " steps of " .. n)
  return out
end

local function matches(a, b)
  local n = 0
  for i = 1, math.min(#a, #b) do
    if math.abs(a[i] - b[i]) < 1e-9 then n = n + 1 end
  end
  return n
end

params:set("lfo1_shape", 1)          -- STEP
params:set("lfo1_rate", 100)         -- fastest division, so laps come quickly

-- MACHINE 1: locked. Two consecutive laps must be identical.
params:set("lfo1_machine", 1)
steps(16)                            -- let it settle onto a lap boundary
local lap1 = steps(16)
local lap2 = steps(16)
check(matches(lap1, lap2) == 16,
  "MACHINE 1 is not locked: " .. matches(lap1, lap2) .. "/16 repeated")

-- MACHINE 0: free. Two laps should share almost nothing.
params:set("lfo1_machine", 0)
steps(16)
local f1 = steps(16)
local f2 = steps(16)
check(matches(f1, f2) <= 2,
  "MACHINE 0 is not free: " .. matches(f1, f2) .. "/16 repeated")

-- halfway: some hold, some do not. Averaged over several laps, because one
-- lap of sixteen coin flips is a noisy thing to assert on.
params:set("lfo1_machine", 0.5)
steps(16)
local held, total = 0, 0
local prev = steps(16)
for _ = 1, 8 do
  local cur = steps(16)
  held = held + matches(prev, cur)
  total = total + 16
  prev = cur
end
local frac = held / total
check(frac > 0.15 and frac < 0.85,
  string.format("MACHINE 0.5 held %.0f%% of slots, wanted somewhere between",
    frac * 100))

-- and it rises monotonically: 0.8 must hold more than 0.2
local function hold_frac(m)
  params:set("lfo1_machine", m)
  steps(16)
  local h, t = 0, 0
  local p = steps(16)
  for _ = 1, 8 do
    local c = steps(16)
    h = h + matches(p, c); t = t + 16; p = c
  end
  return h / t
end
local lo, hi = hold_frac(0.2), hold_frac(0.8)
check(hi > lo + 0.2,
  string.format("MACHINE is not monotonic: 0.2 held %.0f%%, 0.8 held %.0f%%",
    lo * 100, hi * 100))
params:set("lfo1_machine", 0)

-- ---------------------------------------------------------------------------
-- the cell
-- ---------------------------------------------------------------------------

-- find an LFO page and the index of LFO 1's MACHINE cell
local pg, mi, MSLOT
for _, p in ipairs(pappus.pages) do
  if p.kind == "magna" and p.lfos and p.lfos[1] == 1 then pg = p end
end
assert(pg, "no MODNI 1-2 page")
for i, c in ipairs(pg.cells) do
  if c.id == "lfo1_machine" then mi = i end
  if c.swap and c.swap.id == "lfo1_machine" then MSLOT = i end
end
assert(MSLOT, "no cell swaps to lfo1_machine")
check(MSLOT == 2, "the swapping cell should be second in the row, got "
  .. tostring(MSLOT))
mi = MSLOT

local function settle_reveal(n)
  for _ = 1, n do mach_advance(1 / 25) end
end

params:set("lfo1_shape", 3)          -- SINE
check(cell_at(pg, mi).id == "lfo1_phase",
  "the middle cell should be PHASE on a sine LFO, it is "
  .. cell_at(pg, mi).id)
settle_reveal(40)
check(mach_reveal(1) < 0.001,
  "reveal did not retract: " .. mach_reveal(1))
do
  local x, w = magna_cell_x(pg, 1)
  check(math.abs(w - 32) < 0.01,
    string.format("with PHASE showing RATE should be 32 wide, got %.1f", w))
  check(x == 0, "RATE should start at the left edge")
  local _, wm = magna_cell_x(pg, mi)
  check(math.abs(wm - 32) < 0.01, "the middle cell should start at 32")
end

params:set("lfo1_shape", 1)          -- STEP
check(cell_at(pg, mi).id == "lfo1_machine",
  "the middle cell should be MACHINE on a STEP LFO, it is "
  .. cell_at(pg, mi).id)
-- mid-slide: narrower than its final width, and already on screen
settle_reveal(3)
do
  local r = mach_reveal(1)
  check(r > 0.001 and r < 0.999,
    "reveal should be part way after three frames, got " .. r)
  local _, w = magna_cell_x(pg, mi)
  check(w > 32 and w < 41, "the middle cell should be growing, got " .. w)
  local _, w1 = magna_cell_x(pg, 1)
  check(w1 < 32 and w1 > 23, "RATE should be compressing, got " .. w1)
  local _, w3 = magna_cell_x(pg, 3)
  check(math.abs(w3 - 32) < 0.01,
    "DEST A should not move - it is RATE that pays, got " .. w3)
end
settle_reveal(40)
do
  local _, w = magna_cell_x(pg, mi)
  check(w > 36, "MACHINE should settle wider than a quarter row, got " .. w)
  local _, w1 = magna_cell_x(pg, 1)
  check(w1 < w, "RATE should end up narrower than MACHINE")
end
-- the row fills exactly 128 at every point of the slide, or the cells drift
for _, r in ipairs({ 0, 3, 6, 10, 40 }) do
  params:set("lfo1_shape", 1)
  for _ = 1, r do mach_advance(1 / 25) end
  local x4, w4 = magna_cell_x(pg, 4)
  check(math.abs((x4 + w4) - 128) < 0.01,
    string.format("row ends at %.2f, not 128", x4 + w4))
  local x1, w1 = magna_cell_x(pg, 1)
  check(x1 == 0, "the row does not start at 0")
  for k = 2, 4 do
    local xp, wp = magna_cell_x(pg, k - 1)
    local xk = magna_cell_x(pg, k)
    check(math.abs(xk - (xp + wp)) < 0.01,
      string.format("cell %d starts at %.2f, cell %d ended at %.2f",
        k, xk, k - 1, xp + wp))
  end
end
settle_reveal(40)

-- E1 walks past it when it is away, and onto it when it is not.
--
-- `sel` and `page` are locals inside the script, so this asks the question
-- the way a player would: step the cursor along and see whether E2 ever
-- reaches the parameter.
local pgi
for i, p in ipairs(pappus.pages) do if p == pg then pgi = i end end
-- MODNI is in the lower lane now, so K3 alone will never get there
local function goto_pg(n)
  assert(goto_page_index(n), "no page " .. n)
end

local function reachable(id)
  goto_pg(pgi)
  for _ = 1, 20 do enc(1, -1) end
  for _ = 1, 20 do
    local before = params:get(id)
    enc(2, 1)
    local moved = params:get(id) ~= before
    params:set(id, before)
    if moved then return true end
    enc(1, 1)
  end
  return false
end

params:set("lfo1_shape", 1)
check(reachable("lfo1_machine"), "E1 cannot reach MACHINE on a STEP LFO")
check(not reachable("lfo1_phase"), "PHASE is still reachable on a STEP LFO")
params:set("lfo1_shape", 3)
check(not reachable("lfo1_machine"), "E1 lands on MACHINE on a sine LFO")
check(reachable("lfo1_phase"), "E1 cannot reach PHASE on a sine LFO")
-- and both destinations are on the row
check(reachable("lfo1_a1"), "DEST A is not reachable")
check(reachable("lfo1_a2"), "DEST B is not reachable")

-- the grid row follows the swap: the same key sets whichever is in the slot
goto_pg(pgi)
params:set("lfo1_shape", 3)
params:set("lfo1_machine", 0); params:set("lfo1_phase", 0)
mock.grid.key(16, mi, 1); mock.grid.key(16, mi, 0)
check(params:get("lfo1_phase") == 1,
  "the grid did not set PHASE on a sine LFO")
check(params:get("lfo1_machine") == 0,
  "the grid set MACHINE while PHASE was in the slot")
params:set("lfo1_shape", 1)
mock.grid.key(16, mi, 1); mock.grid.key(16, mi, 0)
check(params:get("lfo1_machine") == 1,
  "the grid did not set MACHINE on a STEP LFO")

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("MACHINE TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("MACHINE TEST OK")
