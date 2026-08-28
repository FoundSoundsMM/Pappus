"""TILT: the pre-buffer EQ actually tilts, and it tilts the BUFFER.

Pre-buffer is the whole point, so there are two claims and the second is the
one worth measuring: turning the knob changes the balance of what comes out,
AND the change survives the knob being put back to flat - because by then it
is baked into the recording.
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

# a continuous cloud reading a buffer that has been recording the whole time
PRESETS = [("m_rate", 8), ("m_size", 1.0), ("p_wet", 0.0), ("s_wet", 0.0)]

CASES = [("flat", 0.0), ("bass", -1.0), ("treb", 1.0)]

SCRIPT = r'''
~render = { arg path, args, setns, events;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0] ++ args]
	] ++ setns ++ events ++ [
		[10.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
RENDERS
	"TILT TEST DONE".postln;
	0.5.wait;
	1.exit;
};
'''


def build_script():
    lines = []
    for tag, t in CASES:
        scal, setn = H.init_args(PRESETS, [("mtilt", t)])
        lines.append('\t~render.value("/tmp/tl_%s", [%s], [%s], []); 1.5.wait;'
                     % (tag, scal, setn))
    # BAKED: record with the tilt on, then flatten it at 5 s and LOCK the
    # buffer, so what is heard after that is the recording, not the filter
    scal, setn = H.init_args(PRESETS, [("mtilt", -1.0)])
    lines.append('\t~render.value("/tmp/tl_baked", [%s], [%s], '
                 '[[5.0, [\\n_set, 1001, \\mtilt, 0]], '
                 '[5.0, [\\n_set, 1001, \\mlock, 1]]]); 1.5.wait;' % (scal, setn))
    return SCRIPT.replace("RENDERS", "\n".join(lines))


def balance(tag, t0, t1):
    """High band over low band, in dB."""
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = x.mean(axis=1) if x.ndim > 1 else x
    m = m[int(t0 * sr):int(t1 * sr)]
    n = 8192
    acc = None
    for i in range(0, len(m) - n, n // 2):
        p = np.abs(np.fft.rfft(m[i:i + n] * np.hanning(n))) ** 2
        acc = p if acc is None else acc + p
    fr = np.fft.rfftfreq(n, 1 / sr)
    lo = float(acc[(fr > 80) & (fr < 400)].sum())
    hi = float(acc[(fr > 1500) & (fr < 7000)].sum())
    return 10 * math.log10(max(hi, 1e-30) / max(lo, 1e-30))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + build_script()), "/tmp/tilt.scd",
              timeout=1800, expect="TILT TEST DONE")
        print("rendered")

    fails = []
    print("\n  high/low balance of the output")
    b = {}
    for tag, t in CASES:
        b[tag] = balance("tag" if False else "tl_" + tag, 3.0, 9.0)
        print(f"  TILT {t:+.1f}   {b[tag]:+7.1f} dB")
    span = b["treb"] - b["bass"]
    ok = "ok" if span > 14 else "FAIL"
    if ok == "FAIL":
        fails.append("the knob only spans %.1f dB" % span)
    print(f"\n  the knob spans {span:+.1f} dB   {ok}")
    for tag, want in (("bass", -1), ("treb", 1)):
        d = b[tag] - b["flat"]
        good = (d < -5) if want < 0 else (d > 5)
        if not good:
            fails.append("%s is only %+.1f dB from flat" % (tag, d))
        print(f"  {tag} is {d:+.1f} dB from flat   {'ok' if good else 'FAIL'}")

    print("\n  and it is baked into the BUFFER, not the output:")
    before = balance("tl_baked", 3.0, 4.8)
    after = balance("tl_baked", 6.0, 9.5)
    d = after - b["flat"]
    ok = "ok" if d < -4 else "FAIL"
    if ok == "FAIL":
        fails.append("flattening the knob undid the tilt (%+.1f dB from flat)"
                     % d)
    print(f"  recorded tilted, knob then flat and buffer locked:")
    print(f"    while recording {before:+7.1f} dB")
    print(f"    after           {after:+7.1f} dB   ({d:+.1f} vs a flat "
          f"recording)   {ok}")

    if fails:
        print("\n".join(["\nFAILURES:"] + ["  " + f for f in fails]))
        print("TILT TEST FAILED")
        sys.exit(1)
    print("\nTILT OK")
