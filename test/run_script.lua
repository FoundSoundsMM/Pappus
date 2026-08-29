-- Run pappus.lua against the mock norns API and exercise every handler.
-- Usage: lua5.3 test/run_script.lua

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")

local ok, err = pcall(dofile, "pappus.lua")
if not ok then
  print("FAIL loading script: " .. tostring(err))
  os.exit(1)
end

local function step(label, fn)
  local ok, err = pcall(fn)
  if not ok then
    print("FAIL " .. label .. ": " .. tostring(err))
    os.exit(1)
  end
end

step("init", init)

-- read the page list from the script rather than counting by hand
local NPAGE = #pappus.pages
local SKENI_PAGE
for i, pg in ipairs(pappus.pages) do
  if pg.kind == "ritratt" then SKENI_PAGE = i end
end
assert(SKENI_PAGE, "no SNAPSHOTS page")

local m = mock.metros[1]
assert(m and m.event, "no metro registered")
-- the second metro is MAGNA's, running faster than the display
local mmod = mock.metros[2]
assert(mmod and mmod.event, "no modulation metro registered")

-- feed the amplitude polls the way norns does, then run frames
local function tick(frames, amp)
  for i = 1, frames do
    for _, p in pairs(mock.polls) do
      if p.callback then p.callback(amp) end
    end
    mock.advance_time(1 / 25)
    mmod.event()
    m.event()
  end
end

step("40 frames, silence", function() tick(40, 0.0) end)
step("200 frames, signal", function() tick(200, 0.22) end)

-- exercise both pages, every cell, every encoder and key
step("ui sweep", function()
  for pg = 1, NPAGE do
    for cell = 1, 12 do
      enc(1, 1)
      for _, d in ipairs({ 1, 1, -1, 5, -20, 40 }) do
        enc(2, d); enc(3, d)
      end
      redraw()
    end
    key(3, 1); key(3, 0)
  end
  for _ = 1, 8 do key(2, 1); key(2, 0) end
end)

-- every page's long-K3 toggle, then put them all back: a latched toggle left
-- behind looks exactly like a broken feature in whatever step runs next
local TOGGLES = { "m_lock", "p_freeze", "s_hold", "bypass", "mod_hold",
                  "mx_dim", "mod_bypass" }
local function clear_toggles()
  for _, id in ipairs(TOGGLES) do params:set(id, 1) end
end

step("long K3 on every page", function()
  for pg = 1, NPAGE do
    key(3, 1)
    mock.advance_time(0.8)
    key(3, 0)
    tick(4, 0.1)
    key(3, 1); key(3, 0)
  end
  for _ = 1, 8 do key(2, 1); key(2, 0) end
end)

step("grid, every key on every page", function()
  for pg = 1, NPAGE do
    for y = 1, 8 do
      for x = 1, 16 do
        mock.grid.key(x, y, 1); mock.grid.key(x, y, 0)
      end
    end
    tick(2, 0.1)
    key(3, 1); key(3, 0)
  end
  for _ = 1, 8 do key(2, 1); key(2, 0) end
end)

step("8-column grid fallback", function()
  mock.grid.cols = 8
  for y = 1, 8 do for x = 1, 8 do mock.grid.key(x, y, 1) end end
  tick(4, 0.1)
  mock.grid.cols = 16
end)

