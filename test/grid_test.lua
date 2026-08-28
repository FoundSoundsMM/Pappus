-- The grid's value rows must reach both ENDS of the parameter.
--
-- Mick: "the grid controls on kuluri at their minimum is not representative
-- of 0 on the parameters, same for Modni and Hallat." They were mapped
-- (x - 0.5) / nc - cell CENTRES - so on a sixteen-wide grid the leftmost key
-- set 0.031 of the range and the rightmost 0.969. A row that never reaches
-- zero cannot be switched off from the grid.
--
-- PAGES and the page cursor are locals inside pappus.lua, so this discovers
-- the mapping instead of hardcoding it: snapshot every parameter, press one
-- key, and see which one moved. That cannot drift out of step with the
-- script the way a hand-written table would.

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local function snapshot()
  local s = {}
  for _, id in ipairs(params.order) do s[id] = params:get(id) end
  return s
end

local function moved(before)
  for _, id in ipairs(params.order) do
    if params:get(id) ~= before[id] then return id end
  end
  return nil
end

local function bounds(id)
  local p = params:lookup_param(id)
  if p.options then return 1, #p.options end
  if p.controlspec then return p.controlspec.minval, p.controlspec.maxval end
  return p.min, p.max
end

local function press(x, y)
  mock.grid.key(x, y, 1)
  mock.grid.key(x, y, 0)
end

-- Pages do NOT wrap: K3 stops on the last one. A walk that only ever presses
-- K3 therefore parks on TRIQ, which has no value rows, and every assertion
-- after that quietly tests nothing. Long K2 is the way back to page 1.
-- Pages live in two LANES now (audio, and the modulators stacked underneath),
-- so K3 alone never reaches a MODNI page. Walk the page list directly.
local PAGE_N = #pappus.pages
local walk = 0
local function next_page()
  walk = (walk % PAGE_N) + 1
  goto_page_index(walk)
end
local function home()
  walk = 1
  goto_page_index(1)
end

local checked = 0
home()
for _ = 1, PAGE_N do
  for width = 16, 8, -8 do
    mock.grid.cols = width
    for row = 1, 8 do
      -- which param does this row own? press the far right, which is the
      -- one column most likely to differ from wherever the row already is.
      local before = snapshot()
      press(width, row)
      local id = moved(before)
      if id == nil then
        -- either the row owns nothing, or it was already at maximum
        local probe = snapshot()
        press(1, row)
        id = moved(probe)
        if id then press(width, row) end
      end
      if id then
        local lo, hi = bounds(id)
        local span = math.abs(hi - lo)
        local tol = math.max(span * 1e-6, 1e-9)
        -- Not every page maps a row to a value. The delay page's rows are tap
        -- editors and a press there can nudge s_euclid as a side effect, which
        -- looks identical to "row owns a param" from out here. A value row is
        -- monotonic across the width; anything else is skipped, not failed.
        press(1, row)
        local a = params:get(id)
        press(math.max(2, math.floor(width / 2)), row)
        local b = params:get(id)
        press(width, row)
        local c = params:get(id)
        if not (a < b and b < c) then goto continue end
        check(math.abs(params:get(id) - hi) < tol,
          string.format("%s w%d col %d gave %.6f, max is %.6f",
            id, width, width, params:get(id), hi))
        press(1, row)
        check(math.abs(params:get(id) - lo) < tol,
          string.format("%s w%d col 1 gave %.6f, min is %.6f",
            id, width, params:get(id), lo))
        -- a row that spans zero has to be able to come back to it
        if lo < 0 and hi > 0 then
          local hit = false
          for x = 1, width do
            press(x, row)
            if math.abs(params:get(id)) < tol then hit = true end
          end
          check(hit, string.format(
            "%s w%d: no column returns it to zero", id, width))
        end
        checked = checked + 1
      end
      ::continue::
    end
  end
  mock.grid.cols = 16
  next_page()
end
home()

check(checked > 30, "only " .. checked .. " rows exercised - did the walk work?")

-- ...and the BAR has to end under the key you pressed. The draw used the old
-- cell-centre mapping too, so it read a column short of your finger.
do
  local lit = {}
  local real = mock.grid.led
  mock.grid.led = function(self, x, y, l)
    real(self, x, y, l)
    if l >= 8 then lit[y] = math.max(lit[y] or 0, x) end
  end
  mock.grid.cols = 16
  for _ = 1, PAGE_N do
    for row = 1, 8 do
      for _, col in ipairs({ 4, 9, 16 }) do
        local before = snapshot()
        press(col, row)
        local id = moved(before)
        if id then
          local p = params:lookup_param(id)
          -- option rows show which option is selected, not which
          -- column was pressed, and bipolar rows draw from centre
          local skip = p.options ~= nil
            or (p.controlspec and p.controlspec.minval < 0)
          lit = {}
          grid_redraw()
          if not skip and lit[row] then
            check(lit[row] == col, string.format(
              "%s: pressed col %d, bar ends at %d", id, col, lit[row]))
          end
        end
      end
    end
    next_page()
  end
  mock.grid.led = real
end

-- Every cell parameter must START inside its own range. add_control does not
-- clamp its default, so a default computed from a count (LFO start phases were
-- (i - 1) * 0.25) silently walks off the end when the count grows, and the
-- first thing that notices is the grid drawing past column 16.
do
  local mock2 = require("mock_norns")
  for _, pg in ipairs(pappus.pages) do
    for _, c in ipairs(pg.cells) do
      for _, id in ipairs({ c.id, c.mode, c.alt }) do
        local p = params:lookup_param(id)
        if p and p.controlspec then
          local d = p.controlspec.default
          check(d >= p.controlspec.minval and d <= p.controlspec.maxval,
            string.format("%s default %.4f is outside %.4f..%.4f",
              id, d, p.controlspec.minval, p.controlspec.maxval))
        end
      end
    end
  end
end

if #fails > 0 then
  local seen = {}
  for _, f in ipairs(fails) do
    if not seen[f] then print("  FAIL " .. f); seen[f] = true end
  end
  print(string.format("GRID TEST FAILED (%d)", #fails))
  os.exit(1)
end
print(string.format("GRID TEST OK  (%d rows)", checked))
