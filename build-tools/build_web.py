#!/usr/bin/env python3
"""
build_web.py — produce the itch.io web build of Poker Idle.

Pipeline (all output lands in build/, which is gitignored):
  1. Zip the game source into build/PokerIdle.love (entries at the archive
     root, forward-slash paths — what LÖVE / love.js expect).
  2. Run the love.js transpiler (compatibility variant) to emit the web
     player into build/web/ (game.data, game.js, love.js, love.wasm, a
     default index.html, and a theme/ folder).
  3. Overwrite the generated index.html with our custom shell
     (build-tools/index.html) — the DPR-aware canvas-fitting page. The
     generated one is thrown away every build, so the custom shell is the
     tracked source of truth.
  4. Zip build/web/ into build/PokerIdle-web.zip (entries at the root) for
     upload to itch.

This does NOT launch LÖVE or the game — love.js is a Node transpiler.

Prereqs: Node.js, and love.js installed (`cd build-tools && npm install`).
Run from anywhere: `python build-tools/build_web.py`.
"""

import os
import shutil
import subprocess
import sys
import zipfile

# love.js settings (matching the shipped build):
#   -c  compatibility variant — no pthreads. itch.io doesn't send the
#       COOP/COEP headers SharedArrayBuffer needs, so the threaded variant
#       breaks there; compat is the one that runs on itch.
#   memory is left at the love.js default (16 MB) with dynamic growth, so no
#       -m flag is passed.
TITLE = "Poker Idle"

# Game source included in the .love. Everything else (build/, docs/, .git,
# .claude, .vscode, build-tools) is excluded.
LOVE_ITEMS = [
    "conf.lua", "main.lua",
    "assets", "controllers", "core", "data", "lib",
    "models", "services", "shaders", "states", "utils", "views",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
LOVE_FILE = os.path.join(BUILD, "PokerIdle.love")
WEB_DIR = os.path.join(BUILD, "web")
WEB_ZIP = os.path.join(BUILD, "PokerIdle-web.zip")
SHELL = os.path.join(ROOT, "build-tools", "index.html")

# Where love.js's CLI might live (prefer the tracked build-tools project).
LOVEJS_CANDIDATES = [
    os.path.join(ROOT, "build-tools", "node_modules", "love.js", "index.js"),
    os.path.join(ROOT, "build", "tools", "node_modules", "love.js", "index.js"),
]


def log(msg):
    print(f"[build_web] {msg}")


def zip_dir(out_path, base_dir, items=None):
    """Zip files at the archive root (forward-slash arcnames). When `items`
    is given, only those top-level entries (under base_dir) are included;
    otherwise the whole base_dir is walked."""
    count = 0
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        roots = (
            [os.path.join(base_dir, it) for it in items]
            if items else [base_dir]
        )
        for r in roots:
            if os.path.isfile(r):
                z.write(r, os.path.relpath(r, base_dir).replace(os.sep, "/"))
                count += 1
            else:
                for dirpath, _, files in os.walk(r):
                    for f in files:
                        p = os.path.join(dirpath, f)
                        arc = os.path.relpath(p, base_dir).replace(os.sep, "/")
                        z.write(p, arc)
                        count += 1
    return count


def find_lovejs():
    for c in LOVEJS_CANDIDATES:
        if os.path.isfile(c):
            return c
    sys.exit(
        "love.js not found. Install it first:\n"
        "    cd build-tools && npm install"
    )


def main():
    os.makedirs(BUILD, exist_ok=True)

    log("1/4 packaging .love")
    n = zip_dir(LOVE_FILE, ROOT, LOVE_ITEMS)
    log(f"      {LOVE_FILE} ({n} entries)")

    log("2/4 running love.js (compatibility build)")
    lovejs = find_lovejs()
    if os.path.isdir(WEB_DIR):
        shutil.rmtree(WEB_DIR)
    subprocess.run(
        ["node", lovejs, "-c", "-t", TITLE, LOVE_FILE, WEB_DIR],
        check=True,
    )

    log("3/4 installing custom web shell")
    if not os.path.isfile(SHELL):
        sys.exit(f"missing custom shell: {SHELL}")
    shutil.copyfile(SHELL, os.path.join(WEB_DIR, "index.html"))

    log("4/4 packaging itch zip")
    n = zip_dir(WEB_ZIP, WEB_DIR)
    log(f"      {WEB_ZIP} ({n} entries)")

    log("done. Upload build/PokerIdle-web.zip to itch (HTML5, fullscreen).")


if __name__ == "__main__":
    main()
