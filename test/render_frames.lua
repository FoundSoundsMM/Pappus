-- Drive the real script and dump the exact screen calls for a set of states.
package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()
local m = mock.metros[1]
local mmod = mock.metros[2]

local tphase = 0
local function settle(frames, outamp, vary)
  for _ = 1, frames do
    tphase = tphase + 0.04
    local inamp = 0.1
    if vary then
      inamp = 0.05 + (0.30 * math.abs(math.sin(tphase * 1.7))
              * (0.4 + (0.6 * math.abs(math.sin(tphase * 0.23)))))
    end
    for name, p in pairs(mock.polls) do
      if p.callback then p.callback(name:find("out") and outamp or inamp) end
    end
    mock.advance_time(1 / 25)
    -- the modulation metro runs faster than the display; fire it in step or
    -- the LFO lanes render as flat lines that look like a bug in the drawing
    for _ = 1, 2 do if mmod then mmod.event() end end
    m.event()
  end
end

-- back to page one first, and "back" has to cover the WHOLE list: this was a
-- fixed five presses, which stopped being enough the moment MODNI grew, and
-- every later shot was then taken on the wrong page while still being labelled
-- with the right one.
local function goto_page(n)
  assert(goto_page_index(n), "no page " .. n)
end

-- Shots used to name pages by INDEX. Two granulators inserted two pages in
-- the middle and every index after them pointed at the wrong page - the
-- frames still rendered, they were just labelled as something they were not.
-- PG maps the old numbering onto whatever the page list actually is now.
local PG = {}
do
  local seen = {}
  for i, pg in ipairs(pappus.pages) do
    local key = pg.kind .. tostring(pg.sw or "")
    if not seen[key] then seen[key] = i end
  end
  PG = {
    seen["grain1"], seen["grain21"],          -- GRAINSWARM 1, pages 1 and 2
    seen["grain2"], seen["grain22"],          -- GRAINSWARM 2, pages 1 and 2
    seen["spettru"], seen["delay"], seen["shader"],
    seen["magna"], seen["envmod"], seen["hallat"],
    seen["ritratt"],
  }
end

local out = io.open("/tmp/frames.json", "w")
out:write("[\n")
local first = true
local function shot(name)
  mock.ops = {}; mock.recording = true; redraw(); mock.recording = false
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

-- page 1
-- press AND release: an unreleased grid key now hands the encoders to that
-- voice's level and probability, so leaving one down silently swallows every
-- enc() the rest of this script makes
local function gtap(x, y) mock.grid.key(x, y, 1); mock.grid.key(x, y, 0) end
-- SRC defaults to OFF, so without this every waveform shot below would be a
-- flat line reading NO INPUT - which is correct, and is not what these frames
-- are for. There is a shot of that state further down.
params:set("m_src", 2)
gtap(1, 1); gtap(8, 2); gtap(13, 2)
-- the waveform IS cell zero now, and the page opens on it
assert(current_cell() == 0, "GRAINSWARM did not open on the visualiser")
gtap(5, 3); gtap(16, 3); gtap(11, 4)
params:set("m_spray", 0.35)
settle(230, 0.3, true)
shot("1 GRAINSWARM grains")

-- MODNI markers on the page being modulated: a caret over the label marks
-- the destination, a bright tick rides the bar at the value actually sent
do
  local pd = params:lookup_param("lfo1_d1")
  local function dest(name)
    for i, n in ipairs(pd.options) do if n == name then return i end end
  end
  params:set("lfo1_shape", 3); params:set("lfo1_rate", 20)
  params:set("lfo1_d1", dest("G1.SPRAY")); params:set("lfo1_a1", 0.9)
  params:set("lfo2_d1", dest("G1.SIZE"));  params:set("lfo2_a1", -0.7)
  params:set("lfo3_d1", dest("G1.SWARM")); params:set("lfo3_a1", 0.6)
  params:set("lfo2_rate", 35)
  params:set("m_rate", 7); params:set("m_spray", 0.5)
  for shot_i = 1, 2 do
    settle(18, 0.4, true)
    shot("1 GRAINSWARM modulated " .. shot_i)
  end
  params:set("lfo1_a1", 0); params:set("lfo2_a1", 0); params:set("lfo3_a1", 0)
  params:set("lfo1_d1", 1); params:set("lfo2_d1", 1); params:set("lfo3_d1", 1)
  params:set("m_spray", 0.35); params:set("m_rate", 3)
end

