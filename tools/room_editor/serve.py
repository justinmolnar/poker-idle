#!/usr/bin/env python
"""The room editor's server.

    python tools/room_editor/serve.py        (opens http://127.0.0.1:8765)

Serves tools/room_editor/index.html + editor.js, the sprites straight from
assets/sprites, and /api/data: the layout, the surfaces, the catalog, the
tile kit, the aliases, the animation groups and a per-sprite index (size,
strip cells, bottom row) that the page needs to draw the room the way the
game does. POST /api/save writes data/room_layout.lua (and moves the dev
build's autosaved draft aside, which would otherwise shadow the file).

Dev tooling only. Needs Pillow (tools/requirements-dev.txt) and `lua` on
the PATH (the data files are Lua; it dumps them as JSON).
"""
import json, os, re, sys, subprocess, threading, webbrowser, time, shutil, io
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SPRITES = os.path.join(ROOT, "assets", "sprites")
INDEX_CACHE = os.path.join(HERE, "sprite_index.cache.json")
PORT = int(os.environ.get("ROOM_EDITOR_PORT", "8765"))

# What the shelf offers and the room may draw: the furniture kit, the
# house's own art and anything at the top level. Not the cards.
INCLUDE_DIRS = ("TinyHouse_0.17(@Pixel_Salvaje)", "house")


