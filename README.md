# pappus

*scatter to the wind*

Two euclidean granular swarmers + resonant filterbank + multitap delay +
colour + scene morphing, with modular routing and modulation.

A very deep sound design tool and soundscape instrument.

```
K2 back                  K3 forward
K2 & K3                  change lane
long K2                  reset parameter & clear modulation
long K3                  lock / freeze / hold module
E1                       select parameter
E2 value                 E3 sub-value / fine tune
```

Grid compatible (see below).

Designed by Michael Manning. Inspired by Torso S-4.

Heavy LLM usage disclaimer. 100% Claude code.

---

## requirements

norns. A grid is optional — everything is reachable without one.

## install

```
;install https://github.com/FoundSoundsMM/pappus
```

## the chain

```
GRAINSWARM 1 \
              >  RESONATOR  >  DELAY  >  COLOUR  >  REVERB  >  out
GRAINSWARM 2 /
```

```
STEREO     left to the left buffer, right to the right, kept apart
MONO L     the left input, written to BOTH buffers
MONO R     the right input, written to both
```

A mono source is not "stereo with one side missing": it goes to both sides so
the grains arrive centred rather than stacked against one speaker. STEREO with
a lead in one socket really is one-sided, which is what stereo means.

```
OUT        the master output, after everything (the default)
GS1 / GS2  either granulator's own output
IN L+R     both inputs, averaged
LEFT       the left input only
RIGHT      the right input only
```
## controls

- **K2** back a page, **K3** forward, within the current lane. **Long K2** puts the selected parameter back to its default and takes any modulator off it.
- On **SNAPSHOTS**: long **K3** saves the selected slot, long **K2** clears it, and **push E2** loads it. A load is a **reset first**: everything goes back to its default and the snapshot is applied on top, so nothing from the last patch survives into it — and **SRC always comes back OFF**, because an armed input would record straight over the audio the snapshot just loaded. E2 and E3 walk the slots (one at a time, and a row at a time).
- **K2 and K3 together** change lane: the audio chain (both GRAINSWARMs → RESONATOR → DELAY → COLOUR → SIGNAL → SNAPSHOTS) sits above the modulators (four MODNI LFO pages and MODNI ENV), so paging along the chain never walks you through eight LFO pages. The display wipes vertically so it is obvious which way you went.
- The encoders push, on hardware that has it: **push E1** returns the selected parameter to its default, **push E2** and **push E3** snap it to the nearest round value.
- **Long K3** fires the page's toggle — LOCK, FREEZE, HOLD, BYPASS, DIM.
- **E1** selects a cell, **E2** sets its value, **E3** its sub-value — or, on a cell that has no sub-value, a **fine tune**.
- Both knobs land on **round numbers**. The grid comes from the size of the value rather than the width of the range, so a frequency knob steps in 10 Hz at 700 Hz and 1 Hz at 70; the coarse knob keeps its sweep (a percent of the travel per click) and rounds onto that grid, and the fine knob steps by exactly a tenth of it. 0.5, 700 Hz and 60.1 BPM are all reachable.
- The last page in the audio lane is **PAPPUS**: no controls, just the sky. Every grain that fires puts one dandelion seed into it — one per *grain*, not per voice, so a held chord at 1/16 is a blizzard and a single voice at 1/1 is a seed every couple of seconds. The modules blow them about: MODNI 1 and 2 are the wind direction, WOW the swirl, NOISE the turbulence, DRIVE the spin and the ragged crowns, N.TONE the filament count, LOSS the missing filaments, CRUSH the stepping, RESONATOR's FREQUENCY how high they enter, and the grain's own pitch how big the seed is. The air empties when you leave the page.
- On the grid: one row per grain on either GRAINSWARM page — the page you are on decides which granulator's chord you are editing — one per tap on DELAY, one per slot on SNAPSHOTS. Hold a grain key and E2/E3 set that voice's level and probability.

## clock and transport

With `clock_source` on internal, Pappus is the master and free-runs at **60 BPM**; the **BPM** cell on SIGNAL sets it. Sixty rather than norns' hundred and twenty because every timed control here is a division of the beat, and at 120 the useful divisions all bunch up at the fast end.

Slaved to MIDI, Link or crow, the granulator **waits for PLAY**: nothing is captured and no grain is spawned until the transport starts, and STOP stops it again. Everything downstream keeps running while it waits, so delay tails and resonator rings decay away rather than being cut off. The BPM cell reads **EXT** and is inert — from the encoder and from the grid.

## midi

Clock in: set `clock_source` to MIDI in SYSTEM > CLOCK. Every timed control — grain rate, delay, both LFOs, the resynthesis slice — divides the transport.

Notes in: PARAMS > MIDI > **notes**. Notes drive GRAINSWARM 1.

- **voices** — each held note takes one of the eight grains, up to eight at once; a ninth steals the oldest. Middle C is the leftmost grid column at the middle octave, so the keyboard and the grid agree. Release everything and the swarm goes quiet.
- **transpose** — the grid chord stays as it is and the note moves PITCH. Middle C is no transposition, and the last note played is held.

The grid chord is put back untouched when **notes** returns to off. **velocity to level** maps velocity onto the voice's level; turn it off for a controller that does not send velocity.

CC mapping: norns' own. In PARAMS, hold **K1** and press **K3**.
