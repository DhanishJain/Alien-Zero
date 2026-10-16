#!/usr/bin/env python3
"""Generates assets/iss_interior.jpg - the station-interior art for ISS: Last Survivor.

Every room / corridor is drawn as a view straight down an ISS-style module: four walls of equipment
racks (lockers, vents, screens, cable bundles, valves, fans) converging on an end hatch, with orange
handrails, ceiling light strips and battle damage (scorch marks, dead lights, hanging cables).

The image is exactly map-sized (W*TS x H*TS). If you change the map in main.gd (_build_grid), update the
ROOMS / CORRIDORS lists below and re-run:   python3 tools/gen_interior.py
Needs: pip install pillow numpy
"""
import math
import os
import random

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

TS, W, H = 48, 58, 32          # must match main.gd
S = 2                          # supersampling factor
BIG = (W * TS * S, H * TS * S)
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "iss_interior.jpg")

# (x0, y0, x1, y1) in tiles, inclusive - same numbers as the _carve() calls in main.gd
ROOMS = {
    "habitat": (2, 2, 15, 10),
    "lab": (21, 2, 36, 10),
    "engine": (2, 17, 15, 27),
    "life": (21, 17, 36, 27),
    "airlock": (44, 2, 55, 12),
}
CORRIDORS = [(16, 5, 20, 7), (8, 11, 10, 16), (27, 11, 29, 16), (16, 21, 20, 23), (37, 5, 43, 7)]

THEMES = {
    #            panel colour        accent             panel mix
    "habitat": dict(panel=(176, 180, 186), accent=(90, 140, 210),
                    mix=dict(locker=4, bag=3, blank=2, vent=1, screen=1, cables=1)),
    "lab": dict(panel=(190, 195, 202), accent=(70, 190, 230),
                mix=dict(screen=4, locker=3, blank=1, vent=1, cables=1, fan=1)),
    "engine": dict(panel=(168, 164, 140), accent=(230, 120, 40),
                   mix=dict(cables=4, valves=2, fan=2, vent=2, blank=2, locker=2)),
    "life": dict(panel=(158, 172, 180), accent=(60, 170, 200),
                 mix=dict(valves=2, tank=3, fan=2, vent=1, blank=2, cables=2, locker=1)),
    "airlock": dict(panel=(150, 154, 160), accent=(250, 190, 30),
                    mix=dict(blank=3, hazard=1, locker=3, vent=1, cables=2, screen=1)),
    "corr": dict(panel=(172, 176, 182), accent=(90, 140, 210),
                 mix=dict(locker=3, blank=2, cables=2, vent=1)),
}

img = Image.new("RGB", BIG, (0, 0, 0))
d = ImageDraw.Draw(img, "RGBA")
glow = Image.new("RGB", BIG, (0, 0, 0))     # additive light layer, blurred and screened over at the end
gd = ImageDraw.Draw(glow)


def shade(c, f):
    return tuple(max(0, min(255, int(v * f))) for v in c[:3])


def pick(rng, mix):
    keys = list(mix)
    return rng.choices(keys, weights=[mix[k] for k in keys])[0]


