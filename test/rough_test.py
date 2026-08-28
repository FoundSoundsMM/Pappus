"""Where does the roughness come from?

"Rough" is not a number, so this turns it into one: play a PURE SINE through
the granulator and measure everything that comes out which is not a harmonic
of it. A granulator makes sidebands at the grain rate no matter what - that is
inherent and musical - so the absolute figure means little. What means
something is the DIFFERENCE between two builds on identical settings.

Variants, each a patched SynthDef:

  base    exactly as shipped
  cubic   GrainBuf interpolation 2 -> 4
  nowob   the master WOBBLE stage taken out
  both    cubic and no wobble

Transposition is where interpolation error lives, so the same measurement runs
at 0, +7 and -12 semitones. At unity a linear interpolator is exact and the
whole question is invisible - which is why a test at default pitch would have
said everything was fine.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.5;
	var s = SinOsc.ar(1000, 0, lvl);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

INTERP_A = "2 ** (base / 12), pos, 2, pan, envsel, 16);"
INTERP_B = "2 ** (base / 12), pos, 4, pan, envsel, 16);"
WOB_A = "outsig = DelayC.ar(outsig, 0.02, Lag.kr(0.01 + mxwob, 0.02));"
WOB_B = "outsig = DelayC.ar(outsig, 0.02, 0.01);"

VARIANTS = {
    "base":  [],
    "cubic": [(INTERP_A, INTERP_B)],
    "nowob": [(WOB_A, WOB_B)],
    "both":  [(INTERP_A, INTERP_B), (WOB_A, WOB_B)],
}

# A dense cloud on a locked buffer: long overlapping grains, so what is being
# measured is playback quality and not the grain envelope's own spectrum.
BASE = [("m_rate", 8), ("m_size", 2.0), ("m_contour", 0.0),
        ("p_wet", 0.0), ("s_wet", 0.0),
        ("drive", 0.0), ("compress", 0.0), ("crush", 0.0), ("loss", 0.0),
        ("noise", 0.0), ("m_spray", 0.0), ("m_swarm", 0.0),
        ("m_scan_mode", 2), ("m_scan", 0.5),
        # A SHORT buffer, or the parked playhead reads a stretch that was
        # never recorded: at the 8 s default, position 0.5 is four seconds in
        # and the lock lands at three, so every render came back silent.
        ("m_buflen", 2.0)]

PITCH = [("p0", 0), ("p7", 7), ("pm12", -12)]

SCRIPT = r'''
~render = { arg path, args, setns;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0] ++ args]
	] ++ setns ++ [
		// lock the buffer at 3 s so what is granulated is a clean recording
		[4.0, [\n_set, 1001, \mlock, 1]],
		[9.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"ROUGH TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def render_all():
    for tag, patches in VARIANTS.items():
        lines = []
        for pt, semi in PITCH:
            scal, setn = H.init_args(BASE + [("m_pitch", semi)])
            lines.append('\t~render.value("/tmp/ro_%s_%s", [%s], [%s]); 1.5.wait;'
                         % (tag, pt, scal, setn))
        body = SCRIPT.replace("RENDERS", "\n".join(lines))
        H.run(H.build(SRC + body, patches=patches),
              "/tmp/rough_%s.scd" % tag, timeout=1200,
              expect="ROUGH TEST DONE")


def junk(tag, f0, t0=5.0, t1=8.5, n=32768):
    """Fraction of the energy that is NOT within 1.5% of a harmonic of f0."""
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    acc = None
    for i in range(0, len(m) - n, n // 2):
        p = np.abs(np.fft.rfft(m[i:i + n] * np.hanning(n))) ** 2
        acc = p if acc is None else acc + p
    fr = np.fft.rfftfreq(n, 1 / sr)
    sel = (fr > 40) & (fr < 20000)
    tot = float(acc[sel].sum())
    if tot <= 0:
        return None
    harm = np.zeros_like(acc, dtype=bool)
    k = 1
    while f0 * k < 20000:
        harm |= (fr > f0 * k * 0.985) & (fr < f0 * k * 1.015)
        k += 1
    bad = float(acc[sel & ~harm].sum())
    return 10 * math.log10(max(bad, 1e-30) / tot)


if __name__ == "__main__":
    if "--render" in sys.argv:
        render_all()
        print("rendered")

    print("\n  inharmonic energy, dB below the total (lower is cleaner)")
    print("  %-7s %9s %9s %9s" % ("", "unity", "+7 st", "-12 st"))
    rows = {}
    for tag in VARIANTS:
        vals = []
        for pt, semi in PITCH:
            f0 = 1000 * (2 ** (semi / 12))
            vals.append(junk("ro_%s_%s" % (tag, pt), f0))
        rows[tag] = vals
        print("  %-7s %9s %9s %9s" % (tag,
              *["%.1f" % v if v is not None else "silent" for v in vals]))

    print("\n  what each change is worth, in dB of junk removed")
    for tag in ("cubic", "nowob", "both"):
        d = [rows["base"][i] - rows[tag][i] for i in range(3)
             if rows["base"][i] is not None and rows[tag][i] is not None]
        if d:
            print("  %-7s %s" % (tag,
                  "  ".join("%+.1f" % v for v in d)))