-- grain dots at a rate where there are actually some to see
params:set("m_rate", 7)                 -- 1/16
params:set("m_voices", 5); params:set("m_vspread", 0.5)
params:set("m_swarm", 0.5)
settle(90, 0.35, true); shot("1 GRAINSWARM dots busy")
params:set("m_win_start", 0.3); params:set("m_win_end", 0.75)
settle(40, 0.35, true); shot("1 GRAINSWARM dots + window")
params:set("m_win_start", 0); params:set("m_win_end", 1)
params:set("m_swarm", 0); params:set("m_voices", 1); params:set("m_rate", 3)

-- the header case that collided: long page name, long mode, long value
for _ = 1, 12 do enc(1, -1) end
for _ = 2, 6 do enc(1, 1) end          -- select SLIDE
params:set("m_scan_mode", 2)
settle(10, 0.3, true); shot("1 GRAINSWARM header, SLIDE POS")
params:set("m_scan_mode", 3)
settle(10, 0.3, true); shot("1 GRAINSWARM header, SLIDE D.SYNC")
params:set("m_scan_mode", 1)
for _ = 1, 12 do enc(1, -1) end

-- page 2, BAQBAQ 2/2
goto_page(PG[2])
params:set("m_buflen", 12); params:set("m_strum", 0.6)
params:set("m_voices", 6); params:set("m_vspread", 0.55)
params:set("m_scale", 2)
settle(20, 0.3, true); shot("2 GRAINSWARM 2/2 voices+spread")

-- the euclid grid: it replaces the waveform only while EUCLID / LEN / PHASE
-- is the selected cell, so the frames have to select it first
do
  -- PAGES is a local in the script, so the cell index is written out here:
  -- 1 BUFFR  2 WIN.ST  3 WIN.EN  4 VOICES  5 V.SPRD  6 EUCLID  7 LEN  8 PHASE
  local function selcell(n)
    for _ = 1, 12 do enc(1, -1) end
    for _ = 2, n do enc(1, 1) end
  end
  params:set("m_voices", 8)
  selcell(6)
  params:set("m_euclid", 0); params:set("m_strum", 0.5)
  settle(20, 0.3, true); shot("2 EUCLID off (PHASE rakes)")
  params:set("m_euclid", 0.5); params:set("m_elen", 8)
  params:set("m_strum", 0)
  settle(20, 0.3, true); shot("2 EUCLID 4/8, PHASE 0")
  params:set("m_strum", 0.15)
  settle(20, 0.3, true); shot("2 EUCLID 4/8, PHASE rot 1")
  -- consecutive frames, to catch the playhead moving and the flash fading.
  -- A fast RATE on purpose: at 1/1 a grain lands every two seconds and six
  -- frames apart is the same picture six times.
  params:set("m_rate", 7)
  for q = 1, 6 do settle(3, 0.35, true); shot("2 EUCLID step " .. q) end
  params:set("m_rate", 3)
  params:set("m_elen", 13); params:set("m_euclid", 0.4)
  params:set("m_strum", 0.3)
  settle(20, 0.3, true); shot("2 EUCLID 5/13, rotated")
  params:set("m_euclid", 0); params:set("m_strum", 0); params:set("m_elen", 8)
  params:set("m_voices", 6)
  selcell(1)
end
params:set("m_win_start", 0.25); params:set("m_win_end", 0.7)
settle(120, 0.3, true); shot("2 GRAINSWARM 2/2 window")

params:set("m_win_start", 0); params:set("m_win_end", 1)
settle(30, 0.3, true); shot("2 GRAINSWARM 2/2 full window")

-- page 3, FILTERBANK
params:set("m_voices", 5); params:set("m_vspread", 0.6)
-- GRAINSWARM 2, its own pages. The two things that only exist here: the RATE
-- cell, which is decoupled by default and shows the chain mark only when set
-- to LINK, and the waveform as cell zero carrying the source.
goto_page(PG[3])
params:set("n_src", 2)
local function gtap2(x, y) mock.grid.key(x, y, 1); mock.grid.key(x, y, 0) end
gtap2(4, 1); gtap2(11, 2)
settle(60, 0.3, true); shot("3 GR2 waveform selected")
assert(goto_cell(2), "could not reach GRAINSWARM 2's RATE cell")
settle(8, 0.3, true); shot("3 GR2 RATE own division")
params:set("n_rate_div", 11)            -- LINK: the last entry
settle(8, 0.3, true); shot("3 GR2 RATE linked to GS1")
params:set("n_rate_div", 5)
assert(goto_cell(0), "could not get back to the visualiser")
params:set("n_src", 1)
settle(8, 0.3, true); shot("3 GR2 no input")
params:set("n_src", 3)
settle(8, 0.3, true); shot("3 GR2 mono left")
params:set("n_src", 2)

