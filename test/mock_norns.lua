-- A small mock of the norns Lua API, enough to actually run a script's
-- init / metro / redraw / enc / key / grid handlers off-device.
--
-- The engine table is populated from the real Engine_*.sc addCommand list, so
-- a script calling a command the engine does not declare fails here loudly
-- instead of on the hardware as a bare "error: init".

local M = {}

-- ---------------------------------------------------------------- controlspec
local ControlSpec = {}
ControlSpec.__index = ControlSpec

function ControlSpec.new(min, max, warp, step, default, units)
  local s = setmetatable({}, ControlSpec)
  s.minval, s.maxval = min, max
  s.warp = warp or "lin"
  s.step = step or 0
  s.default = default or min
  s.units = units or ""
  if s.warp == "exp" and (min <= 0 or max <= 0) then
    error("exp controlspec needs positive bounds")
  end
  return s
end

function ControlSpec:map(x)
  x = math.max(0, math.min(1, x))
  if self.warp == "exp" then
    return self.minval * ((self.maxval / self.minval) ^ x)
  end
  return self.minval + (x * (self.maxval - self.minval))
end

function ControlSpec:unmap(v)
  if self.warp == "exp" then
    return math.log(v / self.minval) / math.log(self.maxval / self.minval)
  end
  return (v - self.minval) / (self.maxval - self.minval)
end

-- --------------------------------------------------------------------- params
local Params = {}
Params.__index = Params

local function new_params()
  return setmetatable({ list = {}, byid = {}, order = {} }, Params)
end

function Params:add_separator(id, name) end

function Params:add_control(id, name, spec)
  assert(not self.byid[id], "duplicate param id: " .. id)
  local p = { id = id, name = name, controlspec = spec, value = spec.default,
              action = function() end }
  self.byid[id] = p
  table.insert(self.order, id)
end

function Params:add_option(id, name, options, default)
  assert(not self.byid[id], "duplicate param id: " .. id)
  local p = { id = id, name = name, options = options, value = default or 1,
              action = function() end }
  self.byid[id] = p
  table.insert(self.order, id)
end

function Params:add_number(id, name, min, max, default)
  assert(not self.byid[id], "duplicate param id: " .. id)
  self.byid[id] = { id = id, name = name, min = min, max = max,
                    value = default or min, action = function() end }
  table.insert(self.order, id)
end

local function is_number_param(p)
  return p.options == nil and p.controlspec == nil
end

function Params:lookup_param(id)
  local p = self.byid[id]
  if not p then error("no such param: " .. tostring(id), 2) end
  return p
end

function Params:set_action(id, fn) self:lookup_param(id).action = fn end

function Params:get(id) return self:lookup_param(id).value end

