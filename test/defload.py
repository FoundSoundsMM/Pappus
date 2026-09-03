"""Load Engine_Pappus's SynthDef into a REAL scsynth and check it is accepted.

This exists because test/wirecount.py is not enough on its own. It models
scsynth's interconnect-buffer allocation statically, and it undercounts: a def
it scored at 63 against a limit of 64 was rejected by the actual server with

    exception in GraphDef_Load: exceeded number of interconnect buffers.
    *** ERROR: SynthDef pappus not found

That failure is SILENT on norns. The class loads, alloc completes, every
engine command is accepted and goes nowhere, Lua raises nothing, the screen
and the grid work perfectly - and there is no audio at all, ever. It cost a
release to find by ear. So the check is no longer "does the arithmetic say it
fits", it is "does scsynth take it".

Runs offline, in NRT, so no audio device and no norns are needed.

Usage:  python3 test/defload.py [--loops N]

--loops sets how many .wav files audio/ is pretended to hold. It matters: the
number of loop sources is user-controlled - anyone can drop files in there -
and if the peak wire count grows with it, the def stops loading on somebody
else's machine and not on yours.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "..", "lib", "Engine_Pappus.sc")

# norns leaves scsynth on its default 64 interconnect buffers. This is the
# whole point of the test, so it is not a tunable.
WIRE_BUFS = 64

# The engine's instance vars, longest first: a plain \bbuf\b would also eat
# the "buf" inside "patbuf".
IVARS = ("buf2r", "buf2", "bufr", "buf", "dbuf", "patbuf2", "patbuf",
         "mbus", "envnums", "bufdur", "deldur", "loopbufs")


def find_sclang():
    """PATH first, then the places a desktop install actually puts it."""
    from shutil import which
    p = which("sclang")
    if p:
        return p
    for c in ("/Applications/SuperCollider.app/Contents/MacOS/sclang",
              "/usr/local/bin/sclang", "/usr/bin/sclang",
              os.path.expanduser("~/Applications/SuperCollider.app"
                                 "/Contents/MacOS/sclang")):
        if os.path.exists(c):
            return c
    return None


def synthdef_body():
    src = open(ENGINE).read()
    body = src[src.index("SynthDef(\\pappus"):]
    body = body[:body.index("}).add;") + len("}).add;")].replace(").add;", ")")
    for name in IVARS:
        body = re.sub(r"\b%s\b" % name, "~" + name, body)
    left = re.findall(r"(?<!~)\b(?:%s)\b" % "|".join(IVARS), body)
    assert not left, "unstubbed engine vars: %s" % set(left)
    return body


def script(body, workdir, nloops):
    # Buffers are stubbed as Events so that `.bufnum` answers, which is all
    # the graph ever asks of them.
    loops = ", ".join("~mk.(%d)" % (30 + i) for i in range(nloops))
    return """
~mk = { arg n; (bufnum: n) };
~buf = ~mk.(0); ~bufr = ~mk.(1); ~buf2 = ~mk.(2); ~buf2r = ~mk.(3);
~dbuf = ~mk.(4); ~patbuf = ~mk.(5); ~patbuf2 = ~mk.(6);
~mbus = 7;
~envnums = (10..26);
~bufdur = 60.0; ~deldur = 11.0;
~loopbufs = [%(loops)s];

~d = %(body)s;
"DEF BUILT".postln;
~d.writeDefFile("%(dir)s");

~sc = Score([
	[0.0, ["/b_alloc", 0, 2880000, 1]], [0.0, ["/b_alloc", 1, 2880000, 1]],
	[0.0, ["/b_alloc", 2, 2880000, 1]], [0.0, ["/b_alloc", 3, 2880000, 1]],
	[0.0, ["/b_alloc", 4, 528000, 1]],
	[0.0, ["/b_alloc", 5, 16, 1]],      [0.0, ["/b_alloc", 6, 16, 1]],
	// /d_load, not /d_recv: past a certain size sclang cannot pack the def
	// into an OSC message and the render comes back silent with the real
	// error buried under "makeSynthMsgWithTags: buffer overflow".
	[0.0, ["/d_load", "%(dir)s/pappus.scsyndef"]],
	[0.2, ["/s_new", \\pappus, 1000, 0, 0]],
	[0.6, ["/c_set", 0, 0]]
] ++ (10..26).collect({ arg n; [0.0, ["/b_alloc", n, 256, 1]] })
  ++ (30..%(lastloop)d).collect({ arg n; [0.0, ["/b_alloc", n, 48000, 2]] }));

~sc.recordNRT("%(dir)s/score.osc", "%(dir)s/out.aiff", nil, 48000, "AIFF",
	"int16",
	ServerOptions.new.numOutputBusChannels_(2).numInputBusChannels_(2)
		.numWireBufs_(%(wires)d).memSize_(65536),
	action: { "NRT DONE".postln; 0.exit });
""" % dict(body=body, dir=workdir, wires=WIRE_BUFS, loops=loops,
           lastloop=29 + nloops)


def run(nloops):
    sclang = find_sclang()
    if not sclang:
        print("SKIP: no sclang found. Install SuperCollider to run this test.")
        return None
    work = tempfile.mkdtemp(prefix="pappus-defload-")
    path = os.path.join(work, "check.scd")
    open(path, "w").write(script(synthdef_body(), work, nloops))
    try:
        # A syntax error leaves sclang sitting in its REPL forever, so stdin is
        # closed and the wait is bounded.
        out = subprocess.run([sclang, "-i", "none", path],
                             stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, timeout=300)
        log = out.stdout + out.stderr
    except subprocess.TimeoutExpired:
        subprocess.run(["pkill", "-f", "sclang -i none"])
        return ["sclang timed out - probably a syntax error in the engine"]

    fails = []
    if "DEF BUILT" not in log:
        fails.append("the SynthDef did not build at all")
    for marker, why in (
            ("exceeded number of interconnect buffers",
             "TOO MANY AUDIO WIRES - scsynth refused the def. On norns this is "
             "silent: the synth never starts and there is no audio at all."),
            ("SynthDef pappus not found",
             "the def was rejected, so /s_new had nothing to make"),
            ("FAILURE IN SERVER /s_new", "the synth could not be created")):
        if marker in log:
            fails.append(why)
    if not fails and "NRT DONE" not in log:
        fails.append("the render never finished")
    if fails:
        tail = "\n".join(l for l in log.splitlines()
                         if any(k in l.lower()
                                for k in ("error", "exception", "failure")))
        fails.append("scsynth said:\n" + (tail or log[-1500:]))
    return fails


if __name__ == "__main__":
    nloops = 5
    if "--loops" in sys.argv:
        nloops = int(sys.argv[sys.argv.index("--loops") + 1])
    print("loading the SynthDef into scsynth with %d wire buffers, "
          "%d loop file(s) in audio/ ..." % (WIRE_BUFS, nloops))
    fails = run(nloops)
    if fails is None:
        sys.exit(0)
    if fails:
        for f in fails:
            print("  FAIL " + f)
        sys.exit(1)
    print("DEF LOAD TEST OK  (scsynth accepted the def and made the synth)")