goto_page(PG[5])
local FF = {
  { name = "3 FILTERBANK default" },
  { name = "3 FILTERBANK narrow window", p_bw = 0.7 },
  { name = "3 FILTERBANK wide, low",     p_bw = 5, p_centre = 180 },
  { name = "3 FILTERBANK 2 partials",    p_partials = 2 },
  { name = "3 FILTERBANK morph bell",    p_morph = 0.8 },
  { name = "3 FILTERBANK morph gong",    p_morph = -0.8 },
  { name = "3 FILTERBANK skew high",     p_skew = 0.9 },
  { name = "3 FILTERBANK skew low",      p_skew = -0.9 },
  { name = "3 FILTERBANK long ring",     p_reso = 0.95 },
  { name = "3 FILTERBANK short ring",    p_reso = 0.05 },
  { name = "3 FILTERBANK shape fold",    p_shape = 0.8, p_shape_mode = 2 },
  { name = "3 FILTERBANK frozen",        p_freeze = 2 },
  { name = "3 FILTERBANK free root",     p_root = 2 },
  { name = "3 FILTERBANK free, low",     p_root = 2, p_centre = 120 },
}
for _, f in ipairs(FF) do
  params:set("p_centre", f.p_centre or 700)
  params:set("p_bw", f.p_bw or 2.5)
  params:set("p_partials", f.p_partials or 6)
  params:set("p_morph", f.p_morph or 0)
  params:set("p_skew", f.p_skew or 0)
  params:set("p_reso", f.p_reso or 0.35)
  params:set("p_shape", f.p_shape or 0)
  params:set("p_shape_mode", f.p_shape_mode or 1)
  params:set("p_freeze", f.p_freeze or 1)
  params:set("p_root", f.p_root or 1)
  params:set("p_wet", 0.8)
  settle(40, 0.3, true)
  shot(f.name)
  settle(1, 0.3, true)
  if f.name == "3 FILTERBANK default" then
    for q = 1, 3 do settle(1, 0.3, true); shot("3 FILTERBANK strings " .. q) end
  end
end
params:set("p_wet", 0); params:set("p_freeze", 1)
params:set("p_root", 1)

-- page 4, DELAY
goto_page(PG[6])
params:set("s_euclid", 0.45); params:set("s_spread", 0.5)
params:set("s_feedback", 0.2)
settle(60, 0.3, true); shot("4 DELAY euclid, fb 0.2")

params:set("s_feedback", 0.85); params:set("s_spread", 1.0)
settle(40, 0.35, true); shot("4 DELAY fb 0.85, spread 1")

params:set("s_euclid", 1.0); params:set("s_steps", 3)  -- 9 steps
settle(40, 0.3, true); shot("4 DELAY dense, 9 steps")

params:set("s_hold", 2)
settle(30, 0.3, true); shot("4 DELAY hold")
params:set("s_hold", 1)

params:set("s_euclid", 0); params:set("s_steps", 1)
settle(30, 0.3, true); shot("4 DELAY manual taps")

-- page 5, SHADER
goto_page(PG[7])
local FR = {
  { name = "5 COLOUR clean",        amp = 0.35 },
  { name = "5 COLOUR drive 1",      amp = 0.35, drive = 1.0 },
  { name = "5 COLOUR crush 1",      amp = 0.4,  crush = 1.0 },
  { name = "5 COLOUR noise 1",      amp = 0.45, noise = 1.0 },
  { name = "5 COLOUR loss 0.6",      amp = 0.35, loss = 0.6 },
  { name = "5 COLOUR loss 1.0",      amp = 0.35, loss = 1.0 },
}
for _, f in ipairs(FR) do
  for _, id in ipairs({ "drive", "crush", "loss", "noise" }) do
    params:set(id, f[id] or 0)
  end
  settle(45, f.amp)
  shot(f.name)
end

-- COLOUR: the camera pulls back as voices come in
params:set("m_rate", 7)
params:set("m_vspread", 0.45)
for _, nv in ipairs({ 1, 2, 4, 8 }) do
  params:set("m_voices", nv)
  params:set("drive", 0); params:set("crush", 0); params:set("noise", 0)
  params:set("loss", 0); params:set("m_swarm", 0)
  settle(40, 0.45, true)
  shot(string.format("5 COLOUR %d voice", nv))
end