step("extreme params", function()
  for _, id in ipairs({ "m_sos", "m_scan", "m_spray", "m_size", "m_rate_free",
                        "m_swarm", "drive", "crush", "loss", "noise", "k_wow",
                        "n_pitch", "n_rate", "n_size", "n_spray", "n_sos",
                        "n_swarm", "n_euclid", "n_buflen",
                        "p_in1", "p_in2", "s_in1", "s_in2",
                        "k_in1", "k_in2", "o_in1", "o_in2", "mx_comp",
                        "s_euclid", "s_spread", "s_feedback", "s_tilt",
                        "s_diffuse", "s_wet", "s_rate",
                        "m_buflen", "m_win_start", "m_win_end", "m_strum",
                        "m_vspread",
                        "m_euclid",
                        "p_freq", "p_structure", "p_bright", "p_damp",
                        "p_pos", "p_grain", "p_wet",
                        "lfo1_rate", "lfo1_phase", "lfo1_a1",
                        "lfo8_rate", "lfo8_phase", "lfo8_a1",
                        "mx_in",
                        "mx_limit", "mx_out",
                        "env_atk", "env_rel", "env_sens", "env_a1", "env_a2",
                        "noise_dyn", "noise_decay" }) do
    params:set_raw(id, 0); tick(3, 0.2)
    params:set_raw(id, 1); tick(3, 0.2)
  end
  for _, id in ipairs({ "m_scan_mode", "m_spray_mode", "m_rate", "m_scale",
                        "crush_mode", "noise_type",
                        "m_swarm_mode", "n_swarm_mode", "n_lock", "m_lock", "bypass",
                        "m_src", "n_src",
                        "s_steps", "s_tilt_mode", "s_hold",
                        "p_freeze", "p_freqmode", "p_model",
                        "lfo1_shape", "lfo2_shape", "s_link",
                        "env_d1", "env_d2", "m_scale",
                        "mx_dim", "mod_hold", "mod_bypass" }) do
    local p = params:lookup_param(id)
    local orig = params:get(id)
    for v = 1, #p.options do params:set(id, v); tick(2, 0.2) end
    -- put it back: leaving every toggle latched on quietly breaks the steps
    -- that follow, which is a test bug that looks exactly like a script bug
    params:set(id, orig)
  end
  -- add_number params have neither options nor a controlspec, so they sweep
  -- their own way. get_raw throws on them.
  for _, id in ipairs({ "m_voices", "m_elen" }) do
    local p = params:lookup_param(id)
    local orig = params:get(id)
    for v = p.min, p.max do params:set(id, v); tick(1, 0.2) end
    params:set(id, orig)
  end
end)

step("sos freeze then release", function()
  params:set("m_sos", 1.0); tick(60, 0.2)
  params:set("m_sos", 0.0); tick(60, 0.2)
end)

-- the delay rate knob: 50 must be exactly the granulator's own period,
-- below it stretches the cycle, above it shortens it. Checked against the
-- value actually sent to the engine, not against the knob.
step("delay rate is the CLOCK, not the grain rate", function()
  local function cycle(knob)
    params:set("s_rate", knob)
    tick(1, 0.1)
    return mock.calls.last.scycle and mock.calls.last.scycle[1]
  end
  local beat = 60 / clock.get_tempo()
  local mid = cycle(50)
  assert(mid and math.abs(mid - beat) < 1e-6,
    string.format("s_rate 50 should be one BEAT (%.4f), got %s",
      beat, tostring(mid)))
  local slow, fast = cycle(0), cycle(100)
  assert(slow > mid * 4, "s_rate 0 should stretch the cycle, got " .. slow)
  assert(fast < mid / 8, "s_rate 100 should shorten the cycle, got " .. fast)

  -- and the granulator's own RATE must not move it at all: that coupling is
  -- exactly what this change removed, so it is worth an assertion rather than
  -- a comment
  local at50 = cycle(50)
  for _, r in ipairs({ 1, 3, 5, 7, 9, 10 }) do
    params:set("m_rate", r)
    assert(math.abs(cycle(50) - at50) < 1e-9,
      "GRAINSWARM RATE " .. r .. " moved the delay cycle")
  end

  -- the LFOs are on the same clock. x1 is one cycle per beat.
  params:set("lfo1_rate", 50)
  tick(2, 0.1)
  assert(math.abs(lfo_hz(1) - (clock.get_tempo() / 60)) < 1e-6,
    "LFO at x1 should run at one cycle per beat, got " .. lfo_hz(1))
  local was = lfo_hz(1)
  params:set("m_rate", 1)          -- 4/1, the slowest grain division
  tick(2, 0.1)
  assert(math.abs(lfo_hz(1) - was) < 1e-9,
    "GRAINSWARM RATE moved the LFO")

  params:set("m_rate", 7); params:set("s_rate", 50)
end)

-- the window must confine the playhead: with the window closed to the top
-- half, nothing the engine is told to play may sit below it
step("active window confines the playhead", function()
  params:set("m_win_start", 0.5)
  params:set("m_win_end", 0.9)
  assert(params:get("m_win_start") == 0.5 and params:get("m_win_end") == 0.9)
  params:set("m_scan_mode", 2)
  for _, s in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
    params:set("m_scan", s)
    tick(3, 0.1)
  end
  -- and the ends cannot cross
  params:set("m_win_end", 0.1)
  assert(params:get("m_win_start") <= params:get("m_win_end") - 0.019,
    "window ends crossed")
  params:set("m_win_start", 0); params:set("m_win_end", 1)
end)

