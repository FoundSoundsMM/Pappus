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

Fixed order, and **SIGNAL is the routing**. Every stage has an amount of each
granulator fed into it — **DRY IN**, two bars in one cell, E2 for GRAINSWARM 1 and E3 for
GRAINSWARM 2, all eight at 70% by default. A granulator entering at RESONATOR
flows through everything after it; one entering only at COLOUR has skipped the
first two; one entering only at SIGNAL's **DRY IN** has skipped the lot. Turn a feed to
zero and that granulator bypasses that module — independently of the other one.

There are no module faders and no reordering: how loud a module is in the mix
is decided by how much is fed into it, which is one idea instead of two that
fight. SIGNAL draws the whole thing as a wireframe with a live meter and a dB
number on every box.

**REVERB** sits on SIGNAL itself, after COMP — a compressor does not know a
reverb tail from a transient, so COMP holds the dry mix together first and
REVERB gets whatever it leaves behind. **VERB** is wet/dry — zero is a true
bypass, whatever its secondary knob is doing — and its secondary, **TIME**,
walks size and decay together, from a short tail up to a huge, slowly
decaying tank; pushed all the way it goes past "huge" into frozen, holding
the tank's tail instead of letting it decay. **SHINE** is a shimmer send:
some of the tail is pitch shifted up and
returned into the tank, so a held chord keeps climbing rather than only
decaying. Its **MODE** picks the interval — an octave, a fifth, or the
current SCALE's own nearest fifth.

**RESONATOR** is a Rings-style modal/string resonator excited by the
granulators. **FREQUENCY** locks to the grain chord, runs FREE on its own, or
FREE quantized to the global **SCALE**; **STRUCTURE**, **BRIGHTNESS**,
**DAMPING** and **POSITION** are the four macro controls Mutable Instruments
Rings is built on. **MODE**, paired with STRUCTURE, switches between the
MODAL bank and a Karplus-Strong **STRING** model. **GRAIN** rides the
excitation's own envelope to add grit to the signal — silence in, silence
out — a Mutable Elements-style "blow" that never hisses on its own.

RESONATOR and DELAY are **MIX only** — SEND is gone. It held the dry at
unity and let the wet ride on top, which mattered when a stage was the only
way to get a dry signal past itself; SIGNAL's feeds do that properly now, and
two mechanisms for one job is how a routing page stops being readable.

Master is **mixer → COMP → REVERB → limiter**, and nothing else. There used to be a
hidden mastering stage — expander, saturation, width, tape wobble — which
measured well on a grain cloud and buffeted audibly on a clean signal passed
straight through. A stage nobody can turn off has to be right for every signal
that can reach it.

GRAINSWARM 1 is the parent: **SCALE** is one setting for both, and GRAINSWARM
2's **RATE** is a ratio of GRAINSWARM 1's. A small chain mark says so.

### the capture is stereo

Each granulator records into **two mono buffers**, left and right, because
`GrainBuf` reads a mono buffer — "the buffer holding a mono audio signal",
says its own help — and handing it a two-channel one reads the interleave as
if it were a waveform. So **SRC** is:

```
STEREO     left to the left buffer, right to the right, kept apart
MONO L     the left input, written to BOTH buffers
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

### loading a sample

PARAMS > GRAINSWARM > **1 sample** (and **2 sample** for the second
granulator) fills that granulator's buffer from a file instead of from the
input. Everything downstream is unchanged — GRAINSWARM does not know or care
where the samples in its buffer came from — so a sample is granulated,
resonated, delayed and coloured by exactly the controls a recording is.

Choosing a file moves three things, and it has to:

```
SRC     to OFF        or the live input records over it immediately
SOS     to the top    SOS is also the blend, and at the bottom you hear the
                      input going past rather than the grains - which, with
                      SRC off, is silence
BUFFR   to its length so the playhead and the window span the file rather
                      than the file plus fifty seconds of nothing
```

All three are ordinary cells afterwards. Turning **SRC** back to STEREO
resumes recording over the sample, which is the way back; **1 clear sample**
wipes the buffer instead. While a sample is loaded, the source reads as the
file's name rather than NO INPUT.

Stereo files stay stereo — one channel into each of the pair — and mono files
go to both sides, centred, exactly like MONO L does on the live input.
Nothing resamples on the way in, so a file that is not 48 kHz would play
sharp or flat; the difference is measured from the header and taken out of
every voice's pitch, so a 44.1 kHz sample plays at the pitch it was recorded
at. Anything past sixty seconds is truncated to the buffer.

A **snapshot** saves the loaded audio the same way it saves a recording — it
writes the buffer out either way — and carries the file's name and its rate
correction with it.

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

## performance

PARAMS > PERFORMANCE.

On a norns the screen and the encoders are served by the **same thread**, so a
frame that takes too long does not merely drop a frame — it holds the encoder
queue shut, and what you feel is a knob that does nothing and then jumps
several steps at once. A shield with a Pi 4 in it has the headroom to draw
these pages at twenty-five a second; a factory norns, on a Pi 3, does not
always.

- **screen fps** — 25 (default), 20, 15 or 10. Nothing about the instrument
  changes: every animation advances by elapsed time, so at 15 the same motion
  is drawn less often rather than more slowly. Fifteen is still smooth for
  what is on these pages and is a forty per cent cut in everything the screen
  costs.
- **grid fps** — 25 (default), 15 or 10. Separate because the grid is a
  different bottleneck: not cairo, but up to 128 LED writes and a serial
  frame. The display already skips a refresh entirely when nothing on the grid
  moved; this caps how often it may send one when things are moving.

If you are seeing high CPU or hearing clicks on a factory norns, the other
things worth knowing:

- **audio/** is scanned at load and every `.wav` in it becomes a NOISE type
  and a RESONATOR GRAIN type. The files are held in memory for the whole
  session, so a folder full of long loops is a folder full of resident RAM.
- Every capture buffer is **sixty seconds**, four of them, whatever BUFFR is
  set to. That is fixed at load, not per patch.
- **LOSS** is the single most expensive control in the engine — it is a real
  short-time Fourier transform — but it costs the same whether the knob is up
  or down.
