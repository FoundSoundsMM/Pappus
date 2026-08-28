"""Count the audio-rate interconnect ("wire") buffers a SynthDef needs.

scsynth allocates a FIXED pool of wire buffers - 64 by default, and norns
never raises it - shared by every running synth graph. A def that needs more
is rejected at load with "exceeded number of interconnect buffers", the synth
never starts, and the engine is simply silent: no Lua error, no maiden
warning, nothing to see. That failure mode is expensive to diagnose on
hardware, so measure it here instead.

The allocator reuses buffers: an audio wire is claimed when the unit that
writes it runs, and returned to the free list once the last unit that reads
it has run. This walks the compiled def in unit order and reports the high
water mark, plus where in the graph it happens.

Usage:  python3 test/wirecount.py [path/to/Engine_Foo.sc]
"""
import struct
import sys
import os
import subprocess
import tempfile

RATE_AUDIO = 2


class Reader:
    def __init__(self, b):
        self.b, self.i = b, 0

    def u8(self):
        v = self.b[self.i]; self.i += 1; return v

    def i8(self):
        v = struct.unpack_from(">b", self.b, self.i)[0]; self.i += 1; return v

    def i16(self):
        v = struct.unpack_from(">h", self.b, self.i)[0]; self.i += 2; return v

    def i32(self):
        v = struct.unpack_from(">i", self.b, self.i)[0]; self.i += 4; return v

    def f32(self):
        v = struct.unpack_from(">f", self.b, self.i)[0]; self.i += 4; return v

    def pstr(self):
        n = self.u8()
        s = self.b[self.i:self.i + n].decode("utf-8", "replace"); self.i += n
        return s


def parse(path):
    r = Reader(open(path, "rb").read())
    assert r.b[:4] == b"SCgf", "not a synthdef file"
    r.i = 4
    version = r.i32()
    assert version == 2, "expected synthdef version 2, got %d" % version
    ndefs = r.i16()
    defs = []
    for _ in range(ndefs):
        name = r.pstr()
        for _ in range(r.i32()):
            r.f32()                              # constants
        for _ in range(r.i32()):
            r.f32()                              # param defaults
        for _ in range(r.i32()):
            r.pstr(); r.i32()                    # param names
        ugens = []
        for _ in range(r.i32()):
            cls = r.pstr()
            r.i8()                               # unit rate
            nin, nout = r.i32(), r.i32()
            r.i16()                              # special index
            ins = [(r.i32(), r.i32()) for _ in range(nin)]
            outs = [r.i8() for _ in range(nout)]
            ugens.append((cls, ins, outs))
        for _ in range(r.i16()):                 # variants
            r.pstr()
            for _ in range(0):
                pass
        defs.append((name, ugens))
    return defs


def wire_peak(ugens):
    """Replay scsynth's allocation: claim a buffer per audio output, release it
    once every reader has run. Returns (peak, [(unit index, class, live)])."""
    def is_audio(src, out):
        return src >= 0 and ugens[src][2][out] == RATE_AUDIO

    pending = {}                                  # (unit, output) -> reads left
    for _, ins, _ in ugens:
        for w in ins:
            if is_audio(*w):
                pending[w] = pending.get(w, 0) + 1
    held, peak, trace, at_peak = set(), 0, [], None
    for ui, (cls, ins, outs) in enumerate(ugens):
        for o, rate in enumerate(outs):
            # an output nothing reads never needs a buffer
            if rate == RATE_AUDIO and pending.get((ui, o), 0) > 0:
                held.add((ui, o))
        if len(held) > peak:
            peak = len(held)
            at_peak = (ui, cls, sorted(held))
        trace.append((ui, cls, len(held)))
        for w in ins:
            if is_audio(*w):
                pending[w] -= 1
                if pending[w] == 0:
                    held.discard(w)
    return peak, trace, at_peak


SCRIPT = r'''
~qdef.writeDefFile("%s");
"WROTE".postln;
0.exit;
'''


def def_bytes(engine=None, patches=()):
    """Compile the engine's SynthDef and write it out as a .scsyndef."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import harness as H
    if engine:
        H.ENGINE = engine
    d = tempfile.mkdtemp()
    H.run(H.build(SCRIPT % d, patches=patches), os.path.join(d, "w.scd"),
          timeout=300, expect="WROTE")
    return os.path.join(d, "pappus.scsyndef")


if __name__ == "__main__":
    eng = sys.argv[1] if len(sys.argv) > 1 else None
    path = def_bytes(eng)
    name, ugens = parse(path)[0]
    peak, trace, at_peak = wire_peak(ugens)
    print("%s: %d ugens, peak %d audio wire buffers (scsynth has 64)"
          % (name, len(ugens), peak))
    ui, cls, held = at_peak
    print("\npeak at unit %d (%s). What is being held there, by producer:" % (ui, cls))
    from collections import Counter
    who = Counter("%s#%d" % (ugens[u][0], u) for u, _ in held)
    for k, v in sorted(who.items(), key=lambda kv: -kv[1])[:80]:
        print("   %-22s x%d" % (k, v))
