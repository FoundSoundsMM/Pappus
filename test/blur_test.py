"""BLUR: is it a smear, or is it a vibrato?

Mick's report: "the blur seems to wobble a hell of a lot, can it be more
stable like a smearing? instead of a ghostly vibrato?"

The hypothesis to test is that BLUR lags the FREQUENCY estimate, and the
frequency estimate is noisy (ZeroCrossing on a bandpassed grain cloud jumps
around), so lagging it does not remove the movement - it just slows it down.
Fast jitter becomes slow drift, and slow drift in pitch IS vibrato.

The measurement: render the wet output at several BLUR settings, track the
dominant partial frame by frame, and report

  * how far the pitch moves, in cents (the wobble DEPTH)
  * how fast it moves (the wobble RATE - vibrato lives at 0.5..8 Hz)
  * how much the LEVEL moves (a smear should raise this ... no, LOWER it:
    smearing means overlapping, sustained energy, so amplitude gets steadier)

A real smear should show pitch deviation falling towards zero as BLUR rises,
while the amplitude envelope gets smoother. A vibrato shows pitch deviation
staying put or rising while the rate drops into the vibrato band.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

BLURS = [0.05, 0.25, 0.5, 0.75, 0.95]

PRESETS = [("p_wet", 1.0), ("s_wet", 0.0)]


def build_script():
    scal, setn = H.init_args(PRESETS)
    events = []
    for i, b in enumerate(BLURS):
        events.append(
            '\t~render.value("/tmp/b_%02d", [\\pblur, %.4f]); 1.5.wait;'
            % (i, b))
    return SCRIPT.replace("BASEARGS", scal) \
                 .replace("SETNS", setn) \
                 .replace("RENDERS", "\n".join(events))


SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	// something with real spectral content and a steady pitch: a sawtooth
	// chord plus a little noise, which is what the analysis actually meets.
	var s = Mix([Saw.ar(220, 0.10), Saw.ar(330, 0.07), Saw.ar(440, 0.05)])
		+ PinkNoise.ar(0.01);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, args;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0, BASEARGS] ++ args],
		SETNS
	] ++ [
		[10.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"BLUR TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def track(tag, t0=2.0, t1=9.5, n=4096, hop=1024):
    """Per-frame dominant frequency (cents, relative to the median) and level."""
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    win = np.hanning(n)
    fr = np.fft.rfftfreq(n, 1 / sr)
    lo, hi = np.searchsorted(fr, 80), np.searchsorted(fr, 6000)
    f, lvl = [], []
    for i in range(0, len(m) - n, hop):
        sp = np.abs(np.fft.rfft(m[i:i + n] * win))
        seg = sp[lo:hi]
        k = int(np.argmax(seg)) + lo
        # parabolic interpolation, so the track is not quantised to the bin grid
        if 0 < k < len(sp) - 1:
            a, b, c = (np.log(max(v, 1e-20)) for v in sp[k - 1:k + 2])
            d = 0.5 * (a - c) / max(a - 2 * b + c, 1e-12)
            d = max(min(d, 0.5), -0.5)
        else:
            d = 0.0
        f.append(fr[k] + d * (fr[1] - fr[0]))
        lvl.append(float(np.sqrt((m[i:i + n] ** 2).mean())))
    f = np.array(f)
    med = float(np.median(f))
    cents = 1200 * np.log2(np.maximum(f, 1e-6) / max(med, 1e-6))
    return cents, np.array(lvl), sr / hop


def wobble(cents, fps):
    """Depth in cents (robust) and the rate that dominates the movement."""
    import numpy as np
    c = cents - cents.mean()
    depth = float(np.percentile(np.abs(c), 90))
    w = c * np.hanning(len(c))
    sp = np.abs(np.fft.rfft(w))
    fq = np.fft.rfftfreq(len(w), 1 / fps)
    sel = (fq > 0.2) & (fq < 12)
    rate = float(fq[sel][np.argmax(sp[sel])]) if sel.any() else 0.0
    return depth, rate


if __name__ == "__main__":
    import numpy as np
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/blur.scd", timeout=1800,
              expect="BLUR TEST DONE")
        print("rendered")

    print("\n  BLUR   pitch wobble   rate      level ripple")
    print("  ----   ------------   -------   ------------")
    rows = []
    for i, b in enumerate(BLURS):
        cents, lvl, fps = track("b_%02d" % i)
        depth, rate = wobble(cents, fps)
        ripple = float(np.std(lvl) / max(np.mean(lvl), 1e-12))
        rows.append((b, depth, rate, ripple))
        print(f"  {b:4.2f}   {depth:8.0f} ct   {rate:4.1f} Hz   {ripple:10.3f}")

    print("\nwanted: wobble FALLS as BLUR rises (a smear holds still).")
    print("a vibrato shows wobble flat or rising with the rate dropping into")
    print("the 0.5-8 Hz band.")
    lo = rows[0][1]
    hi = rows[-1][1]
    print(f"\n  BLUR {rows[0][0]:.2f} -> {rows[-1][0]:.2f}: "
          f"{lo:.0f} ct -> {hi:.0f} ct")
    print("  VERDICT:", "smear (stable)" if hi < lo * 0.6 else "WOBBLE")
