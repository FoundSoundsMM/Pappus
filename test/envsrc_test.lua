-- MODNI ENV's SOURCE, and whether it actually listens to what it says.
--
-- The follower is only observable through what it MODULATES, so every check
-- here points it at a parameter and watches that parameter move. Reaching
-- into the follower's own state would test the arithmetic; this tests the
-- wiring, which is the part that was just changed.
--
--   1. LEFT follows the left input and RIGHT the right, separately. This is
--      the claim that would fail silently if both polls still fed one shared
--      accumulator, which is how it worked until now.
--   2. MONO L+R is the MEAN of the two, matching what the granulators do with
--      the same setting - not the louder of them, and not one of them.
--   3. OUT follows the master output and nothing else.
--   4. Choosing a source that is saying nothing gives no modulation at all.

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local mmod = mock.metros[2]
assert(mmod, "no modulation metro")

-- point the follower at COLOUR's DRIVE, hard, and read the modulation off
-- pval - which is what the engine is actually sent
local dp = params:lookup_param("env_d1")
local want
for i, n in ipairs(dp.options) do if n == "C.DRIVE" then want = i end end
assert(want, "C.DRIVE is not a destination")
params:set("env_d1", want)
params:set("env_a1", 1.0)
-- sensitivity of one, NOT four. At four a 0.8 signal drives the follower
-- straight into its ceiling and every case below reads 1.000 - which is a
-- pass for the wrong reason: a saturated follower cannot tell a sum from a
-- pick.
params:set("env_sens", 1)
params:set("env_atk", 0.01)
params:set("env_rel", 0.01)
params:set("drive", 0)

local SRC = { OUT = 1, GS1 = 2, GS2 = 3, SUM = 4, LEFT = 5, RIGHT = 6 }

-- feed a set of polls for a while and report how far DRIVE was pushed
local function drive_under(src, feed)
  params:set("env_src", src)
  -- let whatever was there decay first, or the previous case leaks in
  for _ = 1, 60 do
    mock.advance_time(1 / 60)
    mmod.event()
  end
  local peak = 0
  for _ = 1, 60 do
    for name, v in pairs(feed) do
      local p = mock.polls[name]
      if p and p.callback then p.callback(v) end
    end
    mock.advance_time(1 / 60)
    mmod.event()
    peak = math.max(peak, pval("drive"))
  end
  return peak
end

local L_ONLY = { amp_in_l = 0.8, amp_in_r = 0.0 }
local R_ONLY = { amp_in_l = 0.0, amp_in_r = 0.8 }
local OUT_ONLY = { amp_out_l = 0.8, amp_out_r = 0.8 }

-- 1. the two ends are separate
local l_on_l = drive_under(SRC.LEFT, L_ONLY)
local l_on_r = drive_under(SRC.LEFT, R_ONLY)
local r_on_r = drive_under(SRC.RIGHT, R_ONLY)
local r_on_l = drive_under(SRC.RIGHT, L_ONLY)
print(string.format("  LEFT: L %.3f R %.3f   RIGHT: R %.3f L %.3f",
  l_on_l, l_on_r, r_on_r, r_on_l))

check(l_on_l > 0.3, "SRC LEFT did not follow the left input at all")
check(r_on_r > 0.3, "SRC RIGHT did not follow the right input at all")
check(l_on_r < 0.02,
  "SRC LEFT moved for a signal on the RIGHT input only (" .. l_on_r
  .. "), so the two ends are sharing one reading")
check(r_on_l < 0.02,
  "SRC RIGHT moved for a signal on the LEFT input only (" .. r_on_l .. ")")

-- 2. MONO L+R sums. One channel at 0.8 and the other silent has to give
--    about half what the same signal in both channels gives.
local sum_one = drive_under(SRC.SUM, L_ONLY)
local sum_both = drive_under(SRC.SUM, { amp_in_l = 0.8, amp_in_r = 0.8 })
print(string.format("  MONO L+R: one side %.3f, both sides %.3f",
  sum_one, sum_both))
check(sum_both > sum_one * 1.6,
  string.format("MONO L+R gave %.3f for one channel and %.3f for both - it "
    .. "is picking a channel rather than summing them", sum_one, sum_both))
check(sum_one > 0.1, "MONO L+R ignored a signal on one channel entirely")

-- 3. OUT follows the output, and the input does not reach it
local out_on_out = drive_under(SRC.OUT, OUT_ONLY)
local out_on_in = drive_under(SRC.OUT, L_ONLY)
check(out_on_out > 0.3, "SRC OUT did not follow the master output")
check(out_on_in < 0.02,
  "SRC OUT moved for a signal that only reached the input (" .. out_on_in
  .. ")")

-- ...and the input sources do not follow the output either
local left_on_out = drive_under(SRC.LEFT, OUT_ONLY)
check(left_on_out < 0.02,
  "SRC LEFT moved for the master output (" .. left_on_out .. ")")

-- 4. a source with nothing on it does nothing. GS1 comes off a box meter,
--    and the CroneEngine stub the harness uses has addPoll as a no-op, so
--    that poll never fires here - which is exactly the "chose a source that
--    is saying nothing" case.
local gs1 = drive_under(SRC.GS1, L_ONLY)
check(gs1 < 0.02,
  "SRC GS1 moved (" .. gs1 .. ") while listening to a granulator meter that "
  .. "never reported anything")

params:set("env_a1", 0); params:set("env_d1", 1)

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("ENV SRC TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("ENV SRC TEST OK")