function Params:set(id, v, silent)
  local p = self:lookup_param(id)
  if p.options then
    v = math.max(1, math.min(#p.options, math.floor(v + 0.5)))
  elseif p.controlspec then
    v = math.max(p.controlspec.minval, math.min(p.controlspec.maxval, v))
    -- ...and then through the same round trip norns does. A control param
    -- stores its position on the knob, not the number: set() unmaps and get()
    -- maps back, and on a warped spec that is not an identity. Storing the
    -- number verbatim made the mock kinder than the hardware, which is the
    -- wrong direction for a test to be wrong in.
    v = p.controlspec:map(p.controlspec:unmap(v))
  else
    -- norns rounds and clamps add_number params; so must the mock, or a
    -- fractional voice count sails straight through
    v = math.max(p.min, math.min(p.max, math.floor(v + 0.5)))
  end
  p.value = v
  if not silent then p.action(v) end
end

function Params:get_raw(id)
  local p = self:lookup_param(id)
  if not p.controlspec then
    error("get_raw on a non-control param: " .. id, 2)
  end
  return p.controlspec:unmap(p.value)
end

function Params:set_raw(id, x, silent)
  local p = self:lookup_param(id)
  if not p.controlspec then
    error("set_raw on a non-control param: " .. id, 2)
  end
  self:set(id, p.controlspec:map(x), silent)
end

function Params:delta(id, d)
  local p = self:lookup_param(id)
  if p.options then
    self:set(id, math.max(1, math.min(#p.options, p.value + d)))
  elseif is_number_param(p) then
    self:set(id, p.value + d)
  else
    self:set_raw(id, self:get_raw(id) + (d * 0.01))
  end
end

function Params:string(id)
  local p = self:lookup_param(id)
  if p.options then return p.options[p.value] end
  if is_number_param(p) then return tostring(p.value) end
  return string.format("%.2f%s", p.value, p.controlspec.units or "")
end

function Params:bang()
  for _, id in ipairs(self.order) do
    local p = self.byid[id]
    p.action(p.value)
  end
end

-- --------------------------------------------------------------------- engine
local function engine_commands_from_sc(path)
  local names = {}
  local f = io.open(path, "r")
  if not f then error("cannot read engine file: " .. path) end
  for line in f:lines() do
    local n = line:match('addCommand%("([%w_]+)"')
    if n then names[#names + 1] = n end
  end
  f:close()
  return names
end

-- ----------------------------------------------------------------- install
function M.install(engine_sc_path)
  local calls = { engine = {}, last = {}, screen = 0 }

  _G.controlspec = { new = ControlSpec.new, def = ControlSpec.new }
  _G.params = new_params()
  -- norns adds these itself, before any script param. The script reads both:
  -- clock_source decides whether the transport owns us, clock_tempo is the
  -- internal BPM.
  _G.params:add_option("clock_source", "clock source",
    { "internal", "midi", "link", "crow" }, 1)
  _G.params:add_control("clock_tempo", "tempo",
    ControlSpec.new(20, 300, "lin", 0.1, 120, "bpm"))

  local eng = { name = nil }
  for _, n in ipairs(engine_commands_from_sc(engine_sc_path)) do
    eng[n] = function(...)
      calls.engine[n] = (calls.engine[n] or 0) + 1
      calls.last[n] = { ... }
    end
  end
  -- Anything the script calls that the engine does not declare must blow up,
  -- because on hardware it is a nil-call inside init.
  _G.engine = setmetatable(eng, {
    __index = function(_, k)
      error("engine command not declared in the .sc file: engine." ..
            tostring(k), 2)
    end,
    __newindex = function(t, k, v) rawset(t, k, v) end,
  })

  _G.util = {
    clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end,
    round = function(v, q) q = q or 1; return math.floor(v / q + 0.5) * q end,
    time = function() return M.now end,
    linlin = function(a, b, c, d, v)
      return c + (v - a) / (b - a) * (d - c)
    end,
    -- no audio/ folder off-device, so the noise-loop scan finds nothing and
    -- NOISE falls back to just WHITE/PINK/DUST
    scandir = function() return {} end,
  }
  M.now = 1000.0
  -- scan_noise_loops() builds a path off this before it ever gets to
  -- scandir, so it has to exist even though scandir ignores it
  _G._path = { code = "/tmp/mock-pappus-code/" }

  -- Screen ops are recorded verbatim so a rasteriser can draw exactly what
  -- norns would draw, rather than a re-implementation of the same maths.
  -- norns draws text through cairo, which requires valid UTF-8. A raw
  -- high byte - string.format("%c", 177) was the one that did it - makes
  -- cairo error, and once its context is poisoned the screen stays BLANK on
  -- every page while sound and grid carry on normally. The file itself stays
  -- ASCII because the bad byte is produced at runtime, so an encoding check on
  -- the source cannot catch it. This can.
  local function check_text(s)
    s = tostring(s)
    local i = 1
    while i <= #s do
      local b = s:byte(i)
      if b < 0x80 then
        i = i + 1
      else
        local n = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2)
        if not n then
          error(string.format(
            "screen.text got a byte that is not valid UTF-8 (0x%02X) in %q "
            .. "- cairo will reject this and blank the screen", b, s), 3)
        end
        for k = 1, n - 1 do
          local c = s:byte(i + k)
          if not c or c < 0x80 or c > 0xBF then
            error(string.format(
              "screen.text got truncated UTF-8 (0x%02X) in %q", b, s), 3)
          end
        end
        i = i + n
      end
    end
  end

  local scr = {}
  M.ops = {}
  M.recording = false
  for _, n in ipairs({ "clear", "aa", "line_width", "level", "move", "text",
                       "text_right", "rect", "fill", "stroke", "line",
                       "update", "font_size", "circle", "close", "pixel",
                       "translate" }) do
    scr[n] = function(...)
      if n == "text" or n == "text_right" then check_text((...)) end
      calls.screen = calls.screen + 1
      if M.recording then
        M.ops[#M.ops + 1] = { op = n, args = { ... } }
      end
    end
  end
  -- norns measures the real font; the mock approximates it so layout code that
  -- depends on text width can be exercised. 04B_03 at size 8 is close to 4 px
  -- per character plus the inter-glyph gap.
  -- ...and the size matters now that the interface uses more than one. norns'
  -- bitmap font scales linearly, so the approximation scales with it.
  local fsize = 8
  local base_font_size = scr.font_size
  scr.font_size = function(n) fsize = tonumber(n) or 8; return base_font_size(n) end
  scr.text_extents = function(s)
    calls.screen = calls.screen + 1
    return #tostring(s) * 4.6 * (fsize / 8)
  end
  scr.font_face = function() calls.screen = calls.screen + 1 end
  _G.screen = scr

  -- Scene persistence writes through tab.save/tab.load into norns.state.data.
  -- The mock keeps it in memory: the point is to exercise the save/load path,
  -- not to litter the test run with files.
  M.disk = {}
  _G.tab = {
    save = function(t, path) M.disk[path] = t end,
    load = function(path) return M.disk[path] end,
    count = function(t)
      local n = 0
      for _ in pairs(t or {}) do n = n + 1 end
      return n
    end,
  }
  _G.norns = _G.norns or {}
  _G.norns.state = { data = "/tmp/mock-pappus-data/", name = "pappus" }

  local polls = {}
  _G.poll = {
    set = function(name, fn)
      polls[name] = polls[name] or { name = name, time = 0.1 }
      if fn then polls[name].callback = fn end
      polls[name].start = function() end
      polls[name].stop = function() end
      return polls[name]
    end,
  }
  M.polls = polls

  local metros = {}
  _G.metro = {
    init = function()
      local m = { time = 1, event = nil }
      m.start = function() m.running = true end
      m.stop = function() m.running = false end
      table.insert(metros, m)
      return m
    end,
  }
  M.metros = metros

  local gd = { cols = 16, rows = 8, device = {} }
  gd.all = function() end
  gd.led = function(_, x, y, l)
    assert(x >= 1 and x <= gd.cols, "grid led x out of range: " .. tostring(x))
    assert(y >= 1 and y <= gd.rows, "grid led y out of range: " .. tostring(y))
    assert(l >= 0 and l <= 15, "grid led level out of range: " .. tostring(l))
  end
  gd.refresh = function() end
  _G.grid = { connect = function() return gd end }
  M.grid = gd
  M.clocks = {}

  _G.clock = {
    get_tempo = function()
      local ok, v = pcall(function() return params:get("clock_tempo") end)
      return (ok and type(v) == "number") and v or 120
    end,
    -- Actually RUN the coroutine. It used to return an id and do nothing,
    -- which meant anything scheduled with clock.run - the snapshot load, for
    -- one - silently never happened and the test still passed.
    run = function(f, ...)
      local co = coroutine.create(f)
      local ok, err = coroutine.resume(co, ...)
      if not ok then error(err, 0) end
      M.clocks[#M.clocks + 1] = co
      return #M.clocks
    end,
    -- sleep runs STRAIGHT THROUGH and sync YIELDS, and the asymmetry is
    -- deliberate. A coroutine that sleeps is doing a finite job - the
    -- snapshot morph's fifty steps - and tests want the result, not fifty
    -- resumes. A coroutine that syncs is waiting for a musical boundary and
    -- is usually inside `while true`, so running it straight through is an
    -- infinite loop that hangs the test runner. advance_time resumes them.
    sleep = function() end,
    sync = function() coroutine.yield() end,
    cancel = function() end,
    -- norns calls these on MIDI transport start/stop; scripts assign to them
    transport = {},
  }

  _G.audio = { level_monitor = function() end }

  -- MIDI. A script assigns .event on a connected device; the test drives it
  -- by calling M.midi.send{...}, which is the shape norns hands over.
  local mdev = { name = "mock", port = 1, event = nil }
  mdev.send = function(msg)
    if mdev.event then mdev.event(_G.midi.to_data(msg)) end
  end
  _G.midi = {
    connect = function(n) mdev.port = n or 1; return mdev end,
    to_msg = function(d)
      local t = d[1] & 0xf0
      local msg = { ch = (d[1] & 0x0f) + 1 }
      if t == 0x90 then
        msg.type = (d[3] or 0) > 0 and "note_on" or "note_off"
        msg.note, msg.vel = d[2], d[3]
      elseif t == 0x80 then
        msg.type, msg.note, msg.vel = "note_off", d[2], d[3]
      else
        msg.type = "other"
      end
      return msg
    end,
    to_data = function(m)
      local ch = (m.ch or 1) - 1
      if m.type == "note_on" then
        return { 0x90 | ch, m.note, m.vel or 100 }
      elseif m.type == "note_off" then
        return { 0x80 | ch, m.note, 0 }
      end
      return { 0xb0 | ch, 1, 0 }
    end,
  }
  M.midi = mdev

  M.calls = calls
  return calls
end

function M.advance_time(dt)
  M.now = M.now + dt
  -- anything parked on clock.sync gets one resume per tick of time
  for i = #M.clocks, 1, -1 do
    local co = M.clocks[i]
    if coroutine.status(co) == "dead" then
      table.remove(M.clocks, i)
    else
      local ok, err = coroutine.resume(co)
      if not ok then error(err, 0) end
    end
  end
end

return M
