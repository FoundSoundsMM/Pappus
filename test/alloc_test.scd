// Live allocation test for Engine_Pappus.
//
// Boots a real scsynth, builds a fake norns context (in_b is an ARRAY of two
// mono busses, out_b is one stereo bus), runs alloc, then invokes every
// registered command exactly the way norns would. This is the step that
// catches bus wiring and control-array bugs; compiling and building the
// SynthDef graph do not.

(
s = Server.local;
// norns leaves memSize and numWireBufs at their defaults (the raise in
// Crone.sc is commented out), so this test must too - overriding them here
// would hide exactly the failures the device hits.
s.options.numInputBusChannels_(2).numOutputBusChannels_(2);
s.waitForBoot({
	var ctx, eng, ok = true, fails = 0, names, cond;

	ctx = (
		server: s,
		in_b: Array.fill(2, { Bus.audio(s, 1) }),
		out_b: Bus.new('audio', 0, 2),
		xg: Group.new(s)
	);
	s.sync;
	("in_b indices: " ++ ctx.in_b.collect(_.index)).postln;
	("out_b index:  " ++ ctx.out_b.index).postln;

	eng = Engine_Pappus.new(ctx, { "-> doneCallback fired".postln });
	eng.alloc;
	2.wait;

	if(eng.synth.isNil) {
		"-> FAIL: engine synth is nil".postln; ok = false;
	} {
		("-> synth nodeID: " ++ eng.synth.nodeID).postln;
	};

	// buffers
	if(eng.buf.isNil or: { eng.buf.numFrames != (60 * s.sampleRate) }) {
		("-> FAIL: capture buffer wrong: " ++ eng.buf).postln; ok = false;
	} {
		("-> capture buffer: " ++ eng.buf.numFrames ++ " frames, "
			++ eng.buf.numChannels ++ " ch").postln;
	};
	if(eng.envbufs.size != 17) {
		"-> FAIL: expected 17 envelope buffers".postln; ok = false;
	} { ("-> envelope buffers: " ++ eng.envbufs.size).postln };
	if(eng.patbuf.isNil) { "-> FAIL: no pattern buffer".postln; ok = false; };

	// read the buffers back off the server: the NRT harness fills its own
	// copies, so only this checks the engine's fill code actually ran
	cond = Condition.new;
	eng.envbufs[8].getn(0, 256, { arg vals;
		var peak = vals.maxItem, ends = vals[0].abs.max(vals[255].abs);
		("-> env[8] (sine) peak " ++ peak.round(0.001)
			++ ", ends " ++ ends.round(0.001)
			++ ", peak at frame " ++ vals.indexOf(peak)).postln;
		if(peak < 0.98 or: { ends > 0.02 }) {
			"-> FAIL: envelope buffer not filled correctly".postln; ok = false;
		};
		cond.test = true; cond.signal;
	});
	cond.wait;

	cond = Condition.new;
	eng.envbufs[0].getn(0, 256, { arg vals;
		("-> env[0] (down-ramp) peak at frame " ++ vals.indexOf(vals.maxItem)
			++ " of 256").postln;
		if(vals.indexOf(vals.maxItem) > 40) {
			"-> FAIL: down-ramp envelope peaks too late".postln; ok = false;
		};
		cond.test = true; cond.signal;
	});
	cond.wait;

	cond = Condition.new;
	eng.patbuf.getn(0, 16, { arg vals;
		("-> pattern: " ++ vals.asInteger).postln;
		if(vals.every({ arg v; v == 0 })) {
			"-> FAIL: pattern buffer is empty".postln; ok = false;
		};
		cond.test = true; cond.signal;
	});
	cond.wait;

	// every command, invoked as norns invokes it: msg[0] is the name
	names = eng.commands.keys.asArray.sort;
	("-> " ++ names.size ++ " commands registered").postln;
	names.do { arg k;
		var c = eng.commands[k], fmt = c[\format], args, msg;
		// collect over a String builds another String, which cannot hold the
		// mixed types an OSC arg list needs. build the Array explicitly.
		args = [];
		fmt.asString.do { arg ch, i;
			args = args.add(
				if(ch == $i) { 1 } { if(ch == $s) { "/tmp/alloc-snap.wav" } { (i + 1) / 10 } }
			);
		};
		msg = [k] ++ args;
		try {
			c[\func].value(msg);
		} { arg err;
			("-> FAIL command " ++ k ++ ": " ++ err.errorString).postln;
			fails = fails + 1; ok = false;
		};
	};
	s.sync;
	("-> commands invoked, " ++ fails ++ " failures").postln;

	// the control arrays specifically: eight values in one message
	try {
		eng.commands[\pitches][\func].value([\pitches, 0, 7, 12, -5, 0, 3, 5, -12]);
		eng.commands[\gates][\func].value([\gates, 1, 1, 1, 1, 0, 0, 0, 0]);
		s.sync;
		"-> pitches/gates control arrays set".postln;
	} { arg err;
		("-> FAIL setn: " ++ err.errorString).postln; ok = false;
	};

	// realistic settings, then let it run
	eng.synth.set(\mwet, 1, \mrate, 12, \msize, 0.15, \mcontour, 12,
		\mscan, 0.5, \mscanmode, 2, \mspray, 0.3, \mspraymode, 1,
		\mpattern, 0.5, \drive, 0.6, \crush, 0.4, \noise, 0.5, \wet, 1);
	1.wait;
	eng.synth.set(\mlock, 1, \mscanmode, 3, \mdelay, 0.5);
	1.wait;
	eng.synth.set(\mlock, 0, \mscanmode, 4, \mspraymode, 3, \bypass, 1);
	1.wait;

	s.queryAllNodes;
	1.wait;

	eng.free;
	1.wait;

	if(ok) { "PAPPUS ALLOC TEST OK".postln } { "PAPPUS ALLOC TEST FAILED".postln };
	0.exit;
});
)