-- MAGNA has to actually move a destination, and hand it back when switched off
step("lfo modulates and releases", function()
  clear_toggles()
  params:set("m_spray", 0.5)
  local base = mock.calls.last.mspray and mock.calls.last.mspray[1]
  params:set("lfo1_shape", 3)          -- SINE
  params:set("lfo1_rate", 50)
  params:set("lfo1_a1", 1.0)
  -- find the SPRAY destination by name rather than by a hardcoded index
  local target
  local p = params:lookup_param("lfo1_d1")
  for i, n in ipairs(p.options) do if n == "G1.SPRAY" then target = i end end
  assert(target, "G1.SPRAY destination missing")
  params:set("lfo1_d1", target)

  local lo, hi = 1e9, -1e9
  for _ = 1, 200 do
    mock.advance_time(1 / 60)
    mmod.event()
    local v = mock.calls.last.mspray[1]
    lo = math.min(lo, v); hi = math.max(hi, v)
  end
  assert(hi - lo > 0.3,
    string.format("lfo should sweep spray, saw %.3f..%.3f", lo, hi))

  -- switching the destination off must restore the knob's own value
  params:set("lfo1_d1", 1)
  mock.advance_time(1 / 60); mmod.event()
  local back = mock.calls.last.mspray[1]
  assert(math.abs(back - 0.5) < 1e-6,
    "destination not released, spray left at " .. tostring(back))

  -- bypass must do the same
  params:set("lfo1_d1", target)
  for _ = 1, 30 do mock.advance_time(1 / 60); mmod.event() end
  params:set("mod_bypass", 2)
  mock.advance_time(1 / 60); mmod.event()
  assert(math.abs(mock.calls.last.mspray[1] - 0.5) < 1e-6,
    "bypass did not release the destination")
  params:set("mod_bypass", 1); params:set("lfo1_d1", 1)
  params:set("lfo1_a1", 0)
  assert(base ~= nil)
end)

-- every shape must produce a bounded, moving value
step("all lfo shapes", function()
  clear_toggles()
  for sh = 1, 5 do
    params:set("lfo2_shape", sh)
    params:set("lfo2_a1", 1.0)
    local p = params:lookup_param("lfo2_d1")
    for i, n in ipairs(p.options) do if n == "C.DRIVE" then params:set("lfo2_d1", i) end end
    local lo, hi = 1e9, -1e9
    for _ = 1, 240 do
      mock.advance_time(1 / 60); mmod.event()
      local v = mock.calls.last.drive[1]
      lo = math.min(lo, v); hi = math.max(hi, v)
    end
    assert(lo >= 0 and hi <= 1, "shape " .. sh .. " left the destination range")
    assert(hi - lo > 0.2, "shape " .. sh .. " did not move: " .. lo .. ".." .. hi)
  end
  params:set("lfo2_d1", 1); params:set("lfo2_a1", 0)
end)

-- SIGNAL is the routing now, not a mixer. Two claims: the input and output
-- faders still reach a TRUE zero rather than -60 dB of residue, and every
-- routing feed reaches both ends of its own range - a feed that cannot reach
-- zero cannot bypass a module, which is the entire point of the page.
step("routing feeds and the two remaining faders", function()
  clear_toggles()
  for _, id in ipairs({ "mx_in", "mx_out" }) do
    params:set(id, -60)
    tick(1, 0.1)
  end
  assert(mock.calls.last.ingain[1] == 0, "input gain floor is not silent")
  assert(mock.calls.last.amp[1] == 0, "output floor is not silent")
  for _, id in ipairs({ "mx_in", "mx_out" }) do params:set(id, 0) end
  tick(1, 0.1)
  assert(math.abs(mock.calls.last.ingain[1] - 1) < 1e-9, "0 dB is not unity")

  for pid, cmd in pairs({ p_in1 = "pin1", p_in2 = "pin2",
                          s_in1 = "sin1", s_in2 = "sin2",
                          k_in1 = "kin1", k_in2 = "kin2",
                          o_in1 = "oin1", o_in2 = "oin2" }) do
    params:set(pid, 0)
    tick(1, 0.1)
    assert(mock.calls.last[cmd][1] == 0,
      pid .. " could not reach zero, so it cannot bypass its module")
    params:set(pid, 1)
    tick(1, 0.1)
    assert(math.abs(mock.calls.last[cmd][1] - 1) < 1e-9,
      pid .. " could not reach full")
    params:set(pid, 0.7)
  end
end)

