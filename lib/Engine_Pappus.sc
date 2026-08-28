// Engine_Pappus
// Pappus - scatter to the wind. A chain of Torso S-4 style devices:
//
//   GRAINSWARM 1 and 2 (parallel) > FILTERBANK > DELAY > COLOUR > out,
//   where SIGNAL is the routing: each stage has an amount of each
//   granulator fed into it, so either one can skip any part of the chain
//
// GRAINSWARM continuously captures the input into a mono ring buffer and spawns
// grains from a movable playhead. eight independent voices, one per grid row,
// each with its own pitch.
//
// COLOUR is drive > crush > loss > envelope-following noise.

Engine_Pappus : CroneEngine {
	var <synth, <buf, <bufr, <buf2, <buf2r, <dbuf, <envbufs, <patbuf, <patbuf2, <mbus;
	var bufdur = 60.0;
	var deldur = 11.0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// alloc runs inside a Routine in CroneEngine and doneCallback only fires
	// once it returns. an uncaught error here means the script hangs on
	// "loading..." forever, so wrap it and report instead.
	alloc {
		try {
			this.prAlloc;
			"Engine_Pappus: loaded".postln;
		} { arg err;
			"### Engine_Pappus: alloc failed ###".postln;
			err.reportError;
		};
	}

	// mkdir -p, one level at a time. File.mkdir will not create parents.
	prMakeDir { arg path;
		var parts, acc;
		if(path.isNil or: { path.isEmpty }) { ^this };
		parts = path.split($/);
		acc = "";
		parts.do { arg p;
			if(p.isEmpty.not) {
				acc = acc ++ "/" ++ p;
				if(File.exists(acc).not) { File.mkdir(acc) };
			};
		};
	}

	prAlloc {
		var srv = context.server;
		var envnums, patvals;

		// GRAINSWARM capture. TWO MONO BUFFERS PER GRANULATOR, left and
		// right, because GrainBuf reads a mono buffer - "the buffer holding a
		// mono audio signal", says its own help - and handing it a two
		// channel one would read the interleave as if it were a waveform.
		//
		// So the capture is genuinely stereo and the cost is one extra
		// interpolated buffer read per voice: the MAIN grain is read twice,
		// once per side. The SWARM duplicates are not - there are two of them
		// already, so one is pointed at each side and the pair costs exactly
		// what it did before while still carrying both.
		//
		// With a mono source the two buffers hold the same samples and every
		// number below comes out where it always did.
		buf = Buffer.alloc(srv, (bufdur * srv.sampleRate).asInteger, 1);
		bufr = Buffer.alloc(srv, (bufdur * srv.sampleRate).asInteger, 1);
		// ...and a second pair, because two granulators sharing a capture
		// buffer are not two granulators, they are one buffer read twice.
		// Separate SOS, separate LOCK, separate TILT baked into the recording:
		// that is the whole point of the pair.
		buf2 = Buffer.alloc(srv, (bufdur * srv.sampleRate).asInteger, 1);
		buf2r = Buffer.alloc(srv, (bufdur * srv.sampleRate).asInteger, 1);

		// DELAY delay line. Mono: taps are panned out to stereo, and keeping
		// the feedback path mono is what stops the image wandering as it
		// regenerates.
		dbuf = Buffer.alloc(srv, (deldur * srv.sampleRate).asInteger, 1);

		// EUCLID's gate pattern, sixteen steps. Starts all-open, which is what
		// EUCLID off means; Lua runs Bjorklund and overwrites it whenever the
		// density or the length moves.
		patvals = Array.fill(16, { 1 });

		// 17 grain envelope shapes, down-ramp .. sine .. up-ramp. Precomputed
		// so CONTOUR is a buffer selection at grain spawn rather than a buffer
		// rewrite on every encoder tick.
		//
		// Allocate everything first, sync once, then fill. Buffer.sendCollection
		// syncs with the server per buffer, which on a Pi is eighteen round
		// trips inside alloc; alloc blocking is what leaves norns on
		// "loading..." forever, so keep it to two.
		envbufs = (0..16).collect { Buffer.alloc(srv, 256, 1) };
		patbuf = Buffer.alloc(srv, patvals.size, 1);
		patbuf2 = Buffer.alloc(srv, patvals.size, 1);
		// SIX METERS, on a control bus. SIGNAL draws the signal flow with a
		// live level on every box, and a level Lua guessed at would be a
		// drawing of something nobody measured.
		//   1 GRAINSWARM 1   2 GRAINSWARM 2   3 FILTERBANK
		//   4 DELAY        5 COLOUR         6 OUT
		mbus = Bus.control(srv, 6);
		srv.sync;

		envbufs.do { arg b, i;
			var c = (i / 8) - 1;
			var p = (0.5 + (c * 0.5)).clip(0.04, 0.96);
			b.setn(0, Env([0, 1, 0], [p, 1 - p], \sine).discretize(256).as(Array));
		};
		patbuf.setn(0, patvals);
		patbuf2.setn(0, patvals);
		envnums = envbufs.collect({ arg b; b.bufnum });

		srv.sync;

		// GRAIN SWARMER args: mrate .. gates
		// COLOUR args: drive .. amp
		SynthDef(\pappus, {
			arg inbusl = 0, inbusr = 1, outbus = 0,
				mrate = 8, msize = 0.12, mcontour = 8,
				mbuflen = 8, mwinstart = 0, mwinend = 1, mstrum = 0,
				// FILTERBANK, a resonant filterbank. Forty-eight resonators -
				// six partials on each of the eight grain voices - so the
				// bank is always tuned to the chord the grains are playing
				// and there is no pitch or scale control of its own.
				//
				// The whole layout is computed in Lua and arrives as two
				// arrays: where each resonator sits and how loud it is. That
				// is deliberate. The frequencies depend on the grain chord,
				// the partial stretch, the analysis window, the tilt and the
				// grid's on/off matrix - five things that are all already in
				// Lua - and doing it there costs the graph nothing at all.
				// SLICE and FREEZE are then simply "when is Lua allowed to
				// send", which is why neither appears here.
				pfrq = #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
				pamp = #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
					0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
				preso = 0.3, pshape = 0, pshapemode = 1,
				pfb = 0, pwet = 0,
				mscan = 0.666, mscanmode = 1, mdelay = 0.25,
				mspray = 0, mspraymode = 1, melen = 1, mephase = 0,
				mswarm = 0, mswarmmode = 1, mlock = 0, msos = 0, mtilt = 0,
				msrc = 1,
				pitches = #[0, 0, 0, 0, 0, 0, 0, 0],
				gates = #[1, 0, 0, 0, 0, 0, 0, 0],
				probs = #[1, 1, 1, 1, 1, 1, 1, 1],
				// GRAINSWARM 2. The same controls again, one letter along, so
				// the pairing is obvious at a glance and neither set is the
				// special case. Its defaults are the first one's, which means
				// a fresh script has two identical granulators and INPUT is
				// the only thing that decides what you hear.
				nrate = 8, nsize = 0.12, nbuflen = 8.0, ncontour = 8,
				nwinstart = 0, nwinend = 1, nstrum = 0,
				nscan = 0.666, nscanmode = 1, ndelay = 0.25,
				nspray = 0, nspraymode = 1, nelen = 1, nephase = 0,
				nswarm = 0, nswarmmode = 1, nlock = 0, nsos = 0, ntilt = 0,
				nsrc = 1,
				pitches2 = #[0, 0, 0, 0, 0, 0, 0, 0],
				gates2 = #[1, 0, 0, 0, 0, 0, 0, 0],
				probs2 = #[1, 1, 1, 1, 1, 1, 1, 1],
				t_sync = 0,
				drive = 0,
				crush = 0, crushmode = 1, loss = 0,
				noise = 0, noisetype = 2,
				noisedecay = 0.25, noisetone = 1200, noisedyn = 2,
				scycle = 1.0, sfb = 0, stilt = 0, stiltxover = 900,
				sdiffuse = 0, swet = 0, shold = 0,
				taptimes = #[0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2],
				taplevels = #[1, 0, 0, 0, 0, 0, 0, 0],
				tappans = #[0, 0, 0, 0, 0, 0, 0, 0],
				// COLOUR is always wet now - it is the colour stage, and a
				// colour stage you can turn off is just a bypass with extra
				// steps (which BYPASS already is). WOW takes the knob: a slow
				// drift on the whole stage, gentle at the bottom and properly
				// seasick at the top.
				kwow = 0,
				// ROUTING. Which tap each stage takes as its input, and which
				// the master takes. 0 = the granulator, 1 = FILTERBANK's output,
				// 2 = DELAY's, 3 = COLOUR's. Lua turns a permutation into
				// these four numbers.
				// ROUTING, and it is the whole mixer now.
				//
				// Each stage has an amount of GRAINSWARM 1 and an amount of
				// GRAINSWARM 2 fed INTO it. A granulator entering at FILTERBANK
				// flows on through everything after it; one entering only at
				// COLOUR has skipped the first two; one entering only at OUT
				// has skipped the lot. That is what "bypass a module" means
				// here, and it is per granulator by construction.
				//
				// It replaces TRIQ, the per-stage return faders and the send.
				// Reordering is gone with them: the order is fixed and the
				// interesting question turned out to be WHERE EACH GRANULATOR
				// JOINS, not what order the boxes sit in.
				// Both granulators enter at the HEAD, at 0.7, and the later
				// feeds start at zero. They have to.
				//
				// The stages are serial and pass their input through when
				// their WET is down, so a granulator fed in at all four points
				// arrives at the output FOUR TIMES. Measured with everything
				// at 0.7 that is 2.8x - almost nine decibels - and it is not
				// what "70%" means to anybody. Entering once and flowing
				// through is what the picture on SIGNAL shows, so it is what
				// the defaults should be.
				//
				// The later feeds are for moving WHERE a granulator joins:
				// turn one up and its own head feed down, and it has skipped
				// everything before that point.
				pin1 = 0.7, pin2 = 0.7,        // into FILTERBANK
				sin1 = 0, sin2 = 0,            // into DELAY
				kin1 = 0, kin2 = 0,            // into COLOUR
				oin1 = 0, oin2 = 0,            // straight to the output
				ingain = 1, mcomp = 0.2, limceil = 0.98855,
				bypass = 0, amp = 1, fade = 1, run = 1;

			var lagt = 0.02, envref = 0.5;
			var in, frnd, mkgrain, graw, graw2, gsum, gsum2, gfeed, msig;
			var prng, psh, pdrv, pfl, pfr, pal, par, pones;
			var pfbin, pfbout, plfb, pana, pmono;
			var pin, kin, omix, mcp;
			var fsum, fmix, fsend, fwt;
			var presig, sfeed;
			var dframes, dph, fbtime, fbrd, fblo, fbhi, fbcol, fbamt, dwrite;
			var tphases, taps, wetsig, sdry, smix, ssend, ssig, stl, sxo;
			var dry, sig, env;
			var dr, cr, ls, ns, kw, kwd, kwm;
			var dgain, dbias, dx, dy, mk;
			var bits, q, fb, pre, bc, jit, sr, rd, br, crushed, crushfb, kout;
			var lmono, lchain, lthr, lossmono, ldry, lossed, lmix;
			var lo, hi, nwhite, npink, ndust, nz;
			var nres, nexc, nf0, nsel, nring, nrat, nbamp, nbank;
			var mixed, sent, outsig;
			var mt1, mt2, mt3, mt4, mt5, mt6;

			// =============================================================
			// INPUT
			// norns hands engines TWO mono input busses, not one stereo bus
			// =============================================================
			// input gain sits ahead of everything, including BYPASS, so the
			// bypassed path is a fair comparison rather than a different level
			in = LeakDC.ar([In.ar(inbusl, 1), In.ar(inbusr, 1)])
				* Lag.kr(ingain, 0.05);
			// TILT, and it is PRE-BUFFER on purpose: it shapes what gets
			// recorded, not what comes out. Roll the bottom off before the
			// capture and every grain taken from that part of the buffer is
			// thin for ever - which is the point, and is a different tool
			// from an EQ on the output.
			//
			// A DJ tilt: one crossover, one band up as the other goes down.
			// 12 dB each way, so the knob spans 24 dB of slope and the middle
			// of the band stays where it is.
			// SHELVES, not a crossover. Splitting with LPF and HPF and
			// summing the halves is the obvious construction and it is not
			// transparent at zero: two second-order Butterworths do not sum
			// to unity, they notch at the crossover. Measured, that cost
			// 4.8 dB with the knob at FLAT. A pair of shelves is unity at
			// 0 dB by construction, so flat really is flat.

			// The engine already owns the single LocalIn/LocalOut pair a
			// SynthDef is allowed, down in COLOUR's crush. Rather than a second
			// one - which SC rejects - the pair carries a third channel for
			// FILTERBANK's feedback. Read here, written at the same LocalOut.
			// One LocalIn/LocalOut pair is all a SynthDef gets, so this one
			// carries everything that has to cross a block boundary: two
			// channels for COLOUR's crush error feedback, one for FILTERBANK's
			// own feedback, and three stereo pairs holding each stage's OUTPUT
			// from the previous block.
			//
			// Those last three are what make reordering possible at all. An SC
			// graph is acyclic and evaluated in a fixed order, so a stage
			// cannot read something computed after it. Reading it one block
			// late can. Every stage-to-stage hop therefore costs one control
			// block - about 1.3 ms at 48 kHz, under half a metre of air -
			// whichever direction it goes, which is worth it for the
			// uniformity: no order is a special case.
			// Three channels, not nine. Six of them were the stage taps TRIQ
			// needed to read a stage's output one block late so the boxes
			// could be reordered - and they were held live across the ENTIRE
			// graph, six interconnect buffers that nothing else could use.
			// Dropping reordering handed those back, and they are what pays
			// for the routing above.
			plfb = LocalIn.ar(3);
			fb = plfb[0..1];
			pfbin = plfb[2];

			// fixed detune table, in octaves. A table rather than a random UGen
			// so anything using it is stable and repeatable.
			frnd = [0, 0.41, -0.77, 0.19, 0.93, -0.35, 0.61, -0.12];

			// =============================================================
			// GRAINSWARM, built twice
			//
			// Two independent granulators, each with its own capture buffer,
			// its own euclidean pattern and its own full set of controls. The
			// graph below is written ONCE and instantiated twice, because a
			// copy-pasted second granulator is two places to fix every bug and
			// they drift apart within a week.
			//
			// Everything shared stays outside: the input, the transport gate,
			// the sync trigger, the envelope shape buffers and the detune table.
			// =============================================================
			mkgrain = { arg gbufl, gbufr, gpat, gsrc, mtilt, mrate, msize, mbuflen, mcontour, mstrum,
				mscan, mscanmode, mdelay, mspray, mspraymode, melen, mephase,
				mswarm, mswarmmode, mlock, msos, mwinstart, mwinend,
				pitches, gates, probs;
				var capl, capr, mtl, frames, sos, sosret, sosin, wlen, loopfrac,
				wphase, oldl, oldr, wpos, winlo, winhi, winspan, gph, trig, estep,
				scanstretch, delaypos, scanpos, envsel, nvoices, swarm, dupgain,
				swiva, swivb, unison, strumsp, prnd, warpa, warpb, gsum,
				ssel, sst, sml, smr, gover, sxf;
				// SOURCE. What this granulator is recording, if anything.
				//
				//   1 OFF    nothing. The write is gated shut and the buffer
				//            HOLDS what it already had. "No input" means
				//            nothing arrives, not that silence is recorded
				//            over the top - the destructive reading would
				//            quietly erase a snapshot you just loaded, and
				//            LOCK is already there if you want a freeze.
				//   2 STEREO left to the left buffer, right to the right,
				//            kept apart all the way to the grain
				//   3 MONO L left only, written to BOTH buffers
				//   4 MONO R right only, written to both
				//
				// A mono source is not "stereo with one side missing": it
				// goes to both sides so the grains are centred rather than
				// stacked against one speaker. STEREO with a lead in one
				// socket really is one-sided, which is what stereo means.
				//
				// Control-rate gains, not a Select of candidate signals. The
				// unchosen ones would be built and thrown away, and this graph
				// has ten wires spare in total.
				ssel = gsrc.round(1);
				sst = Lag.kr((ssel > 1.5) * (ssel < 2.5), 0.02);
				sml = Lag.kr((ssel > 2.5) * (ssel < 3.5), 0.02);
				smr = Lag.kr((ssel > 3.5) * (ssel < 4.5), 0.02);
				capl = (in[0] * (sst + sml)) + (in[1] * smr);
				capr = (in[1] * (sst + smr)) + (in[0] * sml);
				// TILT is baked into the recording, so it happens to both
				mtl = Lag.kr(mtilt, 0.05).clip(-1, 1);
				capl = BHiShelf.ar(BLowShelf.ar(capl, 700, 1, 0 - (mtl * 12)),
					700, 1, mtl * 12);
				capr = BHiShelf.ar(BLowShelf.ar(capr, 700, 1, 0 - (mtl * 12)),
					700, 1, mtl * 12);
				frames = BufFrames.kr(gbufl.bufnum);

				// =============================================================
				// GRAINSWARM
				// =============================================================

				// capture, with sound-on-sound rather than a plain overwrite.
				//   msos 0      normal record, new audio replaces old
				//   msos mid    new audio layers on top, old decays a little on
				//               every pass through the buffer
				//   msos ~0.95  near-infinite sustain, new audio barely enters
				//   msos 1      frozen. LOCK forces this.
				//
				// every write is clipped to +/-1, so buffer content can never
				// exceed 1, which makes the freeze at the top of the knob
				// bit-exact rather than merely close.
				sos = Lag.kr(msos, lagt).max(mlock).clip(0, 1);
				sosret = (sos * 1.05).clip(0, 1);          // how much old is kept
				// RUN gates the granulator against an external transport. Stopped,
				// nothing is written to the buffer and no grain is spawned - the
				// buffer holds whatever it had. Everything downstream keeps
				// running, so delay tails and resonator rings decay away naturally
				// instead of being cut off, which is what stopping a transport
				// should sound like.
				sosin = ((1 - sos) * 4).clip(0, 1) * Lag.kr(run, 0.02)
					* Lag.kr(ssel > 1.5, 0.02);
				wlen = (Lag.kr(mbuflen, 0.1) * SampleRate.ir).clip(4800, frames);
				loopfrac = wlen / frames;
				// ONE phasor for both sides. Two would drift apart by a
				// sample here and there and the image would wander with them.
				wphase = Phasor.ar(0, BufRateScale.kr(gbufl.bufnum), 0, wlen);
				oldl = BufRd.ar(1, gbufl.bufnum, wphase, 1, 1);  // no interpolation
				oldr = BufRd.ar(1, gbufr.bufnum, wphase, 1, 1);
				BufWr.ar(((capl * sosin) + (oldl * sosret)).clip2(1),
					gbufl.bufnum, wphase, 1);
				BufWr.ar(((capr * sosin) + (oldr * sosret)).clip2(1),
					gbufr.bufnum, wphase, 1);
				wpos = wphase / wlen;
				winlo = Lag.kr(mwinstart, lagt).clip(0, 0.99);
				winhi = Lag.kr(mwinend, lagt).clip(0.01, 1).max(winlo + 0.01);
				winspan = winhi - winlo;

				// A resettable trigger rather than a bare Impulse, so the
				// granulator can be aligned to a transport start instead of
				// free-running against it. Phasor's reset input snaps it to zero,
				// and the wrap detector reads that as a trigger too - so beat one
				// gets a grain, which is the point of syncing at all.
				gph = Phasor.ar(K2A.ar(t_sync),
					Lag.kr(mrate, lagt).max(0.05) * SampleDur.ir, 0, 1);
				trig = ((gph - Delay1.ar(gph)) < 0) + Impulse.ar(0);
				trig = trig * (run > 0.5);

				// EUCLID. patbuf now holds a sixteen-step gate pattern - Lua owns
				// the Bjorklund distribution and writes the result in, exactly as
				// it does for DELAY's taps - and one step counter is shared by
				// all eight voices. Each voice reads that same pattern at its OWN
				// ROTATION, which is what PHASE sets: voice i is offset by i x
				// mephase steps. One pattern, eight rotations, so the grains
				// interlock instead of merely being sparse.
				//
				// The counter has to be audio rate: a control-rate trigger would
				// miss impulses between blocks. It counts to melen-1 rather than to
				// 15 and being wrapped afterwards, because a 16-step counter folded
				// into a 5-step pattern glitches once every sixteen steps where the
				// wrap and the fold disagree.
				estep = Stepper.ar(trig, 0, 0, (melen - 1).max(0), 1);

				// SCAN
				//   1 STRETCH     playhead speed relative to the write head,
				//                 mapped -1 .. +2 so reverse and freeze are in reach
				//   2 POSITION    fixed playhead
				//   3 DELAY SYNC  behind the write head, division from lua
				//   4 DELAY FREE  behind the write head, seconds from lua
				scanstretch = Phasor.ar(0,
					((Lag.kr(mscan, lagt) * 3) - 1) / (wlen.max(1)), 0, 1);
				delaypos = (wpos - (Lag.kr(mdelay, lagt)
					/ Lag.kr(mbuflen, 0.1).max(0.1))).wrap(0, 1);
				scanpos = Select.ar(mscanmode - 1, [
					scanstretch,
					K2A.ar(Lag.kr(mscan, lagt)),
					delaypos,
					delaypos
				]);

				envsel = Select.kr(mcontour.clip(0, 16), envnums);
				nvoices = gates.sum.max(1);

				// SWARM. Each voice can bring up two detuned duplicates, supersaw
				// style. The knob fades them in, widens the detune and pushes them
				// apart in the stereo field; the mode sets what interval they sit
				// at before detuning is applied.
				//
				//   1 DETUNE    both duplicates at unison, pure beating
				//   2 5TH       -7 / +7 semitones
				//   3 OCT       -12 / +12 semitones
				//   4 5TH+OCT   +7 / +12, organ-stack style
				//
				// Detune is a FIXED spread plus a slow independent drift per
				// duplicate, not a fresh random value per grain. Per-grain random
				// never settles, so it shimmers instead of beating, and SPRAY and
				// PATTERN already cover that territory.
				swarm = Lag.kr(mswarm, lagt).clip(0, 1);
				dupgain = (swarm * 3).clip(0, 1);        // duplicates fade in early
				swiva = Select.kr(mswarmmode - 1, [0, -7, -12,  7]);
				swivb = Select.kr(mswarmmode - 1, [0,  7,  12, 12]);
				unison = (swivb - swiva).abs < 0.5;      // 1 only in DETUNE mode

				// STRUM. mstrum is now a SUBDIVISION of the grain period - the
				// fraction of a period between one voice and the next - so every
				// voice onset lands on a division of the grain clock rather than
				// at an arbitrary fraction of an arbitrary spread. Lua quantises
				// the knob to 1/64 .. 1/8; at the widest, voice eight sits at 7/8
				// of a period, which is why no clamp is needed to keep a voice from
				// still waiting when its next trigger arrives.
				strumsp = (Lag.kr(mstrum, lagt).clip(0, 0.125)
					* (1 / Lag.kr(mrate, lagt).max(0.05))).clip(0, 2);

				// PROBABILITY. One random number per trigger, shared by all eight
				// voices but read through a different fixed offset each, so the
				// voices thin out independently without eight separate random
				// generators - which would cost audio wires this graph does not
				// have. frnd doubles as the offset table.
				prnd = TRand.ar(0, 1, trig);

				// SPRAY's two WARP drifts, hoisted OUT of the voice loop and
				// rotated per voice below.
				//
				// This was eight LFNoise2 pairs, one per voice, each converted
				// to audio rate by its own K2A. A K2A of a control signal has
				// no audio-rate input at all, which means SC's topological sort
				// is free to schedule it anywhere - and it schedules every one
				// of them at the very top of the graph, where they then sit
				// holding an interconnect buffer each until their voice finally
				// runs. Sixteen wires per granulator, held across everything.
				// One granulator absorbed that. Two did not: the def came out
				// at 76 wires against a hard limit of 64.
				//
				// Two shared drifts, rotated by a fixed per-voice angle, give
				// eight decorrelated signals out of two sources. The rotation
				// is a multiply by an audio signal, so it CANNOT float to the
				// top - it is scheduled next to the voice that uses it and the
				// wire is returned immediately.
				warpa = K2A.ar(LFNoise2.kr(0.3 + (mspray * 3)));
				warpb = K2A.ar(LFNoise2.kr(0.2 + (mspray * 2)));

				// eight voices.
				gsum = DC.ar([0, 0]);
				8.do { arg i;
					var vtrig, dtrig, rnd, rnd2, off, pan, pos, base, g, coin;
					var egate;
					var dur, main, mainl, mainr, da, db, dsp, dupa, v, gjit;
					// Gate the TRIGGER, not just the output. Gating only the output
					// meant all 24 generators produced grains at all times and 23
					// were multiplied by zero - 24x the work for the common case of
					// one row lit and SWARM off. A GrainBuf with no triggers costs
					// essentially nothing.
					coin = ((prnd + frnd[i]).wrap(0, 1)) < probs[i];
					// this voice's euclidean gate, read at its own rotation. With
					// EUCLID off Lua fills the buffer with ones and sets melen to
					// 1, so this is a constant 1 and costs one multiply.
					egate = Index.ar(gpat.bufnum,
						(estep + (mephase * i)).floor % melen.max(1));
					vtrig = TDelay.ar(trig * (gates[i] > 0.001) * coin * egate,
						strumsp * i);
					dtrig = vtrig * (dupgain > 0.001);
					rnd = TRand.ar(-1, 1, vtrig);
					rnd2 = TRand.ar(-1, 1, vtrig);
					// SPRAY: 1 RANDOM, 2 RANDOM MONO, 3 WARP, 4 WARP MONO.
					// WARP is now ONE drift shared by the eight voices rather
					// than eight independent ones - see warpa above. RANDOM is
					// still per grain and per voice, which is where the
					// independence actually matters.
					off = Select.ar(mspraymode - 1, [rnd, rnd, warpa, warpa])
						* Lag.kr(mspray, lagt) * 0.25;
					pan = Select.ar(mspraymode - 1, [rnd2, DC.ar(0), warpb, DC.ar(0)])
						* Lag.kr(mspray, lagt);
					// WINDOW. scanpos and the spray offset both live in 0..1 of the
					// active window; that is then folded into the window and scaled
					// by loopfrac, because GrainBuf wants a fraction of the WHOLE
					// buffer and only the first mbuflen seconds of it are live.
					// A few milliseconds of random read offset on every grain,
					// always, whatever SPRAY is doing.
					//
					// A grain clock is periodic, so it amplitude-modulates the
					// signal at the grain rate - and sixteen overlapping copies
					// read from the SAME buffer position comb against each other
					// rather than smoothing out. Measured on a pure sine, that
					// puts a dense skirt of sidebands spaced at exactly the grain
					// rate around every partial, sitting only 15 dB below the
					// total. That skirt is the roughness.
					//
					// Decorrelating the read positions turns the comb into a soft
					// noise floor: 8 ms of jitter measured 5 dB less. It is scaled
					// to the grain so a short one - where the attack matters - is
					// smeared less than a long one.
					// Eight seconds, not four. SIZE reaches eight BEATS now,
					// and eight beats at 60 bpm is eight seconds - a four
					// second ceiling would cap the top of the knob at slow
					// tempos and nowhere else, which is the worst kind of
					// limit because it moves.
					dur = Lag.kr(msize, lagt).clip(0.002, 8);
					gjit = TRand.ar(-1, 1, vtrig)
						* ((dur * 0.04).min(0.008) / bufdur);
					pos = ((winlo + ((scanpos + off + gjit).wrap(0, 1) * winspan))
						* loopfrac);
					base = pitches[i];
					g = Lag.kr(gates[i], 0.02);

					// THE MAIN GRAIN, once per side. Two mono reads rather
					// than one two-channel read, which is the entire cost of
					// stereo capture: GrainBuf with numChannels 2 reads the
					// buffer once and pans the result, so a stereo pair has
					// to be two of them.
					//
					// SPRAY then works as a BALANCE rather than a pan - it
					// pushes the recorded image left or right instead of
					// placing a mono point source.
					//
					// Balance2, not a pair of square-rooted gains. Same law,
					// same 0.707 a side at centre as the Pan2 inside the old
					// mono GrainBuf - so the make-up gain below still holds -
					// but it is ONE ugen instead of six, and the six were
					// each holding an audio wire at the exact moment the
					// graph is at its widest. That was the difference between
					// sixty-four wire buffers and fifty-eight.
					mainl = GrainBuf.ar(1, vtrig, dur, gbufl.bufnum,
						2 ** (base / 12), pos, 2, 0, envsel, 16);
					mainr = GrainBuf.ar(1, vtrig, dur, gbufr.bufnum,
						2 ** (base / 12), pos, 2, 0, envsel, 16);
					main = Balance2.ar(mainl, mainr, pan);

					// semitone offsets: interval, fixed spread, slow drift.
					// drift rates differ per voice so the eight never lock up.
					// Detune spread. The linear 0.4-semitone version topped out at
					// a spread narrower than a whole tone, which is fine for
					// beating and useless for anything else. A quartic term leaves
					// the bottom two thirds of the knob exactly as it was - still
					// fine, still beating - and opens the top out to a cluster
					// several semitones wide.
					dsp = (swarm * 0.4) + ((swarm ** 4) * 6);
					da = swiva - dsp
						+ (LFNoise2.kr(0.07 + (i * 0.011))
							* ((swarm * 0.25) + ((swarm ** 4) * 1.5)));
					db = swivb + dsp
						+ (LFNoise2.kr(0.09 + (i * 0.013))
							* ((swarm * 0.25) + ((swarm ** 4) * 1.5)));

					// summed as they are built, not held apart, to keep the number
					// of simultaneously live interconnect buffers down
					// ONE DUPLICATE PER SIDE, and this is free: there were
					// always two of them, so pointing the flat one at the
					// left buffer and the sharp one at the right makes the
					// swarm layer stereo at exactly the cost it had before.
					// Their own pan still places them, and with a mono source
					// the two buffers hold the same samples so nothing about
					// this changes.
					dupa = GrainBuf.ar(2, dtrig, dur, gbufl.bufnum,
						2 ** ((base + da) / 12), pos, 2,
						(pan - (swarm * 0.7)).clip2(1), envsel, 8)
						+ GrainBuf.ar(2, dtrig, dur, gbufr.bufnum,
							2 ** ((base + db) / 12), pos, 2,
							(pan + (swarm * 0.7)).clip2(1), envsel, 8);

					// Hold level roughly constant as the duplicates come in.
					// Dividing by sqrt(voices) assumes they sum in power, which
					// holds for the interval modes but not for DETUNE: near-unison
					// copies beat against each other and partially cancel, costing
					// about 4 dB. Measured, so DETUNE gets that back, scaled by the
					// detune width rather than the fade-in, since that is what
					// governs how much they cancel.
					v = (main + (dupa * dupgain))
						/ (1 + (2 * dupgain)).sqrt
						* (1 + (unison * swarm * 0.8)) * g;
					gsum = gsum + v;

				};
				gsum = gsum / nvoices.sqrt;

				// OVERLAP. SIZE x RATE is how many grains are sounding at
				// once, and since the roughness fix made them read
				// decorrelated positions they sum in POWER - so the level
				// climbs as the square root of the overlap. Uncorrected, SIZE
				// is a volume knob as well as a texture knob, and now that it
				// reaches eight beats it is a nine decibel one. That is where
				// the clipping came from.
				//
				// Referenced to an overlap of TWO, which is the default, and
				// it only ever ATTENUATES: at or below the default density
				// nothing changes at all, so no existing patch gets quieter.
				// Above it, SIZE becomes what it should have been all along -
				// a control over texture that leaves the level alone, the same
				// principle FILTERBANK's WIDTH and PARTIALS already follow.
				// Clipped at forty, not left to run: the natural gain stops
				// climbing once the grain slots run out (GrainBuf holds
				// sixteen), measured at about +13 dB and flat from there. An
				// uncapped square root keeps correcting past that and turns
				// the top of the knob into a fade-out.
				gover = (Lag.kr(msize, lagt) * Lag.kr(mrate, lagt)).clip(2, 40);
				gsum = gsum * (2 / gover).sqrt;

				// MAKE-UP. The granulator loses a fixed, knowable amount on
				// the way through and it is worth naming rather than leaving
				// as "it comes out quiet":
				//
				//   -3 dB  GrainBuf pans a mono grain into a stereo pair, so
				//          each side carries 0.707 of it
				//   -4 dB  the grain envelope. A raised cosine has an rms of
				//          about 0.61 of what it is windowing
				//   +3 dB  two overlapping grains, which is the default
				//          density and what the line above normalises to
				//
				// About four decibels, and the measured figure is 4.4 - see
				// test/gain_test.py, which sweeps SOS and asks for a FLAT
				// line. That is the real calibration: SOS crossfades between
				// the dry input and the grains, so if the two ends do not
				// match, the knob is a volume control wearing a blend's
				// clothes. A constant, not an AGC - nothing here is guessing.
				gsum = gsum * 1.66;

				// SOS, the tape sound-on-sound blend.
				//
				// One knob doing what the machine did: at 0 you are recording
				// fresh and hearing the input go past, at the top the buffer
				// has frozen and all you hear is what it caught. It is the
				// same number that decides how much of the old survives each
				// pass, which is the whole reason a tape SOS knob feels like
				// one gesture instead of three.
				//
				// The BLEND finishes by 0.6 while the RECORD keeps going to
				// 1.0, and that gap matters: it means you can reach grains-
				// only while the buffer is still recording. If the crossfade
				// ran the full width, "hear only the grains" would arrive at
				// exactly the point the buffer stopped capturing them, and
				// starting from silence you would hear nothing at all.
				sxf = (Lag.kr(msos, lagt).max(mlock).clip(0, 1) / 0.6)
					.clip(0, 1);
				gsum = (gsum * (sxf * 0.5pi).sin)
					+ ([capl, capr] * (sxf * 0.5pi).cos);
				// The GRAINSWARM fader is applied OUTSIDE, by the caller. It
				// used to be the last thing in here, and it cannot be any
				// more: swarm 2 can record swarm 1, and it has to record what
				// swarm 1 is MAKING rather than what the mixer is letting
				// through - otherwise pulling GRA 1 down to hear only swarm 2
				// would also stop swarm 2 recording.
				gsum
			};

			// The two granulators, independent and parallel.
			graw = mkgrain.value(buf, bufr, patbuf, msrc, mtilt, mrate, msize,
				mbuflen, mcontour, mstrum, mscan, mscanmode, mdelay, mspray,
				mspraymode, melen, mephase, mswarm, mswarmmode, mlock, msos,
				mwinstart, mwinend, pitches, gates, probs);

			graw2 = mkgrain.value(buf2, buf2r, patbuf2, nsrc, ntilt, nrate, nsize,
				nbuflen, ncontour, nstrum, nscan, nscanmode, ndelay, nspray,
				nspraymode, nelen, nephase, nswarm, nswarmmode, nlock, nsos,
				nwinstart, nwinend, pitches2, gates2, probs2);

			// The faders LAST, both of them, so neither raw output has to stay
			// alive alongside a faded copy of itself. Two live wires either
			// way, which the budget notices.
			// No granulator fader any more. How much of each granulator you
			// hear is decided by where it is fed in, which is one idea instead
			// of two that interact.
			gsum = graw;
			gsum2 = graw2;
			// Metered HERE, where the signal is, not gathered at the end.
			// Amplitude.kr costs no audio wire; holding six stereo signals
			// alive to the bottom of the graph so they could be measured
			// together would cost twelve.
			mt1 = Amplitude.kr((gsum[0] + gsum[1]) * 0.5, 0.01, 0.2);
			mt2 = Amplitude.kr((gsum2[0] + gsum2[1]) * 0.5, 0.01, 0.2);

			// =============================================================
			// FILTERBANK - a morphing resonant filterbank
			//
			// Forty-eight resonators, tuned to the chord the grains are
			// playing: six partials on each of the eight voices. It replaces a
			// spectral resynthesiser that analysed the input with sixteen
			// zero-crossing counters and rebuilt it with sixteen oscillators.
			// That was accurate and it was unmusical - the counters land
			// wherever the loudest thing in a band happens to be, which for a
			// grain cloud is nowhere in particular, so the output was a bank of
			// oscillators on frequencies with no relationship to the notes
			// being played.
			//
			// A resonator bank cannot do that. It has no opinion about what is
			// in the input; it rings at frequencies IT is tuned to, and the
			// input only decides how hard. Tune it to the chord and everything
			// it does is in key, whatever you feed it.
			//
			// Two DynKlanks rather than forty-eight Ringz. One UGen holds a
			// whole bank, so the wire cost is an input and an output instead of
			// one live signal per resonator - and the odd partials going to the
			// left bank and the even to the right gives the stereo image for
			// free, the same interleave the old version panned by hand.
			//
			// RESONANCE is the ring time, and it is the whole character
			// control: short is a bank of bandpasses colouring the signal,
			// long is a bank of struck bars.


			// FEED. How much of each granulator enters one point in the
			// chain, as a pair of control-rate gains.
			//
			// Never a Select of pre-built candidates: two stereo candidates
			// plus the chosen one is six live audio wires for something two
			// multiplies do, and this graph has never had six to spare.
			//
			// Not power-normalised, and that is the difference from the old
			// INPUT knob. These are FADERS, not a blend - both up means both,
			// at the level you set. A pair of gains that quietly ducked when
			// you raised the other one would make the wireframe on SIGNAL a
			// lie about what it is showing.
			gfeed = { arg a, b;
				[(gsum[0] * Lag.kr(a, 0.05)) + (gsum2[0] * Lag.kr(b, 0.05)),
				 (gsum[1] * Lag.kr(a, 0.05)) + (gsum2[1] * Lag.kr(b, 0.05))];
			};

			pin = gfeed.value(pin1, pin2);
			pmono = (pin[0] + pin[1]) * 0.5;
			// FEEDBACK, squared. Linear in the knob puts the whole useful
			// range in the top tenth; squaring spreads it out. Into a bank of
			// resonators this is a regeneration control - it is what turns a
			// struck sound into a sustained one.
			pana = pmono
				+ (pfbin * Lag.kr(pfb, lagt).clip(0, 1).squared * 1.6);
			// the low resonators would otherwise just thump on the DC and
			// rumble a grain cloud carries
			pana = HPF.ar(pana, 35);

			// RING TIME: 3 ms to 2.7 s. Exponential, because everything
			// interesting about a resonator happens in the first tenth of the
			// knob and the last tenth has to reach "still ringing".
			prng = 0.003 * (900 ** Lag.kr(preso, lagt).clip(0, 1));

			// Odd resonators left, even right. Lagged because Lua sends the
			// layout in steps - on the SLICE grid, or once a frame at CONT -
			// and an un-lagged jump in a resonator's frequency is a click.
			pones = Array.fill(24, 1);
			pfl = Array.fill(24, { arg i; Lag.kr(pfrq[i * 2], 0.012) });
			pfr = Array.fill(24, { arg i; Lag.kr(pfrq[(i * 2) + 1], 0.012) });
			pal = Array.fill(24, { arg i; Lag.kr(pamp[i * 2], 0.03) });
			par = Array.fill(24, { arg i; Lag.kr(pamp[(i * 2) + 1], 0.03) });
			fsum = [
				DynKlank.ar(`[pfl, pal, pones], pana, 1, 0, prng),
				DynKlank.ar(`[pfr, par, pones], pana, 1, 0, prng)
			];
			// RESONANCE would otherwise be a volume knob as well as a
			// character one. Not by much, though, and that is worth writing
			// down: a longer ring holds more energy but a narrower band lets
			// less in, and the two very nearly cancel. Measured across the
			// knob the raw bank moves under 4 dB, so the correction is a
			// twelfth power, not a square root - which is what was here first
			// and it over-corrected by 7 dB.
			fsum = fsum * (0.076 / ((1 + (prng * 12)) ** 0.12));

			// SHAPE, on the way OUT rather than on the way in. Driving the
			// input just gives the bank more to ring on, which is a subtler
			// thing; folding the ringing itself is what makes it read as an
			// oscillator being shaped rather than a filter being pushed.
			//   SOFT  tanh, the gentle one - thickens and rounds
			//   FOLD  the wavefolder, which adds partials that are not in the
			//         bank at all and is where the metallic edge comes from
			//   WRAP  hard wrap, brutal and buzzy
			psh = Lag.kr(pshape, lagt).clip(0, 1);
			pdrv = 1 + (psh * 14);
			fsum = fsum * pdrv;
			fsum = [
				Select.ar(pshapemode - 1,
					[fsum[0].tanh, fsum[0].fold2(1), fsum[0].wrap2(1)]),
				Select.ar(pshapemode - 1,
					[fsum[1].tanh, fsum[1].fold2(1), fsum[1].wrap2(1)])
			];
			fsum = LeakDC.ar(fsum) / (1 + (psh * 3.5));

			// A LIMITER ON THE BANK, hidden, with no control of its own.
			//
			// Forty-eight resonators with a long RING and FEEDBACK up is a
			// regenerating system: it can climb tens of decibels above
			// anything the input suggests, and it does it slowly enough that
			// the first thing you notice is the master limiter pumping on
			// everything else. Catching it HERE means FILTERBANK cannot flatten
			// the rest of the chain to save itself.
			//
			// 0.9 rather than the master's 0.944, and 20 ms of lookahead
			// rather than 10: this one is holding down a resonant tail, not
			// shaving transients, so it can afford to be slower and gentler.
			// Below that ceiling it is inert, which is where the bank spends
			// almost all of its time.
			fsum = Limiter.ar(fsum, 0.9, 0.02);

			pfbout = ((fsum[0] + fsum[1]) * 0.5).tanh;

			// =============================================================
			// SIGNAL, part one - the GRAINSWARM fader and the send tap
			//
			// Wet/dry is a pair of control-rate gains rather than a crossfade
			// plus a sum plus a Select: building both candidate signals and
			// choosing between them costs three live stereo pairs, this costs
			// one. MIX uses the equal-power sine law (what XFade2 approximates)
			// so the middle of the knob does not dip; SEND leaves the dry at
			// unity and the return rides on top, scaled by its own fader.
			//
			// =============================================================
			fwt = Lag.kr(pwet, lagt).clip(0, 1);
			// MIX ONLY. SEND held the dry at unity and let the wet ride on
			// top; it existed back when the granulator had one output and
			// getting a dry signal past a stage meant asking the stage to do
			// it. SIGNAL's feeds do that properly now - a granulator that
			// should skip FILTERBANK simply is not fed into it - so SEND was a
			// second, worse way to say the same thing, and two mechanisms for
			// one job is how a routing page stops being readable.
			fmix = (fwt * 0.5pi).cos;
			fsend = (fwt * 0.5pi).sin;
			presig = (pin * fmix) + (fsum * fsend);
			mt3 = Amplitude.kr((presig[0] + presig[1]) * 0.5, 0.01, 0.2);
			msig = presig;

			// =============================================================
			// DELAY - multitap delay
			//
			// One mono line. Eight taps read it at times Lua places from a
			// euclidean pattern (or from the grid), each with its own level
			// and pan. Feedback is a single read one full cycle back, so the
			// whole pattern repeats and decays rather than each tap feeding
			// every other tap.
			//
			// TILT sits INSIDE the loop as well as on the output, so repeat N
			// has been coloured N times. That is what makes a delay decay
			// rather than just repeat.
			// =============================================================
			// FILTERBANK's output, plus whatever joins the chain at this point.
			// A serial chain with injections rather than a tap selector: the
			// signal always flows forwards, and the only question is where
			// each granulator gets on.
			sdry = presig + gfeed.value(sin1, sin2);
			// what goes INTO the delay line is what the stage was given: the
			// taps are a read of the line, not a second copy of the input
			sfeed = sdry;
			dframes = BufFrames.kr(dbuf.bufnum);
			dph = Phasor.ar(0, BufRateScale.kr(dbuf.bufnum), 0, dframes);

			stl = Lag.kr(stilt, lagt);
			sxo = Lag.kr(stiltxover, lagt).clip(80, 8000);

			fbtime = Lag.kr(scycle, 0.05).clip(0.005, 10);
			fbrd = BufRd.ar(1, dbuf.bufnum,
				(dph - (fbtime * SampleRate.ir)).wrap(0, dframes), 1, 2);
			fblo = LPF.ar(fbrd, sxo);
			fbhi = fbrd - fblo;
			fbcol = (fblo * (stl.neg * 9).dbamp) + (fbhi * (stl * 9).dbamp);

			// HOLD closes the loop and shuts the input out, freezing the line
			fbamt = Lag.kr(sfb, lagt).clip(0, 1).max(shold);
			dwrite = ((sfeed[0] + sfeed[1]) * 0.5 * (1 - shold))
				+ (fbcol * fbamt * 0.98);
			BufWr.ar(dwrite.clip2(1.5), dbuf.bufnum, dph, 1);

			// taps. WOW is a slow independent wander on each read position,
			// a few ms, which is what keeps a digital multitap from sounding
			// sterile.
			// Read and pan one tap at a time, accumulating as we go, for the
			// same wire-buffer reason as FILTRU: eight read phases plus eight
			// mono taps plus eight stereo pans alive at once is two dozen live
			// interconnect buffers, and scsynth only has 64 in total.
			wetsig = DC.ar([0, 0]);
			8.do { arg i;
				var t = Lag.kr(taptimes[i], 0.08).clip(0.001, 10);
				// WOW moved to COLOUR, where it drifts the whole coloured
				// signal instead of only the delay taps. The taps read
				// straight now.
				var ph = (dph - (t.max(0.0005) * SampleRate.ir))
					.wrap(0, dframes);
				wetsig = wetsig + Pan2.ar(BufRd.ar(1, dbuf.bufnum, ph, 1, 2),
					Lag.kr(tappans[i], lagt), Lag.kr(taplevels[i], lagt));
			};

			// output tilt, same control, so the taps themselves are tinted too
			taps = LPF.ar(wetsig, sxo);
			wetsig = (taps * (stl.neg * 9).dbamp)
				+ ((wetsig - taps) * (stl * 9).dbamp);

			// DIFFUSE: Dattorro-style input diffusers. Four allpasses per
			// channel at mutually prime times, decaytime chosen to give a
			// coefficient near 0.6, offset per channel to decorrelate.
			wetsig = 2.collect({ arg c;
				var x = wetsig[c], sp = 1 + (c * 0.13);
				[0.0133, 0.0191, 0.0277, 0.0413].do({ arg dt;
					x = AllpassC.ar(x, 0.05, dt * sp, dt * sp * 13.5);
				});
				XFade2.ar(wetsig[c], x, (Lag.kr(sdiffuse, lagt) * 2) - 1);
			});

			// Same two-gain trick as FILTERBANK, and MIX only for the same reason.
			smix = Lag.kr(swet, lagt).clip(0, 1);
			ssend = (smix * 0.5pi).cos;
			ssig = (sdry * ssend) + (wetsig * (smix * 0.5pi).sin);

			// =============================================================
			// COLOUR
			// =============================================================
			// COLOUR and the master have no INPUT of their own - COLOUR's knob
			// went to WOW and the master is not a stage you aim. Routed to the
			// granulator tap they hear BOTH, which is the only answer that
			// cannot silently drop half the instrument.
			mt4 = Amplitude.kr((ssig[0] + ssig[1]) * 0.5, 0.01, 0.2);
			dry = ssig + gfeed.value(kin1, kin2);
			sig = dry;

			dr = Lag.kr(drive, lagt);
			cr = Lag.kr(crush, lagt);
			ls = Lag.kr(loss, lagt).clip(0, 1);
			ns = Lag.kr(noise, lagt);
			kw = Lag.kr(kwow, lagt).clip(0, 1);

			// ---- ENVELOPE FOLLOWER ----
			// reads DEFORM's own input, so the noise tracks what you hear
			// coming out of GRAINSWARM rather than the raw input.
			//
			// NOISE DYN is an expander on the follower, pivoted around envref
			// so raising it drops the quiet end without gutting the loud end.
			env = Amplitude.ar((dry[0] + dry[1]) * 0.5, 0.002,
				Lag.kr(noisedecay, lagt)).clip(0, 1);
			env = (envref * ((env / envref).max(0) ** Lag.kr(noisedyn, lagt).clip(0.1, 8)))
				.clip(0, 1);

			// ---- DRIVE ----
			// warm asymmetric fuzz, meant as colour rather than level.
			//   * x/(1+|x|) is one divide and has a softer knee than tanh
			//   * the negative half is compressed harder than the positive
			//     half, which is what puts even harmonics in. doing it as a
			//     ratio rather than a DC bias means the asymmetry holds up at
			//     high gain instead of being swamped by the signal.
			//   * highs roll off as it digs in, like a transformer
			//   * mk is a fitted makeup curve holding loudness roughly flat
			//     across the knob, so it colours without getting louder
			dgain = 1 + (dr.squared * 40);
			dbias = 1 + (dr * 6.0 * (sig < 0));
			dx = sig * dgain;
			dy = dx / (1 + (dx.abs * dbias));
			dy = LeakDC.ar(dy);
			dy = LPF.ar(dy, (16000 - (dr * 10000)).clip(500, 18000));
			// makeup fitted against a measured gain sweep (pink noise at
			// -18 dBFS rms). the raw saturator adds up to +26 dB across the
			// knob; this holds output within about 0.3 dB of clean instead.
			// Fitted against a measured gain sweep (pink noise at a realistic
			// -18 dBFS rms). The raw saturator adds up to +11 dB across the
			// knob; this holds the output within about half a dB of clean, so
			// the knob changes character rather than level. Monotonic and
			// positive over dr 0..1, which the param range guarantees.
			mk = 1.00658 + (dr * -2.84907) + (dr.squared * 3.75126)
				+ ((dr ** 3) * -1.62992);
			dy = dy * mk;
			sig = XFade2.ar(sig, dy, ((dr * 4).clip(0, 1) * 2) - 1);

			// COMPRESS used to sit here. It is on the master now: it was
			// holding together the colour stage's own output, which is not
			// what a compressor is for.

			// ---- CRUSH ----
			bits = 16 - (cr * 13.5);
			q = 2 ** (bits - 1);
			pre = (sig + (fb * cr * 0.5)).tanh;
			bc = (pre * q).round / q;
			// held for the single LocalOut at the very end of the graph. It
			// cannot be written here any more: the stage taps that share the
			// bus include COLOUR's own output, which does not exist yet.
			crushfb = (pre - bc).clip2(1) * 0.85;

			jit = K2A.ar(LFNoise2.kr([220, 190]).range(0.7, 1.0));
			sr = (SampleRate.ir * ((1 - cr) ** 3).linlin(0, 1, 0.004, 1.0) * jit)
				.clip(150, SampleRate.ir);
			rd = Latch.ar(sig, Impulse.ar(sr));
			br = Latch.ar(bc, Impulse.ar(sr));

			// ---- CRUSH: quantisation and sample rate, nothing else ----
			//
			// This used to sit AFTER loss and crossfade against it, which made
			// the two parallel: turning CRUSH up did not crush the lossy
			// signal, it replaced it. In series is what they are for. A codec
			// running on a bad converter gets the quantisation first and then
			// has to encode THAT, and the bit noise crush leaves behind is
			// exactly the kind of broadband hash a bit allocator wastes its
			// budget on - so the two compound instead of competing.
			//
			// It is also cheaper here. bc, rd and br are three live stereo
			// pairs; running the FFT between them and the Select kept all six
			// wires alive across the most expensive block in the engine.
			crushed = [
				Select.ar(crushmode - 1, [bc[0], rd[0], br[0]]),
				Select.ar(crushmode - 1, [bc[1], rd[1], br[1]])
			];
			sig = XFade2.ar(sig, crushed, ((cr * 25).clip(0, 1) * 2) - 1);

			// ---- LOSS: a codec falling apart ----
			// Bit crushing and sample-rate reduction are the wrong artefacts
			// for this: they are loud and broadband, and a perceptual codec is
			// neither. What a low-bitrate encoder actually does is throw away
			// the coefficients its bit allocator cannot afford, which leaves
			// holes in the spectrum that open and close frame to frame - the
			// swirling, watery "birdies" - and it narrows the bandwidth as the
			// rate drops. So: PV_MagAbove discards every bin under a threshold
			// that tracks the signal's own level (so the effect does not
			// change with input gain), and PV_BrickWall closes the top down.
			//
			// Mono on purpose. Joint stereo collapses at low bitrates too, so
			// the image narrowing is authentic, and one transform costs half
			// what two would - this is the most expensive thing in the engine.
			// ...and this is the CRUSHED signal now, not the compressed one
			lmono = (sig[0] + sig[1]) * 0.5;
			lchain = FFT(LocalBuf(512).clear, lmono, 0.25, 1);
			// bin magnitudes scale with window size; 128 is a Hann-windowed
			// 512-point FFT's peak bin for a full-scale sine
			lthr = Amplitude.kr(lmono, 0.02, 0.15) * 128 * ls.squared * 0.45;
			lchain = PV_MagAbove(lchain, lthr);
			// Bandwidth holds up until the knob is well past halfway and only
			// then falls off a cliff, which is how bitrate actually behaves -
			// a gentle curve here just sounds like someone closing a filter.
			lchain = PV_BrickWall(lchain, 0 - ((ls ** 2.2) * 0.86));
			lossmono = IFFT(lchain);
			// An FFT costs one window of delay. The dry side of the blend has
			// to be delayed to match or the low end of the knob is a comb
			// filter rather than a fade.
			ldry = DelayN.ar(sig, 0.05, 512 / SampleRate.ir);
			// linear, not equal-power: the two sides are the same signal, one
			// of them mangled, so they add rather than sum in power. An
			// XFade2 here put a measured +3 dB bump in the middle of the knob.
			lmix = (ls * 1.6).clip(0, 1);
			// LOSS is its own knob, not a fourth CRUSH mode. The two are
			// different kinds of damage - one throws bits away, the other
			// throws BANDS away - and they are in series, so a quantised
			// signal that is also bandwidth-starved is reachable, which is
			// exactly what a bad codec on a bad converter sounds like.
			sig = (ldry * (1 - lmix)) + ([lossmono, lossmono] * lmix);

			// ---- NOISE ----
			//
			// Six sources, and the last three are not noise at all. WHITE,
			// PINK and DUST are the raw ones; BELL, GLASS and PLUCK are a
			// six-partial resonator bank STRUCK by the dust, which turns the
			// same envelope-following sputter into struck metal, tapped glass
			// or a plucked string depending only on how the bank is tuned.
			//
			// One bank, not three. The partial ratios and the ring time are
			// chosen at CONTROL rate, so the three characters cost three
			// arrays of numbers rather than three banks of filters - and the
			// bank is a single DynKlank, which is a whole resonator set for
			// the price of one input and one output.
			//
			// The ratios are what make the character, and they are not
			// arbitrary:
			//   BELL   1, 2.76, 5.40, 8.93, 13.34, 18.64 - the classic
			//          circular-plate series. Wildly inharmonic, which is why
			//          a bell has a pitch you can name and a sound you cannot
			//          sing.
			//   GLASS  1, 2.32, 4.25, 6.63, 9.38, 12.22 - tighter and
			//          brighter, the ratios of a struck tube rather than a
			//          plate, with a short ring so it taps instead of tolls.
			//   PLUCK  1..6, dead harmonic, and a ring so short the bank
			//          reads as a string rather than as a resonance.
			nwhite = { WhiteNoise.ar(1) } ! 2;
			npink = { PinkNoise.ar(1.6) } ! 2;
			ndust = { Dust2.ar(1800) } ! 2;
			nz = [
				Select.ar((noisetype - 1).clip(0, 2),
					[nwhite[0], npink[0], ndust[0]]),
				Select.ar((noisetype - 1).clip(0, 2),
					[nwhite[1], npink[1], ndust[1]])
			];

			// resonant or not, decided once at control rate
			nres = Lag.kr(noisetype > 3.5, 0.05);

			// The excitation for the bank is always DUST - a resonator wants
			// hits, not a wash. Density rides on N.DEC so the same knob that
			// sets the dust's throw on the COLOUR page sets how busy the
			// plucking is.
			nexc = (ndust[0] + ndust[1]) * 0.5;
			nexc = Decay.ar(nexc, 0.002) * 0.6;

			// The fundamental is N.TONE, but held to something a resonator
			// can be: twelve kilohertz is a sensible top for a band-pass and
			// an absurd one for a struck bell.
			nf0 = Lag.kr(noisetone, 0.05).clip(60, 2000);
			nsel = (noisetype - 4).clip(0, 2);
			nring = Select.kr(nsel, [2.6, 0.7, 0.11]);
			nrat = [
				Select.kr(nsel, [1, 1, 1]),
				Select.kr(nsel, [2.76, 2.32, 2]),
				Select.kr(nsel, [5.40, 4.25, 3]),
				Select.kr(nsel, [8.93, 6.63, 4]),
				Select.kr(nsel, [13.34, 9.38, 5]),
				Select.kr(nsel, [18.64, 12.22, 6])
			];
			// amplitudes fall away up the series, steeply for PLUCK where the
			// top partials are what makes a string sound like a bell instead
			nbamp = [
				1,
				Select.kr(nsel, [0.62, 0.70, 0.45]),
				Select.kr(nsel, [0.42, 0.52, 0.26]),
				Select.kr(nsel, [0.28, 0.38, 0.15]),
				Select.kr(nsel, [0.18, 0.27, 0.09]),
				Select.kr(nsel, [0.11, 0.19, 0.05])
			];
			nbank = DynKlank.ar(`[
				nrat.collect({ arg r; (r * nf0).clip(30, 16000) }),
				nbamp,
				nring ! 6
			], nexc, 1, 0, 1);

			// LEVEL-MATCHED to the three washes, and to each other.
			//
			// Straight out of the bank, BELL measured 21.6 dB hotter than
			// PINK - so what read as "a nicer noise source" was mostly "a
			// much louder one", and the three rang at different levels among
			// themselves too. A resonator holds energy in proportion to how
			// long it rings, and measured across these three ring times the
			// dependence is about a fourth power, not the square root you
			// would guess: bell/glass is 3.7x the ring for 2.0 dB, glass/pluck
			// 6.4x for 3.6 dB.
			//
			// The exponent is SOLVED, not guessed. Rendering the three at a
			// known exponent gives their uncorrected levels; setting those
			// equal gives 0.587, and at that value the three land within
			// 0.05 dB of each other and within a decibel of the washes. The
			// first guess was a fourth root - the reasoning was fine and the
			// number was less than half what it needed to be.
			//
			// (The very first measurement said 21.6 dB hot and it was
			// understated: at that level the peaks were sitting in the master
			// limiter, so what came back was already compressed.)
			nbank = nbank * (0.085 / (((nring * 10) + 1) ** 0.587));
			nbank = LeakDC.ar(nbank);
			// panned by a slow wander so a bank of six mono resonators does
			// not sit in a point in the middle of the image
			nbank = Pan2.ar(nbank, LFNoise2.kr(0.13) * 0.6);

			// the raw noises are band-passed; the bank is not - it IS a filter
			nz = BPF.ar(nz, Lag.kr(noisetone, lagt).clip(60, 12000), 0.8) * 2.5;
			nz = (nz * (1 - nres)) + (nbank * nres);
			sig = sig + (nz * env * ns * 4);

			// ---- OUT ----
			// COLOUR is ALWAYS WET. It is the colour stage; a colour stage you
			// can turn down is a bypass with extra steps, and BYPASS is right
			// there. Dropping the dry path also drops two live audio wires,
			// which is what paid for the second granulator.
			outsig = sig;

			// ---- WOW ----
			// Tape drift, on the whole coloured signal rather than on eight
			// delay taps, which is a bigger and more useful gesture.
			//
			// Cubic depth: the bottom two thirds of the knob is the slow
			// unsteadiness that makes digital sound less rigid, and only the
			// top goes properly seasick. A linear knob would have spent its
			// whole travel on either one or the other.
			//
			// The base delay tracks the depth so a WOW of zero costs half a
			// millisecond rather than twelve. Moving the knob therefore glides
			// the pitch, which is what a tape machine does when you lean on it.
			kwd = ((kw * 0.0012) + ((kw ** 3) * 0.010));
			kwm = LFNoise2.kr([0.08 + (kw * 0.5), 0.067 + (kw * 0.41)]) * kwd;
			outsig = DelayC.ar(outsig, 0.05,
				Lag.kr(0.0005 + kwd, 0.3) + kwm);
			kout = [
				Select.ar(bypass, [outsig[0], in[0]]),
				Select.ar(bypass, [outsig[1], in[1]])
			];

			// Everything that has to cross a block boundary, written once. A
			// SynthDef gets one LocalOut and it has to sit here, after the last
			// of the three stage taps exists.
			LocalOut.ar(crushfb ++ [pfbout]);

			// ---- THE MIX ----
			// COLOUR's output plus anything routed straight past everything.
			// This is SIGNAL: there is no mixer stage of its own, because a
			// mixer whose faders are all somewhere else is just a sum.
			mt5 = Amplitude.kr((kout[0] + kout[1]) * 0.5, 0.01, 0.2);
			omix = kout + gfeed.value(oin1, oin2);

			// ---- COMP, the one master control ----
			// Moved here from COLOUR, where it was compressing the colour
			// stage's own output and had nothing to do with the mix. A
			// compressor's job is to hold a MIX together, so it belongs after
			// the mix and before the hidden glue.
			//
			// Same law it had on COLOUR - a Compander whose threshold and
			// slope both walk with the knob, plus make-up - so what it does at
			// a given setting is what it always did.
			mcp = Lag.kr(mcomp, lagt).clip(0, 1);
			outsig = Compander.ar(omix, omix,
				thresh: (1 - (mcp * 0.92)).max(0.02),
				slopeBelow: 1,
				slopeAbove: (1 - (mcp * 0.9)).max(0.1),
				clampTime: 0.006,
				relaxTime: 0.15
			);
			// MAKE-UP, derived rather than guessed.
			//
			// This was `1 + (mcp * 2.5)` when the compressor lived on COLOUR:
			// a flat +3.5 dB at the 0.2 default, applied whether the
			// compressor had taken anything off or not. On a colour stage
			// nobody noticed. On the MASTER it is three and a half decibels
			// of unearned level walking straight into the limiter.
			//
			// The Compander's above-threshold law is out = t + (in - t) * s,
			// so the gain it applies to a full-scale peak is exactly that
			// evaluated at in = 1. Inverting it restores the peak and nothing
			// more: +0.3 dB at the default, +15 dB when the knob is buried,
			// and always precisely what was taken away.
			outsig = outsig / ((1 - (mcp * 0.92)).max(0.02)
				+ ((1 - (1 - (mcp * 0.92)).max(0.02))
					* (1 - (mcp * 0.9)).max(0.1)));

			// THE HIDDEN MASTER CHAIN IS GONE.
			//
			// It was an upward expander, an asymmetric saturator, a little
			// mid/side width and a slow tape wobble, all fixed and all
			// invisible. Every one of them was measurable and defensible on a
			// grain cloud, and on a CLEAN SIGNAL PASSED STRAIGHT THROUGH they
			// were audible as a buffeting distortion - which is what Mick
			// heard the moment SOS at 0 made "input straight to output" a
			// thing you could actually do.
			//
			// The wobble is the obvious culprit and the honest lesson: it is a
			// modulated delay line, so it is pitch modulation, and pitch
			// modulation on a grain cloud reads as motion while the same
			// thing on a sustained input reads as a fault. The saturator adds
			// harmonics that nothing asked for on top.
			//
			// A stage nobody can turn off has to be right for every signal
			// that can reach it. These were right for one of them. Master is
			// COMP - which is on the page, with a number - then the level and
			// the limiter, and nothing else.

			outsig = LeakDC.ar(outsig) * Lag.kr(amp, 0.05) * Lag.kr(fade, 0.06);
			outsig = Limiter.ar(outsig,
				Lag.kr(limceil, 0.1).clip(0.03, 1.0), 0.01);
			mt6 = Amplitude.kr((outsig[0] + outsig[1]) * 0.5, 0.01, 0.2);
			Out.kr(mbus, [mt1, mt2, mt3, mt4, mt5, mt6]);
			Out.ar(outbus, outsig);
		}).add;

		srv.sync;

		synth = Synth.new(\pappus, [
			\inbusl, context.in_b[0].index,
			\inbusr, context.in_b[1].index,
			\outbus, context.out_b.index
		], context.xg, \addToTail);

		// ---- GRAINSWARM commands ----
		this.addCommand("mrate", "f", { arg msg; synth.set(\mrate, msg[1]); });
		this.addCommand("msize", "f", { arg msg; synth.set(\msize, msg[1]); });
		this.addCommand("mcontour", "i", { arg msg; synth.set(\mcontour, msg[1]); });
		this.addCommand("mscan", "f", { arg msg; synth.set(\mscan, msg[1]); });
		this.addCommand("mscanmode", "i", { arg msg; synth.set(\mscanmode, msg[1]); });
		this.addCommand("mdelay", "f", { arg msg; synth.set(\mdelay, msg[1]); });
		this.addCommand("mspray", "f", { arg msg; synth.set(\mspray, msg[1]); });
		this.addCommand("mspraymode", "i", { arg msg; synth.set(\mspraymode, msg[1]); });
		this.addCommand("melen", "f", { arg msg; synth.set(\melen, msg[1]); });
		this.addCommand("mephase", "f", { arg msg; synth.set(\mephase, msg[1]); });
		// the sixteen euclidean gate steps. Lua runs Bjorklund and writes the
		// answer; the engine never computes a pattern.
		this.addCommand("epattern", "ffffffffffffffff", { arg msg;
			patbuf.setn(0, msg[1..16]);
		});
		this.addCommand("mswarm", "f", { arg msg; synth.set(\mswarm, msg[1]); });
		this.addCommand("mswarmmode", "i", { arg msg; synth.set(\mswarmmode, msg[1]); });
		this.addCommand("mlock", "i", { arg msg; synth.set(\mlock, msg[1]); });
		this.addCommand("msos", "f", { arg msg; synth.set(\msos, msg[1]); });
		this.addCommand("mbuflen", "f", { arg msg; synth.set(\mbuflen, msg[1]); });
		this.addCommand("mwinstart", "f", { arg msg; synth.set(\mwinstart, msg[1]); });
		this.addCommand("mwinend", "f", { arg msg; synth.set(\mwinend, msg[1]); });
		this.addCommand("mstrum", "f", { arg msg; synth.set(\mstrum, msg[1]); });

		// FILTERBANK
		//
		// The layout arrives as two forty-eight float arrays. That is a big
		// message to send sixty times a second and it is still the cheap
		// option: the alternative is nine or ten scalar controls plus the
		// whole frequency layout rebuilt in the graph, on control-rate UGens,
		// forty-eight times over.
		this.addCommand("pfrq", "ffffffffffffffffffffffffffffffffffffffffffffffff", { arg msg;
			synth.setn(\pfrq, msg[1..48]);
		});
		this.addCommand("pamp", "ffffffffffffffffffffffffffffffffffffffffffffffff", { arg msg;
			synth.setn(\pamp, msg[1..48]);
		});
		this.addCommand("preso", "f", { arg msg; synth.set(\preso, msg[1]); });

		// SNAPSHOTS: the snapshot duck, and the buffer itself.
		//
		// The buffer is written as 16-bit rather than float. Sixty seconds of
		// float mono is 11 MB and there are a hundred and twenty slots; 16-bit
		// halves it, and what is being stored is a granulation source that is
		// about to be chopped into 50 ms grains and put through a resonator
		// bank. The dynamic range is not the thing that matters here.
		this.addCommand("mtilt", "f", { arg msg; synth.set(\mtilt, msg[1]); });
		this.addCommand("msrc", "i", { arg msg; synth.set(\msrc, msg[1]); });

		// ---- GRAINSWARM 2 ----
		// The same surface again with an n. Generated by hand rather than
		// in a loop because addCommand names have to be greppable: a
		// command you cannot find by searching for it is a command that
		// gets reimplemented.

		this.addCommand("nrate", "f", { arg msg; synth.set(\nrate, msg[1]); });
		this.addCommand("nsize", "f", { arg msg; synth.set(\nsize, msg[1]); });
		this.addCommand("ncontour", "i", { arg msg; synth.set(\ncontour, msg[1]); });
		this.addCommand("nscan", "f", { arg msg; synth.set(\nscan, msg[1]); });
		this.addCommand("nscanmode", "i", { arg msg; synth.set(\nscanmode, msg[1]); });
		this.addCommand("ndelay", "f", { arg msg; synth.set(\ndelay, msg[1]); });
		this.addCommand("nspray", "f", { arg msg; synth.set(\nspray, msg[1]); });
		this.addCommand("nspraymode", "i", { arg msg; synth.set(\nspraymode, msg[1]); });
		this.addCommand("nelen", "f", { arg msg; synth.set(\nelen, msg[1]); });
		this.addCommand("nephase", "f", { arg msg; synth.set(\nephase, msg[1]); });
		this.addCommand("nswarm", "f", { arg msg; synth.set(\nswarm, msg[1]); });
		this.addCommand("nswarmmode", "i", { arg msg; synth.set(\nswarmmode, msg[1]); });
		this.addCommand("nlock", "i", { arg msg; synth.set(\nlock, msg[1]); });
		this.addCommand("nsos", "f", { arg msg; synth.set(\nsos, msg[1]); });
		this.addCommand("nbuflen", "f", { arg msg; synth.set(\nbuflen, msg[1]); });
		this.addCommand("nwinstart", "f", { arg msg; synth.set(\nwinstart, msg[1]); });
		this.addCommand("nwinend", "f", { arg msg; synth.set(\nwinend, msg[1]); });
		this.addCommand("nstrum", "f", { arg msg; synth.set(\nstrum, msg[1]); });
		this.addCommand("ntilt", "f", { arg msg; synth.set(\ntilt, msg[1]); });
		this.addCommand("nsrc", "i", { arg msg; synth.set(\nsrc, msg[1]); });
		this.addCommand("pitches2", "ffffffff", { arg msg;
			synth.setn(\pitches2, msg[1..8]);
		});
		this.addCommand("probs2", "ffffffff", { arg msg;
			synth.setn(\probs2, msg[1..8]);
		});
		this.addCommand("gates2", "ffffffff", { arg msg;
			synth.setn(\gates2, msg[1..8]);
		});
		this.addCommand("epattern2", "ffffffffffffffff", { arg msg;
			patbuf2.setn(0, msg[1..16]);
		});

		// ---- the INPUT selectors, and COLOUR WOW ----
		this.addCommand("kwow", "f", { arg msg; synth.set(\kwow, msg[1]); });

		// ---- THE ROUTING ----
		// Two per stage: how much of each granulator is fed in there.
		// This is the whole mixer - there are no module faders any more.

		this.addCommand("pin1", "f", { arg msg; synth.set(\pin1, msg[1]); });
		this.addCommand("pin2", "f", { arg msg; synth.set(\pin2, msg[1]); });
		this.addCommand("sin1", "f", { arg msg; synth.set(\sin1, msg[1]); });
		this.addCommand("sin2", "f", { arg msg; synth.set(\sin2, msg[1]); });
		this.addCommand("kin1", "f", { arg msg; synth.set(\kin1, msg[1]); });
		this.addCommand("kin2", "f", { arg msg; synth.set(\kin2, msg[1]); });
		this.addCommand("oin1", "f", { arg msg; synth.set(\oin1, msg[1]); });
		this.addCommand("oin2", "f", { arg msg; synth.set(\oin2, msg[1]); });
		this.addCommand("mcomp", "f", { arg msg; synth.set(\mcomp, msg[1]); });

		this.addCommand("fade", "f", { arg msg; synth.set(\fade, msg[1]); });
		this.addCommand("run", "i", { arg msg; synth.set(\run, msg[1]); });

		// SIX POLLS, one per box on SIGNAL's wireframe.
		//
		// getnSynchronous reads the control bus through the server's shared
		// memory rather than asking for it over OSC and waiting, which is what
		// makes a per-frame meter affordable at all.
		//
		// NOT VERIFIED HERE. The CroneEngine stub this is tested against has
		// addPoll as a no-op, so the polls exist in the source and have never
		// once fired in a test. The Lua side is written to notice: a meter that
		// has never received a value draws a dash, not a zero, so a failure on
		// hardware reads as "no data" instead of as "this module is silent".
		6.do { arg i;
			this.addPoll(("meter" ++ (i + 1)).asSymbol, {
				mbus.getnSynchronous(6)[i];
			});
		};
		// wipe the capture buffer - a new project starts on silence, not on
		// whatever the last one happened to leave in there
		this.addCommand("bufclear", "i", { arg msg;
			buf.zero; bufr.zero; buf2.zero; buf2r.zero;
		});
		// SNAPSHOT I/O, addressed by buffer: 1 and 2 are GRAINSWARM 1's left
		// and right, 3 and 4 are GRAINSWARM 2's. Four files rather than two,
		// and an old snapshot with only one file per granulator is loaded by
		// asking for the SAME file twice - it lands in both sides and comes
		// back as the mono recording it was.
		this.addCommand("snapwrite", "isf", { arg msg;
			var b = [buf, bufr, buf2, buf2r][(msg[1] - 1).clip(0, 3)];
			var path = msg[2].asString;
			var n = (msg[3] * context.server.sampleRate).asInteger
				.clip(1, b.numFrames);
			// MAKE THE DIRECTORY HERE.
			//
			// buf.write is asynchronous and reports a missing directory to the
			// server's log, not to the caller - so a snapshot saved into a
			// folder that does not exist looked completely successful, wrote
			// its parameters, and came back silent after a restart. Which is
			// every first save on a fresh device, because nothing else creates
			// this folder.
			//
			// It is done in the engine rather than in Lua because sclang's
			// File.mkdir is always here, and each level is made in turn: mkdir
			// does not create parents, and the script's own data folder may
			// not exist yet either.
			this.prMakeDir(path.dirname);
			b.write(path, "wav", "int16", n, 0, false);
		});
		this.addCommand("snapread", "is", { arg msg;
			var b = [buf, bufr, buf2, buf2r][(msg[1] - 1).clip(0, 3)];
			var path = msg[2].asString;
			if (File.exists(path)) { b.read(path, 0, -1, 0, false) };
		});
		this.addCommand("pshape", "f", { arg msg; synth.set(\pshape, msg[1]); });
		this.addCommand("pshapemode", "i", { arg msg;
			synth.set(\pshapemode, msg[1]);
		});
		this.addCommand("pfb", "f", { arg msg; synth.set(\pfb, msg[1]); });
		this.addCommand("pwet", "f", { arg msg; synth.set(\pwet, msg[1]); });

		// one message for all eight voices, so a grid press is a single set
		this.addCommand("pitches", "ffffffff", { arg msg;
			synth.setn(\pitches, msg[1..8]);
		});
		this.addCommand("probs", "ffffffff", { arg msg;
			synth.setn(\probs, msg[1..8]);
		});
		this.addCommand("sync", "i", { arg msg; synth.set(\t_sync, 1); });

		this.addCommand("gates", "ffffffff", { arg msg;
			synth.setn(\gates, msg[1..8]);
		});

		// ---- DEFORM commands ----
		this.addCommand("scycle", "f", { arg msg; synth.set(\scycle, msg[1]); });
		this.addCommand("sfb", "f", { arg msg; synth.set(\sfb, msg[1]); });
		this.addCommand("stilt", "f", { arg msg; synth.set(\stilt, msg[1]); });
		this.addCommand("stiltxover", "f", { arg msg; synth.set(\stiltxover, msg[1]); });
		this.addCommand("sdiffuse", "f", { arg msg; synth.set(\sdiffuse, msg[1]); });
		this.addCommand("swet", "f", { arg msg; synth.set(\swet, msg[1]); });
		this.addCommand("shold", "i", { arg msg; synth.set(\shold, msg[1]); });
		this.addCommand("taptimes", "ffffffff", { arg msg;
			synth.setn(\taptimes, msg[1..8]);
		});
		this.addCommand("taplevels", "ffffffff", { arg msg;
			synth.setn(\taplevels, msg[1..8]);
		});
		this.addCommand("tappans", "ffffffff", { arg msg;
			synth.setn(\tappans, msg[1..8]);
		});

		this.addCommand("drive", "f", { arg msg; synth.set(\drive, msg[1]); });
		this.addCommand("crush", "f", { arg msg; synth.set(\crush, msg[1]); });
		this.addCommand("crushmode", "i", { arg msg; synth.set(\crushmode, msg[1]); });
		this.addCommand("loss", "f", { arg msg; synth.set(\loss, msg[1]); });
		this.addCommand("noise", "f", { arg msg; synth.set(\noise, msg[1]); });
		this.addCommand("noisetype", "i", { arg msg; synth.set(\noisetype, msg[1]); });
		this.addCommand("noisedecay", "f", { arg msg; synth.set(\noisedecay, msg[1]); });
		this.addCommand("noisetone", "f", { arg msg; synth.set(\noisetone, msg[1]); });
		this.addCommand("noisedyn", "f", { arg msg; synth.set(\noisedyn, msg[1]); });
		this.addCommand("bypass", "i", { arg msg; synth.set(\bypass, msg[1]); });
		this.addCommand("amp", "f", { arg msg; synth.set(\amp, msg[1]); });

		// SIGNAL
		this.addCommand("ingain", "f", { arg msg; synth.set(\ingain, msg[1]); });
		this.addCommand("route", "iiii", { arg msg;
			synth.set(\rinp, msg[1], \rins, msg[2], \rink, msg[3],
				\rmast, msg[4]);
		});
		this.addCommand("limceil", "f", { arg msg; synth.set(\limceil, msg[1]); });
	}

	free {
		synth.free;
		buf.free;
		bufr.free;
		buf2.free;
		buf2r.free;
		mbus.free;
		dbuf.free;
		patbuf.free;
		patbuf2.free;
		envbufs.do({ arg b; b.free });
	}
}
