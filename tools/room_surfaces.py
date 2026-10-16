"""tools/room_surfaces.py — per-sprite SURFACES for isometric pixel art.

For every sprite in a kit, finds its TOP FACE (the parallelogram another
item can sit on), its FOOTPRINT, and the HEIGHT between them, from the
pixels alone. Engine-agnostic: a folder of PNGs in, a JSON file and review
sheets out. tools/room_surfaces_to_lua.py turns the JSON into this game's
data/room_surfaces.lua.

    python tools/room_surfaces.py                     detect + overrides + sheets + csv + json
    python tools/room_surfaces.py --only "Bedroom/*"  a subset (globs on the sprite key)
    python tools/room_surfaces.py --no-sheets         json/csv/summary only (fast re-run)
    python tools/room_surfaces.py --zoom KEY [KEY..]  4x render with a grid, to read corners off
    python tools/room_surfaces.py --selftest          synthetic fixtures; no kit needed; exit 1 on a miss
    python tools/room_surfaces.py --check             config "expect" against real kit sprites
    python tools/room_surfaces.py --strict            exit 1 while any flag or stale override remains
    options: --root DIR (assets/sprites) --config FILE --overrides FILE --out DIR

HOW IT WORKS. The kit draws every face in its own flat colour, outlined
darker, and shades the sides darker than the top. So the top face is a
same-colour region whose edges run at the isometric slopes. Every
same-colour region of a sprite is scored as a candidate: its outline must
follow the two iso slopes (±1/2), it must fill its own parallelogram, it
must be a good share of the sprite's width (a headrest or a knob is not a
top), and it must have no long vertical edges (a flat front face is not a
top). The best candidate above the score threshold is the face. The
footprint is that face moved down to the sprite's lowest row, or, for a
sprite with no face, the lower outline of its silhouette. Height is the
distance between the two.

REVIEW. The sheets (review/page_NN.png) show every sprite with its face
tinted green, the face corners in yellow, the footprint in cyan, the two
runners-up numbered. tools/surfaces/overrides.json takes decisions by
sprite key — a seed point, a runner-up to pick, corners typed in, or
"none" — and a re-run merges them. Runs are deterministic: the same kit
and the same overrides give the same bytes.

COORDINATES. Sprite pixel space: origin at the top-left of the PNG (for a
strip, of each cell), x right, y down, integer coordinates of opaque pixels
(alpha > alpha_min). bottom = lowest opaque row + 1. height = bottom - 1 -
face.B.y. Native scale; a consumer multiplies by the item's own scale.
"""
import argparse
import csv
import fnmatch
import hashlib
import json
import os
import re
import sys
from collections import deque

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("[surfaces] needs Pillow and numpy: pip install -r tools/requirements-dev.txt")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.join(ROOT, "tools", "surfaces")

def log(msg):
    print("[surfaces] " + msg)

# ── Config ─────────────────────────────────────────────────────────────

DEFAULTS = {
    "root": "assets/sprites",
    "folders": ["TinyHouse_0.17(@Pixel_Salvaje)"],
    "skip_globs": ["*/Floor_Wall_Tiles_*/*", "*/Room", "*/@Pixel_Salvaje", "*/Books/Books_Title"],
    "max_side": 512,
    "no_surface_globs": [],
    "alpha_min": 8,
    "color_tol": 38,
    "min_area_px": 40,
    "min_width_share": 0.42,
    "max_vrun_rows": 4,
    "max_vrun_frac": 0.5,
    "min_para_fill": 0.45,
    "good_para_fill": 0.75,
    "min_slope_ok": 0.60,
    "position_weight": 0.5,
    "face_score": 0.45,
    "flag_score": 0.35,
    "retry_tols": [0.5, 1.5],
    "foot_min_fit": 0.70,
    "anim_drift_px": 2,
    "sheet": {"cols": 7, "rows": 6, "cell": 112, "label": 24, "flag_cell": 192, "zoom": 4},
    "expect": {},
}

def load_config(path):
    cfg = json.loads(json.dumps(DEFAULTS))
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            user = json.load(fh)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    return cfg

# ── Enumeration (mirrors services/SpriteLoader.lua) ────────────────────

class SpriteFile:
    __slots__ = ("key", "path", "w", "h", "cells", "group", "skipped")
    def __init__(self, key, path, w, h, cells):
        self.key, self.path, self.w, self.h, self.cells = key, path, w, h, cells
        self.group = None
        self.skipped = None

def _is_strip(w, h):
    return h > 0 and w % h == 0 and w // h >= 3          # SpriteLoader:_sliceStrip