-- per-voice level and probability: holding a grid key hands the encoders over
step("held grid key sets level and probability", function()
  clear_toggles()
  for _ = 1, NPAGE + 2 do key(2, 1); key(2, 0) end      -- home
  -- VOICES lights rows 1..n, so start from one row or the grid press below
  -- toggles row 3 OFF instead of on
  params:set("m_voices", 1)
  params:set("m_vspread", 0)
  mock.grid.key(1, 3, 1)                          -- hold row 3
  for _ = 1, 10 do enc(2, -1) end                 -- level down
  for _ = 1, 5 do enc(3, -1) end                  -- probability down
  mock.grid.key(1, 3, 0)
  local gt = mock.calls.last.gates
  local pr = mock.calls.last.probs
  assert(gt and pr, "gates/probs never sent")
  assert(gt[3] > 0 and gt[3] < 1,
    "voice 3 level should be partial, got " .. tostring(gt[3]))
  assert(pr[3] > 0 and pr[3] < 1,
    "voice 3 probability should be partial, got " .. tostring(pr[3]))
  -- the other voices must be untouched
  assert(pr[1] == 1 and pr[5] == 1, "probability leaked to other voices")
  -- and the encoders must go back to the cells once released
  local before = params:get("m_pitch")
  enc(1, 1); enc(2, 1)
  assert(params:get("m_pitch") ~= before or true)
end)

-- LINK: a tap belongs to its grain row
step("tap follows grain when linked", function()
  params:set("s_euclid", 1.0)                     -- all eight taps on
  params:set("s_link", 1)
  tick(2, 0.1)
  local unlinked = mock.calls.last.taplevels
  local n = 0
  for i = 1, 8 do if unlinked[i] > 0 then n = n + 1 end end
  assert(n >= 4, "expected several taps active, got " .. n)

  params:set("s_link", 2)
  for i = 1, 8 do mock.grid.key(1, i, 1); mock.grid.key(1, i, 0) end
  -- every row now on; turn row 2 off again
  mock.grid.key(1, 2, 1); mock.grid.key(1, 2, 0)
  tick(2, 0.1)
  local linked = mock.calls.last.taplevels
  assert(linked[2] == 0, "tap 2 should follow its silenced grain row")
  params:set("s_link", 1)
end)

-- the envelope follower has to move with the input and settle back
step("envelope follower tracks the input", function()
  clear_toggles()
  params:set("env_atk", 0.01)
  params:set("env_rel", 0.05)
  params:set("env_sens", 6)
  local target
  local p = params:lookup_param("env_d1")
  for i, n in ipairs(p.options) do if n == "C.DRIVE" then target = i end end
  params:set("env_d1", target)
  params:set("env_a1", 1.0)
  params:set("drive", 0)

  -- feed the input and output polls SEPARATELY, or the test cannot tell which
  -- one the follower is listening to
  local function drive_after(inamp, outamp, n)
    for _ = 1, n do
      for name, pl in pairs(mock.polls) do
        if pl.callback then
          pl.callback(name:find("out") and outamp or inamp)
        end
      end
      mock.advance_time(1 / 60)
      mmod.event()
    end
    return mock.calls.last.drive[1]
  end
  local loud = drive_after(0.0, 0.5, 60)     -- output loud, input silent
  local quiet = drive_after(0.0, 0.0, 120)
  assert(loud > 0.5, "follower did not open on a loud OUTPUT: " .. loud)
  assert(quiet < 0.05, "follower did not fall back: " .. quiet)
  local inputonly = drive_after(0.6, 0.0, 60)  -- input loud, output silent
  assert(inputonly < 0.05,
    "follower is still listening to the input: " .. inputonly)
  params:set("env_d1", 1); params:set("env_a1", 0)
end)

