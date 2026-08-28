"""Build standalone sclang NRT harnesses from Engine_Pappus's SynthDef.

The SynthDef closes over the engine's instance vars (buf, patbuf, envnums,
bufdur), so it cannot be evaluated on its own. We stub those with fixed
buffer numbers and allocate/fill the matching buffers in the Score.
"""
import math
import subprocess
import os

ENGINE = os.path.join(os.path.dirname(__file__), "..", "lib", "Engine_Pappus.sc")

CAPTURE_BUF = 0
ENV_BUF0 = 1          # 17 envelope buffers, 1..17
PAT_BUF = 18
DEL_BUF = 19
METER_BUS = 60        # six control-bus channels for SIGNAL's meters
CAPTURE_BUF2 = 20     # GRAINSWARM 2's capture buffer
PAT_BUF2 = 21         # ...and its euclidean pattern
# ...and the RIGHT halves. The capture is stereo now - two mono buffers per
# granulator, because GrainBuf reads a mono buffer - so there are four.
CAPTURE_BUFR = 22
CAPTURE_BUF2R = 23
DELDUR = 11.0
SR = 48000
BUFDUR = 60.0
ENVSIZE = 256


def synthdef_body(patches=()):
    src = open(ENGINE).read()
    start = src.index("SynthDef(\\pappus")
    end = src.index("}).add;") + len("}).add;")
    body = src[start:end].replace(").add;", ")")
    for old, new in patches:
        assert old in body, "patch target not found: %r" % old[:60]
        body = body.replace(old, new)
    return body


def env_values(contour):
    """Same shape the engine builds: Env([0,1,0],[p,1-p],\\sine)."""
    p = min(max(0.5 + contour * 0.5, 0.04), 0.96)
    out = []
    for i in range(ENVSIZE):
        t = i / (ENVSIZE - 1)
        if t < p:
            x = t / p
        else:
            x = 1 - ((t - p) / (1 - p))
        # \sine curve on a 0..1 ramp is a raised-cosine
        out.append(0.5 - 0.5 * math.cos(math.pi * min(max(x, 0.0), 1.0)))
    return out


# patbuf is EUCLID's sixteen gate steps now, not the old pitch sequence. It
# was left as the pitch sequence for one version, whose first element is 0 -
# so every grain was gated off and every NRT render came back silent. The
# analysis then divided silence by silence and reported 0.0 dB everywhere,
# which reads as "no change" rather than as "nothing happened".
PATTERN = [1] * 16


def alloc_msgs(fill_env=True):
    msgs = [
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (CAPTURE_BUF, int(BUFDUR * SR)),
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (PAT_BUF, len(PATTERN)),
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (DEL_BUF, int(DELDUR * SR)),
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (CAPTURE_BUF2, int(BUFDUR * SR)),
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (CAPTURE_BUFR, int(BUFDUR * SR)),
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (CAPTURE_BUF2R, int(BUFDUR * SR)),
        "[0.0, ['/b_alloc', %d, %d, 1]]" % (PAT_BUF2, len(PATTERN)),
        "[0.0, ['/b_setn', %d, 0, %d, %s]]"
        % (PAT_BUF2, len(PATTERN), ", ".join(str(v) for v in PATTERN)),
        "[0.0, ['/b_setn', %d, 0, %d, %s]]"
        % (PAT_BUF, len(PATTERN), ", ".join(str(v) for v in PATTERN)),
    ]
    for i in range(17):
        n = ENV_BUF0 + i
        msgs.append("[0.0, ['/b_alloc', %d, %d, 1]]" % (n, ENVSIZE))
        if fill_env:
            vals = env_values((i / 8.0) - 1.0)
            msgs.append(
                "[0.0, ['/b_setn', %d, 0, %d, %s]]"
                % (n, ENVSIZE, ", ".join("%.5f" % v for v in vals))
            )
    return msgs


STUBS = """
~buf = (bufnum: {cap});
~buf2 = (bufnum: {cap2});
~bufr = (bufnum: {capr});
~buf2r = (bufnum: {cap2r});
~patbuf = (bufnum: {pat});
~patbuf2 = (bufnum: {pat2});
~mbus = {mbus};
~dbuf = (bufnum: {del_});
~envnums = ({e0}..{e1});
~bufdur = {bufdur};
""".format(cap=CAPTURE_BUF, cap2=CAPTURE_BUF2,
        capr=CAPTURE_BUFR, cap2r=CAPTURE_BUF2R, pat=PAT_BUF, pat2=PAT_BUF2,
        mbus=METER_BUS, del_=DEL_BUF, e0=ENV_BUF0, e1=ENV_BUF0 + 16, bufdur=BUFDUR)


def build(script_body, patches=(), fill_env=True):
    import re
    body = synthdef_body(patches)
    # Point the engine's instance vars at the stubs. Word boundaries matter:
    # a plain replace of "buf" also mangles "patbuf" into "pat~buf".
    for name in ("buf", "bufr", "buf2", "buf2r", "dbuf", "patbuf", "patbuf2",
                 "mbus", "envnums", "bufdur", "deldur"):
        body = re.sub(r"\b%s\b" % name, "~" + name, body)
    leftovers = re.findall(
        r"(?<!~)\b(?:buf2r|buf2|bufr|patbuf2|buf|dbuf|patbuf|mbus|envnums"
        r"|bufdur|deldur)\b",
        body)
    assert not leftovers, "unstubbed engine vars: %s" % set(leftovers)
    assert "pat~buf" not in body and "~~" not in body, "substitution damaged the body"
    # The def is embedded in the Score as a message. Past a certain size sclang
    # cannot pack it - "makeSynthMsgWithTags: buffer overflow" - and every
    # render comes back silent with "SynthDef pappus not found" buried in the
    # log. Write it to disk and /d_load it instead, which has no such limit.
    loader = ('\n~qdefdir = "/tmp/pappus-nrt";\n'
              "File.mkdir(~qdefdir);\n"
              "~qdef.writeDefFile(~qdefdir);\n"
              '~qrecv = ["/d_load", ~qdefdir ++ "/pappus.scsyndef"];\n')
    return STUBS + "\n~alloc = [\n" + ",\n".join(alloc_msgs(fill_env)) + "\n];\n" \
        + "~qdef = " + body + ";\n" + loader + script_body


