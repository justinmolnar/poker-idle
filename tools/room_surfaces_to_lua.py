"""tools/room_surfaces_to_lua.py — tools/surfaces/surfaces.json -> data/room_surfaces.lua

The only game-specific step of the surfaces tool: the engine-agnostic JSON
from tools/room_surfaces.py becomes a Lua table keyed by sprite file key,
read by services/RoomSurfaces.lua. Deterministic: sorted keys, one entry
per line, no timestamps.

    python tools/room_surfaces_to_lua.py [--in tools/surfaces/surfaces.json] [--out data/room_surfaces.lua]
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HEADER = """-- data/room_surfaces.lua
--
-- ═══════════════════════════════════════════════════════════════════════
-- GENERATED FILE — DO NOT HAND-EDIT
-- Regenerate with:
--   python tools/room_surfaces.py && python tools/room_surfaces_to_lua.py
-- Source: tools/surfaces/surfaces.json (tools/room_surfaces.py over assets/sprites)
-- Hand decisions: tools/surfaces/overrides.json
-- ═══════════════════════════════════════════════════════════════════════
--
-- Per sprite: its TOP FACE (the parallelogram another item sits on), its
-- FOOTPRINT, and the HEIGHT between them, in SPRITE PIXEL SPACE: origin
-- at the top-left of the PNG (for a strip, of each cell), x right, y down,
-- native scale — multiply by the item's own `scale`. `bottom` is the
-- lowest opaque row + 1 (what views/RoomView getSpriteBottom returns).
-- Keyed by sprite FILE key (the path under assets/sprites, no extension):
-- for an animating sprite the reader uses frame 1's entry; a pinned frame
-- uses its own. A strip carries `cells`, one per cell, cell 1 at the top.
--
--   v     "face" | "none"          src  "auto" | "override" | "filter"
--   face  { Tx,Ty, Lx,Ly, Bx,By, Rx,Ry }   foot the same, on the floor
--   height  face.B to the bottom row, px   cell { w, h }
--
-- Reader: services/RoomSurfaces.lua. Checked by sim/smoke_boot.lua.
"""

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def corners(c):
    return "{ %d,%d, %d,%d, %d,%d, %d,%d }" % tuple(v for k in ("T", "L", "B", "R") for v in c[k])

def entry(e):
    v = "face" if e["v"] == "face" else "none"
    parts = ["v = %s" % lua_str(v), "src = %s" % lua_str(e.get("src", "auto")),
             "score = %.3f" % float(e.get("score", 0)), "bottom = %d" % int(e.get("bottom") or 0),
             "cell = { %d, %d }" % tuple(e["cell"])]
    if v == "face" and e.get("face"):
        parts.append("height = %d" % int(e["height"]))
        parts.append("face = " + corners(e["face"]))
    if e.get("foot"):
        parts.append("foot = " + corners(e["foot"]))
    if e.get("cells"):
        parts.append("cells = { " + ", ".join("{ " + entry(c) + " }" for c in e["cells"]) + " }")
    return ", ".join(parts)

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default=os.path.join(ROOT, "tools", "surfaces", "surfaces.json"))
    ap.add_argument("--out", default=os.path.join(ROOT, "data", "room_surfaces.lua"))
    a = ap.parse_args(argv)
    with open(a.src, encoding="utf-8") as fh:
        data = json.load(fh)
    meta, sprites = data["__meta"], data["sprites"]
    lines = [HEADER, "return {",
             "    __meta = { format = %s, space = %s, count = %d, fingerprint = %s }," % (
                 lua_str(meta["format"]), lua_str(meta["space"]), len(sprites), lua_str(meta["fingerprint"]))]
    faces = 0
    for key in sorted(sprites):
        e = sprites[key]
        if e["v"] == "face": faces += 1
        lines.append("    [%s] = { %s }," % (lua_str(key), entry(e)))
    lines.append("}")
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("[surfaces] wrote %s: %d sprites, %d with a face" % (os.path.relpath(a.out, ROOT), len(sprites), faces))
    return 0

if __name__ == "__main__":
    sys.exit(main())
