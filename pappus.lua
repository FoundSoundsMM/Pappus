-- pappus
--
-- scatter to the wind
--
-- SRC picks grainswarmer's
-- input and starts OFF, so
-- select an input to hear
-- something
--
-- SOS at max freezes
-- the buffer
--
-- K2 back  K3 forward
-- K2 & K3 change lane
-- long K2 reset parameter
--   & clear modulation
-- long K3 lock / freeze /
--   hold module
-- E1 select parameter
-- E2 value
-- E3 sub-value / fine tune
--
-- grid compatible
-- (see manual)
--
-- designed by
-- Michael Manning
-- inspired by Torso S-4
--
-- heavy LLM usage
-- 100% Claude code

engine.name = "Pappus"

local g = grid.connect()

-- ---------------------------------------------------------------------------
-- constants
-- ---------------------------------------------------------------------------

-- Physical capture buffer, must match bufdur in Engine_Pappus.sc. The usable
-- loop is m_buflen seconds of it; everything the UI does with time uses that,
-- not this.
local BUFDUR = 60.0
local BUFLEN_MIN, BUFLEN_MAX = 2.0, 60.0
local WAVE_N = 128        -- one waveform slot per screen column
local NVOICE = 8
-- Screen and grid refresh rates. Both are params (see PERFORMANCE) rather
-- than constants, because what a Pi 4 shield can draw at twenty-five a
-- factory norns cannot always, and on norns the screen and the encoders are
-- served by the same thread - a frame that overruns is felt as an encoder
-- that stalls and then jumps.
local FPS = 25
local GRID_FPS = 25
local MAX_MARKS = 96

-- RATE / DELAY SYNC divisions. the S-4 calls one bar "1/1", so 1/4 is a beat.
local DIVS = {
  { name = "4/1",  beats = 16    },
  { name = "2/1",  beats = 8     },
  { name = "1/1",  beats = 4     },
  { name = "1/2",  beats = 2     },
  { name = "1/4",  beats = 1     },
  { name = "1/8",  beats = 0.5   },
  { name = "1/16", beats = 0.25  },
  { name = "1/32", beats = 0.125 },
  { name = "1/64", beats = 0.0625},
  { name = "FREE", beats = nil   },
}

local DIV_NAMES = {}
for i, d in ipairs(DIVS) do DIV_NAMES[i] = d.name end

-- Names are kept to six characters: they show in the header's middle slot,
-- which is the first thing squeezed out when a page name is long.
--
-- The first seven are in their original order on purpose. The scale is an
-- option param, so a saved pset stores its INDEX - inserting anywhere in this
-- list would silently transpose every existing preset. New scales append.
local SCALES = {
  { name = "CHROM",  iv = { 0,1,2,3,4,5,6,7,8,9,10,11 } },
  { name = "MAJOR",  iv = { 0,2,4,5,7,9,11 } },
  { name = "MINOR",  iv = { 0,2,3,5,7,8,10 } },
  { name = "DORIAN", iv = { 0,2,3,5,7,9,10 } },
  { name = "PENT",   iv = { 0,3,5,7,10 } },        -- minor pentatonic
  { name = "WHOLE",  iv = { 0,2,4,6,8,10 } },
  { name = "5THS",   iv = { 0,7 } },
  -- appended in v10
  { name = "PHRYG",  iv = { 0,1,3,5,7,8,10 } },
  { name = "LYDIAN", iv = { 0,2,4,6,7,9,11 } },
  { name = "MIXO",   iv = { 0,2,4,5,7,9,10 } },
  { name = "LOCRIA", iv = { 0,1,3,5,6,8,10 } },
  { name = "HARM.M", iv = { 0,2,3,5,7,8,11 } },
  { name = "MEL.M",  iv = { 0,2,3,5,7,9,11 } },
  { name = "PENT.J", iv = { 0,2,4,7,9 } },         -- major pentatonic
  { name = "BLUES",  iv = { 0,3,5,6,7,10 } },
  { name = "HIRAJO", iv = { 0,2,3,7,8 } },
  { name = "INSEN",  iv = { 0,1,5,7,10 } },
  { name = "KUMOI",  iv = { 0,2,3,7,9 } },
  { name = "OCTA",   iv = { 0,2,3,5,6,8,9,11 } },  -- diminished
  { name = "AUGMNT", iv = { 0,3,4,7,8,11 } },
  { name = "4THS",   iv = { 0,5 } },
  { name = "OCTAVE", iv = { 0 } },
}

local SCALE_NAMES = {}
for i, s in ipairs(SCALES) do SCALE_NAMES[i] = s.name end

local OCTAVES = { -2, -1, 0, 1 }     -- grid columns 13..16

-- Rate offsets, used by DELAY (and later by the LFOs). A single 0-100 knob:
-- 50 is the granulator's own rate, below 50 divides it down (slower, longer
-- cycle), above 50 multiplies it up (faster, shorter cycle). The stored value
-- is the CYCLE ratio, so ratio 4 means a cycle four grain periods long, which
-- is a quarter of the rate.
--
-- When the grain rate is locked to the clock these snap to musical ratios;
-- when it is FREE there is nothing to be musical against, so the knob becomes
-- a continuous detune-style offset instead (see rate_offset below).
local RATIOS = {
  { name = "/64", r = 64 },   { name = "/48", r = 48 },
  { name = "/32", r = 32 },   { name = "/24", r = 24 },
  { name = "/16", r = 16 },   { name = "/12", r = 12 },
  { name = "/8",  r = 8 },    { name = "/6",  r = 6 },
  { name = "/4",  r = 4 },    { name = "/3",  r = 3 },
  { name = "/2",  r = 2 },    { name = "/1.5", r = 1.5 },
  { name = "x1",  r = 1 },
  { name = "x1.5", r = 1 / 1.5 }, { name = "x2",  r = 1 / 2 },
  { name = "x3",  r = 1 / 3 },    { name = "x4",  r = 1 / 4 },
  { name = "x6",  r = 1 / 6 },    { name = "x8",  r = 1 / 8 },
  { name = "x12", r = 1 / 12 },   { name = "x16", r = 1 / 16 },
  { name = "x24", r = 1 / 24 },   { name = "x32", r = 1 / 32 },
  { name = "x48", r = 1 / 48 },   { name = "x64", r = 1 / 64 },
}

