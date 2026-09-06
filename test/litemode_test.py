"""FULL or LITE: does each side name the same machine?

The engine compiles one of two graphs depending on what it is running on
(prLiteMode in Engine_Pappus.sc) and the script builds one of two instruments
off the same question (lite_mode in pappus.lua). THE TWO HAVE TO AGREE. If the
engine says LITE and the script says FULL, GRAINSWARM 2 gets two pages, a
waveform, a grid lane and a visualiser over a granulator that was never built -
silence with a picture of a sound on top, which is exactly the class of failure
this codebase keeps paying for. If it goes the other way, the pages are gone
and the granulator is running anyway.

So both are asked the same eleven questions here, against the device-tree
strings real machines actually publish, and the answers are compared to each
other as well as to what they should be.

Neither side can be imported: prLiteMode is a method on a class that needs
CroneEngine, and pappus.lua wants the whole norns API. So each is driven the
way the rest of test/ drives them - the sclang method body is lifted out and
pointed at fixture files, and the Lua is run through mock_norns with a fake
data folder and a fake /proc.

Usage:  python3 test/litemode_test.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ENGINE = os.path.join(ROOT, "lib", "Engine_Pappus.sc")
SCRIPT = os.path.join(ROOT, "pappus.lua")

NUL = "\0"

# label, /proc/device-tree/compatible, /proc/device-tree/model, mode.txt, LITE?
#
# The compatible strings are NUL-separated lists, which is what the devicetree
# filesystem actually hands over and why both sides search rather than parse.
CASES = [
    ("Pi 4 model B",
     "raspberrypi,4-model-b" + NUL + "brcm,bcm2711" + NUL,
     "Raspberry Pi 4 Model B Rev 1.4" + NUL, None, False),
    ("Pi 5",
     "raspberrypi,5-model-b" + NUL + "brcm,bcm2712" + NUL,
     "Raspberry Pi 5 Model B Rev 1.0" + NUL, None, False),
    ("CM4",
     "raspberrypi,4-compute-module" + NUL + "brcm,bcm2711" + NUL,
     "Raspberry Pi Compute Module 4 Rev 1.1" + NUL, None, False),
    ("Pi 400",
     "raspberrypi,400" + NUL + "brcm,bcm2711" + NUL,
     "Raspberry Pi 400 Rev 1.0" + NUL, None, False),
    # the one that matters: a factory norns names itself only in `model`, and
    # its SoC is bcm2837 either way
    ("factory norns (CM3)",
     "raspberrypi,3-compute-module" + NUL + "brcm,bcm2837" + NUL,
     "Raspberry Pi Compute Module 3 Rev 1.0" + NUL, None, True),
    ("Pi 3B+ shield",
     "raspberrypi,3-model-b-plus" + NUL + "brcm,bcm2837" + NUL,
     "Raspberry Pi 3 Model B Plus Rev 1.3" + NUL, None, True),
    ("Pi Zero 2 W",
     "raspberrypi,model-zero-2-w" + NUL + "brcm,bcm2837" + NUL,
     "Raspberry Pi Zero 2 W Rev 1.0" + NUL, None, True),
    # a desktop has no device tree at all, and unknown is not the same as slow
    ("no device tree", None, None, None, False),
    # ...and the override beats the machine, in both directions
    ("Pi 3 + mode.txt full",
     "raspberrypi,3-compute-module" + NUL + "brcm,bcm2837" + NUL,
     None, "full\n", False),
    ("Pi 4 + mode.txt lite",
     "raspberrypi,4-model-b" + NUL + "brcm,bcm2711" + NUL,
     None, "lite\n", True),
    ("desktop + mode.txt lite", None, None, "lite\n", True),
]


def find_sclang():
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


def find_lua():
    from shutil import which
    for name in ("lua", "lua5.4", "lua5.3"):
        p = which(name)
        if p:
            return p
    return None


def probe_body():
    """prLiteMode, lifted out and made callable on its own.

    Two edits, and only two. The file paths become injectable so the same code
    can be pointed at fixtures instead of at /proc, and `^` becomes a block's
    non-local exit - a method return is a PARSE ERROR inside an interpreted
    Function, and sclang answers a parse error by sitting in its REPL with
    nothing on stdout, so getting this wrong looks exactly like a hang.
    """
    src = open(ENGINE).read()
    i = src.index("\tprLiteMode {")
    j = src.index("\n\t}\n", i) + len("\n\t}\n")
    body = src[i + len("\tprLiteMode "):j].rstrip()
    body = body.replace(
        'Platform.userHomeDir ++ "/dust/data/pappus/mode.txt"', "~modepath")
    body = body.replace(
        '#["/proc/device-tree/compatible", "/proc/device-tree/model"]',
        "~dtfiles")
    body = (body.replace("^true", "ret.value(true)")
                .replace("^false", "ret.value(false)")
                .replace('^#["bcm2711"', 'ret.value(#["bcm2711"')
                .replace("dt.contains(k) }).not;", "dt.contains(k) }).not);"))
    assert "^" not in body, "a return was left unconverted:\n" + body
    return "{ block { arg ret;" + body[body.index("{") + 1:].rstrip() + " }"


def engine_answers(work):
    sclang = find_sclang()
    if not sclang:
        return None
    fix = os.path.join(work, "sc")
    os.makedirs(fix, exist_ok=True)
    lines = []
    for label, compat, model, mode, _want in CASES:
        # a fresh folder per case, so a file from the last one cannot be read
        # by this one - the whole point is what happens when a file is ABSENT
        sub = os.path.join(fix, label.replace(" ", "_").replace("/", "_"))
        os.makedirs(sub, exist_ok=True)
        dtf = []
        if compat is not None:
            open(os.path.join(sub, "compatible"), "w").write(compat)
            dtf.append('"%s/compatible"' % sub)
        if model is not None:
            open(os.path.join(sub, "model"), "w").write(model)
            dtf.append('"%s/model"' % sub)
        if mode is not None:
            open(os.path.join(sub, "mode.txt"), "w").write(mode)
            mpath = '"%s/mode.txt"' % sub
        else:
            mpath = '"%s/absent"' % sub
        lines.append("~dtfiles = [%s]; ~modepath = %s;"
                     % (", ".join(dtf), mpath))
        lines.append('("ANSWER " ++ ~detect.value).postln;')
    scd = ("~detect = %s;\n%s\n0.exit;\n"
           % (probe_body(), "\n".join(lines)))
    path = os.path.join(work, "probe.scd")
    open(path, "w").write(scd)
    try:
        r = subprocess.run([sclang, "-i", "none", path],
                           stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=300)
    except subprocess.TimeoutExpired:
        subprocess.run(["pkill", "-f", "sclang -i none"])
        return ["sclang timed out - a parse error in the lifted method body"]
    log = r.stdout + r.stderr
    return [l.split()[1] == "true"
            for l in log.splitlines() if l.startswith("ANSWER ")]


LUA_PROBE = r'''
package.path = "test/?.lua;" .. package.path
local mock = require("mock_norns")
mock.install("lib/Engine_Pappus.sc")
-- lite_mode reads norns.state.data for the override, so point it at the
-- fixture folder before the script's main chunk runs
norns.state.data = "%s/"

-- ...and it reads the device tree from two ABSOLUTE paths, which on a desktop
-- do not exist. Redirecting them at io.open is what lets the real parsing -
-- the NUL-separated compatible list, the lowercasing, the fast-machine list -
-- be given a factory norns to look at rather than being skipped. Only these
-- two names are touched; everything else opens as itself.
local FAKE = {
  ["/proc/device-tree/compatible"] = %s,
  ["/proc/device-tree/model"]      = %s,
}
local real_open = io.open
io.open = function(path, mode, ...)
  local sub = FAKE[path]
  if sub ~= nil then
    if sub == false then return nil, path .. ": no such file" end
    return real_open(sub, mode, ...)
  end
  return real_open(path, mode, ...)
end

dofile("pappus.lua")
io.open = real_open
print("ANSWER " .. tostring(LITE))
'''


def lua_answers(work):
    lua = find_lua()
    if not lua:
        return None
    out = []
    for label, compat, model, mode, _want in CASES:
        sub = os.path.join(work, "lua", label.replace(" ", "_").replace("/", "_"))
        os.makedirs(sub, exist_ok=True)
        if mode is not None:
            open(os.path.join(sub, "mode.txt"), "w").write(mode)
        def fixture(name, text):
            if text is None:
                return "false"
            fp = os.path.join(sub, name)
            open(fp, "w").write(text)
            return '"%s"' % fp
        path = os.path.join(sub, "probe.lua")
        open(path, "w").write(LUA_PROBE % (
            sub, fixture("compatible", compat), fixture("model", model)))
        env = dict(os.environ)
        env.pop("PAPPUS_LITE", None)
        r = subprocess.run([lua, path], capture_output=True, text=True,
                           cwd=ROOT, env=env, timeout=120)
        line = [l for l in (r.stdout + r.stderr).splitlines()
                if l.startswith("ANSWER ")]
        if not line:
            return ["lua probe said nothing:\n" + (r.stdout + r.stderr)[-1200:]]
        out.append(line[0].split()[1] == "true")
    return out


def lua_source_matches():
    """The two implementations, compared as text rather than as behaviour.

    The Lua side cannot be pointed at a fake /proc - it reads the absolute
    path, and on a desktop there is nothing there - so the eleven machines can
    only be put to the engine. What can be checked on this side is that the
    script is asking the SAME question: same two files, same fast list, same
    override name. A key added to one list and not the other is precisely how
    the two would drift apart and nothing would say so.
    """
    lua = open(SCRIPT).read()
    sc = open(ENGINE).read()
    bad = []
    for token in ("/proc/device-tree/compatible", "/proc/device-tree/model",
                  "mode.txt", "PAPPUS_LITE",
                  "bcm2711", "bcm2712", "pi 4", "pi 5",
                  "compute module 4", "compute module 5"):
        if token not in lua:
            bad.append("pappus.lua's lite_mode never mentions %r" % token)
        if token not in sc:
            bad.append("Engine_Pappus.sc's prLiteMode never mentions %r"
                       % token)
    return bad


if __name__ == "__main__":
    fails = list(lua_source_matches())
    work = tempfile.mkdtemp(prefix="pappus-litemode-")

    eng = engine_answers(work)
    if eng is None:
        print("SKIP engine side: no sclang found.")
    elif eng and isinstance(eng[0], str):
        fails.extend(eng)
    elif len(eng) != len(CASES):
        fails.append("the engine answered %d of %d cases"
                     % (len(eng), len(CASES)))
    else:
        for (label, _c, _m, _mo, want), got in zip(CASES, eng):
            mark = "ok" if got == want else "FAIL"
            print("  engine  %-24s lite=%-5s want=%-5s %s"
                  % (label, got, want, mark))
            if got != want:
                fails.append("engine called %s %s, wanted %s"
                             % (label, "LITE" if got else "FULL",
                                "LITE" if want else "FULL"))

    lua = lua_answers(work)
    if lua is None:
        print("SKIP script side: no lua found.")
    elif lua and isinstance(lua[0], str):
        fails.extend(lua)
    else:
        for (label, _c, _m, _mo, want), got in zip(CASES, lua):
            mark = "ok" if got == want else "FAIL"
            print("  script  %-24s lite=%-5s want=%-5s %s"
                  % (label, got, want, mark))
            if got != want:
                fails.append("script called %s %s, wanted %s"
                             % (label, "LITE" if got else "FULL",
                                "LITE" if want else "FULL"))
        # ...and the claim this test exists for: not just that each side is
        # right, but that they are right TOGETHER, machine by machine.
        if eng and not isinstance(eng[0], str):
            for (label, _c, _m, _mo, _w), e, l in zip(CASES, eng, lua):
                if e != l:
                    fails.append(
                        "engine and script DISAGREE about %s: %s vs %s"
                        % (label, "LITE" if e else "FULL",
                           "LITE" if l else "FULL"))

    if fails:
        for f in fails:
            print("  FAIL " + f)
        sys.exit(1)
    print("LITE MODE TEST OK  (both sides name the same machine)")
