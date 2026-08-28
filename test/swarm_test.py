"""SWARM: duplicates must be silent at 0, land on the right intervals per mode,
detune into a measurable bandwidth, and widen the stereo image."""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

F0 = 220.0

SRC = r'''
~sine = SynthDef(\sinesrc, { arg outl = 16, outr = 17;
	var s = SinOsc.ar(220) * 0.3;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, swarm, smode, spray;
	spray = spray ? 0.06;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~sine.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \sinesrc, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			\mrate, 25, \msize, 0.18, \mcontour, 8,
			\mscan, 0.15, \mscanmode, 2, \mspray, spray, \mspraymode, 1,
			\mpattern, 0, \msos, 0,
			\mswarm, swarm, \mswarmmode, smode,
			\drive, 0, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
			\amp, 0.5]],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8, 1,0,0,0,0,0,0,0]],
		[9.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
	~render.value("/tmp/w_off",     0.0, 1); 1.5.wait;
	~render.value("/tmp/w_detune",  1.0, 1); 1.5.wait;
	~render.value("/tmp/w_fifth",   1.0, 2); 1.5.wait;
	~render.value("/tmp/w_oct",     1.0, 3); 1.5.wait;
	~render.value("/tmp/w_5oct",    1.0, 4); 1.5.wait;
	~render.value("/tmp/w_half",    0.5, 1); 1.5.wait;
	~render.value("/tmp/w_octsp",   1.0, 3, 0.5); 1.5.wait;
	"SWARM TEST DONE".postln;
	0.exit;
};
'''


def spectrum(tag, t0=6.0, t1=9.0):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    seg = x[int(t0 * sr):int(t1 * sr)]
    m = seg.mean(axis=1)
    w = np.hanning(len(m))
    sp = np.abs(np.fft.rfft(m * w))
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    return fr, sp, seg, sr


def mag(fr, sp, f, halfwidth=2.0):
    import numpy as np
    sel = (fr > f - halfwidth) & (fr < f + halfwidth)
    return float(sp[sel].max()) if sel.any() else 0.0


def bandwidth(fr, sp, f, span=40.0):
    """-6 dB width of the cluster around f, in Hz."""
    import numpy as np
    sel = (fr > f - span) & (fr < f + span)
    band, freqs = sp[sel], fr[sel]
    pk = band.max()
    over = freqs[band > pk * 0.5]
    return float(over.max() - over.min()) if len(over) else 0.0


def db(a, b):
    return 20 * math.log10(max(a, 1e-12) / max(b, 1e-12))


if __name__ == "__main__":
    import numpy as np
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/swarm.scd", timeout=900,
              expect="SWARM TEST DONE")
        print("rendered")

    ivs = {"-12": F0 * 2 ** (-1), "-7": F0 * 2 ** (-7 / 12), "0": F0,
           "+7": F0 * 2 ** (7 / 12), "+12": F0 * 2}

    print("\n=== partial levels, dB relative to the unison partial ===")
    print(f"{'':<20}" + "".join(f"{k:>9}" for k in ivs) + f"{'bw@220':>9}{'rms':>9}")
    base_rms = None
    for tag, label in [("w_off", "swarm 0"), ("w_half", "swarm 0.5 DETUNE"),
                       ("w_detune", "swarm 1 DETUNE"), ("w_fifth", "swarm 1 5TH"),
                       ("w_oct", "swarm 1 OCT"), ("w_5oct", "swarm 1 5TH+OCT"),
                       ("w_octsp", "OCT, spray 0.5")]:
        fr, sp, seg, sr = spectrum(tag)
        ref = mag(fr, sp, F0, F0 * 0.055)
        row = "".join(f"{db(mag(fr, sp, f, f * 0.035), ref):>9.1f}" for f in ivs.values())
        bw = bandwidth(fr, sp, F0)
        rms = float(np.sqrt((seg ** 2).mean()))
        if base_rms is None:
            base_rms = rms
        print(f"{label:<20}{row}{bw:>9.1f}{rms:>9.4f}")

    print("\n=== level and stereo width ===")
    for tag, label in [("w_off", "swarm 0"), ("w_half", "swarm 0.5"),
                       ("w_detune", "swarm 1")]:
        fr, sp, seg, sr = spectrum(tag)
        rms = float(np.sqrt((seg ** 2).mean()))
        corr = float(np.corrcoef(seg[:, 0], seg[:, 1])[0, 1])
        print(f"  {label:<12} rms {rms:.4f} ({db(rms, base_rms):+5.1f} dB)"
              f"   L/R correlation {corr:+.3f}")
