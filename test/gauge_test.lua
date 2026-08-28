-- The segment gauge, measured rather than looked at.
--
-- "Every segment is identical" is an arithmetic claim, and the first version
-- failed it invisibly: dividing a 24 px cell into eight gave a pitch of 3.125,
-- so one segment in each row straddled a pixel boundary the others did not and
-- rendered a pixel wider. On a 128x64 screen that is the difference between a
-- readout and a smudge, and it is not something you can be sure of by looking.
--
-- So: walk every page, every cell, and check the rectangles that reach the
-- screen.
--
--   1. every segment in a gauge is the SAME WIDTH
--   2. they sit on an EVEN PITCH, and both are whole pixels
--   3. they start on a whole pixel - which MODNI is the test of, because its
--      three columns are 42.67 px wide and its cells do not begin on one
--   4. a bipolar cell draws its CENTRE RULE, whatever its value, because at
--      rest it lights no segments at all and would otherwise be identical to
--      a parameter that is simply off

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

-- the gauge rows: the bar sits at the bottom of each cell, four pixels tall
local function gauge_rects(ops)
  local out = {}
  for _, o in ipairs(ops) do
    if o.op == "rect" then
      local x, y, w, h = table.unpack(o.args)
      -- height 4 is a full gauge, 2 is one track of a dual cell; anything
      -- else is a label block, a modulation mark or the centre rule
      if (h == 4 or h == 2) and w > 0 and w < 12 then
        out[#out + 1] = { x = x, y = y, w = w, h = h }
      end
    end
  end
  return out
end

-- A row of four cells is four separate gauges and their pitches are only
-- comparable within one cell, so the rectangles have to be split back into
-- cells. NOT by dividing x by the column width - MODNI's columns are 42.67 px
-- and MODNI ENV's are different again, and getting that wrong makes the test
-- report a fault in the drawing that is really a fault in the test. Split on
-- the GAP instead: inside a gauge the segments are one pitch apart, and the
-- jump to the next cell is always several.
local function gauges(rects)
  table.sort(rects, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  local out, cur, prev = {}, nil, nil
  for _, r in ipairs(rects) do
    if not prev or r.y ~= prev.y or (r.x - prev.x) > ((prev.w + 1) * 1.8) then
      cur = {}
      out[#out + 1] = cur
    end
    cur[#cur + 1] = r
    prev = r
  end
  return out
end

local checked = 0
for pi = 1, #pappus.pages do
  goto_page_index(pi)
  local pg = pappus.pages[pi]
  for ci = 1, #pg.cells do
    if goto_cell(ci) then
      mock.ops = {}; mock.recording = true; redraw(); mock.recording = false
      for _, rs in ipairs(gauges(gauge_rects(mock.ops))) do
        if #rs >= 3 then
          checked = checked + 1
          table.sort(rs, function(a, b) return a.x < b.x end)
          local w0 = rs[1].w
          for _, r in ipairs(rs) do
            check(r.w == w0, string.format(
              "%s cell %d: a segment is %g px wide against the first one's %g",
              pg.name, ci, r.w, w0))
            check(r.x == math.floor(r.x), string.format(
              "%s cell %d: a segment starts at x=%g, which is not a pixel",
              pg.name, ci, r.x))
          end
          local pitch = rs[2].x - rs[1].x
          check(pitch == math.floor(pitch), string.format(
            "%s cell %d: the pitch is %g px, which is not a whole number",
            pg.name, ci, pitch))
          for k = 2, #rs do
            check((rs[k].x - rs[k - 1].x) == pitch, string.format(
              "%s cell %d: segment %d is %g px from its neighbour, the first "
              .. "pair are %g apart", pg.name, ci, k, rs[k].x - rs[k - 1].x,
              pitch))
          end
        end
      end
    end
  end
end
check(checked > 40, "only found " .. checked .. " gauges to measure")
print("  gauges measured: " .. checked)

-- 4. the centre rule on a bipolar cell, at rest and off-centre alike
local function has_rule(pgi, ci)
  goto_page_index(pgi)
  assert(goto_cell(ci))
  mock.ops = {}; mock.recording = true; redraw(); mock.recording = false
  local rects = {}
  for _, o in ipairs(mock.ops) do
    if o.op == "rect" then
      local x, y, w, h = table.unpack(o.args)
      -- one pixel wide and taller than the gauge: that is the rule and
      -- nothing else on the row is shaped like it
      if w == 1 and h == 6 then rects[#rects + 1] = { x = x, y = y } end
    end
  end
  return #rects > 0
end

local BPG, BPC
for i, pg in ipairs(pappus.pages) do
  for j, c in ipairs(pg.cells) do
    if c.bipolar and not BPG then BPG, BPC = i, j end
  end
end
assert(BPG, "no bipolar cell anywhere to test")
local bcell = pappus.pages[BPG].cells[BPC]

params:set(bcell.id, 0)
check(has_rule(BPG, BPC),
  "a bipolar cell at rest drew no centre rule, so CENTRED and OFF look the "
  .. "same")
local p = params:lookup_param(bcell.id)
params:set(bcell.id, p.controlspec and p.controlspec.maxval or p.max)
check(has_rule(BPG, BPC),
  "the centre rule vanished when the parameter was moved off centre")
params:set(bcell.id, 0)

if #fails > 0 then
  for i = 1, math.min(#fails, 8) do print("  FAIL " .. fails[i]) end
  if #fails > 8 then print("  ...and " .. (#fails - 8) .. " more") end
  print(string.format("GAUGE TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("GAUGE TEST OK")
