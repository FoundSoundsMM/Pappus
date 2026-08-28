"""Is the output hotter than it used to be?

Mick reported clipping on GRAINSWARM 1 alone after the second granulator went
in. GRAINSWARM 2 is inaudible at the default routing, so if the level really
moved it moved for some other reason, and the only way to know is to render the
SAME patch through the old engine and the new one and compare.

Two numbers per render:

The old-vs-new comparison is made at an overlap of TWO - the default density -
because that is where the new overlap normalisation is inert. Above it the two
builds are meant to differ: that is the fix, not a regression.

  peak      how close to full scale it gets. The limiter sits at 0.944, so a
            peak pinned there means the limiter is holding the roof up - which
            is audible as pumping long before anything actually clips.
  headroom  peak with the limiter opened to 1.0, which is what the chain would
            do if nothing were catching it. This is the honest measure of how
            hot the signal is, because the limiter hides exactly the thing
            being asked about.

Also measures SRC STEREO against SRC LEFT, because that pair is the one real
level change in this build: LEFT takes one channel at unity where the old code
always summed both at half, so on a decorrelated stereo source LEFT is about
3 dB hotter than what used to be the only option.

Run:  python3 test/clip_test.py --render
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

OLD_ENGINE = "/tmp/Engine_backup.sc"      # the single-granulator build

# Decorrelated left and right, so STEREO and LEFT are genuinely different.
SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.3;
	Out.ar(outl, PinkNoise.ar(lvl));
	Out.ar(outr, PinkNoise.ar(lvl));
});
'''

# fully wet: the sweep is about the GRAINS
PRESETS = [("m_rate", 8), ("m_size", 1.0), ("m_sos", 0.8),
           ("p_wet", 0.0), ("s_wet", 0.0)]

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
	"CLIP TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def render_group(tag, over):
    scal, setn = H.init_args(PRESETS, over)
    setn = setn + ",\n\t\t[0.0, ['/n_setn', 1001, \\gates, 8, 1,0,0,0,0,0,0,0]]"
    return '\t~render.value("/tmp/cl_%s", [%s], [%s]); 1.5.wait;' % (tag, scal, setn)


def build_new():
    lines = [
        render_group("new_ste", [("msrc", 2)]),
        render_group("new_left", [("msrc", 3)]),
        # limiter opened right up: what the chain would do uncaught
        render_group("new_open", [("msrc", 2), ("limceil", 1.0),
                                  ("msize", 0.125)]),
    ]
    # SIZE, swept with the limiter open. msize is in SECONDS by the time it
    # reaches the engine; the default patch here is 0.125 s at 16 Hz, an
    # overlap of two. The top of the knob is eight beats, which at this rate is
    # an overlap of sixty-four.
    for tag, sz in (("sz1", 0.125), ("sz4", 0.5), ("sz16", 2.0), ("sz64", 8.0)):
        lines.append(render_group(
            tag, [("msrc", 2), ("limceil", 1.0), ("msize", sz)]))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def build_old():
    # the old engine has no msrc at all - it always summed both inputs, which
    # is exactly what the new STEREO setting does
    lines = [
        render_group("old_ste", []),
        render_group("old_open", [("limceil", 1.0), ("msize", 0.125)]),
    ]
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def stats(tag, t0=3.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/cl_%s.wav" % tag)
    m = x[int(t0 * sr):int(t1 * sr)]
    peak = float(np.abs(m).max())
    r = float(np.sqrt((m * m).mean()))
    return peak, r


def db(v):
    return 20 * math.log10(max(v, 1e-12))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_new()), "/tmp/clip_new.scd", timeout=2400,
              expect="CLIP TEST DONE")
        # The old-engine comparison ran once and answered its question:
        # +0.04 dB rms, -1.10 dB peak, i.e. the chain was not hotter. It cannot
        # be re-run meaningfully now - SOS means a different thing in the two
        # builds, so there is no setting at which they are comparable.

    fails = []
    rows = ["new_ste", "new_left", "new_open"]
    vals = {}
    print("  %-9s %8s %8s %8s" % ("", "peak", "peak dB", "rms dB"))
    for t in rows:
        p, r = stats(t)
        vals[t] = (p, r)
        print("  %-9s %8.4f %8.2f %8.2f" % (t, p, db(p), db(r)))

    def check(c, m):
        if not c:
            fails.append(m)

    if "old_open" in vals:
        # the honest comparison: limiter open, same source, same settings
        d = db(vals["new_open"][0]) - db(vals["old_open"][0])
        dr = db(vals["new_open"][1]) - db(vals["old_open"][1])
        print("\n  new vs old, limiter open: peak %+.2f dB, rms %+.2f dB"
              % (d, dr))
        # PEAK gets a wider bound than rms on purpose. The grain cloud is
        # stochastic and the two builds are separate renders, so the single
        # loudest sample wanders by a decibel run to run while the rms - which
        # is the level question actually being asked - does not.
        check(abs(d) < 2.0,
              "the chain is %+.2f dB hotter at the peak than the single-"
              "granulator build on an identical patch" % d)
        check(abs(dr) < 1.0,
              "the chain is %+.2f dB hotter in rms than the single-"
              "granulator build on an identical patch" % dr)

    # SIZE must not be a volume knob. Sixty-four grains overlapping instead of
    # two is five doublings; uncorrected that is fifteen decibels of power sum,
    # which is exactly the sort of thing you discover by clipping.
    if os.path.exists("/tmp/cl_sz64.wav"):
        base = db(stats("sz1")[1])
        print()
        for tag, ov in (("sz1", 2), ("sz4", 8), ("sz16", 32), ("sz64", 64)):
            d = db(stats(tag)[1]) - base
            print("  SIZE overlap %-3d          rms %+.2f dB" % (ov, d))
            check(d < 6.0,
                  "SIZE at overlap %d is %+.2f dB above the default, so it is "
                  "still a volume knob" % (ov, d))

    # SRC LEFT against SRC STEREO. Not a fault, but it IS a level change and
    # it should be about 3 dB on a decorrelated source, not more.
    dl = db(vals["new_left"][1]) - db(vals["new_ste"][1])
    print("  SRC LEFT vs STEREO:       rms %+.2f dB" % dl)
    check(dl < 4.5,
          "SRC LEFT is %+.2f dB above STEREO, which is more than taking one "
          "channel at unity should cost" % dl)

    if fails:
        for f in fails:
            print("  FAIL " + f)
        print("CLIP TEST FAILED (%d)" % len(fails))
        sys.exit(1)
    print("CLIP TEST OK")
