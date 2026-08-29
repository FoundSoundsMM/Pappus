"""Does every stage actually make a sound when you turn its WET up?

This exists because FILTERBANK (RESONATOR's predecessor) did not. Its default SLICE is CONT, which sends
2000 Hz; `Impulse.kr` above the control rate outputs 1 on every block and never
returns to zero; `Latch` triggers on a RISING edge, so it saw one at time zero
and then held its initial value - zero - for ever. The page was silent out of
the box, and shipped that way twice.

Every other test in this suite hardcoded its engine arguments, so none of them
were looking at the value the script actually sends. This one asks the script:
`harness.init_args` runs the real Lua against the mock, lets `init()` do
whatever it does, and reports what the engine was told. Then it turns each
stage's WET to full - again through the script, not by hand - and measures.

The assertion is deliberately blunt. Not "is it the right level", not "is the
spectrum correct": is there a sound at all. That is the failure this class of
bug produces, and it is the one no amount of careful DSP measurement caught,
because every careful measurement was made with arguments the device never
sees.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
// something with both a partial and a broadband floor, so every stage has
// material to work with
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, lvl = 0.25;
	var s = PinkNoise.ar(lvl) + SinOsc.ar(440, 0, lvl);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, args, setn;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0] ++ args]
	] ++ setn ++ [
		[7.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"WET TEST DONE".postln;
	0.exit;
};
'''

# (tag, label, the params:set calls that turn this stage up, through the script)
CASES = [
    ("dry",  "nothing wet (reference)", []),
    ("spec", "RESONATOR wet, MODAL",   [("p_wet", "1.0")]),
    # This was silent for two versions. A held amplitude is a held ZERO
    # whenever the latch lands between grains, which at a 4 Hz slice is most
    # of the time. SLICE now holds the PITCHES only.
    ("specs", "RESONATOR wet, FREE frequency", [("p_wet", "1.0"), ("p_freqmode", "2")]),
    ("specn", "RESONATOR wet, dark/centred", [("p_wet", "1.0"), ("p_bright", "0.05"),
                                               ("p_pos", "0.5")]),
    ("specq", "RESONATOR wet, DAMPING long", [("p_wet", "1.0"), ("p_damp", "0.9")]),
    # STRING is a whole second signal path (Karplus-Strong voices, no
    # DynKlank at all) - it needs its own "is there a sound" check.
    ("specf", "RESONATOR wet, STRING mode", [("p_wet", "1.0"), ("p_model", "2")]),
    ("stil", "DELAY wet",   [("s_wet", "1.0"), ("s_euclid", "0.5")]),
    ("kul",  "COLOUR wet + drive", [("drive", "0.6")]),
    ("all",  "all three wet", [("p_wet", "0.7"), ("s_wet", "0.7"),
                               ("drive", "0.5")]),
    # TRIQ. Every order has to make a sound, and the reordered ones have to
    # sound DIFFERENT from the default - otherwise the routing is decorative.
    ("r1", "TRIQ SPE>STI>KUL", [("p_wet", "0.7"), ("s_wet", "0.7"),
                                ("drive", "0.5"), ("route", "1")]),
    ("r4", "TRIQ STI>KUL>SPE", [("p_wet", "0.7"), ("s_wet", "0.7"),
                                ("drive", "0.5"), ("route", "4")]),
    ("r6", "TRIQ KUL>STI>SPE", [("p_wet", "0.7"), ("s_wet", "0.7"),
                                ("drive", "0.5"), ("route", "6")]),
]


def build_script():
    lines = []
    for tag, _, presets in CASES:
        args, setn = H.init_args(presets=presets)
        lines.append('\t~render.value("/tmp/wt_%s", [%s],\n\t\t[%s]); 1.5.wait;'
                     % (tag, args, setn))
    return SRC + SCRIPT.replace("RENDERS", "\n".join(lines))


def rms(tag, t0=3.0, t1=7.0):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/wt_%s.wav" % tag)
    return float(np.sqrt((x[int(t0 * sr):int(t1 * sr)] ** 2).mean()))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(build_script()), "/tmp/wet.scd", timeout=1800,
              expect="WET TEST DONE")
        print("rendered")

    fails = []
    ref = rms("dry")
    print("\n=== is there a sound at all? ===")
    print("  every setting reached through the script's own params, not by hand")
    print(f"  {'nothing wet (reference)':<34} rms {ref:.5f}")
    for tag, label, _ in CASES[1:]:
        r = rms(tag)
        d = 20 * math.log10(max(r, 1e-12) / max(ref, 1e-12))
        # a stage that is on must be within shouting distance of the dry level.
        # -20 dB is not a level assertion, it is a "did anything happen"
        # assertion: the failure this catches measured -60 dB.
        known = "[KNOWN]" in label
        ok = "ok" if d > -20 else ("known" if known else "FAIL")
        if ok == "FAIL":
            fails.append("%s is %.1f dB below dry - effectively silent" %
                         (label, d))
        print(f"  {label:<34} rms {r:.5f}   {d:+6.1f} dB vs dry   {ok}")

    print("\n=== and the orders differ from each other ===")
    import numpy as np, soundfile as sf
    def wav(t):
        x, sr = sf.read("/tmp/wt_%s.wav" % t)
        return x[int(3.0 * sr):int(7.0 * sr)]
    a = wav("r1")
    for tag, label in [("r4", "STI>KUL>SPE"), ("r6", "KUL>STI>SPE")]:
        b = wav(tag)
        n = min(len(a), len(b))
        d = float(np.sqrt(((a[:n] - b[:n]) ** 2).mean()))
        ref = float(np.sqrt((a[:n] ** 2).mean()))
        rel = 20 * math.log10(max(d, 1e-12) / max(ref, 1e-12))
        ok = "ok" if rel > -20 else "FAIL"
        if ok == "FAIL":
            fails.append("%s is indistinguishable from the default order" % label)
        print(f"  vs default: {label:<14} difference {rel:+6.1f} dB   {ok}")

    print()
    if fails:
        print("FAILURES:")
        for f in fails:
            print("  - " + f)
        sys.exit(1)
    print("WET OK")