-- GRAINSWARM 2's division list: the same one with LINK on the end, which
-- hands its rate back to GRAINSWARM 1 as a ratio.
local NDIV_NAMES = {}
for i, d in ipairs(DIVS) do NDIV_NAMES[i] = d.name end
NDIV_NAMES[#DIVS + 1] = "LINK"

local SSTEPS = { 16, 12, 9, 7 }
local SSTEP_NAMES = { "16", "12", "9", "7" }

-- base pan positions for the eight taps, scaled by SPREAD.
-- alternating sides so the field opens outward rather than sliding across.
local PAN_BASE = { -1, 1, -0.7, 0.7, -1, 1, -0.45, 0.45 }
local NTAP = 8
local MAX_CYCLE = 10.0

-- SWARM duplicate intervals, mirroring Engine_Pappus's swiva/swivb
local SWARM_IV = { { 0, 0 }, { -7, 7 }, { -12, 12 }, { 7, 12 } }
-- STRUM offsets voice i by i steps of a grain-period subdivision, so every
-- onset lands on a division of the grain clock rather than at an arbitrary
-- fraction of an arbitrary spread. 1/8 is the widest that keeps voice eight
-- (7 steps) inside one period.
-- FILTRU's RAND spread table, in octaves. Must match frnd in Engine_Pappus.sc,
-- or the display draws combs where the engine has not put them.
local FRND = { 0, 0.41, -0.77, 0.19, 0.93, -0.35, 0.61, -0.12 }
-- the dot display auto-ranges to whatever is actually playing
local BLACK = { [1]=true, [3]=true, [6]=true, [8]=true, [10]=true }

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

local page = 1
local sel = {}                    -- selected cell per page, filled once PAGES is
local ui_metro
local last_t = 0

-- Display state for the granulator pages, PER GRANULATOR.
--
-- Every one of these animates something you can hear - the captured waveform,
-- the write and play heads, the grain dots, the euclidean flashes. Showing
-- swarm 1's activity on swarm 2's page would be a picture of a sound that is
-- not being made, which is worse than no picture at all.
--
-- A table rather than a second set of locals: the main chunk is at Lua's
-- 200-local ceiling and another dozen would stop the script loading.
VS = {}
for w = 1, 2 do
  VS[w] = {
    wave = {},          -- WAVE_N amplitude slots = the capture buffer
    wpos = 0,           -- write head 0..1
    spos = 0,           -- scan / play head 0..1
    last_slot = 1,
    slot_peak = 0,
    wave_peak = 0.05,   -- running max, for normalising the display
    pitch_lo = -8, pitch_hi = 8,   -- eased window for the grain dots
    marks = {},         -- animated grain markers
    grain_acc = 0,
    flash = {},         -- per-voice grid flash timers
  }
end

local in_amp = 0
local env_disp = 0



-- DELAY taps. `manual` is what the grid edits; `taps` is what is actually
-- used, which is the euclidean pattern whenever EUCLID is above zero.
local manual = {}
for i = 1, NTAP do manual[i] = { step = (i - 1) * 2, on = (i <= 4) } end
local taps = {}
for i = 1, NTAP do taps[i] = { step = 0, on = false, time = 0, lvl = 0, pan = 0, pitch = 0 } end
local tap_flash = {}
for i = 1, NTAP do tap_flash[i] = 0 end
local stil_phase = 0
local stil_cycle = 1.0
local filt_t = 0                  -- free-running clock for FILTRU's drift sway

local cpu = 0                     -- scsynth load, so overload is visible
local out_amp = 0                 -- COLOUR watches the OUTPUT, not the input
local out_amp_disp = 0
local vis_update                  -- forward declared: init's metro calls it


local grains = {}                 -- per grid row: pitch selection
for i = 1, NVOICE do
  -- lvl and prob are per voice: level rides in the gates array, probability
  -- in its own array, both settable by holding a grid key and turning E2/E3
  grains[i] = { on = (i == 1), semi = 0, oct = 3, lvl = 1, prob = 1 }
end

-- GRAINSWARM 2's eight voices. A SECOND ARRAY, not a second dimension on
-- `grains`: a hundred and twenty-odd places read `grains` and every one of
-- them means swarm 1 unless it says which. Anything that works on either one
-- takes a swarm index and asks gr(w).
--
-- Global rather than local: the main chunk is at Lua's 200-local ceiling, and
-- adding a file-scope local there fails to load outright.
grains2 = {}
for i = 1, NVOICE do
  grains2[i] = { on = (i == 1), semi = 0, oct = 3, lvl = 1, prob = 1 }
end
function gr(w) return (w == 2) and grains2 or grains end

-- RESONATOR's OWN eight voices, edited by the grid on the RESONATOR page
-- exactly like a grainswarm chord - but it belongs to neither granulator.
-- FREQUENCY mode GRID reads this instead of borrowing whichever swarm is
-- feeding the bank harder, so the bank can hold a chord of its own.
--
-- Global for the same reason as grains2: the main chunk is already at Lua's
-- 200-local ceiling.
sp_chord = {}
for i = 1, NVOICE do
  sp_chord[i] = { on = (i == 1), semi = 0, oct = 3, lvl = 1 }
end

-- Parameter prefixes for the pair, and the rule that GRAINSWARM 1 IS THE
-- PARENT. Two things are deliberately not duplicated:
--
--   SCALE   is global. Two granulators in different scales is not a feature,
--           it is a mistake you make once and spend a minute finding. Set it
--           on either page and both follow.
--   RATE    on swarm 2 is a RATIO of swarm 1's, the same x/. list the LFOs
--           and DELAY use. It keeps the pair rhythmically related by
--           construction, and it is one knob instead of a division plus a
--           free-run Hz.
--
-- Everything else is genuinely independent, including the capture buffer,
-- SOS, LOCK and the pre-buffer TILT.
SWP = { "m_", "n_" }
function swid(w, name)
  if name == "scale" then return "m_scale" end
  return SWP[w or 1] .. name
end

-- MIDI note input. Notes drive the same eight voices the grid does, by
-- writing straight into `grains` rather than shadowing it: the visualiser,
-- the RESONATOR pitch lock and the grid display all read that table already,
-- so playing the keyboard moves every one of them without a second code
-- path to keep in step. The grid's own chord is snapshotted on the way in
-- and put back when MIDI notes are switched off, so nothing is lost.
local midi_dev = nil
local midi_note_voice = {}        -- note number -> voice index
local midi_voice_note = {}        -- voice index -> note number
local midi_order = 0
local midi_voice_age = {}         -- voice index -> allocation counter
local midi_saved = nil            -- the grid chord, while MIDI holds the keys

local k3_held_at = nil
local k2_held_at = nil
local held_voice = nil            -- grid key held down, if any
local scene_held_at, scene_held_row = nil, nil

-- last value actually sent to the engine, per key, so tempo-derived values are
-- only resent when they change. Declared here because send_voices touches it.
local sent = {}

for w = 1, 2 do
  for i = 1, WAVE_N do VS[w].wave[i] = 0 end
  for i = 1, NVOICE do VS[w].flash[i] = 0 end
end


-- ---------------------------------------------------------------------------
-- cells
-- ---------------------------------------------------------------------------

-- The three movable stages, and every order of them. Stored as ONE option
-- param rather than three, so a pset or a scene carries the routing as a
-- single value and cannot describe an impossible chain.
local PAGES = {
  -- The two granulators, four pages, numbered 1/4 .. 4/4. The bare numbers
  -- read as "there are four granulators", which is exactly the wrong thing
  -- for a page name to say - the "of four" is what makes it a position.
  --
  -- Page number and granulator number are now two different things - page 3
  -- belongs to granulator 2 - so the badge down the left of the visualiser
  -- says "G2" rather than a bare numeral. A bare 2 next to a header reading
  -- GRAINSWARM 3 is a puzzle; the G answers it.
  {
    name = "GRAINSWARM",
    short = "GR.SW",
    dots = { 1, 4 },
    sw = 1,
    kind = "grain",
    modpre = "G1.",
    toggle = "m_lock",
    rows = 2,
    cells = {
      { id = "m_pitch",   label = "PITCH",  mode = "m_scale" },
      { id = "m_rate",    label = "RATE",   alt  = "m_rate_free" },
      { id = "m_size",    label = "SIZE"   },
      { id = "m_contour", label = "SHAPE",  bipolar = true },
      { id = "m_scan",    label = "SLIDE",  mode = "m_scan_mode" },
      { id = "m_spray",   label = "SPRAY",  mode = "m_spray_mode" },
      { id = "m_sos", alt = "m_tilt",     label = "SOS"    },
      { id = "m_swarm",   label = "SWARM",  mode = "m_swarm_mode" },
    },
  },
  {
    name = "GRAINSWARM",
    short = "GR.SW",
    dots = { 2, 4 },
    sw = 1,
    kind = "grain2",
    modpre = "G1.",
    toggle = "m_lock",
    rows = 2,
    cells = {
      { id = "m_buflen",    label = "BUFFR"  },
      { id = "m_win_start", label = "WIN.ST" },
      { id = "m_win_end",   label = "WIN.EN" },
      { id = "m_voices",    label = "VOICES" },
      { id = "m_vspread",   label = "V.SPRD", mode = "m_scale" },
      -- the three euclidean controls sit together, in the order you reach for
      -- them: how dense, how long, how far each voice is rotated
      { id = "m_euclid",    label = "EUCLID" },
      { id = "m_elen",      label = "LEN"    },
      { id = "m_strum",     label = "PHASE"  },
    },
  },
  {
    name = "GRAINSWARM",
    short = "GR.SW",
    dots = { 3, 4 },
    sw = 2,
    kind = "grain",
    modpre = "G2.",
    toggle = "n_lock",
    rows = 2,
    cells = {
      -- PITCH's mode cell is the SHARED scale, on both granulators' pages.
      -- It is the same parameter twice, which is the point: you can reach it
      -- from wherever you are and it can only ever say one thing.
      { id = "n_pitch",   label = "PITCH",  mode = "m_scale" },
      -- RATE, and it is GRAINSWARM 2'S OWN by default. The division list has
      -- one extra entry on the end, LINK, and choosing it hands the rate back
      -- to GRAINSWARM 1 as a ratio which E3 then sets - the same idiom as
      -- GRAINSWARM 1's own RATE, where the last entry is FREE and E3 sets the
      -- Hz. The chain mark appears only while LINK is chosen, because that is
      -- the only time this cell belongs to something else.
      { id = "n_rate_div", alt = "n_rate", label = "RATE",
        linkwhen = "n_rate_div" },
      { id = "n_size",    label = "SIZE"   },
      { id = "n_contour", label = "SHAPE",  bipolar = true },
      { id = "n_scan",    label = "SLIDE",  mode = "n_scan_mode" },
      { id = "n_spray",   label = "SPRAY",  mode = "n_spray_mode" },
      { id = "n_sos", alt = "n_tilt",     label = "SOS"    },
      { id = "n_swarm",   label = "SWARM",  mode = "n_swarm_mode" },
    },
  },
  {
    name = "GRAINSWARM",
    short = "GR.SW",
    dots = { 4, 4 },
    sw = 2,
    kind = "grain2",
    modpre = "G2.",
    toggle = "n_lock",
    rows = 2,
    cells = {
      { id = "n_buflen",    label = "BUFFR"  },
      { id = "n_win_start", label = "WIN.ST" },
      { id = "n_win_end",   label = "WIN.EN" },
      { id = "n_voices",    label = "VOICES" },
      { id = "n_vspread",   label = "V.SPRD", mode = "m_scale" },
      { id = "n_euclid",    label = "EUCLID" },
      { id = "n_elen",      label = "LEN"    },
      { id = "n_strum",     label = "PHASE"  },
    },
  },
  {
    name = "RESONATOR",
    -- nine characters is close to the longest name on the instrument, and a
    -- page whose cells carry modes needs the room: the header drops to the
    -- short form only when the mode would otherwise be shaved away
    short = "RESON",
    kind = "spettru",
    toggle = "p_freeze",
    rows = 2,
    cells = {
      -- The dual feed, first on the page. Two bars in one cell: E2 is how
      -- much GRAINSWARM 1 enters this stage, E3 how much GRAINSWARM 2. Set
      -- one to zero and that granulator skips this module.
      { id = "p_in1", alt = "p_in2", label = "DRY IN", dual = true },
      { id = "p_freq",      label = "FREQ",   mode = "p_freqmode" },
      { id = "p_structure", label = "STRUCT", mode = "p_model", bipolar = true },
      { id = "p_bright",    label = "BRIGHT" },
      { id = "p_damp",      label = "DAMP"   },
      { id = "p_pos",       label = "POSN"   },
      { id = "p_grain",     label = "GRAIN", mode = "p_grain_type" },
      { id = "p_wet",       label = "WET"    },
    },
  },
  {
    name = "DELAY",
    kind = "delay",
    toggle = "s_hold",
    rows = 2,
    cells = {
      { id = "s_in1", alt = "s_in2", label = "DRY IN", dual = true },
      { id = "s_euclid",   label = "EUCLID", mode = "s_steps" },
      { id = "s_rate",     label = "RATE",   mode = "s_link" },
      { id = "s_spread",   label = "SPREAD", mode = "s_pspread" },
      { id = "s_feedback", label = "FEEDBK" },
      { id = "s_tilt",     label = "TILT",   mode = "s_tilt_mode", bipolar = true },
      { id = "s_diffuse",  label = "DIFFUS" },
      { id = "s_wet",      label = "WET"    },
    },
  },
  {
    name = "COLOUR",
    kind = "shader",
    toggle = "bypass",
    rows = 2,
    cells = {
      -- in signal order: CRUSH quantises and LOSS then has to encode what
      -- crush left behind. The page used to read LOSS then CRUSH, which was
      -- the order the graph ran them in when they were parallel and is now a
      -- lie about the chain.
      { id = "k_in1", alt = "k_in2", label = "DRY IN", dual = true },
      { id = "drive",       label = "DRIVE"  },
      { id = "crush",       label = "CRUSH", mode = "crush_mode" },
      { id = "loss",        label = "LOSS"   },
      { id = "noise",       label = "NOISE", mode = "noise_type" },
      { id = "noise_decay", label = "N.DEC", alt = "noise_dyn" },
      { id = "noise_tone",  label = "N.TONE" },
      -- WET is gone: COLOUR is always wet, because a colour stage you can
      -- turn down is BYPASS with extra steps and BYPASS is the toggle on this
      -- very page. WOW inherits the knob.
      { id = "k_wow",       label = "WOW"    },
    },
  },
  { name = "MODNI_LFO_PAGES" },   -- placeholder, expanded below
  {
    name = "MODNI ENV",
    short = "ENV",
    kind = "envmod",
    toggle = "mod_hold",
    cols = 3,
    rows = 2,
    cells = {
      { id = "env_src",  label = "SRC"     },
      { id = "env_atk",  label = "ATTACK"  },
      { id = "env_rel",  label = "RELEASE" },
      { id = "env_sens", label = "SENS"    },
      { id = "env_a1",   label = "DEST A",  mode = "env_d1", bipolar = true },
      { id = "env_a2",   label = "DEST B",  mode = "env_d2", bipolar = true },
    },
  },
  {
    name = "SIGNAL",
    kind = "hallat",
    toggle = "mx_dim",
    rows = 2,
    cells = {
      -- SIGNAL is the routing page now, not a mixer. The per-module faders
      -- are gone: how loud a module is in the mix is decided by how much is
      -- fed into it, which is one idea instead of two that fight.
      { id = "o_in1", alt = "o_in2", label = "DRY IN", dual = true },
      { id = "mx_comp",  label = "COMP"  },
      -- VERB, after COMP: a compressor holds the DRY mix together, and does
      -- not know a reverb tail from a transient, so it runs first and VERB
      -- gets whatever it leaves behind. E2 is wet/dry, E3 is TIME - size and
      -- decay together, frozen at the top of its travel - and SHIMMER is the
      -- shimmer send, with its interval (an octave, a fifth, or the current
      -- SCALE's own fifth) on its mode.
      { id = "r_verb",    label = "VERB", alt = "r_decay" },
      { id = "r_shimmer", label = "SHINE", mode = "r_shimmer_mode" },
      { id = "mx_limit", label = "LIMIT" },
      { id = "mx_out",   label = "LEVEL" },
      -- BPM lived on TRIQ, and TRIQ is gone. This is the plumbing page now,
      -- so it inherits the one system control that belongs on one.
      { id = "clock_tempo", label = "BPM" },
    },
  },
  {
    -- LAST IN THE LANE, on purpose. Everything before it is the instrument;
    -- this is what you do with the instrument once it sounds right, and it is
    -- the one page you arrive at by paging all the way to the end.
    --
    -- One hundred and twenty snapshots. No cells: the whole screen is the
    -- slot grid, and it mirrors the monome exactly - fifteen columns of
    -- slots, and the sixteenth column is the CLEAR modifier.
    name = "SNAPSHOTS",
    short = "SNAPS",
    kind = "ritratt",
    rows = 0,
    cells = {},
  },
  -- ...and the last page in the lane is not a page of controls at all
  {
    name = "PAPPUS",
    kind = "pappus",
    rows = 0,
    cells = {},
  },
}

-- The eight LFO pages, two LFOs each, built rather than typed out: the same
-- three cells eight times is exactly the kind of block that drifts when one
-- of them is edited and the others are not.
--
-- Three columns, not four. A whole word fits in 42 pixels where "1DSTA" was
-- all that fitted in 32, and the LFO's number has moved out of every label
-- and into the page name - so the page says WHICH pair and the cells say
-- WHAT. Top row is the first of the pair and lines up with the top lane of
-- the visualiser above it.
do
  local at
  for i, pg in ipairs(PAGES) do if pg.name == "MODNI_LFO_PAGES" then at = i end end
  table.remove(PAGES, at)
  for k = 0, 3 do
    local a, b = (k * 2) + 1, (k * 2) + 2
    local cells = {}
    for _, n in ipairs({ a, b }) do
      local pre = "lfo" .. n .. "_"
      cells[#cells + 1] = { id = pre .. "rate",  label = "RATE",
                            mode = pre .. "shape" }
      -- The swapping one. It is PHASE normally and MACHINE on STEP and
      -- GLIDE, and `swap` is how the cell says so: same slot, same key, same
      -- grid row, different parameter under it.
      cells[#cells + 1] = { id = pre .. "phase", label = "PHASE",
                            swap = { id = pre .. "machine", label = "MACHINE",
                                     shape = pre .. "shape" } }
      -- the cell's VALUE is the modulation amount and its MODE is the
      -- destination, so one cell is a whole routing
      cells[#cells + 1] = { id = pre .. "a1",    label = "DEST A",
                            mode = pre .. "d1", bipolar = true }
      cells[#cells + 1] = { id = pre .. "a2",    label = "DEST B",
                            mode = pre .. "d2", bipolar = true }
    end
    table.insert(PAGES, at + k, {
      name = string.format("MODNI %d-%d", a, b),
      short = string.format("M%d-%d", a, b),
      kind = "magna",
      toggle = "mod_hold",
      cols = 3,
      rows = 2,
      lfos = { a, b },
      cells = cells,
    })
  end
end

-- The GRAINSWARM pages start on cell ZERO - the waveform - because SRC lives
-- there and it defaults to OFF: the first control you meet should be the one
-- that decides whether there is anything to hear.
for i = 1, #PAGES do
  local k = PAGES[i].kind
  sel[i] = ((k == "grain" or k == "grain2") and PAGES[i].sw) and 0 or 1
end

-- Two LANES, stacked. The audio chain runs left to right and the modulators
-- live underneath it, so K2 and K3 never walk you through eight LFO pages on
-- the way from COLOUR to SIGNAL. K2 and K3 together drops down to the
-- modulators and again comes back up, and the display wipes vertically so it
-- is obvious which way you went.
-- one table, because this chunk is at Lua's 200-local ceiling
-- Which granulator the visualisers are drawing. On a GRAINSWARM page it is
-- that page's own; anywhere else it is the parent, because that is the one
-- whose chord RESONATOR and the rest default to.
--
-- This has to live BELOW the page table. As a local, PAGES is not in scope in
-- anything declared above it - the name silently resolves to a nil global
-- instead, so the function returned 1 for every page and GRAINSWARM 2 drew
-- swarm 1's waveform under a badge reading "1". No error, just a wrong
-- picture, which is the expensive kind.
-- Which pages have a selectable visualiser. Only the granulator pages: it is
-- the waveform that carries a control, and the other visualisers are readouts.
function grain_vis_page(pg)
  return pg and (pg.kind == "grain" or pg.kind == "grain2") and pg.sw or nil
end

function vis_swarm()
  local pg = PAGES[page]
  return (pg and pg.sw) or 1
end

local LANE = { { }, { }, at = { 1, 1 }, n = 1 }
for i, pg in ipairs(PAGES) do
  local mod = (pg.kind == "magna" or pg.kind == "envmod")
  local L = LANE[mod and 2 or 1]
  L[#L + 1] = i
end

-- which page is showing. `page` itself stays local; this is the read-only
-- view tests and the frame renderer use.
-- the per-voice trigger flash and the step the generators are on, so the
-- display's gating can be tested against euclid_hit rather than eyeballed
function grain_flash(v, w) return VS[w or vis_swarm()].flash[v] or 0 end
function grain_step(w) return VS[w or vis_swarm()].flash.step or 0 end

function current_page()
  return page
end

-- Which cell the cursor is on. Zero means the visualiser on a GRAINSWARM
-- page. Exposed for tests: they used to count encoder clicks from an assumed
-- starting point, which stopped being true the moment cell zero existed.
function current_cell() return sel[page] end

-- ...and a way to land on one without counting clicks at all.
function goto_cell(i)
  local guard = 0
  while sel[page] ~= i and guard < 40 do
    enc(1, (sel[page] < i) and 1 or -1)
    guard = guard + 1
  end
  return sel[page] == i
end

function lane_page()
  return LANE[LANE.n][util.clamp(LANE.at[LANE.n], 1, #LANE[LANE.n])]
end

-- Jump straight to a page index, picking the lane it lives in. Tests and the
-- frame renderer used to walk there with K3, which stopped working the moment
-- pages were split into lanes - and walked silently onto the wrong page
-- rather than failing.
function goto_page_index(i)
  for ln = 1, 2 do
    for k, pi in ipairs(LANE[ln]) do
      if pi == i then LANE.n, LANE.at[ln], page = ln, k, i ; return true end
    end
  end
  return false
end


-- MACHINE's reveal, one per LFO. Progress runs 0..1 in real time and the
-- eased value is a smoothstep of it, so the cell accelerates away from the
-- edge and settles instead of arriving at full speed. The three cells beside
-- it are laid out against the SAME number, which is what makes them compress
-- rather than jump.
-- one table rather than three file-scope locals: this chunk is close to
-- Lua's 200-local ceiling and the reveal is one idea, not three
local mach = { t = 0.26, p = {}, r = {} }

-- What is actually in a cell slot right now. Only the LFO pages use it, and
-- only for their middle cell; everywhere else it hands back what it was given.
--
-- Every reader goes through this - the draw, the encoders, the grid, the
-- scene capture - so there is exactly one place that decides which parameter
-- a slot holds. The swap is at the halfway point of the reveal, which is also
-- where the cell is widest-changing, so the label crossfades under the slide
-- rather than popping before or after it.
function cell_at(pg, i)
  local c = pg.cells[i]
  if not c then return nil end
  local sw = c.swap
  if not sw then return c end
  if params:get(sw.shape) <= 2 then return sw end
  return c
end

-- nothing hides any more: the middle cell always holds SOMETHING
function cell_visible(pg, i)
  return pg.cells[i] ~= nil
end


-- The page list, named so tests can read it. Three separate test bugs have
-- come from hardcoding "there are ten pages" or "SKENI is page nine": the
-- walk parks on the last page, every assertion after that quietly passes on
-- nothing, and the run still prints OK. One namespaced global is cheaper than
-- finding that a fourth time.
pappus = { pages = PAGES, lane = LANE }   -- lfos is added once the table exists

local TILT_XOVER = { 80, 650, 2500 }

-- ---------------------------------------------------------------------------
-- param helpers, so cells can hold either controls or options
-- ---------------------------------------------------------------------------

-- dB to linear, with the bottom of every fader being a true zero rather than
-- -60 dB of residue
local function dbl(db)
  if db <= -59.5 then return 0 end
  return 10 ^ (db / 20)
end

local function is_option(id)
  local p = params:lookup_param(id)
  return p.options ~= nil
end

-- add_number params have neither options nor a controlspec, so the cell
-- helpers have to handle a third shape or they blow up on get_raw
local function is_number(id)
  local p = params:lookup_param(id)
  return p.options == nil and p.controlspec == nil
end

local function frac(id)
  local p = params:lookup_param(id)
  if p.options then
    local n = #p.options
    if n < 2 then return 0 end
    return (params:get(id) - 1) / (n - 1)
  elseif p.controlspec == nil then
    local span = (p.max or 1) - (p.min or 0)
    if span <= 0 then return 0 end
    return (params:get(id) - (p.min or 0)) / span
  end
  return params:get_raw(id)
end

-- Where zero sits in the same 0..1 space frac() reports, so the grid's
-- bipolar rows can draw their centre line on the column that actually SETS
-- zero rather than on the geometric middle of the row.
local function zero_frac(id)
  local p = params:lookup_param(id)
  if p.controlspec then
    if p.controlspec.minval < 0 and p.controlspec.maxval > 0 then
      return p.controlspec:unmap(0)
    end
    return 0
  end
  if p.options then return 0 end
  local span = (p.max or 1) - (p.min or 0)
  if span <= 0 or (p.min or 0) >= 0 then return 0 end
  return (0 - p.min) / span
end

-- THE GRID A KNOB LANDS ON.
--
-- Chosen from the MAGNITUDE of the value rather than the width of the range,
-- because a frequency knob spends its life at both 40 Hz and 8 kHz and no
-- single increment is right for both. The floor keeps a parameter sitting at
-- zero from being handed an absurdly small step.
local function quantum(v, span)
  -- The floor is there so a parameter sitting at exactly zero is not handed
  -- an infinitely small step, and it has to be SMALL: at a fiftieth of the
  -- range, a 20 Hz .. 11.5 kHz knob was being given a 100 Hz grid at its
  -- bottom end, where 100 Hz is five times the whole value.
  local m = math.max(math.abs(v), (span or 1) * 0.001)
  if m < 2 then return 0.01 end
  if m < 20 then return 0.1 end
  if m < 200 then return 1 end
  if m < 2000 then return 10 end
  return 100
end

-- Both knobs land on that grid, and this is the whole point of them doing so:
-- a value arrived at by adding a hundredth of the KNOB'S TRAVEL to whatever
-- was there before is a number like 0.4937, and no amount of turning gets you
-- to 0.5. The coarse knob keeps its feel - a percent of the travel per click,
-- which on a warped spec is a percentage of the value rather than a fixed
-- amount - and then rounds onto the grid. The fine knob does not sweep at
-- all: it steps by exactly one tenth of the grid, from the nearest point ON
-- it, so it is a way of typing a number rather than a slower sweep.
local function bump(id, d, fine)
  if is_option(id) or is_number(id) then
    params:delta(id, d)
    return
  end
  local p = params:lookup_param(id)
  local spec = p and p.controlspec
  if not spec then
    local step = (fine and 0.002 or 0.01) * d
    params:set_raw(id, util.clamp(params:get_raw(id) + step, 0, 1))
    return
  end

  local lo, hi = spec.minval, spec.maxval
  local v = params:get(id)

  -- A spec that declares its own STEP OF AT LEAST ONE - so far, only the
  -- semitone pitch controls - is a fixed grid, not a continuous range that
  -- happens to be round right now. Running it through the magnitude-based
  -- quantum() below gave PITCH a hundredth-of-a-semitone grid near zero: a
  -- click did almost nothing, which read as unresponsive, and left decimals
  -- in the display. There is no finer-than-a-semitone to type, so fine and
  -- coarse match.
  --
  -- The threshold matters: several dB faders (mx_out among them) declare a
  -- 0.1 step too, but that is norns' own "reasonable precision" convention,
  -- not a claim about the click grid - honouring it here rounded a coarse
  -- click near the middle of its range, where the rest of the instrument's
  -- magnitude-based grid wants whole decibels.
  if spec.step and spec.step >= 1 then
    local target = util.clamp(v + (d * spec.step), lo, hi)
    params:set(id, util.round(target / spec.step) * spec.step)
    return
  end

  local q = quantum(v, hi - lo)

  local target
  if fine then
    -- One decade finer than the coarse grid, and DECIDED BY THE VALUE ALONE.
    -- The first version worked it out from the size of the coarse step at
    -- that exact point, which meant the fine step changed size half way
    -- through a sweep: SKEW went 0.11, 0.12, 0.13, 0.131 as a floating-point
    -- comparison flipped under it. A knob whose step size is a surprise is
    -- worse than one that is merely slow.
    q = q / 10
    target = (math.floor(v / q + 0.5) + d) * q
  else
    target = spec:map(util.clamp(spec:unmap(v) + (0.01 * d), 0, 1))
    -- the grid of where it is GOING, not where it came from. A click that
    -- crosses a decade - 1.98 up to 2.07 - has to land on the grid it arrives
    -- on, or the number is round by the rules of the place it just left.
    q = quantum(target, hi - lo)
    target = math.floor(target / q + 0.5) * q
    -- ...and it has to actually MOVE. At the bottom of a warped range a whole
    -- click is worth less than one step of the grid, and rounding then hands
    -- back the number it started from - a knob that does nothing.
    if d ~= 0 and math.abs(target - v) < (q * 0.5) then
      target = (math.floor(v / q + 0.5) + ((d > 0) and 1 or -1)) * q
    end
  end
  -- a hair of tolerance before the clamp: 0.1 + 0.2 is not 0.3 in binary and
  -- the top of a range should be reachable
  params:set(id, util.clamp(target, lo, hi))
end

-- ---------------------------------------------------------------------------
-- pitch
-- ---------------------------------------------------------------------------

local function snap_to_scale(semi, sc)
  local iv = SCALES[sc].iv
  local oct = math.floor(semi / 12)
  local pc = semi - (oct * 12)
  local best, bd = iv[1], 999
  for _, v in ipairs(iv) do
    local d = math.abs(v - pc)
    if d < bd then bd, best = d, v end
  end
  return (oct * 12) + best
end

-- VERB's SHIMMER interval, resolved here rather than in the engine because
-- SCALE needs the scale table. OCT and 5TH are fixed - 12 and 7 semitones -
-- and SCALE is NOT an octave snapped to the scale: snap_to_scale(12, sc)
-- would just return 12 again for almost every scale, since the root is
-- degree zero and is in the scale by definition, which makes "octave
-- quantised to scale" a no-op. A fifth is not guaranteed the same way, so
-- SCALE snaps THAT instead - the scale's own nearest approximation to a
-- fifth, flat in Locrian, wherever a given mode puts it - which is the one
-- version of "quantised to scale" that actually depends on the scale.
local function send_rshimmer()
  local m = pval("r_shimmer_mode")
  local semi = 12
  if m == 2 then semi = 7
  elseif m == 3 then semi = snap_to_scale(7, pval("m_scale")) end
  engine.rshimmersemi(semi)
end

-- DELAY's PITCH SPREAD, the second knob on the SPREAD cell. Same shape as
-- PAN_BASE: a value per tap SLOT, not per step, so it is a property of the
-- tap the way the pan is, and does not reshuffle when EUCLID or the grid
-- changes which slots are on. OCT+5TH snaps that same ramp to the nearest
-- octave-or-fifth; SCALE snaps it to the master scale instead of the tap's
-- own semitones, reusing snap_to_scale exactly as GRAINSWARM's V.SPRD does.
--
-- The RANGE the taps ramp across is not fixed - it grows with the SPREAD
-- knob itself, the same knob that sets the pan spread, so "no spread" really
-- means no spread. Two breakpoint tables, one per edge, walked and
-- interpolated independently: TOP climbs 0 -> 1 -> 2 -> 3 octaves over the
-- knob's first three quarters then holds; BOTTOM stays put at 0 until the
-- knob passes halfway, then drops to -1 and holds. That is what gives an
-- asymmetric span once the knob is most of the way up, rather than a
-- symmetric one that would blow the top octave out early.
local PSPREAD_IV = { -12, -7, 0, 7, 12 }
local PSPREAD_TOP = { { 0, 0 }, { 0.25, 1 }, { 0.5, 2 }, { 0.75, 3 }, { 1, 3 } }
local PSPREAD_BOT = { { 0, 0 }, { 0.25, 0 }, { 0.5, -1 }, { 0.75, -1 }, { 1, -1 } }
local function pspread_edge(v, tbl)
  v = util.clamp(v, 0, 1)
  for k = 1, #tbl - 1 do
    local a, b = tbl[k], tbl[k + 1]
    if v <= b[1] then
      local f = (b[1] > a[1]) and ((v - a[1]) / (b[1] - a[1])) or 0
      return a[2] + (f * (b[2] - a[2]))
    end
  end
  return tbl[#tbl][2]
end
local function pspread_base(i, spread)
  local lo = pspread_edge(spread, PSPREAD_BOT) * 12
  local hi = pspread_edge(spread, PSPREAD_TOP) * 12
  return lo + ((i - 1) * (hi - lo) / (NTAP - 1))
end
local function snap_to_set(semi, set)
  local best, bd = set[1], 999
  for _, v in ipairs(set) do
    local d = math.abs(v - semi)
    if d < bd then bd, best = d, v end
  end
  return best
end

-- gates carries LEVEL, not just on/off: the engine already lags it and uses
-- >0.001 as the trigger gate, so a fractional value has always worked.
-- scale DEGREE to semitones above the root, wrapping into octaves. Degree 8
-- of a seven-note scale is the root an octave up, not a clamp.
local function degree_semi(d, sc)
  local iv = SCALES[sc].iv
  local n = #iv
  local oct = math.floor(d / n)
  return (oct * 12) + iv[(d % n) + 1]
end

-- VOICES and SPREAD, so the grid is a convenience rather than a requirement.
-- VOICES lights rows 1..n; SPREAD walks them up the selected scale, from
-- unison at 0 to roughly two octaves at the top. Writes straight into the same
-- per-voice state the grid edits, so the grid LEDs move with the knob and a
-- later grid edit simply wins.
local function distribute(w)
  w = w or 1
  local n = pval(swid(w, "voices"))
  local sp = pval(swid(w, "vspread"))
  local sc = pval("m_scale")
  -- Step is measured in scale DEGREES, sized so the top of the knob spans
  -- about two octaves whatever the scale: a fixed degree step would put a
  -- pentatonic voice eight three octaves up and a chromatic one barely one.
  -- Two octaves is also the ceiling the grid can represent - OCTAVES only
  -- reaches +1, so a target above 23 semitones has nowhere to be stored.
  local step = sp * (#SCALES[sc].iv * 1.92 / 7)
  local G = gr(w)
  for i = 1, NVOICE do
    local st = G[i]
    st.on = (i <= n)
    if st.on then
      local semi = util.clamp(degree_semi(util.round((i - 1) * step), sc), 0, 23)
      st.semi = semi % 12
      st.oct = util.clamp(3 + math.floor(semi / 12), 1, #OCTAVES)
    end
  end
end

local function send_voices(w)
  w = w or 1
  local base = pval(swid(w, "pitch"))
  local sc = pval("m_scale")
  local G = gr(w)
  local p, gt, pr = {}, {}, {}
  for i = 1, NVOICE do
    local st = G[i]
    local semi = base + st.semi + (OCTAVES[st.oct] * 12)
    p[i] = snap_to_scale(semi, sc)
    gt[i] = st.on and st.lvl or 0
    pr[i] = st.prob
  end
  if w == 2 then
    engine.pitches2(p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
    engine.gates2(gt[1], gt[2], gt[3], gt[4], gt[5], gt[6], gt[7], gt[8])
    engine.probs2(pr[1], pr[2], pr[3], pr[4], pr[5], pr[6], pr[7], pr[8])
    return
  end
  engine.pitches(p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
  engine.gates(gt[1], gt[2], gt[3], gt[4], gt[5], gt[6], gt[7], gt[8])
  engine.probs(pr[1], pr[2], pr[3], pr[4], pr[5], pr[6], pr[7], pr[8])
  sent.taps = nil          -- LINK means the taps depend on the grid too
  -- RESONATOR's pitch lock follows the chord, so the chord moving has to
  -- re-derive it. Cheap, and it means the lock is never a frame behind.
  -- RESONATOR is tuned to the chord, so the chord moving re-tunes the bank.
  -- Only when SLICE is continuous: on a slow slice the whole point is that
  -- the bank keeps the chord it caught until the next tick.
  if send_bank and params:get("p_freeze") ~= 2 then send_bank() end
end

-- Bresenham/Bjorklund euclidean distribution: k onsets spread over n steps.
-- Returns the 0-based step index of each onset.
local function euclid_steps(k, n)
  local out, bucket = {}, 0
  k = util.clamp(k, 0, n)
  for i = 1, n do
    bucket = bucket + k
    if bucket >= n then
      bucket = bucket - n
      out[#out + 1] = i - 1
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- MIDI notes
--
-- MODE has three positions:
--   OFF        the grid owns the chord, as before
--   VOICES     each held note takes one of the eight voices. Polyphonic, up
--              to eight notes; a ninth steals the oldest. Release them all
--              and the swarm goes quiet, which is what a keyboard should do.
--   TRANSPOS   the grid chord stays exactly as it is and the note moves
--              PITCH. Middle C is no transposition.
--
-- Middle C (60) is voice semitone 0 at the middle octave, so the mapping
-- lines up with the grid: C is the leftmost column, and OCTAVES index 3 is
-- the unshifted one.
-- ---------------------------------------------------------------------------

local MIDI_ROOT = 60

local function midi_snapshot()
  local s = {}
  for i = 1, NVOICE do
    local st = grains[i]
    s[i] = { on = st.on, semi = st.semi, oct = st.oct,
             lvl = st.lvl, prob = st.prob }
  end
  return s
end

local function midi_release_all()
  if midi_saved then
    for i = 1, NVOICE do
      local st, s = grains[i], midi_saved[i]
      st.on, st.semi, st.oct, st.lvl, st.prob = s.on, s.semi, s.oct, s.lvl, s.prob
    end
    midi_saved = nil
  end
  midi_note_voice, midi_voice_note, midi_voice_age = {}, {}, {}
  send_voices()
end

local function midi_pick_voice()
  -- a voice nobody is holding, preferring one that is already silent
  for i = 1, NVOICE do
    if midi_voice_note[i] == nil and not grains[i].on then return i end
  end
  for i = 1, NVOICE do
    if midi_voice_note[i] == nil then return i end
  end
  -- everything held: steal the oldest
  local best, bestage = 1, math.huge
  for i = 1, NVOICE do
    local a = midi_voice_age[i] or 0
    if a < bestage then best, bestage = i, a end
  end
  return best
end

local function midi_note_on(note, vel)
  local mode = params:get("mi_mode")
  if mode == 3 then
    params:set("m_pitch", util.clamp(note - MIDI_ROOT, -24, 24))
    return
  end
  if midi_saved == nil then
    midi_saved = midi_snapshot()
    -- the keyboard takes over from silence, not from the grid chord on top
    for i = 1, NVOICE do grains[i].on = false end
  end
  local v = midi_note_voice[note] or midi_pick_voice()
  local prev = midi_voice_note[v]
  if prev and prev ~= note then midi_note_voice[prev] = nil end
  local rel = note - MIDI_ROOT
  local oct = 3 + math.floor(rel / 12)
  local st = grains[v]
  st.semi = rel % 12
  st.oct = util.clamp(oct, 1, #OCTAVES)
  st.on = true
  if params:get("mi_vel") == 2 then
    st.lvl = util.clamp((vel or 100) / 127, 0.02, 1)
  end
  midi_note_voice[note] = v
  midi_voice_note[v] = note
  midi_order = midi_order + 1
  midi_voice_age[v] = midi_order
  send_voices()
end

local function midi_note_off(note)
  if params:get("mi_mode") == 3 then return end
  local v = midi_note_voice[note]
  if v == nil then return end
  midi_note_voice[note] = nil
  midi_voice_note[v] = nil
  grains[v].on = false
  send_voices()
end

function midi_connect()
  local n = params:get("mi_dev")
  midi_dev = midi.connect(n)
  midi_dev.event = function(data)
    if params:get("mi_mode") == 1 then return end
    local ch = params:get("mi_ch")
    local msg = midi.to_msg(data)
    if ch > 1 and msg.ch ~= (ch - 1) then return end
    if msg.type == "note_on" then
      midi_note_on(msg.note, msg.vel)
    elseif msg.type == "note_off" then
      midi_note_off(msg.note)
    end
  end
end

-- the pattern EUCLID would generate right now
local function euclid_taps()
  local n = SSTEPS[params:get("s_steps")]
  local k = 1 + math.floor(pval("s_euclid") * (NTAP - 0.001))
  local on = euclid_steps(k, n)
  local out = {}
  for i = 1, NTAP do
    out[i] = { step = on[i] or 0, on = (on[i] ~= nil) }
  end
  return out
end

local function using_euclid()
  return pval("s_euclid") > 0.001
end

-- hand the generated pattern over to the grid and stop generating
local function adopt_pattern()
  if using_euclid() then
    local gen = euclid_taps()
    for i = 1, NTAP do
      manual[i].step, manual[i].on = gen[i].step, gen[i].on
    end
    params:set("s_euclid", 0)
  end
end

-- ---------------------------------------------------------------------------
-- tempo-dependent values, resent only when they actually change
-- ---------------------------------------------------------------------------

local function set_if_changed(key, val, fn)
  if sent[key] ~= val then
    sent[key] = val
    fn(val)
  end
end

-- Everything from here reads through pval, not params:get, so a MODNI
-- destination pointed at RATE, SIZE, the tap layout or the voice spread moves
-- the sound without moving the knob.
local function grain_hz(w)
  local di = (w == 2) and pval("n_rate_div") or pval("m_rate")
  -- GRAINSWARM 2's list has LINK past the end of DIVS, which is the one case
  -- that reads swarm 1's rate instead of its own.
  local linked = (w == 2) and di > #DIVS
  local d = DIVS[linked and pval("m_rate") or util.clamp(di, 1, #DIVS)]
  local hz
  if d.beats == nil then
    hz = pval("m_rate_free")
  else
    hz = util.clamp((clock.get_tempo() / 60) / d.beats, 0.05, 200)
  end
  if linked then
    -- GRAINSWARM 1 IS THE PARENT. Swarm 2's RATE is a ratio of whatever swarm
    -- 1 arrived at, clocked or free - so the pair can never drift into an
    -- unrelated tempo, and swapping swarm 1 to a free Hz takes swarm 2 with
    -- it. RATIOS stores divisors, so "x2" is r = 1/2 and this is a divide.
    -- RATIOS is read directly rather than through clock_ratio: that helper
    -- is defined a hundred lines below this one, and a local function cannot
    -- see a local declared after it.
    hz = hz / RATIOS[util.clamp(
      util.round(pval("n_rate") / 100 * (#RATIOS - 1)) + 1, 1, #RATIOS)].r
  end
  return util.clamp(hz, 0.05, 200)
end

local function ratio_index(knob)
  return util.clamp(util.round(knob / 100 * (#RATIOS - 1)) + 1, 1, #RATIOS)
end

-- The transport, in beats per second. norns' clock IS the clock source: set
-- clock_source to MIDI in SYSTEM > CLOCK and this follows the incoming MIDI
-- clock with no extra plumbing, which is why nothing here has to know where
-- the tempo came from.
local function clock_hz()
  return clock.get_tempo() / 60
end

-- ---------------------------------------------------------------------------
-- Transport
--
-- Slaved to something, the granulator waits: nothing is captured and no grain
-- is spawned until PLAY arrives. Free-running, it is the master and never
-- stops - which is the behaviour it has always had, and the only sensible one
-- when there is nothing to wait for.
--
-- Everything DOWNSTREAM keeps running while it waits, so a delay tail or a
-- resonator ring decays away rather than being cut off mid-note. That is what
-- stopping a transport should sound like.
-- ---------------------------------------------------------------------------

function clock_external()
  local ok, v = pcall(function() return params:get("clock_source") end)
  return ok and type(v) == "number" and v > 1
end

-- ---------------------------------------------------------------------------
-- Staying in phase
--
-- The grain clock is an audio-rate Phasor in the engine, reset by a trigger.
-- That reset only ever happened on a transport START, which is not enough for
-- two separate reasons:
--
--   * a START message is not guaranteed. Link has no MIDI start; a DAW already
--     rolling when the script loads sends nothing; a CONTINUE is not a START.
--     Miss it once and the phasor free-runs from whenever the script loaded,
--     which is an arbitrary offset that never corrects itself.
--   * even after a good START, the phasor runs at a rate computed from the
--     tempo. Any rounding at all accumulates, and half an hour later it is
--     wherever it has drifted to.
--
-- Either one lands you at a stable, wrong offset - which sounds exactly like
-- latency and is not. So re-align on a musical boundary, forever.
--
-- The boundary is a whole number of GRAIN PERIODS, never a bare bar: resetting
-- the phasor mid-period restarts the grain, so the correction has to land
-- where a grain was going to fire anyway. At a fast rate that is every four
-- beats; at 4/1 it is every sixteen, which is that rate's own period.
local resync_clock = nil

function resync_beats()
  local d = DIVS[util.clamp(util.round(pval("m_rate")), 1, #DIVS)]
  local per = d and d.beats
  if not per or per <= 0 then return 4 end       -- FREE rate: no grid to hold
  return per * math.max(1, math.ceil(4 / per))
end

function resync_start()
  if resync_clock and clock.cancel then pcall(clock.cancel, resync_clock) end
  if not (clock and clock.run and clock.sync) then return end
  resync_clock = clock.run(function()
    while true do
      clock.sync(resync_beats())
      -- only when something else owns the tempo. Free-running we ARE the
      -- reference, and a reset would be a hiccup with nothing to fix.
      if clock_external() and run_state == 1 then engine.sync(1) end
    end
  end)
end

-- Set the moment a transport START or STOP actually arrives, and never
-- assumed before then.
--
-- An external CLOCK source is not evidence of an external TRANSPORT. Link has
-- no start message at all. A DAW that is merely selected as the source sends
-- nothing until somebody presses play, and if it was already rolling when the
-- script loaded it sent its START long before we existed. Treating "source is
-- not internal" as "wait for play" turns every one of those into an
-- instrument that is completely silent for a reason nothing on screen
-- explains - and the way you find out is by shipping it.
--
-- So: run until something tells us otherwise. The first transport message is
-- what enrols us as a slave; from then on STOP means stop and START means
-- start, exactly as before.
transport_seen = false

function transport_slaved()
  return clock_external() and transport_seen
end

-- from_transport marks a call that came from a real clock.transport callback,
-- as opposed to init or a clock_source change guessing on our behalf.
function transport_set(on, from_transport)
  if from_transport then transport_seen = true end
  local want = (on or not transport_slaved()) and 1 or 0
  if run_state ~= want then
    run_state = want
    engine.run(want)
  end
end

-- 0..100 -> how many BEATS long one cycle is. 50 is x1, one cycle per beat.
--
-- DELAY's cycle and the two MODNI LFOs used to be derived from the GRAIN
-- rate, which meant reaching for RATE on GRAINSWARM silently retimed the delay
-- and both modulators. They are clocked from the transport now, so the four
-- rates are independent and every one of them is a musical division of the
-- beat. The consequence: with GRAINSWARM in FREE these no longer go
-- continuous, because they are not looking at the granulator any more.
local function clock_ratio(knob)
  return RATIOS[ratio_index(knob)].r
end

local function clock_label(knob)
  return RATIOS[ratio_index(knob)].name
end

-- ---------------------------------------------------------------------------
-- RESONATOR - a Rings-style modal/string resonator
--
-- MODAL is forty-eight resonators: six partials on each of the eight grain
-- voices, the same bank the old FILTERBANK ran. STRING is eight
-- Karplus-Strong voices, one per grain voice, sharing the same tuning. The
-- engine runs both and cross-fades on MODE.
--
-- This replaced a spectral resynthesiser, and the reason is worth keeping.
-- That version analysed the input with sixteen zero-crossing counters and
-- rebuilt it with sixteen oscillators. It was accurate. It was also unmusical,
-- and unavoidably so: a counter lands on whatever is loudest inside its band,
-- and for a grain cloud that is nowhere in particular, so the oscillators sat
-- on frequencies with no relationship to the notes being played. A resonator
-- bank has the opposite failure mode - it has no opinion about the input at
-- all, it rings where IT is tuned, and the input only decides how hard.
--
-- The layout is computed here and sent as flat arrays, because every input
-- to it - the chord, FREQUENCY's mode, STRUCTURE, BRIGHTNESS, POSITION -
-- already lives in Lua. FREEZE reduces to "when is this allowed to send",
-- which is why the engine has none of it.
-- ---------------------------------------------------------------------------

local NPART = 6                       -- partials per voice, MODAL
local NBAND = NVOICE * NPART          -- forty-eight resonators
local PQ_REF = 261.6256               -- C4: what a grain at semitone 0 rings

-- what was last sent, so a still bank is not re-sent sixty times a second
local bank_f, bank_a = {}, {}
for i = 1, NBAND do bank_f[i], bank_a[i] = 0, 0 end

-- the visualiser's OWN amplitude, brightness only - POSITION is left out on
-- purpose. Its |sin| weighting hits exact zero on every even partial at the
-- centre, which reads fine as a level sent to the engine but as a picture
-- is half the strings vanishing and reappearing as the knob moves through
-- values near that null - it looked broken because the maths IS a hard
-- null, not a smooth taper. The audio still gets POSITION; the eyes don't.
local bank_ad = {}
for i = 1, NBAND do bank_ad[i] = 0 end

-- the STRING path's own eight voices - one per grain voice, not per partial
local vbank_f, vbank_a = {}, {}
for v = 1, NVOICE do vbank_f[v], vbank_a[v] = 0, 0 end

-- STRUCTURE stretches the partial series. At zero it is harmonic - 1, 2, 3,
-- 4 - and every voice rings like a string. Positive stretches it, which is
-- what makes bells and struck metal inharmonic; negative compresses it
-- towards a cluster, which is closer to a gong. It is one exponent, so it
-- sweeps continuously and modulates well, which is the whole point of a
-- macro like this.
function spettru_ratio(k)
  return k ^ (1 + (util.clamp(pval("p_structure"), -1, 1) * 0.45))
end

-- Forty-eight resonators is six partials on each of eight voices, and there
-- are sixteen voices. Three partials each would fit both chords in and would
-- halve the bank's depth, which is where its whole character lives - so the
-- bank follows ONE granulator.
--
-- Whichever is FED IN HARDER, with GRAINSWARM 1 winning a tie. The bank has
-- to be tuned to something, and "the one you are sending it most of" is the
-- only answer that follows the routing rather than ignoring it: mute swarm 1
-- into RESONATOR and the bank retunes to what is actually exciting it.
function spettru_swarm()
  return (pval("p_in2") > pval("p_in1")) and 2 or 1
end

-- The frequency and level of all forty-eight MODAL resonators, and all eight
-- STRING voices, right now.
--
-- FREQUENCY is a semitone control in all four modes:
--   GRAINS  the chord the grains are playing tunes the bank, exactly as
--           before; FREQUENCY is a free transpose ON TOP of that chord.
--   FREE    one harmonic series off FREQUENCY itself, decoupled from the
--           grains entirely: stack v takes FREQUENCY x v as its fundamental.
--   SCALE   the same as FREE, except FREQUENCY is snapped to the nearest
--           degree of the global scale first.
--   GRID    `sp_chord` tunes the bank instead - the RESONATOR page's own
--           per-voice chord, set by the grid exactly like a grainswarm's.
--
-- BRIGHTNESS and POSITION replace the old CENTRE/WIDTH/SKEW gain window with
-- something that has a physical reading: BRIGHTNESS rolls the upper partials
-- off (a dark body has none of them, a bright one keeps them all), and
-- POSITION is the classic mode-shape-at-the-excitation-point formula -
-- amplitude(partial k) proportional to |sin(pi * position * k)| - the same
-- reason a string plucked at its centre loses its even harmonics. POSITION
-- only reaches the audio array (`a`); the display array (`ad`, see below)
-- leaves it out, because a hard null on every even partial is a picture of
-- strings blinking in and out rather than a bank quietly rebalancing.
function spettru_layout()
  local w = spettru_swarm()
  local G = gr(w)
  local freqst = util.clamp(pval("p_freq"), -48, 48)
  local mode = util.round(pval("p_freqmode"))
  local sc = pval("m_scale")
  local bright = util.clamp(pval("p_bright"), 0, 1)
  local falloff = 0.15 + (bright * 0.85)
  local pos = util.clamp(pval("p_pos"), 0, 1)
  -- FREE and SCALE both decouple the bank from the chord: the whole bank
  -- becomes ONE harmonic series off a single root, spread across eight
  -- v-anchored stacks (eight stacks spread over three octaves measured
  -- 17 dB down, because the same total power split across widely separated
  -- resonators catches far less of the input) - SCALE just snaps that root
  -- to the scale first.
  local freeish = mode == 2 or mode == 3
  local gridish = mode == 4
  local root_semi = freqst
  if mode == 3 then root_semi = snap_to_scale(freqst, sc) end
  local f, a, ad, vf, va = {}, {}, {}, {}, {}
  local sumsq, sumsq_d = 0, 0
  for v = 1, NVOICE do
    local st = gridish and sp_chord[v] or G[v]
    local f0
    if freeish then
      f0 = PQ_REF * (2 ^ (root_semi / 12)) * v
    elseif gridish then
      local semi = snap_to_scale(st.semi + (OCTAVES[st.oct] * 12), sc)
      f0 = PQ_REF * (2 ^ ((semi + freqst) / 12))
    else
      local semi = snap_to_scale(
        pval(swid(w, "pitch")) + st.semi + (OCTAVES[st.oct] * 12), sc)
      f0 = PQ_REF * (2 ^ ((semi + freqst) / 12))
    end
    vf[v] = f0
    va[v] = (st.on or freeish) and ((freeish and 1 or st.lvl)) or 0
    for k = 1, NPART do
      local i = ((v - 1) * NPART) + k
      local hz = util.clamp(
        f0 * spettru_ratio(freeish and i or k), 20, 16000)
      local g, gd = 0, 0
      if st.on or freeish then
        gd = falloff ^ (k - 1)                              -- BRIGHTNESS rolloff
        gd = gd * (freeish and 1 or st.lvl)
        g = gd * math.abs(math.sin(math.pi * pos * k))      -- POSITION mode-shape
        sumsq = sumsq + (g * g)
        sumsq_d = sumsq_d + (gd * gd)
      end
      f[i], a[i], ad[i] = hz, g, gd
    end
  end
  -- Normalise the bank to constant total POWER, not to a count of lit
  -- resonators. Counting was the obvious version and it is wrong: BRIGHTNESS
  -- and POSITION mean the forty-eight are not equal contributors, so
  -- dividing by sqrt(count) made a dark bank quiet and a bright one loud.
  -- Scaling so the sum of squares is one makes both level-neutral, which is
  -- what you want from controls that are about balance rather than volume.
  -- The display array is normalised SEPARATELY, on its own sum - it never
  -- saw POSITION's zeros, so its own power is a different number and
  -- sharing the audio normaliser would just reintroduce the nulls sideways.
  if sumsq > 1e-9 then
    local norm = 1 / math.sqrt(sumsq)
    for i = 1, NBAND do a[i] = util.clamp(a[i] * norm, 0, 1) end
  end
  if sumsq_d > 1e-9 then
    local normd = 1 / math.sqrt(sumsq_d)
    for i = 1, NBAND do ad[i] = util.clamp(ad[i] * normd, 0, 1) end
  end
  return f, a, ad, vf, va
end

function send_bank(force)
  local f, a, ad, vf, va = spettru_layout()
  local changed = force and true or false
  for i = 1, NBAND do
    if math.abs(f[i] - bank_f[i]) > 0.02
      or math.abs(a[i] - bank_a[i]) > 0.0008 then
      changed = true
    end
    bank_f[i], bank_a[i], bank_ad[i] = f[i], a[i], ad[i]
  end
  for v = 1, NVOICE do
    if math.abs(vf[v] - vbank_f[v]) > 0.02
      or math.abs(va[v] - vbank_a[v]) > 0.0008 then
      changed = true
    end
    vbank_f[v], vbank_a[v] = vf[v], va[v]
  end
  if not changed then return end
  engine.pfrq(table.unpack(bank_f, 1, NBAND))
  engine.pamp(table.unpack(bank_a, 1, NBAND))
  engine.pvfrq(table.unpack(vbank_f, 1, NVOICE))
  engine.pvamp(table.unpack(vbank_a, 1, NVOICE))
end

-- The bank re-tunes whenever anything it depends on moves.
--
-- There used to be a SLICE here - a clock that gated when the layout was
-- allowed to change, with a euclidean figure on top. It is gone, and Mick was
-- right about why: it only bit while the chord or MORPH were already moving,
-- so on a held chord the knob did nothing at all. A control that is inert
-- unless something else is happening is not a control.
-- The bank's inputs, as a set. Everything the layout reads that a MODULATOR
-- can reach: the four RESONATOR knobs, the scale, the two chord transposes,
-- and the two feeds - which of those is larger decides WHICH granulator's
-- chord the bank follows. The chord itself is not here; a chord change comes
-- through send_voices, which re-lays the bank on the spot.
local BANK_DEPS = {
  p_freq = true, p_freqmode = true, p_structure = true,
  p_bright = true, p_pos = true,
  m_scale = true, m_pitch = true, n_pitch = true,
  p_in1 = true, p_in2 = true,
}

-- ONLY WHEN A MODULATOR IS ON IT.
--
-- Laying the bank out is forty-eight resonators' worth of scale snapping,
-- powers and sines, and it was being run sixty times a second unconditionally
-- - on the same thread as the redraw and the encoders - to discover, almost
-- always, that nothing had moved. Every knob that feeds the layout already
-- re-lays it from its own action, and mod_apply calls those actions with the
-- modulated value, so a modulated FREQUENCY or BRIGHTNESS re-tunes the bank
-- whether this tick runs or not.
--
-- What this is still here for is the case those actions cannot cover: a
-- destination whose value is moving but whose quantised send has not changed.
-- So it runs when something is modulating one of the bank's inputs, and does
-- not when nothing is - which is almost all of the time.
function spettru_tick(dt)
  if params:get("p_freeze") == 2 then return end
  for id in pairs(BANK_DEPS) do
    if mod_targets(id) then
      send_bank()
      return
    end
  end
end

function spettru_band_hz(i)
  return bank_f[i]
end

-- the visualiser's own reading - see bank_ad above: everything but POSITION
function spettru_band_amp(i)
  return bank_ad[i]
end

-- ---------------------------------------------------------------------------
-- GRAINSWARM's euclidean generator
--
-- One pattern, eight rotations. The Bjorklund distribution runs here and the
-- answer is written into the engine's sixteen-slot buffer, exactly as DELAY
-- does for its taps - the engine never computes a rhythm, it only reads one.
--
-- PHASE carries two behaviours because they are the same idea in two units:
-- with EUCLID off it is a per-voice TIME offset (a rake across the grain
-- period, the old STRUM), with EUCLID on it is a per-voice STEP offset (a
-- rotation of the figure). Only one of the two is ever non-zero, and choosing
-- between them is done here rather than in the graph.
--
-- The length is in STEPS of the grain clock, so the whole thing is derived
-- from GRAINSWARM's own RATE with nothing extra to set.
-- ---------------------------------------------------------------------------

-- one sixteen-step pattern per granulator
local epat = { {}, {} }
for w = 1, 2 do for i = 1, 16 do epat[w][i] = 1 end end

function euclid_kn(w)
  w = w or 1
  local n = util.clamp(util.round(pval(swid(w, "elen"))), 2, 16)
  local dens = pval(swid(w, "euclid"))
  if dens <= 0.001 then return 0, n end
  return util.clamp(util.round(dens * n), 1, n), n
end

function euclid_rot(w)
  local _, n = euclid_kn(w)
  return util.round(pval(swid(w or 1, "strum")) * (n - 1))
end

-- forced true on the first call: the engine's buffer starts all-open and so
-- does epat, so a pure change check would never send anything at all and the
-- two would agree only by luck of matching defaults.
local epat_sent = { false, false }

function send_euclid(w)
  w = w or 1
  local P = epat[w]
  local pre = (w == 2) and "n" or "m"
  local k, n = euclid_kn(w)
  local changed = not epat_sent[w]
  if k == 0 then
    -- EUCLID off: buffer all open, one step, and PHASE is the old STRUM
    for i = 1, 16 do
      if P[i] ~= 1 then P[i] = 1; changed = true end
    end
    set_if_changed(pre .. "elen", 1, function(v) engine[pre .. "elen"](v) end)
    set_if_changed(pre .. "ephase", 0, function(v) engine[pre .. "ephase"](v) end)
    -- CONTINUOUS. With EUCLID off, PHASE is a rake across the grain period
    -- and there is nothing for it to line up WITH - the quantised list exists
    -- so that a rotation lands on a step of the figure, and there is no figure.
    -- Quantising it anyway threw away the whole middle of the knob and made
    -- eight useful positions out of a control that has a hundred.
    --
    -- Still capped at an eighth of a period, which is what keeps voice eight
    -- from still waiting when its next trigger arrives.
    set_if_changed(pre .. "strum", pval(swid(w, "strum")) * 0.125,
      function(v) engine[pre .. "strum"](v) end)
  else
    local want = {}
    for i = 1, 16 do want[i] = 0 end
    for _, st in ipairs(euclid_steps(k, n)) do want[st + 1] = 1 end
    for i = 1, 16 do
      if P[i] ~= want[i] then P[i] = want[i]; changed = true end
    end
    set_if_changed(pre .. "elen", n, function(v) engine[pre .. "elen"](v) end)
    set_if_changed(pre .. "ephase", euclid_rot(w),
      function(v) engine[pre .. "ephase"](v) end)
    set_if_changed(pre .. "strum", 0, function(v) engine[pre .. "strum"](v) end)
  end
  if changed then
    epat_sent[w] = true
    local send = (w == 2) and engine.epattern2 or engine.epattern
    send(P[1], P[2], P[3], P[4], P[5], P[6], P[7], P[8], P[9], P[10],
      P[11], P[12], P[13], P[14], P[15], P[16])
  end
end

-- does voice i fire on step s (0-based)? The display and the engine have to
-- agree about this, so there is exactly one expression of it.
function euclid_hit(i, s, w)
  w = w or 1
  local k, n = euclid_kn(w)
  if k == 0 then return true end
  return epat[w][(((s + (euclid_rot(w) * (i - 1))) % n) + 1)] == 1
end


local function buflen(w)
  return util.clamp(pval(swid(w or 1, "buflen")), BUFLEN_MIN, BUFLEN_MAX)
end

-- scan positions live in 0..1 of the ACTIVE WINDOW; the waveform display shows
-- the whole loop, so anything drawn on it has to be folded back in
local function win_map(p, w)
  w = w or 1
  local lo = pval(swid(w, "win_start"))
  local hi = math.max(pval(swid(w, "win_end")), lo + 0.01)
  return lo + (p * (hi - lo))
end

local function update_timing()
  local hz = grain_hz()
  set_if_changed("mrate", hz, function(v) engine.mrate(v) end)

  local spb = 60 / clock.get_tempo()
  local size = util.clamp(pval("m_size") * spb, 0.002, 8)
  set_if_changed("msize", size, function(v) engine.msize(v) end)

  -- SCAN's single knob means something different in each mode
  local mode = pval("m_scan_mode")
  local scan = pval("m_scan")
  local delay = 0
  if mode == 3 then
    -- DELAY SYNC: quantise the knob to the same division list as RATE
    local n = #DIVS - 1
    local idx = util.clamp(math.floor(scan * n) + 1, 1, n)
    delay = DIVS[idx].beats * spb
  elseif mode == 4 then
    delay = scan * buflen()
  end
  delay = util.clamp(delay, 0, buflen() * 0.98)
  set_if_changed("mdelay", delay, function(v) engine.mdelay(v) end)

  -- ---- GRAINSWARM 2, the same three derived values ----
  -- Its RATE is a ratio of swarm 1's, so this has to be recomputed whenever
  -- swarm 1's rate, the tempo, or the ratio itself moves. All three land here.
  set_if_changed("nrate", grain_hz(2), function(v) engine.nrate(v) end)
  set_if_changed("nsize", util.clamp(pval("n_size") * spb, 0.002, 8),
    function(v) engine.nsize(v) end)
  do
    local m2 = pval("n_scan_mode")
    local sc2 = pval("n_scan")
    local d2 = 0
    if m2 == 3 then
      local nn = #DIVS - 1
      d2 = DIVS[util.clamp(math.floor(sc2 * nn) + 1, 1, nn)].beats * spb
    elseif m2 == 4 then
      d2 = sc2 * buflen(2)
    end
    set_if_changed("ndelay", util.clamp(d2, 0, buflen(2) * 0.98),
      function(v) engine.ndelay(v) end)
  end

  -- DELAY. One delay cycle is a division of the BEAT, not of the grain
  -- period: 50 on the knob is one cycle per beat, /4 is a bar, x4 is
  -- sixteenths. The bottom of the knob runs into MAX_CYCLE - at 120 bpm
  -- anything past /20 is longer than the 11 s delay buffer - which is a
  -- clamp, not a bug.
  local cycle = util.clamp(clock_ratio(pval("s_rate")) / clock_hz(),
    0.02, MAX_CYCLE)
  stil_cycle = cycle
  set_if_changed("scycle", cycle, function(v) engine.scycle(v) end)

  local n = SSTEPS[pval("s_steps")]
  local src = using_euclid() and euclid_taps() or manual
  local spread = pval("s_spread")
  local pspread = pval("s_pspread")
  local mscale = pval("m_scale")
  local nactive = 0
  for i = 1, NTAP do if src[i].on then nactive = nactive + 1 end end
  local norm = 1 / math.sqrt(math.max(nactive, 1))

  -- LINK: tap N belongs to grain N. Off, the two pages are independent
  -- machines that happen to share a clock; on, they are one instrument -
  -- silencing a grid row takes its echo with it.
  local link = pval("s_link") == 2
  local sig = {}
  for i = 1, NTAP do
    local t = taps[i]
    -- LINK follows GRAINSWARM 1. It is the parent, and a delay that changed
    -- which chord it was chained to when you moved a knob on RESONATOR would be
    -- the wrong kind of clever.
    local gv = grains[i]
    t.step = util.clamp(src[i].step, 0, n - 1)
    t.on = src[i].on and ((not link) or gv.on)
    t.time = cycle * ((t.step + 1) / n)
    -- later taps sit a little back, which reads as depth rather than a row
    t.lvl = t.on and (norm * (1 - (0.35 * (t.step / n)))) or 0
    if link and t.on then t.lvl = t.lvl * gv.lvl end
    t.pan = PAN_BASE[i] * spread
    if pspread == 1 then
      t.pitch = 0
    elseif pspread == 2 then
      t.pitch = pspread_base(i, spread)
    elseif pspread == 3 then
      t.pitch = snap_to_set(pspread_base(i, spread), PSPREAD_IV)
    else
      t.pitch = snap_to_scale(util.round(pspread_base(i, spread)), mscale)
    end
    sig[i] = string.format("%d%d%.2f%.2f", t.step, t.on and 1 or 0, t.lvl, t.pitch)
  end
  local key = table.concat(sig, ",") .. ":" .. string.format("%.4f,%.3f", cycle, spread)
  if sent.taps ~= key then
    sent.taps = key
    engine.taptimes(taps[1].time, taps[2].time, taps[3].time, taps[4].time,
                    taps[5].time, taps[6].time, taps[7].time, taps[8].time)
    engine.taplevels(taps[1].lvl, taps[2].lvl, taps[3].lvl, taps[4].lvl,
                     taps[5].lvl, taps[6].lvl, taps[7].lvl, taps[8].lvl)
    engine.tappans(taps[1].pan, taps[2].pan, taps[3].pan, taps[4].pan,
                   taps[5].pan, taps[6].pan, taps[7].pan, taps[8].pan)
    engine.tappitch(taps[1].pitch, taps[2].pitch, taps[3].pitch, taps[4].pitch,
                    taps[5].pitch, taps[6].pitch, taps[7].pitch, taps[8].pitch)
  end
end

-- What the source reads as, in the two places it is shown: the header when
-- the waveform is selected, and the band itself.
--
-- Not the raw option names. "OFF" on a waveform that is not moving says
-- nothing about WHY; "NO INPUT" says what is wrong and "STEREO IN" says what
-- is happening, which is the same information a mixer prints on a channel.
function src_label(i)
  return ({ "NO INPUT", "STEREO IN", "MONO L", "MONO R" })[i] or "NO INPUT"
end

local function scan_label()
  local mode = pval("m_scan_mode")
  local scan = pval("m_scan")
  if mode == 1 then
    -- 0.666 is exactly 1.00x, where the playhead runs WITH the write head and
    -- the granulator has no history to replay. Anywhere else it lags, and the
    -- lag replaying is what sounds like a reverb - so the one position that
    -- has no wash is worth naming rather than printing as "1.00x" among a
    -- hundred other two-decimal numbers.
    local r = (scan * 3) - 1
    if math.abs(r - 1) < 0.02 then return "UNITY" end
    return string.format("%.2fx", r)
  elseif mode == 2 then
    return string.format("%.0f%%", scan * 100)
  elseif mode == 3 then
    local n = #DIVS - 1
    return DIVS[util.clamp(math.floor(scan * n) + 1, 1, n)].name
  else
    return string.format("%.2fs", scan * buflen())
  end
end

-- ---------------------------------------------------------------------------
-- MODNI - two LFOs
--
-- These run in Lua, not in the engine, because the whole point is that a
-- destination can be any parameter in the app; wiring thirty possible targets
-- into the SynthDef would cost a multiplexer per destination and there is no
-- wire budget for that. The cost is that modulation updates at MOD_FPS rather
-- than at audio rate, so the rate is clamped to MOD_MAX_HZ - past about a
-- fifth of the update rate a sine would start to read as a staircase. The
-- page shows the resulting frequency in Hz so the clamp is never a mystery.
--
-- Modulation is applied ON TOP of each destination's own value and sent
-- straight to the engine, never written back through params:set. The knob
-- still owns the parameter; the LFO only offsets what gets sent.
-- ---------------------------------------------------------------------------

local MOD_FPS = 60
local MOD_MAX_HZ = 12
-- Eight LFOs, two destinations each: sixteen routings.
--
-- The row is four cells - RATE, a middle one, DEST A, DEST B - and the middle
-- one is the trick that makes it fit. It is PHASE on the three phase shapes,
-- and it becomes MACHINE on STEP and GLIDE, because on those two PHASE has
-- nothing to do: STEP's output is the held value and ignores phase entirely,
-- and GLIDE only uses it to shift the ease between one hold and the next. So
-- the cell that would otherwise be dead is the one MACHINE takes.
local NLFO = 8
local LFO_DEST = 2

-- Five characters each, deliberately. The header shows the selected cell's
-- mode beside the page name, and "S&H HARD" was wide enough to squeeze
-- "MODNI 1-2" down to its short form. STEP and GLIDE say the same thing about
-- a sample and hold - one jumps to the new value, the other eases to it - in
-- half the width. The ORDER is unchanged, so saved scenes and psets still
-- point at the same shapes.
local LFO_SHAPES = { "STEP", "GLIDE", "SINE", "TRI", "SAW", "SQUARE" }

-- The two families need different pictures. SINE, TRI and SAW are functions of
-- phase, so the lane draws the curve itself with a marker riding on it - exact
-- at any rate. Sample and hold is not a function of phase at all: one cycle of
-- it is a single flat value, so drawing "one cycle" would say nothing. For
-- those the lane draws the last SH_N HELD VALUES as a staircase, which is what
-- the LFO is actually doing.
--
-- (A phase-indexed history was tried first and is wrong: once the rate passes
-- one slot per update tick, neighbouring slots hold samples from different
-- cycles and a clean sine renders as noise.)
-- Sixteen, to match the machine's loop length: with MACHINE at the top the
-- lane draws exactly one lap of the sequence, so a locked pattern reads as a
-- shape that holds still rather than as a staircase that happens to repeat.
local SH_N = 16

-- THE MACHINE.
--
-- A Turing machine on the sample and hold. Sixteen slots on a loop; each step
-- reads the next one and then rewrites it with a fresh random value with
-- probability (1 - MACHINE). At zero every slot is rewritten every lap, which
-- is exactly the free-running random it replaced - the knob at rest changes
-- nothing. At one nothing is ever rewritten and the sixteen values loop for
-- ever. In between, some slots hold and some do not, and the pattern drifts
-- one note at a time, which is the whole reason the circuit is loved.
--
-- It only exists on STEP and GLIDE. The other three shapes are functions of
-- phase and have no held value to lock, so the cell is not drawn at all.
local MACHINE_N = 16

local lfos = {}
pappus.lfos = lfos          -- so the machine can be tested without a scope hack
for i = 1, NLFO do
  lfos[i] = { phase = 0, val = 0, sh = 0, sh_prev = 0, hz = 1,
              shist = {}, spos = 1, reg = {}, rpos = 0 }
  for k = 1, SH_N do lfos[i].shist[k] = 0 end
  -- seeded, so a machine locked from the first bar has something to play
  for k = 1, MACHINE_N do lfos[i].reg[k] = (math.random() * 2) - 1 end
end

-- The third modulator is the input itself. It is the most musical source in
-- the box - duck the delay as you play, open the combs on transients - and it
-- costs nothing new: the amplitude polls are already running for the display.
-- Unlike the LFOs it is unipolar, so a positive amount pushes a destination up
-- from where the knob left it and a negative one pulls it down.
local EHIST_N = 96
-- pk is one reading per SOURCE: OUT, GS1, GS2, LEFT, RIGHT. The two ends of
-- the input and the output arrive sixty times a second and are accumulated as
-- PEAKS between ticks; the two granulator levels come off the box meters,
-- which run slower than the modulation tick does, so those are held rather
-- than accumulated - zeroing them every tick would give the follower a source
-- that reads zero three ticks out of four.
local env = { val = 0, peak = 0, hist = {}, hpos = 1, acc = 0,
              pk = { 0, 0, 0, 0, 0 } }
for k = 1, EHIST_N do env.hist[k] = 0 end
local mod_metro
local mod_last = 0

-- Destinations. Each is one parameter plus the single engine command that
-- carries it, so a modulation tick is a map and a send - no Lua-side
-- recomputation. That is why SIZE, RATE and the tap layout are not here:
-- they need update_timing, which rebuilds the tap tables and is far too
-- expensive to run sixty times a second.
-- Every parameter on a page is a destination, and the list is BUILT from the
-- pages rather than hand-maintained, so a control cannot be added to the UI
-- and quietly stay unmodulatable. Names come from the cell labels, prefixed by
-- page, so what you pick here matches what you see there.
--
-- MODNI's and SKENI's own pages are excluded: a modulator that can modulate
-- its own rate or amount feeds back, and a morph knob that drives parameters
-- which are themselves destinations recurses.
local MOD_PREFIX = {
  grain = "G.", grain2 = "G.", spettru = "F.", delay = "D.",
  shader = "C.", hallat = "S.",
}

-- reachable from the params menu but not from any cell
local MOD_EXTRA = {
  { id = "m_lock",    name = "G1.LOCK" },
  { id = "n_lock",    name = "G2.LOCK" },
  { id = "s_hold",    name = "S.HOLD" },
  { id = "bypass",    name = "K.BYP" },
  { id = "mx_dim",    name = "H.DIM" },
}

-- The window ends push each other apart through params:set, which would drag
-- the KNOB along with the modulation and never give it back. These two get a
-- plain engine send instead of their own action.
local MOD_OVERRIDE = {
  m_win_start = function(v) engine.mwinstart(v) end,
  m_win_end   = function(v) engine.mwinend(v) end,
  n_win_start = function(v) engine.nwinstart(v) end,
  n_win_end   = function(v) engine.nwinend(v) end,
}

local MOD_DESTS = { { name = "OFF" } }
do
  local seen = {}
  local function add(id, name)
    if id and not seen[id] then
      seen[id] = true
      MOD_DESTS[#MOD_DESTS + 1] = { id = id, name = name }
    end
  end
  for _, pg in ipairs(PAGES) do
    local pre = pg.modpre or MOD_PREFIX[pg.kind]
    if pre then
      for _, c in ipairs(pg.cells) do
        add(c.id, pre .. c.label)
        add(c.mode, pre .. c.label .. ".M")
        add(c.alt, pre .. c.label .. ".A")
      end
    end
  end
  for _, e in ipairs(MOD_EXTRA) do add(e.id, e.name) end
end

local MOD_NAMES = {}
for i, d in ipairs(MOD_DESTS) do MOD_NAMES[i] = d.name end

local mod_delta = {}              -- param id -> normalised offset in effect
local mod_assigned = {}           -- param id -> true if any slot targets it

-- ...readable from outside, because "is anything modulating this?" is a
-- question the drawing code asks about parameters it is not currently on.
function mod_targets(id) return mod_assigned[id] == true end
local mod_sent = {}               -- param id -> last value actually sent

-- The modulated value of a parameter, in its own units. Modulation is stored
-- as a NORMALISED offset so one amount means the same thing on a 0-1 knob, a
-- 20-4000 Hz knob and an eight-way option; this is where that is undone.
--
-- Nothing here writes to the parameter. The knob keeps its value and every
-- reader that cares about the sounding value calls this instead - which is
-- what lets destinations like SIZE and RATE work at all, since those are
-- recomputed in Lua rather than sent straight to the engine.
function pval(id)
  local d = mod_delta[id]
  local base = params:get(id)
  if not d or d == 0 then return base end
  local p = params:lookup_param(id)
  if p.options then
    return util.clamp(util.round(base + (d * (#p.options - 1))), 1, #p.options)
  elseif p.controlspec then
    return p.controlspec:map(
      util.clamp(p.controlspec:unmap(base) + d, 0, 1))
  end
  local lo, hi = p.min or 0, p.max or 1
  return util.clamp(util.round(base + (d * (hi - lo))), lo, hi)
end

-- Precomputed parameter ids. These are read eight times per modulation tick,
-- sixty times a second; building the strings each time is 1400 throwaway
-- allocations a second on a machine that does not need them.
local LFO_ID = {}
for i = 1, NLFO do
  LFO_ID[i] = { rate = "lfo" .. i .. "_rate", phase = "lfo" .. i .. "_phase",
                shape = "lfo" .. i .. "_shape", a1 = "lfo" .. i .. "_a1",
                d1 = "lfo" .. i .. "_d1", a2 = "lfo" .. i .. "_a2",
                d2 = "lfo" .. i .. "_d2",
                machine = "lfo" .. i .. "_machine" }
end

function lfo_hz(i)          -- global so the test suite can read it back
  return util.clamp(clock_hz() / clock_ratio(params:get(LFO_ID[i].rate)),
    0.005, MOD_MAX_HZ)
end

local function lfo_shape(idx, l, ph)
  if idx == 1 then
    return l.sh
  elseif idx == 2 then
    -- cosine ease between successive holds: stepped, but never a jump
    return l.sh_prev + ((l.sh - l.sh_prev) * (0.5 - (0.5 * math.cos(ph * math.pi))))
  elseif idx == 3 then
    return math.sin(ph * 2 * math.pi)
  elseif idx == 4 then
    return 1 - (4 * math.abs(((ph + 0.25) % 1) - 0.5))
  elseif idx == 5 then
    return (ph * 2) - 1
  else
    -- SQUARE. A hard gate, and it is deliberately NOT smoothed: the other
    -- five shapes all move continuously, so the one thing this adds is the
    -- jump. Rounding its corners would make it a slow trapezoid nobody asked
    -- for. It is exactly +1 for the first half of the cycle and -1 for the
    -- second, which also makes it the shape to reach for when a destination
    -- wants two states rather than a sweep.
    return (ph < 0.5) and 1 or -1
  end
end

-- the value the display should draw at an arbitrary phase, so the lane can be
-- drawn as the shape it actually is rather than a generic squiggle
local function lfo_at(i, ph)
  return lfo_shape(params:get(LFO_ID[i].shape), lfos[i], ph % 1)
end

local function mod_advance(dt)
  local held = params:get("mod_hold") == 2
  for i = 1, NLFO do
    local l = lfos[i]
    l.hz = lfo_hz(i)
    if not held then
      local p = l.phase + (dt * l.hz)
      if p >= 1 then
        -- one new sample per cycle, however many cycles went by
        for _ = 1, math.min(math.floor(p), 4) do
          l.sh_prev = l.sh
          l.rpos = (l.rpos % MACHINE_N) + 1
          -- rewrite this slot, or keep what is in it. One comparison; the
          -- whole behaviour of the knob is in it.
          if math.random() >= util.clamp(pval(LFO_ID[i].machine), 0, 1) then
            l.reg[l.rpos] = (math.random() * 2) - 1
          end
          l.sh = l.reg[l.rpos]
          l.spos = (l.spos % SH_N) + 1
          l.shist[l.spos] = l.sh
        end
        p = p % 1
      end
      l.phase = p
    end
    l.val = lfo_at(i, l.phase + params:get(LFO_ID[i].phase))
  end

  -- one-pole with separate attack and release, fed from whichever source the
  -- SRC cell is pointing at. MONO L+R is the mean of the two ends rather than
  -- the louder of them, so it matches what the granulators do with the same
  -- setting: sum, not pick.
  local si = params:get("env_src")
  local pk = env.pk
  local raw = (si == 1 and pk[1])
    or (si == 2 and pk[2])
    or (si == 3 and pk[3])
    or (si == 4 and ((pk[4] + pk[5]) * 0.5))
    or (si == 5 and pk[4])
    or pk[5]
  local target = util.clamp(raw * params:get("env_sens"), 0, 1)
  pk[1], pk[4], pk[5] = 0, 0, 0
  local tc = (target > env.val) and params:get("env_atk") or params:get("env_rel")
  local k = 1 - math.exp(-dt / math.max(tc, 0.001))
  if held then k = 0 end
  env.val = env.val + ((target - env.val) * k)

  -- history is a plain time window: an envelope has no cycle to index by
  env.acc = env.acc + dt
  if env.acc >= (3.0 / EHIST_N) then
    env.acc = 0
    env.hpos = (env.hpos % EHIST_N) + 1
    env.hist[env.hpos] = env.val
  end
end

local function mod_apply()
  local acc = {}
  local seen = {}
  -- THE AMOUNT IS CUBED, and the reason is that the amount is a FRACTION OF
  -- THE WHOLE PARAMETER RANGE. An LFO at 0.2 was moving its destination
  -- through a fifth of everything it can do - a fifth of RESO is the
  -- difference between a filter and a struck bar - so the bottom of the knob
  -- was already a large gesture and the top four fifths were all "even more".
  --
  -- Cubing keeps both ends exactly where they were, 0 and full range, and
  -- bends everything between: 0.2 becomes 0.008, 0.5 becomes 0.125, 0.8
  -- becomes 0.512. That puts a usable amount of shimmer in the first half of
  -- the travel, which is where a modulation amount is actually set from.
  --
  -- Signed, so a negative amount bends identically in the other direction.
  local function route(di, amt, val)
    if di <= 1 then return end
    local id = MOD_DESTS[di].id
    seen[id] = true
    if amt ~= 0 then
      acc[id] = (acc[id] or 0) + (val * amt * amt * math.abs(amt))
    end
  end

  if params:get("mod_bypass") ~= 2 then
    for i = 1, NLFO do
      route(params:get(LFO_ID[i].d1), params:get(LFO_ID[i].a1), lfos[i].val)
      route(params:get(LFO_ID[i].d2), params:get(LFO_ID[i].a2), lfos[i].val)
    end
    for s = 1, 2 do
      route(params:get("env_d" .. s), params:get("env_a" .. s), env.val)
    end
  end
  mod_assigned = seen

  -- Applying a destination means calling that parameter's OWN action with the
  -- modulated value. For most that is the engine send it already had; for the
  -- ones whose action recomputes something in Lua - the tap table, the voice
  -- layout - it is that recompute, and those functions read through pval, so
  -- they see the modulated value without the knob ever moving.
  local changed = false
  for id, delta in pairs(acc) do
    if mod_delta[id] ~= delta then
      mod_delta[id] = delta
      changed = true
    end
  end

  -- hand back anything that stopped being modulated, exactly once, or it stays
  -- stuck wherever the modulator left it
  local stale
  for id in pairs(mod_delta) do
    if acc[id] == nil then
      stale = stale or {}
      stale[#stale + 1] = id
    end
  end
  if stale then
    for _, id in ipairs(stale) do
      mod_delta[id] = nil
      mod_sent[id] = nil
    end
    changed = true
  end

  if not changed then return end

  local touched = {}
  for id in pairs(acc) do touched[id] = true end
  if stale then for _, id in ipairs(stale) do touched[id] = true end end

  for id in pairs(touched) do
    local v = pval(id)
    local q = (type(v) == "number") and (math.floor(v * 10000 + 0.5) / 10000) or v
    if mod_sent[id] ~= q then
      mod_sent[id] = q
      local ov = MOD_OVERRIDE[id]
      if ov then ov(v) else params:lookup_param(id).action(v) end
    end
  end
end

-- ---------------------------------------------------------------------------
-- params
-- ---------------------------------------------------------------------------

-- NOISE's loop sources. Every .wav file sitting in audio/ becomes an option
-- on the noise type menu, in alphabetical order by filename - drop a file
-- in and it shows up here without touching this script. Engine_Pappus.sc's
-- prAlloc runs the identical scan (same folder, same filter, same sort)
-- over the same folder, so the two lists agree on count and order without
-- either side telling the other; this is why the menu names come from the
-- filename rather than from anything the engine reports back.
local function scan_noise_loops()
  local dir = _path.code .. norns.state.name .. "/audio/"
  local names = {}
  for _, f in ipairs(util.scandir(dir)) do
    if f:lower():match("%.wav$") then
      table.insert(names, f)
    end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  local labels = {}
  for i, f in ipairs(names) do
    labels[i] = f:gsub("%.[Ww][Aa][Vv]$", ""):upper()
  end
  return labels
end

local function add_params()
  -- The noise-source list, built once and shared by NOISE (on COLOUR) and
  -- GRAIN TYPE (on RESONATOR) - both pick from the same WHITE/PINK/DUST
  -- plus whatever is in audio/, so there is exactly one scan and one list
  -- rather than two that could drift apart.
  local noise_types = { "WHITE", "PINK", "DUST" }
  for _, label in ipairs(scan_noise_loops()) do
    table.insert(noise_types, label)
  end

  params:add_separator("grainswarm", "GRAINSWARM")

  params:add_control("m_pitch", "pitch",
    controlspec.new(-24, 24, "lin", 1, 0, "st"))
  params:set_action("m_pitch", function() send_voices() end)

  -- SCALE IS GLOBAL. One list, both granulators, reachable from either page.
  -- Two granulators in different scales is not a feature you would use, it is
  -- a mistake you make once and then spend a minute finding.
  params:add_option("m_scale", "scale", SCALE_NAMES, 1)
  params:set_action("m_scale", function()
    -- re-lay the spread onto the new scale, but only if SPREAD is what put
    -- the voices where they are; a hand-made grid chord is left alone
    for w = 1, 2 do
      if params:get(swid(w, "vspread")) > 0 then distribute(w) end
      send_voices(w)
    end
    -- VERB's SHIMMER is only affected in SCALE mode, but send_rshimmer()
    -- checks that itself - cheaper to always call than to duplicate the
    -- check here.
    send_rshimmer()
  end)

  -- 1/4: a grain per beat. A bar per grain was a texture default; this is
  -- a rhythm one, and it is what you hear first.
  params:add_option("m_rate", "rate", DIV_NAMES, 5)      -- 1/4, one beat
  params:set_action("m_rate", function() update_timing() end)

  params:add_control("m_rate_free", "rate (free)",
    controlspec.new(0.1, 100, "exp", 0, 8, "Hz"))
  params:set_action("m_rate_free", function() update_timing() end)

  -- Down to two thousandths of a beat, which is a millisecond at 120 and
  -- lands on the engine's 2 ms floor at any sensible tempo. That bottom end is
  -- the microsound register - grains short enough that you stop hearing them
  -- as grains and start hearing the rate as a pitch - and it was simply out of
  -- reach before: the old floor of 0.01 beats is 5 ms at 120, which is a short
  -- grain rather than a particle.
  params:add_control("m_size", "size",
    controlspec.new(0.002, 8, "exp", 0, 0.25, "beats"))
  params:set_action("m_size", function() update_timing() end)

  params:add_control("m_contour", "shape",
    controlspec.new(-1, 1, "lin", 0, 0, ""))
  params:set_action("m_contour", function(x)
    engine.mcontour(util.clamp(math.floor((x + 1) * 8 + 0.5), 0, 16))
  end)

  params:add_control("m_scan", "slide",
    controlspec.new(0, 1, "lin", 0, 0.666, ""))
  params:set_action("m_scan", function(x)
    engine.mscan(x)
    update_timing()
  end)

  params:add_option("m_scan_mode", "slide mode",
    { "STRETCH", "POS", "D.SYNC", "D.FREE" }, 1)
  params:set_action("m_scan_mode", function(x)
    engine.mscanmode(x)
    update_timing()
  end)

  params:add_control("m_spray", "spray",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_spray", function(x) engine.mspray(x) end)

  params:add_option("m_spray_mode", "spray mode",
    { "RANDOM", "RND MONO", "WARP", "WARP MONO" }, 1)
  params:set_action("m_spray_mode", function(x) engine.mspraymode(x) end)

  -- SOURCE. What GRAINSWARM 1 is recording, if anything.
  --
  -- It defaults to OFF, which means a fresh script captures nothing and makes
  -- no sound until you point it at an input. That is a deliberate choice and
  -- it has a cost - silence with no error is the most expensive failure this
  -- instrument has - so the waveform view says NO INPUT in plain words
  -- whenever it is off, rather than showing a flat line and leaving you to
  -- work it out.
  --
  -- OFF holds the buffer rather than recording silence over it. "No input"
  -- means nothing is arriving, not that silence is being written: the
  -- destructive reading would erase a snapshot the moment you loaded it, and
  -- LOCK is already there for a deliberate freeze.
  -- STEREO really is stereo now: two mono capture buffers per granulator,
  -- left and right, because GrainBuf reads a mono buffer. MONO L and MONO R
  -- write one input to BOTH buffers, so a mono source arrives centred rather
  -- than stacked against one speaker.
  params:add_option("m_src", "1 source",
    { "OFF", "STEREO", "MONO L", "MONO R" }, 1)
  params:set_action("m_src", function(x) engine.msrc(x) end)

  -- sound on sound. 0 records normally, the middle layers new over old with
  -- the old decaying each pass, and the very top is a true freeze.
  params:add_control("m_sos", "sos",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_sos", function(x) engine.msos(x) end)

  -- TILT, on SOS's sub-value. A DJ tilt EQ sitting BEFORE the buffer, so it
  -- shapes what is recorded rather than what comes out: roll the bottom off
  -- and every grain later taken from that stretch of buffer is thin, which is
  -- a different instrument from an EQ on the output.
  params:add_control("m_tilt", "tilt (pre-buffer)",
    controlspec.new(-1, 1, "lin", 0, 0, ""))
  params:set_action("m_tilt", function(x) engine.mtilt(x) end)

  -- EUCLID: each grain runs the same euclidean pattern at its own rotation.
  -- 0 is off - every trigger fires, which is what the granulator did before
  -- this existed.
  params:add_control("m_euclid", "euclid density",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_euclid", function() send_euclid() end)

  params:add_number("m_elen", "euclid length", 2, 16, 8)
  params:set_action("m_elen", function() send_euclid() end)

  -- SWARM: each grain brings up two duplicates, supersaw style. the knob
  -- fades them in and widens both the detune and the stereo spread; the mode
  -- sets the interval they sit at before detuning.
  params:add_control("m_swarm", "swarm",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_swarm", function(x) engine.mswarm(x) end)

  params:add_option("m_swarm_mode", "swarm mode",
    { "DETUNE", "5TH", "OCT", "5TH+OCT" }, 1)
  params:set_action("m_swarm_mode", function(x) engine.mswarmmode(x) end)

  params:add_option("m_lock", "lock buffer", { "off", "on" }, 1)
  params:set_action("m_lock", function(x) engine.mlock(x - 1) end)

  -- ---- GRAINSWARM 2/2 ----

  -- usable loop length inside the 60 s allocation. Everything time-based in
  -- GRAINSWARM - the delay-mode scan offsets, the waveform display - measures
  -- against this rather than the physical buffer.
  params:add_control("m_buflen", "buffer",
    controlspec.new(BUFLEN_MIN, BUFLEN_MAX, "exp", 0, 8, "s"))
  params:set_action("m_buflen", function(x)
    engine.mbuflen(x)
    update_timing()
  end)

  -- active window. The playhead, and everything SPRAY does to it, is confined
  -- between these; END is held above START in the engine as well as here.
  params:add_control("m_win_start", "window start",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_win_start", function(x)
    if x > params:get("m_win_end") - 0.02 then
      params:set("m_win_end", math.min(1, x + 0.02))
    end
    engine.mwinstart(x)
  end)

  params:add_control("m_win_end", "window end",
    controlspec.new(0, 1, "lin", 0, 1, ""))
  params:set_action("m_win_end", function(x)
    if x < params:get("m_win_start") + 0.02 then
      params:set("m_win_start", math.max(0, x - 0.02))
    end
    engine.mwinend(x)
  end)

  -- How many grid rows are lit, and how far apart they sit on the scale.
  -- Without these the instrument needs a grid to play more than one voice.
  params:add_number("m_voices", "voices", 1, NVOICE, 1)
  params:set_action("m_voices", function() distribute(); send_voices() end)

  params:add_control("m_vspread", "voice spread",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_vspread", function() distribute(); send_voices() end)

  -- PHASE. Two jobs, and which one it has depends on EUCLID:
  --   EUCLID off  it is the old STRUM - voice i fires i subdivisions of a
  --               grain period after the trigger, a phase-locked rake
  --   EUCLID on   it ROTATES the pattern, voice i by i steps, so the eight
  --               voices interlock around one euclidean figure
  -- Both are "how far apart in phase are the voices", which is why one knob
  -- can carry both and why it kept the id m_strum.
  params:add_control("m_strum", "phase",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("m_strum", function() send_euclid() end)

  -- ---- GRAINSWARM 2 ----
  --
  -- The same surface, one letter along, minus the two things the parent owns:
  -- there is no n_scale (SCALE is global) and no n_rate_free (swarm 2's RATE
  -- is a ratio of swarm 1's, so whether the pair is clocked or free-running
  -- is swarm 1's decision to make).

  params:add_separator("grainswarm2", "GRAINSWARM 2")

  params:add_control("n_pitch", "2 pitch",
    controlspec.new(-24, 24, "lin", 1, 0, "st"))
  params:set_action("n_pitch", function() send_voices(2) end)

  -- GRAINSWARM 2's own division, with LINK on the end. Decoupled by default:
  -- two granulators locked to one rate is a pair of voices doing the same
  -- rhythm, and the reason to have two of them is that they do not have to.
  params:add_option("n_rate_div", "2 rate", NDIV_NAMES, 5)   -- 1/4
  params:set_action("n_rate_div", function() update_timing() end)

  -- ...and the ratio, which only applies while the division says LINK. The
  -- same list DELAY and the LFOs use, so "x2" means the same thing
  -- everywhere in the script.
  params:add_control("n_rate", "2 rate ratio",
    controlspec.new(0, 100, "lin", 0, 50, ""))
  params:set_action("n_rate", function() update_timing() end)

  params:add_control("n_size", "2 size",
    controlspec.new(0.002, 8, "exp", 0, 0.25, "beats"))
  params:set_action("n_size", function() update_timing() end)

  params:add_control("n_contour", "2 shape",
    controlspec.new(-1, 1, "lin", 0, 0, ""))
  params:set_action("n_contour", function(x)
    engine.ncontour(util.clamp(math.floor((x + 1) * 8 + 0.5), 0, 16))
  end)

  params:add_control("n_scan", "2 slide",
    controlspec.new(0, 1, "lin", 0, 0.666, ""))
  params:set_action("n_scan", function(x)
    engine.nscan(x)
    update_timing()
  end)

  params:add_option("n_scan_mode", "2 slide mode",
    { "STRETCH", "POS", "D.SYNC", "D.FREE" }, 1)
  params:set_action("n_scan_mode", function(x)
    engine.nscanmode(x)
    update_timing()
  end)

  params:add_control("n_spray", "2 spray",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_spray", function(x) engine.nspray(x) end)

  params:add_option("n_spray_mode", "2 spray mode",
    { "RANDOM", "RND MONO", "WARP", "WARP MONO" }, 1)
  params:set_action("n_spray_mode", function(x) engine.nspraymode(x) end)

  -- ...and swarm 2's, which has one option the parent does not: it can record
  -- GRAINSWARM 1'S OUTPUT and granulate the granulation. Tapped PRE-fader, so
  -- pulling GRA 1 down to hear only swarm 2 does not also stop swarm 2
  -- recording. There is no reciprocal option on swarm 1 on purpose: two
  -- granulators that can feed each other is a feedback loop with no gain
  -- control anywhere in it.
  -- GSWARM1 is NOT in this list any more. The engine dropped GRAINSWARM 1 as
  -- a source when the two became parallel voices into one chain, and the
  -- selector's arithmetic gives a gain of zero for anything past MONO R - so
  -- the option survived as a setting that silently recorded nothing.
  params:add_option("n_src", "2 source",
    { "OFF", "STEREO", "MONO L", "MONO R" }, 1)
  params:set_action("n_src", function(x) engine.nsrc(x) end)

  params:add_control("n_sos", "2 sos",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_sos", function(x) engine.nsos(x) end)

  params:add_control("n_tilt", "2 tilt (pre-buffer)",
    controlspec.new(-1, 1, "lin", 0, 0, ""))
  params:set_action("n_tilt", function(x) engine.ntilt(x) end)

  params:add_control("n_euclid", "2 euclid density",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_euclid", function() send_euclid(2) end)

  params:add_number("n_elen", "2 euclid length", 2, 16, 8)
  params:set_action("n_elen", function() send_euclid(2) end)

  params:add_control("n_swarm", "2 swarm",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_swarm", function(x) engine.nswarm(x) end)

  params:add_option("n_swarm_mode", "2 swarm mode",
    { "DETUNE", "5TH", "OCT", "5TH+OCT" }, 1)
  params:set_action("n_swarm_mode", function(x) engine.nswarmmode(x) end)

  params:add_option("n_lock", "2 lock buffer", { "off", "on" }, 1)
  params:set_action("n_lock", function(x) engine.nlock(x - 1) end)

  params:add_control("n_buflen", "2 buffer",
    controlspec.new(BUFLEN_MIN, BUFLEN_MAX, "exp", 0, 8, "s"))
  params:set_action("n_buflen", function(x)
    engine.nbuflen(x)
    update_timing()
  end)

  params:add_control("n_win_start", "2 window start",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_win_start", function(x)
    if x > params:get("n_win_end") - 0.02 then
      params:set("n_win_end", math.min(1, x + 0.02))
    end
    engine.nwinstart(x)
  end)

  params:add_control("n_win_end", "2 window end",
    controlspec.new(0, 1, "lin", 0, 1, ""))
  params:set_action("n_win_end", function(x)
    if x < params:get("n_win_start") + 0.02 then
      params:set("n_win_start", math.max(0, x - 0.02))
    end
    engine.nwinend(x)
  end)

  params:add_number("n_voices", "2 voices", 1, NVOICE, 1)
  params:set_action("n_voices", function() distribute(2); send_voices(2) end)

  params:add_control("n_vspread", "2 voice spread",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_vspread", function() distribute(2); send_voices(2) end)

  params:add_control("n_strum", "2 phase",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("n_strum", function() send_euclid(2) end)


  -- ---- THE ROUTING ----
  --
  -- Eight faders, two per stage: how much of each granulator is fed in at
  -- that point. A granulator entering at RESONATOR flows through everything
  -- after it; one entering only at DIRECT has skipped the whole chain. That
  -- is what bypassing a module means here, and it is per granulator.
  --
  -- Both granulators enter at the HEAD at 0.7; every later feed starts at
  -- zero. The stages are serial and pass their input through when their WET
  -- is down, so a granulator fed in at all four points arrives at the output
  -- FOUR TIMES - measured at 2.8x, nearly nine decibels, which is not what
  -- "70%" means to anybody. Enter once, flow through, and use the later feeds
  -- to move where a granulator JOINS rather than to add copies of it.

  -- RESONATOR's own DRY IN reaches above unity - +5 dB of headroom past 100%,
  -- so a granulator can be made to drive the bank harder than it plays back,
  -- the way a real exciter overdriving a body would. Nothing else's DRY IN
  -- does this: it is the one feed that goes into a resonant, potentially
  -- self-sustaining system rather than a straight pass-through, so "louder
  -- than the source" is a legitimate thing to ask of it.
  params:add_control("p_in1", "spettru in: grainswarm 1",
    controlspec.new(0, dbl(5), "lin", 0, 0.7, ""))
  params:set_action("p_in1", function(x) engine.pin1(x) end)

  params:add_control("p_in2", "spettru in: grainswarm 2",
    controlspec.new(0, dbl(5), "lin", 0, 0.7, ""))
  params:set_action("p_in2", function(x) engine.pin2(x) end)

  params:add_control("s_in1", "delay in: grainswarm 1",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("s_in1", function(x) engine.sin1(x) end)

  params:add_control("s_in2", "delay in: grainswarm 2",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("s_in2", function(x) engine.sin2(x) end)

  params:add_control("k_in1", "kuluri in: grainswarm 1",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("k_in1", function(x) engine.kin1(x) end)

  params:add_control("k_in2", "kuluri in: grainswarm 2",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("k_in2", function(x) engine.kin2(x) end)

  params:add_control("o_in1", "direct in: grainswarm 1",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("o_in1", function(x) engine.oin1(x) end)

  params:add_control("o_in2", "direct in: grainswarm 2",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("o_in2", function(x) engine.oin2(x) end)

  params:add_separator("spettru", "RESONATOR")

  -- FREQUENCY is a semitone control in all four modes, not a Hz one - it
  -- reads the same knob whether the bank is locked, free, scale-locked or
  -- gridded.
  --   GRAINS  the chord the grains are playing, six partials on each of the
  --           eight voices, exactly as before - FREQUENCY becomes a free
  --           transpose ON TOP of the chord rather than sitting unused.
  --   FREE    one harmonic series on FREQUENCY itself, decoupled from the
  --           grains entirely: stack v takes FREQUENCY x v as its
  --           fundamental, same eight-stack shape as GRAINS.
  --   SCALE   the same as FREE, except FREQUENCY is snapped to the nearest
  --           degree of the global scale first - a quantized root instead
  --           of a continuous one.
  --   GRID    the bank's OWN chord, `sp_chord`, set by the grid on the
  --           RESONATOR page exactly like a grainswarm chord - eight voices
  --           with their own semitone and octave, independent of both
  --           granulators. FREQUENCY is still a free transpose on top.
  params:add_control("p_freq", "spettru frequency",
    controlspec.new(-48, 48, "lin", 1, 0, "st"))
  params:set_action("p_freq", function() send_bank(true) end)

  params:add_option("p_freqmode", "spettru frequency mode",
    { "GRAINS", "FREE", "SCALE", "GRID" }, 1)
  params:set_action("p_freqmode", function() send_bank(true) end)

  -- STRUCTURE stretches the partial series - harmonic at zero, stretched
  -- towards bell above it, compressed towards gong below - and, in STRING,
  -- detunes a second comb per voice for the same "stiffer string" idea.
  -- MODE, paired with it, picks which resonator model STRUCTURE is shaping.
  params:add_control("p_structure", "spettru structure",
    controlspec.new(-1, 1, "lin", 0, 0, ""))
  params:set_action("p_structure", function(x)
    engine.pstruct(x)
    send_bank(true)
  end)

  -- BRIGHTNESS is a low-pass filter on the excitation itself before either
  -- bank hears it - Rings' own primary mechanism - and, in MODAL, it also
  -- tilts the per-partial amplitude falloff the old WIDTH used to.
  params:add_control("p_bright", "spettru brightness",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action("p_bright", function(x)
    engine.pbright(x)
    send_bank(true)
  end)

  -- DAMPING is the ring time, and it is the character control: short is a
  -- bank of bandpasses colouring what goes through, long is a bank of struck
  -- bars - or a string - that keeps sounding after the input stops.
  params:add_control("p_damp", "spettru damping",
    controlspec.new(0, 1, "lin", 0, 0.35, ""))
  params:set_action("p_damp", function(x) engine.pdamp(x) end)

  -- POSITION models where the exciter strikes/plucks the resonator: centred
  -- cancels even harmonics (hollow, PWM-like), edge-struck leaves the whole
  -- series intact. Per-partial in MODAL (pure Lua, the mode-shape formula),
  -- a pick-position comb notch per voice in STRING.
  params:add_control("p_pos", "spettru position",
    controlspec.new(0, 1, "lin", 0, 0.18, ""))
  params:set_action("p_pos", function(x)
    engine.ppos(x)
    send_bank(true)
  end)

  params:add_option("p_model", "spettru model", { "MODAL", "STRING" }, 1)
  params:set_action("p_model", function(x) engine.pmodel(x) end)

  -- GRAIN rides the exciter's OWN envelope rather than hissing on its own -
  -- noise scaled by how loud the grains are right now, so it reads as grit
  -- ON the signal, not a separate breath layer under it. Silence in, silence
  -- out. Mutable Elements' "blow" character, but strictly excitation-linked.
  params:add_control("p_grain", "spettru grain",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("p_grain", function(x) engine.pgrain(x) end)

  -- GRAIN TYPE: which texture GRAIN is mixing in, off the same list NOISE
  -- offers on COLOUR - WHITE/PINK/DUST plus whatever is in audio/. A loop
  -- here always plays at its own recorded speed; there is no tone control
  -- on this page to re-time it with.
  params:add_option("p_grain_type", "spettru grain type", noise_types, 2)
  params:set_action("p_grain_type", function(x) engine.pgraintype(x) end)

  params:add_control("p_wet", "spettru wet",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("p_wet", function(x) engine.pwet(x) end)

  -- INPUT: which granulator this stage listens to. 0 is GRAINSWARM 1, the
  -- middle is 2, the top is both - and everything between those is a real
  -- crossfade, because it is a knob and it is a modulation destination.
  -- FREEZE is the page's long-K3 toggle rather than a mode, because it is the
  -- one control here you reach for mid-phrase.
  params:add_option("p_freeze", "spettru freeze", { "off", "on" }, 1)
  params:set_action("p_freeze", function(x)
    -- FREEZE is not an engine control any more. The bank holds whatever it
    -- was last told, so freezing is simply Lua not sending - and unfreezing
    -- has to send once, or nothing moves until the next slice tick.
    if x == 1 then send_bank(true) end
  end)

  params:add_separator("stillel", "DELAY")

  -- EUCLID is density; its mode is the step count, so the knob and the mode
  -- are two different axes rather than the same one twice.
  params:add_control("s_euclid", "euclid",
    controlspec.new(0, 1, "lin", 0, 0.45, ""))
  params:add_option("s_steps", "euclid steps", SSTEP_NAMES, 1)

  -- 50 = the granulator's own rate. Below divides it down, above multiplies.
  -- Unquantised on purpose: when RATE is clocked the knob snaps to musical
  -- ratios on the way out, but when RATE is FREE it is a continuous detune,
  -- and a stepped param would make the fine encoder do nothing there.
  params:add_control("s_rate", "delay rate",
    controlspec.new(0, 100, "lin", 0, 50, ""))
  params:set_action("s_rate", function() update_timing() end)

  params:add_control("s_spread", "spread",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))

  -- PITCH SPREAD, the second parameter on the SPREAD cell (E3). A "speed"
  -- style repitch of the taps - not a time-stretched pitch shift - so each
  -- mode just picks how the fixed -1..+1 octave ramp across the eight tap
  -- slots is quantised: chromatic (OCT), octaves-and-fifths only (OCT+5TH),
  -- or the master scale (SCALE), reusing the same degree logic as
  -- GRAINSWARM's V.SPRD.
  params:add_option("s_pspread", "pitch spread",
    { "OFF", "OCT", "OCT+5TH", "SCALE" }, 1)

  params:add_control("s_feedback", "feedback",
    controlspec.new(0, 1, "lin", 0, 0.35, ""))
  params:set_action("s_feedback", function(x) engine.sfb(x) end)

  params:add_control("s_tilt", "delay tilt",
    controlspec.new(-1, 1, "lin", 0, -0.2, ""))
  params:set_action("s_tilt", function(x) engine.stilt(x) end)

  params:add_option("s_tilt_mode", "delay tilt band", { "LOW", "MID", "HIGH" }, 2)
  params:set_action("s_tilt_mode", function(x) engine.stiltxover(TILT_XOVER[x]) end)

  params:add_control("s_diffuse", "diffuse",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("s_diffuse", function(x) engine.sdiffuse(x) end)

  -- WOW used to live here, wobbling the eight tap read positions. It is on
  -- COLOUR now, where it drifts the whole coloured signal instead - a bigger
  -- gesture, and it frees this slot for the thing that actually needs a knob
  -- on this page.
  -- dry by default: the delay is an effect you reach for, not something the
  -- instrument arrives wearing
  params:add_control("s_wet", "delay wet",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("s_wet", function(x) engine.swet(x) end)

  params:add_option("s_link", "tap follows grain", { "off", "on" }, 1)
  params:set_action("s_link", function() sent.taps = nil end)

  params:add_option("s_hold", "delay hold", { "off", "on" }, 1)
  params:set_action("s_hold", function(x) engine.shold(x - 1) end)

  params:add_separator("kuluri", "COLOUR")

  params:add_control("drive", "drive",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("drive", function(x) engine.drive(x) end)

  params:add_control("crush", "crush",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("crush", function(x) engine.crush(x) end)

  -- LOSS is a perceptual-codec failure rather than a converter one: spectral
  -- holes that swirl frame to frame, and a bandwidth that collapses.
  -- LOSS is its own knob now. CRUSH is quantisation and sample rate only,
  -- which is what the word means everywhere else.
  params:add_control("loss", "loss",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("loss", function(x) engine.loss(x) end)

  params:add_option("crush_mode", "crush mode",
    { "BIT CRUSH", "REDUX", "BIT+REDUX" }, 3)
  params:set_action("crush_mode", function(x) engine.crushmode(x) end)

  params:add_control("noise", "noise",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("noise", function(x) engine.noise(x) end)

  -- WHITE, PINK and DUST are washes. Everything after that is whatever is
  -- sitting in audio/ - RAIN, RICE, COUSCOUS, PINE and SEA out of the box,
  -- plus anything a user drops in themselves. N.TONE re-times a loop rather
  -- than filtering it - turn it down and the loop slows and drops, turn it
  -- up and it speeds up and rises, 1200Hz being each loop's own recorded
  -- speed.
  params:add_option("noise_type", "noise type", noise_types, 2)
  params:set_action("noise_type", function(x) engine.noisetype(x) end)

  params:add_control("noise_decay", "noise decay",
    controlspec.new(0.01, 4, "exp", 0, 0.25, "s"))
  params:set_action("noise_decay", function(x) engine.noisedecay(x) end)

  params:add_control("noise_tone", "noise tone",
    controlspec.new(60, 12000, "exp", 0, 1200, "Hz"))
  params:set_action("noise_tone", function(x) engine.noisetone(x) end)

  params:add_control("noise_dyn", "noise dyn",
    controlspec.new(0.25, 4, "exp", 0, 2, "x"))
  params:set_action("noise_dyn", function(x) engine.noisedyn(x) end)

  -- WOW. Tape drift on the whole of COLOUR, cubic in the knob: the bottom two
  -- thirds is the slow unsteadiness that stops digital sounding rigid, and
  -- only the top goes properly seasick.
  params:add_control("k_wow", "kuluri wow",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("k_wow", function(x) engine.kwow(x) end)

  params:add_option("bypass", "kuluri bypass", { "off", "on" }, 1)
  params:set_action("bypass", function(x) engine.bypass(x - 1) end)

  params:add_separator("modni", "MODNI")

  for i = 1, NLFO do
    local pre = "lfo" .. i .. "_"
    params:add_option(pre .. "shape", i .. " shape", LFO_SHAPES, 3)  -- SINE

    params:add_control(pre .. "rate", i .. " rate",
      controlspec.new(0, 100, "lin", 0, 50, ""))

    -- spread the eight starting phases evenly round the cycle. This was
    -- (i - 1) * 0.25, which was right for two LFOs and put LFOs 6, 7 and 8 at
    -- 1.25, 1.5 and 1.75 - outside their own 0..1 spec, which add_control does
    -- not clamp. The grid drew a bar past the end of the row and asserted.
    params:add_control(pre .. "phase", i .. " phase",
      controlspec.new(0, 1, "lin", 0, (i - 1) / NLFO, ""))

    params:add_control(pre .. "machine", i .. " machine",
      controlspec.new(0, 1, "lin", 0, 0, ""))

    for s = 1, LFO_DEST do
      params:add_option(pre .. "d" .. s, i .. " dest " .. s, MOD_NAMES, 1)
      -- switching a destination has to release the old one, or it stays where
      -- the LFO left it
      params:set_action(pre .. "d" .. s, function() mod_apply() end)
      params:add_control(pre .. "a" .. s, i .. " amount " .. s,
        controlspec.new(-1, 1, "lin", 0, 0, ""))
    end
  end

  -- envelope follower
  params:add_control("env_atk", "env attack",
    controlspec.new(0.002, 1, "exp", 0, 0.01, "s"))
  params:add_control("env_rel", "env release",
    controlspec.new(0.02, 4, "exp", 0, 0.35, "s"))
  -- WHAT THE FOLLOWER IS LISTENING TO. It was the master output and nothing
  -- else, which is right for ducking and useless for playing something in:
  -- an envelope taken from the output of a chain that is already reacting to
  -- the input is a feedback loop with a delay in it.
  --
  -- OUT stays first, and is the default, so an existing patch does not change
  -- character the moment it is loaded.
  params:add_option("env_src", "env source",
    { "OUT", "GS1", "GS2", "IN L+R", "LEFT", "RIGHT" }, 1)

  params:add_control("env_sens", "env sensitivity",
    controlspec.new(0.5, 40, "exp", 0, 6, "x"))
  for s = 1, 2 do
    params:add_option("env_d" .. s, "env dest " .. s, MOD_NAMES, 1)
    params:set_action("env_d" .. s, function() mod_apply() end)
    params:add_control("env_a" .. s, "env amount " .. s,
      controlspec.new(-1, 1, "lin", 0, 0, ""))
  end

  params:add_option("mod_hold", "lfo hold", { "off", "on" }, 1)
  params:add_option("mod_bypass", "lfo bypass", { "off", "on" }, 1)
  params:set_action("mod_bypass", function() mod_apply() end)

  params:add_separator("hallat", "SIGNAL")

  -- Everything here is in dB, with the bottom of each fader a true zero.
  -- The returns reach +12 because a SEND with a quiet return is the whole
  -- reason this page exists.

  -- POST: the sends hear the GRAINSWARM fader, so pulling it down takes the
  -- effects with it. PRE: they do not, so the tails ring on as the source
  -- fades away.
  -- COMP, on the master where a compressor belongs: mixer > COMP > the hidden
  -- glue > limiter. It came off COLOUR, where it was compressing the colour
  -- stage's own output rather than holding a mix together.
  params:add_control("mx_comp", "master comp",
    controlspec.new(0, 1, "lin", 0, 0.2, ""))
  params:set_action("mx_comp", function(x) engine.mcomp(x) end)

  -- VERB, after COMP: mixer > COMP > VERB > the hidden glue > limiter. A
  -- compressor does not know a reverb tail from a transient, so COMP runs on
  -- the dry mix and VERB gets whatever COMP leaves behind - its tail keeps
  -- the dynamics COMP gave it rather than having them ironed flat. VERB
  -- itself is wet/dry only now, and a true bypass at zero regardless of
  -- TIME: nothing about the tank's size or decay lives on this knob any
  -- more.
  params:add_control("r_verb", "verb amount",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("r_verb", function(x) engine.rverb(x) end)

  -- TIME is E3 on the VERB cell: size and decay together, one knob because
  -- turning a tank up usually means "bigger AND longer" as a single move.
  -- Pushed to the top it goes past "huge, long tail" into FROZEN - the tank's
  -- feedback holds instead of decaying, a shimmer-tank freeze rather than a
  -- tap-tempo delay - see the note by rdecay in the engine for the curve.
  params:add_control("r_decay", "verb time",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("r_decay", function(x) engine.rtime(x) end)

  -- SHIMMER: some of the tail is pitch shifted up and returned to the tank,
  -- so a held chord grows an ascending ghost instead of only decaying - the
  -- Valhalla move. MODE picks the interval it climbs by; see send_rshimmer
  -- for why SCALE reaches for a fifth rather than an octave.
  params:add_control("r_shimmer", "shine amount",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("r_shimmer", function(x) engine.rshimmer(x) end)

  params:add_option("r_shimmer_mode", "shine interval",
    { "OCT", "5TH", "SCALE" }, 1)
  params:set_action("r_shimmer_mode", function() send_rshimmer() end)

  -- -0.1 dB, not -0.5. With the routing summing up to eight feeds the limiter
  -- is doing real work now, and the last tenth of a decibel of headroom is
  -- worth having when it is the difference between catching a peak and
  -- shaving it.
  params:add_control("mx_limit", "limiter ceiling",
    controlspec.new(-24, 0, "lin", 0.1, -0.1, "dB"))
  params:set_action("mx_limit", function(x) engine.limceil(dbl(x)) end)

  params:add_control("mx_out", "output level",
    controlspec.new(-60, 10, "lin", 0.1, 0, "dB"))
  params:set_action("mx_out", function(x)
    engine.amp(dbl(x + (params:get("mx_dim") == 2 and -15 or 0)))
  end)

  params:add_separator("midi", "MIDI")

  params:add_option("mi_mode", "notes",
    { "off", "voices", "transpose" }, 1)
  params:set_action("mi_mode", function(x)
    -- leaving VOICES has to hand the chord back, or the grid stays blank.
    -- Entering it takes the voices straight away rather than leaving the old
    -- chord droning until the first note - switching to keyboard control and
    -- having the previous chord keep playing is the confusing option.
    if x ~= 2 then
      midi_release_all()
    elseif midi_saved == nil then
      midi_saved = midi_snapshot()
      for i = 1, NVOICE do grains[i].on = false end
      send_voices()
    end
  end)

  params:add_number("mi_dev", "device", 1, 4, 1)
  params:set_action("mi_dev", function() midi_connect() end)

  params:add_option("mi_ch", "channel",
    { "all", "1", "2", "3", "4", "5", "6", "7", "8",
      "9", "10", "11", "12", "13", "14", "15", "16" }, 1)

  params:add_option("mi_vel", "velocity to level", { "off", "on" }, 2)

  params:add_option("mx_dim", "dim output", { "off", "on" }, 1)
  params:set_action("mx_dim", function(x)
    engine.amp(dbl(params:get("mx_out") + (x == 2 and -15 or 0)))
  end)

  -- the engine passes the dry signal through itself, so norns' own in>out
  -- monitor path would double it
  params:add_option("monitor", "norns in>out monitor", { "off", "on" }, 1)
  params:set_action("monitor", function(x) audio.level_monitor(x == 2 and 1 or 0) end)

  params:add_separator("perf", "PERFORMANCE")

  -- SCREEN FPS.
  --
  -- On a norns, every screen call and every encoder event are handled by the
  -- SAME thread. A frame that takes too long does not merely drop a frame -
  -- it holds the encoder queue shut, and what you feel is a knob that does
  -- nothing and then jumps several steps at once when the thread comes back.
  -- A shield with a Pi 4 in it has the headroom to draw these pages at
  -- twenty-five; a factory norns, on a Pi 3, does not always.
  --
  -- Nothing about the instrument changes with this - the animation is all
  -- time-based and advances by dt - it is the number of times a second the
  -- picture is rebuilt.
  params:add_option("fps", "screen fps", { "25", "20", "15", "10" }, 1)
  params:set_action("fps", function(x)
    FPS = ({ 25, 20, 15, 10 })[x] or 25
    if ui_metro then
      ui_metro.time = 1 / FPS
      ui_metro:start()
    end
  end)

  -- GRID FPS, separately, because the grid is a different bottleneck: not
  -- cairo, but up to a hundred and twenty-eight LED writes and a serial frame
  -- per refresh. The display already skips a refresh when nothing on the grid
  -- moved; this caps how often it may send one when things ARE moving.
  params:add_option("grid_fps", "grid fps", { "25", "15", "10" }, 1)
  params:set_action("grid_fps", function(x)
    GRID_FPS = ({ 25, 15, 10 })[x] or 25
  end)
end

-- ---------------------------------------------------------------------------
-- animation: the heads and the grain markers are modelled here rather than
-- polled from the engine. one fewer moving part, and for a display it is
-- indistinguishable.
-- ---------------------------------------------------------------------------

local function sos_amount(w)
  w = w or 1
  local s = params:get(swid(w, "sos"))
  if params:get(swid(w, "lock")) == 2 then s = 1 end
  return s
end

-- how far MACHINE has slid out for LFO i, 0..1, eased
function mach_reveal(i)
  return mach.r[i] or 0
end

function mach_advance(dt)
  for i = 1, NLFO do
    local want = (params:get(LFO_ID[i].shape) <= 2) and 1 or 0
    local p = mach.p[i] or 0
    local step = dt / mach.t
    if p < want then p = math.min(want, p + step)
    elseif p > want then p = math.max(want, p - step) end
    mach.p[i] = p
    mach.r[i] = p * p * (3 - (2 * p))       -- smoothstep
  end
end

-- The granulator display, run once per granulator. Everything in here reads
-- that swarm's parameters and writes that swarm's VS entry; nothing is shared
-- but the input level and the output envelope.
local function advance_swarm(dt, w)
  local V = VS[w]
  local G = gr(w)
  local pre = (w == 2) and "n" or "m"
  -- capture, mirroring the engine's sound-on-sound blend so the display
  -- layers and freezes exactly as the buffer does
  local sos = sos_amount(w)
  local ret = math.min(sos * 1.05, 1)
  local ing = util.clamp((1 - sos) * 4, 0, 1)

  -- SOURCE, mirrored from the engine. OFF gates the write shut and the
  -- displayed buffer holds, exactly as the real one does.
  local src = params:get(swid(w, "src"))
  if src == 1 then ing = 0 end
  local lvl = in_amp
  if src == 5 then
    -- SWARM 2 RECORDING SWARM 1, and this is the line that made it look
    -- broken.
    --
    -- It used to be `in_amp * (is swarm 1 firing)`. in_amp is the LIVE INPUT
    -- level - so the moment swarm 1 was playing from a buffer it had already
    -- captured, with nothing new coming in the front, this went to zero and
    -- swarm 2's waveform drew a flat line. The engine was recording swarm 1
    -- perfectly well the whole time; the picture said it was getting nothing,
    -- which is worse than no picture.
    --
    -- The fix is to ask the right thing. Swarm 1's display already models what
    -- swarm 1 is playing: the captured amplitude AT ITS OWN PLAYHEAD, gated by
    -- whether a grain is firing. That is the same model its own waveform is
    -- drawn from, so the two views agree with each other - which is the
    -- property that actually matters here.
    --
    -- Still a model and not a measurement: nothing polls swarm 1's output.
    local V1 = VS[1]
    local f = 0
    for v = 1, NVOICE do
      if grains[v].on then f = math.max(f, V1.flash[v] or 0) end
    end
    local sl = util.clamp(
      math.floor(win_map(V1.spos, 1) * WAVE_N) + 1, 1, WAVE_N)
    lvl = (V1.wave[sl] or 0) * (0.35 + (0.65 * f))
  end

  V.slot_peak = math.max(V.slot_peak, lvl)
  V.wpos = (V.wpos + (dt / buflen(w))) % 1
  local slot = util.clamp(math.floor(V.wpos * WAVE_N) + 1, 1, WAVE_N)
  if slot ~= V.last_slot then
    -- fill any slots skipped between frames so there are no gaps
    local i = V.last_slot
    local guard = 0
    repeat
      i = (i % WAVE_N) + 1
      V.wave[i] = math.min((V.wave[i] * ret) + (V.slot_peak * ing), 1)
      guard = guard + 1
    until i == slot or guard > WAVE_N
    V.last_slot = slot
    V.slot_peak = 0
  end

  -- the display normalises against the loudest slot, with a floor so silence
  -- is not amplified into noise. raw input amplitude is far too small to read
  -- at ten pixels of half-height otherwise.
  local mx = 0
  for i = 1, WAVE_N do
    if V.wave[i] > mx then mx = V.wave[i] end
  end
  -- instant attack, slow release, so the display does not pump on every hit
  if mx > V.wave_peak then
    V.wave_peak = mx
  else
    V.wave_peak = V.wave_peak + ((mx - V.wave_peak) * 0.05)
  end

  -- scan head
  local mode = params:get(swid(w, "scan_mode"))
  local scan = params:get(swid(w, "scan"))
  if mode == 1 then
    V.spos = (V.spos + (dt * ((scan * 3) - 1) / buflen(w))) % 1
  elseif mode == 2 then
    V.spos = scan
  else
    V.spos = (V.wpos - ((sent[pre .. "delay"] or 0) / buflen(w))) % 1
  end

  -- grain markers, spawned at the engine's trigger rate
  local hz = sent[pre .. "rate"] or 8
  V.grain_acc = V.grain_acc + (dt * hz)
  local spawns = 0
  while V.grain_acc >= 1 and spawns < 6 do
    V.grain_acc = V.grain_acc - 1
    spawns = spawns + 1
    local spray = params:get(swid(w, "spray"))
    local base = params:get(swid(w, "pitch"))
    local sc = params:get("m_scale")
    -- The step the euclidean generators are on. Free-running; euclid_hit takes
    -- it modulo the pattern length and applies each voice's own rotation, so
    -- one counter drives all eight and a single playhead column is honest for
    -- every row at once.
    V.flash.step = (V.flash.step or 0) + 1
    V.flash.life = V.flash.life or {}
    for v = 1, NVOICE do
      local st = G[v]
      -- Gate the DISPLAY the way the engine gates the voice: the euclidean
      -- figure and the probability coin. This used to spawn a dot for every
      -- lit voice on every tick, so at EUCLID 4/16 the dot field was four
      -- times denser than the sound - the picture was of a rhythm that was
      -- not being played.
      if st.on and euclid_hit(v, V.flash.step, w)
        and (math.random() < (st.prob or 1)) and #V.marks < MAX_MARKS then
        local off = (math.random() * 2 - 1) * spray * 0.25
        table.insert(V.marks, {
          pos = win_map((V.spos + off) % 1, w),
          age = 0,
          life = util.clamp((sent[pre .. "size"] or 0.1) * 2.5, 0.30, 1.4),
          voice = v,
          pitch = snap_to_scale(base + st.semi + (OCTAVES[st.oct] * 12), sc),
          amp = out_amp_disp,
        })
        V.flash[v] = 1
        -- the V.flash lasts as long as the GRAIN does, so a long SIZE holds the
        -- step lit and a short one blinks: the fade IS the voice's envelope
        V.flash.life[v] = util.clamp((sent[pre .. "size"] or 0.1) * 2.2, 0.13, 1.2)
        -- and the PAPPUS page gets its seed here, because this is the only
        -- place in the script that knows a GRAIN went off rather than a voice
        -- being switched on
        pappus_seed(w, st.lvl or 1,
          snap_to_scale(base + st.semi + (OCTAVES[st.oct] * 12), sc))
      end
    end
  end

  for i = #V.marks, 1, -1 do
    local m = V.marks[i]
    m.age = m.age + dt
    if m.age >= m.life then table.remove(V.marks, i) end
  end

  for v = 1, NVOICE do
    local lf = (V.flash.life and V.flash.life[v]) or 0.16
    V.flash[v] = math.max(0, V.flash[v] - (dt / lf))
  end

  filt_t = (filt_t + dt) % 3600
  if kuluri_advance then kuluri_advance(dt) end

  -- fit the grain-dot pitch axis to the notes in play, eased so it glides
  -- rather than jumping when a row is toggled
  do
    local base = params:get(swid(w, "pitch"))
    local sc = params:get("m_scale")
    local lo, hi = 1e9, -1e9
    for i = 1, NVOICE do
      local st = G[i]
      if st.on then
        local pp = snap_to_scale(base + st.semi + (OCTAVES[st.oct] * 12), sc)
        if pp < lo then lo = pp end
        if pp > hi then hi = pp end
      end
    end
    if lo > hi then lo, hi = -4, 4 end
    local sw = params:get(swid(w, "swarm"))
    if sw > 0.02 then
      local iv = SWARM_IV[params:get(swid(w, "swarm_mode"))]
      lo = lo + math.min(iv[1], iv[2], 0)
      hi = hi + math.max(iv[1], iv[2], 0)
    end
    local mid = (lo + hi) * 0.5
    local span = math.max(hi - lo, 7) * 0.5
    local tlo, thi = mid - span - 1.5, mid + span + 1.5
    local k = math.min(dt * 3, 1)
    V.pitch_lo = V.pitch_lo + ((tlo - V.pitch_lo) * k)
    V.pitch_hi = V.pitch_hi + ((thi - V.pitch_hi) * k)
  end
end

local function advance(dt)
  advance_swarm(dt, 1)
  advance_swarm(dt, 2)

  -- DELAY playhead sweeping one delay cycle, flashing taps as it crosses
  do
    local prev = stil_phase
    stil_phase = (stil_phase + (dt / math.max(stil_cycle, 0.02))) % 1
    local wrapped = stil_phase < prev
    for i = 1, NTAP do
      local t = taps[i]
      if t.on and stil_cycle > 0 then
        local tp = t.time / stil_cycle
        if (not wrapped and tp > prev and tp <= stil_phase)
          or (wrapped and (tp > prev or tp <= stil_phase)) then
          tap_flash[i] = 1
        end
      end
      tap_flash[i] = math.max(0, tap_flash[i] - (dt * 2.6))
    end
  end

  -- envelope of what COLOUR is actually putting out, for the visualiser
  local ocoeff = math.exp(-dt / 0.18)
  out_amp_disp = math.min(math.max(out_amp, out_amp_disp * ocoeff), 1)
  out_amp = 0

  local decay = params:get("noise_decay")
  local coeff = math.exp(-dt / decay)
  env_disp = math.min(math.max(in_amp, env_disp * coeff), 1)
  in_amp = 0
end


-- ---------------------------------------------------------------------------
-- SKENI - eight scenes, and a knob between any two of them
--
-- A scene is every performance parameter plus the grid state, because a recall
-- that leaves the grid behind only restores half the sound. Two slots are
-- nominated A and B and MORPH crossfades between them.
--
-- The morph only touches parameters that actually DIFFER between the two
-- scenes. That list is computed once, when A, B or the stored scenes change,
-- and it matters: setting all sixty parameters at the display rate would be
-- sixty engine messages per frame for the sake of the handful that moved.
-- Option parameters cannot be interpolated, so they switch at the halfway
-- point; grain pitch does the same, while per-voice level and probability are
-- continuous and glide.
-- ---------------------------------------------------------------------------

-- [1..120] = { p = {}, g = {}, t = {}, wav = path } or nil
local scenes = {}

-- Everything reachable from a page, plus the handful that only live in the
-- params menu. Built from PAGES so it cannot drift out of step with the UI.
local SCENE_EXTRA = {
  "m_scale", "m_rate_free", "m_euclid", "m_elen", "noise_dyn", "s_steps", "s_link",
  "m_lock", "s_hold", "p_freeze", "bypass", "mx_dim",
  "env_d1", "env_d2", "mod_bypass",
  "n_euclid", "n_elen", "n_lock",
  -- every LFO's shape and destination are cell MODES now, so scene_ids picks
  -- them up from PAGES; they were listed here when there were two of them and
  -- the list would have to grow by hand every time an LFO was added
}

local function scene_ids()
  local seen, out = {}, {}
  local function add(id)
    if id and not seen[id] then seen[id] = true; out[#out + 1] = id end
  end
  for _, pg in ipairs(PAGES) do
    if pg.kind ~= "ritratt" then
      for _, c in ipairs(pg.cells) do
        add(c.id); add(c.mode); add(c.alt)
        -- the swapped-in parameter is a real setting even when it is not the
        -- one on screen, so a snapshot has to carry both
        if c.swap then add(c.swap.id); add(c.swap.mode); add(c.swap.alt) end
      end
    end
  end
  for _, id in ipairs(SCENE_EXTRA) do add(id) end
  return out
end

local SIDS

local function scene_capture()
  local sc = { p = {}, g = {}, g2 = {}, g3 = {}, t = {} }
  for _, id in ipairs(SIDS) do sc.p[id] = params:get(id) end
  for i = 1, NVOICE do
    local v = grains[i]
    sc.g[i] = { on = v.on, semi = v.semi, oct = v.oct, lvl = v.lvl,
                prob = v.prob }
    -- g2 is a separate key, not an extension of g: an OLD snapshot has no g2
    -- at all, and it has to keep loading rather than blowing up or silently
    -- writing swarm 1's chord into swarm 2.
    local u = grains2[i]
    sc.g2[i] = { on = u.on, semi = u.semi, oct = u.oct, lvl = u.lvl,
                 prob = u.prob }
    -- g3 is RESONATOR's own chord, same reasoning as g2 above.
    local sp = sp_chord[i]
    sc.g3[i] = { on = sp.on, semi = sp.semi, oct = sp.oct, lvl = sp.lvl }
  end

  -- THE WAVEFORM PICTURE, both granulators.
  --
  -- The trace is not read back from the buffer - nothing reads a 60 second
  -- server buffer into Lua sixty times a second - it is a model the display
  -- builds as the audio goes past. So restoring the AUDIO restored the sound
  -- and left the picture blank, which reads as "the snapshot lost my buffer"
  -- when the buffer is sitting right there.
  --
  -- Quantised to a byte on the way in. It is drawn twenty-eight pixels tall;
  -- eight bits is four more than the display can show, and full floats would
  -- put thirty thousand long decimals in the scene file.
  sc.w = {}
  for w = 1, 2 do
    local a = {}
    for i = 1, WAVE_N do
      a[i] = math.floor(util.clamp(VS[w].wave[i] or 0, 0, 1) * 255 + 0.5)
    end
    sc.w[w] = { q = a, peak = VS[w].wave_peak }
  end
  for i = 1, NTAP do
    sc.t[i] = { step = manual[i].step, on = manual[i].on }
  end
  return sc
end

-- Put the stored trace back. A snapshot from before this existed has no `w`
-- at all and is left alone rather than blanked: an old snapshot should look
-- like it did, which is empty, not wrong.
function scene_apply_wave(sc)
  if not (sc and sc.w) then return end
  for w = 1, 2 do
    local src = sc.w[w]
    if src and src.q then
      for i = 1, WAVE_N do VS[w].wave[i] = (src.q[i] or 0) / 255 end
      VS[w].wave_peak = src.peak or 0.05
    end
  end
end

local function scene_path()
  if norns and norns.state and norns.state.data then
    return norns.state.data .. "scenes.data"
  end
end

local function scene_save()
  local path = scene_path()
  if not (path and tab and tab.save) then return end
  pcall(tab.save, scenes, path)
end

local function scene_apply(sc)
  if not sc then return end
  for _, id in ipairs(SIDS) do
    if sc.p[id] ~= nil then params:set(id, sc.p[id]) end
  end
  for i = 1, NVOICE do
    if sc.g[i] then
      local v, u = grains[i], sc.g[i]
      v.on, v.semi, v.oct = u.on, u.semi, u.oct
      v.lvl, v.prob = u.lvl or 1, u.prob or 1
    end
    if sc.g2 and sc.g2[i] then
      local v, u = grains2[i], sc.g2[i]
      v.on, v.semi, v.oct = u.on, u.semi, u.oct
      v.lvl, v.prob = u.lvl or 1, u.prob or 1
    end
    if sc.g3 and sc.g3[i] then
      local v, u = sp_chord[i], sc.g3[i]
      v.on, v.semi, v.oct, v.lvl = u.on, u.semi, u.oct, u.lvl or 1
    end
  end
  for i = 1, NTAP do
    if sc.t[i] then manual[i].step, manual[i].on = sc.t[i].step, sc.t[i].on end
  end
  scene_apply_wave(sc)
  send_voices()
  send_voices(2)
  send_bank(true)
  sent.taps = nil
end

-- ---------------------------------------------------------------------------
-- SNAPSHOTS - one hundred and twenty snapshots
--
-- A snapshot is the whole instrument: every parameter, the grid chord, the
-- delay taps, AND the audio sitting in the granulator's buffer. That last part
-- is what makes it a snapshot rather than a preset - recall a slot and the
-- same sound is in the same buffer, so the settings mean what they meant.
--
-- Saving FREEZES the buffer, because a recording that is still running is not
-- a thing you can have taken a picture of. LOCK goes on as part of the save.
--
-- The audio is written to the script's own data folder as 16-bit mono at the
-- current BUFFER length. Sixty seconds of float is 11 MB and there are a
-- hundred and twenty slots; sixteen-bit at the default eight seconds is about
-- 750 kB, and what is stored is granulation source about to be cut into 50 ms
-- grains, so the last bits of dynamic range are not what matters.
-- ---------------------------------------------------------------------------

local SNAP_N = 120                  -- fifteen columns of eight, the grid exactly
local SNAP_W = 15
local SNAP_HOLD = 0.6                 -- how long a hold has to be
local snap = { sel = 1, last = 0, hold = nil, mod16 = {},
               busy = false, fill = {}, want = {}, pulse = {}, act = nil }
for i = 1, SNAP_N do
  snap.fill[i], snap.want[i], snap.pulse[i] = 0, 0, 0
end

-- Start a hold. The animation runs WITH the finger rather than after it, so
-- the square fills as you press and drains back if you let go early - which
-- means the gesture is its own progress bar and you can always change your
-- mind. The commit happens the moment it completes, still held, because that
-- is when the feedback should arrive; the release afterwards does nothing.
function snap_hold_start(i, mode)
  snap.act = { slot = i, mode = mode, t0 = util.time(),
               from = snap.fill[i] or 0,
               target = (mode == "save") and 1 or 0 }
end

function snap_hold_end()
  local a = snap.act
  snap.act = nil
  if not a then return false end
  if a.done then return true end
  -- The commit normally happens in the animation tick, which is also what
  -- draws it. If that tick stuttered - a heavy frame, a page redraw - the
  -- gesture still happened, and losing a save because the screen was busy is
  -- not acceptable. So check the clock as well as the animation.
  if (util.time() - a.t0) >= SNAP_HOLD then
    if a.mode == "save" then snap_store(a.slot) else snap_clear(a.slot) end
    snap.pulse[a.slot] = 1
    return true
  end
  return false
end

local function snap_dir()
  if norns and norns.state and norns.state.data then
    return norns.state.data .. "ritratt/"
  end
end

-- FOUR files per snapshot: a left and a right for each granulator, since the
-- capture is a pair of mono buffers. The left file keeps the name it always
-- had, so an old snapshot still finds its audio.
local function snap_wav(n, right)
  local d = snap_dir()
  return d and string.format(right and "%s%03d-r.wav" or "%s%03d.wav", d, n)
end

-- GRAINSWARM 2's capture, in its own files beside the first. A snapshot that
-- restored one of the two buffers would come back half silent, which is the
-- exact bug the mkdir fix was about - just with a different cause.
local function snap_wav2(n, right)
  local d = snap_dir()
  return d and string.format(right and "%s%03d-b-r.wav" or "%s%03d-b.wav", d, n)
end

local function snap_save_table()
  local path = scene_path()
  if not (path and tab and tab.save) then return end
  pcall(tab.save, scenes, path)
end

-- SAVE. Freeze first, so what gets written is what you were listening to.
function snap_store(n)
  if n < 1 or n > SNAP_N then return end
  params:set("m_lock", 2)
  params:set("n_lock", 2)
  local sc = scene_capture()
  local w = snap_wav(n)
  if w then
    -- No pcall'd mkdir here any more. It used to try util.make_dir and fall
    -- back to a shell mkdir, both swallowed - and when both failed the write
    -- failed silently on the server, so a snapshot saved its parameters,
    -- reported success, and came back silent after a restart. The engine
    -- makes the directory itself now, immediately before writing, where
    -- File.mkdir is always available and the failure cannot be swallowed.
    --
    -- And no `if engine.snapwrite` guard: if that command is missing, that is
    -- a broken build and should be a loud error, not a quiet skip.
    -- FOUR files, not two: the capture is stereo, and each granulator is a
    -- pair of mono buffers. Buffer 1 and 2 are GRAINSWARM 1's left and right,
    -- 3 and 4 are GRAINSWARM 2's.
    local d1 = util.clamp(params:get("m_buflen"), 0.5, 60)
    engine.snapwrite(1, w, d1)
    engine.snapwrite(2, snap_wav(n, true), d1)
    sc.wav, sc.wavr = w, snap_wav(n, true)
  end
  local w2 = snap_wav2(n)
  if w2 then
    local d2 = util.clamp(params:get("n_buflen"), 0.5, 60)
    engine.snapwrite(3, w2, d2)
    engine.snapwrite(4, snap_wav2(n, true), d2)
    sc.wav2, sc.wav2r = w2, snap_wav2(n, true)
  end
  scenes[n] = sc
  snap.want[n] = 1
  snap.last = n
  snap_save_table()
end

-- NEW PROJECT. An empty slot is not "nothing to load" - it is a clean sheet.
-- Everything back to its default, every modulation slot released, the chord
-- back to one voice and the buffer wiped, so what you get is the instrument as
-- it comes rather than the last patch with a few things moved.
-- Everything back to its defaults, WITHOUT touching the buffers. Pulled out
-- of snap_blank because a recall needs exactly this and must not have the
-- other half: by the time it runs, the snapshot's audio is already sitting in
-- the buffer and a bufclear would wipe what was just loaded.
local function snap_defaults()
  for _, id in ipairs(SIDS) do param_reset(id) end
  for i = 1, NVOICE do
    for _, G in ipairs({ grains, grains2 }) do
      local v = G[i]
      v.on, v.semi, v.oct, v.lvl, v.prob = (i == 1), 0, 3, 1, 1
    end
    local sp = sp_chord[i]
    sp.on, sp.semi, sp.oct, sp.lvl = (i == 1), 0, 3, 1
  end
  for i = 1, NTAP do manual[i].step, manual[i].on = i - 1, (i == 1) end
  send_voices()
  send_voices(2)
  sent.taps = nil
  send_bank(true)
end

local function snap_blank()
  snap_defaults()
  -- bufclear wipes BOTH capture buffers: a new project starts on silence, and
  -- silence in one of the two is not silence. The picture goes with it.
  if engine.bufclear then engine.bufclear(1) end
  for w = 1, 2 do
    for i = 1, WAVE_N do VS[w].wave[i] = 0 end
    VS[w].wave_peak = 0.05
  end
  send_voices()
  send_voices(2)
  sent.taps = nil
  send_bank(true)
end

-- LOAD, as a two second morph.
--
-- The BUFFER cannot be crossfaded - it is one buffer and the granulator is
-- reading it - so that swaps at the start under a short duck, and everything
-- else glides across on top. Which is the right way round: the buffer is the
-- material and the parameters are the shape, so what you hear is the new
-- material arriving and then being formed.
--
-- Options and switches cannot be interpolated either; they flip at the
-- halfway point. Anything with a number behind it is a straight lerp.
-- LOAD, as a fade out and a fade in.
--
-- It used to be a two second MORPH: every differing parameter interpolated
-- across fifty steps while the buffer swapped underneath. It was a nice idea
-- and it did not survive contact with the routing rework - a morph is only
-- musical when the path between two settings is itself musical, and half of
-- what a snapshot holds now is topology. Sliding a feed from 0 to 0.7 walks a
-- granulator into a module it was bypassing; sliding a rate ratio walks
-- through every division on the way. What you heard was two seconds of
-- something neither snapshot contains.
--
-- So: duck to silence, change EVERYTHING at once in the dark, come back. The
-- fade is what makes it a transition rather than a jump, and the silence in
-- the middle is what makes the arrival read as arrival.
--
-- Each side of the duck is a full second, and there is a short pad of true
-- silence either side of the swap - long enough for the engine's own fade
-- Lag (60ms) to actually finish moving before anything changes underneath
-- it. No blending of the two snapshots themselves: everything still flips
-- at once, in the dark. Just a longer, cleaner dark.
function snap_recall(n)
  if snap.busy then return end
  local sc = scenes[n]
  snap.busy = true
  snap.last = n

  -- A RECALL IS A RESET, then the snapshot on top of it.
  --
  -- Applying the stored values on their own leaves everything the snapshot
  -- does NOT carry exactly where the last patch left it - anything added to
  -- the instrument since that slot was saved, and anything that was never in
  -- the scene list at all. What you get is the old patch wearing some of the
  -- new one, which is the sort of thing you notice an hour later.
  --
  -- SRC is the one that has to be forced rather than merely defaulted: it is
  -- not in the scene list, and if an input is armed when the snapshot's audio
  -- lands in the buffer, the live signal records straight over the top of it.
  -- Loading a snapshot has to leave you listening to the snapshot.
  local function swap()
    if sc then
      snap_defaults()
      scene_apply(sc)
    else
      snap_blank()
    end
    params:set("m_src", 1)
    params:set("n_src", 1)
  end

  if not (clock and clock.run) then
    swap()
    snap.busy = false
    return
  end

  clock.run(function()
    -- OUT, over a full second, in steps fine enough to read as a filter
    -- closing rather than a staircase.
    local steps = 60
    for k = 1, steps do
      engine.fade(1 - (k / steps))
      clock.sleep(1.0 / steps)
    end
    engine.fade(0)
    -- The engine's own fade control is a Lag.kr(fade, 0.06) - the ramp above
    -- gets it to zero, but the lag itself is still chasing that last step for
    -- another ~60ms after. Swapping the buffer and every parameter before it
    -- has actually settled is what the clicks were: the tail end of the OLD
    -- signal, still faintly live, hitting a hard parameter/buffer change.
    -- This pause is silence's turn to actually finish.
    clock.sleep(0.15)

    -- everything, in silence: the audio in both buffers, every parameter,
    -- both chords, the taps and the stored waveform pictures
    --
    -- DELAY's feedback line is not part of that - it reads and writes its
    -- buffer continuously regardless of the output fade, so left alone it
    -- would hand the new snapshot a line still full of the old one's
    -- repeats. Zeroed here, in the same silence, so what carries forward is
    -- only what the snapshot itself put there.
    engine.delayclear(1)
    if sc then
      -- An OLD snapshot has one file per granulator, from when the capture
      -- was mono. It is loaded by asking for the same file twice - it lands
      -- in both sides and comes back as the mono recording it was, rather
      -- than as a stereo one with a silent right.
      if sc.wav then
        engine.snapread(1, sc.wav)
        engine.snapread(2, sc.wavr or sc.wav)
      end
      if sc.wav2 then
        engine.snapread(3, sc.wav2)
        engine.snapread(4, sc.wav2r or sc.wav2)
      end
    elseif engine.bufclear then
      engine.bufclear(1)
    end
    swap()
    -- And the same margin before opening back up, so the new snapshot is
    -- fully in place - buffers read, parameters applied - before anything
    -- is audible again.
    clock.sleep(0.15)

    for k = 1, steps do
      engine.fade(k / steps)
      clock.sleep(1.0 / steps)
    end
    engine.fade(1)
    snap.busy = false
  end)
end

-- The stored scenes, for the test suite. `scenes` is reassigned wholesale
-- when the file is loaded from disk, so a reference handed out at startup
-- would go stale - this is a function for that reason.
function scene_table() return scenes end

function snap_clear(n)
  if not scenes[n] then return end
  -- all four files, or clearing a slot leaves three of them behind and the
  -- data folder fills up with audio nothing points at
  local sc = scenes[n]
  scenes[n] = nil
  snap.want[n] = 0
  for _, w in ipairs({ sc.wav, sc.wavr, sc.wav2, sc.wav2r }) do
    pcall(os.remove, w)
  end
  if snap.last == n then snap.last = 0 end
  snap_save_table()
end

function snap_occupied(n)
  return scenes[n] ~= nil
end

-- the fill animation. Saving fills the square, clearing dissolves it; both are
-- the same number moving, and the DRAW decides which of the two it looks like.
function snap_advance(dt)
  local a = snap.act
  local held = nil
  if a then
    local p = util.clamp((util.time() - a.t0) / SNAP_HOLD, 0, 1)
    local e = p * p * (3 - (2 * p))              -- eased, not linear
    snap.fill[a.slot] = a.from + ((a.target - a.from) * e)
    held = a.slot
    if p >= 1 and not a.done then
      a.done = true
      if a.mode == "save" then snap_store(a.slot) else snap_clear(a.slot) end
      snap.pulse[a.slot] = 1
    end
  end
  local k = math.min(dt * 5.5, 1)
  for i = 1, SNAP_N do
    -- a slot being held is driven by the finger; everything else eases to
    -- where it belongs, which is also what pulls an abandoned hold back
    if i ~= held then
      local w = snap.want[i]
      local f = snap.fill[i]
      if math.abs(w - f) < 0.004 then
        snap.fill[i] = w
      else
        snap.fill[i] = f + ((w - f) * k)
      end
    end
    if (snap.pulse[i] or 0) > 0 then
      snap.pulse[i] = math.max(0, snap.pulse[i] - (dt / 0.45))
    end
  end
end

-- something happened to this slot: swell and settle
function snap_pulse(i)
  snap.pulse[i] = 1
end

function snap_state()
  return snap
end

-- Column 16 is split top/bottom: rows 1-4 arm SAVE, rows 5-8 arm CLEAR. Either
-- half is a plain hold - any key in it counts, so a thumb can land on any of
-- the four rows and it still reads as "that half is down".
function snap_mods(st)
  st = st or snap
  local save_held, clear_held = false, false
  for row = 1, 4 do if st.mod16[row] then save_held = true end end
  for row = 5, 8 do if st.mod16[row] then clear_held = true end end
  return save_held, clear_held
end


-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

function init()
  add_params()
  -- SIXTY, not norns' hundred and twenty. A granular instrument whose grain
  -- rate is a division of the beat wants a slow beat: at 120 a 1/1 grain is
  -- two seconds and the useful divisions all bunch up at the fast end.
  --
  -- Set as the param's DEFAULT as well as its value, or "put this back" on
  -- the BPM cell - and the reset every snapshot recall now does - would hand
  -- back 120 and the instrument would have two different defaults.
  do
    local p = params:lookup_param("clock_tempo")
    if p then p.default = 60 end
    params:set("clock_tempo", 60)
  end

  params:bang()

  SIDS = scene_ids()
  do
    local path = scene_path()
    if path and tab and tab.load then
      local ok, loaded = pcall(tab.load, path)
      if ok and type(loaded) == "table" then scenes = loaded end
    end
    -- slots restored from disk start already full, or every one of them
    -- animates itself in on the first frame the page is looked at
    for i = 1, 120 do
      local on = scenes[i] and 1 or 0
      snap_state().fill[i], snap_state().want[i] = on, on
    end
  end

  midi_connect()

  -- We start RUNNING, always. Only a transport that has actually spoken to us
  -- can stop the buffer - see transport_set.
  run_state = nil
  transport_seen = false
  transport_set(false)
  resync_start()
  do
    local p = params:lookup_param("clock_source")
    if p then
      local prev = p.action
      p.action = function(x)
        if prev then prev(x) end
        -- a new source has told us nothing yet, so an old STOP must not
        -- follow us across. Release the gate and wait to be enrolled again.
        transport_seen = false
        transport_set(true)
      end
    end
  end

  send_voices()
  send_voices(2)
  send_bank(true)
  send_euclid()
  send_euclid(2)
  update_timing()

  -- SIGNAL's seven box meters. Untested here - the CroneEngine stub the test
  -- harness uses has addPoll as a no-op - so the callback records that a
  -- value ARRIVED as well as what it was, and the page draws a dash for any
  -- box that has never heard from the engine.
  for i = 1, 7 do
    local mp = poll.set("meter" .. i, function(v)
      local lv = util.clamp(v or 0, 0, 4)
      meters[i] = lv
      meter_seen[i] = true
      -- ...and the first two are also a source the envelope follower can be
      -- pointed at, which is the only reason these run at thirty rather than
      -- fifteen: a follower is a good deal more sensitive to a stepped input
      -- than a meter bar is.
      if i <= 2 then env.pk[i + 1] = lv end
    end)
    if mp then
      -- METERS 1 AND 2 ARE NOT ONLY METERS. They are the two granulator
      -- levels the envelope follower can be pointed at, and a follower is a
      -- good deal more sensitive to a stepped input than a bar is, so those
      -- two keep thirty a second. The other five only ever draw a box on
      -- SIGNAL, and a box redrawn faster than the screen refreshes is work
      -- nobody sees - every poll is an OSC message out of sclang, which on a
      -- Pi 3 is the process that starves the audio server when it is busy.
      mp.time = (i <= 2) and (1 / 30) or (1 / 12)
      mp:start()
    end
  end

  -- the two ends of the input separately now: the follower can be told to
  -- listen to one of them
  local pl = poll.set("amp_in_l", function(v)
    in_amp = math.max(in_amp, v)
    env.pk[4] = math.max(env.pk[4], v)
  end)
  -- Thirty, not sixty. These are accumulated as PEAKS between modulation
  -- ticks rather than sampled, so halving the rate halves the OSC traffic out
  -- of sclang without the follower ever seeing a gap - it sees a peak taken
  -- over twice as long, which is what a peak is for.
  pl.time = 1 / 30
  pl:start()
  local pr = poll.set("amp_in_r", function(v)
    in_amp = math.max(in_amp, v)
    env.pk[5] = math.max(env.pk[5], v)
  end)
  pr.time = 1 / 30
  pr:start()

  local pc = poll.set("cpu_avg", function(v) cpu = v end)
  pc.time = 0.5
  pc:start()

  -- MODNI's follower listens to the MASTER OUTPUT, not the input: what you
  -- want to duck or open against is what is coming out of the whole chain,
  -- including the grains, the delay and the limiter.
  local function on_out(v)
    out_amp = math.max(out_amp, v)
    env.pk[1] = math.max(env.pk[1], v)
  end
  local ol = poll.set("amp_out_l", on_out)
  ol.time = 1 / 30
  ol:start()
  local orr = poll.set("amp_out_r", on_out)
  orr.time = 1 / 30
  orr:start()

  last_t = util.time()
  ui_metro = metro.init()
  ui_metro.time = 1 / FPS
  ui_metro.event = function()
    local now = util.time()
    local dt = math.min(now - last_t, 0.2)
    last_t = now
    -- before anything else: the grain tick seeds the scene, and it can only
    -- do that if it already knows whether the scene is on screen
    pappus_live = (PAGES[page].kind == "pappus")
    update_timing()
    advance(dt)
    mach_advance(dt)
    wipe_advance(dt)
    snap_advance(dt)
    if spettru_strings then spettru_strings(dt) end
    vis_update(dt)
    pappus_advance(dt)
    redraw()
    grid_redraw()
  end
  ui_metro:start()

  -- modulation runs on its own faster metro: the LFOs would be visibly
  -- stepped at the 25 fps the display is happy with
  mod_last = util.time()
  mod_metro = metro.init()
  mod_metro.time = 1 / MOD_FPS
  mod_metro.event = function()
    local now = util.time()
    local dt = math.min(now - mod_last, 0.2)
    mod_last = now
    mod_advance(dt)
    mod_apply()
    -- RESONATOR's bank is laid out here rather than in the display tick:
    -- STRUCTURE, FREQUENCY, BRIGHTNESS and POSITION are all modulation
    -- destinations, so the layout has to be recomputed at the rate the
    -- modulators move, not at the rate the screen redraws.
    spettru_tick(dt)
  end
  mod_metro:start()

  -- MIDI clock already works: norns' clock source handles it and every
  -- tempo-derived value here reads clock.get_tempo() live. What was missing is
  -- PHASE - the granulator free-ran against the transport. These realign it.
  clock.transport.start = function()
    engine.sync(1)
    stil_phase = 0
    transport_set(true, true)
  end
  clock.transport.stop = function()
    transport_set(false, true)
  end
end

-- cleanup can run against a script whose init never finished, in which case
-- the polls were never created and poll.set returns nil
function stop_poll(name)
  local p = poll.set(name)
  if p then p:stop() end
end

function cleanup()
  if ui_metro then ui_metro:stop() end
  if mod_metro then mod_metro:stop() end
  for _, n in ipairs({ "amp_in_l", "amp_in_r", "cpu_avg",
                       "amp_out_l", "amp_out_r" }) do
    stop_poll(n)
  end
  -- The meters by COUNT, not by a hand-written list. The list said meter1 to
  -- meter6 and there have been seven since REVERB got a box on SIGNAL, so
  -- meter7 was left running after the script exited - a poll firing out of
  -- sclang forever, for a page no longer on screen.
  for i = 1, 7 do stop_poll("meter" .. i) end
  audio.level_monitor(1)
end

-- ---------------------------------------------------------------------------
-- encoders / keys
-- ---------------------------------------------------------------------------

-- which module the TRIQ page has highlighted, as a POSITION in the chain

function enc(n, d)
  local pg = PAGES[page]

  if pg.kind == "ritratt" then
    -- E2 walks the slots one at a time, E3 a whole row - which is what makes
    -- a hundred and twenty of them reachable without a grid
    local st = snap_state()
    if n == 2 then
      st.sel = util.clamp(st.sel + d, 1, SNAP_N)
    elseif n == 3 then
      st.sel = util.clamp(st.sel + (d * SNAP_W), 1, SNAP_N)
    end
    return
  end

  -- a held grain key takes the encoders over
  if held_voice and (pg.kind == "grain" or pg.kind == "grain2") then
    local w = pg.sw or 1
    local st = gr(w)[held_voice]
    if n == 2 then
      st.lvl = util.clamp(st.lvl + (d * 0.02), 0, 1)
      send_voices(w)
    elseif n == 3 then
      st.prob = util.clamp(st.prob + (d * 0.02), 0, 1)
      send_voices(w)
    end
    return
  end

  if n == 1 then
    -- step over cells that are not on screen. MACHINE only exists on STEP and
    -- GLIDE, so on a sine LFO the cursor walks straight past it.
    --
    -- On a GRAINSWARM page the cursor can also sit at ZERO, which is the
    -- WAVEFORM itself. SRC used to be a cell taking eighteen pixels off the
    -- row to say one word; the picture it describes is right there and four
    -- times the size, so the picture is the control. Selecting it highlights
    -- the band and E2 changes what is being recorded.
    local vis_sel = grain_vis_page(pg)
    local lo = vis_sel and 0 or 1
    local i, step = sel[page], (d > 0) and 1 or -1
    for _ = 1, math.abs(d) do
      local j = i
      repeat
        j = j + step
      until j < lo or j > #pg.cells or j == 0 or cell_visible(pg, j)
      if j < lo or j > #pg.cells then break end
      i = j
    end
    sel[page] = i
    return
  end
  -- CELL ZERO: the waveform. E2 walks the source, E3 does the same, because
  -- there is only one thing to change and having E3 do nothing on the one
  -- selection that is not a cell is a small mystery for no gain.
  if sel[page] == 0 then
    local w = pg.sw or 1
    params:delta(swid(w, "src"), d)
    return
  end

  -- and if the shape changed under it, do not leave the cursor on a cell that
  -- has since slid away
  if not cell_visible(pg, sel[page]) then
    local i = sel[page]
    while i > 1 and not cell_visible(pg, i) do i = i - 1 end
    sel[page] = i
  end
  local c = cell_at(pg, sel[page])
  if not c then return end
  -- BPM is a cell on SIGNAL now rather than a special case on TRIQ's E1, so
  -- the "you cannot move it while something else owns the tempo" rule has to
  -- live here. A knob that cannot do anything is worse than no knob, and the
  -- cell is drawn dimmed to say so.
  if c.id == "clock_tempo" and clock_external() then return end
  if n == 2 then
    bump(c.id, d, false)
  elseif n == 3 then
    if c.mode then
      params:delta(c.mode, d)
    elseif c.alt then
      -- the sub-value is a parameter in its own right, so it gets the same
      -- rounding rather than norns' raw hundredth-of-the-travel
      bump(c.alt, d, false)
    else
      bump(c.id, d, true)
    end
  end
end

-- a grid key released after a page change would otherwise leave the encoders
-- hijacked by a voice that is no longer on screen
function leave_page()
  held_voice = nil
  scene_held_at, scene_held_row = nil, nil
end

-- ---------------------------------------------------------------------------
-- The page wipe
--
-- One offset, applied with a single screen.translate at the top of redraw and
-- undone at the bottom. The page that is arriving is drawn shifted off the
-- edge it came from and slides home; there is no attempt to draw the OLD page
-- too, because at 128 pixels wide a slide of 160 ms reads as motion whether or
-- not anything is following it out, and drawing two pages means running two
-- visualisers a frame.
--
-- The easing is the same smoothstep MACHINE uses, for the same reason: things
-- that arrive at constant speed look mechanical.
-- ---------------------------------------------------------------------------

local wipe = { p = 1, dx = 0, dy = 0, t = 0.16 }

function wipe_start(dx, dy)
  wipe.p, wipe.dx, wipe.dy = 0, dx, dy
end

function wipe_advance(dt)
  if wipe.p >= 1 then return end
  wipe.p = math.min(1, wipe.p + (dt / wipe.t))
end

function wipe_offset()
  if wipe.p >= 1 then return 0, 0 end
  local p = wipe.p
  local e = 1 - (p * p * (3 - (2 * p)))          -- 1 .. 0, eased
  return util.round(wipe.dx * 128 * e), util.round(wipe.dy * 64 * e)
end

-- ---------------------------------------------------------------------------
-- keys
--
-- K2 and K3 walk the current lane. Held together they change lane, and the
-- press that completes the pair has to CANCEL the page move the first press
-- would otherwise have made - which is why the work happens on release and a
-- combo flag survives until both are up.
-- ---------------------------------------------------------------------------

local k_down = { false, false, false, combo = false }

function goto_lane_index(i)
  leave_page()
  LANE.at[LANE.n] = util.clamp(i, 1, #LANE[LANE.n])
  page = lane_page()
end

function key(n, z)
  if n >= 4 then
    -- pushable encoders arrive as extra keys on the hardware that has them
    if z == 1 then enc_push(n - 3) end
    return
  end
  k_down[n] = (z == 1)

  if z == 1 and n == 3 and PAGES[page].kind == "ritratt" and not k_down[2] then
    snap_hold_start(snap_state().sel, "save")
  end

  if z == 1 and k_down[2] and k_down[3] then
    -- Both down. The lane change now waits for the RELEASE, because a long
    -- hold of the pair is SNAPSHOTS's clear and the two have to be told apart -
    -- and a page-level gesture that fires the instant the second key touches
    -- down is impossible to back out of anyway.
    k_down.combo = true
    k_down.at = util.time()
    if PAGES[page].kind == "ritratt" then
      -- the pair is the clear gesture, so whatever K3 started on its own is
      -- replaced by a drain
      snap_hold_start(snap_state().sel, "clear")
    end
    return
  end

  if z == 0 and k_down.combo and not (k_down[2] or k_down[3]) then
    k_down.combo = false
    k2_held_at, k3_held_at = nil, nil
    if PAGES[page].kind == "ritratt" then
      -- the hold either completed on its own or it did not; either way the
      -- lane must not change under a gesture aimed at a slot
      if snap_hold_end() then return end
      return
    end
    leave_page()
    local dy = (LANE.n == 1) and 1 or -1        -- audio is above, so we drop
    LANE.n = (LANE.n == 1) and 2 or 1
    page = lane_page()
    wipe_start(0, dy)
    return
  end

  if n == 2 then
    if z == 1 then
      k2_held_at = util.time()
    else
      if k_down.combo then k2_held_at = nil; return end
      local held = k2_held_at and (util.time() - k2_held_at) or 0
      k2_held_at = nil
      if held > 0.4 then
        if PAGES[page].kind == "ritratt" then
          snap_recall(snap_state().sel)
          snap_pulse(snap_state().sel)
        else
          -- Put the selected parameter back where it started, and take any
          -- modulator off it. Without the second half it looks like nothing
          -- happened: the LFO moves it off the default again on the next tick.
          local c = cell_at(PAGES[page], sel[page])
          if c then param_reset(c.id) end
        end
        return
      end
      local was = LANE.at[LANE.n]
      goto_lane_index(LANE.at[LANE.n] - 1)
      -- No wipe if nothing moved. Sliding the same page back into place at
      -- the end of a lane reads as a stutter, not as an edge.
      if LANE.at[LANE.n] ~= was then wipe_start(-1, 0) end
    end
  elseif n == 3 then
    if z == 1 then
      k3_held_at = util.time()
    else
      if k_down.combo then k3_held_at = nil; return end
      local held = k3_held_at and (util.time() - k3_held_at) or 0
      k3_held_at = nil
      if PAGES[page].kind == "ritratt" then
        -- the save hold started on key DOWN and committed itself if it got
        -- far enough; a short press falls through to the page move
        if snap_hold_end() then return end
        local was = LANE.at[LANE.n]
        goto_lane_index(LANE.at[LANE.n] + 1)
        if LANE.at[LANE.n] ~= was then wipe_start(1, 0) end
        return
      end
      if held > 0.4 then
        do
          local id = PAGES[page].toggle
          if id then params:set(id, params:get(id) == 1 and 2 or 1) end
        end
      else
        local was = LANE.at[LANE.n]
        goto_lane_index(LANE.at[LANE.n] + 1)
        if LANE.at[LANE.n] ~= was then wipe_start(1, 0) end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Pushable encoders
--
-- Stock norns encoders do not push. The hardware that does report the pushes
-- as extra keys (K4..K6) or as MIDI, so both routes land here and the
-- behaviour is written once.
--
--   push E1   the parameter you are pointing at goes back to its default
--   push E2   snap it to the nearest round value
--   push E3   the same, for the sub-value
-- ---------------------------------------------------------------------------

-- the step a value should snap to, chosen from its own range so a 0..1 knob
-- snaps to tenths and a 20..11500 Hz one snaps to hundreds
function snap_step(p)
  local lo, hi = 0, 1
  if p.controlspec then lo, hi = p.controlspec.minval, p.controlspec.maxval
  elseif p.min then lo, hi = p.min, p.max end
  local span = math.abs(hi - lo)
  if span <= 0 then return 1 end
  local mag = 10 ^ math.floor(math.log(span / 10, 10))
  return math.max(mag, 1e-6)
end

-- Put a parameter back to its default AND take any modulator off it. The
-- second half matters: defaulting a destination that an LFO is still driving
-- looks like nothing happened, because the modulator moves it straight back
-- off the default on the next tick.
function param_reset(id)
  if not id then return end
  local p = params:lookup_param(id)
  if not p then return end
  local d = p.controlspec and p.controlspec.default or p.default
  if d == nil and p.options then d = 1 end
  if d ~= nil then params:set(id, d) end
  -- every modulation slot that points here goes to OFF
  local want
  for i, dest in ipairs(MOD_DESTS) do if dest.id == id then want = i end end
  if not want then return end
  for i = 1, NLFO do
    for _, k in ipairs({ "d1", "d2" }) do
      if params:get(LFO_ID[i][k]) == want then params:set(LFO_ID[i][k], 1) end
    end
  end
  for s2 = 1, 2 do
    if params:get("env_d" .. s2) == want then params:set("env_d" .. s2, 1) end
  end
end

function enc_push(n)
  local pg = PAGES[page]
  if pg.kind == "ritratt" then
    -- The page has no cells, so the three pushes are free. LOAD is on a push
    -- rather than on short K3 because K3 has to stay page-forward: a page you
    -- cannot leave with the key that leaves every other page is a trap.
    local st = snap_state()
    if n == 1 then snap_clear(st.sel)
    elseif n == 2 then snap_recall(st.sel)
    else snap_store(st.sel) end
    return
  end
  local c = pg.cells and cell_at(pg, sel[page])
  if not c then return end
  local id = c.id
  if n ~= 1 then
    -- E3 works on whichever sub-parameter the cell carries, as it does when
    -- turned; E2 always works on the cell's own value
    if n == 3 then id = c.mode or c.alt or c.id end
  end
  local p = params:lookup_param(id)
  if not p then return end
  if n == 1 then
    param_reset(id)
    return
  end
  if p.options then return end                 -- an option is already round
  local step = snap_step(p)
  params:set(id, util.round(params:get(id) / step) * step)
end

-- ---------------------------------------------------------------------------
-- screen
-- ---------------------------------------------------------------------------

local CELL_W = 32
-- The visualiser band. GLOBAL rather than local so that a mockup can resize
-- it and call the real drawing routines at a size the instrument does not
-- currently use - which is how a layout gets looked at before it is built.
WAVE_TOP, WAVE_H = 8, 28

-- The granulator badge: a boxed numeral down the left edge of the waveform and
-- euclid views.
--
-- With two identical-looking granulator pages the single most important thing
-- on screen is WHICH ONE YOU ARE ON, and the header cannot carry it - it is
-- already spending its width on the cell name, the mode and the value, and the
-- one thing that gets truncated is the end of the page name. So the numeral
-- gets its own reserved space that nothing else can encroach on, and both
-- visualisers start after it rather than drawing underneath.
--
-- Eleven pixels wide: enough for a digit at double size plus a one-pixel
-- border and a column of air, and narrow enough that the waveform still has
-- 116 of its 128 slots.
local SWB_W = 11


function draw_swarm_badge(w, top, h)
  local x0 = 0
  screen.aa(0)
  -- IDENTICAL for both. The parent used to get a filled plate and swarm 2 an
  -- outline, on the theory that one should read as heavier - and it read as a
  -- STATUS instead: filled meant on, empty meant this one is not receiving
  -- anything. A decorative difference on the one element whose whole job is
  -- to say WHICH, gets taken as saying WHETHER. Same plate, different numeral.
  screen.level(3)
  screen.rect(x0 + 0.5, top + 0.5, SWB_W - 1, h - 1)
  screen.fill()
  screen.level(6)
  screen.rect(x0 + 0.5, top + 0.5, SWB_W - 1, h - 1)
  screen.stroke()

  -- A small G above the numeral. The pages are numbered 1..4 and the
  -- granulators 1..2, so a bare "2" sitting under a header reading
  -- GRAINSWARM 3 is a puzzle. The G says which axis the number is on.
  screen.level(5)
  screen.move(x0 + 3, top + 7)
  screen.text("G")

  -- The numeral, drawn as a filled seven-segment digit rather than as text.
  -- screen.text has no size control on norns, and "1" and "2" at the default
  -- size are five pixels tall in an eleven-pixel box - which reads as a label
  -- rather than as the thing the box exists to say.
  local cx = x0 + (SWB_W / 2)
  local cy = top + ((h + 6) / 2)
  local dw, dh = 5, 13                     -- digit box
  local lx, rx = cx - (dw / 2), cx + (dw / 2)
  local ty, my, by = cy - (dh / 2), cy, cy + (dh / 2)
  screen.level(15)
  if w == 1 then
    -- a 1 with a serif foot, so it cannot be mistaken for a bare stroke
    screen.rect(cx - 0.5, ty, 2, dh)
    screen.fill()
    screen.rect(lx, ty + 2, 2, 2)          -- the flag
    screen.fill()
    screen.rect(lx, by - 2, dw + 1, 2)     -- the foot
    screen.fill()
  else
    screen.rect(lx, ty, dw + 1, 2)         -- top bar
    screen.fill()
    screen.rect(rx - 1, ty, 2, (dh / 2) + 1)
    screen.fill()
    screen.rect(lx, my - 1, dw + 1, 2)     -- middle bar
    screen.fill()
    screen.rect(lx, my, 2, (dh / 2))
    screen.fill()
    screen.rect(lx, by - 2, dw + 1, 2)     -- bottom bar
    screen.fill()
  end
end

function cell_geom(pg)
  return 13, { 37, 51 }
end

-- Where a cell sits on a GRAINSWARM page, and how wide.
--
-- Nine cells now, not eight: four across the top and FIVE across the bottom,
-- because SRC belongs at the head of the second row and there is nowhere else
-- for it to go. Five equal columns would be 25.6 px each, and at that width
-- every five-letter label on the page loses its last letter - the cells stop
-- being readable to buy space for one that does not need it.
--
-- So SRC is narrow and the other four share what is left. Its values are OFF,
-- STE, L, R and GS1, none of which need room, and the header spells the
-- selected one out in full anyway.
-- The grain pages are back to four even columns: SRC left the cell grid and
-- became the VISUALISER ITSELF, which is selectable as if it were cell zero.
function grain_cell_x(pg, i)
  local row = (i <= 4) and 0 or 1
  local slot = (i - 1) % 4
  return slot * 32, 32
end

-- Where a cell sits on an LFO page, and how wide.
--
-- Three cells fill the row when MACHINE is away and four share it when it is
-- out, with everything driven off one number - so RATE, PHASE and DEST
-- narrow by exactly as much as MACHINE grows, and the whole row moves as one
-- piece. Returns nil while it is fully retracted, which is what keeps it off
-- the screen entirely rather than at zero width.
function magna_cell_x(pg, i)
  local row = math.floor((i - 1) / 4) + 1
  local slot = ((i - 1) % 4) + 1
  local rv = mach_reveal((pg.lfos or { 1, 2 })[row])
  -- Four cells always. The middle one grows from 32 to 41 as MACHINE takes it
  -- over, because "MACHINE" does not fit in 32 and a cell that has to
  -- abbreviate its own label is a cell that is too narrow.
  --
  -- The nine pixels come from RATE alone, not shared across the row. Taking
  -- three from each meant DEST A and DEST B both shaved to "DEST", which is
  -- worse than any amount of squeeze - two cells you cannot tell apart. RATE
  -- can afford it: four letters, and its value is in the header anyway.
  local mid = 32 + (rv * 9)
  local first = 32 - (rv * 9)
  if slot == 1 then return 0, first end
  if slot == 2 then return first, mid end
  if slot == 3 then return first + mid, 32 end
  return first + mid + 32, 32
end

function draw_cells(pg)
  local ch, rows = cell_geom(pg)
  local active = sel[page]
  -- A page can ask for fewer, wider columns. Four 32-pixel cells is as much as
  -- fits with five-character labels; three 42-pixel ones hold a whole word,
  -- which is what MODNI needs now that there are eight LFOs and the number has
  -- moved out of the label and into the page name.
  local ncol = pg.cols or 4
  local dyn = (pg.kind == "magna")
  local grainrow = (pg.kind == "grain")
  for i = 1, #pg.cells do
    local cell = cell_at(pg, i)
    local x, CELL_W, row
    if dyn then
      row = math.floor((i - 1) / 4) + 1
      x, CELL_W = magna_cell_x(pg, i)
    elseif grainrow then
      row = (i <= 4) and 1 or 2
      x, CELL_W = grain_cell_x(pg, i)
    else
      row = math.floor((i - 1) / ncol) + 1
      CELL_W = 128 / ncol
      x = ((i - 1) % ncol) * CELL_W
    end
    if x and rows[row] then
      local y = rows[row]
      local on = (i == active)

      -- widths are clamped because a cell can be MID-SLIDE and only a pixel
      -- or two across; cairo will not take a negative rectangle
      local dim0 = (cell.id == "clock_tempo") and clock_external()
      -- THE SELECTION IS A BLOCK, not a frame. A one-pixel outline round a
      -- 32x13 cell is four thin lines competing with everything else drawn in
      -- thin lines; a filled label with the word knocked out of it is the one
      -- thing on the screen that cannot be mistaken for anything else.
      if on and not dim0 then
        screen.level(15)
        screen.rect(x + 1, y, math.max(CELL_W - 2, 1), 8)
        screen.fill()
      end

      -- a parameter that cannot be moved is drawn as one: the label, the
      -- bar and the frame all drop, so it reads as unavailable rather than
      -- as merely unselected
      local dim = (cell.id == "clock_tempo") and clock_external()
      local ink = dim and 2 or (on and 0 or 4)
      screen.level(ink)
      screen.move(x + 3, y + 6)
      -- Shave the label to the cell rather than let it run into its
      -- neighbour. It is also the nicest part of MACHINE's entrance: as the
      -- cell slides out from the edge the word arrives a letter at a time.
      --
      -- THE CHAIN LINK, drawn BEFORE the label rather than after it. Two
      -- things on the GRAINSWARM 2 pages are not swarm 2's own: RATE is a
      -- ratio of swarm 1's, and SCALE is one setting shared by both. Neither
      -- is discoverable from the value - "x2" and "DORIAN" look exactly like
      -- independent settings - so they are marked.
      --
      -- It is a PREFIX because a mark placed after the label lands in the
      -- top-right corner, which the modulation caret already owns, and reads
      -- as a stray character on the end of the word. In front it reads as
      -- what it is: this parameter belongs to something else.
      local lab = cell.label
      -- BPM says EXT on its own line while something else owns the tempo.
      -- "BPM EXT" is a couple of pixels wider than a 32-pixel cell, which is
      -- why the truncation below may run into an EMPTY neighbouring slot: a
      -- label can use space no other cell wants. BPM is the last cell on
      -- SIGNAL and the two slots beside it are empty.
      if cell.id == "clock_tempo" and clock_external() then
        lab = lab .. " EXT"
      end
      -- ONLY the cell that is genuinely someone else's. SCALE is shared too,
      -- but it is a MODE on the PITCH and V.SPRD cells, and marking those said
      -- that PITCH was linked - which it is not, it is swarm 2's own - while
      -- costing a letter off both labels to say it.
      local linked = cell.link
        or (cell.linkwhen and params:get(cell.linkwhen) > #DIVS)
      local lx = x + 3
      -- Four pixels and one of air. Six cost RATE its E - the one cell the
      -- mark exists for was the one it made unreadable.
      if linked then
        local ly = y + 2
        screen.level(dim and 2 or (on and 0 or 5))
        screen.rect(lx, ly, 2, 3); screen.rect(lx + 2, ly, 2, 3)
        screen.fill()
        screen.level(dim and 2 or (on and 15 or 7))
        screen.rect(lx + 2, ly + 1, 1, 1); screen.fill()
        lx = lx + 5
        screen.level(ink)
        screen.move(lx, y + 6)
      end
      -- How much room the label really has: its own cell, plus any EMPTY
      -- slots immediately to its right on the same row. A label may use space
      -- no other cell wants, which is what lets "BPM EXT" fit in a
      -- thirty-two pixel cell that is the last one on its page.
      local avail = CELL_W - 3.5 - (lx - x - 3)
      do
        local slot, j = ((i - 1) % ncol) + 1, i
        while slot < ncol and pg.cells[j + 1] == nil do
          avail = avail + CELL_W
          slot, j = slot + 1, j + 1
        end
      end
      while #lab > 0 and screen.text_extents(lab) > avail do
        lab = lab:sub(1, #lab - 1)
      end
      if #lab > 0 then screen.text(lab) end

      local bx, by, bw, bh = x + 3, y + ch - 4, math.max(CELL_W - 8, 1), 4

      -- THE GAUGE. Lit-or-not blocks rather than a continuous fill: it reads
      -- as a stepped readout instead of a level meter, and a segment that is
      -- either on or off survives this screen in a way that the last two
      -- pixels of a smooth fill do not.
      --
      -- EVERY SEGMENT IS THE SAME WIDTH, and that takes arithmetic rather
      -- than good intentions. The first version divided the cell by eight and
      -- got a pitch of 3.125 px, so the fifth segment straddled a pixel
      -- boundary the others did not and came out a pixel fatter - cairo was
      -- rendering exactly what it was asked for. Everything below is whole
      -- pixels, starting from a floored origin, because MODNI's three columns
      -- are 42.67 px wide and its cells do not begin on a pixel either.
      local gx = math.floor(bx)
      local gw = math.floor(bw)
      local NSEG = util.clamp(math.floor((gw + 1) / 3), 2, 8)
      -- a bipolar gauge needs an EVEN count, so that its centre falls in the
      -- gap between two segments rather than through the middle of one
      if cell.bipolar and (NSEG % 2) == 1 then NSEG = NSEG - 1 end
      local pitch = math.floor((gw + 1) / NSEG)
      local segw = pitch - 1
      -- below about two pixels of pitch there is no room for a gap, and a
      -- ladder with no gaps is a bar. Mid-slide cells get one.
      local solid = (pitch < 2)
      local function gauge(f, gy, gh, lv)
        if solid then
          screen.level(dim and 1 or 2)
          screen.rect(gx, gy, gw, gh)
          screen.fill()
          if f > 0.001 then
            screen.level(lv)
            screen.rect(gx, gy, math.max(f * gw, 1), gh)
            screen.fill()
          end
          return
        end
        -- ceil, not round: any amount at all lights the first block, so a
        -- parameter that is ON never looks like one that is OFF
        local lit = math.min(math.ceil(f * NSEG - 0.0001), NSEG)
        -- ONE PATH PER LEVEL, not one per segment. cairo accumulates
        -- rectangles into the current path and fills the lot on one call, so
        -- a run of blocks at the same brightness is a single fill - the
        -- ladder gets drawn in four calls instead of twenty-four.
        --
        -- Every page draws eight of these every frame, and every one of those
        -- calls crosses from Lua into cairo on the same thread that reads the
        -- encoders. That thread being busy is what a factory norns feels as
        -- an encoder that does nothing and then jumps.
        if lit > 0 then
          screen.level(lv)
          for k = 1, lit do
            screen.rect(gx + ((k - 1) * pitch), gy, segw, gh)
          end
          screen.fill()
        end
        if lit < NSEG then
          screen.level(dim and 1 or 2)
          for k = lit + 1, NSEG do
            screen.rect(gx + ((k - 1) * pitch), gy, segw, gh)
          end
          screen.fill()
        end
      end

      -- A DUAL cell is TWO BARS in one slot: the upper is GRAINSWARM 1 on E2,
      -- the lower is GRAINSWARM 2 on E3.
      --
      -- They are drawn as two separate tracks with a hard gap between them,
      -- not as one bar split down the middle. Stacking two half-height fills
      -- inside the ordinary four-pixel bar box was the first attempt and it
      -- was useless: two 1.5 px fills touching each other are a 3 px bar, and
      -- with both feeds at the same value - which is the default - it looked
      -- exactly like every other cell on the page. The gap is the whole point.
      if cell.dual then
        -- two ladders, GRAINSWARM 1 above GRAINSWARM 2, with a pixel of black
        -- between them. Same rule as before: two 1.5 px fills touching each
        -- other are one 3 px bar, and the gap is the whole point.
        gauge(frac(cell.id), y + ch - 5, 2, dim and 3 or (on and 15 or 9))
        gauge(frac(cell.alt), y + ch - 2, 2, dim and 3 or (on and 11 or 6))
        if mod_assigned[cell.id] or mod_assigned[cell.alt] then
          screen.level(on and 0 or 6)
          screen.rect(x + CELL_W - 6, y + 1, 3, 1)
          screen.fill()
        end
        goto dual_done
      end

      -- BPM HAS NO BAR, and no box either. A tempo drawn as a fraction of a
      -- 20..300 range tells you nothing - the number is the whole point - so
      -- the bar row holds the figure itself. EXT rides on the LABEL line,
      -- where it is not covering anything up.
      if cell.id == "clock_tempo" then
        screen.level(dim and 4 or (on and 15 or 9))
        screen.move(bx, by + 4)
        screen.text(string.format("%.1f", clock_external()
          and clock.get_tempo() or params:get("clock_tempo")))
        goto dual_done
      end

      local v = frac(cell.id)
      local lv = dim and 3 or (on and 15 or 9)
      if cell.bipolar and not solid then
        -- Lit outwards from the centre, and the centre itself is a FULL RULE
        -- standing in the gap between the two middle segments, overshooting
        -- the gauge top and bottom. A one-pixel detent pip was there before
        -- and it was not enough: at rest a bipolar parameter lights nothing
        -- at all, so without a mark of its own CENTRED and OFF are the same
        -- picture. The rule is the zero on the scale.
        local half = NSEG / 2
        local n = (v - 0.5) * 2 * half
        local lo, hi
        if n >= 0 then lo, hi = half + 1, half + math.ceil(n - 0.0001)
        else lo, hi = half + 1 + math.floor(n + 0.0001), half end
        -- lit run and unlit remainder as two paths, same as gauge above
        if hi >= lo then
          screen.level(lv)
          for k = lo, hi do
            screen.rect(gx + ((k - 1) * pitch), by, segw, bh)
          end
          screen.fill()
        end
        screen.level(dim and 1 or 2)
        for k = 1, NSEG do
          if k < lo or k > hi then
            screen.rect(gx + ((k - 1) * pitch), by, segw, bh)
          end
        end
        screen.fill()
        screen.level(dim and 3 or (on and 15 or 12))
        screen.rect(gx + (half * pitch) - 1, by - 1, 1, bh + 2)
        screen.fill()
      else
        gauge(v, by, bh, lv)
      end

      -- MODNI, shown where it lands rather than only where it was assigned.
      -- The bar stays the KNOB; a caret over the label marks a cell as a
      -- destination at all, and a bright tick rides the bar at the value the
      -- engine is actually being sent. Two marks because a modulator sitting
      -- at zero would otherwise be indistinguishable from no routing.
      if mod_assigned[cell.id] then
        -- knocked out of the selected cell's block, drawn on top of an
        -- unselected one: either way it is the same mark in the same place
        screen.level(on and 0 or 6)
        screen.rect(x + CELL_W - 6, y + 1, 3, 1)
        screen.fill()
      end
      local md = mod_delta[cell.id]
      if md and md ~= 0 then
        local mv = util.clamp(v + md, 0, 1)
        screen.level(15)
        screen.rect(gx + math.floor(mv * (gw - 1)), by - 1, 1, bh + 2)
        screen.fill()
      end
      ::dual_done::
    end
  end
end

-- map a grain's pitch to a y position inside the waveform band
function pitch_y(semi)
  local V = VS[vis_swarm()]
  local span = math.max(V.pitch_hi - V.pitch_lo, 1)
  local t = util.clamp((semi - V.pitch_lo) / span, 0, 1)
  return WAVE_TOP + WAVE_H - 2 - (t * (WAVE_H - 4))
end

-- ---------------------------------------------------------------------------
-- GRAINSWARM 2/2: the euclidean grid
--
-- Eight rows, one per grain, n columns for the pattern length. A voice's row
-- is its own rotation of the same figure, which is the only way to see what
-- PHASE is actually doing - the numbers alone ("ROT 2") do not tell you that
-- voices 1 and 5 have collided.
--
-- It replaces the waveform only while one of EUCLID / LEN / PHASE is the
-- selected cell. BUFFR and the two window ends live on this page too and are
-- unusable without the waveform, so the display follows what you are holding.
-- ---------------------------------------------------------------------------

-- the three cells that swap the waveform out for the grid
local EUCLID_CELLS = {
  m_euclid = true, m_elen = true, m_strum = true,
  n_euclid = true, n_elen = true, n_strum = true,
}

function draw_euclid()
  local w = vis_swarm()
  local V, G = VS[w], gr(w)
  local top, h = WAVE_TOP, WAVE_H
  local k, n = euclid_kn(w)
  local rowh = math.floor(h / NVOICE)
  local y0 = top + math.floor((h - (rowh * NVOICE)) / 2)
  -- the badge owns the left edge now, so the figure starts after it
  local x0, span = SWB_W + 3, 124 - SWB_W - 1
  draw_swarm_badge(w, top, h)

  screen.aa(0)

  if k == 0 then
    -- EUCLID off: PHASE is a time rake, so show it as one. Each voice gets a
    -- single block, placed where in the grain period it fires - and it flashes
    -- when it does, which is what makes the rake legible as a rake rather than
    -- as eight blocks in a diagonal.
    local f = pval(swid(w, "strum")) * 0.125
    screen.level(1)
    screen.move(x0, y0 - 1.5)
    screen.line(x0 + span, y0 - 1.5)
    screen.stroke()
    for i = 1, NVOICE do
      local g = G[i]
      local x = x0 + (f * (i - 1) * span)
      local fl = g.on and (V.flash[i] or 0) or 0
      local base = g.on and util.clamp(4 + math.floor(g.lvl * 5), 4, 9) or 2
      screen.level(util.clamp(math.floor(base + (fl * (15 - base)) + 0.5), 1, 15))
      -- it grows as well as brightens: on a five-pixel block, brightness
      -- alone is easy to miss at the edge of your eye
      local grow = util.round(fl * 2)
      screen.rect(x - grow, y0 + ((i - 1) * rowh), 5 + (grow * 2), rowh - 1)
      screen.fill()
    end
    return
  end

  -- The playhead: one column for all eight rows. euclid_hit already applies
  -- each voice's rotation when it indexes the pattern, so column s in row i
  -- IS what voice i does on step s - which means a single vertical line is
  -- correct for every row at once, and the interlock between differently
  -- rotated voices is the thing you can suddenly see.
  --
  -- Rows are three pixels tall, so brightness on its own is not enough to
  -- catch: a firing step goes to full white AND grows a pixel either side,
  -- and the whole row lifts with it. Three cues for one event, because at
  -- this size any one of them is easy to miss.
  local cw = span / n
  local cur = (V.flash.step or 0) % n
  local px = x0 + (cur * cw)

  -- a faint column under everything, so the playhead is still locatable on a
  -- row of rests
  screen.level(1)
  screen.rect(px, y0 - 1, math.max(cw - 1, 1), (rowh * NVOICE) + 1)
  screen.fill()

  for i = 1, NVOICE do
    local g = G[i]
    local y = y0 + ((i - 1) * rowh)
    local on = g.on
    local fl = on and (V.flash[i] or 0) or 0
    -- the row lifts as a whole while this voice is sounding
    local base = on and util.clamp(3 + math.floor(g.lvl * 3) + math.floor(fl * 4),
      3, 11) or 2
    for st = 0, n - 1 do
      local x = x0 + (st * cw)
      if euclid_hit(i, st, w) then
        if st == cur and fl > 0.02 then
          screen.level(util.clamp(math.floor(base + (fl * (15 - base)) + 0.5),
            1, 15))
          local grow = (fl > 0.45) and 1 or 0
          screen.rect(x, y - grow, math.max(cw - 1, 1),
            (rowh - 1) + (grow * 2))
        else
          screen.level(base)
          screen.rect(x, y, math.max(cw - 1, 1), rowh - 1)
        end
        screen.fill()
      else
        -- a rest is a single dim pixel, not an empty cell: an empty row and a
        -- row that is not being drawn at all look identical otherwise
        screen.level(1)
        screen.rect(x, y + math.floor((rowh - 1) / 2), 2, 1)
        screen.fill()
      end
    end
  end

  -- and the column is bracketed rather than drawn through: a line over the
  -- top of the cells would dim the very cell it is pointing at
  screen.level(13)
  screen.rect(px, y0 - 2, math.max(cw - 1, 1), 1)
  screen.rect(px, y0 + (rowh * NVOICE), math.max(cw - 1, 1), 1)
  screen.fill()
end

-- The visualiser band, marked as selected.
--
-- Two full-width rules, top and bottom, rather than corner brackets. The
-- corners collided with the granulator badge at the left edge, and a full
-- rectangle would put a horizon through the middle of the trace. Two lines
-- say "this band is the thing you are turning" and leave the picture alone.
function draw_vis_bracket(pg)
  if sel[page] ~= 0 or not grain_vis_page(pg) then return end
  screen.level(12)
  screen.rect(0, WAVE_TOP - 1, 128, 1)
  screen.rect(0, WAVE_TOP + WAVE_H, 128, 1)
  screen.fill()
end

function draw_waveform()
  local w = vis_swarm()
  local V = VS[w]
  local cy = WAVE_TOP + (WAVE_H / 2)
  local maxh = (WAVE_H / 2) - 1
  local sos = sos_amount(w)
  local locked = sos >= 0.999
  -- The K3 LOCK toggle specifically, not the blended figure above: SOS
  -- pinned at max also reads as fully frozen (sos_amount folds the two
  -- together so the brightness/write-head logic below does not need to
  -- care which one it is), but K3 only releases the toggle. Telling
  -- someone to "HOLD K3 TO UNLOCK" when a snapshot loaded with SOS itself
  -- maxed would be a lie - K3 flips lock_on straight back to false and the
  -- buffer is still frozen because SOS never moved.
  local lock_on = params:get(swid(w, "lock")) == 2
  local norm = math.max(V.wave_peak, 0.03)
  draw_swarm_badge(w, WAVE_TOP, WAVE_H)

  -- The captured buffer, one column per slot, normalised with a mild curve so
  -- quiet detail is still visible. Columns OUTSIDE the active window are drawn
  -- dim: grains can never read there, and separating the two by brightness
  -- says so far more directly than the bracket alone.
  local wlo = params:get(swid(w, "win_start"))
  local whi = params:get(swid(w, "win_end"))
  -- the badge covers the first SWB_W columns, so the trace starts after it
  local ilo = math.max(wlo * WAVE_N, SWB_W + 1)
  local ihi = whi * WAVE_N
  if lock_on then
    -- K3's own lock, not SOS pinned at max (that is `locked` below) - this
    -- is the one case where the buffer is frozen for a reason K3 actually
    -- releases, so it is the only case that gets to say so.
    -- norns' screen has no text_center - centering by hand with
    -- text_extents. A missing function here throws on every redraw while
    -- locked, which kills the redraw callback for good: the screen freezes
    -- on "LOCKED" and never comes back even after K3 unlocks it.
    local midx = SWB_W + 2 + ((WAVE_N - SWB_W - 2) / 2)
    local l1 = "LOCKED"
    screen.level(15)
    screen.move(midx - (screen.text_extents(l1) / 2), cy - 2)
    screen.text(l1)
    local l2 = "HOLD K3 TO UNLOCK"
    screen.level(4)
    screen.move(midx - (screen.text_extents(l2) / 2), cy + 7)
    screen.text(l2)
  else
    -- SOS pinned at max freezes the buffer too, independently of K3 - a
    -- performance move, not the toggle - so the trace still draws, just at
    -- the same raised brightness `locked` already drove below.
    local inlev, outlev = (locked and 9 or 6), (locked and 3 or 2)
    local lev = nil
    for i = SWB_W + 2, WAVE_N do
      local want = ((i - 1) >= ilo - 1 and (i - 1) <= ihi) and inlev or outlev
      if want ~= lev then
        if lev then screen.stroke() end
        screen.level(want)
        lev = want
      end
      local h = (math.min(V.wave[i] / norm, 1) ^ 0.7) * maxh
      if h < 0.5 then h = 0.5 end
      screen.move(i - 0.5, cy - h)
      screen.line(i - 0.5, cy + h)
    end
    screen.stroke()
  end

  -- active window: a bracket along the top edge. Grains only ever read from
  -- inside it, so it wants to be visible on both GRAINSWARM pages, not just the
  -- one whose knobs set it.
  if wlo > 0.002 or whi < 0.998 then
    local x0 = ilo + 0.5
    local x1 = ihi - 0.5
    screen.level(11)
    screen.move(x0, WAVE_TOP + 0.5)
    screen.line(x1, WAVE_TOP + 0.5)
    screen.stroke()
    screen.move(x0, WAVE_TOP + 0.5)
    screen.line(x0, WAVE_TOP + 3.5)
    screen.move(x1, WAVE_TOP + 0.5)
    screen.line(x1, WAVE_TOP + 3.5)
    screen.stroke()
  end

  -- write head, dim
  if not locked then
    screen.level(2)
    local x = math.floor(V.wpos * WAVE_N) + 0.5
    screen.move(x, WAVE_TOP)
    screen.line(x, WAVE_TOP + WAVE_H)
    screen.stroke()
  end

  -- grains as dots: x is where in the buffer, y is pitch, size is how loud.
  -- SWARM's duplicates ride along as smaller satellites at their interval, so
  -- the fifths and octaves are visible as well as audible.
  local swarm = params:get(swid(w, "swarm"))
  local iva = SWARM_IV[params:get(swid(w, "swarm_mode"))][1]
  local ivb = SWARM_IV[params:get(swid(w, "swarm_mode"))][2]
  for _, m in ipairs(V.marks) do
    local f = 1 - (m.age / m.life)
    local x = (m.pos * WAVE_N)
    -- BIGGER, and dark-edged. A grain used to top out at about four pixels
    -- across and sit at level 7-15 on a waveform drawn at level 6 - so at low
    -- amplitude it was a mid-grey dot on a mid-grey block, which is a dot you
    -- can only find if you already know where it is.
    --
    -- Two changes and the second matters more than the first. The radius is
    -- up by two thirds, and every grain is now drawn on a BLACK HALO: a
    -- filled circle a pixel wider at level 0, under the grain itself. Nothing
    -- on a one-bit screen separates a shape from its background like a gap
    -- does, and the halo works at every brightness, where raising the level
    -- only worked while the waveform behind happened to be dark.
    local r = (2.2 + (math.min(m.amp * 2.6, 1) * 4.2)) * (0.62 + (0.38 * f))
    local function dot(semi, rad, lv, core)
      local y = pitch_y(semi)
      if rad >= 0.4 then
        screen.level(0)
        screen.circle(x, y, rad + 1)
        screen.fill()
        screen.level(lv)
        screen.circle(x, y, rad)
        screen.fill()
        -- and a full-brightness core, scaled with the grain rather than a
        -- single pixel: on a six-pixel dot one pixel of white is a speck.
        if core and rad > 1.4 then
          screen.level(15)
          local cr = math.max(rad * 0.42, 1)
          screen.circle(x, y, cr)
          screen.fill()
        end
      end
    end
    if swarm > 0.02 then
      local sr = r * (0.34 + (swarm * 0.26))
      local sl = math.floor(4 + (f * 9 * swarm))
      dot(m.pitch + iva - (swarm * 0.4), sr, sl)
      dot(m.pitch + ivb + (swarm * 0.4), sr, sl)
    end
    dot(m.pitch, r, math.floor(9 + (f * 6)), true)
  end

  -- playhead, folded into the active window like the engine's is
  screen.level(locked and 15 or 12)
  local x = math.floor(win_map(V.spos, w) * WAVE_N) + 0.5
  screen.move(x, WAVE_TOP - 1)
  screen.line(x, WAVE_TOP + WAVE_H + 1)
  screen.stroke()

  -- NO INPUT first, ahead of LOCK and SOS. SRC defaults to OFF, so the very
  -- first thing a new user sees is a granulator that is capturing nothing -
  -- and silence with nothing on screen to explain it is the most expensive
  -- failure this instrument has. It is said in words, at full brightness.
  -- THE SOURCE, said out loud in the band - unless the band is the current
  -- selection, in which case the header is already saying it and two copies
  -- of the same three words stacked on top of each other is worse than one.
  if sel[page] ~= 0 then
    local si = params:get(swid(w, "src"))
    screen.level((si == 1) and 15 or 6)
    screen.move(126, WAVE_TOP + 7)
    screen.text_right(src_label(si))
  end

  -- LOCK and SOS used to print here too, in exactly the same pixels as the
  -- source above - two pieces of text on top of each other, and the one that
  -- lost was the one telling you whether anything is being recorded at all.
  --
  -- Neither is missed. LOCK is the page's TOGGLE and already shows in the
  -- header at the top left, and SOS is a cell on this page with its own value
  -- in the header when you select it. The band says the one thing nothing
  -- else says.
end

-- ---------------------------------------------------------------------------
-- COLOUR visualiser
--
-- One family of concentric rings, monochrome and antialiased. Each stage of
-- the device deforms the ring in its own way, so the picture is a readout of
-- the processing rather than decoration:
--
--   DRIVE   the circle collapses into a polygon as the vertex count falls
--   CRUSH   radial spikes push the outline into a star
--   NOISE   fur along the outline, gated by the output envelope exactly like
--           the audio, so it only grows where there is signal
--   TILT    dither. Tilted low, a dim stipple fills the body: dark and heavy.
--           Tilted high, the inverse: a bright sparkle halo outside the rim.
--
-- Everything driving it is eased towards its target each frame and the hair
-- is a slow random walk rather than fresh noise, so it moves smoothly instead
-- of flickering.
-- ---------------------------------------------------------------------------

-- Every knob the Kuluri picture reacts to is read through pval, not
-- params:get, so a modulated DRIVE visibly deforms the circles.
local vis = { env = 0, drive = 0, crush = 0, noise = 0, loss = 0, rot = 0,
              comp = 0, ndec = 0, tone = 0, wow = 0, wob = 0 }

function ease(a, b, k) return a + ((b - a) * k) end

local ndec_spec = nil

vis_update = function(dt)
  local k = math.min(dt * 6, 1)
  ndec_spec = ndec_spec or params:lookup_param("noise_decay").controlspec
  vis.env   = ease(vis.env,   math.min(out_amp_disp * 2.2, 1), math.min(dt * 9, 1))
  vis.drive = ease(vis.drive, pval("drive"), k)
  vis.crush = ease(vis.crush, pval("crush"), k)
  vis.noise = ease(vis.noise, pval("noise"), k)
  vis.loss  = ease(vis.loss,  pval("loss"), k)
  vis.comp  = ease(vis.comp,  pval("mx_comp"), k)
  vis.ndec  = ease(vis.ndec,  ndec_spec:unmap(pval("noise_decay")), k)
  vis.tone  = ease(vis.tone or 0,
    params:lookup_param("noise_tone").controlspec:unmap(pval("noise_tone")), k)
  vis.wow   = ease(vis.wow or 0, pval("k_wow"), k)
  -- Two independent angles. ROT is the wave field's travel, which speeds up
  -- with the output level so a loud passage visibly runs faster. WOBBLE is a
  -- slow shear laid over it, and it is WOW's - the one control on the page
  -- whose whole character is unsteadiness.
  vis.rot   = (vis.rot + (dt * (0.10 + (vis.env * 0.35)))) % (math.pi * 2)
  vis.wob   = ((vis.wob or 0) + (dt * (0.13 + (vis.wow * 0.9)))) % (math.pi * 2)
end

function tri(x)                 -- -1..1 triangle, period 1
  x = x % 1
  return (4 * math.abs(x - 0.5)) - 1
end

-- exact radius of a regular n-gon of circumradius 1, at angle a
function poly_r(a, n)
  local seg = (math.pi * 2) / n
  local t = (a % seg) - (seg * 0.5)
  return math.cos(math.pi / n) / math.cos(t)
end

-- morph smoothly between neighbouring polygons so DRIVE has no steps
function morph_r(a, n)
  if n >= 40 then return 1 end
  local n0 = math.floor(n)
  local f = n - n0
  local r0 = poly_r(a, n0)
  if f < 0.002 then return r0 end
  return r0 + ((poly_r(a, n0 + 1) - r0) * f)
end

-- ---------------------------------------------------------------------------
-- COLOUR visualiser: one circle per grain
--
-- The page shows the eight grain voices as circles rather than a single ring,
-- and behaves like a camera: with one voice live it fills the band and is
-- clipped by it, and as voices come in it pulls back until all eight fit. They
-- are not in a neat row - each is nudged off centre by a fixed amount that
-- grows as they shrink, so the field fills the space. The nudge only ever
-- increases the distance between neighbours, and the radius is set from the
-- horizontal spacing alone, so they can never overlap.
--
-- The circles are FILLED, not outlined. Everything below is a way of altering
-- a filled shape, because that is the only vocabulary a solid has:
--
--   DRIVE  morphs the outline towards a polygon, bottoming out at a DIAMOND.
--   CRUSH  spikes the outline (except in LOSS mode, which has its own look).
--   TILT   is the one that used to be meaningless. Tilted LOW it DARKENS the
--          fill; tilted HIGH it THINS it to a ring. So the knob reads as
--          "heavy and solid" at one end and "bright and hollow" at the other.
--   COMP   squeezes the whole field towards the middle - positions AND radii
--          by the same factor, so nothing overlaps - up to 20% at full
--          compression. Not more: it should read as crowding, not as a zoom.
--   NOISE  throws DUST around the circles. N.DEC is how far it sprays: a short
--          decay keeps it hugging the edge, a long one flings it across the
--          band.
--   LOSS   dithers the fill with a black scanline/checker mask laid over the
--          whole band. Drawing it across the band rather than per circle costs
--          one path instead of eight and looks identical, because everything
--          the mask crosses outside a circle is already black.
--
-- SWARM draws each voice's two duplicates as faint copies, pushed apart by
-- their interval and by the stereo spread the engine gives them.
--
-- The whole field sways with the master output and vibrates at the grain rate.
-- The vibration frequency is capped well under half the frame rate: past that
-- it aliases into a slow wobble that reads as a bug, so above the cap the rate
-- drives the AMPLITUDE instead.
-- ---------------------------------------------------------------------------


-- The path of one deformed circle, clipped to the band by CLAMPING y rather
-- than lifting the pen: a fill needs a closed path, so the clipped shape has
-- to keep a flat top and bottom instead of a gap.
-- ---------------------------------------------------------------------------
-- COLOUR: a wave field
--
-- Not objects on a lattice - ONE SURFACE, the whole width of the band. A stack
-- of thin lines, each of them the same travelling wave sampled a little
-- further along, so what the eye assembles is a sheet flexing in space rather
-- than a row of rings. It is the same trick a contour map plays: the lines are
-- nothing on their own, the SPACING between them is the shape.
--
-- Two wave trains cross it - one running right, one running left - and the
-- moire where they pass through each other is what gives the field its twist.
-- Brightness follows height, so the crests catch the light and the troughs
-- fall away, which is what makes a stack of lines read as a sculpted ribbon.
--
-- Nothing here counts voices. The field is always the full size of the band;
-- what the music does is BEND it. Every control owns one axis of the surface:
--
--   DRY IN   the two feeds weight the two wave trains, so a granulator routed
--            straight here visibly drives its own direction of travel
--   DRIVE    sharpens the crests - a smooth swell folds into a ridge
--   CRUSH    terraces the whole field into contour steps
--   LOSS     breaks the lines up into dashes
--   NOISE    fires a travelling perturbation that opens the field as it passes
--   N.DEC    how far and how wide that perturbation travels
--   N.TONE   the spatial frequency: long swells or a tight ripple
--   WOW      a slow phase wander that shears the sheet
--   COMP     squeezes the stack together vertically
--   BYPASS   the field relaxes flat
--
-- ...and the output envelope sets the amplitude of the whole thing, so the
-- surface breathes with what you are hearing.
-- ---------------------------------------------------------------------------

-- travelling perturbations, fired by NOISE when a grain lands
local kpulse = {}
local KPULSE_MAX = 5
local KLINES = 6

function kuluri_ripple(x0, dir, amt)
  if #kpulse >= KPULSE_MAX then return end
  kpulse[#kpulse + 1] = { x = x0, dir = dir, age = 0, amp = amt }
end

function kuluri_advance(dt)
  local life = 0.55 + (vis.ndec * 1.5)
  for i = #kpulse, 1, -1 do
    local p = kpulse[i]
    p.age = p.age + (dt / life)
    if p.age >= 1 then table.remove(kpulse, i) end
  end
end

-- last frame's trigger flashes, so a grain landing is a RISING EDGE rather
-- than "the flash is currently high", which would fire a pulse every frame
-- for as long as it took to fade.
kfl = {}

-- the field itself, held between frames so a redraw is not thirty tables
kY, kLV = {}, {}

function draw_kuluri()
  local top, h = WAVE_TOP, WAVE_H
  local bot = top + h
  local cy = top + (h / 2)
  local byp = (params:get("bypass") == 2)

  screen.aa(1)
  screen.stroke()          -- clear the current point left by screen.text

  -- a grain landing throws a perturbation across the field: GRAINSWARM 1's
  -- from the left, GRAINSWARM 2's from the right, so the two are still
  -- distinguishable without either of them being counted
  if vis.noise > 0.02 and not byp then
    for w = 1, 2 do
      local FL = VS[w].flash
      for i = 1, NVOICE do
        local f = FL[i] or 0
        local key = (w * 16) + i
        if f > 0.6 and (kfl[key] or 0) <= 0.6 then
          kuluri_ripple((w == 1) and -6 or 134, (w == 1) and 1 or -1,
            vis.noise)
        end
        kfl[key] = f
      end
    end
  end

  local STEPS = 30
  local dx = 128 / STEPS

  -- the swell. Never zero: a dead field is a page that looks broken rather
  -- than a page that is quiet.
  local amp = (h * 0.5) * (0.20 + (vis.env * 0.62))
  if byp then amp = amp * 0.1 end
  -- the stack closes up as the swell grows, so the sheet flexes INSIDE the
  -- band. Without this the outer lines run into the edge and clamp, and a
  -- clamped line is a dead flat horizontal that reads as a drawing bug.
  local spread = (h - 1) * (1 - ((amp / (h * 0.5)) * 0.52))
  -- N.TONE is the spatial frequency - how many crests fit across the screen
  local kx = (math.pi * 2) * (0.55 + (vis.tone * 1.5)) / 128
  local fw1, fw2 = pval("k_in1"), pval("k_in2")
  local wa = 0.42 + (fw1 * 0.5)
  local wb = 0.28 + (fw2 * 0.5)
  local wsum = wa + wb
  -- the two trains travel in opposite directions, at rates that do not divide
  -- into each other, so the interference pattern never settles into a loop
  local pa = vis.rot * 2.3
  local pb = vis.rot * -1.41
  local squash = 1 - (vis.comp * 0.28)
  -- CRUSH terraces the surface: y snaps to a contour step
  local terr = (vis.crush > 0.02) and (0.5 + (vis.crush * 4.5)) or 0
  -- DRIVE folds the sine towards a cusp
  local sharp = 1 - (vis.drive * 0.68)
  local pspan = 34 + (vis.ndec * 110)      -- how far a perturbation travels
  local pwide = 9 + (vis.ndec * 13)        -- and how wide it is
  local dash = math.floor(vis.rot * 2.4)   -- LOSS's dashes crawl

  -- HOW FAR THE WAVE LAGS FROM ONE LINE TO THE NEXT, and it cannot be a
  -- constant. The lag is what turns a stack of identical curves into a
  -- surface, but two neighbours whose lag times the swell exceeds the gap
  -- between them cross - and a crossing on this screen is a smudge, not a
  -- detail. So the lag is derived from the room there actually is: enough
  -- offset to sculpt, never enough to collide.
  local off = util.clamp(
    0.62 * (spread * squash) / (math.max(amp, 1) * (KLINES - 1)) * 4, 0.5, 2.6)

  -- SHAPE FIRST, DRAW SECOND. On a 128x64 screen two lines that pass within
  -- a pixel of each other are not two lines, they are a grey smudge - and a
  -- travelling wave sampled at nine heights spends half its time doing
  -- exactly that. So the whole field is computed, then a separation pass
  -- pushes any pair that has closed up back apart, and only then is it drawn.
  -- It is the same rule a contour map follows: contours never touch.
  for li = 1, KLINES do
    kY[li] = kY[li] or {}
    kLV[li] = kLV[li] or {}
    local t = (li - 1) / (KLINES - 1)
    local base = cy + ((t - 0.5) * spread * squash)
    -- the middle of the sheet swings further than its edges, which is what
    -- gives the bundle a waist instead of moving like a stack of rulers
    local lamp = amp * (0.76 + (0.32 * math.sin(t * math.pi)))
    -- the phase offset per line IS the surface: without it every line is the
    -- same curve and the stack reads as a striped ribbon rather than a sheet
    local sa = t * off
    local sb = t * -off * 0.6
    -- WOW wanders each line's phase against its neighbours, which shears the
    -- sheet rather than merely moving it
    local ww = math.sin(vis.wob + (t * 2.7)) * vis.wow * off * 0.7

    for s = 0, STEPS do
      local x = s * dx
      local u = (math.sin((x * kx) + pa + sa + ww) * wa)
        + (math.sin((x * kx * 0.63) + pb + sb - ww) * wb)
      u = u / wsum
      if sharp < 0.995 then
        u = ((u < 0) and -1 or 1) * (math.abs(u) ^ sharp)
      end

      -- the perturbations, as a gaussian bulge that pushes the stack open
      local g = 0
      for _, p in ipairs(kpulse) do
        local d = (x - (p.x + (p.dir * p.age * pspan))) / pwide
        if d > -2.6 and d < 2.6 then
          g = g + (math.exp(-(d * d)) * p.amp * (1 - p.age))
        end
      end

      -- the bulge opens the stack, and it has to open it INTO the room the
      -- swell is not already using - pushed by a flat number it drives the
      -- outer lines into the edge of the band, where they clamp into a
      -- horizontal bar
      kY[li][s] = base + (u * lamp * (1 - (g * 0.5)))
        + (g * (t - 0.5) * spread * 0.32)

      -- the light. Height first - crests bright, troughs dark - which is what
      -- turns a stack of lines into a surface. Quantised in THREES: every
      -- change of level is a fresh cairo path, and at finer steps a single
      -- line was costing thirty of them.
      local lv = 6 + (u * 6.4) + (vis.env * 4) + (g * 7)
        - (math.abs(t - 0.5) * 2.2)
      if byp then lv = 4 end
      kLV[li][s] = util.clamp(math.floor((lv / 3) + 0.5) * 3, 1, 15)
    end
  end

  -- the separation pass, column by column. CRUSH is the exception it has to
  -- make room for: terracing is lines LANDING on the same contour, so the gap
  -- relaxes as the terraces come in or the steps would be prised back open.
  -- 3 px, and that is a floor rather than a preference: at two pixels a pair
  -- of lines on this screen is a grey bar. Six lines at three pixels is
  -- fifteen, which leaves the rest of the band for the wave to move in.
  local gap = math.max(2.6, (spread * squash) / (KLINES - 1) * 0.4)
    * (1 - vis.crush)
  if gap > 0.2 then
    for s = 0, STEPS do
      for li = 2, KLINES do
        local mn = kY[li - 1][s] + gap
        if kY[li][s] < mn then kY[li][s] = mn end
      end
      -- pushing down can walk the bottom line off the band; carry the excess
      -- back up through the whole stack rather than letting it clamp flat
      local over = kY[KLINES][s] - bot
      if over > 0 then
        for li = KLINES, 1, -1 do
          kY[li][s] = kY[li][s] - over
          if li > 1 and (kY[li][s] - kY[li - 1][s]) >= gap then break end
        end
      end
    end
  end

  for li = 1, KLINES do
    local px, py, plv
    local open = false
    for s = 0, STEPS do
      local x = s * dx
      local y = util.clamp(kY[li][s], top, bot)
      if terr > 0 then y = util.clamp(math.floor(y / terr + 0.5) * terr, top, bot) end
      local lv = kLV[li][s]

      local keep = true
      if vis.loss > 0.02 then
        keep = (((s * 29) + (li * 53) + dash) % 100) >= (vis.loss * 70)
      end

      if s > 0 then
        if keep and lv > 1 then
          if open and lv == plv then
            screen.line(x, y)
          else
            if open then screen.stroke() end
            screen.level(lv)
            screen.move(px, py)
            screen.line(x, y)
            open, plv = true, lv
          end
        elseif open then
          screen.stroke()
          open = false
        end
      end
      px, py = x, y
    end
    if open then screen.stroke() end
  end

  screen.aa(0)

  if byp then
    screen.level(15)
    screen.move(126, top + 7)
    screen.text_right("BYP")
  end
end

function draw_stillel()
  local top, h = WAVE_TOP, WAVE_H
  local cy = top + (h / 2)
  local half = (h / 2) - 6
  local n = SSTEPS[params:get("s_steps")]
  local fb = params:get("s_feedback")
  local held = params:get("s_hold") == 2

  screen.aa(0)

  -- step ruler along the centre
  screen.level(1)
  for i = 1, n do
    local x = 2 + (((i) / n) * 123)
    screen.rect(x, cy, 1, 1)
  end
  screen.fill()

  -- playhead
  screen.aa(1)
  screen.level(held and 3 or 6)
  local px = 2 + (stil_phase * 123)
  screen.move(px, top + 1)
  screen.line(px, top + h - 1)
  screen.stroke()

  -- taps
  for i = 1, NTAP do
    local t = taps[i]
    if t.on then
      local x = 2 + ((t.time / math.max(stil_cycle, 0.001)) * 123)
      local y = cy + (t.pan * half)
      local f = tap_flash[i]
      local r = 1.1 + (t.lvl * 2.6) + (f * 1.2)

      -- feedback halo: rings that widen and dim, so more feedback smears
      if fb > 0.03 or held then
        -- a soft glow, not dominant rings: the taps must stay readable
        local rings = held and 2 or (1 + math.floor(fb * 1.5))
        local gap = 0.9 + (fb * 0.8)
        local base = (held and 4 or (1.5 + (fb * 3))) + (f * 2)
        for k = 1, rings do
          screen.level(util.clamp(math.floor(base - (k * 1.1)), 1, 8))
          screen.circle(x, y, r + (k * gap))
          screen.stroke()
        end
      end

      screen.level(math.floor(6 + (f * 9)))
      screen.circle(x, y, r)
      screen.fill()
    end
  end

  screen.aa(0)
  if held then
    screen.level(15)
    screen.move(126, top + 7)
    screen.text_right("HOLD")
  elseif using_euclid() then
    screen.level(5)
    screen.move(126, top + 7)
    screen.text_right("EUC")
  end
end

-- ---------------------------------------------------------------------------
-- FILTRU visualiser
--
-- Eight resonators laid out by frequency: x is the note each comb is tuned to
-- on a log scale, so SPREAD visibly fans them apart and TUNE slides the whole
-- set. Everything else is read off the stem:
--
--   RESO    stem height - how long it rings
--   WIDTH   the stem leans, left or right, by where that comb sits in the field
--   DRIFT   the stems sway, each at its own rate, exactly as the tuning does
--   POLE    negative feedback draws the stem broken, because it has lost its
--           even harmonics and sounds hollow
--   DAMP    a ceiling line; stems past it are dimmed, since that is where the
--           lowpass has taken the ring away
--   WET     overall brightness
--
-- A comb belonging to a silenced grid row is drawn faint: it is still there,
-- but nothing is exciting it.
-- ---------------------------------------------------------------------------

-- the RESONATOR visualiser draws the bank, so it reads the chord the bank is
-- actually tuned to - which INPUT decides
function voice_semi(i)
  local w = spettru_swarm()
  local st = gr(w)[i]
  return snap_to_scale(
    params:get(swid(w, "pitch")) + st.semi + (OCTAVES[st.oct] * 12),
    params:get("m_scale"))
end

-- mirrors the engine's per-voice comb tuning exactly
-- ---------------------------------------------------------------------------
-- RESONATOR visualiser: the analysis window and what is in it
--
-- Log frequency across the screen, one mark per band. The height of a mark is
-- that band's live level, polled from... nothing: the tracked levels live in
-- Lua already - this draws what the KNOBS do, exactly and honestly - where
-- each band sits, how BRIGHTNESS and POSITION have shaped its level, where
-- FREQUENCY has moved the lot - and animates the whole field at the
-- modulator rate so you can see how fast it is re-tuning.
--
-- The band positions are computed by spettru_band_hz, the same function the
-- engine's arithmetic mirrors, so the picture cannot drift from the sound.
-- ---------------------------------------------------------------------------

-- The frequency axis, auto-fitted to the bank.
--
-- It used to be a fixed 20 Hz .. 16 kHz, and one chord's partials occupy about
-- a fifth of that - which is why everything sat in a clump in the middle with
-- empty screen either side. This tracks the lowest and highest resonator that
-- is actually sounding and eases towards them, so the strings always fill the
-- width whatever the chord is doing.
local sp_lo, sp_hi = 100, 4000

function freq_x(f)
  local t = math.log(util.clamp(f, 20, 16000) / sp_lo) / math.log(sp_hi / sp_lo)
  return 2 + (util.clamp(t, 0, 1) * 123)
end

-- ---------------------------------------------------------------------------
-- RESONATOR visualiser: forty-eight strings
--
-- Each resonator is drawn as a string standing at its own frequency, and a
-- grain landing plucks the lot: every string takes a kick scaled by how much
-- gain it has, and then rings down at the DAMPING time - the same number the
-- engine is using, so a long ring really does keep moving for longer.
--
-- The ripple is the fundamental mode of a string fixed at both ends: one
-- antinode in the middle, none at the ends. sin(pi * u) is the shape along its
-- length and sin(2 pi f t) is the oscillation, which is all a struck string
-- does to first order. The visual frequency is NOT the audio frequency - at
-- 261 Hz a string would blur to a solid block at 25 fps - it is a slow
-- stand-in that rises with pitch, so high strings still shimmer faster.
-- ---------------------------------------------------------------------------

-- each string's phase is set once, from its index, and never touched again -
-- a phase that gets randomised on every grain landing is a phase that jumps,
-- and a jump reads as a glitch, not a wobble. What moves is only the
-- amplitude, which tracks the live level.
local sring = {}
for i = 1, NBAND do
  sring[i] = { a = 0, ph = (i * 2.399963) % (2 * math.pi) }
end

function spettru_strings(dt)
  -- how quickly the wobble's size follows the live level. Reuses DAMPING's
  -- curve so a long DAMPING still reads as a slower, more liquid picture,
  -- but as a settling time on an envelope follower now, not a decay after a
  -- kick - there is no kick left to decay from.
  local rt = 0.003 * (900 ^ util.clamp(pval("p_damp"), 0, 1))
  local ease = 1 - math.exp(-dt / math.max(rt * 1.6, 0.22))
  local drive = math.min(out_amp_disp * 2.4, 1)
  local lo, hi = 1e9, -1e9
  for i = 1, NBAND do
    local r = sring[i]
    local g0 = spettru_band_amp(i)
    local target = math.min(1, g0 * 3.5 * drive)
    r.a = r.a + ((target - r.a) * ease)
    if r.a < 0.0005 then r.a = 0 end
    local f = spettru_band_hz(i)
    if f > 20 and g0 > 0.0005 then
      if f < lo then lo = f end
      if f > hi then hi = f end
    end
  end
  if hi > lo then
    -- a third of an octave of air either side, and eased so a chord change
    -- glides the axis rather than snapping it
    local wlo, whi = lo / 1.26, hi * 1.26
    if whi / wlo < 4 then                     -- never zoom past two octaves
      local mid = math.sqrt(wlo * whi)
      wlo, whi = mid / 2, mid * 2
    end
    local e = math.min(dt * 2.5, 1)
    sp_lo = sp_lo + ((util.clamp(wlo, 20, 8000) - sp_lo) * e)
    sp_hi = sp_hi + ((util.clamp(whi, 60, 16000) - sp_hi) * e)
  end
end

function draw_spettru()
  local top, h = WAVE_TOP, WAVE_H
  local base = top + h - 1
  local wet = pval("p_wet")
  local frz = params:get("p_freeze") == 2
  local lit = 0.3 + (0.7 * wet)

  screen.aa(0)

  -- the two ends the strings are fixed between
  screen.level(1)
  screen.move(0, base + 0.5)
  screen.line(128, base + 0.5)
  screen.move(0, top + 0.5)
  screen.line(128, top + 0.5)
  screen.stroke()

  local L = base - top - 2                    -- string length in pixels
  local t = filt_t
  for i = 1, NBAND do
    local f = spettru_band_hz(i)
    local g = spettru_band_amp(i)
    if f > 20 and g > 0.0005 then
      local r = sring[i]
      local x = freq_x(f)
      -- the visual pitch: 0.8 Hz at the bottom of the axis, 3.5 at the top.
      -- Slow enough to read at twenty-five frames a second without the
      -- per-frame phase step turning into a flicker.
      local u = util.clamp((x - 2) / 123, 0, 1)
      local vf = 0.8 + (u * 2.7)
      -- how far it bows, in pixels - straight off the eased level, so the
      -- swing simply grows and shrinks with volume. Forty-eight strings
      -- across 123 pixels sit about two and a half apart, so 6.5 is a wide
      -- swing without the picture turning to soup.
      local amp = math.min(r.a, 1) * 6.5
      local lv = util.clamp(
        math.floor(((4 + (r.a * 11)) * lit) + 0.5), 1, 15)
      screen.level(lv)
      if amp < 0.4 then
        -- at rest it is just a string
        screen.move(x, top + 1)
        screen.line(x, base - 1)
      else
        -- one cycle top to bottom, its phase creeping with time so the
        -- ripple reads as travelling rather than the whole string just
        -- bowing to one side; still pinned at both ends
        local phase = (t * vf * 2 * math.pi) + r.ph
        local n = 7
        for k = 0, n do
          local uu = k / n
          local env = math.sin(uu * math.pi)
          local dx = x + (amp * env * math.sin((uu * math.pi * 2) - phase))
          if k == 0 then screen.move(dx, top + 1) else screen.line(dx, base - ((1 - uu) * L) - 1) end
        end
      end
      screen.stroke()
    end
  end

  if frz then
    screen.level(15)
    screen.move(126, top + 7)
    screen.text_right("FRZ")
  elseif params:get("p_model") == 2 then
    screen.level(5)
    screen.move(126, top + 7)
    screen.text_right("STR")
  end
end

-- ---------------------------------------------------------------------------
-- MODNI visualiser
--
-- Two lanes, one per LFO, each drawing the shape it is actually running over
-- one cycle with a dot riding at the current phase, so S&H HARD looks like
-- steps and SAW looks like a saw rather than everything looking like a
-- squiggle with a number next to it. The bar on the right is the live value.
-- The two small marks beside it are that LFO's two destinations, drawn at the
-- amount they are contributing right now - a routing sending nothing is
-- visibly sending nothing.
-- ---------------------------------------------------------------------------

function draw_lfo_lane(i, top, h)
  local l = lfos[i]
  local cy = top + (h / 2)
  local half = (h / 2) - 1
  local bypassed = params:get("mod_bypass") == 2
  local held = params:get("mod_hold") == 2
  local W = 96                                    -- lane width, bars sit right

  screen.level(1)
  screen.move(0, cy + 0.5)
  screen.line(W, cy + 0.5)
  screen.stroke()

  local shape = params:get(LFO_ID[i].shape)
  local px

  screen.level(bypassed and 2 or 7)
  if shape <= 2 then
    -- the last SH_N held values, oldest left, newest at the right edge
    local prev
    for k = 0, SH_N - 1 do
      local v = l.shist[((l.spos + k) % SH_N) + 1]
      local x0, x1 = (k / SH_N) * W, ((k + 1) / SH_N) * W
      local y = cy - (v * half)
      if shape == 1 then
        -- the path is already sitting at (x0, prev), so this line IS the step
        if prev then screen.line(x0, y) else screen.move(x0, y) end
        screen.line(x1, y)
      else
        -- S&H SOFT eases between holds, so draw it eased
        local py = prev or y
        for t = 0, 4 do
          local f = t / 4
          local yy = py + ((y - py) * (0.5 - (0.5 * math.cos(f * math.pi))))
          local xx = x0 + ((x1 - x0) * f)
          if t == 0 and k == 0 then screen.move(xx, yy) else screen.line(xx, yy) end
        end
      end
      prev = y
    end
    px = W
  else
    -- a function of phase: draw the curve itself, exact at any rate
    --
    -- EVERY OTHER PIXEL, except for SQUARE. A sine, a triangle and a ramp
    -- sampled every two pixels and joined with straight segments are
    -- indistinguishable at this size from the same curve sampled every one -
    -- the segments interpolate what was skipped - and it is half the calls.
    -- Two lanes at ninety-seven points each was the single biggest thing
    -- MODNI asked the screen for. SQUARE is the exception because its edge is
    -- vertical: sampled coarsely it comes back as a two-pixel diagonal, which
    -- reads as a drawing fault rather than as a gate.
    local off = params:get(LFO_ID[i].phase)
    local step = (shape == 6) and 1 or 2
    for x = 0, W, step do
      local y = cy - (lfo_at(i, (x / W) + off) * half)
      if x == 0 then screen.move(x, y) else screen.line(x, y) end
    end
    -- the last sample may have fallen short of the right edge
    if (W % step) ~= 0 then
      screen.line(W, cy - (lfo_at(i, 1 + off) * half))
    end
    px = ((l.phase + params:get(LFO_ID[i].phase)) % 1) * W
  end
  screen.stroke()

  -- where it is right now
  screen.level(held and 5 or 12)
  screen.move(px + 0.5, top)
  screen.line(px + 0.5, top + h)
  screen.stroke()
  screen.level(bypassed and 4 or 15)
  screen.circle(px, cy - (l.val * half), 1.6)
  screen.fill()

  -- live value
  local bx = W + 6
  screen.level(2)
  screen.move(bx + 0.5, top + 1)
  screen.line(bx + 0.5, top + h - 1)
  screen.stroke()
  screen.level(bypassed and 3 or 13)
  local vh = l.val * half
  screen.rect(bx - 1, cy - math.max(vh, 0), 3, math.max(math.abs(vh), 1))
  screen.fill()

  -- the two destinations, at their present contribution
  for s = 1, LFO_DEST do
    local dx = W + 14 + ((s - 1) * 7)
    local di = params:get((s == 1) and LFO_ID[i].d1 or LFO_ID[i].d2)
    local amt = params:get((s == 1) and LFO_ID[i].a1 or LFO_ID[i].a2)
    screen.level(1)
    screen.move(dx + 0.5, top + 1)
    screen.line(dx + 0.5, top + h - 1)
    screen.stroke()
    if di > 1 and amt ~= 0 and not bypassed then
      local dv = l.val * amt * half
      screen.level(11)
      screen.rect(dx - 1, cy - math.max(dv, 0), 3, math.max(math.abs(dv), 1))
      screen.fill()
    end
  end

  screen.level(4)
  screen.move(1, top + 6)
  screen.text(tostring(i))
end

function draw_magna()
  local pair = PAGES[page].lfos or { 1, 2 }
  screen.aa(0)
  -- top lane is the top row of cells, bottom lane the bottom row
  draw_lfo_lane(pair[1], WAVE_TOP, 13)
  draw_lfo_lane(pair[2], WAVE_TOP + 15, 13)
end

-- ---------------------------------------------------------------------------
-- MODNI 2/2 visualiser
--
-- A plain three-second time window of the follower, newest at the right. No
-- cycle to index by, so unlike the LFO lanes this really is a scrolling
-- history. The two bars on the right are what each destination is receiving,
-- and the dotted line is unity - anything above it is the follower saturating,
-- which is the thing you actually need to see when setting SENS.
-- ---------------------------------------------------------------------------

function draw_envmod()
  local top, h = WAVE_TOP, WAVE_H
  local base = top + h - 1
  local W = 96
  local bypassed = params:get("mod_bypass") == 2
  local held = params:get("mod_hold") == 2

  screen.aa(0)
  screen.level(1)
  screen.move(0, base + 0.5)
  screen.line(W, base + 0.5)
  screen.stroke()

  -- unity
  screen.level(2)
  for x = 0, W, 3 do screen.rect(x, top + 1, 1, 1) end
  screen.fill()

  screen.level(bypassed and 2 or 8)
  for k = 0, EHIST_N - 1 do
    local v = env.hist[((env.hpos + k) % EHIST_N) + 1]
    local x = (k / (EHIST_N - 1)) * W
    local y = base - (v * (h - 3))
    if k == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()

  screen.level(held and 5 or 12)
  screen.move(W + 0.5, top)
  screen.line(W + 0.5, base)
  screen.stroke()
  screen.level(bypassed and 4 or 15)
  screen.circle(W, base - (env.val * (h - 3)), 1.6)
  screen.fill()

  for s = 1, 2 do
    local dx = W + 10 + ((s - 1) * 9)
    local di = params:get("env_d" .. s)
    local amt = params:get("env_a" .. s)
    screen.level(1)
    screen.move(dx + 0.5, top + 1)
    screen.line(dx + 0.5, base)
    screen.stroke()
    if di > 1 and amt ~= 0 and not bypassed then
      local dv = env.val * math.abs(amt) * (h - 3)
      screen.level(11)
      if amt >= 0 then
        screen.rect(dx - 1, base - dv, 3, math.max(dv, 1))
      else
        -- a negative amount ducks, so it hangs from the top
        screen.rect(dx - 1, top + 1, 3, math.max(dv, 1))
      end
      screen.fill()
    end
  end
end

-- ---------------------------------------------------------------------------
-- SIGNAL visualiser
--
-- Five faders and an output meter. The meter is drawn against the limiter
-- ceiling, which is the number that matters: when the bar reaches the line
-- the limiter is working, and that is the answer to "why did turning this up
-- do nothing".
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- SIGNAL: the signal flow, drawn as it actually is
--
-- Six boxes and the lines between them. The two granulators on the left, the
-- three processors across the middle, the output on the right - and a line
-- from a granulator to a box only exists if that granulator is actually being
-- fed into it. Turn a feed to zero and the line goes; the picture is the
-- routing rather than a diagram of it.
--
-- Every box carries a live level, as a filled bar AND as a number in dB. The
-- bar is for glancing at while your hands are busy; the number is for the one
-- question a bar cannot answer, which is how far from clipping you are.
--
-- The levels come from six engine polls. A poll that has never delivered
-- draws a DASH rather than a zero: this is the one part of the instrument
-- whose plumbing could not be tested here (the CroneEngine stub used by the
-- test harness has addPoll as a no-op), and a meter that reads a confident
-- 0 dB when nothing is arriving is exactly the sort of quiet lie that costs a
-- day. If you see dashes, the polls are not reaching Lua.
-- ---------------------------------------------------------------------------

-- level per box, 0..1, and whether anything has ever arrived
meters = { 0, 0, 0, 0, 0, 0, 0 }
meter_seen = { false, false, false, false, false, false, false }

-- Seven boxes now REVERB sits between COLOUR and OUT. The granulators stack
-- on the left, the chain runs across the middle, and the two rows never
-- share a column - so a wire can always get from one to the other without
-- crossing a box. The five chain boxes moved from a spacing of 22 to 20 (and
-- their block shifted 14 px left) to make room for the new one; OUT lands
-- back on its old x by construction, which is why only it looks untouched.
--
-- REVERB has no FEED of its own - see HAL_FEED below - so it is a plain
-- spine box, the same as DELAY or COLOUR would be without their per-stage
-- DRY IN.
local HAL_BOX = {
  { n = "GR1", x = 0,  row = -1, m = 1 },
  { n = "GR2", x = 0,  row =  1, m = 2 },
  { n = "RES", x = 28, row =  0, m = 3 },
  { n = "DLY", x = 48, row =  0, m = 4 },
  { n = "COL", x = 68, row =  0, m = 5 },
  { n = "RVB", x = 88, row =  0, m = 6 },
  { n = "OUT", x = 108, row = 0, m = 7 },
}

-- REVERB is not a granulator entry point - it has no DRY IN of its own, and
-- a granulator can only reach it by flowing through COLOUR - so box 6 has no
-- entry here on purpose.
local HAL_FEED = { [3] = { "p_in1", "p_in2" }, [4] = { "s_in1", "s_in2" },
                   [5] = { "k_in1", "k_in2" }, [7] = { "o_in1", "o_in2" } }

local HAL_BW, HAL_BH = 18, 11

-- -inf to 0, and clamped there. Above 0 dB the number is not information any
-- more - the limiter is holding the roof up and what you need to know is that
-- you are AT the ceiling, which "0" says and "+2" does not say any better.
local function hal_db(v)
  if v <= 0.0002 then return "-inf" end
  return string.format("%.0f", math.min(20 * math.log(v, 10), 0))
end

-- top-left of a box
local function hal_xy(b)
  local mid = WAVE_TOP + (WAVE_H / 2) - (HAL_BH / 2)
  return b.x, mid + (b.row * ((WAVE_H - HAL_BH) / 2))
end

-- A wire as a list of points, routed so it touches nothing.
--
-- GRAINSWARM 1's feeds run along a bus ABOVE the chain row and drop into the
-- top edge of their target; GRAINSWARM 2's run below and rise into the
-- bottom edge. The only diagonal in the picture is the short hop into SPE,
-- which has nothing between it and the granulators. Nothing crosses a box and
-- the two granulators never share a line, so at a glance the top half of the
-- picture is GR1 and the bottom half is GR2.
local function hal_wire(gi, b, lvl)
  local gx, gy = hal_xy(HAL_BOX[gi])
  local bx, by = hal_xy(b)
  local sy = gy + (HAL_BH / 2)                 -- leaves the granulator here
  -- The bus is STRAIGHT. It used to vibrate by up to a pixel with the level,
  -- which on a 128x64 screen reads as the drawing being unstable rather than
  -- as the signal being loud. The flow says that better: the dashes travel
  -- towards the destination, and how fast they travel IS the level.
  local bus = (gi == 1) and (WAVE_TOP + 1) or (WAVE_TOP + WAVE_H - 1)
  local enter = (gi == 1) and by or (by + HAL_BH)   -- top or bottom edge
  local tx = bx + (HAL_BW / 2)
  if b.m == 3 then
    -- straight into RESONATOR's side: it is the first box and the space in
    -- front of it is empty, so a bus would be ceremony
    return { { gx + HAL_BW, sy }, { bx, by + (HAL_BH / 2) } }
  end
  return { { gx + HAL_BW, sy }, { gx + HAL_BW + 4, sy },
           { gx + HAL_BW + 4, bus }, { tx, bus }, { tx, enter } }
end

-- Draw a polyline as travelling dashes.
--
-- The flow IS the signal: dashes travel at a constant speed and it is
-- brightness, not speed, that carries the feed amount. That is the whole
-- reason the numbers came off the chain boxes - a number tells you a level
-- at a point, a moving wire tells you where the signal is going, and how
-- much of it is FEED AMOUNT in the same pixels, so turning a feed down
-- fades its wire out rather than slowing it.
--
-- Kept subtle on purpose: three-pixel dashes with three-pixel gaps.
local function hal_flow(pts, amt, lvl, phase, lev)
  local segs = {}
  local total = 0
  for i = 1, #pts - 1 do
    local dx = pts[i + 1][1] - pts[i][1]
    local dy = pts[i + 1][2] - pts[i][2]
    local len = math.sqrt((dx * dx) + (dy * dy))
    segs[i] = { pts[i], pts[i + 1], len, total }
    total = total + len
  end
  if total < 1 then return end
  local step = 6
  local off = (phase * step) % step
  screen.level(lev)
  local d = off - step
  while d < total do
    local a, b2 = d, math.min(d + 3, total)
    d = d + step
    if b2 > 0 then
      a = math.max(a, 0)
      for _, sg in ipairs(segs) do
        local s0, s1 = sg[4], sg[4] + sg[3]
        local ca, cb = math.max(a, s0), math.min(b2, s1)
        if cb > ca then
          local t0 = (ca - s0) / sg[3]
          local t1 = (cb - s0) / sg[3]
          screen.move(sg[1][1] + ((sg[2][1] - sg[1][1]) * t0),
                      sg[1][2] + ((sg[2][2] - sg[1][2]) * t0))
          screen.line(sg[1][1] + ((sg[2][1] - sg[1][1]) * t1),
                      sg[1][2] + ((sg[2][2] - sg[1][2]) * t1))
        end
      end
    end
  end
  screen.stroke()
end

function draw_hallat()
  screen.aa(0)

  -- the spine first, dim and continuous: it is always there and it is the
  -- thing the animated wires join
  screen.level(2)
  for i = 3, 6 do
    local ax, ay = hal_xy(HAL_BOX[i])
    local bx, by = hal_xy(HAL_BOX[i + 1])
    screen.move(ax + HAL_BW, ay + (HAL_BH / 2))
    screen.line(bx, by + (HAL_BH / 2))
  end
  screen.stroke()

  for _, b in ipairs(HAL_BOX) do
    local f = HAL_FEED[b.m]
    if f then
      for gi = 1, 2 do
        local amt = pval(f[gi])
        if amt > 0.005 then
          local lvl = meters[gi] or 0
          -- phase runs on the free display clock at a fixed speed - dash
          -- travel used to scale with level, but that read as the drawing
          -- stuttering rather than as the signal being loud, so speed is now
          -- constant and brightness (below) carries the feed amount instead.
          local ph = filt_t * 2
          hal_flow(hal_wire(gi, b, lvl), amt, lvl, ph,
            util.clamp(math.floor(2 + (amt * 9)), 2, 12))
        end
      end
    end
  end

  local selc = PAGES[page].cells[sel[page]]
  local selid = selc and selc.id

  for _, b in ipairs(HAL_BOX) do
    local x, y = hal_xy(b)
    local lv = meters[b.m] or 0
    local seen = meter_seen[b.m]

    -- the box is filled BEHIND its name by its own level, so the meter and
    -- the label occupy the same pixels instead of competing for the row
    screen.level(0)
    screen.rect(x, y, HAL_BW, HAL_BH)
    screen.fill()
    screen.level(2)
    screen.rect(x + 0.5, y + 0.5, HAL_BW - 1, HAL_BH - 1)
    screen.stroke()
    -- THE BAR IS IN DECIBELS, over a 40 dB window. Linear amplitude put -15
    -- dB - a perfectly healthy signal - at a fifth of the box, so every meter
    -- sat near empty all the time and the top four fifths of the bar were
    -- reserved for levels you should never see. On a dB scale -15 fills
    -- five eighths of it, which is what a meter is for.
    if seen and lv > 0.001 then
      local f = util.clamp((20 * math.log(math.max(lv, 1e-6), 10) + 40) / 40,
        0, 1)
      screen.level(5)
      screen.rect(x + 1, y + 1, math.max(f * (HAL_BW - 2), 1), HAL_BH - 2)
      screen.fill()
    end
    screen.level(15)
    screen.move(x + 2, y + 8)
    -- The output box IS its readout. "OUT" is the rightmost box on a chain
    -- that reads left to right, so its position already says which one it is,
    -- and the one thing you want from it is the number.
    if b.m == 7 then
      screen.text(seen and hal_db(lv) or "--")
    else
      screen.text(b.n)
    end
  end

  -- the selected feed pair is ringed, so E2/E3 are visibly attached to a box
  for _, b in ipairs(HAL_BOX) do
    local f = HAL_FEED[b.m]
    if f and selid == f[1] then
      local x, y = hal_xy(b)
      screen.level(15)
      screen.rect(x - 1.5, y - 1.5, HAL_BW + 2, HAL_BH + 2)
      screen.stroke()
    end
  end

  screen.aa(0)
end

-- ---------------------------------------------------------------------------
-- SNAPSHOTS: the slot grid
--
-- Fifteen columns of eight, laid out exactly as the monome is, so a slot on
-- screen is the key under your finger. A saved slot is a filled square; an
-- empty one is an outline.
--
-- The two animations are the same number moving in opposite directions and
-- they deliberately do NOT look alike. Saving fills from the bottom, the way a
-- thing being written fills up. Clearing dithers away against a fixed
-- threshold field, so the fill breaks up and evaporates rather than draining -
-- which reads as losing something rather than as filling it backwards.
-- ---------------------------------------------------------------------------

-- fixed per-pixel threshold, so a square dissolving twice dissolves the same
-- way. Random per frame would boil.
local SNAP_TH = {}
for i = 0, 63 do SNAP_TH[i] = ((i * 37) % 61) / 60 end

-- The slots that are not idle this frame, held between frames so the page is
-- not allocating a table twenty-five times a second for something that is
-- usually empty.
local rit_busy = {}

function draw_ritratt()
  local st = snap_state()
  -- Five pixels tall, not six. Eight rows of six ran from y=11 to y=59 and
  -- the legend's glyphs start at about 57, so the bottom two rows had text
  -- through them. Give the legend its own band rather than drawing over the
  -- thing it is describing.
  local x0, y0 = 3, 9
  local cw, ch = 8, 5
  screen.aa(0)

  -- the gestures, because there is no grid on some rigs and nothing else on
  -- this page says what the keys do
  screen.level(2)
  screen.move(2, 62)
  screen.text("K2 LOAD   K3 SAVE   BOTH CLEAR")

  -- TWO PATHS FOR A HUNDRED AND TWENTY SQUARES.
  --
  -- Every slot used to get its own level/rect/stroke, so this page cost 360
  -- cairo calls a frame before it drew anything else - by a wide margin the
  -- most expensive thing the script asks the screen to do, on the same thread
  -- that reads the encoders. But almost every slot is IDLE, and an idle slot
  -- is drawn at exactly one of two brightnesses: empty, or holding a
  -- snapshot. Two brightnesses is two paths, whatever the number of squares.
  --
  -- Only the slots actually DOING something - filling, dissolving, pulsing,
  -- or under the cursor - still need a call of their own, and there are never
  -- more than a handful of those at once.
  local busy_n = 0
  for pass = 0, 1 do
    screen.level((pass == 1) and 4 or 2)
    local any = false
    for i = 1, 120 do
      local f = st.fill[i] or 0
      local pu = st.pulse[i] or 0
      local occ = snap_occupied(i)
      if f > 0.02 or pu > 0 or i == st.sel then
        if pass == 0 then
          busy_n = busy_n + 1
          rit_busy[busy_n] = i
        end
      elseif (occ and 1 or 0) == pass then
        local col = ((i - 1) % 15)
        local row = math.floor((i - 1) / 15)
        screen.rect(x0 + (col * cw) + 0.5, y0 + (row * ch) + 0.5,
          cw - 3, ch - 3)
        any = true
      end
    end
    if any then screen.stroke() end
  end

  for b = 1, busy_n do
    local i = rit_busy[b]
    local col = ((i - 1) % 15)
    local row = math.floor((i - 1) / 15)
    local x, y = x0 + (col * cw), y0 + (row * ch)
    local f = st.fill[i] or 0
    local occ = snap_occupied(i)
    -- The pulse: swell, then settle. sin() rather than a decay, because a
    -- decay starts at its biggest and only shrinks - what you want to see is
    -- the square GROW and come back, which is one arc, not half of one.
    local pu = st.pulse[i] or 0
    local grow = (pu > 0) and (math.sin(pu * math.pi) * 2.6) or 0
    if grow > 0 then
      x = x - grow
      y = y - grow
    end
    local gw, gh = cw + (grow * 2), ch + (grow * 2)

    if f > 0.02 then
      if occ then
        -- filling up, from the bottom
        local fh = math.max(1, util.round((gh - 2) * f))
        screen.level(util.clamp(
          math.floor(((st.last == i) and 15 or 11) + (pu * 4) + 0.5), 1, 15))
        screen.rect(x, y + (gh - 2) - fh, gw - 2, fh)
        screen.fill()
      else
        -- dissolving: keep the pixels whose threshold is still under f
        screen.level(9)
        local k = 0
        for py = 0, ch - 3 do
          for px = 0, cw - 3 do
            if SNAP_TH[k % 64] < f then screen.rect(x + px, y + py, 1, 1) end
            k = k + 1
          end
        end
        screen.fill()
      end
    end
    if f < 0.98 then
      screen.level(util.clamp(
        math.floor((occ and 4 or 2) + (pu * 9) + 0.5), 1, 15))
      screen.rect(x + 0.5, y + 0.5, gw - 3, gh - 3)
      screen.stroke()
    end
    if i == st.sel then
      screen.level(15)
      screen.rect(x - 0.5, y - 0.5, gw - 1, gh - 1)
      screen.stroke()
    end
  end
end

-- ---------------------------------------------------------------------------
-- PAPPUS - the last page
--
-- A pappus is the parachute on a dandelion seed. One is spawned by every
-- GRAIN THAT ACTUALLY FIRES - not one per voice, not eight sitting there
-- being animated - so the air fills at the rate the instrument is playing and
-- empties when it stops. A held chord at 1/16 is a blizzard; one voice at 1/1
-- is a seed every couple of seconds, drifting alone.
--
-- Everything about how they move comes from the modules:
--
--   OUT level     how fast the air moves, and how bright they are
--   MODNI 1 / 2   the wind direction, so a modulated instrument visibly
--                 changes which way the air is going
--   WOW           a slow swirl laid over the wind - the one control whose
--                 character is unsteadiness, doing the same job here
--   NOISE         turbulence: per-frame jitter on every seed
--   DRIVE         spin, and unevenness in the crown - a driven signal has
--                 ragged seeds turning fast
--   N.TONE        how many filaments each crown has
--   LOSS          filaments missing from the crown
--   CRUSH         positions snap to a grid, so the drift steps
--   RESONATOR     where the seeds are in the air: a high FREQUENCY lifts them
--   the grain     its own level sets the seed's size and brightness, its
--                 pitch how high it enters
--
-- It costs about the same as the COLOUR page: one stroke for a crown, one for
-- a stalk. The air empties when you leave, so arriving is always a clear sky
-- filling up rather than ten minutes of drift nobody watched.
-- ---------------------------------------------------------------------------


do
  local PAPPI_MAX = 24
  local pappi = {}
  local since_grain = 0            -- seconds since the last grain
  local since_seed = 0             -- since the last seed, so a dense pattern
                                  -- fills the air without flooding it
  -- set by the display metro from the page you are on: the seeding happens
  -- deep inside the grain tick, which has no business knowing about pages
  pappus_live = false

  function pappus_clear()
    for i = #pappi, 1, -1 do pappi[i] = nil end
  end

  -- (w, lvl, semi) - and it was (w, v, lvl, semi) until this was read again.
  -- The call site passes three, so the level was landing in `v`, the PITCH in
  -- `lvl` and nothing in `semi`: seeds were sized by a note number and every
  -- one of them entered at the same height. It looked fine, because the
  -- default chord is one voice at semitone zero and zero is a plausible level.
  function pappus_seed(w, lvl, semi)
    if not pappus_live then return end
    since_grain = 0
    -- No time throttle. There was one - a tenth of a second - and it quietly
    -- turned "one per grain" into "one per TICK": eight voices fire on the
    -- same tick, the first took the slot and the other seven were refused, so
    -- a chord put no more in the air than a single note. The cap is the only
    -- limit now. A dense pattern fills the sky and holds it full, which is
    -- what dense playing ought to look like.
    if #pappi >= PAPPI_MAX then return end
    since_seed = 0
    -- a high note enters high, and RESONATOR's FREQUENCY lifts the whole field
    local lift = params:lookup_param("p_freq").controlspec:unmap(pval("p_freq"))
    local ny = util.clamp(52 - (util.clamp((semi or 0) + 24, 0, 48) / 48 * 34)
      - (lift * 12) + (math.random() * 8 - 4), 4, 60)
    pappi[#pappi + 1] = {
      x = (w == 1) and (math.random() * 40) or (88 + (math.random() * 40)),
      y = ny,
      -- its own drift, on top of the wind, so a crowd does not move as a block
      vx = (math.random() * 2 - 1) * 3,
      vy = (math.random() * 2 - 1) * 2,
      -- SIZE COMES FROM THE NOTE, not the level. A voice's level is 1 unless
      -- somebody has been holding grid keys, so sizing by it made every seed
      -- the same size; the pitch is always different. High notes are small
      -- seeds, which is also how it works outside.
      r = 2.5 + (math.random() * 1.5)
        + ((1 - util.clamp(((semi or 0) + 24) / 48, 0, 1)) * 2.5),
      -- a fixed-per-seed scale, standing in for how far into the screen it
      -- spawned. Fixed at birth like LOSS's missing filaments, not redrawn
      -- every frame, so a "near" seed reads as near and does not flicker.
      depth = 0.55 + (math.random() * 0.9),
      rot = math.random() * math.pi * 2,
      spin = (math.random() * 2 - 1) * 0.8,
      seedy = math.random() * math.pi * 2,
      age = 0,
      life = 7 + (math.random() * 7),
      lvl = lvl or 1,
      w = w,
    }
  end

  function pappus_advance(dt)
    if not pappus_live then
      if #pappi > 0 then pappus_clear() end
      return
    end
    since_seed = since_seed + dt
    since_grain = since_grain + dt

    -- Nothing playing is not the same as nothing to look at. After a few
    -- seconds of silence the air keeps a few seeds in it anyway, drifting -
    -- otherwise the page is a blank screen on a quiet instrument, which is
    -- indistinguishable from a broken one.
    if since_grain > 4 and #pappi < 5 and since_seed > 1.5 then
      since_seed = 0
      pappus_seed_idle()
    end

    local wind = vis and vis.wow or 0
    local sp = 0.35 + (out_amp_disp * 2.6)
    local wx = ((lfos[1] and lfos[1].val or 0) * 7) + 1.5
    local wy = (lfos[2] and lfos[2].val or 0) * 4
    local turb = (vis and vis.noise or 0) * 26
    local swirl = (vis and vis.wob or 0)

    for i = #pappi, 1, -1 do
      local p = pappi[i]
      p.age = p.age + dt
      if p.age >= p.life then
        table.remove(pappi, i)
      else
        -- the wind, plus a swirl whose phase depends on where in the frame the
        -- seed is, so the field rotates slowly rather than blowing one way
        local sw = wind * 9
        local ax = wx + (math.cos(swirl + (p.y * 0.09)) * sw)
        local ay = wy + (math.sin(swirl + (p.x * 0.06)) * sw * 0.6)
        p.vx = p.vx + ((ax - p.vx) * math.min(dt * 0.7, 1))
        p.vy = p.vy + ((ay - p.vy) * math.min(dt * 0.7, 1))
        if turb > 0.5 then
          p.vx = p.vx + ((math.random() * 2 - 1) * turb * dt)
          p.vy = p.vy + ((math.random() * 2 - 1) * turb * dt * 0.7)
        end
        p.x = p.x + (p.vx * sp * dt * 6)
        p.y = p.y + (p.vy * sp * dt * 6)
        p.rot = p.rot + (p.spin * dt * (0.4 + ((vis and vis.drive or 0) * 3.5)))
        -- off one edge and back on the other: the air does not end at the frame
        if p.x < -12 then p.x = 140 elseif p.x > 140 then p.x = -12 end
        if p.y < -12 then p.y = 76 elseif p.y > 76 then p.y = -12 end
      end
    end
  end

  function pappus_seed_idle()
    pappi[#pappi + 1] = {
      x = math.random() * 128, y = math.random() * 64,
      vx = (math.random() * 2 - 1) * 2, vy = (math.random() * 2 - 1) * 1.5,
      r = 3 + (math.random() * 3), depth = 0.55 + (math.random() * 0.9),
      rot = math.random() * math.pi * 2,
      spin = (math.random() * 2 - 1) * 0.6, seedy = math.random() * math.pi * 2,
      age = 0, life = 9 + (math.random() * 8), lvl = 0.4, w = 1,
    }
  end

  function draw_pappus()
    screen.clear()
    screen.aa(1)
    screen.line_width(1)

    local drive = vis and vis.drive or 0
    local loss = vis and vis.loss or 0
    local crush = vis and vis.crush or 0
    local tone = vis and vis.tone or 0
    local nfil = 5 + math.floor(tone * 6)
    local q = (crush > 0.02) and (1 + math.floor(crush * 5)) or 0

    for _, p in ipairs(pappi) do
      -- fade in over the first second and out over the last two, so nothing
      -- ever appears or vanishes - they drift into view
      local f = math.min(p.age / 1.0, 1)
        * math.min((p.life - p.age) / 2.0, 1)
      local lv = util.clamp(math.floor(
        (2 + (p.lvl * 7) + (out_amp_disp * 6)) * f + 0.5), 0, 15)
      if lv > 0 then
        local x, y = p.x, p.y
        if q > 0 then
          x = math.floor(x / q + 0.5) * q
          y = math.floor(y / q + 0.5) * q
        end
        local r = p.r * p.depth * (0.85 + (out_amp_disp * 0.5))

        -- THE CROWN. All the filaments go into one path and get one stroke:
        -- a stroke is a cairo flush, and twenty-eight seeds times ten flushes
        -- is not something a Pi does at twenty-five frames a second.
        screen.level(lv)
        for k = 0, nfil - 1 do
          -- LOSS takes filaments out, and WHICH ones is fixed per seed rather
          -- than random per frame - an eroded crown stays the same crown
          -- instead of boiling
          if loss < 0.02
            or ((((k * 37) + math.floor(p.seedy * 91)) % 100) >= (loss * 82)) then
            local a = p.rot + (k / nfil * math.pi * 2)
            -- DRIVE makes the crown ragged: alternate filaments run long
            local rr = r * (1 + (((k % 2 == 0) and 1 or -1) * drive * 0.45))
            screen.move(x + (math.cos(a) * 1.4 * 1.2), y + (math.sin(a) * 1.4))
            screen.line(x + (math.cos(a) * rr * 1.2), y + (math.sin(a) * rr))
          end
        end
        screen.stroke()

        -- the seed itself, hanging off the crown on its stalk, brighter than
        -- the fluff: it is the only solid part of a real one too
        local sa = p.rot + (math.pi * 0.5)
        local sx = x + (math.cos(sa) * (r + 2) * 1.2)
        local sy = y + (math.sin(sa) * (r + 2))
        screen.level(util.clamp(lv + 3, 0, 15))
        screen.move(x + (math.cos(sa) * 1.4 * 1.2), y + (math.sin(sa) * 1.4))
        screen.line(sx, sy)
        screen.stroke()
        if r > 4 then
          screen.rect(sx - 0.5, sy - 0.5, 1, 1)
          screen.fill()
        end
      end
    end

    screen.aa(0)
    screen.update()
  end
end

function redraw()
  local pg = PAGES[page]
  local c = cell_at(pg, sel[page])

  screen.clear()
  screen.aa(0)
  screen.line_width(1)

  -- The wipe. One translate in, one out - everything between is drawn in page
  -- coordinates and knows nothing about it.
  local wx, wy = wipe_offset()
  if wx ~= 0 or wy ~= 0 then screen.translate(wx, wy) end

  -- The scene owns the whole screen: no header, no cells, nothing to read. It
  -- still goes through the wipe, so it slides in from the edge like every
  -- other page rather than cutting.
  if pg.kind == "pappus" then
    draw_pappus()
    if wx ~= 0 or wy ~= 0 then screen.translate(-wx, -wy) end
    screen.update()
    return
  end

  -- Header: page name at the left, the selected cell's value at the right, its
  -- mode in between. All three are measured before anything is drawn, because
  -- fixed positions collide as soon as a name or a mode gets long - "BAQBAQ
  -- 1/2" ran straight into "POSITION". The middle is what gives way: it is
  -- clipped to whatever gap is left, and dropped entirely if there is none.
  local tog = pg.toggle and params:get(pg.toggle) == 2
  local TOGNAME = { m_lock = "LOCK", s_hold = "HOLD", p_freeze = "FREEZE",
                    bypass = "BYPASS", mod_hold = "LFO HOLD", mx_dim = "DIM" }

  local title = tog and TOGNAME[pg.toggle] or pg.name

  local value
  if pg.kind == "ritratt" then
    -- the slot the cursor is on, and whether it has audio in it
    local st = snap_state()
    value = string.format("%03d", st.sel)
    if scenes[st.sel] and scenes[st.sel].wav then value = value .. " *" end
  elseif not c then
    -- cell zero on a GRAINSWARM page is the waveform, and its value is the
    -- source. Everywhere else a page with no cell simply has no value.
    local vw = grain_vis_page(pg)
    value = vw and src_label(params:get(swid(vw, "src"))) or ""
  elseif c.id == "m_scan" then
    value = scan_label()
  elseif c.id == "s_rate" then
    value = clock_label(params:get("s_rate"))
  elseif c.id == "noise_tone" then
    -- the same knob means two things: a filter centre on the three washes,
    -- a PLAYBACK SPEED on the loop sources (1200Hz is 1x, the file's own
    -- recorded speed)
    local hz = pval("noise_tone")
    if params:get("noise_type") > 3 then
      value = string.format("%.2fx", hz / 1200)
    else
      value = string.format("%.0fHz", hz)
    end
  elseif c.id == "m_size" or c.id == "n_size" then
    -- in TIME, not in beats. The knob is in beats because a long grain wants
    -- to be musical, but the short end is a timbre and "0.004 beats" tells you
    -- nothing about it - milliseconds tell you whether you are in the
    -- microsound register or not.
    local sec = sent[((pg.sw or 1) == 2) and "nsize" or "msize"] or 0
    value = (sec < 1) and string.format("%.1fms", sec * 1000)
      or string.format("%.2fs", sec)
  elseif c.id == "n_rate_div" then
    -- Its own division, or the ratio when LINK is chosen - and the Hz either
    -- way, because a division on its own does not tell you how fast the pair
    -- has ended up running relative to each other.
    if params:get("n_rate_div") > #DIVS then
      value = string.format("%s %.2fHz", clock_label(params:get("n_rate")),
        grain_hz(2))
    else
      value = string.format("%.2fHz", grain_hz(2))
    end
  elseif c.id == "p_in1" then
    -- RESONATOR's DRY IN alone reaches above unity - see the params comment
    -- on why. Percent up to 100, same as every other DRY IN; past it the
    -- number switches to dB of boost, which is what "over 100%" actually
    -- means and reads unambiguously rather than as a number nobody can
    -- place against 0 dB.
    local function inpct(id)
      local x = pval(id)
      if x <= 1.0 then return string.format("%d", math.floor(x * 100 + 0.5)) end
      return string.format("+%.1fdB", 20 * math.log(x, 10))
    end
    value = string.format("GS1 %s / GS2 %s", inpct(c.id), inpct(c.alt))
  elseif c.dual then
    -- Both halves, NAMED. The cell shows two bars and the header used to show
    -- "70 / 70", which says there are two of something without saying which
    -- is which - and the two bars are stacked, so there is no left-to-right
    -- convention to fall back on either.
    value = string.format("GS1 %d / GS2 %d",
      math.floor(pval(c.id) * 100 + 0.5),
      math.floor(pval(c.alt) * 100 + 0.5))
  elseif c.id == "n_tilt" then
    local t = pval("n_tilt")
    value = (math.abs(t) < 0.02) and "FLAT"
      or string.format("%s %+.0fdB", (t > 0) and "TREBLE" or "BASS",
        math.abs(t) * 12)
  elseif c.id == "clock_tempo" then
    value = clock_external() and "EXT" or
      string.format("%.1f", params:get("clock_tempo"))
  elseif c.id == "m_tilt" then
    local t = pval("m_tilt")
    if math.abs(t) < 0.02 then
      value = "FLAT"
    else
      value = string.format("%s %+.0fdB", (t > 0) and "TREBLE" or "BASS",
        math.abs(t) * 12)
    end
  elseif c.id == "p_structure" then
    local m = pval("p_structure")
    if math.abs(m) < 0.02 then
      value = "HARMONIC"
    else
      -- ASCII only. string.format("%c", 177) emits a raw 0xB1, which is not
      -- valid UTF-8; norns draws text through cairo, cairo rejects it, and
      -- once its context is in an error state the screen stays blank on EVERY
      -- page. The file itself stays ASCII, so a file-encoding check cannot
      -- catch this - the bad byte is made at runtime.
      value = string.format("%s %.2f", (m > 0) and "BELL" or "GONG",
        math.abs(m))
    end
  elseif c.id == "m_strum" or c.id == "n_strum" then
    -- PHASE reads as whatever it is doing: a subdivision when EUCLID is off,
    -- a rotation in steps when it is on
    local w = pg.sw or 1
    local k = euclid_kn(w)
    if k == 0 then
      -- continuous now, so it reads as a fraction of the grain period rather
      -- than as a name from a list it no longer belongs to
      local f = params:get(c.id) * 0.125
      value = (f < 0.0005) and "ALIGN" or string.format("1/%.0f", 1 / f)
    else
      local r = euclid_rot(w)
      value = (r == 0) and "ALIGN" or string.format("ROT %d", r)
    end
  elseif c.id == "m_pitch" or c.id == "n_pitch" or c.id == "p_freq" then
    -- whole semitones only - params:string()'s default "%.2f st" is decimals
    -- for a grid that bump() now only ever lands on integers of.
    value = string.format("%+d st", params:get(c.id))
  elseif c.id == "m_euclid" or c.id == "n_euclid" then
    local k, n = euclid_kn(pg.sw or 1)
    value = (k == 0) and "OFF" or string.format("%d/%d", k, n)
  elseif c.id:match("^lfo%d+_rate$") then
    -- the ratio AND what it works out to, because the Lua LFOs are clamped
    -- and the knob would otherwise lie at the top of its travel
    local i = tonumber(c.id:match("^lfo(%d+)_rate$"))
    value = string.format("%s %.2fHz", clock_label(params:get(c.id)), lfos[i].hz)
  else
    value = params:string(c.id)
  end

  local mid, midlevel
  if cpu > 70 then
    mid, midlevel = string.format("CPU %d", math.floor(cpu)), 15
  elseif pg.kind == "ritratt" then
    local st = snap_state()
    local save_held, clear_held = snap_mods(st)
    mid = (save_held and "SAVE") or (clear_held and "CLEAR")
      or (snap_occupied(st.sel) and "SAVED" or "NEW")
    midlevel = (save_held or clear_held) and 15 or 5
  elseif c and c.mode then
    mid, midlevel = params:string(c.mode), 6
  elseif c and c.alt and not c.dual then
    mid, midlevel = params:string(c.alt), 6
  end

  -- Resolve the whole layout BEFORE drawing any of it. A long page name
  -- squeezes the mode out entirely, so pages that know they are long carry a
  -- short form used only when it is needed: once you are on the page its name
  -- is the redundant part, the mode is not.
  local tx = 1
  -- PAGE DOTS. "1/4" is a fraction you have to read; four dots with one lit
  -- is a position you can see. They cost the same four pixels a character
  -- would, and they are measured into the layout below like part of the name,
  -- because a mark that pushes the mode text off the screen is not free.
  local dots = (not tog) and pg.dots or nil
  local dotw = dots and ((dots[2] * 4) + 2) or 0
  local right = 127 - screen.text_extents(value) - 4
  local function fits()
    return (right - screen.text_extents(mid))
      >= (tx + screen.text_extents(title) + dotw + 4)
  end
  if mid and pg.short and not tog and not fits() then title = pg.short end
  if mid then
    -- and if it still does not fit, shave characters rather than overlap
    while #mid > 0 and not fits() do mid = mid:sub(1, #mid - 1) end
    if #mid <= 1 then mid = nil end
  end

  screen.level(tog and 3 or 15)
  screen.move(tx, 7)
  screen.text(title)
  if dots then
    local dx = tx + screen.text_extents(title) + 3
    for i = 1, dots[2] do
      screen.level((i == dots[1]) and 15 or 3)
      screen.rect(dx + ((i - 1) * 4), 3, 2, 2)
      screen.fill()
    end
  end
  screen.level(15)
  screen.move(127, 7)
  screen.text_right(value)

  if mid then
    screen.level(midlevel)
    screen.move(right, 7)
    screen.text_right(mid)
  end

  local k = pg.kind
  if k == "grain2" and EUCLID_CELLS[cell_at(pg, sel[page]) and
      cell_at(pg, sel[page]).id] then
    draw_euclid()
    draw_vis_bracket(pg)
  elseif k == "grain" or k == "grain2" then
    draw_waveform()
    draw_vis_bracket(pg)
  elseif k == "spettru" then
    draw_spettru()
  elseif k == "delay" then
    draw_stillel()
  elseif k == "magna" then
    draw_magna()
  elseif k == "envmod" then
    draw_envmod()
  elseif k == "hallat" then
    draw_hallat()
  elseif k == "ritratt" then
    draw_ritratt()
  else
    draw_kuluri()
  end

  draw_cells(pg)
  if wx ~= 0 or wy ~= 0 then screen.translate(-wx, -wy) end
  screen.update()
end

-- ---------------------------------------------------------------------------
-- grid
--   page 1: one row per grain. x1-12 semitones, x13-16 octave.
--   page 2: one row per deform param, x sets the value.
-- ---------------------------------------------------------------------------

function cols()
  return (g.cols and g.cols > 0) and g.cols or 16
end

-- Setting one cell from a grid column. Shared by every page's generic
-- parameter-row fallback, RESONATOR included.
function grid_set_cell(cell, x, nc)
  local p = params:lookup_param(cell.id)
  if is_option(cell.id) then
    params:set(cell.id,
      util.clamp(math.floor((x - 1) / nc * #p.options) + 1, 1, #p.options))
    return
  end
  -- Column one is the parameter's MINIMUM and the last column its MAXIMUM.
  --
  -- This used to be (x - 0.5) / nc - cell CENTRES rather than endpoints -
  -- which leaves both ends half a column short. On a sixteen-wide grid the
  -- bottom of a 0..1 control landed on 0.031 and the top on 0.969, so the
  -- leftmost key was not actually off and the rightmost was not actually
  -- full. On COLOUR, MODNI and SIGNAL, where a row IS one parameter, that is
  -- the difference between a clean bypass and a permanent trickle.
  local f = (nc > 1) and ((x - 1) / (nc - 1)) or 0
  if is_number(cell.id) then
    -- set_raw would throw on an add_number param
    local v = p.min + (f * (p.max - p.min))
    if p.min < 0 and p.max > 0 then
      -- a bipolar row has to be able to return to centre, and with an even
      -- column count no column lands on it by arithmetic. Snap the nearest.
      local step = (p.max - p.min) / math.max(nc - 1, 1)
      if math.abs(v) < step * 0.5 then v = 0 end
    end
    params:set(cell.id, v)
  else
    local spec = p.controlspec
    if spec and spec.minval < 0 and spec.maxval > 0 then
      local z = spec:unmap(0)
      -- <= , not < : with an even column count the two keys either side of
      -- centre are EXACTLY half a step away and a strict test snaps neither.
      if math.abs(f - z) <= (0.5 / math.max(nc - 1, 1)) + 1e-9 then f = z end
    end
    params:set_raw(cell.id, util.clamp(f, 0, 1))
  end
end

function g.key(x, y, z)
  if y < 1 or y > NVOICE then return end

  local kind = PAGES[page].kind

  -- Holding a grain key turns the encoders into that voice's level and
  -- probability. It is the only spare dimension on a grid whose rows and
  -- columns are both already spoken for, and it means the two most performative
  -- per-voice controls need no page of their own.
  if kind == "grain" or kind == "grain2" then
    if z == 1 then
      held_voice = y
    elseif held_voice == y then
      held_voice = nil
    end
  end
  -- PAPPUS is SNAPSHOTS' own slots wearing a different picture on the norns
  -- screen - the grid underneath it is still the 15x8 slot grid, so it needs
  -- the release too, to finish a hold-to-save started on this page.
  if z == 0 and kind ~= "ritratt" and kind ~= "pappus" then return end

  if kind == "grain" or kind == "grain2" then
    -- the chord you edit is the one belonging to the granulator whose page
    -- you are on
    local w = PAGES[page].sw or 1
    local G = gr(w)
    local n = cols()
    if n >= 16 then
      if x <= 12 then
        local st = G[y]
        if st.on and st.semi == (x - 1) then
          st.on = false
        else
          st.semi = x - 1
          st.on = true
        end
      else
        G[y].oct = util.clamp(x - 12, 1, #OCTAVES)
      end
    else
      -- narrow grid: semitones only, no octave keys
      local st = G[y]
      if st.on and st.semi == (x - 1) then
        st.on = false
      else
        st.semi = util.clamp(x - 1, 0, 11)
        st.on = true
      end
    end
    send_voices(w)
  elseif kind == "delay" then
    -- row = tap, x = step. Pressing while EUCLID is generating takes the
    -- pattern over rather than starting from an empty grid.
    adopt_pattern()
    local n = SSTEPS[params:get("s_steps")]
    local st = math.min(x, n) - 1
    if manual[y].on and manual[y].step == st then
      manual[y].on = false
    else
      manual[y].step, manual[y].on = st, true
    end
    sent.taps = nil
  elseif kind == "ritratt" or kind == "pappus" then
    -- Fifteen columns of slots and a sixteenth column split top/bottom: the
    -- top four rows arm SAVE, the bottom four arm CLEAR. Neither does
    -- anything on its own - it is a modifier, held in one hand while the
    -- other holds down a slot.
    --
    -- With a modifier down, a slot press is still a HOLD, not a tap: the
    -- square fills (or drains) with the finger exactly as it always did, and
    -- letting go before it completes backs out with nothing changed. The
    -- only thing that moved is which gesture arms which mode - it used to be
    -- one CLEAR key that flipped the same hold between save and clear; now
    -- it is which half of column 16 is under the other hand.
    --
    -- With NEITHER modifier down, a slot press is a plain, immediate load -
    -- there is nothing destructive about loading, so it needs no hold and no
    -- chance to back out.
    --
    -- PAPPUS reaches this branch too: it is SNAPSHOTS' own state under a
    -- different screen, not a different page of grid behaviour.
    local st = snap_state()
    local nc = cols()
    if nc >= 16 and x == 16 then
      st.mod16[y] = (z == 1)
      return
    end
    local i = ((y - 1) * SNAP_W) + x
    if i < 1 or i > SNAP_N then return end
    if z == 1 then
      st.sel = i
      local save_held, clear_held = snap_mods(st)
      if save_held or clear_held then
        -- The hold starts NOW and you watch it happen.
        st.hold = i
        snap_hold_start(i, save_held and "save" or "clear")
      else
        snap_recall(i)
        snap_pulse(i)
      end
    elseif st.hold == i then
      st.hold = nil
      -- released early: the animation eases back on its own and nothing
      -- committed. No fallback to a load here - a modifier was down, so the
      -- intent was never ambiguous the way a bare tap is.
      snap_hold_end()
    end
  elseif kind == "spettru" then
    -- RESONATOR's own chord: row = voice, x1-12 semitone, x13-16 octave -
    -- the same gesture as a grainswarm's grid, but writing into `sp_chord`
    -- rather than either granulator's, so it only ever moves the bank.
    local st = sp_chord[y]
    local n = cols()
    if n >= 16 then
      if x <= 12 then
        if st.on and st.semi == (x - 1) then
          st.on = false
        else
          st.semi = x - 1
          st.on = true
        end
      else
        st.oct = util.clamp(x - 12, 1, #OCTAVES)
      end
    else
      if st.on and st.semi == (x - 1) then
        st.on = false
      else
        st.semi = util.clamp(x - 1, 0, 11)
        st.on = true
      end
    end
    send_bank(true)
  else
    -- COLOUR, MODNI and SIGNAL: row = cell, x sets its value
    local cell = cell_at(PAGES[page], y)
    -- the tempo row is inert when something else owns the tempo
    if cell and cell.id == "clock_tempo" and clock_external() then cell = nil end
    if cell then
      sel[page] = y
      grid_set_cell(cell, x, cols())
    end
  end
end

-- The LED frame is built into a shadow buffer and only pushed to the device
-- when it DIFFERS from what is already on there.
--
-- The old version cleared the grid, wrote up to a hundred and twenty-eight
-- LEDs and sent a serial frame every display tick, twenty-five times a
-- second, whether anything had moved or not - and on most pages nothing does
-- for seconds at a time. Every one of those writes is a Lua-to-C call on the
-- thread that also reads the encoders, and the refresh is a serial write on
-- top. Comparing 128 integers first is cheaper than any of it.
local gbuf, gprev = {}, {}
for i = 1, 128 do gbuf[i], gprev[i] = 0, -1 end
local grid_last = 0
-- (x, y, l) not (self, ...): `g:led(a,b,c)` became `gled(a,b,c)`, a plain
-- call, when the colon went
local function gled(x, y, l)
  if x >= 1 and x <= 16 and y >= 1 and y <= 8 then
    gbuf[((y - 1) * 16) + x] = l
  end
end

function grid_redraw()
  if g.device == nil then
    -- Unplugged. Forget what was on it, so the frame after it comes back is
    -- unconditionally sent: a grid that reconnects is a BLANK grid, and
    -- comparing against what the old one was showing would leave it blank
    -- until something happened to move.
    gprev[1] = -1
    return
  end
  for i = 1, 128 do gbuf[i] = 0 end
  local nn = cols()
  local kind = PAGES[page].kind

  if kind == "grain" or kind == "grain2" then
    local G = gr(PAGES[page].sw or 1)
    for row = 1, NVOICE do
      local st = G[row]
      local fl = VS[PAGES[page].sw or 1].flash[row]
      local semis = math.min(12, nn)
      for x = 1, semis do
        local lv = BLACK[x - 1] and 1 or 3
        if st.semi == (x - 1) then
          lv = st.on and 15 or 6
          if st.on and fl > 0 then lv = 15 end
        end
        gled(x, row, lv)
      end
      if nn >= 16 then
        for i = 1, #OCTAVES do
          gled(12 + i, row, (st.oct == i) and (st.on and 12 or 5) or 2)
        end
      end
      -- a brief lift across the row when that grain fires
      if fl > 0.5 and st.on then
        gled(util.clamp(st.semi + 1, 1, semis), row, 15)
      end
    end
  elseif kind == "delay" then
    local n = math.min(SSTEPS[params:get("s_steps")], nn)
    local gen = using_euclid()
    for i = 1, NTAP do
      local t = taps[i]
      for x = 1, n do
        -- every fourth step marked, so the bar is readable
        gled(x, i, ((x - 1) % 4 == 0) and 2 or 1)
      end
      if t.on then
        local x = util.clamp(t.step + 1, 1, n)
        local lv = gen and 9 or 14
        if tap_flash[i] > 0 then lv = 15 end
        gled(x, i, lv)
      end
    end
  elseif kind == "ritratt" or kind == "pappus" then
    -- same slot grid PAPPUS's norns screen does not show
    local st = snap_state()
    local save_held, clear_held = snap_mods(st)
    for y = 1, NVOICE do
      for x = 1, math.min(SNAP_W, nn) do
        local i = ((y - 1) * SNAP_W) + x
        local lv = snap_occupied(i) and 8 or 1
        if i == st.last then lv = 15 end
        if i == st.sel then lv = math.max(lv, 4) end
        gled(x, y, lv)
      end
      if nn >= 16 then
        -- top half is SAVE, bottom half is CLEAR, so the split reads at a
        -- glance even before anything is held
        local armed = (y <= 4) and save_held or clear_held
        gled(16, y, armed and 15 or ((y <= 4) and 4 or 2))
      end
    end
  elseif kind == "spettru" then
    for row = 1, NVOICE do
      local st = sp_chord[row]
      local semis = math.min(12, nn)
      for x = 1, semis do
        local lv = BLACK[x - 1] and 1 or 3
        if st.semi == (x - 1) then lv = st.on and 15 or 6 end
        gled(x, row, lv)
      end
      if nn >= 16 then
        for i = 1, #OCTAVES do
          gled(12 + i, row, (st.oct == i) and (st.on and 12 or 5) or 2)
        end
      end
    end
  else
    for i = 1, math.min(#PAGES[page].cells, 8) do
      local cell = cell_at(PAGES[page], i)
      if cell then
      local v = frac(cell.id)
      -- the COLUMN that sets this value, using the same endpoint mapping
      -- g.key does, so the bar ends under the key you pressed. It used to be
      -- round(v * nn), which is a cell-centre mapping and read one column
      -- short of wherever you had just put your finger.
      local col = util.clamp(util.round(v * (nn - 1)) + 1, 1, nn)
      local lv = (i == sel[page]) and 15 or 8
      if cell.bipolar then
        local zc = util.clamp(
          util.round(zero_frac(cell.id) * (nn - 1)) + 1, 1, nn)
        for x = math.min(zc, col), math.max(zc, col) do gled(x, i, lv) end
        gled(util.clamp(zc, 1, nn), i, 4)
      elseif v > 0.0001 then
        for x = 1, col do gled(x, i, lv) end
      end
      if (not cell.bipolar) and v <= 0.0001 then
        gled(1, i, (i == sel[page]) and 4 or 2)
      end
      end
    end
  end

  local dirty = false
  for i = 1, 128 do
    if gbuf[i] ~= gprev[i] then dirty = true; break end
  end
  if not dirty then return end
  -- ...and even a changed frame is only sent as often as GRID FPS allows.
  -- What is missed is picked up on the next tick, because the comparison
  -- above is against what was last SENT, not against the last frame built.
  --
  -- A millisecond of slack: without it the interval and the tick are the same
  -- number, floating point decides which is fractionally larger, and at the
  -- default the throttle halves the rate it was meant to leave alone.
  local now = util.time()
  if (now - grid_last) < ((1 / GRID_FPS) - 0.001) then return end
  grid_last = now

  g:all(0)
  for y = 1, 8 do
    for x = 1, nn do
      local v = gbuf[((y - 1) * 16) + x]
      if v ~= 0 then g:led(x, y, v) end
    end
  end
  g:refresh()
  for i = 1, 128 do gprev[i] = gbuf[i] end
end
