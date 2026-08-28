"""Rasterise captured norns screen ops into a contact sheet, so a visualiser
can be looked at rather than guessed at. Supersampled 8x then downscaled,
which approximates the antialiasing norns' cairo does."""
import json, sys
from PIL import Image, ImageDraw, ImageFont

W, H, SS = 128, 64, 8
GREY = [int(round(i / 15 * 255)) for i in range(16)]

_FONTS = {}


def font(size):
    """norns' bitmap font at an arbitrary size. Cached: building a TrueType
    face is not free and a frame can ask for the same size a hundred times."""
    f = _FONTS.get(size)
    if f is None:
        try:
            f = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                int(round(size * SS)))
        except Exception:
            f = ImageFont.load_default()
        _FONTS[size] = f
    return f


FONT = font(7)


def render(ops):
    img = Image.new("L", (W * SS, H * SS), 0)
    d = ImageDraw.Draw(img)
    # cairo accumulates sub-paths: move_to starts a new one but keeps the
    # previous, and stroke draws them all. Keeping only the last sub-path
    # silently drops anything drawn as many short segments in one stroke.
    level, paths, rects, pos = 15, [], [], (0, 0)
    fsize = 8
    # cairo's translate is cumulative and every later coordinate is relative
    # to it, which is exactly how the page-slide wipe is drawn
    ox, oy = 0.0, 0.0
    for o in ops:
        op, a = o["op"], o["args"]
        if op == "translate":
            ox += a[0]; oy += a[1]
            continue
        # text and text_right carry only a string; their position came from a
        # preceding move, which is already offset
        if op in ("move", "line", "rect", "circle"):
            a = list(a)
            a[0] = a[0] + ox
            a[1] = a[1] + oy
        if op == "level":
            level = max(0, min(15, int(a[0])))
        elif op == "move":
            pos = (a[0], a[1]); paths.append([pos])
        elif op == "line":
            pos = (a[0], a[1])
            if not paths:
                paths.append([pos])
            else:
                paths[-1].append(pos)
        elif op == "stroke":
            for sub in paths:
                if len(sub) > 1:
                    d.line([(x * SS, y * SS) for x, y in sub],
                           fill=GREY[level], width=max(1, SS // 2), joint="curve")
            for sh in rects:
                if sh[0] == "r":
                    _, x, y, w, h = sh
                    d.rectangle([x * SS, y * SS, (x + w) * SS, (y + h) * SS],
                                outline=GREY[level], width=max(1, SS // 2))
                else:
                    _, x, y, r = sh
                    d.ellipse([(x - r) * SS, (y - r) * SS,
                               (x + r) * SS, (y + r) * SS],
                              outline=GREY[level], width=max(1, SS // 2))
            paths, rects = [], []
        elif op == "rect":
            rects.append(("r", a[0], a[1], a[2], a[3]))
        elif op == "circle":
            rects.append(("c", a[0], a[1], a[2]))
        elif op == "pixel":
            rects.append(("r", a[0], a[1], 1, 1))
        elif op == "close":
            # cairo closes the current sub-path; PIL's polygon() closes for us,
            # so this only has to not break the path list
            pass
        elif op == "fill":
            # cairo fills the PATH too, not just rects - the grain circles are
            # filled polygons and an earlier version of this rasteriser drew
            # them as nothing at all
            for sub in paths:
                if len(sub) > 2:
                    d.polygon([(x * SS, y * SS) for x, y in sub],
                              fill=GREY[level])
            for sh in rects:
                if sh[0] == "r":
                    _, x, y, w, h = sh
                    d.rectangle([x * SS, y * SS, (x + w) * SS, (y + h) * SS],
                                fill=GREY[level])
                else:
                    _, x, y, r = sh
                    d.ellipse([(x - r) * SS, (y - r) * SS,
                               (x + r) * SS, (y + r) * SS], fill=GREY[level])
            rects, paths = [], []
        elif op == "font_size":
            fsize = float(a[0]) if a else 8
        elif op in ("text", "text_right"):
            s = str(a[0])
            # norns draws text with the baseline at the move point; the size
            # the script asked for is what decides how far above it the glyph
            # reaches
            fh = fsize * 7.0 / 8.0
            fo = font(fh)
            tw = d.textlength(s, font=fo)
            x = pos[0] * SS - (tw if op == "text_right" else 0)
            d.text((x, pos[1] * SS - fh * SS), s, fill=GREY[level], font=fo)
        elif op == "clear":
            d.rectangle([0, 0, W * SS, H * SS], fill=0)
            paths, rects = [], []
    return img.resize((W, H), Image.LANCZOS)


def sheet(frames, cols=3, scale=3, pad=6):
    tiles = [(f["name"], render(f["ops"])) for f in frames]
    rows = (len(tiles) + cols - 1) // cols
    tw, th = W * scale, H * scale + 12
    out = Image.new("L", (cols * (tw + pad) + pad, rows * (th + pad) + pad), 40)
    d = ImageDraw.Draw(out)
    try:
        f = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 10)
    except Exception:
        f = ImageFont.load_default()
    for i, (name, im) in enumerate(tiles):
        cx = pad + (i % cols) * (tw + pad)
        cy = pad + (i // cols) * (th + pad)
        out.paste(im.resize((tw, th - 12), Image.NEAREST), (cx, cy))
        d.text((cx + 2, cy + th - 11), name, fill=255, font=f)
    return out


if __name__ == "__main__":
    frames = json.load(open("/tmp/frames.json"))
    sheet(frames).save(sys.argv[1] if len(sys.argv) > 1 else "/tmp/shader.png")
    print("frames:", len(frames))
