// SNAPSHOTS's buffer round trip, on a real server.
//
// The symptom that prompted this: snapshots restored their parameters after a
// restart but came back silent. Parameters live in a Lua table; the audio
// lives in a .wav the ENGINE has to write. If that write never lands, nothing
// upstream ever finds out - buf.write is asynchronous and reports failure to
// the server's log, not to the caller.
//
// So: capture something recognisable, ask the engine to write it, and check
// the file. Then wipe the buffer, ask the engine to read it back, and check
// the samples returned.

s = Server.local;
s.options.numInputBusChannels_(2).numOutputBusChannels_(2);
s.waitForBoot({
	var ctx, eng, ok = true, dir, path, n;

	dir = "/tmp/ritratt-io/";
	path = dir ++ "042.wav";
	// deliberately NOT created: a fresh device has no snapshot folder either,
	// and this is the first thing that could be going wrong
	("test dir exists beforehand: " ++ File.exists(dir)).postln;

	ctx = (
		server: s,
		in_b: Array.fill(2, { Bus.audio(s, 1) }),
		out_b: Bus.new('audio', 0, 2),
		xg: Group.new(s)
	);
	s.sync;
	eng = Engine_Pappus.new(ctx, { });
	eng.alloc;
	2.wait;

	if(eng.buf.isNil) { "-> FAIL: no buffer".postln; ok = false; };

	// Something unmistakable in the buffer, filled with /b_gen rather than
	// /b_setn: ninety-six thousand floats do not fit in one OSC message, and
	// the failure is a "buffer overflow" in sendMsg that looks like an engine
	// fault and is not.
	eng.buf.sine1([1, 0.5, 0.25], true, true, true);
	s.sync;
	0.3.wait;

	eng.commands[\snapwrite][\func].value(["snapwrite", path, 2.0]);
	s.sync;
	1.5.wait;

	if(File.exists(path).not) {
		"-> FAIL: the engine did not write the file".postln; ok = false;
	} {
		("-> wrote " ++ File(path, "rb").length ++ " bytes").postln;
	};

	// wipe, then read it back
	eng.buf.zero;
	s.sync; 0.3.wait;
	eng.commands[\snapread][\func].value(["snapread", path]);
	s.sync;
	1.0.wait;

	c = Condition.new;
	eng.buf.getn(24000, 4, { arg v;
		var peak = v.abs.maxItem;
		("-> read back: " ++ v.round(0.001)).postln;
		if(peak < 0.05) {
			"-> FAIL: the buffer is still empty after snapread".postln;
			ok = false;
		};
		c.test = true; c.signal;
	});
	c.wait;

	if(ok) { "SNAPIO OK".postln } { "SNAPIO FAILED".postln };
	0.5.wait;
	s.quit;
	0.5.wait;
	1.exit;
});
