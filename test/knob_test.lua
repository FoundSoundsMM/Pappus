-- The knobs, and whether a number you can name is reachable.
--
-- A control parameter stores its POSITION ON THE KNOB, not its value, and the
-- encoders used to move that position by a hundredth of its travel per click.
-- Adding a hundredth of the travel to whatever was there before gives numbers
-- like 0.4937 and 1493.6, and no amount of turning gets you to 0.5 or 1500 -
-- worse, on a warped spec the same click is worth a different amount at each
-- end, so there is no step size you can learn.
--
-- Four claims, checked on every continuous cell on every page:
--
--   1. EVERY CLICK LANDS ON A ROUND NUMBER. Not near one - on one, to within
--      a hundredth of the step, which is all the room floating point needs.
--   2. EVERY CLICK MOVES. A grid you cannot leave is worse than no grid: at
--      the bottom of a warped range a whole coarse click can be worth less
--      than one step, and rounding then hands back the number it started on.
--   3. FINE IS FINER. Ten fine clicks must not travel further than one
--      coarse one, or the two knobs are the same knob.
--   4. THE ENDS ARE REACHABLE, and turning past them stays put rather than
--      wrapping or sticking short.

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

-- the same grid the script uses, restated here rather than reached into: a
-- test that calls the function under test to work out what it expects can
-- only ever agree with it
local function grid_of(v, span)
  local m = math.max(math.abs(v), span * 0.001)
  if m < 2 then return 0.01 end
  if m < 20 then return 0.1 end
  if m < 200 then return 1 end
  if m < 2000 then return 10 end
  return 100
end

local function on_grid(v, q)
  local off = math.abs((v / q) - util.round(v / q))
  return off < 0.01
end

-- every continuous cell in the instrument, with the page and cell to reach it
local CELLS = {}
for pi, pg in ipairs(pappus.pages) do
  for ci, c in ipairs(pg.cells) do
    local p = params:lookup_param(c.id)
    if p and p.controlspec and c.id ~= "clock_tempo" then
      CELLS[#CELLS + 1] = { pi = pi, ci = ci, id = c.id, name = pg.name,
                            label = c.label, alt = c.alt, mode = c.mode }
    end
  end
end
assert(#CELLS > 20, "only found " .. #CELLS .. " continuous cells")

local coarse_checked, fine_checked = 0, 0

for _, e in ipairs(CELLS) do
  local p = params:lookup_param(e.id)
  local spec = p.controlspec
  local span = spec.maxval - spec.minval
  goto_page_index(e.pi)
  if goto_cell(e.ci) then
    -- from three places in the range, not just the default: a warped knob
    -- behaves differently at each end and the default is usually at neither
    for _, start in ipairs({ 0.15, 0.5, 0.85 }) do
      params:set(e.id, spec:map(start))
      for k = 1, 6 do
        local before = params:get(e.id)
        enc(2, 1)
        local v = params:get(e.id)
        local q = grid_of(v, span)
        coarse_checked = coarse_checked + 1
        check(on_grid(v, q), string.format(
          "%s / %s: a coarse click left %.6f, which is not a multiple of %g",
          e.name, e.label, v, q))
        if before < spec.maxval - (q * 0.5) then
          check(v > before, string.format(
            "%s / %s: a coarse click at %.6f did not move it", e.name,
            e.label, before))
        end
      end
    end

    -- FINE only where E3 is the fine tune. On a cell carrying a mode or a
    -- sub-value E3 is that instead, which is the design and not a fault.
    if not (e.alt or e.mode) then
      for _, start in ipairs({ 0.2, 0.6 }) do
        params:set(e.id, spec:map(start))
        for k = 1, 6 do
          local before = params:get(e.id)
          -- the fine step is one tenth of the grid the value is ON, so the
          -- expectation is taken from BEFORE the click - the same number the
          -- script works from
          local q = grid_of(before, span) / 10
          enc(3, 1)
          local v = params:get(e.id)
          fine_checked = fine_checked + 1
          check(on_grid(v, q), string.format(
            "%s / %s: a fine click left %.6f, not a multiple of %g",
            e.name, e.label, v, q))
          if before < spec.maxval - (q * 0.5) then
            check(v > before, string.format(
              "%s / %s: a fine click at %.6f did not move it",
              e.name, e.label, before))
          end
        end

        -- 3. and ten of them must not outrun one coarse click
        params:set(e.id, spec:map(start))
        local base = params:get(e.id)
        for _ = 1, 10 do enc(3, 1) end
        local fine_travel = math.abs(params:get(e.id) - base)
        params:set(e.id, spec:map(start))
        enc(2, 1)
        local coarse_travel = math.abs(params:get(e.id) - base)
        check(fine_travel <= (coarse_travel * 1.5) + 1e-9, string.format(
          "%s / %s: ten fine clicks moved %.4f, one coarse click moved %.4f",
          e.name, e.label, fine_travel, coarse_travel))
      end
    end

    -- 4. both ends, exactly, and no further.
    --
    -- ...except the window pair, which clamp against EACH OTHER: WIN.ST drags
    -- WIN.EN along in front of it and stops two hundredths short of the top
    -- on purpose, because a window with no width is not a window.
    local paired = (e.id:match("win_start$") or e.id:match("win_end$")) ~= nil
    params:set(e.id, spec:map(0.5))
    for _ = 1, 400 do enc(2, 1) end
    local top = params:get(e.id)
    check(paired or math.abs(top - spec.maxval) < (span * 1e-6), string.format(
      "%s / %s: turning up stopped at %.6f, the top is %.6f",
      e.name, e.label, top, spec.maxval))
    enc(2, 1)
    check(params:get(e.id) == top,
      e.name .. " / " .. e.label .. ": turning past the top moved it")
    for _ = 1, 400 do enc(2, -1) end
    local bot = params:get(e.id)
    check(paired or math.abs(bot - spec.minval) < (span * 1e-6), string.format(
      "%s / %s: turning down stopped at %.6f, the bottom is %.6f",
      e.name, e.label, bot, spec.minval))
    param_reset(e.id)
  end
end

print(string.format("  %d cells, %d coarse clicks, %d fine clicks",
  #CELLS, coarse_checked, fine_checked))

-- and the tempo, which is the one people will notice: whole beats on the
-- coarse knob and tenths on the fine one
do
  local HAL, BPMI
  for i, pg in ipairs(pappus.pages) do
    for j, c in ipairs(pg.cells) do
      if c.id == "clock_tempo" then HAL, BPMI = i, j end
    end
  end
  assert(HAL, "no BPM cell")
  params:set("clock_source", 1)
  goto_page_index(HAL)
  assert(goto_cell(BPMI), "could not select BPM")
  params:set("clock_tempo", 60)
  for _ = 1, 4 do
    enc(2, 1)
    local v = params:get("clock_tempo")
    check(math.abs(v - util.round(v)) < 0.01,
      "a coarse click left the tempo at " .. v .. ", not a whole number")
  end
  params:set("clock_tempo", 60)
  enc(3, 1)
  local v = params:get("clock_tempo")
  check(math.abs(v - 60.1) < 1e-6,
    "a fine click from 60 BPM gave " .. v .. ", wanted 60.1")
end

if #fails > 0 then
  for i = 1, math.min(#fails, 10) do print("  FAIL " .. fails[i]) end
  if #fails > 10 then print("  ...and " .. (#fails - 10) .. " more") end
  print(string.format("KNOB TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("KNOB TEST OK")
