#!/usr/bin/env python3
"""Spooktacular icon — the noir detective ghost, traced from the reference
sprite in `Resources/spook-ref.png`.

Pipeline (deterministic, so the committed AppIcon.svg is reproducible):
  1. flood-fill the flat backdrop out from the edges, so the ghost's white
     body is never mistaken for the grey background;
  2. crop tight and downsample the (soft, AI-grained) source to a crisp
     ~41x56 sprite grid;
  3. quantize to 6 tones, then luminance-remap to a punchy 5-step noir
     palette (deep darks, bright ghost-white) so pixels read sharp;
  4. compose on a slate night with a radial glow and a soft drop shadow.

64x64 -> 1024 nearest-neighbour. `--svg` emits the canonical run-length vector
rendered to AppIcon.icns by scripts/create-icns.sh.
"""
import sys
import math
import collections
from pathlib import Path
from PIL import Image

G = 64
OUT = 1024
REF = Path(__file__).resolve().parent.parent / "Resources" / "spook-ref.png"

# ---- noir palette (luminance buckets) ----
PALETTE = [
    (18, 20, 32),     # near-black — outline, coat, shades
    (42, 46, 66),     # dark navy
    (98, 106, 134),   # mid slate
    (178, 184, 206),  # light slate
    (240, 242, 251),  # ghost white
]
BG_CENTER = (70, 78, 104)
BG_TOP    = (30, 34, 50)
BG_BOT    = (9, 10, 16)


def _remap(c):
    lum = (0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]) / 255
    if lum < 0.16:
        return PALETTE[0]
    if lum < 0.36:
        return PALETTE[1]
    if lum < 0.60:
        return PALETTE[2]
    if lum < 0.82:
        return PALETTE[3]
    return PALETTE[4]


def _sprite():
    """Isolate + downsample + remap the reference into a 64-grid RGBA sprite."""
    work = Image.open(REF).convert("RGB").resize((160, 160), Image.LANCZOS)
    w, h = work.size
    px = work.load()
    bg = px[2, 2]

    def near_bg(c):
        return abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) <= 50

    # flood fill the connected background from every edge pixel
    is_bg = [[False] * w for _ in range(h)]
    queue = collections.deque()
    for x in range(w):
        queue.append((x, 0)); queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y)); queue.append((w - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or is_bg[y][x]:
            continue
        if not near_bg(px[x, y]):
            continue
        is_bg[y][x] = True
        queue.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])

    rgba = work.convert("RGBA")
    rp = rgba.load()
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if is_bg[y][x]:
                rp[x, y] = (0, 0, 0, 0)
            else:
                xs.append(x); ys.append(y)
    char = rgba.crop((min(xs), min(ys), max(xs) + 1, max(ys) + 1))
    cw, ch = char.size

    sh = 56
    sw = max(1, round(sh * cw / ch))
    if sw > 58:
        sw, sh = 58, max(1, round(58 * ch / cw))
    small = char.resize((sw, sh), Image.LANCZOS)
    quant = small.convert("RGB").quantize(colors=6, method=Image.MEDIANCUT).convert("RGB")
    sp, qp = small.load(), quant.load()
    spr = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    out = spr.load()
    for y in range(sh):
        for x in range(sw):
            if sp[x, y][3] >= 128:
                out[x, y] = _remap(qp[x, y]) + (255,)
    return spr, sw, sh


def render():
    spr, sw, sh = _sprite()
    sp = spr.load()
    img = Image.new("RGBA", (G, G), (0, 0, 0, 0))
    ip = img.load()
    cx, cy = G * 0.5, G * 0.46
    for y in range(G):
        for x in range(G):
            t = y / (G - 1)
            base = tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3))
            d = math.hypot(x - cx, (y - cy) * 1.06)
            glow = max(0.0, 1 - d / (G * 0.6)) ** 2 * 0.6
            ip[x, y] = tuple(min(255, int(base[i] + (BG_CENTER[i] - base[i]) * glow)) for i in range(3)) + (255,)
    ox = (G - sw) // 2
    oy = int(G * 0.52 - sh / 2)
    # soft drop shadow (multiply the backdrop where the sprite casts)
    for y in range(sh):
        for x in range(sw):
            if sp[x, y][3] >= 128:
                gx, gy = ox + x + 1, oy + y + 2
                if 0 <= gx < G and 0 <= gy < G:
                    b = ip[gx, gy]
                    ip[gx, gy] = tuple(int(b[i] * 0.55) for i in range(3)) + (255,)
    for y in range(sh):
        for x in range(sw):
            if sp[x, y][3] >= 128:
                ip[ox + x, oy + y] = sp[x, y]
    return img


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
    img = render()
    img.resize((OUT, OUT), Image.NEAREST).save(path)
    img.resize((48, 48), Image.NEAREST).save(path.replace(".png", "_48.png"))
    img.resize((16, 16), Image.NEAREST).save(path.replace(".png", "_16.png"))
    print("wrote", path)

    if "--svg" in sys.argv:
        px = img.load()
        rects = []
        for y in range(G):
            x = 0
            while x < G:
                r, g, b, a = px[x, y]
                x2 = x + 1
                while x2 < G and px[x2, y] == (r, g, b, a):
                    x2 += 1
                rects.append(f'<rect x="{x}" y="{y}" width="{x2 - x}" height="1" fill="#{r:02x}{g:02x}{b:02x}"/>')
                x = x2
        svg = ('<?xml version="1.0" encoding="utf-8"?>\n'
               f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 {G} {G}" '
               'shape-rendering="crispEdges" image-rendering="pixelated" preserveAspectRatio="xMidYMid meet">\n'
               '<metadata>{"brand":"Spooky Labs","app":"Spooktacular","subject":"noir detective ghost",'
               '"grid":"64x64","style":"traced pixel art"}</metadata>\n' + "\n".join(rects) + "\n</svg>\n")
        Path(path.replace(".png", ".svg")).write_text(svg)
        print("wrote", path.replace(".png", ".svg"), f"({len(rects)} rects)")


if __name__ == "__main__":
    main()
