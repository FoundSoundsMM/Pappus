"""Verify sound-on-sound: the top of the knob must truly freeze the buffer,
and mid settings must layer new audio over retained old audio."""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~sine = SynthDef(\sinesrc, { arg outl = 16, outr = 17, freq = 220, lvl = 0.3;
	var s = SinOsc.ar(Lag.kr(freq, 0.001)) * lvl;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, dur, sos, events;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~sine.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \sinesrc, 1000, 0, 0, \outl, 16, \outr, 17, \freq, 220]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			\mrate, 25, \msize, 0.15, \mcontour, 8,
			\mscan, 0.15, \mscanmode, 2, \mspray, 0.08, \mspraymode, 1,
			\mpattern, 0, \msos, sos,
			\drive, 0, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
			\amp, 0.5]],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8, 1,0,0,0,0,0,0,0]]
	] ++ events ++ [
		[dur, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

fork {
	// ---- FREEZE ----
	// tone for 4 s then silence. with sos 0 the buffer is erased on the next
	// pass; with sos driven to 1 at t=4 it must survive.
	~render.value("/tmp/s_free", 13.0, 0,
		[[4.0, ['/n_set', 1000, \lvl, 0]]]);
	2.0.wait;
	~render.value("/tmp/s_froz", 13.0, 0,
		[[4.0, ['/n_set', 1000, \lvl, 0]], [4.0, ['/n_set', 1001, \msos, 1]]]);
	2.0.wait;

	// ---- LAYERING ----
	// 220 Hz for the first buffer pass, 330 Hz for the second.
	// sos 0 keeps only the new tone; sos 0.6 must keep both.
	~render.value("/tmp/s_lay0", 17.0, 0,
		[[8.2, ['/n_set', 1000, \freq, 330]]]);
	2.0.wait;
	~render.value("/tmp/s_lay6", 17.0, 0.6,
		[[8.2, ['/n_set', 1000, \freq, 330]]]);
	2.0.wait;

	"SOS TEST DONE".postln;
	0.exit;
};
'''


def tone(path, f, t0, t1):
    """Band ENERGY, not a single bin peak.

    SPRAY randomises where each grain reads from, so a one-bin measurement of
    this swings several dB between runs of identical code - which reads as a
    regression when it is only the dice. Integrating power across a +/-4% band
    over a long window averages that out; repeated runs now agree to a few
    tenths of a dB.
    """
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = x.mean(axis=1)[int(t0 * sr):int(t1 * sr)]
    if len(m) < 256:
        return None, None
    w = np.hanning(len(m))
    sp = np.abs(np.fft.rfft(m * w)) ** 2
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    sel = (fr > f * 0.96) & (fr < f * 1.04)
    return float(np.sqrt(sp[sel].sum())), float(np.sqrt((m ** 2).mean()))


if __name__ == "__main__":
    import numpy as np
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/sos.scd", timeout=900,
              expect="SOS TEST DONE")
        print("rendered")

    print("\n=== FREEZE (input silent from 4 s, measured 9-13 s) ===")
    for tag, label in [("s_free", "sos 0   (should erase)"),
                       ("s_froz", "sos 1   (should hold)")]:
        a, r = tone("/tmp/%s.wav" % tag, 220.0, 9.0, 13.0)
        print(f"  {label}:  220 Hz mag {a:.4f}   output rms {r:.5f}")

    print("\n=== LAYERING (220 Hz pass 1, 330 Hz pass 2, measured 13-17 s) ===")
    for tag, label in [("s_lay0", "sos 0.0"), ("s_lay6", "sos 0.6")]:
        a220, r = tone("/tmp/%s.wav" % tag, 220.0, 13.0, 17.0)
        a330, _ = tone("/tmp/%s.wav" % tag, 330.0, 13.0, 17.0)
        ratio = 20 * math.log10(max(a220, 1e-12) / max(a330, 1e-12))
        print(f"  {label}:  220 Hz {a220:.4f}   330 Hz {a330:.4f}   "
              f"old vs new {ratio:+6.1f} dB")
