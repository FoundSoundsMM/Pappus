"""SIGNAL: the mixer has to actually change levels.

The complaint this page exists to answer is that SEND returns were too quiet,
so the checks that matter are: does a return fader move the return (and only
the return), does input gain scale the whole thing, does the limiter ceiling
hold the peak, and does PRE keep the effect alive when BAQBAQ is pulled down.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.3;
	var s = SinOsc.ar(220) * lvl;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

BASE = r'''\mcontour, 8, \mspray, 0, \mswarm, 0, \mpattern, 0, \mstrum, 0,
	\mbuflen, 4, \mrate, 30, \msize, 0.12, \mscanmode, 1, \mscan, 0.666,
	\drive, 0, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
	\amp, 1.0, \limceil, 0.944'''

SCRIPT = r'''
~render = { arg path, args, events;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			BASEARGS] ++ args],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8, 1,0,0,0,0,0,0,0]]
	] ++ events ++ [
		[7.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

// Return-fader checks run quiet with the limiter open, or the limiter eats
// the very difference being measured.
~quiet = [\amp, 0.2, \limceil, 1.0];

// FILTRU in SEND, return fader at unity then +12 dB
~filt = [\pwet, 1, \pcentre, 800, \pspan, 3,
	\pslicehz, 200, \pblur, 0.05, \pwave, 0.2, \pnorm, 2.13];
// DELAY in SEND, one tap
~stil = [\swet, 1, \scycle, 0.25, \sfb, 0.3, \sdiffuse, 0,
	\shold, 0];

fork {
	~render.value("/tmp/m_dry",   ~quiet ++ [\pwet, 0, \swet, 0], []); 1.5.wait;

	~render.value("/tmp/m_f0",  ~filt ++ ~quiet ++ [\flev, 1], []); 1.5.wait;
	~render.value("/tmp/m_f12", ~filt ++ ~quiet ++ [\flev, 3.981], []); 1.5.wait;

	~render.value("/tmp/m_s0",  ~stil ++ ~quiet ++ [\slev, 1],
		[[0.0, ['/n_setn', 1001, \taptimes, 8, 0.12,0.2,0.3,0.4,0.5,0.6,0.7,0.8]],
		 [0.0, ['/n_setn', 1001, \taplevels, 8, 1,0,0,0,0,0,0,0]],
		 [0.0, ['/n_setn', 1001, \tappans, 8, 0,0,0,0,0,0,0,0]]]); 1.5.wait;
	~render.value("/tmp/m_s12", ~stil ++ ~quiet ++ [\slev, 3.981],
		[[0.0, ['/n_setn', 1001, \taptimes, 8, 0.12,0.2,0.3,0.4,0.5,0.6,0.7,0.8]],
		 [0.0, ['/n_setn', 1001, \taplevels, 8, 1,0,0,0,0,0,0,0]],
		 [0.0, ['/n_setn', 1001, \tappans, 8, 0,0,0,0,0,0,0,0]]]); 1.5.wait;

	// input gain: -6 dB in should be -6 dB out
	~render.value("/tmp/m_dryf", [\pwet, 0, \swet, 0], []); 1.5.wait;
	~render.value("/tmp/m_in6", [\pwet, 0, \swet, 0, \ingain, 0.5012], []);
	1.5.wait;

	// limiter: a ceiling 20 dB down must hold the peak there
	~render.value("/tmp/m_lim", [\pwet, 0, \swet, 0, \limceil, 0.1], []);
	1.5.wait;

	// PRE vs POST: BAQBAQ pulled 20 dB down, delay in SEND.
	// POST takes the delay with it, PRE leaves it up.
	~render.value("/tmp/m_post", ~stil ++ [\slev, 1, \glev, 0.1, \sendpre, 0],
		[[0.0, ['/n_setn', 1001, \taptimes, 8, 0.12,0.2,0.3,0.4,0.5,0.6,0.7,0.8]],
		 [0.0, ['/n_setn', 1001, \taplevels, 8, 1,0,0,0,0,0,0,0]],
		 [0.0, ['/n_setn', 1001, \tappans, 8, 0,0,0,0,0,0,0,0]]]); 1.5.wait;
	~render.value("/tmp/m_pre", ~stil ++ [\slev, 1, \glev, 0.1, \sendpre, 1],
		[[0.0, ['/n_setn', 1001, \taptimes, 8, 0.12,0.2,0.3,0.4,0.5,0.6,0.7,0.8]],
		 [0.0, ['/n_setn', 1001, \taplevels, 8, 1,0,0,0,0,0,0,0]],
		 [0.0, ['/n_setn', 1001, \tappans, 8, 0,0,0,0,0,0,0,0]]]); 1.5.wait;

	"MIX TEST DONE".postln;
	0.exit;
};
'''.replace("BASEARGS", BASE)


def stats(tag, t0=4.0, t1=7.0):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    seg = x[int(t0 * sr):int(t1 * sr)]
    return (float(np.sqrt((seg ** 2).mean())), float(np.abs(seg).max()))


def db(a, b):
    return 20 * math.log10(max(a, 1e-12) / max(b, 1e-12))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/mix.scd", timeout=1800,
              expect="MIX TEST DONE")
        print("rendered")

    dry_rms, dry_pk = stats("m_dry")
    print("\n=== return faders (both effects in SEND) ===")
    print(f"  {'':<28}{'rms':>9}{'vs dry':>9}{'vs unity':>10}")
    print(f"  {'dry, no sends':<28}{dry_rms:>9.4f}{0.0:>9.1f}{'':>10}")
    for tag, label, ref in [
        ("m_f0",  "spettru send, return 0 dB",  None),
        ("m_f12", "spettru send, return +12",   "m_f0"),
        ("m_s0",  "stillel send, return 0 dB", None),
        ("m_s12", "stillel send, return +12",  "m_s0"),
    ]:
        r, _ = stats(tag)
        rel = f"{db(r, stats(ref)[0]):>10.1f}" if ref else " " * 10
        print(f"  {label:<28}{r:>9.4f}{db(r, dry_rms):>9.1f}{rel}")

    print("\n=== input gain and limiter ===")
    r6, _ = stats("m_in6")
    full, _ = stats("m_dryf")
    print(f"  input -6 dB:        {db(r6, full):+6.1f} dB out (expect -6.0)")
    _, pk = stats("m_lim")
    print(f"  ceiling -20 dB:     peak {pk:.4f} "
          f"({20*math.log10(max(pk,1e-9)):+6.1f} dBFS, expect <= -20)")

    print("\n=== send tap, BAQBAQ pulled 20 dB down ===")
    for tag, label in [("m_post", "POST (delay follows)"),
                       ("m_pre", "PRE  (delay stays up)")]:
        r, _ = stats(tag)
        print(f"  {label:<24} rms {r:.5f}  "
              f"({db(r, stats('m_dryf')[0]):+6.1f} dB vs dry)")
    print(f"  PRE - POST: {db(stats('m_pre')[0], stats('m_post')[0]):+6.1f} dB")
