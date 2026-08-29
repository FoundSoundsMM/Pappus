-- Four ways of drawing the parameter row, on the same pages, from the same
-- state, so they can be compared rather than described.
--
-- The layout does not move: header, picture, two rows of four. What changes is
-- what a CELL is.
--
--   0  what it is now      label + a chunky bar
--   1  value              label small and dim, THE NUMBER bright, a hairline
--                         under it for the position in range
--   2  value, inverted    the same, but the selected cell is a filled block
--                         with black text rather than a thin frame
--   3  ring               an Elektron-style dial to the left of the number
--
-- The point of 1-3 is that EVERY cell shows its value, not just the one you
-- are holding. A bar says "about two thirds"; a number says 0.62.
package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()
local m = mock.metros[1]
local mmod = mock.metros[2]

local tphase = 0
local function settle(frames, outamp)
  for _ = 1, frames do
    tphase = tphase + 0.04
    local inamp = 0.05 + (0.30 * math.abs(math.sin(tphase * 1.7)))
    for name, p in pairs(mock.polls) do
      if p.callback then p.callback(name:find("out") and outamp or inamp) end
    end
    mock.advance_time(1 / 25)
    for _ = 1, 2 do if mmod then mmod.event() end end
    m.event()
  end
end

local out = io.open("/tmp/cells.json", "w")
out:write("[\n")
local first = true
local function shot(name, fn)
  mock.ops = {}; mock.recording = true
  screen.clear(); screen.aa(0); screen.line_width(1)
  fn()
  screen.update()
  mock.recording = false
  if not first then out:write(",\n") end
  first = false
  out:write(string.format('{"name":%q,"ops":[', name))
  for i, o in ipairs(mock.ops) do
    local a = {}
    for _, v in ipairs(o.args) do
      a[#a + 1] = (type(v) == "number") and string.format("%.3f", v)
        or string.format("%q", tostring(v))
    end
    out:write(string.format('%s{"op":%q,"args":[%s]}',
      i > 1 and "," or "", o.op, table.concat(a, ",")))
  end
  out:write("]}")
end

-- ---------------------------------------------------------------------------
-- A value string for EVERY cell, not just the selected one
--
-- The real script has one of these, but it is an inline chain inside redraw()
-- that only ever runs for the cell under the cursor. Making every cell show
-- its value means lifting it out into a function - which is the one piece of
-- refactoring any of these styles needs.
-- ---------------------------------------------------------------------------

local function short_value(id)
  local p = params:lookup_param(id)
  local v = pval(id)
  if p.options then
    local s = p.options[math.floor(v)] or "?"
    return s
  end
  if id == "clock_tempo" then
    return string.format("%.1f", params:get(id))
  end
  local spec = p.controlspec
  local lo = spec and spec.minval or p.min or 0
  local hi = spec and spec.maxval or p.max or 1
  local span = math.abs(hi - lo)
  if span > 400 then
    return (v >= 1000) and string.format("%.1fk", v / 1000)
      or string.format("%d", math.floor(v + 0.5))
  elseif span > 20 then
    return string.format("%d", math.floor(v + 0.5))
  elseif span > 3 then
    return string.format("%.1f", v)
  end
  return string.format("%.2f", v):gsub("^0%.", ".")
end

local function frac_of(id)
  local p = params:lookup_param(id)
  local v = pval(id)
  if p.options then return (v - 1) / math.max(#p.options - 1, 1) end
  if p.controlspec then return p.controlspec:unmap(v) end
  local lo, hi = p.min or 0, p.max or 1
  return (hi > lo) and ((v - lo) / (hi - lo)) or 0
end

-- ---------------------------------------------------------------------------
-- the four cell renderers
-- ---------------------------------------------------------------------------

local CH = 13
local ROWS = { 37, 51 }

local function cells_of(pg)
  local list = {}
  for i = 1, #pg.cells do
    local c = pg.cells[i]
    if c then
      local ncol = pg.cols or 4
      local w = 128 / ncol
      list[#list + 1] = {
        c = c, i = i,
        x = ((i - 1) % ncol) * w, w = w,
        y = ROWS[math.floor((i - 1) / ncol) + 1],
      }
    end
  end
  return list
end

local function clip(s, avail)
  s = tostring(s)
  while #s > 0 and screen.text_extents(s) > avail do s = s:sub(1, #s - 1) end
  return s
end

-- 0: what it is now
local function style_bar(pg)
  draw_cells(pg)
end

-- 1 and 2: the number is the cell
local function style_value(pg, sel_i, invert)
  for _, e in ipairs(cells_of(pg)) do
    local on = (e.i == sel_i)
    local c = e.c
    local val = c.dual
      and string.format("%d/%d", math.floor(pval(c.id) * 100 + 0.5),
                                 math.floor(pval(c.alt) * 100 + 0.5))
      or short_value(c.id)

    if on and invert then
      screen.level(15)
      screen.rect(e.x + 1, e.y, e.w - 2, CH - 1)
      screen.fill()
    elseif on then
      screen.level(4)
      screen.rect(e.x + 1.5, e.y + 0.5, e.w - 3, CH - 2)
      screen.stroke()
    end

    local ink = (on and invert) and 0 or (on and 15 or 9)
    local dimink = (on and invert) and 0 or (on and 9 or 3)

    screen.level(dimink)
    screen.move(e.x + 3, e.y + 5)
    screen.text(clip(c.label, e.w - 6))

    screen.level(ink)
    screen.move(e.x + 3, e.y + 12)
    screen.text(clip(val, e.w - 6))

    -- the hairline: where in its range this parameter sits. One pixel, at the
    -- very bottom of the cell, because it is the thing you glance at rather
    -- than the thing you read.
    local f = c.dual and pval(c.id) or frac_of(c.id)
    screen.level((on and invert) and 0 or (on and 15 or 5))
    screen.rect(e.x + 3, e.y + CH - 1, math.max((e.w - 6) * f, 1), 1)
    screen.fill()
    if c.dual then
      screen.level((on and invert) and 0 or (on and 12 or 4))
      screen.rect(e.x + 3, e.y + CH - 2, math.max((e.w - 6) * pval(c.alt), 1), 1)
      screen.fill()
    end

    if mod_targets(c.id) then
      screen.level((on and invert) and 0 or 15)
      screen.rect(e.x + e.w - 6, e.y + 2, 3, 1)
      screen.fill()
    end
  end
end

-- 3: a dial, drawn as an arc, and the number beside it
local function arc(cx, cy, r, a0, a1, lv)
  screen.level(lv)
  local n = 14
  for i = 0, n do
    local a = a0 + ((a1 - a0) * (i / n))
    local x, y = cx + (math.cos(a) * r * 1.15), cy + (math.sin(a) * r)
    if i == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()
end

local function style_ring(pg, sel_i)
  local A0, A1 = math.pi * 0.75, math.pi * 2.25    -- 270 degrees, gap at the
  for _, e in ipairs(cells_of(pg)) do              -- bottom, like a knob
    local on = (e.i == sel_i)
    local c = e.c
    local cx, cy, r = e.x + 8, e.y + 6, 5
    local f = c.dual and pval(c.id) or frac_of(c.id)

    if on then
      screen.level(4)
      screen.rect(e.x + 1.5, e.y + 0.5, e.w - 3, CH - 2)
      screen.stroke()
    end

    arc(cx, cy, r, A0, A1, on and 4 or 2)
    if c.bipolar then
      local mid = (A0 + A1) / 2
      arc(cx, cy, r, mid, A0 + ((A1 - A0) * f), on and 15 or 9)
    else
      arc(cx, cy, r, A0, A0 + ((A1 - A0) * math.max(f, 0.001)), on and 15 or 9)
    end
    if c.dual then
      arc(cx, cy, r - 2.5, A0,
        A0 + ((A1 - A0) * math.max(pval(c.alt), 0.001)), on and 12 or 6)
    end

    local tx = e.x + 15
    screen.level(on and 9 or 3)
    screen.move(tx, e.y + 5)
    screen.text(clip(c.label, e.w - (tx - e.x) - 2))
    screen.level(on and 15 or 9)
    screen.move(tx, e.y + 12)
    screen.text(clip(c.dual
      and string.format("%d", math.floor(pval(c.id) * 100 + 0.5))
      or short_value(c.id), e.w - (tx - e.x) - 2))

    if mod_targets(c.id) then
      screen.level(15)
      screen.rect(e.x + e.w - 4, e.y + 2, 3, 1)
      screen.fill()
    end
  end
end

-- 4 and 5: the label gets its own line, and the bottom line is a small dial
-- with the number beside it. The dial is either an ARC (Elektron's) or a
-- POINTER - at eight pixels across those are genuinely different to read.
local function style_dial(pg, sel_i, pointer)
  local A0, A1 = math.pi * 0.75, math.pi * 2.25
  for _, e in ipairs(cells_of(pg)) do
    local on = (e.i == sel_i)
    local c = e.c
    local cx, cy, r = e.x + 6.5, e.y + 9.5, 3

    if on then
      screen.level(15)
      screen.rect(e.x + 1, e.y, e.w - 2, 7)
      screen.fill()
    end
    screen.level(on and 0 or 4)
    screen.move(e.x + 3, e.y + 6)
    screen.text(clip(c.label, e.w - 6))

    local f = c.dual and pval(c.id) or frac_of(c.id)
    local a = A0 + ((A1 - A0) * f)
    if pointer then
      arc(cx, cy, r, A0, A1, on and 5 or 2)
      screen.level(on and 15 or 10)
      screen.move(cx, cy)
      screen.line(cx + (math.cos(a) * r * 1.15), cy + (math.sin(a) * r))
      screen.stroke()
    else
      arc(cx, cy, r, A0, A1, on and 5 or 2)
      if c.bipolar then
        arc(cx, cy, r, (A0 + A1) / 2, a, on and 15 or 10)
      else
        arc(cx, cy, r, A0, math.max(a, A0 + 0.01), on and 15 or 10)
      end
      if c.dual then
        arc(cx, cy, r - 2, A0,
          math.max(A0 + ((A1 - A0) * pval(c.alt)), A0 + 0.01), on and 12 or 6)
      end
    end

    screen.level(on and 15 or 9)
    screen.move(e.x + e.w - 3, e.y + 12)
    screen.text_right(clip(c.dual
      and string.format("%d", math.floor(pval(c.id) * 100 + 0.5))
      or short_value(c.id), e.w - 15))

    if mod_targets(c.id) then
      screen.level(on and 0 or 15)
      screen.rect(e.x + e.w - 6, e.y + 2, 3, 1)
      screen.fill()
    end
  end
end

-- 6: the label, the number, and a SEGMENTED gauge. Eight lit-or-not blocks
-- rather than a continuous fill - it reads as a stepped readout instead of a
-- level meter, and at two pixels a segment it survives the screen.
local function style_seg(pg, sel_i)
  local NSEG = 8
  for _, e in ipairs(cells_of(pg)) do
    local on = (e.i == sel_i)
    local c = e.c

    if on then
      screen.level(15)
      screen.rect(e.x + 1, e.y, e.w - 2, 7)
      screen.fill()
    end
    screen.level(on and 0 or 4)
    screen.move(e.x + 3, e.y + 6)
    screen.text(clip(c.label, e.w - 6))

    -- no number here. The whole cell is the gauge, which is what buys it
    -- enough width to be read as steps rather than as a smear; the exact
    -- value is in the header, where it always was.
    local seg = ((e.w - 6) + 1) / NSEG
    local function gauge(f, gy, gh, lv)
      local lit = math.floor((f * NSEG) + 0.999)
      for k = 1, NSEG do
        screen.level((k <= lit) and lv or 2)
        screen.rect(e.x + 3 + ((k - 1) * seg), gy, seg - 1, gh)
        screen.fill()
      end
    end
    if c.dual then
      gauge(pval(c.id), e.y + 8, 2, on and 15 or 9)
      gauge(pval(c.alt), e.y + 11, 2, on and 12 or 6)
    else
      gauge(frac_of(c.id), e.y + 9, 4, on and 15 or 9)
    end

    if mod_targets(c.id) then
      screen.level(on and 0 or 15)
      screen.rect(e.x + e.w - 6, e.y + 2, 3, 1)
      screen.fill()
    end
  end
end

-- ---------------------------------------------------------------------------
-- the header and the picture, as they already are
-- ---------------------------------------------------------------------------

local function frame(pgi, sel_i, style)
  local pg = pappus.pages[pgi]
  assert(goto_page_index(pgi), "no such page")
  assert(goto_cell(sel_i), "no such cell")
  local c = pg.cells[sel_i]

  screen.level(15)
  screen.move(1, 7)
  screen.text(pg.name)
  screen.move(127, 7)
  screen.text_right(c and (c.dual
    and string.format("GS1 %d / GS2 %d", math.floor(pval(c.id) * 100 + 0.5),
                                         math.floor(pval(c.alt) * 100 + 0.5))
    or short_value(c.id)) or "")

  local k = pg.kind
  if k == "spettru" then draw_spettru()
  elseif k == "delay" then draw_stillel()
  elseif k == "hallat" then draw_hallat()
  elseif k == "grain" or k == "grain2" then draw_waveform()
  else draw_kuluri() end

  if style == 0 then style_bar(pg)
  elseif style == 1 then style_value(pg, sel_i, false)
  elseif style == 2 then style_value(pg, sel_i, true)
  elseif style == 3 then style_ring(pg, sel_i)
  elseif style == 4 then style_dial(pg, sel_i, false)
  elseif style == 5 then style_dial(pg, sel_i, true)
  else style_seg(pg, sel_i) end
end

-- ---------------------------------------------------------------------------

params:set("m_src", 2); params:set("n_src", 2)
local function gtap(x, y) mock.grid.key(x, y, 1); mock.grid.key(x, y, 0) end
gtap(1, 1); gtap(8, 2); gtap(13, 2); gtap(5, 3)
params:set("m_rate", 7); params:set("m_voices", 4)
params:set("p_wet", 0.8); params:set("p_freq", 0)
params:set("s_feedback", 0.4); params:set("s_euclid", 0.45)
params:set("drive", 0.62); params:set("crush", 0.3); params:set("noise", 0.45)
params:set("noise_type", 4)
do
  local pd = params:lookup_param("lfo1_d1")
  for i, n in ipairs(pd.options) do
    if n == "C.DRIVE" then params:set("lfo1_d1", i) end
  end
  params:set("lfo1_a1", 0.5); params:set("lfo1_rate", 30)
end
settle(140, 0.42)

local PG = {}
for i, pg in ipairs(pappus.pages) do
  local key = pg.kind .. tostring(pg.sw or "")
  if not PG[key] then PG[key] = i end
end

local NAMES = { [0] = "0 bar (now)", "1 value", "2 value inverted", "3 ring",
                "4 label + arc dial", "5 label + pointer dial",
                "6 label + segment gauge" }
for st = 0, 6 do
  settle(6, 0.42)
  shot(NAMES[st] .. " / COLOUR", function() frame(PG["shader"], 2, st) end)
  shot(NAMES[st] .. " / RESONATOR", function() frame(PG["spettru"], 3, st) end)
  shot(NAMES[st] .. " / DELAY", function() frame(PG["delay"], 1, st) end)
end

out:write("\n]\n")
out:close()
print("wrote /tmp/cells.json")