def run(scd_text, path, timeout=600, expect="DONE"):
    """Run a harness script. A syntax error leaves sclang sitting in its REPL
    forever, so treat a timeout as a failure and surface whatever it printed."""
    open(path, "w").write(scd_text)
    env = dict(os.environ)
    env.update(QT_QPA_PLATFORM="offscreen",
               QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu",
               XDG_RUNTIME_DIR="/tmp/runtime-root")
    try:
        r = subprocess.run(["sclang", "-i", "none", path], capture_output=True,
                           text=True, timeout=timeout, env=env)
        out = r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") + \
              (e.stderr or b"").decode(errors="replace")
        subprocess.run(["pkill", "-f", "sclang -i none"])
        raise RuntimeError("sclang timed out. tail:\n" + _errs(out))
    if expect and expect not in out:
        raise RuntimeError("harness did not reach %r. errors:\n%s"
                           % (expect, _errs(out)))
    return out


def _errs(out):
    keep = [l for l in out.splitlines()
            if ("ERROR" in l or "error" in l or "not understood" in l
                or "WARNING" in l) and "WebEngine" not in l]
    return "\n".join(keep[-25:]) or "\n".join(out.splitlines()[-25:])


# ---------------------------------------------------------------------------
# The engine arguments the Lua ACTUALLY sends at init.
#
# Hand-written arg strings in these tests have now diverged from the script
# three separate times, and every time the test stayed green while the device
# was broken:
#
#   * patbuf still held the old pitch sequence after EUCLID repurposed it, so
#     every grain was gated off and every render was silent;
#   * mix_test still set \fwet after FILTRU became FILTERBANK, so the return
#     measured 0.0 dB - which reads as "no change", not as "not connected";
#   * spettru_test hardcoded \pslicehz 200 while the script's DEFAULT is CONT,
#     which sends 2000 - and at 2000 the latch never fired and the whole page
#     was silent out of the box.
#
# So stop writing them by hand. This runs the real Lua against the mock, lets
# init() do whatever init() does, and reports what the engine was told.
# ---------------------------------------------------------------------------

# commands whose payload is an array, and the SynthDef arg they set. epattern
# writes a BUFFER rather than a control, so it is not in here.
ARRAY_CMDS = {
    "pitches": "pitches", "gates": "gates", "probs": "probs",
    "pitches2": "pitches2", "gates2": "gates2", "probs2": "probs2",
    "taptimes": "taptimes", "taplevels": "taplevels", "tappans": "tappans",
    "pfrq": "pfrq", "pamp": "pamp",
    "fone": "fone", "ftwo": "ftwo", "fthr": "fthr",
    "gone": "gone", "gtwo": "gtwo", "gthr": "gthr",
}
SKIP_CMDS = {"epattern", "epattern2", "sync"}


def _dump(presets=()):
    """Run pappus.lua under the mock and return {command: [args]} after init."""
    import json
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sets = "\n".join("params:set(%r, %s)" % (k, v) for k, v in presets)
    lua = """
package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
dofile("pappus.lua")
init()
%s
local out = {}
for k, v in pairs(mock.calls.last) do
  local parts = {}
  for i, x in ipairs(v) do parts[i] = string.format("%%.9g", x) end
  out[#out + 1] = string.format("%%q:[%%s]", k, table.concat(parts, ","))
end
print("{" .. table.concat(out, ",") .. "}")
""" % sets
    path = "/tmp/pappus-initdump.lua"
    open(path, "w").write(lua)
    r = subprocess.run(["lua5.3", path], capture_output=True, text=True,
                       cwd=root, timeout=120)
    line = [l for l in r.stdout.splitlines() if l.startswith("{")]
    if not line:
        raise RuntimeError("init dump produced nothing:\n" + r.stdout + r.stderr)
    return json.loads(line[-1])


def init_args(presets=(), overrides=()):
    """Return (scalar_arg_string, setn_messages) as the Lua would send them.

    `presets` are params:set calls applied after init, so a test can ask for
    "what does the script send when WET is up" rather than guessing.
    `overrides` are (argname, value) pairs applied last, for the one or two
    things a given render wants to differ.
    """
    d = _dump(presets)
    over = dict(overrides)
    scal, setn = [], []
    for cmd, vals in sorted(d.items()):
        if cmd in SKIP_CMDS:
            continue
        if cmd in ARRAY_CMDS:
            setn.append("[0.0, ['/n_setn', 1001, \\%s, %d, %s]]"
                        % (ARRAY_CMDS[cmd], len(vals),
                           ",".join("%.9g" % v for v in vals)))
        elif len(vals) == 1:
            scal.append((cmd, vals[0]))
    for k, v in over.items():
        scal = [(a, b) for a, b in scal if a != k] + [(k, v)]
    return (", ".join("\\%s, %.9g" % (k, v) for k, v in scal),
            ",\n\t\t".join(setn))