class Tunnel:
    def __init__(self, rect, k, theme, seed, nb=6, hatch="door"):
        x0, y0, x1, y1 = rect
        self.L, self.T = x0 * TS * S, y0 * TS * S
        self.R, self.B = (x1 + 1) * TS * S, (y1 + 1) * TS * S
        self.cx, self.cy = (self.L + self.R) / 2, (self.T + self.B) / 2
        self.hw, self.hh = (self.R - self.L) / 2, (self.B - self.T) / 2
        self.tw, self.th = x1 - x0 + 1, y1 - y0 + 1          # size in tiles
        self.k, self.nb, self.theme, self.hatch = k, nb, THEMES[theme], hatch
        self.name = theme
        self.g = 1.0 / k - 1.0
        self.rng = random.Random(seed)

    # ---- projection -------------------------------------------------------------------------
    def sc(self, z):                      # perspective scale at depth z (0 = near plane, 1 = end wall)
        return 1.0 / (1.0 + z * self.g)

    def P(self, X, Y, z):
        s = self.sc(z)
        return (self.cx + X * self.hw * s, self.cy + Y * self.hh * s)

    def wallpt(self, wall, a, z, off=0.0):
        u = -1.0 + 2.0 * a
        if wall == "T":
            return self.P(u, -1.0 + off, z)
        if wall == "B":
            return self.P(u, 1.0 - off, z)
        if wall == "L":
            return self.P(-1.0 + off, u, z)
        return self.P(1.0 - off, u, z)

    # ---- drawing -----------------------------------------------------------------------------
    def draw(self):
        self.draw_end_wall()
        walls = ["B", "L", "R", "T"]
        for wall in walls:
            na = max(2, round((self.tw if wall in "TB" else self.th) / 2.6))
            for ia in range(na):
                for ib in range(self.nb - 1, -1, -1):          # far to near
                    self.panel(wall, ia / na, (ia + 1) / na, ib / self.nb, (ib + 1) / self.nb)
        self.rails()
        self.lights()
        self.damage()
        self.frame()

    def panel(self, wall, a0, a1, z0, z1):
        rng = self.rng

        def q(u, v):
            return self.wallpt(wall, a0 + (a1 - a0) * u, z0 + (z1 - z0) * v)

        zm = (z0 + z1) / 2
        sc = self.sc(zm)
        f = (1.0 - 0.45 * zm) * {"T": 1.08, "L": 0.95, "R": 0.95, "B": 0.78}[wall] * rng.uniform(0.94, 1.04)
        base = shade(self.theme["panel"], f)
        acc = self.theme["accent"]
        lw = lambda w: max(1, int(w * S * sc * 1.6))

        def poly(u0, u1, v0, v1, fill, outline=None):
            d.polygon([q(u0, v0), q(u1, v0), q(u1, v1), q(u0, v1)], fill=fill, outline=outline)

        def line(p, p2, fill, w=1.0):
            d.line([q(*p), q(*p2)], fill=fill, width=lw(w))

        def disc(u, v, r, fill, n=14):
            pts = [q(u + r * math.cos(t * 2 * math.pi / n), v + r * math.sin(t * 2 * math.pi / n)) for t in range(n)]
            d.polygon(pts, fill=fill)

        def led(u, v, col):
            disc(u, v, 0.035, col, 8)
            x, y = q(u, v)
            r = max(2, 5 * S * sc)
            gd.ellipse([x - r, y - r, x + r, y + r], fill=shade(col, 0.55))

        poly(0, 1, 0, 1, base)
        # recessed body + seams
        poly(0.04, 0.96, 0.05, 0.95, shade(base, 0.93))
        d.polygon([q(0, 0), q(1, 0), q(1, 1), q(0, 1)], outline=(10, 12, 16, 170))
        kind = pick(rng, self.theme["mix"])
        dark = shade(base, 0.45)
        light = shade(base, 1.15)

        if kind == "locker":
            rows, cols = rng.choice([2, 3, 4]), rng.choice([1, 2])
            for r in range(rows):
                for c in range(cols):
                    u0, u1 = 0.09 + c * 0.82 / cols, 0.09 + (c + 1) * 0.82 / cols - 0.03
                    v0, v1 = 0.1 + r * 0.8 / rows, 0.1 + (r + 1) * 0.8 / rows - 0.03
                    poly(u0, u1, v0, v1, shade(base, 0.86), (15, 18, 22, 150))
                    poly((u0 + u1) / 2 - 0.12, (u0 + u1) / 2 + 0.12, v1 - 0.12 * (v1 - v0) - 0.05, v1 - 0.05, dark)
                    if rng.random() < 0.6:
                        poly(u0 + 0.04, u0 + 0.2, v0 + 0.03, v0 + 0.1, (225, 225, 205))
                    if rng.random() < 0.7:
                        led(u1 - 0.07, v0 + 0.07, rng.choice([(40, 230, 110), (255, 170, 30), (40, 230, 110)]))
        elif kind == "bag":                                  # velcro'd cargo bags (crew quarters)
            for r in range(rng.choice([1, 2])):
                v0 = 0.08 + r * 0.46
                col = shade(rng.choice([(190, 170, 130), (170, 150, 120), (150, 160, 175)]), f)
                poly(0.1, 0.9, v0, v0 + 0.4, col, (30, 25, 18, 160))
                for i in range(4):
                    line((0.2 + i * 0.2, v0 + 0.05), (0.2 + i * 0.2, v0 + 0.35), shade(col, 0.7), 0.6)
                poly(0.4, 0.6, v0 + 0.15, v0 + 0.25, (235, 235, 225))
        elif kind == "vent":
            poly(0.12, 0.88, 0.12, 0.88, (20, 22, 26))
            for i in range(7):
                v = 0.17 + i * 0.1
                line((0.16, v), (0.84, v), shade(base, 0.6), 0.9)
        elif kind == "screen":
            poly(0.08, 0.92, 0.08, 0.72, (12, 16, 22), (150, 155, 160, 200))
            for i in range(5):
                v = 0.14 + i * 0.1
                w = rng.uniform(0.2, 0.7)
                col = rng.choice([acc, (60, 230, 130), (240, 200, 70)])
                line((0.14, v), (0.14 + w * 0.7, v), col, 0.9)
            x, y = q(0.5, 0.4)
            r = max(6, 22 * S * sc)
            gd.ellipse([x - r, y - r * 0.6, x + r, y + r * 0.6], fill=shade(acc, 0.28))
            for i in range(4):
                poly(0.12 + i * 0.2, 0.26 + i * 0.2, 0.78, 0.9, shade(base, 0.7))
            led(0.88, 0.82, (40, 230, 110))
        elif kind == "cables":
            cols = [(30, 30, 34), (200, 70, 40), (60, 100, 190), (200, 200, 205), (30, 140, 90), (220, 190, 40)]
            for i in range(7):
                c0 = rng.choice(cols)
                u = 0.12 + i * 0.12
                off = rng.uniform(-0.05, 0.05)
                pts = [q(u + off * math.sin(t * 3), t) for t in [i2 / 10 for i2 in range(11)]]
                d.line(pts, fill=shade(c0, f), width=lw(2.2))
            for v in (0.25, 0.6, 0.85):
                poly(0.08, 0.92, v, v + 0.045, (210, 210, 200))                 # cable ties
        elif kind == "valves":
            for v in (0.28, 0.72):
                poly(0.02, 0.98, v - 0.07, v + 0.07, shade((150, 140, 125), f))
                line((0.02, v - 0.07), (0.98, v - 0.07), shade((230, 225, 215), f), 0.7)
            for u in (0.3, 0.7):
                disc(u, 0.5, 0.17, (190, 40, 35))
                disc(u, 0.5, 0.1, shade(base, 0.6))
                line((u - 0.17, 0.5), (u + 0.17, 0.5), (190, 40, 35), 1.1)
                line((u, 0.33), (u, 0.67), (190, 40, 35), 1.1)
        elif kind == "fan":
            disc(0.5, 0.5, 0.38, shade(base, 0.5))
            disc(0.5, 0.5, 0.33, (14, 16, 20))
            for i in range(5):
                t = i * 2 * math.pi / 5
                d.polygon([q(0.5, 0.5), q(0.5 + 0.3 * math.cos(t), 0.5 + 0.3 * math.sin(t)),
                           q(0.5 + 0.3 * math.cos(t + 0.7), 0.5 + 0.3 * math.sin(t + 0.7))], fill=shade(base, 0.8))
            disc(0.5, 0.5, 0.07, light)
        elif kind == "tank":
            poly(0.15, 0.85, 0.06, 0.94, shade((170, 180, 190), f), (20, 24, 28, 170))
            poly(0.15, 0.85, 0.35, 0.42, shade(acc, f))
            poly(0.15, 0.85, 0.62, 0.69, shade(acc, f))
            poly(0.3, 0.7, 0.1, 0.16, dark)
            led(0.5, 0.5, (255, 170, 30))
        elif kind == "hazard":
            poly(0.05, 0.95, 0.1, 0.9, (28, 28, 30))
            for i in range(6):
                if i % 2 == 0:
                    poly(0.05, 0.95, 0.1 + i * 0.8 / 6, 0.1 + (i + 1) * 0.8 / 6, shade((235, 185, 25), f * 0.95))
            poly(0.3, 0.7, 0.36, 0.64, dark, (15, 15, 15, 200))
        else:                                                # blank panel: screws + label
            for (u, v) in ((0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)):
                disc(u, v, 0.03, dark, 8)
            poly(0.25, 0.75, 0.4, 0.5, (225, 225, 210))
            poly(0.25, 0.5, 0.58, 0.64, shade(acc, f))

    def rails(self):                               # orange handrails running down both side walls
        for wall, a in (("L", 0.3), ("R", 0.3), ("T", 0.78), ("B", 0.22)):
            n = 24
            prev = self.wallpt(wall, a, 0.0, 0.07)
            for i in range(1, n + 1):
                z = i / n
                p = self.wallpt(wall, a, z, 0.07)
                s = self.sc((i - 0.5) / n)
                d.line([prev, p], fill=shade((235, 130, 30), 0.55 + 0.45 * s), width=max(2, int(5 * S * s)))
                prev = p
            for i in range(0, self.nb + 1):        # brackets
                z = i / self.nb
                a0, b0 = self.wallpt(wall, a, z, 0.0), self.wallpt(wall, a, z, 0.07)
                d.line([a0, b0], fill=(60, 62, 68, 230), width=max(2, int(3 * S * self.sc(z))))

    def lights(self):                              # ceiling strip (some dead / red emergency)
        rng = self.rng
        for i in range(self.nb):
            z0, z1 = i / self.nb + 0.02, (i + 1) / self.nb - 0.02
            state = rng.choices(["ok", "dead", "red"], weights=[6, 2, 2] if self.name in ("engine", "life", "airlock") else [8, 1, 1])[0]
            col = {"ok": (250, 250, 235), "dead": (50, 52, 58), "red": (255, 40, 30)}[state]
            pts = [self.wallpt("T", 0.43, z0, 0.0), self.wallpt("T", 0.57, z0, 0.0),
                   self.wallpt("T", 0.57, z1, 0.0), self.wallpt("T", 0.43, z1, 0.0)]
            d.polygon(pts, fill=col)
            if state != "dead":
                gd.polygon(pts, fill=shade(col, 0.9 if state == "ok" else 0.7))

    def draw_end_wall(self):
        k = self.k
        corners = [self.P(-1, -1, 1), self.P(1, -1, 1), self.P(1, 1, 1), self.P(-1, 1, 1)]
        d.polygon(corners, fill=shade(self.theme["panel"], 0.5))
        x0, y0, x1, y1 = corners[0][0], corners[0][1], corners[2][0], corners[2][1]
        for i in range(1, 6):                                      # wall seams
            x = x0 + (x1 - x0) * i / 6
            d.line([(x, y0), (x, y1)], fill=(0, 0, 0, 90), width=2 * S)
        for i in range(1, 4):
            y = y0 + (y1 - y0) * i / 4
            d.line([(x0, y), (x1, y)], fill=(0, 0, 0, 90), width=2 * S)
        cx, cy = self.cx, self.cy
        r = min(self.hw, self.hh) * k * 0.78
        bez, inner = (52, 54, 60), (122, 128, 136)
        if self.hatch == "outside":                                # big window onto space
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=bez)
            rr = r * 0.86
            n = int(rr * 2)
            win = Image.new("RGB", (n, n), (5, 7, 18))
            wd = ImageDraw.Draw(win)
            rng = random.Random(7)
            for _ in range(110):
                x, y = rng.uniform(0, n), rng.uniform(0, n)
                b = rng.randint(130, 255)
                wd.ellipse([x - S, y - S, x + S, y + S], fill=(b, b, 255))
            pr = n * 0.95                                           # planet limb sweeping across the lower left
            pc = (n * 0.15, n * 1.25)
            for i in range(14):                                     # atmosphere glow -> surface
                rad = pr * (1 + 0.05 * (13 - i) / 13)
                col = (int(20 + i * 2), int(60 + i * 5), int(130 + i * 7))
                wd.ellipse([pc[0] - rad, pc[1] - rad, pc[0] + rad, pc[1] + rad], fill=col)
            wd.ellipse([pc[0] - pr * 0.97, pc[1] - pr * 0.97, pc[0] + pr * 0.97, pc[1] + pr * 0.97], fill=(18, 40, 92))
            for _ in range(14):                                     # cloud streaks
                x, y = rng.uniform(0, n * 0.7), rng.uniform(n * 0.5, n)
                wd.ellipse([x, y, x + rng.uniform(20, 70) * S, y + 5 * S], fill=(140, 170, 210))
            mask = Image.new("L", (n, n), 0)
            ImageDraw.Draw(mask).ellipse([0, 0, n - 1, n - 1], fill=255)
            img.paste(win, (int(cx - rr), int(cy - rr)), mask)
            d.arc([cx - rr, cy - rr, cx + rr, cy + rr], 215, 265, fill=(255, 255, 255, 120), width=3 * S)
            gd.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(14, 22, 46))
        else:
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=bez)
            for i in range(12):
                a = i * math.pi / 6
                bx, by = cx + r * 0.93 * math.cos(a), cy + r * 0.93 * math.sin(a)
                d.ellipse([bx - 2 * S, by - 2 * S, bx + 2 * S, by + 2 * S], fill=(150, 152, 158))
            rr = r * 0.84
            d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=inner)
            d.ellipse([cx - rr * 0.9, cy - rr * 0.9, cx + rr * 0.9, cy + rr * 0.9], outline=(70, 74, 80), width=3 * S)
            for i in range(4):
                a = i * math.pi / 2 + 0.5
                d.line([(cx, cy), (cx + rr * 0.9 * math.cos(a), cy + rr * 0.9 * math.sin(a))], fill=(80, 84, 90), width=4 * S)
            wr = r * 0.22
            d.ellipse([cx - wr, cy - wr, cx + wr, cy + wr], fill=(205, 206, 210), outline=(60, 62, 68), width=2 * S)
            wx, wy, wrr = cx + r * 0.28, cy - r * 0.34, r * 0.17               # porthole
            d.ellipse([wx - wrr, wy - wrr, wx + wrr, wy + wrr], fill=(10, 14, 28), outline=bez, width=3 * S)
        lx, ly = cx + r * 1.15, cy - r * 0.55
        d.rectangle([lx, ly, lx + 10 * S, ly + 22 * S], fill=(25, 27, 32))
        d.ellipse([lx + 2 * S, ly + 3 * S, lx + 8 * S, ly + 9 * S], fill=(255, 60, 40))
        d.ellipse([lx + 2 * S, ly + 13 * S, lx + 8 * S, ly + 19 * S], fill=(60, 230, 110))
        gd.ellipse([lx - 6 * S, ly - 6 * S, lx + 16 * S, ly + 12 * S], fill=(70, 12, 8))
        # centre lamp glow so the far end reads as lit
        gd.ellipse([cx - r * 1.2, cy - r * 1.2, cx + r * 1.2, cy + r * 1.2], fill=(20, 22, 26))

    def damage(self):
        rng = self.rng
        # scorch marks on the walls
        for _ in range(3):
            wall = rng.choice("TBLR")
            a, z = rng.uniform(0.15, 0.85), rng.uniform(0.0, 0.7)
            c = self.wallpt(wall, a, z)
            rad = rng.uniform(30, 70) * S * self.sc(z)
            layer = Image.new("RGBA", BIG, (0, 0, 0, 0)) if False else None
            for i in range(8):
                rr = rad * (1 - i / 9)
                d.ellipse([c[0] - rr, c[1] - rr * 0.7, c[0] + rr, c[1] + rr * 0.7], fill=(8, 6, 4, 26))
        # a torn-open panel with exposed wiring + sparks
        wall = rng.choice("LRT")
        a0 = rng.choice([0.0, 0.2, 0.4, 0.6, 0.8])
        z0 = rng.choice([0.0, 1 / self.nb])
        pts = []
        for i in range(10):
            u, v = rng.uniform(0.15, 0.85), rng.uniform(0.15, 0.85)
            pts.append(self.wallpt(wall, a0 + 0.2 * u, z0 + (1 / self.nb) * v))
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        pts.sort(key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
        d.polygon(pts, fill=(14, 12, 12), outline=(80, 70, 60))
        for i in range(5):
            p = pts[rng.randrange(len(pts))]
            q2 = (p[0] + rng.uniform(-30, 30) * S, p[1] + rng.uniform(-24, 24) * S)
            d.line([p, q2], fill=rng.choice([(220, 60, 40), (240, 200, 60), (70, 120, 220)]), width=2 * S)
        gd.ellipse([cx - 22 * S, cy - 16 * S, cx + 22 * S, cy + 16 * S], fill=(90, 60, 14))
        # hanging cables dangling from the ceiling
        for _ in range(3):
            a = rng.uniform(0.2, 0.8)
            p0 = self.wallpt("T", a, rng.uniform(0.0, 0.25))
            ln = rng.uniform(25, 60) * S
            p1 = (p0[0] + rng.uniform(-18, 18) * S, p0[1] + ln)
            mid = (p0[0] + (p1[0] - p0[0]) * 0.5 + rng.uniform(-10, 10) * S, p0[1] + ln * 0.5)
            col = rng.choice([(30, 30, 34), (200, 70, 40), (60, 100, 190)])
            pts = []
            for i in range(11):
                t = i / 10
                pts.append(((1 - t) ** 2 * p0[0] + 2 * t * (1 - t) * mid[0] + t * t * p1[0],
                            (1 - t) ** 2 * p0[1] + 2 * t * (1 - t) * mid[1] + t * t * p1[1]))
            d.line(pts, fill=col, width=3 * S)
            d.ellipse([p1[0] - 2 * S, p1[1] - 2 * S, p1[0] + 2 * S, p1[1] + 2 * S], fill=(210, 150, 70))

    def frame(self):                                # soft occlusion at the module opening
        for i in range(10):
            a = 70 - i * 7
            d.rectangle([self.L + i * S, self.T + i * S, self.R - i * S - 1, self.B - i * S - 1], outline=(0, 0, 0, max(a, 0)))


def main():
    jobs = []
    for name, rect in ROOMS.items():
        jobs.append(Tunnel(rect, k=0.42, theme=name, seed=hash(name) % 1000 + len(name),
                           hatch="outside" if name == "airlock" else "door"))
    for i, rect in enumerate(CORRIDORS):
        jobs.append(Tunnel(rect, k=0.55, theme="corr", seed=100 + i, nb=4))
    for t in jobs:
        t.draw()

    global img
    g = glow.filter(ImageFilter.GaussianBlur(10 * S))
    g2 = glow.filter(ImageFilter.GaussianBlur(3 * S))
    img = ImageChops.screen(img, g.point(lambda v: int(v * 1.1)))
    img = ImageChops.screen(img, g2.point(lambda v: int(v * 0.5)))
    out = img.resize((W * TS, H * TS), Image.LANCZOS)

    a = np.asarray(out).astype(np.float32)
    rng = np.random.default_rng(3)
    grain = rng.normal(0, 3.2, a.shape[:2])[..., None]
    low = np.asarray(Image.fromarray((rng.random((H * 2, W * 2)) * 255).astype(np.uint8)).resize(
        (W * TS, H * TS), Image.BICUBIC)).astype(np.float32)[..., None] / 255.0
    a = a * (0.9 + 0.14 * low) + grain                         # grime + film grain
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(OUT, quality=90)
    print("wrote", os.path.abspath(OUT), os.path.getsize(OUT) // 1024, "KB")


if __name__ == "__main__":
    main()
