"""Mick's repro: SIZE tiny, SHAPE 0, DELAY diffuse 0 and wet 0 - and there is
clearly a reverb.

An earlier test (tail_test.py) measured the tail at DEFAULT settings and
concluded the wash was the capture buffer looping. This is a different case and
deserves a different measurement rather than a restatement: with grains that
short, anything that rings is ringing on its own.

Every stage is switched out one at a time from the full chain, so whatever the
tail is attached to shows up as the render where it disappears. The input is a
single 20 ms click at 0.5 s and then silence, which is the only source that
cannot be confused with its own echo.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
// two seconds of pink noise from 0.5 s, then silence. A click is the wrong
// probe here: with 4 ms grains at 8 Hz the output is 4 ms of sound every
// 125 ms, and a click gives the granulator almost nothing to find.
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	var env = EnvGen.ar(Env([0, 1, 1, 0, 0], [0.002, 1.996, 0.002, 30], \lin),
		Impulse.ar(0));
	var s = PinkNoise.ar(0.5) * DelayN.ar(env, 1, 0.5);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# The settings Mick describes, spelled out: tiny grains, SHAPE at 0, DELAY
# diffuse and wet both off. Everything else at what init sends.
BASE = r'''\mspray, 0, \mspraymode, 1, \mswarm, 0, \mswarmmode, 1,
	\mstrum, 0, \melen, 1, \mephase, 0, \msos, 0, \mlock, 0,
	\mbuflen, 8, \mwinstart, 0, \mwinend, 1,
	\mscan, 0.666, \mscanmode, 1, \mdelay, 0,
	\mcontour, 8,
	\pcentre, 800, \pspan, 3, \pslicehz, 2000, \pfreeze, 0,
	\pblur, 0.15, \pfb, 0, \pwave, 0.2, \pwarp, 1, \ppitch, 0,
	\pnorm, 2.13, \pwet, 0, \pquanton, 0,
	\scycle, 2, \sfb, 0.35, \stilt, -0.2, \stiltxover, 650,
	\sdiffuse, 0, \swet, 0, \shold, 0,
	\drive, 0, \compress, 0, \crush, 0, \crushmode, 4, \tilt, 0,
	\noise, 0, \noisetype, 2, \noisedecay, 0.25, \noisetone, 1200,
	\noisedyn, 2,
	\bypass, 0,
	\ingain, 1, \glev, 1, \flev, 1, \slev, 1, \klev, 1, \sendpre, 0,
	\limceil, 1.0, \amp, 1.0'''

TAPS = r'''[0.0, ['/n_setn', 1001, \taptimes, 8, 0.5,1,1.5,2,0.125,0.125,0.125,0.125]],
	[0.0, ['/n_setn', 1001, \taplevels, 8, 0.467,0.423,0.380,0.336,0,0,0,0]],
	[0.0, ['/n_setn', 1001, \tappans, 8, -0.5,0.5,-0.35,0.35,-0.5,0.5,-0.225,0.225]],'''

SCRIPT = r'''
~render = { arg path, args;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0, BASEARGS] ++ args],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8, 1,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \pgate, 16, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]],
		TAPARGS
		[10.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

// SIZE tiny, SHAPE 0, one voice, a rate you would actually play at
~pluck = [\mrate, 8, \msize, 0.004];

fork {
	~render.value("/tmp/k_full", ~pluck); 1.5.wait;
	// one stage out at a time
	~render.value("/tmp/k_nostil", ~pluck ++ [\sfb, 0, \swet, 0, \slev, 0]);
	1.5.wait;
	~render.value("/tmp/k_nokul",  ~pluck ++ [\wet, 0]); 1.5.wait;
	~render.value("/tmp/k_nospec", ~pluck ++ [\flev, 0]); 1.5.wait;
	// and the granulator on its own, tapped before anything else
	~render.value("/tmp/k_gonly",  ~pluck ++ [\wet, 0, \slev, 0, \flev, 0,
		\swet, 0, \sfb, 0]); 1.5.wait;

	// the buffer itself: shorten it and the tail should shorten with it if
	// the wash is the capture loop replaying
	~render.value("/tmp/k_buf2",   ~pluck ++ [\mbuflen, 2]); 1.5.wait;
	~render.value("/tmp/k_buf1",   ~pluck ++ [\mbuflen, 1]); 1.5.wait;
	// SLIDE at unity: the playhead runs WITH the write head instead of
	// lagging it, so there is no history to replay
	~render.value("/tmp/k_unity",  ~pluck ++ [\mscan, 0.5]); 1.5.wait;
	// and the window closed right down at the top of the buffer
	~render.value("/tmp/k_win",    ~pluck ++ [\mwinstart, 0.9, \mwinend, 1.0]);
	1.5.wait;

	"PLUCK TEST DONE".postln;
	0.exit;
};
'''.replace("BASEARGS", BASE).replace("TAPARGS", TAPS)


def env(tag, hop=0.005):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = np.abs(x).max(axis=1)
    n = int(hop * sr)
    return [(i / sr, float(m[i:i + n].max())) for i in range(0, len(m) - n, n)]


def report(tag, label, ref):
    e = env(tag)
    peak = max(v for _, v in e) or 0.0
    if peak < 1e-5:
        print(f"  {label:<26} silent")
        return
    thr = ref * 0.003                      # about -50 dB of the reference peak
    last = 0.0
    for t, v in e:
        if v > thr:
            last = t
    print(f"  {label:<26} peak {peak:.4f}   rings until {last:5.2f}s"
          f"   tail {max(last - 2.5, 0):5.2f}s")


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/pluck.scd", timeout=1800,
              expect="PLUCK TEST DONE")
        print("rendered")

    ref = max(v for _, v in env("k_full")) or 1e-9

    print("\n=== one 20 ms click at 0.50 s, then silence ===")
    print("    SIZE 0.004, SHAPE centred, DELAY diffuse 0 and wet 0")
    print("    input runs 0.50-2.50 s; tail is measured from 2.50 s")
    for tag, label in [("k_full", "the whole chain"),
                       ("k_nostil", "DELAY out entirely"),
                       ("k_nokul", "COLOUR out"),
                       ("k_nospec", "FILTERBANK return out"),
                       ("k_gonly", "GRAINSWARM alone")]:
        report(tag, label, ref)

    print("\n=== and what changes its length ===")
    for tag, label in [("k_full", "8 s buffer (as above)"),
                       ("k_buf2", "2 s buffer"),
                       ("k_buf1", "1 s buffer"),
                       ("k_unity", "SLIDE at unity (0.5)"),
                       ("k_win", "window closed to 0.9-1.0")]:
        report(tag, label, ref)

    print("\n=== envelope of the full chain, 0.1 s steps ===")
    e = env("k_full")
    peak = max(v for _, v in e) or 1e-9
    for t, v in e:
        if 0.4 < t < 7.0 and round(t * 200) % 40 == 0:
            bar = "#" * int(56 * (v / peak))
            print(f"  {t:5.2f}s {20*math.log10(max(v,1e-9)/peak):+7.1f} dB {bar}")
