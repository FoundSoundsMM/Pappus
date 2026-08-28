"""Gain staging: is a healthy signal in a healthy signal out?

SOS is now a crossfade between the DRY INPUT and the GRAINS, which turns a
vague complaint - "the out meter sits near the bottom" - into an exact,
falsifiable question:

    sweep SOS from 0 to 1 and the output level must not move.

At 0 the chain is passing the input through, so that end IS the reference. If
the grains come out quieter, the deficit is measured in decibels rather than
argued about, and the make-up constant in the granulator is set from it. A knob
that changes the level while claiming to change the blend is the thing being
ruled out.

Second question, separately: how does the whole chain compare to its own input?
Unity is the target. An instrument that loses ten decibels makes every user
reach for a gain control to get back to where they started.

Third: FILTERBANK's hidden limiter. Long ring plus feedback is a regenerating
system that can climb far above anything the input suggests; the limiter has to
hold it without being audible when the bank is behaving.

Run:  python3 test/gain_test.py --render
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.3;
	var s = PinkNoise.ar(lvl);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# Mono-correlated source, so SRC STEREO is exactly the input and the reference
# is not muddied by a channel sum.
PRESETS = [("m_rate", 8), ("m_size", 0.25), ("p_wet", 0.0), ("s_wet", 0.0)]

SOS_SWEEP = [0.0, 0.15, 0.3, 0.45, 0.6, 0.8]

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
	"GAIN TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def group(tag, over):
    scal, setn = H.init_args(PRESETS, [("msrc", 2)] + over)
    setn = setn + ",\n\t\t[0.0, ['/n_setn', 1001, \\gates, 8, 1,0,0,0,0,0,0,0]]"
    return '\t~render.value("/tmp/gn_%s", [%s], [%s]); 1.5.wait;' % (tag, scal, setn)


def build_script():
    lines = []
    # the limiter is opened all the way for the sweep: it is the last thing in
    # the chain and it would flatten exactly the differences being measured
    for v in SOS_SWEEP:
        lines.append(group("sos%02d" % round(v * 100),
                           [("limceil", 1.0), ("msos", v)]))
    # FILTERBANK at its most regenerative, wet, with the limiter after it doing
    # the work. Rendered twice - once as built, once with the bank's own
    # limiter opened - so the claim "it is holding something down" is measured
    # rather than asserted.
    hot = [("limceil", 1.0), ("msos", 0.8), ("pwet", 1.0),
           ("preso", 0.95), ("pfb", 0.85)]
    lines.append(group("spettru", hot))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


# the same render with the bank's own limiter taken out of the graph, so the
# claim "it is holding something down" is an A/B rather than an assertion
NOLIM = [("fsum = Limiter.ar(fsum, 0.9, 0.02);", "")]


def build_nolim():
    hot = [("limceil", 1.0), ("msos", 0.8), ("pwet", 1.0),
           ("preso", 0.95), ("pfb", 0.85)]
    return SCRIPT.replace("RENDERS", group("spettru_nolim", hot))


def stats(tag, t0=4.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/gn_%s.wav" % tag)
    m = x[int(t0 * sr):int(t1 * sr)]
    return float(abs(m).max()), float(math.sqrt(float((m * m).mean())))


def db(v):
    return 20 * math.log10(max(v, 1e-12))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/gain.scd", timeout=2400,
              expect="GAIN TEST DONE")
        H.run(H.build(SRC + build_nolim(), patches=NOLIM), "/tmp/gain_nl.scd",
              timeout=2400, expect="GAIN TEST DONE")

    fails = []

    def check(c, m):
        if not c:
            fails.append(m)

    print("=== SOS: dry at the bottom, grains at the top. It must be FLAT ===")
    ref = None
    worst, worst_at = 0.0, 0.0
    for v in SOS_SWEEP:
        p, r = stats("sos%02d" % round(v * 100))
        if ref is None:
            ref = r
        d = db(r) - db(ref)
        if abs(d) > abs(worst):
            worst, worst_at = d, v
        print("  SOS %4.2f   rms %8.2f dB   peak %8.2f dB   %+6.2f dB vs dry"
              % (v, db(r), db(p), d))
    check(abs(worst) < 3.0,
          "SOS moved the level by %+.2f dB at %.2f, so it is a volume control "
          "as well as a blend" % (worst, worst_at))

    # unity through the whole instrument. The source is PinkNoise.ar(0.3),
    # whose rms is 0.3 / sqrt(3) for the uniform-ish distribution SC generates;
    # measured directly off the dry end of the sweep instead of assumed.
    print("\n=== the whole chain against its own input ===")
    print("  dry (SOS 0) is the input passing through: %.2f dB" % db(ref))
    _, rgr = stats("sos%02d" % round(0.8 * 100))
    print("  grains (SOS 0.80):                        %.2f dB" % db(rgr))

    print("\n=== FILTERBANK, wet, long ring, feedback up ===")
    p, r = stats("spettru")
    print("  peak %.3f (%.2f dB)   rms %.2f dB" % (p, db(p), db(r)))
    check(p < 1.05,
          "FILTERBANK at full regeneration reached %.3f with the master limiter "
          "open, so its own limiter is not holding it" % p)
    if os.path.exists("/tmp/gn_spettru_nolim.wav"):
        pn, rn = stats("spettru_nolim")
        print("  without the bank limiter:  peak %.3f (%.2f dB)   rms %.2f dB"
              % (pn, db(pn), db(rn)))
        print("  the limiter is holding back %.1f dB of peak" % (db(pn) - db(p)))
        check(pn > p,
              "taking the bank limiter out changed nothing (%.3f vs %.3f), so "
              "it is not doing the job it was added for" % (pn, p))

    if fails:
        for f in fails:
            print("  FAIL " + f)
        print("GAIN TEST FAILED (%d)" % len(fails))
        sys.exit(1)
    print("GAIN TEST OK")
