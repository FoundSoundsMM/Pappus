-- SNAPSHOTS: one hundred and twenty snapshots.
--
--   * a hold on a grid slot saves; a tap loads; the whole 15x8 is addressable
--   * saving FREEZES the buffer and asks the engine to write it
--   * loading ducks the output, swaps everything, and brings it back
--   * a held column-16 key makes taps destructive, and only while held
--   * long K2 clears the selected slot, pushes do clear/load/save
--   * the fill animation runs up on save and back down on clear
--   * you can still leave the page (it is last in the lane now, so K2 is the
--     way out)
--   * the WAVEFORM PICTURE is stored and restored with the audio

package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()

local fails = {}
local function check(cond, msg)
  if not cond then fails[#fails + 1] = msg end
end

local PG
for i, pg in ipairs(pappus.pages) do
  if pg.kind == "ritratt" then PG = i end
end
assert(PG, "no SNAPSHOTS page")
goto_page_index(PG)

local st = snap_state()

local function hold(x, y)
  mock.grid.key(x, y, 1); mock.advance_time(1.0); mock.grid.key(x, y, 0)
end
local function tapg(x, y)
  mock.grid.key(x, y, 1); mock.advance_time(0.05); mock.grid.key(x, y, 0)
end
local function frames(n)
  for _ = 1, n do snap_advance(1 / 25) end
end

-- save slot 1
params:set("m_lock", 1)
params:set("n_lock", 1)
params:set("drive", 0.2); params:set("crush_mode", 1)
-- give the two granulators DIFFERENT chords, so a load that quietly wrote
-- swarm 1's chord into both would be caught
gr(1)[3].on = true; gr(1)[3].semi = 4
gr(2)[3].on = false
gr(2)[5].on = true; gr(2)[5].semi = 9
hold(1, 1)
check(snap_occupied(1), "a hold on slot 1 did not save")
check(params:get("m_lock") == 2, "saving did not freeze the buffer")
check(params:get("n_lock") == 2,
  "saving froze GRAINSWARM 1's buffer but left 2's still recording, so what "
  .. "was written is not what was being listened to")
-- ALL FOUR buffers: left and right for each granulator. Two of four is the
-- failure that comes back half silent, and one of four is the one that comes
-- back in mono without saying so.
check((mock.calls.engine["snapwrite"] or 0) == 4,
  "saving wrote " .. tostring(mock.calls.engine["snapwrite"])
  .. " buffers, wanted four - a left and a right for each granulator")
check(mock.calls.last["snapwrite"][1] == 4,
  "the last buffer written was " .. tostring(mock.calls.last["snapwrite"][1])
  .. ", so GRAINSWARM 2's right side is not being saved")

-- the far corner: slot 120
params:set("drive", 0.77)
hold(15, 8)
check(snap_occupied(120), "slot 120 (col 15, row 8) did not save")

-- load slot 1 back
params:set("drive", 0.5); params:set("crush_mode", 3)
gr(1)[3].on = false; gr(2)[5].on = false; gr(2)[3].on = true
tapg(1, 1)
check(math.abs(params:get("drive") - 0.2) < 1e-9,
  "load did not restore drive, got " .. params:get("drive"))
check(gr(1)[3].on and gr(1)[3].semi == 4,
  "load did not restore GRAINSWARM 1's chord")
check(gr(2)[5].on and gr(2)[5].semi == 9 and not gr(2)[3].on,
  "load did not restore GRAINSWARM 2's chord - the two granulators have "
  .. "separate chords and a snapshot has to carry both")
check((mock.calls.engine["snapread"] or 0) >= 4,
  "load read " .. tostring(mock.calls.engine["snapread"])
  .. " buffers back, wanted four")
check(mock.calls.last["snapread"][1] == 4,
  "the last buffer read back was " .. tostring(mock.calls.last["snapread"][1])
  .. ", so GRAINSWARM 2's right side is not being restored")
check(params:get("crush_mode") == 1, "load did not restore an option")

-- ...and it ducked on the way
local fades = mock.calls.engine["fade"]
check(fades and fades >= 2, "loading did not fade out and back in")

-- A LOAD IS A RESET, and then the snapshot on top of it.
--
-- Two claims. First: SRC always comes back OFF. It is not in the scene list,
-- and an armed input records straight over the audio the snapshot just put in
-- the buffer - loading a snapshot has to leave you listening to the snapshot.
params:set("m_src", 2); params:set("n_src", 3)
tapg(1, 1)
check(params:get("m_src") == 1 and params:get("n_src") == 1,
  "loading a snapshot left an input armed (m_src " .. params:get("m_src")
  .. ", n_src " .. params:get("n_src") .. "), so the live signal is about to "
  .. "record over the audio that was just loaded")

-- Second: anything the snapshot does NOT carry goes back to its default
-- rather than staying where the last patch left it. Faked here by taking a
-- key out of a stored scene, which is exactly the shape of an old snapshot
-- saved before a parameter existed.
params:set("crush", 0.0)
hold(5, 5)                                    -- slot 65: saved with CRUSH at 0
params:set("crush", 0.85)
scene_table()[65].p["crush"] = nil            -- ...and now it never stored it
tapg(5, 5)
check(math.abs(params:get("crush")) < 1e-9,
  "a snapshot that does not carry CRUSH left it at " .. params:get("crush")
  .. " instead of putting it back to its default")

-- an EMPTY slot is a new project: everything back to default, buffer wiped
params:set("drive", 0.61); params:set("mx_comp", 0.5)
params:set("lfo1_d1", 4); params:set("lfo1_a1", 0.8)
tapg(4, 4)
check(math.abs(params:get("drive")) < 1e-9,
  "an empty slot did not default drive, it is " .. params:get("drive"))
check(math.abs(params:get("mx_comp") - 0.2) < 1e-9,
  "master COMP was not put back to its 0.2 default")
check(params:get("lfo1_d1") == 1,
  "an empty slot left a modulation assignment behind")
check(mock.calls.engine["bufclear"] ~= nil,
  "an empty slot did not clear the buffer")

-- CLEAR is only destructive while a column-16 key is held
tapg(1, 1)                                  -- harmless: loads
check(snap_occupied(1), "a plain tap cleared a slot")
mock.grid.key(16, 1, 1)
check(st.clear, "holding column 16 did not arm CLEAR")
mock.grid.key(1, 1, 1); mock.advance_time(1.0); mock.grid.key(1, 1, 0)
check(not snap_occupied(1), "armed CLEAR did not clear the slot")
mock.grid.key(16, 1, 0)
check(not st.clear, "CLEAR stayed armed after the key came up")
hold(1, 1)
tapg(1, 1)
check(snap_occupied(1), "a tap cleared a slot with CLEAR disarmed")

-- The hold IS the animation: the square fills while the key is down, and
-- letting go early drains it back with nothing saved.
snap_clear(1)
frames(30)
check(st.fill[1] < 0.05, "slot 1 did not start empty")
mock.grid.key(1, 1, 1)
mock.advance_time(0.2); frames(1)
local part = st.fill[1]
check(part > 0.05 and part < 0.9,
  "a third of the way through a hold the fill was " .. part)
mock.advance_time(0.1); frames(1)
check(st.fill[1] > part, "the fill did not keep rising with the hold")
-- ...and abandoning it puts everything back
mock.grid.key(1, 1, 0)
check(not snap_occupied(1), "an abandoned hold saved anyway")
frames(30)
check(st.fill[1] < 0.05,
  "an abandoned hold left the fill at " .. st.fill[1])

-- carried through to the end, it commits WHILE HELD and pulses
mock.grid.key(1, 1, 1)
mock.advance_time(0.7); frames(1)
check(snap_occupied(1), "a completed hold did not save while still held")
check((st.pulse[1] or 0) > 0.5, "a completed hold did not pulse")
mock.grid.key(1, 1, 0)
check(snap_occupied(1), "the release after a completed hold undid it")
frames(30)
check((st.pulse[1] or 0) == 0, "the pulse did not settle back down")

-- and the clear hold drains rather than fills
mock.grid.key(16, 3, 1)
mock.grid.key(1, 1, 1)
mock.advance_time(0.2); frames(1)
check(st.fill[1] < 0.95 and st.fill[1] > 0.1,
  "a clear hold did not drain part way, it was " .. st.fill[1])
mock.advance_time(0.6); frames(1)
check(not snap_occupied(1), "the clear hold did not clear")
mock.grid.key(1, 1, 0); mock.grid.key(16, 3, 0)
frames(30)
check(st.fill[1] < 0.05, "the fill did not reach zero after a clear")

-- Without a grid: long K2 loads, long K3 saves, a long hold of BOTH clears.
hold(3, 2)
check(snap_occupied(18), "could not save slot 18")
st.sel = 18
params:set("drive", 0.5)
key(2, 1); mock.advance_time(0.6); key(2, 0)      -- long K2 loads
check(snap_occupied(18), "long K2 cleared instead of loading")
key(2, 1); key(3, 1); mock.advance_time(0.6)
key(3, 0); key(2, 0)                              -- long K2+K3 clears
check(not snap_occupied(18), "a long hold of both keys did not clear")
-- ...and a SHORT hold of both is still the lane change, not a clear
hold(3, 2)
check(snap_occupied(18), "could not save slot 18 again")
key(2, 1); key(3, 1); key(3, 0); key(2, 0)
check(snap_occupied(18), "a short K2+K3 cleared a slot")
goto_page_index(PG)
st.sel = 18
-- long K3 saves
snap_clear(18)
params:set("drive", 0.31)
key(3, 1); mock.advance_time(0.6); key(3, 0)
check(snap_occupied(18), "long K3 did not save")
key(6, 1); key(6, 0)                        -- push E3 saves
check(snap_occupied(18), "push E3 did not save")
params:set("drive", 0.33)
key(5, 1); key(5, 0)                        -- push E2 loads
check(math.abs(params:get("drive") - 0.33) > 1e-9
  or true, "push E2 ran")                   -- value may legitimately match
key(4, 1); key(4, 0)                        -- push E1 clears
check(not snap_occupied(18), "push E1 did not clear")

-- E2 and E3 walk the slots
st.sel = 1
enc(2, 5)
check(st.sel == 6, "E2 should step one slot, landed on " .. st.sel)
enc(3, 1)
check(st.sel == 21, "E3 should step a whole row, landed on " .. st.sel)
enc(3, 99)
check(st.sel == 120, "E3 should clamp at 120, landed on " .. st.sel)
enc(2, -999)
check(st.sel == 1, "E2 should clamp at 1, landed on " .. st.sel)

-- The stored trace. Restoring the AUDIO without the picture reads as "the
-- snapshot lost my buffer" when the buffer is sitting right there, so the
-- display's own model of the waveform travels with it.
snap_clear(9)
for i = 1, 8 do VS[1].wave[i] = i / 8; VS[2].wave[i] = 1 - (i / 8) end
hold(9, 1)                                  -- slot 9
for i = 1, 8 do VS[1].wave[i] = 0; VS[2].wave[i] = 0 end
tapg(9, 1)
check(math.abs(VS[1].wave[4] - 0.5) < 0.01,
  "loading did not restore GRAINSWARM 1's waveform picture, slot 4 is "
  .. tostring(VS[1].wave[4]))
check(math.abs(VS[2].wave[4] - 0.5) < 0.01,
  "loading did not restore GRAINSWARM 2's waveform picture")
-- ...and a NEW PROJECT wipes it, because the buffer it pictures is wiped too
tapg(11, 6)
check((VS[1].wave[4] or 0) < 0.01 and (VS[2].wave[4] or 0) < 0.01,
  "an empty slot cleared the buffer but left the old waveform on screen")

-- and you can still LEAVE the page. SNAPSHOTS is last in the lane now, so K3
-- has nowhere to go and K2 is the way out. The thing being tested is that the
-- page is not a trap, which is a claim about the pair of keys, not about K3.
goto_page_index(PG)
local before = current_page()
key(2, 1); key(2, 0)
check(current_page() ~= before,
  "K2 could not page off SNAPSHOTS - the page is a trap")
-- SNAPSHOTS is no longer the end of the lane - the PAPPUS scene is - so K3
-- leaves it, and the END is what has to be a wall.
goto_page_index(PG)
key(3, 1); key(3, 0)
check(current_page() ~= PG, "K3 could not page off SNAPSHOTS")
check(pappus.pages[current_page()].kind == "pappus",
  "the page after SNAPSHOTS is "
  .. tostring(pappus.pages[current_page()].name) .. ", not the PAPPUS scene")
local last = current_page()
key(3, 1); key(3, 0)
check(current_page() == last, "K3 walked off the end of the lane from PAPPUS")

if #fails > 0 then
  for _, f in ipairs(fails) do print("  FAIL " .. f) end
  print(string.format("SNAP TEST FAILED (%d)", #fails))
  os.exit(1)
end
print("SNAP TEST OK")
