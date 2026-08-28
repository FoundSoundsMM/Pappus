"""CRUSH mode LOSS: does it behave like a codec running out of bits?

Three things have to be true across the knob, and none of them is obvious from
the code:

  1. BANDWIDTH collapses - the spectral centroid and the -20 dB corner both
     come down, monotonically.
  2. HOLES appear - the spectrum gets patchy frame to frame rather than just
     quieter. Measured as the variance of each bin's level over time: a static
     lowpass has low variance, bins winking in and out has high variance.
  3. LEVEL does not run away. The knob should change character, not loudness.

Also checks that at CRUSH 0 the mode is transparent (bar the FFT's one window
of latency, which is delay-compensated in the blend but not removed).
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
// A grain-like broadband source with real transients, which is where codec
// artefacts actually live. A steady sine would hide all of them.
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	var trig = Impulse.ar(6);
	var env = EnvGen.ar(Env.perc(0.002, 0.14), trig);
	var s = (PinkNoise.ar(0.7) + (Saw.ar([180, 181.5]).sum * 0.25)) * env * 0.5;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, crush, mode;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			// granulator out of the way: LOSS is measured on the input
			\mcontour, 8, \mspray, 0, \mswarm, 0, \mstrum, 0, \mbuflen, 4,
			\drive, 0, \compress, 0, \tilt, 0, \noise, 0,
			\crush, crush, \crushmode, mode,
			\amp, 1.0, \limceil, 1.0,
			\fwet, 0, \swet, 0, \glev, 1]],
		[0.0, ['/n_setn', 1001, \gates, 8, 0,0,0,0,0,0,0,0]],
		[5.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
	// COLOUR is fully wet but the granulator is silent, so what reaches the
	// crush stage is the raw input. Patch the chain to feed it in.
	[0, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0].do { arg c, i;
		~render.value("/tmp/l_" ++ i, c, 4);
		1.2.wait;
	};
	~render.value("/tmp/l_ref", 0, 1); 1.2.wait;
	"LOSS TEST DONE".postln;
	0.exit;
};
'''

# The granulator is silent here, so route the input straight into COLOUR.
PATCH = [("dry = ssig;", "dry = in;")]

AMTS = [0, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0]


def frames(path, t0=1.0, t1=5.0, n=1024):
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = x.mean(axis=1)[int(t0 * sr):int(t1 * sr)]
    hop = n // 2
    w = np.hanning(n)
    out = []
    for i in range(0, len(m) - n, hop):
        out.append(np.abs(np.fft.rfft(m[i:i + n] * w)))
    fr = np.fft.rfftfreq(n, 1 / sr)
    return np.array(out), fr


def measure(path):
    import numpy as np
    S, fr = frames(path)
    P = S ** 2
    tot = P.sum(axis=1)
    live = P[tot > tot.max() * 0.02]           # ignore the gaps between hits
    if len(live) < 4:
        return None
    mean = live.mean(axis=0)
    centroid = float((fr * mean).sum() / max(mean.sum(), 1e-12))
    # -20 dB corner of the average spectrum
    ref = mean.max()
    idx = np.where(mean > ref * 0.01)[0]
    corner = float(fr[idx[-1]]) if len(idx) else 0.0
    rms = float(np.sqrt((S ** 2).sum(axis=1)).mean())
    return centroid, corner, S, fr, rms


def holes(path, ref):
    """Fraction of audible reference bins that this render has thrown away.

    This is the measurement that matters and the one a level or variance
    statistic cannot give: compare bin by bin against the untouched render and
    count what dropped by more than 20 dB. A static lowpass would show this
    only above its corner; a codec shows it scattered through the band, which
    is why the number is taken BELOW the surviving bandwidth.
    """
    import numpy as np
    A, fr = frames(path)
    B, _ = frames(ref)
    n = min(len(A), len(B))
    A, B = A[:n], B[:n]
    band = (fr > 200) & (fr < 4000)
    a, b = A[:, band], B[:, band]
    loud = b > b.max() * 0.005                 # only bins the reference had
    if loud.sum() == 0:
        return 0.0
    gone = loud & (a < b * 0.1)                # 20 dB down or worse
    return float(gone.sum()) / float(loud.sum())


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT, patches=PATCH), "/tmp/loss.scd",
              timeout=1800, expect="LOSS TEST DONE")
        print("rendered")

    print("\n=== CRUSH mode LOSS ===")
    print(f"  {'crush':>6}{'centroid':>10}{'-20dB':>9}{'holes<4k':>10}{'level':>9}")
    base = None
    for i, c in enumerate(AMTS):
        r = measure("/tmp/l_%d.wav" % i)
        if r is None:
            print(f"  {c:>6.2f}   (silent)")
            continue
        cen, cor, _S, _fr, rms = r
        if base is None:
            base = rms
        h = holes("/tmp/l_%d.wav" % i, "/tmp/l_0.wav") * 100
        print(f"  {c:>6.2f}{cen:>10.0f}{cor:>9.0f}{h:>9.0f}%"
              f"{20*math.log10(max(rms,1e-9)/max(base,1e-9)):>+9.1f}")

    r0 = measure("/tmp/l_0.wav")
    rr = measure("/tmp/l_ref.wav")
    print(f"\n  transparency at crush 0: centroid {r0[0]:.0f} Hz vs "
          f"BIT CRUSH at 0 {rr[0]:.0f} Hz")