-- and the deformations, at four voices
params:set("m_voices", 4)
for _, f in ipairs({
  { name = "5 COLOUR drive max (diamond)", drive = 1.0 },
  { name = "5 COLOUR crush",  crush = 0.8 },
  { name = "5 COLOUR noise + short ndec", noise = 1.0, ndec = 0.02 },
  { name = "5 COLOUR noise + long ndec",  noise = 1.0, ndec = 3.5 },
  { name = "5 COLOUR swarm (unison)", swarm = 0.8 },
  { name = "5 COLOUR swarm (oct)",    swarm = 0.8, swmode = 3 },
  { name = "5 COLOUR tilt - (dark fill)", loss = 0.6 },
  { name = "5 COLOUR tilt + (thin fill)", loss = 1.0 },
  { name = "5 COLOUR comp 1 (squeeze)",   comp = 1.0 },
}) do
  params:set("drive", f.drive or 0); params:set("crush", f.crush or 0)
  params:set("noise", f.noise or 0); params:set("loss", f.loss or 0)
  params:set("m_swarm", f.swarm or 0); params:set("mx_comp", f.comp or 0)
  params:set("m_swarm_mode", f.swmode or 1)
  params:set("noise_decay", f.ndec or 0.25)
  settle(40, 0.45, true)
  shot(f.name)
end
params:set("m_swarm", 0); params:set("loss", 0); params:set("mx_comp", 0.2)
params:set("m_swarm_mode", 1)
params:set("noise_decay", 0.25)

-- LOSS: the fill should be dithered, not eaten into arcs.
-- Clear TILT first: the frame loop above leaves it at +1, which hollows every
-- circle out and makes the dither impossible to read.
params:set("loss", 0); params:set("drive", 0); params:set("noise", 0)
for _, cv in ipairs({ 0.3, 0.7, 1.0 }) do
  params:set("loss", cv)
  settle(40, 0.4)
  shot(string.format("5 COLOUR loss %.1f", cv))
end
params:set("loss", 0)

-- page 6, MAGNA
goto_page(PG[8])
local ML = {
  { name = "6 MODNI sine + saw",  s1 = 3, s2 = 5 },
  { name = "6 MODNI S&H hard",    s1 = 1, s2 = 1, ph = 0.35 },
  { name = "6 MODNI S&H soft/tri", s1 = 2, s2 = 4 },
}
for _, f in ipairs(ML) do
  params:set("lfo1_shape", f.s1); params:set("lfo2_shape", f.s2)
  params:set("lfo1_rate", 30); params:set("lfo2_rate", 62)
  params:set("lfo2_phase", f.ph or 0.25)
  params:set("lfo1_a1", 0.8); params:set("lfo1_d1", 3)
  params:set("lfo2_a1", -0.5); params:set("lfo2_d1", 12)
  params:set("lfo3_a1", 0.9); params:set("lfo3_d1", 20)
  settle(35, 0.3, true)
  shot(f.name)
end
params:set("lfo1_a1", 0); params:set("lfo2_a1", 0); params:set("lfo3_a1", 0)
params:set("lfo1_d1", 1); params:set("lfo2_d1", 1); params:set("lfo3_d1", 1)

-- MACHINE sliding in. Shape SINE has no held value to lock so the cell is
-- away; switching LFO 1 to STEP brings it out over about a quarter second,
-- compressing RATE, PHASE and DEST as it comes.
goto_page(PG[8])
params:set("lfo1_shape", 3); params:set("lfo2_shape", 3)
params:set("lfo1_rate", 40)
settle(30, 0.3, true); shot("6 MACHINE away (sine)")
params:set("lfo1_shape", 1)
for i = 1, 5 do
  settle(1, 0.3, true)
  shot("6 MACHINE sliding " .. i)
end
settle(30, 0.3, true)
params:set("lfo1_machine", 0.65)
settle(4, 0.3, true); shot("6 MACHINE out, LOCK 65%")
params:set("lfo1_machine", 1)
settle(4, 0.3, true); shot("6 MACHINE locked")
params:set("lfo1_machine", 0); params:set("lfo1_shape", 3)
settle(30, 0.3, true)

-- a later LFO pair, to prove the page/lane pairing follows the page
goto_page(PG[8] + 3)
params:set("lfo7_shape", 4); params:set("lfo8_shape", 2)
params:set("lfo7_rate", 40); params:set("lfo8_rate", 70)
params:set("lfo7_a1", 0.7); params:set("lfo7_d1", 5)
params:set("lfo7_a2", -0.4); params:set("lfo7_d2", 9)
params:set("lfo8_a1", -0.9); params:set("lfo8_d1", 14)
settle(35, 0.3, true); shot("9 MODNI 7-8")
params:set("lfo7_a1", 0); params:set("lfo8_a1", 0); params:set("lfo7_a2", 0)
params:set("lfo7_d1", 1); params:set("lfo8_d1", 1); params:set("lfo7_d2", 1)

