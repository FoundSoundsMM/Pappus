"""DELAY: echoes must land exactly on the tap times, pan where told, and
feedback must repeat the whole pattern one cycle later, decaying."""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~clk = SynthDef(\clik, { arg outl = 16, outr = 17;
	// one short click at 0.5 s, so echo arrival times are unambiguous
	var trig = TDelay.ar(Impulse.ar(0), 0.5);
	var e = EnvGen.ar(Env.perc(0.0005, 0.004), trig);
	var s = SinOsc.ar(1500) * e * 0.8;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# Baqbaq has no dry path any more, so bypass the granulator to test the delay
# on its own. This is the only way to see clean impulse arrivals.
# Two patch points now: the delay is fed from SIGNAL's send tap, not from the
# dry path, so both have to be redirected to the raw input.
PATCH = [("sfeed = presig * Select.kr(sendpre, [gl, 1]);", "sfeed = in;"),
         ("sdry = msig;", "sdry = in;")]

SCRIPT = r'''
~render = { arg path, args, times, levels, pans;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~clk.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \clik, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			\drive, 0, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
			\amp, 1.0] ++ args],
		[0.0, ['/n_setn', 1001, \taptimes, 8] ++ times],
		[0.0, ['/n_setn', 1001, \taplevels, 8] ++ levels],
		[0.0, ['/n_setn', 1001, \tappans, 8] ++ pans],
		[4.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

~t4 = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8];
~l4 = [1, 1, 1, 1, 0, 0, 0, 0];
~mono = [0, 0, 0, 0, 0, 0, 0, 0];
~wide = [-1, 1, -0.7, 0.7, 0, 0, 0, 0];

fork {
	// taps only, no feedback, SEND so the dry click is visible as t=0
	~render.value("/tmp/d_taps",
		[\scycle, 0.4, \sfb, 0, \sdiffuse, 0, \swet, 1, \shold, 0],
		~t4, ~l4, ~mono);
	1.5.wait;

	// same, panned
	~render.value("/tmp/d_pan",
		[\scycle, 0.4, \sfb, 0, \sdiffuse, 0, \swet, 1, \shold, 0],
		~t4, ~l4, ~wide);
	1.5.wait;

	// feedback: the whole pattern should repeat one cycle later, quieter
	~render.value("/tmp/d_fb",
		[\scycle, 0.5, \sfb, 0.6, \sdiffuse, 0, \swet, 1, \shold, 0],
		~t4, ~l4, ~mono);
	1.5.wait;

	// diffusion should smear a click into a tail rather than leave it a spike
	~render.value("/tmp/d_diff",
		[\scycle, 0.4, \sfb, 0, \sdiffuse, 1, \swet, 1, \shold, 0],
		~t4, ~l4, ~mono);
	1.5.wait;

	"DELAY TEST DONE".postln;
	0.exit;
};
'''


def arrivals(path, thresh=0.02):
    """Return (time, peak) of each transient in the mono sum."""
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = np.abs(x).max(axis=1)
    out, i, n = [], 0, len(m)
    while i < n:
        if m[i] > thresh:
            j = min(n, i + int(0.02 * sr))
            k = i + int(np.argmax(m[i:j]))
            out.append((k / sr, float(m[k])))
            i = i + int(0.03 * sr)
        else:
            i += 1
    return out, sr


if __name__ == "__main__":
    import numpy as np, soundfile as sf
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT, patches=PATCH), "/tmp/stillel.scd",
              timeout=900, expect="DELAY TEST DONE")
        print("rendered")

    print("\n=== tap arrival times (click at 0.500 s, taps at 0.1/0.2/0.3/0.4) ===")
    ev, sr = arrivals("/tmp/d_taps.wav")
    base = ev[0][0] if ev else 0
    print(f"{'arrival':>9}{'offset':>9}{'expected':>10}{'error ms':>10}{'peak':>8}")
    expect = [0.0, 0.1, 0.2, 0.3, 0.4]
    for i, (t, p) in enumerate(ev[:5]):
        e = expect[i] if i < len(expect) else float("nan")
        print(f"{t:>9.4f}{t-base:>9.4f}{e:>10.4f}{(t-base-e)*1000:>10.2f}{p:>8.4f}")

    print("\n=== pan: per-tap channel balance (taps hard L / R / -0.7 / +0.7) ===")
    x, sr = sf.read("/tmp/d_pan.wav")
    ev, _ = arrivals("/tmp/d_pan.wav")
    for i, (t, _) in enumerate(ev[1:5]):
        a = int((t - 0.004) * sr); b = int((t + 0.02) * sr)
        l = float(np.sqrt((x[a:b, 0] ** 2).mean()))
        r = float(np.sqrt((x[a:b, 1] ** 2).mean()))
        bal = 20 * math.log10(max(r, 1e-9) / max(l, 1e-9))
        print(f"  tap {i+1}: L {l:.4f}  R {r:.4f}   R-L {bal:+6.1f} dB")

    print("\n=== feedback: pattern should repeat one cycle (0.5 s) later ===")
    ev, _ = arrivals("/tmp/d_fb.wav", 0.01)
    base = ev[0][0]
    for t, p in ev[:10]:
        print(f"  {t-base:.4f} s  peak {p:.4f}")

    print("\n=== diffuse: click energy should spread in time ===")
    for tag, label in [("d_taps", "diffuse 0"), ("d_diff", "diffuse 1")]:
        x, sr = sf.read("/tmp/%s.wav" % tag)
        m = np.abs(x).max(axis=1)
        a = int(0.60 * sr); b = int(0.68 * sr)      # around the first echo
        seg = m[a:b]
        pk = seg.max()
        spread = float((seg > pk * 0.1).sum()) / sr * 1000
        print(f"  {label}: peak {pk:.4f}, energy above -20dB spans {spread:.1f} ms")
