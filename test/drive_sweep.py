"""Measure the DRIVE stage's gain across the knob, so the makeup polynomial
can hold loudness roughly flat (colour, not volume)."""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

DRIVES = [0, 125, 250, 375, 500, 625, 750, 875, 1000]

SRC = r'''
~srcDef = SynthDef(\srcx, { arg outl = 16, outr = 17;
	var s = PinkNoise.ar(1.294!2);   // about -18 dBFS rms
	Out.ar(outl, s[0]); Out.ar(outr, s[1]);
});
'''

SCRIPT = r'''
~mk = { arg drv, path;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~srcDef.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcx, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			
			\drive, drv, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
			\amp, 0.3]],
		[3.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
	DRIVELIST.do { arg d;
		~mk.value(d / 1000, "/tmp/drv_" ++ d);
		1.2.wait;
	};
	"DRIVE SWEEP DONE".postln;
	0.exit;
};
'''


# COLOUR's input is the granulator, which is always fully wet - so with the
# envelope buffers left unfilled this test was measuring silence and quietly
# reporting a division by zero. Feed the raw input into COLOUR instead: the
# DRIVE stage is what is under test, not the grains in front of it.
FEED = [("dry = ssig;", "dry = in;")]


def sweep(patches, tag):
    script = SCRIPT.replace("DRIVELIST", str(DRIVES).replace(" ", ""))
    text = H.build(SRC + script, patches=FEED + list(patches), fill_env=False)
    H.run(text, "/tmp/%s.scd" % tag, timeout=300, expect="DRIVE SWEEP DONE")


def measure():
    import numpy as np, soundfile as sf
    out = []
    for d in DRIVES:
        x, sr = sf.read("/tmp/drv_%d.wav" % d)
        m = x[int(0.5 * sr):]           # skip the settling ramp
        out.append((d / 1000.0,
                    float(np.sqrt((m ** 2).mean())),
                    float(np.abs(m).max())))
    return out


if __name__ == "__main__":
    import numpy as np
    stage = sys.argv[1] if len(sys.argv) > 1 else "fit"
    if stage == "fit":
        sweep([("dy = dy * mk;", "dy = dy * 1;"),
               ("sig = XFade2.ar(sig, dy, ((dr * 4).clip(0, 1) * 2) - 1);",
                "sig = dy;")], "drv_fit")
        rows = measure()
        base = rows[0][1]
        print("drive   rms      peak    gain(dB)  needed makeup")
        drs, needed = [], []
        for dr, rms, pk in rows:
            g = rms / base
            print("%5.3f  %.5f  %.4f  %+7.2f   %6.3f"
                  % (dr, rms, pk, 20 * math.log10(g), 1 / g))
            drs.append(dr); needed.append(1 / g)
        # cubic fit in dr
        c = np.polyfit(drs, needed, 3)
        print("\nmakeup ~ %.5f + %.5f*dr + %.5f*dr^2 + %.5f*dr^3"
              % (c[3], c[2], c[1], c[0]))
        print("SC: mk = %.5f + (dr * %.5f) + (dr.squared * %.5f) + ((dr ** 3) * %.5f);"
              % (c[3], c[2], c[1], c[0]))
        fitted = np.polyval(c, drs)
        print("fit residual (dB): " +
              " ".join("%+.2f" % (20 * math.log10(f / n))
                       for f, n in zip(fitted, needed)))
    else:
        sweep([("sig = XFade2.ar(sig, dy, ((dr * 4).clip(0, 1) * 2) - 1);",
                "sig = dy;")], "drv_check")
        rows = measure()
        base = rows[0][1]
        print("drive   rms      peak    level vs clean (dB)")
        for dr, rms, pk in rows:
            print("%5.3f  %.5f  %.4f   %+6.2f"
                  % (dr, rms, pk, 20 * math.log10(rms / base)))
