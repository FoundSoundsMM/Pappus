"""Per-voice level and probability, and the transport-sync trigger.

LEVEL rides in the existing `gates` array, so the check is that a fractional
gate scales that voice's contribution rather than muting it or ignoring it.

PROBABILITY thins the trigger stream. All eight voices share one random number
read through different fixed offsets, so the thing worth verifying is not just
that a low probability drops grains but that the voices drop *independently* -
a shared coin would make them all fire or all fall silent together, which
would sound like a stutter rather than a thinning.

SYNC has to restart the grain phase: after a t_sync the next grain must land
immediately, not wherever the free-running phasor happened to be.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	var s = SinOsc.ar(300) * 0.4;
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

BASE = r'''\mcontour, 8, \mspray, 0, \mswarm, 0, \mpattern, 0, \mstrum, 0,
	\mbuflen, 4, \msize, 0.02, \mscanmode, 2, \mscan, 0.3,
	\drive, 0, \compress, 0, \crush, 0, \tilt, 0, \noise, 0,
	\fwet, 0, \swet, 0, \amp, 1.0, \limceil, 1.0'''

SCRIPT = r'''
~render = { arg path, args, gates, probs, events;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0, BASEARGS] ++ args],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8] ++ gates],
		[0.0, ['/n_setn', 1001, \probs, 8] ++ probs]
	] ++ events ++ [
		[8.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

~on1 = [1,0,0,0,0,0,0,0];
~all = [1,1,1,1,1,1,1,1];
~p1  = [1,1,1,1,1,1,1,1];

fork {
	// LEVEL: one voice, full then half
	~render.value("/tmp/v_full", [\mrate, 12], ~on1, ~p1, []); 1.2.wait;
	~render.value("/tmp/v_half", [\mrate, 12], [0.5,0,0,0,0,0,0,0], ~p1, []);
	1.2.wait;

	// PROBABILITY: eight voices, strummed apart so each one's grains are
	// individually countable, at three probabilities
	~render.value("/tmp/v_p100", [\mrate, 4, \mstrum, 0.9], ~all, ~p1, []);
	1.2.wait;
	~render.value("/tmp/v_p50", [\mrate, 4, \mstrum, 0.9], ~all,
		[0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5], []); 1.2.wait;
	~render.value("/tmp/v_p10", [\mrate, 4, \mstrum, 0.9], ~all,
		[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1], []); 1.2.wait;

	// SYNC at 3.35 s: with a 2 s period the next grain would not be due until
	// 4 s, so a grain at 3.35 can only have come from the reset
	~render.value("/tmp/v_sync", [\mrate, 0.5], ~on1, ~p1,
		[[3.35, ['/n_set', 1001, \t_sync, 1]]]); 1.2.wait;
	~render.value("/tmp/v_free", [\mrate, 0.5], ~on1, ~p1, []); 1.2.wait;

	"VOICE TEST DONE".postln;
	0.exit;
};
'''.replace("BASEARGS", BASE)


def onsets(tag, t0, t1, thresh=0.008, refract=0.004):
    path = tag + ".wav"
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    m = np.abs(x).max(axis=1)[int(t0 * sr):int(t1 * sr)]
    k = max(1, int(0.0006 * sr))
    m = np.convolve(m, np.ones(k) / k, mode="same")
    out, armed, i, n = [], True, 0, len(m)
    hold = int(refract * sr)
    while i < n:
        if armed and m[i] > thresh:
            out.append(t0 + (i / sr))
            armed = False
            i += hold
        elif m[i] < thresh * 0.25:
            armed = True
            i += 1
        else:
            i += 1
    return out


def rms(tag, t0=2.0, t1=8.0):
    path = tag + ".wav"
    import numpy as np, soundfile as sf
    x, sr = sf.read(path)
    seg = x[int(t0 * sr):int(t1 * sr)]
    return float(np.sqrt((seg ** 2).mean()))


def db(a, b):
    return 20 * math.log10(max(a, 1e-12) / max(b, 1e-12))


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/voice.scd", timeout=1800,
              expect="VOICE TEST DONE")
        print("rendered")

    print("\n=== per-voice LEVEL (gates carries it) ===")
    f, h = rms("/tmp/v_full"), rms("/tmp/v_half")
    print(f"  gate 1.0 rms {f:.5f}")
    print(f"  gate 0.5 rms {h:.5f}   ({db(h, f):+.1f} dB, expect about -6)")

    print("\n=== per-voice PROBABILITY (8 voices, strummed apart) ===")
    base = len(onsets("/tmp/v_p100", 2.0, 8.0))
    for tag, label, want in [("/tmp/v_p100", "prob 1.0", 1.0),
                             ("/tmp/v_p50", "prob 0.5", 0.5),
                             ("/tmp/v_p10", "prob 0.1", 0.1)]:
        n = len(onsets(tag, 2.0, 8.0))
        print(f"  {label}: {n:4d} grains   {n/max(base,1)*100:5.1f}% of full"
              f"   (expect ~{want*100:.0f}%)")

    # independence: if every voice shared one coin, a fired trigger would fire
    # all eight, so grains would arrive in full strums of eight or not at all.
    ev = onsets("/tmp/v_p50", 2.0, 8.0)
    period = 0.25
    buckets = {}
    for t in ev:
        buckets.setdefault(int(t / period), 0)
        buckets[int(t / period)] += 1
    counts = sorted(buckets.values())
    if counts:
        allor = sum(1 for c in counts if c in (0, 8))
        print(f"  per-trigger grain counts at prob 0.5: "
              f"min {counts[0]}, median {counts[len(counts)//2]}, "
              f"max {counts[-1]}  ({allor}/{len(counts)} were all-or-nothing)")

    print("\n=== SYNC (0.5 Hz, reset at 3.35 s) ===")
    for tag, label in [("/tmp/v_free", "free-running"), ("/tmp/v_sync", "reset")]:
        ev = [t for t in onsets(tag, 3.0, 5.0)]
        print(f"  {label}: grains at " +
              (", ".join(f"{t:.2f}s" for t in ev[:6]) or "none"))
