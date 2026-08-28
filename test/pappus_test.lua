-- The PAPPUS page: the scene at the end of the lane.
--
--   1. IT IS THE LAST PAGE, and it is reachable by paging there like anything
--      else.
--   2. ONE SEED PER GRAIN. Not one per voice - the air fills at the rate the
--      instrument is playing - so more voices lit must put more seeds in the
--      air over the same stretch of time. If they were per voice the two
--      counts would come out the same.
--   3. IT ONLY LIVES ON ITS OWN PAGE. Nothing is seeded and nothing is drawn
--      anywhere else, and leaving empties the air so that coming back is a
--      clear sky rather than whatever was left over.
--   4. A QUIET INSTRUMENT IS NOT A BLANK SCREEN. With no grains at all, a few
--      seeds still drift in - a page that renders nothing is indistinguishable
--      from one that is broken.

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local m = mock.metros[1]
local function run(seconds, amp)
  for _ = 1, math.floor(seconds * 25) do
    for name, p in pairs(mock.polls) do
      if p.callback then p.callback(amp or 0.3) end
    end
    mock.advance_time(1 / 25)
    m.event()
  end
end

-- Count what reaches the screen: every seed draws a crown and a stalk, and
-- each of those is one stroke. The particle list itself is a local inside the
-- page's own scope and staying out of it is the point - this measures what a
-- person would actually see.
local function strokes()
  mock.ops = {}; mock.recording = true
  redraw()
  mock.recording = false
  local n = 0
  for _, o in ipairs(mock.ops) do if o.op == "stroke" then n = n + 1 end end
  return n
end

-- 1. last in the lane
local PGI
for i, pg in ipairs(pappus.pages) do
  if pg.kind == "pappus" then PGI = i end
end
assert(PGI, "there is no PAPPUS page")
local audio_last
for i, pg in ipairs(pappus.pages) do
  if pg.kind ~= "magna" and pg.kind ~= "envmod" then audio_last = i end
end
check(PGI == audio_last,
  "PAPPUS is page " .. PGI .. " but the audio lane ends at " .. audio_last)

goto_page_index(PGI)
check(current_page() == PGI, "could not get to the PAPPUS page")
local ppage = current_page()
key(3, 1); key(3, 0)
check(current_page() == ppage, "K3 paged off the end past PAPPUS")

-- 2. one seed per grain
params:set("m_src", 2)
-- 1/4 at sixty: one grain per voice per second. Slow enough that neither
-- case saturates the sky - if both filled it to the cap the count could not
-- tell them apart and the test would pass on a bug.
params:set("m_rate", 5)

local function fill(nv)
  goto_page_index(1)                    -- leave: the air empties
  run(0.2)
  for i = 1, 8 do                       -- all eight on...
    if not gr(1)[i].on then mock.grid.key(1, i, 1); mock.grid.key(1, i, 0) end
  end
  for i = nv + 1, 8 do                  -- ...then back down to nv
    mock.grid.key(1, i, 1); mock.grid.key(1, i, 0)
  end
  goto_page_index(PGI)
  run(2.2)
  return strokes()
end

local one = fill(1)
local many = fill(8)
print(string.format("  strokes after 2.2s: one voice %d, eight voices %d",
  one, many))
check(one > 0, "a playing instrument put nothing on the page at all")
check(many > (one * 2),
  ("eight voices put %d strokes in the air against one voice's %d - nothing "
    .. "like eight times as many, so seeds are not being made per GRAIN"
  ):format(many, one))

-- 3. it only lives here
goto_page_index(PGI)
run(2)
check(strokes() > 0, "the page drew nothing while it was the page")
goto_page_index(1)
run(1)
mock.ops = {}; mock.recording = true; redraw(); mock.recording = false
local texts = 0
for _, o in ipairs(mock.ops) do
  if o.op == "text" or o.op == "text_right" then texts = texts + 1 end
end
check(texts > 0, "the ordinary page drew no text, so the scene is on top of it")

-- ...and coming back is a clear sky, not what was left behind
goto_page_index(PGI)
local arrive = strokes()
check(arrive == 0,
  "arriving on the page found " .. arrive .. " strokes already in the air")

-- 4. quiet is not blank. Every voice off, nothing firing, and it still
--    eventually has something in it.
for i = 1, 8 do
  if gr(1)[i].on then mock.grid.key(1, i, 1); mock.grid.key(1, i, 0) end
end
params:set("m_src", 1)
goto_page_index(PGI)
run(14, 0.0)
check(strokes() > 0,
  "a silent instrument left the page completely blank, which reads as broken")

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("PAPPUS TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("PAPPUS TEST OK")
