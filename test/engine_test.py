"""Engine-level checks: DRIVE harmonic content, and MOSAIC granulation."""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~sine = SynthDef(\sinesrc, { arg outl = 16, outr = 17, freq = 220, lvl = 0.25;
	var s = SinOsc.ar(freq) * lvl;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, dur, args, pit, gat;
	pit = pit ? [0,0,0,0,0,0,0,0];
	gat = gat ? [1,0,0,0,0,0,0,0];
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~sine.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \sinesrc, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000] ++ args],
		[0.0, ['/n_setn', 1001, \pitches, 8] ++ pit],
		[0.0, ['/n_setn', 1001, \gates, 8] ++ gat],
		[dur, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

~base = [\inbusl, 16, \inbusr, 17, \outbus, 0,
	\compress, 0, \crush, 0, \tilt, 0, \noise, 0,
	\amp, 0.5];

fork {
	// --- DRIVE harmonics ---
	[0, 30, 60, 100].do { arg d;
		~render.value("/tmp/h_" ++ d, 2.0, ~base ++ [\drive, d / 100]);
		1.0.wait;
	};

	// --- MOSAIC: fixed position, one voice, unison then +12 then a chord ---
	~render.value("/tmp/g_uni", 8.0, ~base ++ [
		\drive, 0, \mrate, 20, \msize, 0.2, \mcontour, 8,
		\mscan, 0.5, \mscanmode, 2, \mspray, 0, \mpattern, 0],
		[0,0,0,0,0,0,0,0], [1,0,0,0,0,0,0,0]);
	1.5.wait;

	~render.value("/tmp/g_oct", 8.0, ~base ++ [
		\drive, 0, \mrate, 20, \msize, 0.2, \mcontour, 8,
		\mscan, 0.5, \mscanmode, 2, \mspray, 0, \mpattern, 0],
		[12,0,0,0,0,0,0,0], [1,0,0,0,0,0,0,0]);
	1.5.wait;

	~render.value("/tmp/g_chord", 8.0, ~base ++ [
		\drive, 0, \mrate, 20, \msize, 0.2, \mcontour, 8,
		\mscan, 0.5, \mscanmode, 2, \mspray, 0, \mpattern, 0],
		[0,7,12,0,0,0,0,0], [1,1,1,0,0,0,0,0]);
	1.5.wait;

	// --- MOSAIC: spray should decorrelate the stereo field ---
	~render.value("/tmp/g_spray", 8.0, ~base ++ [
		\drive, 0, \mrate, 30, \msize, 0.15, \mcontour, 8,
		\mscan, 0.5, \mscanmode, 2, \mspray, 0.8, \mspraymode, 1],
		[0,0,0,0,0,0,0,0], [1,0,0,0,0,0,0,0]);
	1.5.wait;

	// --- MOSAIC: all voices muted should be silent ---
	~render.value("/tmp/g_mute", 8.0, ~base ++ [
		\drive, 0, \mrate, 20, \msize, 0.2,
		\mscan, 0.5, \mscanmode, 2],
		[0,0,0,0,0,0,0,0], [0,0,0,0,0,0,0,0]);
	1.5.wait;

	"ENGINE TEST DONE".postln;
	0.exit;
};
'''


def peaks(path, t0, t1, n=6):
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = x.mean(axis=1)[int(t0 * sr):int(t1 * sr)]
    w = np.hanning(len(m))
    sp = np.abs(np.fft.rfft(m * w))
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    idx = np.argsort(sp)[::-1]
    out, used = [], []
    for i in idx:
        if fr[i] < 20:
            continue
        if any(abs(fr[i] - u) < 15 for u in used):
            continue
        used.append(fr[i])
        out.append((float(fr[i]), float(sp[i])))
        if len(out) >= n:
            break
    return out, sr


def harmonic_report(path, f0=220.0):
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = x.mean(axis=1)[int(0.5 * sr):]
    w = np.hanning(len(m))
    sp = np.abs(np.fft.rfft(m * w))
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    def at(f):
        i = np.argmin(np.abs(fr - f))
        return float(sp[max(0, i - 2):i + 3].max())
    fund = at(f0)
    return [20 * math.log10(max(at(f0 * k), 1e-12) / max(fund, 1e-12))
            for k in range(1, 7)]


if __name__ == "__main__":
    import numpy as np, soundfile as sf
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/engtest.scd", timeout=900,
              expect="ENGINE TEST DONE")
        print("rendered")

    print("\n=== DRIVE harmonic content (dB relative to fundamental) ===")
    print(f"{'drive':>6} " + "".join(f"{'H'+str(k):>8}" for k in range(1, 7)))
    for d in [0, 30, 60, 100]:
        h = harmonic_report("/tmp/h_%d.wav" % d)
        print(f"{d/100:>6.2f} " + "".join(f"{v:>8.1f}" for v in h))
    print("H2/H4/H6 are the even (tube-ish) harmonics")

    print("\n=== MOSAIC granulation (dominant partials, 6-8 s) ===")
    for name, label in [("g_uni", "1 voice, unison"),
                        ("g_oct", "1 voice, +12"),
                        ("g_chord", "3 voices, 0/+7/+12")]:
        pk, sr = peaks("/tmp/%s.wav" % name, 6.0, 8.0, 4)
        tot = max(p[1] for p in pk)
        shown = [f"{p[0]:.0f}Hz({20*math.log10(p[1]/tot):+.0f}dB)"
                 for p in pk if p[1] / tot > 0.08]
        print(f"  {label:<22} {' '.join(shown)}")

    x, sr = sf.read("/tmp/g_spray.wav")
    seg = x[int(6 * sr):]
    print("\n  spray on, L/R correlation: %.3f (lower = wider)"
          % float(np.corrcoef(seg[:, 0], seg[:, 1])[0, 1]))

    x, _ = sf.read("/tmp/g_mute.wav")
    print("  all gates 0, output rms: %.6f (want ~0)"
          % float(np.sqrt((x[int(6 * sr):] ** 2).mean())))
