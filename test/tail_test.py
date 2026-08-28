"""Where does the reverb-like tail come from?

Mick reports it "always" sounds like there is a reverb on. Everything that
could obviously reverberate - FILTRU, DELAY, the SWARM duplicates - is at
zero wet by default, so guessing is useless. This feeds a short burst and then
silence, and measures how long the output keeps ringing, bisecting the chain
by tapping the output at each stage.

Settings are the ones the Lua actually sends at init (dumped from the mock),
with RATE and voices raised to something you would really play at.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
import harness as H

SRC = r'''
// 250 ms of pink noise starting at 0.5 s, then silence for the rest.
~src = SynthDef(\srcsig, { arg outl = 16, outr = 17;
	var gate = EnvGen.ar(Env([0, 1, 1, 0, 0], [0.002, 0.246, 0.002, 20],
		\lin), Impulse.ar(0), timeScale: 1);
	var s = PinkNoise.ar(0.5) * DelayN.ar(gate, 1, 0.5);
	Out.ar(outl, s); Out.ar(outr, s);
});
'''

# Everything below is the Lua's real init state, verified against a mock dump.
BASE = r'''\mcontour, 8, \mspray, 0, \mspraymode, 1, \mswarm, 0, \mswarmmode, 1,
	\mpattern, 0, \mstrum, 0, \msos, 0, \mlock, 0,
	\mbuflen, 8, \mwinstart, 0, \mwinend, 1,
	\mscan, 0.666, \mscanmode, 1, \mdelay, 0,
	\ftrack, 2, \freso, 0.6, \fshift, 1, \fpole, 0,
	\fwidth, 0.5, \fdrift, 0, \pwet, 0, \fwetmode, 1,
	\scycle, 2, \sfb, 0.35, \stilt, -0.2, \stiltxover, 650,
	\sdiffuse, 0, \swet, 0, \shold, 0,
	\drive, 0, \compress, 0, \crush, 0, \crushmode, 1, \tilt, 0,
	\noise, 0, \noisetype, 2, \noisedecay, 0.25, \noisetone, 1200,
	\noisedyn, 2,
	\bypass, 0,
	\ingain, 1, \glev, 1, \flev, 1, \slev, 1, \klev, 1, \sendpre, 0,
	\limceil, 1.0, \amp, 1.0'''

TAPS = r'''[0.0, ['/n_setn', 1001, \taptimes, 8, 0.5,1,1.5,2,0.125,0.125,0.125,0.125]],
	[0.0, ['/n_setn', 1001, \taplevels, 8, 0.467,0.423,0.380,0.336,0,0,0,0]],
	[0.0, ['/n_setn', 1001, \tappans, 8, -0.5,0.5,-0.35,0.35,-0.5,0.5,-0.225,0.225]],'''

SCRIPT = r'''
~render = { arg path, args, gates;
	Score(~alloc ++ [
		[0.0, ['/d_recv', ~src.asBytes]],
		[0.0, ~qrecv],
		[0.0, ['/s_new', \srcsig, 1000, 0, 0, \outl, 16, \outr, 17]],
		[0.0, ['/s_new', \pappus, 1001, 3, 1000,
			\inbusl, 16, \inbusr, 17, \outbus, 0, BASEARGS] ++ args],
		[0.0, ['/n_setn', 1001, \pitches, 8, 0,0,0,0,0,0,0,0]],
		[0.0, ['/n_setn', 1001, \gates, 8] ++ gates],
		TAPARGS
		[12.0, [\c_set, 0, 0]]
	]).recordNRT(path ++ ".osc", path ++ ".wav", nil,
		sampleRate: 48000, headerFormat: "WAV", sampleFormat: "float",
		options: ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2));
};

~four = [1,1,1,1,0,0,0,0];
~one  = [1,0,0,0,0,0,0,0];

fork {
	// as played: 1/16 grains, four voices
	~render.value("/tmp/t_full", [\mrate, 8, \msize, 0.125], ~four); 1.5.wait;
	// one voice
	~render.value("/tmp/t_one",  [\mrate, 8, \msize, 0.125], ~one);  1.5.wait;
	// short grains: if the tail is grain LENGTH it should shrink
	~render.value("/tmp/t_short",[\mrate, 8, \msize, 0.01], ~four);  1.5.wait;
	// playhead parked instead of scanning
	~render.value("/tmp/t_park", [\mrate, 8, \msize, 0.125,
		\mscanmode, 2, \mscan, 0.3], ~four); 1.5.wait;
	// delay feedback off, in case it leaks
	~render.value("/tmp/t_nofb", [\mrate, 8, \msize, 0.125, \sfb, 0], ~four);
	1.5.wait;
	// no grains at all: the chain on its own
	~render.value("/tmp/t_nogr", [\mrate, 8, \msize, 0.125],
		[0,0,0,0,0,0,0,0]); 1.5.wait;

	// ---- which knob makes it wash? ----
	// The buffer holds the last mbuflen seconds. Anything that makes the
	// playhead read somewhere other than where the write head is, or reads
	// several places at once, replays that history - which is what a reverb
	// is. These isolate each candidate.
	~render.value("/tmp/t_sc50", [\mrate, 8, \msize, 0.125, \mscan, 0.5],
		~four); 1.5.wait;
	~render.value("/tmp/t_sc80", [\mrate, 8, \msize, 0.125, \mscan, 0.8],
		~four); 1.5.wait;
	~render.value("/tmp/t_spry", [\mrate, 8, \msize, 0.125, \mspray, 0.3],
		~four); 1.5.wait;
	~render.value("/tmp/t_size", [\mrate, 8, \msize, 0.5], ~four); 1.5.wait;
	~render.value("/tmp/t_swrm", [\mrate, 8, \msize, 0.125, \mswarm, 0.5],
		~four); 1.5.wait;
	~render.value("/tmp/t_sos",  [\mrate, 8, \msize, 0.125, \msos, 0.6],
		~four); 1.5.wait;

	// SPRAY's excursion is scaled by the active window, and the tail can never
	// outlast the buffer - so both are really the "reverb size" control
	~render.value("/tmp/t_sprw", [\mrate, 8, \msize, 0.125, \mspray, 0.3,
		\mwinstart, 0.0, \mwinend, 0.12], ~four); 1.5.wait;
	~render.value("/tmp/t_sprb", [\mrate, 8, \msize, 0.125, \mspray, 0.3,
		\mbuflen, 2], ~four); 1.5.wait;

	"TAIL TEST DONE".postln;
	0.exit;
};
'''.replace("BASEARGS", BASE).replace("TAPARGS", TAPS)


def envelope(tag, hop=0.02):
    import numpy as np, soundfile as sf
    x, sr = sf.read("/tmp/%s.wav" % tag)
    m = np.abs(x).max(axis=1)
    n = int(hop * sr)
    out = [(i / sr, float(m[i:i + n].max())) for i in range(0, len(m) - n, n)]
    return out


def report(tag, label, ref=None):
    """Tail measured against a FIXED threshold, not a per-render one.

    A relative -60 dB threshold flatters a quiet render and, worse, calls a
    silent file infinitely long - the first version of this reported the
    parked-playhead case as an 11 second tail when it was simply silence.
    """
    env = envelope(tag)
    peak = max(v for _, v in env) or 0.0
    if peak < 1e-4:
        print(f"  {label:<22} silent")
        return env
    thr = (ref or peak) * 0.003          # about -50 dB of the reference
    last = 0.0
    for t, v in env:
        if v > thr:
            last = t
    print(f"  {label:<22} peak {peak:.4f}   rings until {last:5.2f}s"
          f"   tail {max(last - 0.75, 0):5.2f}s")
    return env


if __name__ == "__main__":
    if "--render" in sys.argv:
        H.run(H.build(SRC + SCRIPT), "/tmp/tail.scd", timeout=1800,
              expect="TAIL TEST DONE")
        print("rendered")

    print("\n=== how long does it ring after a 250 ms burst? ===")
    print("    (input runs 0.50-0.75 s, then silence)")
    base = max(v for _, v in envelope("t_full"))
    for tag, label in [("t_full", "defaults, 4 voices"),
                       ("t_one", "one voice"),
                       ("t_short", "10 ms grains"),
                       ("t_park", "playhead parked"),
                       ("t_nofb", "delay feedback 0"),
                       ("t_nogr", "no grains at all")]:
        report(tag, label, base)

    print("\n=== which knob makes it wash? ===")
    for tag, label in [("t_sc50", "SCAN 0.5 (half speed)"),
                       ("t_sc80", "SCAN 0.8 (1.4x speed)"),
                       ("t_spry", "SPRAY 0.3"),
                       ("t_size", "SIZE 0.5 beats"),
                       ("t_swrm", "SWARM 0.5"),
                       ("t_sos", "SOS 0.6")]:
        report(tag, label, base)

    print("\n=== and what shortens it ===")
    for tag, label in [("t_spry", "SPRAY 0.3, 8 s buffer"),
                       ("t_sprw", "  + window 0.00-0.12"),
                       ("t_sprb", "  + buffer 2 s instead")]:
        report(tag, label, base)

    print("\n=== envelope of the default case, 0.02 s steps ===")
    env = envelope("t_full")
    peak = max(v for _, v in env) or 1e-9
    for t, v in env:
        if t > 0.4 and t < 6.0 and (round(t * 50) % 10 == 0):
            bar = "#" * int(60 * (v / peak))
            print(f"  {t:5.2f}s {20*math.log10(max(v,1e-9)/peak):+7.1f} dB {bar}")
