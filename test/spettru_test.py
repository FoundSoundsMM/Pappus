"""RESONATOR: is the bank actually tuned to the chord?

This is the claim the whole redesign rests on. The old spectral resynthesiser
put its oscillators wherever the zero-crossing counters landed, which for a
grain cloud is nowhere in particular - accurate, and unmusical. A resonator
bank rings where IT is tuned, so the test is simply: feed it noise and see
whether the peaks come out on the notes the grains are playing.

  * one grain at semitone 0 gives peaks on the harmonic series of C4
  * a grain a fifth up moves every peak by a fifth, ratios intact
  * STRUCTURE stretches the series - partial six lands well above 6x
  * BRIGHTNESS rolls the upper partials off; the fundamental is untouched
  * DAMPING lengthens the tail after the input stops
  * POSITION at 0.5 cancels the EVEN partials exactly - the textbook
    mode-shape-at-the-excitation-point result - and leaves the odd ones alone
  * STRING mode (a whole second, Karplus-Strong signal path) still lands its
    fundamental on the chord

Everything is rendered with a broadband source through the granulator, which
is what the bank actually meets in use. A resonator does not care what the
input's spectrum is, only that there is energy at its frequency, so noise is
the fairest excitation there is.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

C4 = 261.6256

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.25, gate = 1;
	var s = PinkNoise.ar(lvl) * gate;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# A continuous cloud: the bank wants steady excitation, not one grain every
# two seconds.
# WET at 1 in MIX mode replaces the dry path entirely, so what is measured is
# the bank alone. Muting the GRA fader would NOT do it: the fader sits on the
# granulator output and RESONATOR reads that same tap, so it would mute the
# exciter as well.
PRESETS = [("m_rate", 8), ("m_size", 1.0), ("p_wet", 1.0),
           ("s_wet", 0.0)]

SCRIPT = r'''
~render = { arg path, args, events;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0, BASEARGS] ++ args],
		SETNS
	] ++ events ++ [
		[9.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"RESONATOR TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''

# (tag, presets applied to the SCRIPT's own params before the args are read)
CASES = [
    ("root",   []),
    ("fifth",  [("m_pitch", 7)]),
    ("struct", [("p_structure", 0.8)]),
    ("dark",   [("p_bright", 0.05)]),
    ("bright", [("p_bright", 0.95)]),
    ("ringlo", [("p_damp", 0.02)]),
    ("ringhi", [("p_damp", 0.95)]),
    ("posmid", [("p_pos", 0.5)]),
    ("string", [("p_model", 2)]),
]
# the tail cases gate the source off at 5 s so the ring can be measured
TAIL = {"ringlo", "ringhi"}


def build_script():
    """One render per case. Each carries the arg string its own params give."""
    lines, setns = [], None
    for tag, pre in CASES:
        scal, setn = H.init_args(PRESETS + pre)
        setns = setn
        extra = ("[[5.0, ['/n_set', 1000, \\gate, 0]]]"
                 if tag in TAIL else "[]")
        lines.append('\t~render.value("/tmp/sp_%s", %s, [%s], %s); 1.5.wait;'
                     % (tag, "[" + scal + "]", setn, extra))
    body = SCRIPT.replace("\\inbusl, 16, \\inbusr, 17, \\outbus, 0, BASEARGS] ++ args",
                          "\\inbusl, 16, \\inbusr, 17, \\outbus, 0] ++ args")
    body = body.replace("~render = { arg path, args, events;",
                        "~render = { arg path, args, setns, events;")
    body = body.replace("\t\tSETNS\n\t] ++ events", "\t] ++ setns ++ events")
    return body.replace("RENDERS", "\n".join(lines))


def spec(tag, t0=2.5, t1=8.5, n=16384):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    acc, cnt = None, 0
    for i in range(0, len(m) - n, n // 2):
        w = m[i:i + n] * np.hanning(n)
        p = np.abs(np.fft.rfft(w)) ** 2
        acc = p if acc is None else acc + p
        cnt += 1
    return np.fft.rfftfreq(n, 1 / sr), acc / max(cnt, 1)


def peak_near(fr, sp, f, rel=0.04, floor=0.0):
    """Where the energy in +/-rel of f actually sits, in cents from f.

    The CENTROID, not the argmax. A resonator driven by pink noise has a
    skirt several bins wide and a sloping noise floor under it, so the single
    loudest bin wanders by tens of cents run to run - at 261 Hz, 50 cents is
    under three bins. The centroid of the same peak does not.
    """
    import numpy as np
    sel = (fr > f * (1 - rel)) & (fr < f * (1 + rel))
    if not sel.any():
        return 0.0, 999.0
    w = np.maximum(sp[sel] - floor, 0.0)
    if w.sum() <= 0:
        return 0.0, 999.0
    got = float((fr[sel] * w).sum() / w.sum())
    return float(w.max()), 1200 * math.log2(max(got, 1e-9) / f)


def level(fr, sp, f, rel=0.04):
    import numpy as np
    sel = (fr > f * (1 - rel)) & (fr < f * (1 + rel))
    return float(sp[sel].sum()) if sel.any() else 0.0


def db(a, b):
    return 10 * math.log10(max(a, 1e-30) / max(b, 1e-30))


def tail(tag, t0=5.05, t1=8.5):
    """RMS in windows after the source stops, as a fraction of pre-stop."""
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    pre = np.sqrt((m[int(4.0 * sr):int(5.0 * sr)] ** 2).mean())
    # how long until it falls 40 dB below the sustained level
    thr = pre * 0.01
    step = int(sr * 0.02)
    for i in range(int(t0 * sr), min(int(t1 * sr), len(m)) - step, step):
        if np.sqrt((m[i:i + step] ** 2).mean()) < thr:
            return (i / sr) - 5.0
    return t1 - 5.0


if __name__ == "__main__":
    import numpy as np
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/spettru.scd",
              timeout=2400, expect="RESONATOR TEST DONE")
        print("rendered")

    fails = []

    print("\n=== is the bank on the chord? (MODAL, default) ===")
    fr, sp = spec("sp_root")
    floor = float(np.median(sp[(fr > 60) & (fr < 8000)]))
    for k in range(1, 7):
        f = C4 * k
        amp, cents = peak_near(fr, sp, f, floor=floor)
        d = db(level(fr, sp, f), floor)
        ok = "ok" if (abs(cents) < 45 and d > 12) else "FAIL"
        if ok == "FAIL":
            fails.append("partial %d: %+.0f cents, %+.1f dB over floor"
                         % (k, cents, d))
        print(f"  partial {k}  {f:7.1f} Hz   {cents:+5.0f} cents"
              f"   {d:+6.1f} dB over floor   {ok}")

    print("\n=== a fifth up moves the whole bank ===")
    fr, sp = spec("sp_fifth")
    r = 2 ** (7 / 12)
    for k in (1, 2, 3):
        f = C4 * k * r
        _, cents = peak_near(fr, sp, f, floor=floor)
        ok = "ok" if abs(cents) < 45 else "FAIL"
        if ok == "FAIL":
            fails.append("fifth, partial %d off by %+.0f cents" % (k, cents))
        print(f"  partial {k}  {f:7.1f} Hz   {cents:+5.0f} cents   {ok}")

    print("\n=== STRUCTURE stretches the series ===")
    fr, sp = spec("sp_struct")
    want = C4 * (6 ** (1 + (0.8 * 0.45)))
    _, cents = peak_near(fr, sp, want, rel=0.06, floor=floor)
    d = db(level(fr, sp, want, 0.06), floor)
    ok = "ok" if (abs(cents) < 90 and d > 8) else "FAIL"
    if ok == "FAIL":
        fails.append("stretched partial 6 not at %.0f Hz (%+.0f cents, %+.1f dB)"
                     % (want, cents, d))
    print(f"  partial 6 stretched to {want:7.1f} Hz   {cents:+5.0f} cents"
          f"   {d:+6.1f} dB   {ok}")
    d6 = db(level(fr, sp, C4 * 6), floor)
    print(f"  ...and 6x C4 ({C4*6:.0f} Hz) is now only {d6:+.1f} dB over floor")

    print("\n=== BRIGHTNESS rolls the top off, leaves the fundamental alone ===")
    frd, spd = spec("sp_dark")
    frb, spb = spec("sp_bright")
    d1 = db(level(frd, spd, C4), level(frb, spb, C4))
    d6 = db(level(frd, spd, C4 * 6), level(frb, spb, C4 * 6))
    ok1 = "ok" if abs(d1) < 6 else "FAIL"
    ok6 = "ok" if d6 < -18 else "FAIL"
    if ok1 == "FAIL":
        fails.append("BRIGHTNESS moved the fundamental %+.1f dB - it should "
                     "be untouched (falloff^0 = 1)" % d1)
    if ok6 == "FAIL":
        fails.append("BRIGHTNESS dark vs bright only moved partial 6 by "
                     "%+.1f dB" % d6)
    print(f"  partial 1, dark vs bright   {d1:+6.1f} dB   {ok1}")
    print(f"  partial 6, dark vs bright   {d6:+6.1f} dB   {ok6}")

    print("\n=== DAMPING is a ring time ===")
    lo, hi = tail("sp_ringlo"), tail("sp_ringhi")
    ok = "ok" if hi > lo * 3 else "FAIL"
    if ok == "FAIL":
        fails.append("ring times too close: %.2f s vs %.2f s" % (lo, hi))
    print(f"  DAMP 0.02  tail to -40 dB  {lo:5.2f} s")
    print(f"  DAMP 0.95  tail to -40 dB  {hi:5.2f} s   {ok}")

    print("\n=== POSITION at 0.5 cancels the even partials exactly ===")
    fr, sp = spec("sp_posmid")
    for k in range(1, 7):
        f = C4 * k
        d = db(level(fr, sp, f), floor)
        even = (k % 2 == 0)
        ok = "ok" if ((even and d < 6) or ((not even) and d > 10)) else "FAIL"
        if ok == "FAIL":
            fails.append("POSITION 0.5, partial %d (%s): %+.1f dB over floor"
                         % (k, "even" if even else "odd", d))
        print(f"  partial {k} ({'even' if even else 'odd '})"
              f"   {d:+6.1f} dB over floor   {ok}")

    print("\n=== STRING mode still lands on the chord ===")
    fr, sp = spec("sp_string")
    amp, cents = peak_near(fr, sp, C4, floor=floor)
    d = db(level(fr, sp, C4), floor)
    ok = "ok" if (abs(cents) < 60 and d > 8) else "FAIL"
    if ok == "FAIL":
        fails.append("STRING fundamental: %+.0f cents, %+.1f dB over floor"
                     % (cents, d))
    print(f"  fundamental  {C4:7.1f} Hz   {cents:+5.0f} cents"
          f"   {d:+6.1f} dB over floor   {ok}")

    if fails:
        print("\n".join(["\nFAILURES:"] + ["  " + f for f in fails]))
        print("RESONATOR TEST FAILED")
        sys.exit(1)
    print("\nRESONATOR OK")
