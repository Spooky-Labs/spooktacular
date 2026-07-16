#!/usr/bin/env python3
"""Spooktacular icon v3 — outlined pixel-art (per user reference sprite):
dark outline ringing every shape, FLAT tonal bands (no gradients), bold eyes.
Two ghosts around a campfire on a night sky. 64x64 -> 1024 nearest-neighbor."""
from PIL import Image, ImageDraw
import math, sys

G = 64
OUT = 1024

# ---- palette (flat) ----
OUTLINE   = (20, 11, 38, 255)     # near-black violet ring
NIGHT_TOP = (44, 26, 82)
NIGHT_BOT = (14, 9, 30)
STAR      = (150, 138, 190, 255)
STAR_HI   = (206, 196, 245, 255)
MOON      = (226, 219, 250, 255)
# ghost flat tones
GH_HL   = (250, 249, 255, 255)
GH_BASE = (210, 202, 244, 255)
GH_SHAD = (150, 128, 208, 255)
GH_WARM = (255, 208, 150, 255)
EYE_HI  = (214, 205, 244, 255)   # pale violet catchlight
# flame flat tones
F_CORE = (255, 247, 210, 255)
F_Y    = (255, 200, 80, 255)
F_O    = (243, 138, 44, 255)
F_R    = (214, 58, 30, 255)
# logs
LOG   = (92, 60, 46, 255)
LOG_HI= (132, 84, 54, 255)
EMBER = (255, 178, 78, 255)

bg = Image.new('RGBA', (G, G), (0, 0, 0, 0))
bpx = bg.load()
FIRE = (32.0, 45.0)
def paint_bg(x, y):
    t = y / (G - 1)
    col = tuple(int(NIGHT_TOP[i] + (NIGHT_BOT[i]-NIGHT_TOP[i])*t) for i in range(3))
    dx, dy = x-FIRE[0], (y-FIRE[1])*1.3
    glow = max(0.0, 1 - math.hypot(dx,dy)/26.0)**1.9 * 0.5
    col = tuple(min(255,int(col[i] + ((255,150,60)[i]-col[i])*glow)) for i in range(3))
    bpx[x,y] = col + (255,)
for y in range(G):
    for x in range(G):
        paint_bg(x, y)

# subject layer (transparent) — everything that gets an outline
sub = Image.new('RGBA', (G, G), (0, 0, 0, 0))
spx = sub.load()
def s(x, y, col):
    if 0 <= x < G and 0 <= y < G:
        spx[int(x), int(y)] = col

# ---------- ghost (flat bands) ----------
def ghost(cx, top, w, h, facing):
    bottom = top + h
    dome = 0.32
    hem = 0.18
    for yy in range(int(top), int(bottom)):
        ty = (yy - top)/h
        hw = w*math.sin((ty/dome)*(math.pi/2)) if ty < dome else w
        for xo in range(int(-hw)-1, int(hw)+2):
            if abs(xo) > hw: continue
            if ty > 1-hem:
                u = xo/(2*w)+0.5
                wave = 0.5-0.5*math.cos(u*3*2*math.pi)
                if ty > (1-hem) + hem*(0.12+0.88*wave): continue
            near = (xo/w)*facing
            if near > 0.70:               tone = GH_WARM
            elif near < -0.42:            tone = GH_SHAD
            elif ty < 0.16 or near > 0.30: tone = GH_HL
            else:                          tone = GH_BASE
            s(cx+xo, yy, tone)
    # eyes — big, bold, mint catchlight
    ey = top + h*0.32
    for sgn in (-1, 1):
        ex = cx + sgn*w*0.44
        for dx in range(-1, 3):
            for dy in range(0, 4):
                s(ex+dx, ey+dy, OUTLINE)
        s(ex, ey, EYE_HI); s(ex+1, ey, EYE_HI)   # catchlight top
    # smile
    my = top + h*0.5
    for dx in (-2,-1,0,1,2):
        s(cx+dx, my + (1 if abs(dx)<2 else 0), OUTLINE)

