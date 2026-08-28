"""Two granulators, and the routing that decides where each of them joins.

The single INPUT knob these two used to share is gone. SIGNAL is a set of
feeds now - how much of each granulator is fed into each stage - so the claims
have changed with it:

  1. GRAINSWARM 2 MAKES A SOUND AT ALL. Everything else is worthless if the
     second granulator is silent, and "the def loads" does not prove it: the
     whole thing is one function called twice, so a mistake in the second call
     is invisible until something listens to it.
  2. A FEED AT ZERO IS A BYPASS. Set a granulator's feed into a stage to zero
     and none of it reaches that stage - measured by muting the OTHER
     granulator's voices, so the only thing that can be making a sound is the
     one whose route is under test.
  3. THE DIRECT FEED SKIPS EVERYTHING. Route a granulator only to the output
     with every stage feed at zero and it is still audible, which is the whole
     point of the page.

Run:  python3 test/dual_test.py --render
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.22;
	var s = PinkNoise.ar(lvl);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# A plain grain cloud, everything downstream out of the way, so what reaches
# the output IS the granulator pair and nothing else.
# SOS is a crossfade between the dry input and the grains now, and it
# defaults to 0 - fully dry. Left there, every case below would be
# measuring the input passing through and calling it the granulator.
PRESETS = [("m_rate", 8), ("m_size", 1.0), ("n_size", 1.0),
           ("m_sos", 0.8), ("n_sos", 0.8),
           # ...and both granulators actually recording. SRC defaults to OFF,
           # and this test sat on cached renders through the release that added
           # it - so it went on reporting OK while measuring nothing at all.
           # Re-rendering is what caught it. A test that is not re-run is not a
           # test.
           ("m_src", 2), ("n_src", 2),
           ("p_wet", 0.0), ("s_wet", 0.0)]

MUTE = "0,0,0,0,0,0,0,0"
OPEN = "1,0,0,0,0,0,0,0"

# Feeds, as the engine names them. All eight default to 0.7.
ALL_ON = {}
G1_OFF = {"pin1": 0, "sin1": 0, "kin1": 0, "oin1": 0}
G2_OFF = {"pin2": 0, "sin2": 0, "kin2": 0, "oin2": 0}
G1_DIRECT = {"pin1": 0, "sin1": 0, "kin1": 0, "oin1": 0.7}

# tag, feed overrides, swarm 1 voices, swarm 2 voices
CASES = [
    ("g1_only",   G2_OFF,    OPEN, MUTE),   # only swarm 1, routed normally
    ("g2_only",   G1_OFF,    MUTE, OPEN),   # only swarm 2, routed normally
    ("g1_muted",  G1_OFF,    OPEN, MUTE),   # every feed off: nothing gets out
    ("g2_muted",  G2_OFF,    MUTE, OPEN),
    ("g1_direct", G1_DIRECT, OPEN, MUTE),   # straight past the whole chain
    ("both",      ALL_ON,    OPEN, OPEN),
]

SCRIPT = r'''
~render = { arg path, args, setns;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0] ++ args]
	] ++ setns ++ [
		[10.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"DUAL TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build_script():
    lines = []
    for tag, feeds, g1, g2 in CASES:
        scal, setn = H.init_args(PRESETS, list(feeds.items()))
        # the gate arrays are overridden AFTER init_args' own, so these win
        setn = setn + (",\n\t\t[0.0, ['/n_setn', 1001, \\gates, 8, %s]]"
                       ",\n\t\t[0.0, ['/n_setn', 1001, \\gates2, 8, %s]]"
                       % (g1, g2))
        lines.append('\t~render.value("/tmp/du_%s", [%s], [%s]); 1.5.wait;'
                     % (tag, scal, setn))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def rms(tag, t0=4.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/du_%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    return float(np.sqrt((m * m).mean()))


def db(a, b):
    return 20 * math.log10(max(a, 1e-12) / max(b, 1e-12))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/dual.scd", timeout=2400,
              expect="DUAL TEST DONE")

    r = {t: rms(t) for t, _, _, _ in CASES}
    for t in sorted(r):
        print("  %-10s rms %.5f" % (t, r[t]))

    fails = []

    def check(c, m):
        if not c:
            fails.append(m)

    # 1. both granulators make a sound at all
    check(r["g1_only"] > 0.002,
          "GRAINSWARM 1 produced nothing: rms %.5f" % r["g1_only"])
    check(r["g2_only"] > 0.002,
          "GRAINSWARM 2 produced nothing: rms %.5f" % r["g2_only"])

    # 2. every feed at zero really is a bypass, not a duck. Anything above
    #    about -40 dB would be a leak rather than a route that is switched off.
    d1 = db(r["g1_muted"], r["g1_only"])
    d2 = db(r["g2_muted"], r["g2_only"])
    check(d1 < -40,
          "GRAINSWARM 1 with every feed at zero was only %.1f dB down" % d1)
    check(d2 < -40,
          "GRAINSWARM 2 with every feed at zero was only %.1f dB down" % d2)

    # 3. the direct feed skips the chain and is still heard
    check(r["g1_direct"] > 0.002,
          "GRAINSWARM 1 routed straight to the output produced nothing")

    check(r["both"] > 0.002, "both granulators together produced nothing")

    print("\n  g1, every feed off : %6.1f dB" % d1)
    print("  g2, every feed off : %6.1f dB" % d2)
    print("  g1 direct to out   : rms %.5f" % r["g1_direct"])

    if fails:
        for f in fails:
            print("  FAIL " + f)
        print("DUAL TEST FAILED (%d)" % len(fails))
        sys.exit(1)
    print("DUAL TEST OK")
