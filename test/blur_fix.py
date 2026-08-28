"""Candidate fixes for the BLUR wobble, measured against the current build.

blur_probe.py established the fault: band 12's frequency control swings
1557 cents at BLUR 0.05 and still 195 cents at BLUR 0.75, with most of the
movement energy in the 0.5-8 Hz vibrato band. BLUR lags a noisy estimate,
and lagging noise does not remove it - it slows it down, and slow pitch
movement IS vibrato.

Three candidates, cumulative:

  A  CLAMP   the per-band estimate cannot legitimately fall outside that
             band's own passband - a partial an octave away belongs to a
             different band, which will report it. Clamping to +/-1.5 band
             half-widths caps the excursion at the band width by
             construction, which is 1557 ct -> about 340 ct at SPAN 3.
  B  MEDIAN  a 9-point median before the lag, which throws away the outlier
             zero-crossing counts rather than averaging them in.
  C  SPLIT   BLUR stops being one lag on both. Frequency settles fast and
             stays put (capped at 250 ms); AMPLITUDE gets the long one, up
             to 8 s. Smearing is energy persisting and overlapping, which is
             an amplitude property, not a pitch one.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

BLURS = [0.05, 0.5, 0.95]
PRESETS = [("m_rate", 8), ("m_size", 1.0),
           ("p_wet", 1.0), ("s_wet", 0.0)]

PROBE = [
    ("var fsum, fmix, fsend, fwt;",
     "var fsum, fmix, fsend, fwt, dbgf, dbga;"),
    ("o = Blip.ar(bfrq, pw, bamp * pgate[i] * pnorm);",
     "if (i == 4, { dbgf = bfrq; });\n"
     "if (i == 12, { dbga = bfrq; });\n"
     "o = Blip.ar(bfrq, pw, bamp * pgate[i] * pnorm);"),
    ("Out.ar(outbus, outsig);",
     "Out.ar(outbus, [K2A.ar(dbgf), K2A.ar(dbga)]);"),
]

RAW = "bfrq = A2K.kr(ZeroCrossing.ar(b));"
LAT = ("bfrq = Lag.kr(Latch.kr(bfrq, ptrig), plagt);\n"
       "\t\t\t\tbamp = Lag.kr(Select.kr(pfreeze, [bamp, Latch.kr(bamp, ptrig)]),\n"
       "\t\t\t\t\tplagt);")

# A: clamp to the band
CLAMP = [(RAW, RAW + "\n\t\t\t\tbfrq = bfrq.clip(cf / (2 ** (pspn * 1.5 / nband)),"
          " cf * (2 ** (pspn * 1.5 / nband)));")]
# B: clamp + median
MEDIAN = [(RAW, "bfrq = Median.kr(9, A2K.kr(ZeroCrossing.ar(b)));\n"
           "\t\t\t\tbfrq = bfrq.clip(cf / (2 ** (pspn * 1.5 / nband)),"
           " cf * (2 ** (pspn * 1.5 / nband)));")]
# C: clamp + median + split the lag
SPLIT = MEDIAN + [
    (LAT,
     "bfrq = Lag.kr(Latch.kr(bfrq, ptrig), pflag);\n"
     "\t\t\t\tbamp = Lag.kr(Select.kr(pfreeze, [bamp, Latch.kr(bamp, ptrig)]),\n"
     "\t\t\t\t\tplagt);"),
    ("plagt = 0.004 * ((2000) ** Lag.kr(pblur, lagt).clip(0, 1));",
     "plagt = 0.004 * ((2000) ** Lag.kr(pblur, lagt).clip(0, 1));\n"
     "\t\t\tpflag = 0.008 * ((30) ** Lag.kr(pblur, lagt).clip(0, 1));"),
    ("var pctr, pspn, plagt, ptrig, pimp, psstep, pw;",
     "var pctr, pspn, plagt, pflag, ptrig, pimp, psstep, pw;"),
]

VARIANTS = [("now", []), ("A clamp", CLAMP), ("B +median", MEDIAN),
            ("C +split", SPLIT)]

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
	"BLUR FIX DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build(tag):
    scal, setn = H.init_args(PRESETS)
    ev = ['\t~render.value("/tmp/%s_%02d", [\\pblur, %.4f]); 1.5.wait;'
          % (tag, i, b) for i, b in enumerate(BLURS)]
    return SCRIPT.replace("BASEARGS", scal).replace("SETNS", setn) \
                 .replace("RENDERS", "\n".join(ev))


def stats(tag, ch, t0=2.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    f = np.maximum(x[int(t0 * sr):int(t1 * sr), ch], 1e-6)
    ct = 1200 * np.log2(f / np.median(f))
    ct = ct - ct.mean()
    depth = float(np.percentile(np.abs(ct), 90))
    d = int(sr / 200)
    cd = ct[: (len(ct) // d) * d].reshape(-1, d).mean(axis=1)
    sp = np.abs(np.fft.rfft(cd * np.hanning(len(cd))))
    fq = np.fft.rfftfreq(len(cd), d / sr)
    sel = (fq > 0.15) & (fq < 20)
    vib = float((sp[(fq > 0.5) & (fq < 8)] ** 2).sum())
    tot = float((sp[sel] ** 2).sum())
    return depth, vib / max(tot, 1e-20)


if __name__ == "__main__":
    if "--render" in sys.argv:
        for n, (name, patches) in enumerate(VARIANTS):
            tag = "bf%d" % n
            H.run(H.build(SRC + build(tag), patches=PROBE + patches),
                  "/tmp/blurfix%d.scd" % n, timeout=1800,
                  expect="BLUR FIX DONE")
            print("rendered", name)

    for ch, cname in ((0, "band 4"), (1, "band 12")):
        print(f"\n  {cname} - pitch movement, cents (and %% of it at 0.5-8 Hz)")
        head = "  %-10s" % "variant" + "".join("   BLUR %.2f    " % b
                                               for b in BLURS)
        print(head)
        for n, (name, _) in enumerate(VARIANTS):
            row = "  %-10s" % name
            for i in range(len(BLURS)):
                depth, vib = stats("bf%d_%02d" % (n, i), ch)
                row += "  %6.0f ct %3.0f%%" % (depth, vib * 100)
            print(row)
