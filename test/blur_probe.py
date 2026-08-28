"""BLUR, measured at the source.

blur_test.py tracks the loudest partial of the OUTPUT, which hops between
sixteen independent oscillators and reports a wobble that is mostly the
tracker changing its mind. This one patches the SynthDef so the output IS
band 8's frequency control, in Hz, written to the left channel, and its
amplitude to the right. No spectral estimation, no ambiguity: this is the
number the oscillator is being handed.

  left  = bfrq for band 8, in Hz
  right = bamp for band 8, x1000
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

BLURS = [0.05, 0.25, 0.5, 0.75, 0.95]
# A CONTINUOUS cloud, not the script's default of half a grain per second.
# At the defaults FILTERBANK is looking at near-silence most of the time, which
# measures as enormous ripple that has nothing to do with BLUR.
PRESETS = [("m_rate", 8), ("m_size", 1.0),
           ("p_wet", 1.0), ("s_wet", 0.0)]

PATCHES = [
    ("var fsum, fmix, fsend, fwt;",
     "var fsum, fmix, fsend, fwt, dbgf, dbga;"),
    ("o = Blip.ar(bfrq, pw, bamp * pgate[i] * pnorm);",
     "if (i == 4, { dbgf = bfrq; });\n"
     "if (i == 12, { dbga = bfrq; });\n"
     "o = Blip.ar(bfrq, pw, bamp * pgate[i] * pnorm);"),
    ("Out.ar(outbus, outsig);",
     "Out.ar(outbus, [K2A.ar(dbgf), K2A.ar(dbga)]);"),
]

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
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
	"BLUR PROBE DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build_script(tagbase="bp"):
    scal, setn = H.init_args(PRESETS)
    ev = ['\t~render.value("/tmp/%s_%02d", [\\pblur, %.4f]); 1.5.wait;'
          % (tagbase, i, b) for i, b in enumerate(BLURS)]
    return SCRIPT.replace("BASEARGS", scal).replace("SETNS", setn) \
                 .replace("RENDERS", "\n".join(ev))


def stats(tag, ch=0, t0=2.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    f = x[int(t0 * sr):int(t1 * sr), ch]
    a = f
    f = np.maximum(f, 1e-6)
    ct = 1200 * np.log2(f / np.median(f))
    ct = ct - ct.mean()
    depth = float(np.percentile(np.abs(ct), 90))
    # movement rate: decimate to 200 Hz, spectrum of the cents track
    d = int(sr / 200)
    cd = ct[: (len(ct) // d) * d].reshape(-1, d).mean(axis=1)
    w = cd * np.hanning(len(cd))
    sp = np.abs(np.fft.rfft(w))
    fq = np.fft.rfftfreq(len(w), d / sr)
    sel = (fq > 0.15) & (fq < 20)
    rate = float(fq[sel][np.argmax(sp[sel])])
    # how much of the movement sits in the vibrato band, 0.5-8 Hz
    tot = float((sp[(fq > 0.15) & (fq < 20)] ** 2).sum())
    vib = float((sp[(fq > 0.5) & (fq < 8)] ** 2).sum())
    aripple = float(np.std(a) / max(np.mean(a), 1e-12))
    return depth, rate, vib / max(tot, 1e-20), aripple


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script(), patches=PATCHES),
              "/tmp/blurprobe.scd", timeout=1800, expect="BLUR PROBE DONE")
        print("rendered")

    for ch, name in ((0, "band 4"), (1, "band 12")):
        print(f"\n  {name}")
        print("  BLUR   pitch move   dominant   in 0.5-8 Hz")
        print("  ----   ----------   --------   -----------")
        for i, b in enumerate(BLURS):
            depth, rate, vib, ar = stats("bp_%02d" % i, ch)
            print(f"  {b:4.2f}   {depth:7.0f} ct   {rate:5.2f} Hz   "
                  f"{vib*100:8.0f} %")
