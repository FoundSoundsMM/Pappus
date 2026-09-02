-- Loading a SAMPLE into a granulator's buffer instead of recording one.
--
-- The three things the load has to move - SOURCE off, SOS up, BUFFR to the
-- sample's length - are the whole feature: get any of them wrong and the file
-- lands in the buffer and you hear silence, or you hear it for one pass and
-- then the input records over it. So they are what this checks, along with
-- the sample-rate correction, which is the part nobody notices until a 44.1k
-- file comes back a semitone and a half sharp.

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end
local function near(a, b, tol, msg)
  check(math.abs(a - b) <= (tol or 1e-6),
    string.format("%s: %.6f vs %.6f", msg, a, b))
end

-- ------------------------------------------------------------------ fixtures
-- Real files, written here rather than checked in: the header walk is the
-- thing under test and a hand-built header is the only way to be sure which
-- fields it is reading.
local DIR = "/tmp/pappus-sample-test"
os.execute("mkdir -p " .. DIR)

local function le(v, n)
  local out = {}
  for _ = 1, n do out[#out + 1] = string.char(v % 256); v = math.floor(v / 256) end
  return table.concat(out)
end

local function write_wav(path, ch, rate, bits, frames, extra_chunk)
  local bytes = frames * ch * (bits // 8)
  local pre = extra_chunk or ""
  local f = assert(io.open(path, "wb"))
  local fmt = "fmt " .. le(16, 4) .. le(1, 2) .. le(ch, 2) .. le(rate, 4)
    .. le(rate * ch * (bits // 8), 4) .. le(ch * (bits // 8), 2) .. le(bits, 2)
  local data = "data" .. le(bytes, 4) .. string.rep("\0", bytes)
  local body = pre .. fmt .. data
  f:write("RIFF" .. le(4 + #body, 4) .. "WAVE" .. body)
  f:close()
  return path
end

-- 48k stereo, two seconds
local S48 = write_wav(DIR .. "/take48.wav", 2, 48000, 16, 96000)
-- 44.1k mono, one second, with a LIST chunk in front of fmt so the walk has
-- to skip something to find it - which is what a file out of any editor
-- actually looks like
local S441 = write_wav(DIR .. "/take441.wav", 1, 44100, 24, 44100,
  "LIST" .. le(10, 4) .. "INFOhello\0")
-- an odd-sized chunk, so the word-alignment pad is exercised
local SODD = write_wav(DIR .. "/odd.wav", 2, 48000, 16, 24000,
  "LIST" .. le(5, 4) .. "INFOx" .. "\0")

-- ---------------------------------------------------------------- wav_info
do
  local ch, fr, rate = wav_info(S48)
  check(ch == 2, "48k stereo: channels " .. tostring(ch))
  check(fr == 96000, "48k stereo: frames " .. tostring(fr))
  check(rate == 48000, "48k stereo: rate " .. tostring(rate))

  ch, fr, rate = wav_info(S441)
  check(ch == 1, "44.1k mono: channels " .. tostring(ch))
  check(fr == 44100, "44.1k mono: frames " .. tostring(fr))
  check(rate == 44100, "44.1k mono: rate " .. tostring(rate))

  ch, fr = wav_info(SODD)
  check(ch == 2 and fr == 24000,
    "odd-sized chunk: " .. tostring(ch) .. "ch " .. tostring(fr) .. "fr")

  check(wav_info(DIR .. "/nope.wav") == nil, "missing file did not return nil")
  local junk = DIR .. "/junk.wav"
  local f = assert(io.open(junk, "wb")); f:write("not a wav at all"); f:close()
  check(wav_info(junk) == nil, "non-wav did not return nil")
end

-- ------------------------------------------------------------------- loading
do
  params:set("m_src", 2)                -- recording from the input
  params:set("m_sos", 0)
  params:set("m_buflen", 8)
  mock.calls.engine.bufload = nil

  check(sample_load(1, S48), "load returned false")
  check(mock.calls.engine.bufload == 1, "engine.bufload was not called")
  check(mock.calls.last.bufload[1] == 1
    and mock.calls.last.bufload[2] == S48, "bufload got the wrong arguments")

  -- the three that have to move
  check(params:get("m_src") == 1, "SOURCE was not turned off")
  near(params:get("m_sos"), 1, 1e-6, "SOS was not turned up")
  near(params:get("m_buflen"), 2.0, 0.01, "BUFFR is not the sample's length")

  -- ...and the header says so
  check(src_label(1, 1) == "TAKE48",
    "the source label does not name the sample: " .. src_label(1, 1))
  check(src_label(1, 2) == "NO INPUT",
    "swarm 2 picked up swarm 1's sample")

  -- a 48k file needs no correction at all
  near(sample_semi(1), 0, 1e-9, "48k file was given a pitch offset")
end

-- ------------------------------------------------------- the rate correction
do
  params:set("m_pitch", 0)
  mock.calls.last.pitches2 = nil
  check(sample_load(2, S441), "44.1k load returned false")
  -- 44100/48000 is 0.91875, which is 1.47 semitones down
  near(sample_semi(2), 12 * math.log(44100 / 48000, 2), 1e-9,
    "wrong semitone correction")
  check(sample_semi(2) < -1.4 and sample_semi(2) > -1.5,
    "correction is not about a semitone and a half: " .. sample_semi(2))
  local p = mock.calls.last.pitches2
  check(p ~= nil, "swarm 2's pitches were not resent after the load")
  if p then
    -- every voice carries it, whether it is sounding or not
    for i = 1, 8 do
      check(math.abs(p[i] % 1) > 0.4,
        string.format("voice %d is still on a whole semitone (%.4f)", i, p[i]))
    end
  end
  near(params:get("n_buflen"), 2.0, 0.01,
    "a one second file did not clamp BUFFR to the minimum")
end

-- --------------------------------------------------------------------- clear
do
  mock.calls.engine.bufwipe = nil
  sample_clear(1)
  check(mock.calls.engine.bufwipe == 1, "engine.bufwipe was not called")
  check(mock.calls.last.bufwipe[1] == 1, "bufwipe got the wrong granulator")
  near(sample_semi(1), 0, 1e-9, "the correction survived the clear")
  check(src_label(1, 1) == "NO INPUT", "the sample name survived the clear")
  near(params:get("m_sos"), 0, 1e-6, "SOS was not handed back")
end

-- Choosing a live input drops the sample identity: from there on what is in
-- the buffer is a recording, and reporting a pitch correction for it would
-- detune the whole instrument.
do
  check(sample_load(1, S441), "reload returned false")
  check(sample_semi(1) ~= 0, "reload did not set a correction")
  params:set("m_src", 2)
  near(sample_semi(1), 0, 1e-9, "the correction survived switching to STEREO")
  check(src_label(1, 1) == "NO INPUT" or params:get("m_src") ~= 1,
    "the sample name survived switching to STEREO")
end

-- A directory, an empty string and a dash all mean "nothing chosen". The file
-- param's DEFAULT is a directory and params:bang() fires it at startup.
do
  mock.calls.engine.bufload = nil
  params:set("m_sample", _path.audio)
  params:set("m_sample", "")
  params:set("m_sample", "-")
  check(mock.calls.engine.bufload == nil,
    "a folder or an empty path was treated as a file")
end

-- Picking a real file through the param does everything sample_load does.
do
  mock.calls.engine.bufload = nil
  params:set("m_src", 2)
  params:set("m_sample", S48)
  check(mock.calls.engine.bufload == 1, "the file param did not load")
  check(params:get("m_src") == 1, "the file param did not turn SOURCE off")
end

-- ---------------------------------------------------------- CAN IT RECORD?
--
-- The regression this exists for: loading a sample pinned SOS to the top and
-- never gave it back, and SOS at the top is the engine's FREEZE - the write
-- gain is `((1 - sos) * 4).clip(0, 1)`, which is exactly zero there. So after
-- any sample load, turning SRC back to a live input armed an input that the
-- granulator was still frozen against, and nothing recorded. Silently, with
-- nothing on screen to say why.
--
-- The engine takes max(SOS, LOCK), so "is this granulator able to record" is
-- that max being under one, and it is checked from the values the engine was
-- actually sent rather than from the params.
local function recording(w)
  local L = mock.calls.last
  local sos = L[(w == 1) and "msos" or "nsos"]
  local lock = L[(w == 1) and "mlock" or "nlock"]
  local src = L[(w == 1) and "msrc" or "nsrc"]
  local held = math.max(sos and sos[1] or 0, lock and lock[1] or 0)
  return (src and src[1] or 1) > 1 and held < 1
end

do
  params:set("m_src", 2)
  params:set("m_sos", 0.35)
  check(recording(1), "not recording before the load - bad starting state")

  check(sample_load(1, S48), "load returned false")
  check(not recording(1), "the loaded sample is not being held")
  check(params:get("m_lock") == 2, "LOCK is not on, so the freeze is invisible")

  -- THE WAY BACK, as the README describes it
  params:set("m_src", 2)
  check(recording(1),
    "SRC back to STEREO left the granulator frozen - it cannot record")
  near(params:get("m_sos"), 0.35, 1e-6, "SOS was not handed back")
  check(params:get("m_lock") == 1, "LOCK was not released")
end

-- ...and the other way back: clearing the sample
do
  params:set("m_sos", 0.5)
  params:set("m_src", 2)
  check(sample_load(1, S48), "second load returned false")
  sample_clear(1)
  near(params:get("m_sos"), 0.5, 1e-6, "clear did not hand SOS back")
  check(params:get("m_lock") == 1, "clear did not release LOCK")
  params:set("m_src", 2)
  check(recording(1), "cleared, armed, and still cannot record")
end

-- Loading a SECOND sample on top of a first must not learn 1.0 as "where SOS
-- was" - the number to keep is the one from before any of it started.
do
  params:set("m_src", 2)
  params:set("m_sos", 0.22)
  check(sample_load(1, S48), "load A returned false")
  check(sample_load(1, S441), "load B returned false")
  params:set("m_src", 2)
  near(params:get("m_sos"), 0.22, 1e-6,
    "a second load overwrote the remembered SOS")
end

-- A SNAPSHOT carries the sample identity, because the audio alone does not.
-- The wav a snapshot writes is the buffer at the server's rate, so the frames
-- come back exactly as they went in - and so does the correction they need.
do
  params:set("m_src", 2)
  check(sample_load(1, S441), "load for the snapshot returned false")
  local semi = sample_semi(1)
  check(semi ~= 0, "no correction to carry")
  snap_store(1)
  -- something else entirely in the buffer
  sample_clear(1)
  params:set("m_src", 2)
  near(sample_semi(1), 0, 1e-9, "clear did not drop the correction")
  -- ...and back
  snap_recall(1)
  for _ = 1, 200 do mock.advance_time(1 / 25) end
  near(sample_semi(1), semi, 1e-9,
    "the snapshot did not restore the sample-rate correction")
  check(src_label(1, 1) == "TAKE441",
    "the snapshot did not restore the sample name: " .. src_label(1, 1))
end

if #fails > 0 then
  for _, m in ipairs(fails) do print("  FAIL " .. m) end
  error(#fails .. " sample failures")
end
print("SAMPLE TEST OK")