-- MODNI ENV
goto_page(PG[9])
params:set("env_sens", 8); params:set("env_atk", 0.01); params:set("env_rel", 0.4)
params:set("env_a1", 0.8); params:set("env_d1", 12)
params:set("env_a2", -0.6); params:set("env_d2", 20)
settle(60, 0.4, true); shot("10 MODNI ENV follower")
params:set("env_a1", 0); params:set("env_a2", 0)
params:set("env_d1", 1); params:set("env_d2", 1)

-- SIGNAL
goto_page(PG[10])
settle(30, 0.35, true); shot("11 SIGNAL flat")

params:set("mx_in", 4); params:set("mx_comp", 0.4)
params:set("p_in1", 0.9); params:set("p_in2", 0.2)
params:set("k_in1", 0.0); params:set("o_in1", 0.8)
settle(30, 0.5, true); shot("11 SIGNAL sends up, pre-fader")

params:set("mx_limit", -12)
settle(30, 0.8, true); shot("11 SIGNAL hitting the ceiling")

-- SNAPSHOTS
goto_page(PG[11])
settle(20, 0.3, true); shot("12 SNAPSHOTS empty")
params:set("drive", 0.2)
-- the hold, caught mid-gesture: the square fills WITH the finger
mock.grid.key(5, 3, 1)
for q = 1, 4 do
  mock.advance_time(0.14)
  settle(1, 0.3, true)
  shot("12 SNAPSHOTS holding " .. q)
end
mock.advance_time(0.2)
settle(1, 0.3, true); shot("12 SNAPSHOTS committed")
for q = 1, 3 do settle(2, 0.3, true); shot("12 SNAPSHOTS pulse " .. q) end
mock.grid.key(5, 3, 0)
settle(20, 0.3, true)
-- a hold that is abandoned half way puts itself back
mock.grid.key(9, 5, 1)
mock.advance_time(0.25); settle(1, 0.3, true); shot("12 SNAPSHOTS abandoning")
mock.grid.key(9, 5, 0)
settle(3, 0.3, true); shot("12 SNAPSHOTS abandoned")
settle(20, 0.3, true); shot("12 SNAPSHOTS one saved")

-- SIGNAL: the routing wireframe, which is the page TRIQ turned into
goto_page(PG[10])
params:set("p_in1", 0.9); params:set("p_in2", 0.2)
params:set("k_in1", 0.0); params:set("k_in2", 0.8)
params:set("o_in1", 0.8); params:set("o_in2", 0.0)
settle(20, 0.4, true); shot("10 SIGNAL routing split")
params:set("clock_source", 3)                -- link: BPM goes EXT
settle(6, 0.4, true); shot("10 SIGNAL BPM ext")
params:set("clock_source", 1)
-- ...and with GRAINSWARM 1 sent straight past everything
params:set("p_in1", 0); params:set("s_in1", 0); params:set("k_in1", 0)
params:set("o_in1", 1)
settle(14, 0.4, true); shot("10 SIGNAL GR1 direct to out")
-- consecutive frames, to catch the wires actually flowing
params:set("p_in1", 0.9); params:set("p_in2", 0.5)
params:set("k_in1", 0.7); params:set("o_in2", 0.6)
for q = 1, 3 do settle(2, 0.4, true); shot("10 SIGNAL flow " .. q) end

-- the PAPPUS scene, at the end of the lane
do
  local PP
  for i, pg in ipairs(pappus.pages) do if pg.kind == "pappus" then PP = i end end
  goto_page(PP)
  params:set("m_rate", 7); params:set("m_voices", 6); params:set("m_src", 2)
  settle(120, 0.4, true); shot("13 PAPPUS")
  settle(30, 0.4, true); shot("13 PAPPUS 2")
  params:set("drive", 0.9)
  settle(40, 0.5, true); shot("13 PAPPUS drive")
  params:set("drive", 0); params:set("loss", 0.6)
  settle(40, 0.4, true); shot("13 PAPPUS loss")
  params:set("loss", 0); params:set("k_wow", 0.9)
  settle(60, 0.4, true); shot("13 PAPPUS wow")
  params:set("k_wow", 0)
end

out:write("\n]\n")
out:close()
print("wrote /tmp/frames.json")
