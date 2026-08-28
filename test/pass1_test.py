"""Pass 1 engine features: buffer length + active window, and STRUM.

FILTRU used to be tested here as a comb bank. It is a formant bank now and has
its own file, test/filtru_test.py - this one stops at the granulator.

WINDOW is tested by recording a buffer whose first half is 220 Hz and second
half 660 Hz, freezing it, then parking the playhead at a fixed position. With
the window wide open that position lands in the first half; with the window
moved to the top half the SAME knob position must land in the second half.

STRUM is tested by counting grain onsets: at 0 the eight voices must fire as
one burst, opened up they must fan out across most of a grain period.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17, freq = 220, lvl = 0.3,
		noise = 0;
	var s = (SinOsc.ar(Lag.kr(freq, 0.001)) * lvl * (1 - noise))
		+ (PinkNoise.ar(lvl) * noise);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

SCRIPT = r'''
~render = { arg path, dur, args, events, gates;
	gates = gates ? [1,0,0,0,0,0,0,0];
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0,
			\mcontour, 8, \mspray, 0, \mswarm, 0, \mpattern, 0,
			\sfb, 0, \swet, 0, \sdiffuse, 0,
			\drive, 0, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
			\amp, 1.0] ++ args],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8] ++ gates]
	] ++ events ++ [
		[dur, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

// ---- WINDOW -------------------------------------------------------------
// 4 s loop: 220 Hz fills 0..2 s of it, 660 Hz fills 2..4 s. Frozen at 4.1 s.
~winargs = { arg lo, hi;
	[\mbuflen, 4, \mwinstart, lo, \mwinend, hi,
		\mrate, 20, \msize, 0.2, \mscanmode, 2, \mscan, 0.1, \mstrum, 0]
};
~winev = [[2.0, ['/n_set', 1000, \freq, 660]],
	[4.1, ['/n_set', 1001, \msos, 1]]];

// ---- STRUM --------------------------------------------------------------
// eight voices, one trigger every 0.5 s, tiny grains so onsets are countable
// mstrum is now a SUBDIVISION of the grain period per voice, not a spread:
// 0.125 means voice i fires i eighths of a period after the trigger.
~strumargs = { arg st;
	[\mbuflen, 4, \mrate, 2, \msize, 0.01, \mscanmode, 2, \mscan, 0.3,
		\mstrum, st]
};

fork {
	~render.value("/tmp/p_win0", 9.0, ~winargs.value(0, 1), ~winev); 1.5.wait;
	~render.value("/tmp/p_win5", 9.0, ~winargs.value(0.5, 1), ~winev); 1.5.wait;

	~render.value("/tmp/p_str0", 6.0, ~strumargs.value(0), [],
		[1,1,1,1,1,1,1,1]); 1.5.wait;
	~render.value("/tmp/p_str1", 6.0, ~strumargs.value(0.125), [],
		[1,1,1,1,1,1,1,1]); 1.5.wait;

	"PASS1 TEST DONE".postln;
	0.exit;
};
'''


def spec(path, t0, t1):
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = x.mean(axis=1)[int(t0 * sr):int(t1 * sr)]
    w = np.hanning(len(m))
    sp = np.abs(np.fft.rfft(m * w))
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    return fr, sp


def mag(fr, sp, f, rel=0.03):
    import numpy as np
    sel = (fr > f * (1 - rel)) & (fr < f * (1 + rel))
    return float(sp[sel].max()) if sel.any() else 0.0


def db(a, b):
    return 20 * math.log10(max(a, 1e-12) / max(b, 1e-12))


def onsets(path, t0, t1, thresh=0.01, refract=0.006):
    """Rising edges only: the envelope has to fall back below a quarter of the
    threshold before another onset counts, so one grain is one onset."""
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = np.abs(x).max(axis=1)[int(t0 * sr):int(t1 * sr)]
    # short smoothing so a grain's own zero crossings do not read as onsets
    k = max(1, int(0.0008 * sr))
    m = np.convolve(m, np.ones(k) / k, mode="same")
    out, armed, i, n = [], True, 0, len(m)
    hold = int(refract * sr)
    while i < n:
        if armed and m[i] > thresh:
            out.append(i / sr)
            armed = False
            i += hold
        elif m[i] < thresh * 0.25:
            armed = True
            i += 1
        else:
            i += 1
    return out


if __name__ == "__main__":
    import numpy as np
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/pass1.scd", timeout=1800,
              expect="PASS1 TEST DONE")
        print("rendered")

    print("\n=== WINDOW (frozen buffer, playhead parked at 0.1) ===")
    print("  window 0-1 should read 220 Hz, window 0.5-1 should read 660 Hz")
    for tag, label in [("p_win0", "window 0.0-1.0"), ("p_win5", "window 0.5-1.0")]:
        fr, sp = spec("/tmp/%s.wav" % tag, 6.0, 9.0)
        a, b = mag(fr, sp, 220), mag(fr, sp, 660)
        print(f"  {label}: 220 Hz {a:9.2f}   660 Hz {b:9.2f}   "
              f"660-220 {db(b, a):+6.1f} dB")

    print("\n=== STRUM (8 voices, 2 Hz, so a period is 500 ms) ===")
    for tag, label in [("p_str0", "strum OFF"), ("p_str1", "strum 1/8")]:
        # exactly one grain period, starting just before a trigger
        ev = onsets("/tmp/%s.wav" % tag, 4.0, 4.5)
        span = (ev[-1] - ev[0]) if len(ev) > 1 else 0.0
        gaps = [(ev[i + 1] - ev[i]) * 1000 for i in range(len(ev) - 1)]
        # every voice must land on an eighth of the period, not merely be
        # spread out: that is the difference between a rake and a phase-locked
        # rake, and only the gaps show it
        detail = ""
        if gaps:
            detail = (f"   gaps {min(gaps):.1f}-{max(gaps):.1f} ms"
                      f" (expect 62.5)")
        print(f"  {label}: {len(ev)} onsets in one period,"
              f" spanning {span*1000:6.1f} ms{detail}")