def lua_json(expr):
    """Run `lua` from the repo root and return the JSON it prints for `expr`."""
    code = ("package.path='./?.lua;./?/init.lua;'..package.path;"
            "local json=require('lib.json');"
            "io.write(json.encode(%s))" % expr)
    out = subprocess.run(["lua", "-e", code], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return json.loads(out.stdout)


def scan_keys():
    keys = []
    for base in INCLUDE_DIRS:
        d = os.path.join(SPRITES, base)
        if not os.path.isdir(d):
            continue
        for dirpath, _, files in os.walk(d):
            for f in files:
                if f.lower().endswith(".png"):
                    rel = os.path.relpath(os.path.join(dirpath, f), SPRITES).replace("\\", "/")
                    keys.append(rel[:-4])
    for f in os.listdir(SPRITES):
        if f.lower().endswith(".png"):
            keys.append(f[:-4])
    return sorted(set(keys))


def sprite_info(key):
    """Size, strip cells and the bottom opaque row per cell (what the game's
    getSpriteBottom and SpriteLoader:_sliceStrip compute)."""
    from PIL import Image
    path = os.path.join(SPRITES, key + ".png")
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    cells = 1
    if h > 0 and w % h == 0 and w // h >= 3:
        cells = w // h
    cw = w // cells
    bottoms = []
    alpha = im.getchannel("A")
    for c in range(cells):
        cell = alpha.crop((c * cw, 0, (c + 1) * cw, h))
        bbox = cell.getbbox()           # (l, t, r, b) of non-zero alpha
        bottoms.append(bbox[3] if bbox else h)
    return {"w": w, "h": h, "cells": cells, "cell_w": cw, "bottoms": bottoms,
            "mtime": os.path.getmtime(path)}


def sprite_index():
    cache = {}
    if os.path.exists(INDEX_CACHE):
        try:
            with open(INDEX_CACHE, encoding="utf-8") as f:
                cache = json.load(f)
        except Exception:
            cache = {}
    out, dirty = {}, False
    for key in scan_keys():
        path = os.path.join(SPRITES, key + ".png")
        mt = os.path.getmtime(path)
        c = cache.get(key)
        if c and abs(c.get("mtime", -1) - mt) < 1e-6:
            out[key] = c
        else:
            try:
                out[key] = sprite_info(key)
                dirty = True
            except Exception as e:
                print("[room-editor] skip", key, e)
    if dirty or set(out) != set(cache):
        with open(INDEX_CACHE, "w", encoding="utf-8") as f:
            json.dump(out, f)
    return out


FRAME_PATTERNS = [re.compile(p) for p in (
    r"^(.*?)[-_]Frame[-_]?(\d+)$",
    r"^(.*?)[-_](\d+)$",
    r"^(.*?)[-_/](\d+)$",
    r"^(.*?)[-_]([A-Za-z])$",
)]


def animations(keys):
    """SpriteLoader:_buildAnimations: keys that end in a frame number (or a
    letter) group by their prefix; groups of two or more are sequences,
    reachable by the prefix and by every frame's key."""
    groups = {}
    for key in keys:
        if "cards/" in key:
            continue
        for pat in FRAME_PATTERNS:
            m = pat.match(key)
            if m:
                base, num = m.group(1), m.group(2)
                n = int(num) if num.isdigit() else ord(num)
                groups.setdefault(base, []).append((n, key))
                break
    out = {}
    for base, frames in groups.items():
        if len(frames) >= 2:
            frames.sort()
            seq = [k for _, k in frames]
            out[base] = seq
            for k in seq:
                out[k] = seq
    return out


def build_data():
    data = lua_json("{ layout = dofile('data/room_layout.lua'), surfaces = dofile('data/room_surfaces.lua'), "
                    "tiles = dofile('data/room_tiles.lua') }")
    cat = lua_json("(function() local out = {} for _, it in ipairs(dofile('data/catalog.lua')) do "
                   "out[#out+1] = { id = it.id, name = it.name, sprite = it.sprite, hidden = it.hidden or false, "
                   "retired = it.retired or false, frame = it.frame, anim_room = it.anim_room } end return out end)()")
    with open(os.path.join(SPRITES, "aliases.json"), encoding="utf-8") as f:
        aliases = json.load(f).get("aliases", {})
    idx = sprite_index()
    return {
        "layout": data["layout"], "surfaces": data["surfaces"], "tiles": data["tiles"],
        "catalog": cat, "aliases": aliases, "sprites": idx, "animations": animations(list(idx.keys())),
        "root": ROOT,
    }


def love_save_dir():
    appdata = os.environ.get("APPDATA")
    if appdata:
        return os.path.join(appdata, "LOVE", "poker-idle")
    return None


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if "/sprites/" in (args[0] if args else ""):
            return
        sys.stderr.write("[room-editor] " + (fmt % args) + "\n")

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            pass    # the browser went away mid-reply (a reload); nothing to do

    def do_GET(self):
        u = urlparse(self.path)
        path = unquote(u.path)
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if path == "/editor.js":
            with open(os.path.join(HERE, "editor.js"), "rb") as f:
                return self._send(200, f.read(), "text/javascript; charset=utf-8")
        if path == "/favicon.ico":
            return self._send(204, b"", "image/x-icon")
        if path == "/api/data":
            try:
                return self._send(200, json.dumps(build_data()))
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        if path.startswith("/sprites/"):
            rel = path[len("/sprites/"):]
            full = os.path.normpath(os.path.join(SPRITES, rel))
            if not full.startswith(os.path.normpath(SPRITES)) or not os.path.isfile(full):
                return self._send(404, "no such sprite", "text/plain")
            with open(full, "rb") as f:
                return self._send(200, f.read(), "image/png")
        return self._send(404, "not found", "text/plain")

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8")
        if u.path == "/api/save":
            target = os.path.join(ROOT, "data", "room_layout.lua")
            with open(target, "w", encoding="utf-8", newline="\n") as f:
                f.write(body if body.endswith("\n") else body + "\n")
            moved = []
            sd = love_save_dir()
            if sd:
                for name in ("room_layout_draft.lua", "room_layout_draft.bak.lua"):
                    p = os.path.join(sd, name)
                    if os.path.exists(p):
                        bak = p + ".before-editor-save"
                        shutil.move(p, bak)
                        moved.append(bak)
            return self._send(200, json.dumps({"ok": True, "path": target, "moved": moved}))
        if u.path == "/api/draft":
            with open(os.path.join(HERE, "draft.json"), "w", encoding="utf-8") as f:
                f.write(body)
            return self._send(200, json.dumps({"ok": True}))
        return self._send(404, "not found", "text/plain")


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = "http://127.0.0.1:%d/" % PORT
    print("[room-editor] serving", ROOT, "at", url)
    if "--no-browser" not in sys.argv:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