def scan(root, folders, skip_globs, max_side):
    files = []
    for folder in folders:
        base = os.path.join(root, folder)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for fn in sorted(filenames):
                if not fn.lower().endswith(".png"):
                    continue
                full = os.path.join(dirpath, fn)
                key = os.path.relpath(full, root).replace("\\", "/")[:-4]
                if any(fnmatch.fnmatch(key, g) for g in skip_globs):
                    continue
                try:
                    with Image.open(full) as im:
                        w, h = im.size
                except Exception as e:                       # pragma: no cover
                    log("cannot open %s: %s" % (key, e)); continue
                sf = SpriteFile(key, full, w, h, w // h if _is_strip(w, h) else 1)
                if sf.cells == 1 and max(w, h) > max_side:
                    sf.skipped = "larger than %d" % max_side
                files.append(sf)
    files.sort(key=lambda f: f.key)
    return files

ANIM_PATTERNS = [
    re.compile(r"^(.*?)[-_]Frame[-_]?(\d+)$"),
    re.compile(r"^(.*?)[-_](\d+)$"),
    re.compile(r"^(.*?)[-_/](\d+)$"),
    re.compile(r"^(.*?)[-_]([A-Za-z])$"),
]

def group_animations(keys):
    """SpriteLoader:_buildAnimations, exactly: base -> [member keys] sorted by
    the trailing number (a letter counts as its byte); >= 2 members only.
    Returns {member_key: (base, index0, members)}."""
    groups = {}
    for key in keys:
        if "cards/" in key:
            continue
        for pat in ANIM_PATTERNS:
            m = pat.match(key)
            if m:
                base, num = m.group(1), m.group(2)
                n = int(num) if num.isdigit() else ord(num)
                groups.setdefault(base, []).append((n, key))
                break
    out = {}
    for base, members in groups.items():
        if len(members) < 2:
            continue
        members.sort()
        keys_sorted = [k for _, k in members]
        for i, k in enumerate(keys_sorted):
            out[k] = (base, i, keys_sorted)
    return out

# ── Pixels ─────────────────────────────────────────────────────────────

def load_rgba(path):
    with Image.open(path) as im:
        return np.array(im.convert("RGBA"))

def split_cells(arr, n):
    h = arr.shape[0]
    return [arr[:, i * h:(i + 1) * h] for i in range(n)]

class Sil:
    __slots__ = ("mask", "top", "bot", "left", "right", "area", "width_max", "height", "bottom_per_col", "largest_area")

def silhouette(arr, alpha_min):
    mask = arr[..., 3] > alpha_min
    s = Sil()
    s.mask = mask
    rows = np.where(mask.any(axis=1))[0]
    if len(rows) == 0:
        return None
    cols = np.where(mask.any(axis=0))[0]
    s.top, s.bot = int(rows[0]), int(rows[-1])
    s.left, s.right = int(cols[0]), int(cols[-1])
    s.area = int(mask.sum())
    s.height = s.bot - s.top + 1
    widths = mask.sum(axis=1)
    s.width_max = int(widths.max())
    bpc = np.full(mask.shape[1], -1, dtype=np.int32)
    for x in cols:
        ys = np.where(mask[:, x])[0]
        bpc[x] = int(ys[-1])
    s.bottom_per_col = bpc
    s.largest_area = 1
    return s

def quantize(arr, mask, tol):
    """Palette index per pixel (-1 outside the mask): colours sorted by
    count, each joining the first palette entry within `tol` RGB distance."""
    rgb = arr[..., :3].astype(np.int32)
    flat = rgb[mask]
    if len(flat) == 0:
        return np.full(mask.shape, -1, dtype=np.int16)
    packed = flat[:, 0] * 65536 + flat[:, 1] * 256 + flat[:, 2]
    uniq, counts = np.unique(packed, return_counts=True)
    order = np.argsort(-counts, kind="stable")
    uniq = uniq[order]
    cols = np.stack([uniq // 65536, (uniq // 256) % 256, uniq % 256], axis=1).astype(np.float64)
    palette = []          # representative colours
    assign = np.empty(len(uniq), dtype=np.int16)
    for i, c in enumerate(cols):
        if palette:
            d = np.linalg.norm(np.array(palette) - c, axis=1)
            j = int(np.argmin(d))
            if d[j] <= tol:
                assign[i] = j
                continue
        palette.append(c)
        assign[i] = len(palette) - 1
    lut = dict(zip(uniq.tolist(), assign.tolist()))
    idx = np.full(mask.shape, -1, dtype=np.int16)
    idx[mask] = np.array([lut[p] for p in packed.tolist()], dtype=np.int16)
    return idx

def components(idx, min_area):
    """4-connected regions of equal palette index. Label relaxation on the
    whole array (vectorised) instead of a per-pixel BFS."""
    h, w = idx.shape
    lab = np.arange(h * w, dtype=np.int32).reshape(h, w)
    lab[idx < 0] = -1
    v_same = (idx[1:, :] == idx[:-1, :]) & (idx[1:, :] >= 0)
    h_same = (idx[:, 1:] == idx[:, :-1]) & (idx[:, 1:] >= 0)
    def relax(new, a, b, same):
        # Each side takes the min of the pair, against its CURRENT value: the
        # two views overlap, so a plain assignment would undo the other's.
        m = np.minimum(a, b)
        a[same] = np.minimum(a[same], m[same])
        b[same] = np.minimum(b[same], m[same])
    while True:
        new = lab.copy()
        relax(new, new[1:, :], new[:-1, :], v_same)
        relax(new, new[:, 1:], new[:, :-1], h_same)
        if np.array_equal(new, lab):
            break
        lab = new
    out = []
    labels, counts = np.unique(lab[lab >= 0], return_counts=True)
    for L, n in zip(labels.tolist(), counts.tolist()):
        if n < min_area:
            continue
        m = lab == L
        ys, xs = np.where(m)
        out.append({"mask": m, "area": int(n), "bbox": (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())),
                    "palette": int(idx[ys[0], xs[0]])})
    out.sort(key=lambda c: -c["area"])
    return out

def fill_holes(mask):
    """The mask with its enclosed holes filled (flood the outside from a
    padded border, PIL does it in C)."""
    h, w = mask.shape
    im = Image.new("L", (w + 2, h + 2), 0)
    im.paste(Image.fromarray((mask * 255).astype(np.uint8)), (1, 1))
    ImageDraw.floodfill(im, (0, 0), 128)
    outside = np.array(im) == 128
    return ~outside[1:-1, 1:-1]

# ── Scoring ────────────────────────────────────────────────────────────

def _corners(solid):
    ys, xs = np.where(solid)
    top, bot, left, right = ys.min(), ys.max(), xs.min(), xs.max()
    tx = xs[ys == top]; bx = xs[ys == bot]; ly = ys[xs == left]; ry = ys[xs == right]
    T = (int(round((tx.min() + tx.max()) / 2)), int(top))
    B = (int(round((bx.min() + bx.max()) / 2)), int(bot))
    L = (int(left), int(round((ly.min() + ly.max()) / 2)))
    R = (int(right), int(round((ry.min() + ry.max()) / 2)))
    return T, L, B, R

def _quad_area(T, L, B, R):
    pts = [T, R, B, L]
    a = 0.0
    for i in range(4):
        x1, y1 = pts[i]; x2, y2 = pts[(i + 1) % 4]
        a += x1 * y2 - x2 * y1
    return abs(a) / 2.0

def _boundary_profile(solid):
    """Per row of the solid mask's bbox: first and last column."""
    rows = np.where(solid.any(axis=1))[0]
    lx, rx = [], []
    for y in rows:
        xs = np.where(solid[y])[0]
        lx.append(int(xs[0])); rx.append(int(xs[-1]))
    return rows, np.array(lx), np.array(rx)

def _longest_zero_run(d):
    best = run = 0
    for v in d:
        run = run + 1 if v == 0 else 0
        best = max(best, run)
    return best

def score_face(comp, sil, cfg, bypass_gates=False):
    solid = fill_holes(comp["mask"])
    area = int(solid.sum())
    T, L, B, R = _corners(solid)
    w = R[0] - L[0] + 1
    h = B[1] - T[1] + 1
    out = {"corners": (T, L, B, R), "solid": solid, "area": area, "score": 0.0, "why": None, "m": {}}
    qa = _quad_area(T, L, B, R)
    para_fill = area / qa if qa > 0 else 0.0
    out["m"]["para_fill"] = round(para_fill, 3)
    width_share = w / max(1, sil.width_max)
    out["m"]["width_share"] = round(width_share, 3)
    rows, lx, rx = _boundary_profile(solid)
    if len(rows) < 3:
        out["why"] = "tiny"; return out
    dl, dr = np.diff(lx), np.diff(rx)
    vrun = max(_longest_zero_run(dl), _longest_zero_run(dr))
    out["m"]["vrun"] = int(vrun)
    ok = np.concatenate([np.abs(dl), np.abs(dr)])
    slope_ok = float(np.mean((ok >= 1) & (ok <= 3))) if len(ok) else 0.0
    out["m"]["slope_ok"] = round(slope_ok, 3)
    # sign structure: the left edge moves left above L, right below it; the
    # right edge moves right above R, left below it
    def sign_frac(d, pivot_row):
        if len(d) == 0: return 1.0
        ys = rows[:-1]
        above = ys < pivot_row
        want = np.where(above, -1, 1)
        return float(np.mean(np.sign(d) == want))
    sl = sign_frac(dl, L[1])
    sr = sign_frac(-dr, R[1])
    sign_ok = (sl + sr) / 2
    out["m"]["sign_ok"] = round(sign_ok, 3)
    position = 1 - cfg["position_weight"] * (T[1] - sil.top) / max(1, sil.height)
    out["m"]["position"] = round(position, 3)
    vec = ((T[0] - L[0]) - (R[0] - B[0]), (T[1] - L[1]) - (R[1] - B[1]))
    sym = max(0.0, 1 - (abs(vec[0]) + abs(vec[1])) / max(1, w))
    out["m"]["sym"] = round(sym, 3)
    if not bypass_gates:
        if para_fill < cfg["min_para_fill"]:
            out["why"] = "shape"; return out
        if width_share < cfg["min_width_share"]:
            out["why"] = "narrow"; return out
        # A front face's sides run vertical for its whole height; a top
        # face's extreme columns span a few rows at most (a bevel band at
        # the front edge is the usual case). Judged against the region's
        # smaller side so a wide, flat strip is not mistaken for a front.
        if vrun > max(cfg["max_vrun_rows"], cfg["max_vrun_frac"] * min(w, h)):
            out["why"] = "vertical"; return out
        if slope_ok < cfg["min_slope_ok"]:
            out["why"] = "slope"; return out
    fill_term = min(1.0, max(0.0, (para_fill - cfg["min_para_fill"]) / max(1e-6, cfg["good_para_fill"] - cfg["min_para_fill"])))
    width_term = min(1.0, width_share / cfg["min_width_share"] * 0.5 + 0.5) if width_share >= cfg["min_width_share"] else width_share
    # The soft terms average (a product of five 0.8s is 0.3, which reads
    # as a bad face when it is a slightly rounded one); position and the
    # region's size relative to the sprite's largest candidate multiply,
    # so a headboard's top strip loses to the mattress under it.
    area_term = min(1.0, (area / max(1, sil.largest_area)) ** 0.5)
    score = (fill_term + width_term + slope_ok + sign_ok + sym) / 5 * position * area_term
    out["m"]["area_term"] = round(area_term, 3)
    out["score"] = round(float(score), 3)
    return out

def pick_face(cands, cfg):
    good = [c for c in cands if c["why"] is None]
    good.sort(key=lambda c: -c["score"])
    best = good[0] if good else None
    runners = good[1:3]
    if best and best["score"] >= cfg["face_score"]:
        verdict = "face"
    elif best and best["score"] >= cfg["flag_score"]:
        verdict = "flag"
    else:
        verdict = "none"
    why = None
    if verdict == "none":
        rejected = [c for c in cands if c["why"]]
        if rejected:
            rejected.sort(key=lambda c: -c["area"])
            why = rejected[0]["why"]
        elif best:
            why = "low"
        else:
            why = "empty"
    return verdict, best, runners, why

def footprint_from_outline(sil, cfg):
    bpc = sil.bottom_per_col
    cols = np.where(bpc >= 0)[0]
    if len(cols) < 3:
        return None, "tiny"
    mx = bpc[cols].max()
    bcols = cols[bpc[cols] == mx]
    Bf = (int(round((bcols.min() + bcols.max()) / 2)), int(mx))
    Lf = (int(cols[0]), int(bpc[cols[0]]))
    Rf = (int(cols[-1]), int(bpc[cols[-1]]))
    Tf = (Lf[0] + Rf[0] - Bf[0], Lf[1] + Rf[1] - Bf[1])
    def slope(p, q):
        dx = q[0] - p[0]
        return abs(q[1] - p[1]) / dx if dx else 99.0
    s1, s2 = slope(Lf, Bf), slope(Bf, Rf)
    if not (0.25 <= s1 <= 0.75 and 0.25 <= s2 <= 0.75):
        return None, "flat"
    # fit: columns whose bottom lies within 2 px of the polyline
    hits = 0
    for x in cols:
        if x <= Bf[0]:
            y = Lf[1] + (x - Lf[0]) * (Bf[1] - Lf[1]) / max(1, Bf[0] - Lf[0])
        else:
            y = Bf[1] + (x - Bf[0]) * (Rf[1] - Bf[1]) / max(1, Rf[0] - Bf[0])
        if abs(bpc[x] - y) <= 2:
            hits += 1
    fit = hits / len(cols)
    if fit < cfg["foot_min_fit"]:
        return None, "fit"
    return {"T": Tf, "L": Lf, "B": Bf, "R": Rf, "fit": round(fit, 3)}, None

def analyse_cell(arr, cfg):
    """One pass at the configured colour tolerance; when that is not a face,
    again at the retry tolerances (a dark sprite's top and side merge at
    the usual tolerance; a textured top splits at it), keeping the best."""
    res = _analyse_once(arr, cfg, cfg["color_tol"])
    if res["verdict"] != "face":
        for k in cfg.get("retry_tols", []):
            alt = _analyse_once(arr, cfg, cfg["color_tol"] * k)
            if alt["verdict"] == "face" or alt["score"] > res["score"]:
                alt["retry_tol"] = round(cfg["color_tol"] * k, 1)
                res = alt
                if res["verdict"] == "face":
                    break
    return res

def _analyse_once(arr, cfg, tol):
    sil = silhouette(arr, cfg["alpha_min"])
    res = {"verdict": "none", "score": 0.0, "why": "empty", "face": None, "runners": [], "foot": None,
           "foot_src": None, "height": None, "bottom": None, "cell": [int(arr.shape[1]), int(arr.shape[0])],
           "_solid": None}
    if sil is None:
        return res
    res["bottom"] = sil.bot + 1
    idx = quantize(arr, sil.mask, tol)
    comps = components(idx, cfg["min_area_px"])
    sil.largest_area = max([c["area"] for c in comps] or [1])
    cands = [score_face(c, sil, cfg) for c in comps]
    verdict, best, runners, why = pick_face(cands, cfg)
    res["verdict"], res["why"] = verdict, why
    res["_cands"] = cands
    if best:
        res["score"] = best["score"]
        res["_best"] = best
    if verdict in ("face", "flag") and best:
        _set_face(res, best["corners"], sil)
        res["_solid"] = best["solid"]
        res["runners"] = [{"corners": r["corners"], "score": r["score"]} for r in runners]
    else:
        foot, fwhy = footprint_from_outline(sil, cfg)
        res["foot"], res["foot_src"] = foot, ("outline" if foot else None)
    res["_sil"] = sil
    return res

def _set_face(res, corners, sil):
    T, L, B, R = corners
    res["face"] = {"T": T, "L": L, "B": B, "R": R}
    h = (sil.bot) - B[1]
    res["height"] = int(h)
    res["foot"] = {"T": (T[0], T[1] + h), "L": (L[0], L[1] + h), "B": (B[0], B[1] + h), "R": (R[0], R[1] + h)}
    res["foot_src"] = "face"

def flood(arr, mask, seed, tol):
    h, w = mask.shape
    sx, sy = seed
    if not (0 <= sx < w and 0 <= sy < h and mask[sy, sx]):
        return None
    rgb = arr[..., :3].astype(np.int32)
    base = rgb[sy, sx]
    out = np.zeros_like(mask)
    q = deque([(sy, sx)]); out[sy, sx] = True
    while q:
        y, x = q.popleft()
        for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not out[ny, nx]:
                if np.sqrt(((rgb[ny, nx] - base) ** 2).sum()) <= tol:
                    out[ny, nx] = True; q.append((ny, nx))
    return out

# ── Per file, groups, overrides ────────────────────────────────────────

def analyse_file(sf, cfg):
    arr = load_rgba(sf.path)
    cells = split_cells(arr, sf.cells) if sf.cells > 1 else [arr]
    return {"cells": [analyse_cell(c, cfg) for c in cells], "arr": arr}

def _corner_list(face):
    return [face["T"], face["L"], face["B"], face["R"]]

def drift_px(a, b):
    if not (a and b):
        return 0 if not (a or b) else 99
    return max(abs(p[0] - q[0]) + abs(p[1] - q[1]) for p, q in zip(_corner_list(a), _corner_list(b)))

def apply_overrides(results, overrides, groups, cfg, files_by_key):
    """results: {key: {"cells": [res...]}}. Mutates in place; returns the
    report {applied, stale}."""
    report = {"applied": [], "stale": []}
    # 1. the config's no-surface globs
    for key, r in results.items():
        if any(fnmatch.fnmatch(key, g) for g in cfg["no_surface_globs"]):
            for c in r["cells"]:
                _none(c, "filter")
    # 2. overrides, with apply_to_group fan-out
    expanded = {}
    for key, ov in overrides.items():
        if key.startswith("_"):
            continue
        expanded[key] = ov
        if ov.get("apply_to_group") and key in groups:
            for member in groups[key][2]:
                if member not in overrides:
                    expanded.setdefault(member, dict(ov, _from=key))
    for key, ov in expanded.items():
        r = results.get(key)
        if r is None:
            if key in files_by_key or ov.get("_from"):
                continue       # out of this run's subset, or a fan-out to a missing member
            report["stale"].append((key, "no such sprite"))
            continue
        kinds = [k for k in ("surface", "seed", "pick", "face", "accept") if k in ov]
        if len(kinds) != 1:
            report["stale"].append((key, "needs exactly one of surface/seed/pick/face/accept")); continue
        cell_i = int(ov.get("cell", 1)) - 1
        if not (0 <= cell_i < len(r["cells"])):
            report["stale"].append((key, "no cell %d" % (cell_i + 1))); continue
        res = r["cells"][cell_i]
        arr = r["arr"] if r["cells"] and len(r["cells"]) == 1 else split_cells(r["arr"], len(r["cells"]))[cell_i]
        sil = res.get("_sil")
        kind = kinds[0]
        ok = True
        if kind == "surface":
            if ov["surface"] != "none":
                report["stale"].append((key, "surface must be \"none\"")); continue
            _none(res, "override")
        elif kind == "seed":
            if sil is None:
                report["stale"].append((key, "empty sprite")); continue
            reg = flood(arr, sil.mask, tuple(ov["seed"]), float(ov.get("tol", cfg["color_tol"])))
            if reg is None or reg.sum() < cfg["min_area_px"]:
                report["stale"].append((key, "seed %s hits nothing" % (ov["seed"],))); continue
            comp = {"mask": reg, "area": int(reg.sum()), "bbox": None, "palette": -1}
            sil.largest_area = max(sil.largest_area, comp["area"])
            sc = score_face(comp, sil, cfg, bypass_gates=True)
            _set_face(res, sc["corners"], sil)
            res["_solid"] = sc["solid"]
            res.update(verdict="face", score=sc["score"], why=None, source="override", runners=[])
        elif kind == "pick":
            n = int(ov["pick"])
            runners = res.get("runners") or []
            if not (2 <= n <= len(runners) + 1):
                report["stale"].append((key, "no runner-up %d" % n)); continue
            best = [c for c in res.get("_cands", []) if c["why"] is None]
            best.sort(key=lambda c: -c["score"])
            chosen = best[n - 1]
            _set_face(res, chosen["corners"], sil)
            res["_solid"] = chosen["solid"]
            res.update(verdict="face", score=chosen["score"], why=None, source="override", runners=[])
        elif kind == "accept":
            # The flagged best candidate is right: promote it.
            if res["verdict"] != "flag" or not res.get("face"):
                report["stale"].append((key, "nothing flagged to accept")); continue
            res.update(verdict="face", why=None, source="override")
        elif kind == "face":
            f = ov["face"]
            if f == "silhouette":
                # A flat thing (a carpet, a mat): the whole silhouette is the face.
                if sil is None:
                    report["stale"].append((key, "empty sprite")); continue
                corners = _corners(sil.mask)
            else:
                try:
                    corners = tuple((int(f[k][0]), int(f[k][1])) for k in ("T", "L", "B", "R"))
                except Exception:
                    report["stale"].append((key, "face needs T/L/B/R [x,y]")); continue
            w, h = res["cell"]
            if any(not (0 <= x < w and 0 <= y < h) for x, y in corners):
                report["stale"].append((key, "corner outside the sprite")); continue
            if sil is None:
                report["stale"].append((key, "empty sprite")); continue
            _set_face(res, corners, sil)
            res["_solid"] = sil.mask if f == "silhouette" else None
            res.update(verdict="face", score=1.0, why=None, source="override", runners=[])
        if ok:
            if "height_px" in ov and res.get("face"):
                res["height"] = int(ov["height_px"])
                T, L, B, R = _corner_list(res["face"])
                hh = res["height"]
                res["foot"] = {"T": (T[0], T[1] + hh), "L": (L[0], L[1] + hh), "B": (B[0], B[1] + hh), "R": (R[0], R[1] + hh)}
            fp = ov.get("footprint")
            if fp == "none":
                res["foot"], res["foot_src"] = None, "override"
            elif isinstance(fp, dict):
                try:
                    res["foot"] = {k: (int(fp[k][0]), int(fp[k][1])) for k in ("T", "L", "B", "R")}
                    res["foot_src"] = "override"
                except Exception:
                    report["stale"].append((key, "footprint needs T/L/B/R [x,y]"))
            res["note"] = ov.get("note")
            report["applied"].append(key + ("" if not ov.get("_from") else " (via " + ov["_from"] + ")"))
    return report

def _none(res, source):
    res.update(verdict="none", why=None, face=None, height=None, runners=[], source=source)
    res["_solid"] = None
    if res.get("foot_src") == "face":
        res["foot"], res["foot_src"] = None, None

def mark_drift(results, groups, cfg):
    for key, g in groups.items():
        base, i, members = g
        if i == 0 or key not in results or members[0] not in results:
            continue
        a = results[members[0]]["cells"][0].get("face")
        b = results[key]["cells"][0].get("face")
        d = drift_px(a, b)
        results[key]["cells"][0]["drift"] = d if d > cfg["anim_drift_px"] else 0

# ── Outputs ────────────────────────────────────────────────────────────

def _pt(p): return [int(p[0]), int(p[1])]

def entry_json(res):
    e = {"v": res["verdict"], "src": res.get("source", "auto"), "score": round(float(res["score"]), 3),
         "cell": res["cell"], "bottom": res["bottom"]}
    if res.get("why"): e["why"] = res["why"]
    if res.get("face"):
        e["face"] = {k: _pt(res["face"][k]) for k in ("T", "L", "B", "R")}
        e["height"] = int(res["height"])
    if res.get("foot"):
        e["foot"] = {k: _pt(res["foot"][k]) for k in ("T", "L", "B", "R")}
        e["foot_src"] = res["foot_src"]
    if res.get("runners"):
        e["runners"] = [{"corners": [_pt(p) for p in r["corners"]], "score": r["score"]} for r in res["runners"]]
    if res.get("drift"): e["drift"] = int(res["drift"])
    if res.get("note"): e["note"] = res["note"]
    return e

def write_json(path, results, files, cfg, kit_fp):
    out = {"__meta": {"format": "room-surfaces/1", "space": "sprite_px", "count": len(results),
                      "fingerprint": kit_fp, "config": {k: cfg[k] for k in sorted(cfg) if k not in ("sheet", "expect")}},
           "sprites": {}}
    for key in sorted(results):
        cells = results[key]["cells"]
        e = entry_json(cells[0])
        if len(cells) > 1:
            e["cells"] = [entry_json(c) for c in cells]
        out["sprites"][key] = e
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")

def kit_fingerprint(files):
    h = hashlib.sha1()
    for f in files:
        h.update(("%s:%dx%d\n" % (f.key, f.w, f.h)).encode("utf-8"))
    return h.hexdigest()[:16]

def review_units(results, groups):
    """One unit per plain file, per strip (cell 1), per animation group
    (canonical) plus each drifting member."""
    units = []
    for key in sorted(results):
        g = groups.get(key)
        if g and g[1] > 0 and not results[key]["cells"][0].get("drift"):
            continue
        units.append(key)
    return units

def verdict_order(v):
    return {"flag": 0, "none": 1, "face": 2}.get(v, 3)

def write_csv(path, results, groups, units):
    rows = []
    cell_no = {k: i for i, k in enumerate(units)}
    for key in sorted(results):
        r = results[key]["cells"][0]
        f = r.get("face")
        rows.append([key, r["verdict"], r.get("source", "auto"), r["score"], r.get("why") or "",
                     r.get("height") if r.get("height") is not None else "",
                     "%d,%d %d,%d %d,%d %d,%d" % tuple(v for k in ("T", "L", "B", "R") for v in f[k]) if f else "",
                     r.get("foot_src") or "", r.get("drift") or "", len(results[key]["cells"]),
                     cell_no.get(key, ""), r.get("note") or ""])
    rows.sort(key=lambda x: (verdict_order(x[1]), x[0]))
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["sprite", "verdict", "source", "score", "why", "height", "face T L B R", "foot", "drift", "cells", "unit", "note"])
        w.writerows(rows)

def summary_lines(results, report, files):
    from collections import Counter
    vc = Counter(r["cells"][0]["verdict"] for r in results.values())
    sc = Counter(r["cells"][0].get("source", "auto") for r in results.values())
    lines = ["%d sprites analysed (%d skipped)" % (len(results), sum(1 for f in files if f.skipped)),
             "verdicts: face %d, flag %d, none %d" % (vc["face"], vc["flag"], vc["none"]),
             "sources: auto %d, override %d, filter %d" % (sc["auto"], sc["override"], sc["filter"]),
             "overrides applied: %d, stale: %d" % (len(report["applied"]), len(report["stale"]))]
    for k, why in report["stale"]:
        lines.append("  stale: %s — %s" % (k, why))
    flags = sorted(k for k, r in results.items() if r["cells"][0]["verdict"] == "flag")
    if flags:
        lines.append("flags (%d):" % len(flags))
        lines += ["  " + k for k in flags]
    return lines

# ── Sheets ─────────────────────────────────────────────────────────────

GREEN = (80, 255, 120, 255); YELLOW = (255, 240, 120, 255); CYAN = (120, 230, 255, 255)
ORANGE = (255, 190, 80, 255); GREY = (150, 140, 130, 255); BLUE = (140, 180, 255, 255); RED = (255, 100, 100, 255)

def _draw_unit(canvas, draw, x0, y0, cell, label_h, key, r, arr, tag=""):
    sc = (cell - 6) / max(arr.shape[0], arr.shape[1])
    im = Image.fromarray(arr)
    big = im.resize((max(1, int(im.size[0] * sc)), max(1, int(im.size[1] * sc))), Image.NEAREST)
    canvas.alpha_composite(big, (x0 + 3, y0 + 3))
    v = r["verdict"]
    if r.get("_solid") is not None and v in ("face", "flag"):
        tint = np.zeros((arr.shape[0], arr.shape[1], 4), dtype=np.uint8)
        tint[r["_solid"]] = (80, 255, 120, 110)
        canvas.alpha_composite(Image.fromarray(tint).resize(big.size, Image.NEAREST), (x0 + 3, y0 + 3))
    def P(pts): return [(x0 + 3 + (px + 0.5) * sc, y0 + 3 + (py + 0.5) * sc) for px, py in pts]
    if r.get("foot"):
        draw.polygon(P(_corner_list(r["foot"])), outline=CYAN)
    if r.get("face"):
        draw.polygon(P(_corner_list(r["face"])), outline=YELLOW)
    for i, ru in enumerate(r.get("runners") or []):
        pts = P(ru["corners"])
        draw.polygon(pts, outline=GREY)
        draw.text(pts[0], str(i + 2), fill=GREY)
    col = {"face": GREEN, "flag": ORANGE, "none": GREY}[v]
    if r.get("source") in ("override", "filter"): col = BLUE
    if r.get("drift"): col = RED
    name = key.split("/")[-1]
    draw.text((x0 + 3, y0 + cell), (tag + name)[:18], fill=col)
    sub = "%s %.2f" % (v, r["score"])
    if r.get("height") is not None: sub += " h=%d" % r["height"]
    if r.get("source") and r["source"] != "auto": sub += " " + r["source"]
    elif r.get("why"): sub += " " + r["why"]
    draw.text((x0 + 3, y0 + cell + 11), sub[:22], fill=col)

def write_sheets(out_dir, results, groups, units, cfg):
    S = cfg["sheet"]
    cols, rows_n, cell, label_h = S["cols"], S["rows"], S["cell"], S["label"]
    per = cols * rows_n
    pages = (len(units) + per - 1) // per
    for p in range(pages):
        canvas = Image.new("RGBA", (cols * cell, rows_n * (cell + label_h)), (30, 28, 26, 255))
        draw = ImageDraw.Draw(canvas)
        for i, key in enumerate(units[p * per:(p + 1) * per]):
            r = results[key]["cells"][0]
            arr = results[key]["arr"]
            if len(results[key]["cells"]) > 1:
                arr = split_cells(arr, len(results[key]["cells"]))[0]
            tag = ("%02d " % (p * per + i)) + ("x%d " % len(results[key]["cells"]) if len(results[key]["cells"]) > 1 else "")
            _draw_unit(canvas, draw, (i % cols) * cell, (i // cols) * (cell + label_h), cell, label_h, key, r, arr, tag)
        canvas.save(os.path.join(out_dir, "page_%02d.png" % p))
    flags = [k for k in units if results[k]["cells"][0]["verdict"] == "flag"]
    fc = S["flag_cell"]; fcols = 4; frows = 4; fper = fcols * frows
    for p in range((len(flags) + fper - 1) // fper):
        canvas = Image.new("RGBA", (fcols * fc, frows * (fc + label_h)), (30, 28, 26, 255))
        draw = ImageDraw.Draw(canvas)
        for i, key in enumerate(flags[p * fper:(p + 1) * fper]):
            r = results[key]["cells"][0]; arr = results[key]["arr"]
            if len(results[key]["cells"]) > 1: arr = split_cells(arr, len(results[key]["cells"]))[0]
            _draw_unit(canvas, draw, (i % fcols) * fc, (i // fcols) * (fc + label_h), fc, label_h, key, r, arr)
        canvas.save(os.path.join(out_dir, "flagged_%02d.png" % p))
    return pages

def write_zoom(out_dir, key, results, cfg):
    r = results[key]["cells"][0]; arr = results[key]["arr"]
    if len(results[key]["cells"]) > 1: arr = split_cells(arr, len(results[key]["cells"]))[0]
    z = cfg["sheet"]["zoom"]
    h, w = arr.shape[:2]
    pad = 24
    canvas = Image.new("RGBA", (w * z + pad * 2, h * z + pad * 2), (30, 28, 26, 255))
    canvas.alpha_composite(Image.fromarray(arr).resize((w * z, h * z), Image.NEAREST), (pad, pad))
    draw = ImageDraw.Draw(canvas)
    for gx in range(0, w + 1, 8):
        draw.line([(pad + gx * z, pad), (pad + gx * z, pad + h * z)], fill=(255, 255, 255, 40))
        draw.text((pad + gx * z, 4), str(gx), fill=GREY)
    for gy in range(0, h + 1, 8):
        draw.line([(pad, pad + gy * z), (pad + w * z, pad + gy * z)], fill=(255, 255, 255, 40))
        draw.text((2, pad + gy * z), str(gy), fill=GREY)
    def P(pts): return [(pad + (px + 0.5) * z, pad + (py + 0.5) * z) for px, py in pts]
    if r.get("foot"): draw.polygon(P(_corner_list(r["foot"])), outline=CYAN)
    if r.get("face"): draw.polygon(P(_corner_list(r["face"])), outline=YELLOW)
    for i, ru in enumerate(r.get("runners") or []):
        draw.polygon(P(ru["corners"]), outline=GREY); draw.text(P(ru["corners"])[0], str(i + 2), fill=GREY)
    os.makedirs(os.path.join(out_dir, "zoom"), exist_ok=True)
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", key)
    path = os.path.join(out_dir, "zoom", slug + ".png")
    canvas.save(path)
    return path

# ── Self-test fixtures ─────────────────────────────────────────────────

def _iso_box(size=128, w_cells=1.0, h_cells=1.0, height=40, top=(220, 160, 90), left=(170, 110, 60), right=(130, 80, 40),
             outline=(40, 25, 15), dotted=False, headrest=False, headboard=False):
    """A boxy iso sprite: top parallelogram, two side faces, outlined."""
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx = size // 2
    hw = int(32 * w_cells); hh = int(32 * h_cells)        # half-widths along the two iso axes (2:1)
    # floor diamond: T,L,B,R around (cx, base)
    base = size - 12 - height
    L = (cx - hw, base - hw // 2 + 0); R = (cx + hh, base - hh // 2 + 0)
    T = (L[0] + R[0] - cx, L[1] + R[1] - base); B = (cx, base)
    # convention: front corner B at bottom; L is down-left of T, R down-right
    L = (cx - hw, base - (hw) // 2); R = (cx + hh, base - (hh) // 2); T = (L[0] + R[0] - B[0], L[1] + R[1] - B[1])
    up = lambda p: (p[0], p[1] - height)
    if headrest:   # rises behind the top's back corner, as a chair's back does
        d.rectangle([cx - 6, up(T)[1] - 30, cx + 6, up(T)[1] + 6], fill=(150, 40, 40, 255), outline=outline + (255,))
    d.polygon([up(T), up(R), up(B), up(L)], fill=top + (255,), outline=outline + (255,))
    d.polygon([up(L), up(B), B, L], fill=left + (255,), outline=outline + (255,))
    d.polygon([up(B), up(R), R, B], fill=right + (255,), outline=outline + (255,))
    if dotted:
        for y in range(up(T)[1] + 4, up(B)[1] - 2, 4):
            for x in range(L[0] + 4, R[0] - 2, 4):
                if im.getpixel((x, y))[:3] == top:
                    d.point((x, y), fill=(200, 140, 70, 255))
    if headboard:
        d.polygon([up(T), up(R), (up(R)[0], up(R)[1] - 28), (up(T)[0], up(T)[1] - 28)], fill=(90, 60, 40, 255), outline=outline + (255,))
    return np.array(im), {"T": up(T), "L": up(L), "B": up(B), "R": up(R), "height": height, "bottom": B[1] + 1}

def _sticky(size=64):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.polygon([(12, 10), (52, 30), (52, 58), (12, 38)], fill=(240, 230, 90, 255), outline=(60, 50, 10, 255))
    return np.array(im)

def selftest():
    cfg = load_config(None)
    fails = []
    def check(name, cond, detail=""):
        print("  %s %s %s" % ("ok  " if cond else "FAIL", name, detail))
        if not cond: fails.append(name)
    # grouping parity
    keys = ["K/Living Roon/shelving_6", "K/Living Roon/shelving_7", "K/Cat_Ani/Cat_99_2_A", "K/Cat_Ani/Cat_99_2_B",
            "K/Clock_Ani/Clock_1", "K/Clock_Ani/Clock_2", "K/Clock_Ani/Clock_3", "K/Microwave/Microwave_5_Tile",
            "K/Microwave/Microwave_5_Tile_B", "K/Microwave/Microwave_5_Tile_C", "K/Bedroom/Night_Table_Tile(Drawer_1)",
            "K/Doors/Door_2_Brown", "cards/clubs_2"]
    g = group_animations(keys)
    check("group shelving_6/7", g.get("K/Living Roon/shelving_7", ("", -1, []))[2] == ["K/Living Roon/shelving_6", "K/Living Roon/shelving_7"])
    check("group letters", g.get("K/Cat_Ani/Cat_99_2_B", ("", -1, []))[1] == 1)
    check("group numbers", [m for m in g.get("K/Clock_Ani/Clock_2", ("", -1, []))[2]] == ["K/Clock_Ani/Clock_1", "K/Clock_Ani/Clock_2", "K/Clock_Ani/Clock_3"])
    check("variant letters group", "K/Microwave/Microwave_5_Tile_C" in g and "K/Microwave/Microwave_5_Tile" not in g)
    check("drawer alone", "K/Bedroom/Night_Table_Tile(Drawer_1)" not in g)
    check("cards skipped", "cards/clubs_2" not in g)
    # (a) crate
    arr, truth = _iso_box()
    r = analyse_cell(arr, cfg)
    check("crate face", r["verdict"] == "face", "got %s %s score %.2f" % (r["verdict"], r.get("why"), r["score"]))
    if r.get("face"):
        err = drift_px(r["face"], truth)
        check("crate corners", err <= 2, "max corner error %d px" % err)
        check("crate height", abs(r["height"] - truth["height"]) <= 1, "got %s want %d" % (r["height"], truth["height"]))
        check("crate bottom", r["bottom"] == truth["bottom"], "got %s want %d" % (r["bottom"], truth["bottom"]))
    # (b) dotted top
    arr, truth = _iso_box(dotted=True)
    r = analyse_cell(arr, cfg)
    check("dotted face", r["verdict"] == "face" and r.get("face") and drift_px(r["face"], truth) <= 2,
          "got %s %s" % (r["verdict"], r.get("why")))
    # (c) sticky note
    r = analyse_cell(_sticky(), cfg)
    check("sticky none", r["verdict"] == "none" and r.get("why") == "vertical", "got %s %s" % (r["verdict"], r.get("why")))
    # (d) headrest
    arr, truth = _iso_box(headrest=True)
    r = analyse_cell(arr, cfg)
    check("headrest ignored", r["verdict"] == "face" and r.get("face") and drift_px(r["face"], truth) <= 2,
          "got %s %s" % (r["verdict"], r.get("why")))
    # (e) strip of three crates
    arr, truth = _iso_box()
    strip = np.concatenate([arr, arr, arr], axis=1)
    cells = split_cells(strip, 3)
    rs = [analyse_cell(c, cfg) for c in cells]
    check("strip cells", len(cells) == 3 and all(x["verdict"] == "face" for x in rs))
    # (f) bed with headboard: the face is below the silhouette's top
    arr, truth = _iso_box(w_cells=1.5, height=24, headboard=True)
    r = analyse_cell(arr, cfg)
    check("headboard bed", r["verdict"] in ("face", "flag") and r.get("face") and drift_px(r["face"], truth) <= 3,
          "got %s %s score %.2f drift %s" % (r["verdict"], r.get("why"), r["score"], drift_px(r.get("face"), truth) if r.get("face") else "-"))
    # (g) rectangular top
    arr, truth = _iso_box(w_cells=2.0, h_cells=1.0, height=30)
    r = analyse_cell(arr, cfg)
    check("rectangular top", r["verdict"] == "face" and r.get("face") and drift_px(r["face"], truth) <= 2,
          "got %s %s drift %s" % (r["verdict"], r.get("why"), drift_px(r.get("face"), truth) if r.get("face") else "-"))
    print("selftest: %d failure(s)" % len(fails))
    return 1 if fails else 0

# ── Main ───────────────────────────────────────────────────────────────

def run_check(results, cfg):
    fails = 0
    for key, want in cfg.get("expect", {}).items():
        r = results.get(key)
        if r is None:
            print("  MISSING %s" % key); fails += 1; continue
        c = r["cells"][0]
        ok = c["verdict"] == want[0]
        if ok and len(want) >= 3 and c.get("height") is not None:
            ok = want[1] <= c["height"] <= want[2]
        print("  %s %s: %s %.2f h=%s (want %s)" % ("ok  " if ok else "FAIL", key, c["verdict"], c["score"], c.get("height"), want))
        if not ok: fails += 1
    print("check: %d failure(s)" % fails)
    return 1 if fails else 0

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.join(ROOT, "assets", "sprites"))
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--overrides", default=os.path.join(HERE, "overrides.json"))
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--only", nargs="*", default=None)
    ap.add_argument("--no-sheets", action="store_true")
    ap.add_argument("--zoom", nargs="*", default=None)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    cfg = load_config(a.config)
    overrides = {}
    if os.path.exists(a.overrides):
        with open(a.overrides, encoding="utf-8") as fh:
            overrides = json.load(fh).get("overrides", {})
    files = scan(a.root, cfg["folders"], cfg["skip_globs"], cfg["max_side"])
    files_by_key = {f.key: f for f in files}
    groups = group_animations([f.key for f in files])
    for f in files:
        f.group = groups.get(f.key)
    todo = [f for f in files if not f.skipped]
    if a.only:
        todo = [f for f in todo if any(fnmatch.fnmatch(f.key, "*" + g) or fnmatch.fnmatch(f.key, g) for g in a.only)]
    log("%d sprites, %d groups, %d to analyse" % (len(files), len(set(g[0] for g in groups.values())), len(todo)))
    results = {}
    for i, f in enumerate(todo):
        results[f.key] = analyse_file(f, cfg)
        if (i + 1) % 100 == 0: log("  %d/%d" % (i + 1, len(todo)))
    report = apply_overrides(results, overrides, groups, cfg, files_by_key)
    mark_drift(results, groups, cfg)
    os.makedirs(a.out, exist_ok=True)
    review = os.path.join(a.out, "review")
    os.makedirs(review, exist_ok=True)
    units = review_units(results, groups)
    if not a.only:
        write_json(os.path.join(a.out, "surfaces.json"), results, files, cfg, kit_fingerprint(files))
    write_csv(os.path.join(review, "report.csv"), results, groups, units)
    lines = summary_lines(results, report, files)
    with open(os.path.join(review, "summary.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    for l in lines[:4]: log(l)
    for k, why in report["stale"]: log("  stale override: %s — %s" % (k, why))
    if not a.no_sheets:
        pages = write_sheets(review, results, groups, units, cfg)
        log("%d review pages in %s" % (pages, review))
    for key in a.zoom or []:
        if key in results: log("zoom: " + write_zoom(review, key, results, cfg))
        else: log("zoom: no such sprite in this run: " + key)
    rc = 0
    if a.check:
        rc = run_check(results, cfg)
    if a.strict:
        # Frames past the first of an animation are not review units (the
        # game draws frame 1's entry for an animating sprite).
        flags = sum(1 for k, r in results.items() if r["cells"][0]["verdict"] == "flag"
                    and not (k in groups and groups[k][1] > 0))
        if flags or report["stale"]:
            log("strict: %d flag(s), %d stale override(s)" % (flags, len(report["stale"]))); rc = 1
    return rc

if __name__ == "__main__":
    sys.exit(main())