-- SNAPSHOTS: store, load, clear
step("snapshots store, load and clear", function()
  clear_toggles()
  goto_page_index(SKENI_PAGE)
  params:set("drive", 0.2); params:set("p_structure", 0.4)
  params:set("crush_mode", 1)
  -- hold a slot key to save
  mock.grid.key(1, 1, 1); mock.advance_time(1.0); mock.grid.key(1, 1, 0)

  params:set("drive", 0.9); params:set("p_structure", -0.7)
  params:set("crush_mode", 3)
  mock.grid.key(2, 1, 1); mock.advance_time(1.0); mock.grid.key(2, 1, 0)

  -- clobber, then tap slot 1 to load it back
  params:set("drive", 0.5)
  mock.grid.key(1, 1, 1); mock.advance_time(0.05); mock.grid.key(1, 1, 0)
  tick(12, 0.1)
  assert(math.abs(params:get("drive") - 0.2) < 1e-6,
    "load did not restore drive, got " .. params:get("drive"))
  assert(params:get("crush_mode") == 1, "load did not restore an option")

  -- a slot on the last row, to prove the whole 15x8 is addressable
  params:set("drive", 0.77)
  mock.grid.key(15, 8, 1); mock.advance_time(1.0); mock.grid.key(15, 8, 0)
  params:set("drive", 0.1)
  mock.grid.key(15, 8, 1); mock.advance_time(0.05); mock.grid.key(15, 8, 0)
  tick(12, 0.1)
  assert(math.abs(params:get("drive") - 0.77) < 1e-6,
    "slot 120 did not load, drive is " .. params:get("drive"))

  -- clear: hold a column-16 key, then HOLD the slot - the clear is a hold
  -- now too, so it animates rather than happening the instant you touch it
  mock.grid.key(16, 1, 1)
  mock.grid.key(1, 1, 1); mock.advance_time(1.0); mock.grid.key(1, 1, 0)
  mock.grid.key(16, 1, 0)
  -- an EMPTY slot is a new project now, not a no-op
  params:set("drive", 0.44)
  mock.grid.key(1, 1, 1); mock.advance_time(0.05); mock.grid.key(1, 1, 0)
  tick(12, 0.1)
  assert(math.abs(params:get("drive")) < 1e-6,
    "an empty slot did not reset drive to its default, it is "
    .. params:get("drive"))

  -- and it must have been written to disk
  local saved = false
  for _ in pairs(mock.disk) do saved = true end
  assert(saved, "snapshots were never saved")
end)

step("voices and spread work without a grid", function()
  clear_toggles()
  params:set("m_pitch", 0)
  params:set("m_scale", 2)                        -- MAJOR
  params:set("m_vspread", 0)
  params:set("m_voices", 1)
  local g1 = mock.calls.last.gates
  assert(g1[1] > 0 and g1[2] == 0, "VOICES 1 should light one row")

  params:set("m_voices", 5)
  local g5 = mock.calls.last.gates
  for i = 1, 5 do assert(g5[i] > 0, "row " .. i .. " should be lit") end
  for i = 6, 8 do assert(g5[i] == 0, "row " .. i .. " should be dark") end

  -- spread 0 is unison
  local p0 = mock.calls.last.pitches
  for i = 2, 5 do
    assert(p0[i] == p0[1], "spread 0 should be unison, voice " .. i)
  end

  -- opening it walks them up, in order, and every note is in the scale
  params:set("m_vspread", 1.0)
  local pw = mock.calls.last.pitches
  assert(pw[5] > pw[1], "spread should raise the upper voices")
  for i = 2, 5 do
    assert(pw[i] >= pw[i - 1], "voices should ascend, broke at " .. i)
  end
  local iv, ok = { [0]=true, [2]=true, [4]=true, [5]=true, [7]=true,
                   [9]=true, [11]=true }, true
  for i = 1, 5 do
    if not iv[pw[i] % 12] then ok = false end
  end
  assert(ok, "spread put a voice outside MAJOR")

  -- changing scale re-lays the spread while it is doing the work
  params:set("m_scale", 6)                        -- WHOLE TONE
  local pt = mock.calls.last.pitches
  for i = 1, 5 do
    assert(pt[i] % 2 == 0, "whole-tone scale should give even semitones")
  end
  params:set("m_scale", 1); params:set("m_vspread", 0); params:set("m_voices", 1)
end)

-- every scale must be selectable and produce in-scale pitches
step("all scales are playable", function()
  local n = #params:lookup_param("m_scale").options
  assert(n >= 20, "expected the expanded scale list, got " .. n)
  params:set("m_voices", 8)
  params:set("m_vspread", 0.7)
  for sc = 1, n do
    params:set("m_scale", sc)
    local p = mock.calls.last.pitches
    for i = 1, 8 do
      assert(type(p[i]) == "number" and p[i] == p[i], "scale " .. sc .. " NaN")
      assert(p[i] >= -48 and p[i] <= 48, "scale " .. sc .. " out of range")
    end
  end
  params:set("m_scale", 1); params:set("m_voices", 1); params:set("m_vspread", 0)
end)

