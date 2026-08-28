"""SRC: what each granulator is recording, and whether OFF really means off.

Four claims, and the discriminator for each is chosen so that no amount of
level fiddling could fake it:

  1. OFF CAPTURES NOTHING. Start with an empty buffer, leave SRC off, and the
     output stays at digital silence for the whole render. This is the claim
     that matters most, because SRC defaults to OFF - if it leaked, the
     default would be "quiet" rather than "off" and nobody would ever notice
     until they wondered why the buffer had material in it.
  2. STEREO IS STEREO. The source puts 300 Hz in the left and 3 kHz in the
     right, so a real stereo capture comes back low-heavy in the LEFT OUTPUT
     and high-heavy in the RIGHT. Measured per channel, because that is the
     only measurement that can tell a stereo capture from a summed one: the
     old test measured the mono sum and could not have caught this.
  3. A MONO SOURCE IS CENTRED. MONO L writes the left input to BOTH capture
     buffers, so it arrives in the middle rather than stacked against one
     speaker - which is the difference between "mono" and "stereo with one
     lead unplugged".

Run:  python3 test/src_test.py --render
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

# Two tones, one per channel, so "which input" is answerable from the spectrum
SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	Out.ar(outl, SinOsc.ar(300, 0, 0.3));
	Out.ar(outr, SinOsc.ar(3000, 0, 0.3));
});
'''

# fully wet, or these measure the dry input rather than the grains
PRESETS = [("m_rate", 8), ("m_size", 1.0), ("n_size", 1.0),
           ("m_sos", 0.8), ("n_sos", 0.8),
           ("p_wet", 0.0), ("s_wet", 0.0)]

# tag, msrc, nsrc   (1 OFF, 2 STEREO, 3 LEFT, 4 RIGHT)
CASES = [
    ("off",     1, 1),        # nothing anywhere: silence
    ("left",    3, 1),
    ("right",   4, 1),
    ("stereo",  2, 1),
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
	"SRC TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build_script():
    lines = []
    for tag, ms, ns in CASES:
        scal, setn = H.init_args(PRESETS, [("msrc", ms), ("nsrc", ns)])
        # both granulators playing, so the only thing under test is the source
        setn = setn + (",\n\t\t[0.0, ['/n_setn', 1001, \\gates, 8, 1,0,0,0,0,0,0,0]]"
                       ",\n\t\t[0.0, ['/n_setn', 1001, \\gates2, 8, 1,0,0,0,0,0,0,0]]")
        lines.append('\t~render.value("/tmp/sr_%s", [%s], [%s]); 1.5.wait;'
                     % (tag, scal, setn))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def chans(tag, t0=5.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/sr_%s.wav" % tag)
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    return x[int(t0 * sr):int(t1 * sr), 0], x[int(t0 * sr):int(t1 * sr), 1], sr


def rms(a):
    import numpy as np
    return float(np.sqrt(np.mean(a * a)))


def band(a, sr, lo, hi):
    """energy in a band, as an rms"""
    import numpy as np
    n = 8192
    acc = None
    for i in range(0, len(a) - n, n // 2):
        p = np.abs(np.fft.rfft(a[i:i + n] * np.hanning(n))) ** 2
        acc = p if acc is None else acc + p
    fr = np.fft.rfftfreq(n, 1 / sr)
    sel = (fr > lo) & (fr < hi)
    return float(acc[sel].sum())


def db(a, b):
    return 10 * math.log10(max(a, 1e-30) / max(b, 1e-30))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/src.scd", timeout=2400,
              expect="SRC TEST DONE")

    fails = []

    def check(c, m):
        if not c:
            fails.append(m)

    data = {}
    print("  %-8s %8s %8s   %9s %9s" % ("", "rms L", "rms R",
                                        "L: 3k/300", "R: 3k/300"))
    for tag, _, _ in CASES:
        l, r, sr = chans(tag)
        bl = db(band(l, sr, 2200, 4000), band(l, sr, 200, 450))
        br = db(band(r, sr, 2200, 4000), band(r, sr, 200, 450))
        data[tag] = (rms(l), rms(r), bl, br)
        print("  %-8s %8.5f %8.5f   %+9.1f %+9.1f"
              % (tag, rms(l), rms(r), bl, br))

    # 1. OFF captures nothing at all
    check(max(data["off"][0], data["off"][1]) < 1e-6,
          "SRC OFF still recorded something, so the default is 'quiet' "
          "rather than 'off'")

    # 2. STEREO KEEPS THE TWO ENDS APART. This is the whole claim: the source
    #    puts 300 Hz in the left and 3 kHz in the right, so a stereo capture
    #    has to come back low-heavy on the left and high-heavy on the right.
    #    A mono capture - which is what this was - gives both tones in both
    #    channels and both numbers land near zero.
    sl, sr_, sbl, sbr = data["stereo"]
    check(sbl < -12,
          "SRC STEREO: the LEFT output is %+.1f dB high-over-low, so the "
          "right input's 3 kHz is in the left channel - the capture is being "
          "summed to mono somewhere" % sbl)
    check(sbr > 12,
          "SRC STEREO: the RIGHT output is %+.1f dB high-over-low, so the "
          "left input's 300 Hz is in the right channel" % sbr)
    check(min(sl, sr_) > 0.002, "SRC STEREO produced silence in one channel")

    # 3. A MONO SOURCE IS CENTRED, not stacked against one speaker: MONO L
    #    has to come out of both, at about the same level, and carry only the
    #    left input's tone.
    ll, lr, lbl, lbr = data["left"]
    check(min(ll, lr) > 0.002, "SRC MONO L produced silence in one channel")
    check(abs(20 * math.log10(max(ll, 1e-9) / max(lr, 1e-9))) < 3.0,
          "SRC MONO L came out %.1f dB louder on one side - a mono source "
          "should be centred" % (20 * math.log10(max(ll, 1e-9) / max(lr, 1e-9))))
    check(max(lbl, lbr) < -12,
          "SRC MONO L let the right input's 3 kHz through (%+.1f / %+.1f dB)"
          % (lbl, lbr))

    rl, rr, rbl, rbr = data["right"]
    check(min(rbl, rbr) > 12,
          "SRC MONO R let the left input's 300 Hz through (%+.1f / %+.1f dB)"
          % (rbl, rbr))
    check(abs(20 * math.log10(max(rl, 1e-9) / max(rr, 1e-9))) < 3.0,
          "SRC MONO R is not centred")

    if fails:
        for f in fails:
            print("  FAIL " + f)
        print("SRC TEST FAILED (%d)" % len(fails))
        sys.exit(1)
    print("SRC TEST OK")
