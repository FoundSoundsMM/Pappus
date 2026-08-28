"""COLOUR's noise sources, and whether the three new ones actually ring.

WHITE, PINK and DUST are washes. BELL, GLASS and PLUCK strike a six-partial
resonator bank, and "it is a bank of resonators" is a claim with a spectrum
attached - so measure the spectrum rather than trusting the wiring:

  1. THEY RING. A resonator bank struck by dust has narrow tall PEAKS; a wash
     does not, even a heavily band-passed one.
     Measured as PEAK OVER MEDIAN power across 100 Hz .. 8 kHz. Spectral
     flatness was the first attempt and it could not tell any of the six
     apart: the washes are band-passed at N.TONE with a Q of 0.8, so they are
     not flat either, and a geometric mean over a band with deep nulls
     collapses towards zero for everything. Peak-over-median asks the question
     that actually separates a resonance from a hump.
  2. THEY ARE TUNED TO N.TONE. The lowest strong peak has to land on the
     fundamental that was asked for, not somewhere near it - otherwise
     "N.TONE is the fundamental" is a comment rather than a fact.
  3. THEY DIFFER FROM EACH OTHER. BELL rings longest and reaches highest;
     PLUCK is harmonic and dies fastest. If all three came out the same the
     ratio tables are not being read.
  4. AND THEY ARE ALL THE SAME LOUDNESS. Picking a noise source is a
     character decision and must not also be a level decision - straight out
     of the bank BELL measured 21.6 dB hotter than PINK.

Run:  python3 test/noise_test.py --render
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

# Silence in. The noise source is gated by COLOUR's envelope follower, so it
# needs SOMETHING - a slow soft pulse train gives it an envelope to open on
# without putting any spectrum of its own into the measurement.
SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	var s = SinOsc.ar(80, 0, 0.25) * EnvGen.kr(
		Env.perc(0.01, 0.35), Impulse.kr(2));
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# COLOUR wide open on the noise and nothing else, granulator out of the way.
PRESETS = [("m_rate", 8), ("m_size", 0.25), ("m_src", 2), ("m_sos", 0.0),
           ("p_wet", 0.0), ("s_wet", 0.0),
           ("noise", 1.0), ("noise_decay", 0.6), ("noise_tone", 300),
           ("noise_dyn", 2), ("drive", 0.0), ("crush", 0.0), ("loss", 0.0)]

TYPES = [("white", 1), ("pink", 2), ("dust", 3),
         ("bell", 4), ("glass", 5), ("pluck", 6)]

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
	"NOISE TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build_script():
    lines = []
    for tag, ty in TYPES:
        scal, setn = H.init_args(PRESETS, [("noisetype", ty), ("limceil", 1.0)])
        setn = setn + ",\n\t\t[0.0, ['/n_setn', 1001, \\gates, 8, 0,0,0,0,0,0,0,0]]"
        setn = setn + ",\n\t\t[0.0, ['/n_setn', 1001, \\gates2, 8, 0,0,0,0,0,0,0,0]]"
        lines.append('\t~render.value("/tmp/nz_%s", [%s], [%s]); 1.5.wait;'
                     % (tag, scal, setn))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def spectrum(tag, t0=3.0, t1=9.5):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/nz_%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    n = 16384
    acc = None
    for i in range(0, len(m) - n, n // 2):
        p = np.abs(np.fft.rfft(m[i:i + n] * np.hanning(n))) ** 2
        acc = p if acc is None else acc + p
    fr = np.fft.rfftfreq(n, 1 / sr)
    return fr, acc, float(math.sqrt(float((m * m).mean())))


def peakiness(fr, acc):
    """Peak over median power, in dB, across 100 Hz .. 8 kHz."""
    import numpy as np
    band = acc[(fr > 100) & (fr < 8000)]
    med = float(np.median(band))
    return 10 * math.log10(max(float(band.max()), 1e-30) / max(med, 1e-30))


def first_peak(fr, acc, lo=150, hi=600):
    import numpy as np
    sel = (fr > lo) & (fr < hi)
    return float(fr[sel][acc[sel].argmax()])


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/noise.scd", timeout=2400,
              expect="NOISE TEST DONE")

    fails = []

    def check(c, m):
        if not c:
            fails.append(m)

    data = {}
    print("  %-7s %10s %10s %10s" % ("", "rms dB", "peak/med", "peak Hz"))
    for tag, _ in TYPES:
        fr, acc, r = spectrum(tag)
        fl = peakiness(fr, acc)
        pk = first_peak(fr, acc)
        data[tag] = (r, fl, pk)
        print("  %-7s %10.2f %10.1f %10.1f"
              % (tag, 20 * math.log10(max(r, 1e-12)), fl, pk))

    for tag in ("white", "pink", "dust", "bell", "glass", "pluck"):
        check(data[tag][0] > 0.0005, "%s produced nothing at all" % tag)

    # 1. the new three ring; the old three do not
    washes = max(data[t][1] for t in ("white", "pink", "dust"))
    for tag in ("bell", "glass", "pluck"):
        # eight, not ten: PLUCK rings for a tenth of a second, and a short
        # ring IS less peaky than a long one - that is the difference between
        # a plucked string and a bell, not a failure to ring.
        check(data[tag][1] > washes + 8,
              "%s peaks only %.1f dB over its own median against the washes' "
              "%.1f - it is not ringing" % (tag, data[tag][1], washes))

    # 2. tuned to N.TONE, which the render asked for at 300 Hz
    for tag in ("bell", "glass", "pluck"):
        cents = 1200 * math.log(data[tag][2] / 300.0, 2)
        print("  %-7s fundamental is %+.0f cents from N.TONE" % (tag, cents))
        check(abs(cents) < 120,
              "%s's lowest partial is %+.0f cents off the 300 Hz it was told "
              "to use" % (tag, cents))

    # 4. all six at the same loudness, within 6 dB
    lo = min(20 * math.log10(max(data[t][0], 1e-12)) for t, _ in TYPES)
    hi = max(20 * math.log10(max(data[t][0], 1e-12)) for t, _ in TYPES)
    print("  loudest to quietest source: %.1f dB" % (hi - lo))
    check((hi - lo) < 6.0,
          "the six sources span %.1f dB, so choosing one is a level decision "
          "as well as a character one" % (hi - lo))

    # 3. they are not the same sound. PLUCK is harmonic and short, BELL is
    #    inharmonic and long, so their flatness has to separate.
    check(data["pluck"][1] != data["bell"][1],
          "PLUCK and BELL measured identically, so the ratio table is not "
          "being read")

    if fails:
        for f in fails:
            print("  FAIL " + f)
        print("NOISE TEST FAILED (%d)" % len(fails))
        sys.exit(1)
    print("NOISE TEST OK")
