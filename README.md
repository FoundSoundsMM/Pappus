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