# ---------- flame ----------
def flame(cx, base_y, w, h):
    for yy in range(int(base_y-h), int(base_y)):
        ry = (base_y-yy)/h
        hw = max(0.7, w*(1-ry)**0.7*(1+0.16*math.sin(ry*9)))
        for xo in range(int(-hw)-1, int(hw)+2):
            if abs(xo) > hw: continue
            x = cx+xo+0.8*math.sin(ry*4)
            r = math.hypot(xo/max(hw,1), ry*1.15)
            tone = F_CORE if (r<0.34 and ry<0.78) else F_Y if r<0.62 else F_O if r<0.86 else F_R
            s(x, yy, tone)

def logs(cx, y):
    d = ImageDraw.Draw(sub)
    for x0,x1,yy in [(-11,11,0),(-13,5,2),(-4,12,3)]:
        d.line([(cx+x0,y+yy),(cx+x1,y+yy)], fill=LOG, width=2)
    for x in range(cx-9, cx+9, 3): s(x, y, LOG_HI)

logs(32, 52)
flame(32, 52, 6.2, 19)
ghost(19, 18, 9.0, 29, +1)
ghost(45, 18, 9.0, 29, -1)

# ---------- outline pass: dark ring around every subject pixel ----------
outlined = Image.new('RGBA', (G, G), (0,0,0,0))
opx = outlined.load()
def occupied(x, y):
    return 0 <= x < G and 0 <= y < G and spx[x, y][3] > 0
for y in range(G):
    for x in range(G):
        if spx[x, y][3] > 0:
            opx[x, y] = spx[x, y]
        else:
            # if any 8-neighbour is a subject, this is outline
            ring = any(occupied(x+dx, y+dy)
                       for dx in (-1,0,1) for dy in (-1,0,1) if (dx or dy))
            if ring:
                opx[x, y] = OUTLINE

# ---------- compose: bg + stars/moon + outlined subjects ----------
img = bg.copy()
ipx = img.load()
# stars + crescent moon (bg accents, no outline)
for (x,y,c) in [(8,8,STAR),(14,5,STAR_HI),(52,7,STAR),(56,12,STAR),(44,4,STAR),
                (6,16,STAR),(20,3,STAR_HI),(49,17,STAR)]:
    ipx[x,y] = c
d = ImageDraw.Draw(img)
mx,my = 53,9
d.ellipse([mx-4,my-4,mx+4,my+4], fill=MOON)
for yy in range(my-5,my+5):
    for xx in range(mx-5,mx+6):
        if (xx-(mx+2))**2+(yy-(my-1))**2 <= 16 and 0<=xx<G and 0<=yy<G:
            paint_bg(xx,yy); ipx[xx,yy]=bpx[xx,yy]
img.alpha_composite(outlined)
# embers over the flame
for (x,y) in [(30,29),(35,25),(33,21)]: ipx[x,y]=EMBER

# ---------- output ----------
path = sys.argv[1] if len(sys.argv)>1 else 'v3.png'
img.resize((OUT,OUT), Image.NEAREST).save(path)
img.resize((48,48), Image.NEAREST).save(path.replace('.png','_48.png'))
img.resize((16,16), Image.NEAREST).save(path.replace('.png','_16.png'))
print("wrote", path)

if '--svg' in sys.argv:
    px = img.load(); rects = []
    for yy in range(G):
        x = 0
        while x < G:
            r, g, b, a = px[x, yy]; x2 = x + 1
            while x2 < G and px[x2, yy] == (r, g, b, a): x2 += 1
            rects.append(f'<rect x="{x}" y="{yy}" width="{x2-x}" height="1" fill="#{r:02x}{g:02x}{b:02x}"/>')
            x = x2
    svg = ('<?xml version="1.0" encoding="utf-8"?>\n'
           f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 {G} {G}" '
           'shape-rendering="crispEdges" image-rendering="pixelated" preserveAspectRatio="xMidYMid meet">\n'
           '<metadata>{"brand":"Spooky Labs","app":"Spooktacular","scene":"two ghosts around a campfire",'
           '"grid":"64x64","style":"outlined pixel art"}</metadata>\n' + '\n'.join(rects) + '\n</svg>\n')
    open(path.replace('.png', '.svg'), 'w').write(svg)
    print("wrote", path.replace('.png', '.svg'))