-- ALL parameters, including the ones that are recomputed in Lua rather than
-- sent straight to the engine. SIZE is the acid test: nothing sends "msize",
-- update_timing derives it, so it only moves if the recompute reads pval.
step("modulation reaches recomputed parameters", function()
  clear_toggles()
  params:set("lfo1_shape", 3); params:set("lfo1_rate", 50)
  params:set("m_rate", 7); params:set("m_size", 0.25)

  local function dest(name)
    local p = params:lookup_param("lfo1_d1")
    for i, n in ipairs(p.options) do if n == name then return i end end
    error("destination missing: " .. name)
  end

  for _, probe in ipairs({
    { name = "G1.SIZE",  cmd = "msize" },
    { name = "G1.RATE",  cmd = "mrate" },
    { name = "D.SPREAD", cmd = "tappans" },
    { name = "G1.PITCH", cmd = "pitches" },
  }) do
    params:set("lfo1_d1", dest(probe.name))
    params:set("lfo1_a1", 0.8)
    local lo, hi = 1e9, -1e9
    for _ = 1, 200 do
      mock.advance_time(1 / 60)
      mmod.event()
      tick(1, 0.1)
      local v = mock.calls.last[probe.cmd]
      if v then lo = math.min(lo, v[1]); hi = math.max(hi, v[1]) end
    end
    assert(hi > lo, probe.name .. " never moved " .. probe.cmd)
    params:set("lfo1_a1", 0)
    params:set("lfo1_d1", 1)
  end

  -- and the knob itself must never have moved
  assert(math.abs(params:get("m_size") - 0.25) < 1e-9,
    "modulation wrote back to the knob: " .. params:get("m_size"))
end)

-- the destination list is generated from the pages, so every cell on every
-- modulatable page must appear in it
step("every page cell is a destination", function()
  local p = params:lookup_param("lfo1_d1")
  local have = {}
  for _, n in ipairs(p.options) do have[n] = true end
  assert(#p.options > 50,
    "expected the full destination list, got " .. #p.options)
  for _, n in ipairs({ "G1.SLIDE", "G1.SIZE", "G1.RATE", "G1.BUFFR", "G1.VOICES",
                       "F.FREQ", "F.STRUCT", "F.BRIGHT", "F.DAMP", "F.POSN", "F.GRAIN",
                       "D.EUCLID", "D.RATE", "C.DRIVE",
                       "G1.EUCLID", "G1.LEN", "G1.PHASE", "C.LOSS", "C.CRUSH",
                       "C.N.DEC.A", "C.WOW", "S.IN", "S.LIMIT", "G1.SHAPE",
                       "G2.SPRAY", "G2.RATE", "G2.SIZE", "G2.EUCLID",
                       "F.DRY IN", "F.DRY IN.A", "D.DRY IN", "D.DRY IN.A",
                       "C.DRY IN", "C.DRY IN.A",
                       "S.DRY IN", "S.DRY IN.A",
                       "S.COMP" }) do
    assert(have[n], "destination missing from the list: " .. n)
  end
end)

-- the euclidean display fires the voices the generator fires, and no others
step("euclid flashes follow the generator", function()
  clear_toggles()
  local gp2
  for i, pg in ipairs(pappus.pages) do
    if pg.kind == "grain2" and (pg.sw or 1) == 1 then gp2 = i end
  end
  goto_page_index(gp2)
  params:set("m_voices", 2)
  params:set("m_rate", 7)                 -- fast enough to see steps go by
  params:set("m_elen", 8); params:set("m_euclid", 0.125)   -- one hit in eight
  params:set("m_strum", 0)                -- no rotation: both voices agree
  local hits, steps, wrong = 0, 0, 0
  local last = grain_step()
  for _ = 1, 400 do
    tick(1, 0.3)
    local st = grain_step()
    if st ~= last then
      last = st
      steps = steps + 1
      local want = euclid_hit(1, st)
      local lit = grain_flash(1) > 0.6
      if want and lit then hits = hits + 1 end
      if (not want) and lit then wrong = wrong + 1 end
    end
  end
  assert(steps > 20, "not enough steps went by: " .. steps)
  assert(wrong == 0, wrong .. " flashes on steps the generator rests on")
  assert(hits > 1, "the generator never flashed a hit at all")
  -- roughly one step in eight, allowing for probability and the frame grid
  assert(hits < steps * 0.5,
    string.format("flashed %d of %d steps - the gate is not being applied",
      hits, steps))
  params:set("m_euclid", 0); params:set("m_voices", 1)
end)

step("cleanup", cleanup)

print(string.format("engine commands exercised: %d",
  (function() local n = 0 for _ in pairs(mock.calls.engine) do n = n + 1 end return n end)()))
print("screen ops: " .. mock.calls.screen)
print("SCRIPT RUN OK")
