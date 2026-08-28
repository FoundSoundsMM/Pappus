"""COLOUR: CRUSH and LOSS are in SERIES, not in parallel.

They used to be parallel - LOSS ran on the compressed signal, CRUSH ran on the
compressed signal, and a crossfade picked between them. So at CRUSH 1 the LOSS
knob did nothing at all: the crossfade had already thrown that side away.

The discriminator is bandwidth. LOSS brick-walls the top off; CRUSH does the
opposite, quantisation noise is broadband hash. So:

  parallel   CRUSH 1 + LOSS 1 looks like CRUSH alone - top end intact
  series     CRUSH 1 + LOSS 1 looks like LOSS  - top end gone, and the hash
             crush made is gone with it, because loss had to encode it

Four renders: neither, crush alone, loss alone, both.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.22;
	var s = PinkNoise.ar(lvl);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# COLOUR fully wet on a continuous cloud, nothing else in the way
PRESETS = [("m_rate", 8), ("m_size", 1.0), ("p_wet", 0.0), ("s_wet", 0.0),
           ("drive", 0.0), ("compress", 0.0),
           ("noise", 0.0)]

CASES = [
    ("none",  [("crush", 0.0), ("loss", 0.0)]),
    ("crush", [("crush", 1.0), ("loss", 0.0)]),
    ("loss",  [("crush", 0.0), ("loss", 1.0)]),
    ("both",  [("crush", 1.0), ("loss", 1.0)]),
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
		[9.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"SERIES TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build_script():
    lines = []
    for tag, pre in CASES:
        scal, setn = H.init_args(PRESETS + pre)
        lines.append('\t~render.value("/tmp/se_%s", [%s], [%s]); 1.5.wait;'
                     % (tag, scal, setn))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def spec(tag, t0=3.0, t1=8.5, n=8192):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    acc = None
    for i in range(0, len(m) - n, n // 2):
        p = np.abs(np.fft.rfft(m[i:i + n] * np.hanning(n))) ** 2
        acc = p if acc is None else acc + p
    return np.fft.rfftfreq(n, 1 / sr), acc


def band(fr, sp, lo, hi):
    return float(sp[(fr > lo) & (fr < hi)].sum())


def db(a, b):
    return 10 * math.log10(max(a, 1e-30) / max(b, 1e-30))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/series.scd",
              timeout=1800, expect="SERIES TEST DONE")
        print("rendered")

    fails = []
    S, hf, mid = {}, {}, {}
    for tag, _ in CASES:
        fr, sp = spec("se_" + tag)
        S[tag] = (fr, sp)
        hf[tag] = band(fr, sp, 8000, 20000)
        mid[tag] = band(fr, sp, 200, 2000)

    print("\n  top end (8k+) relative to the mid band")
    for tag, _ in CASES:
        print(f"  {tag:<6} {db(hf[tag], mid[tag]):+7.1f} dB")

    print("\n  does LOSS still bite once CRUSH is up?")
    d = db(hf["both"] / max(mid["both"], 1e-30),
           hf["crush"] / max(mid["crush"], 1e-30))
    ok = "ok" if d < -6 else "FAIL"
    if ok == "FAIL":
        fails.append("adding LOSS on top of CRUSH changed the top end by only "
                     "%+.1f dB - they are still parallel" % d)
    print(f"  CRUSH+LOSS vs CRUSH alone: {d:+.1f} dB of top end   {ok}")

    print("\n  ...and does CRUSH still bite under LOSS?")
    import numpy as np
    fr = S["loss"][0]
    a, b = S["loss"][1], S["both"][1]
    a = a / max(a.sum(), 1e-30)
    b = b / max(b.sum(), 1e-30)
    diff = float(np.abs(a - b).sum())
    ok2 = "ok" if diff > 0.05 else "FAIL"
    if ok2 == "FAIL":
        fails.append("CRUSH under LOSS changed the spectrum by only %.3f"
                     % diff)
    print(f"  normalised spectral difference {diff:.3f}   {ok2}")

    print("\n  and the top end really is being removed, not just moved")
    d2 = db(hf["loss"] / max(mid["loss"], 1e-30),
            hf["none"] / max(mid["none"], 1e-30))
    ok3 = "ok" if d2 < -6 else "FAIL"
    if ok3 == "FAIL":
        fails.append("LOSS alone only took %+.1f dB off the top" % d2)
    print(f"  LOSS vs clean: {d2:+.1f} dB   {ok3}")

    if fails:
        print("\n".join(["\nFAILURES:"] + ["  " + f for f in fails]))
        print("SERIES TEST FAILED")
        sys.exit(1)
    print("\nSERIES OK")
