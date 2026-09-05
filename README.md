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

Grid compatible.

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
- **screen detail** — FULL (default) or LITE. A different economy from screen
  fps: fps is how *often* a page is drawn, this is how much of it there is to
  draw, and dropping to 15 while keeping full detail leaves every frame as
  expensive as it was. LITE takes the antialiasing off COLOUR's sheet and
  PAPPUS's filaments, samples the sheet at twenty points across instead of
  thirty, and draws the GRAINSWARM waveform in two-pixel columns rather than
  one — taking the louder slot of each pair, so a transient is still on the
  screen rather than averaged away. Cells, headers, values, numbers and the
  grid are untouched. On the two heaviest pages that is about a quarter of the
  geometry, before counting what the antialiasing was costing on its own.
- **mod fps** — 60 (default) or 30, and this one is not free. The modulators
  run on their own metro, faster than the display, because an LFO stepped at
  the screen's rate is visibly stepped; sixty a second is eight LFOs advanced,
  sixteen routings accumulated and every touched destination re-sent, on the
  same thread as the screen and the encoders. Halving it halves that. What you
  give up is the top of the RATE knob: the ceiling tracks the update rate at a
  fifth of it — past which a sine stops being a sine and becomes a staircase —
  so at 30 the fastest an LFO can run drops from 12 Hz to 6. Everything below
  is unchanged, the RATE cell shows the resulting Hz either way, and an LFO
  already set above the new ceiling is pulled down to it rather than left
  aliasing.

If you are seeing high CPU or hearing clicks on a factory norns, the other
things worth knowing:

- **audio/** is scanned at load and every `.wav` in it becomes a NOISE type
  and a RESONATOR GRAIN type. Every one of them is held in memory and played
  continuously for the whole session, whichever is selected — so a folder full
  of long loops costs both resident RAM and memory bandwidth all the time.
- Every capture buffer is **sixty seconds**, four of them, whatever BUFFR is
  set to. That is fixed at load, not per patch.
- **LOSS** is the single most expensive control in the engine — it is a real
  short-time Fourier transform — but it costs the same whether the knob is up
  or down.

### changing the engine

`lib/Engine_Pappus.sc` is one SynthDef sitting close to a hard limit: scsynth
allocates a fixed pool of **64 audio interconnect buffers**, and a def needing
more is *rejected at load*. On norns that failure is silent — the class loads,
every engine command is accepted and goes nowhere, Lua raises nothing, screen
and grid work perfectly, and there is no audio at all.

`test/wirecount.py` models that allocation statically and **undercounts**: it
scored a def at 63 that the real server refused. So before shipping any engine
change, load it into an actual scsynth:

```
python3 test/defload.py            # ...and --loops N to fake N files in audio/
```

It needs SuperCollider installed, runs offline in NRT, and takes about a
minute.
