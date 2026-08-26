#!/usr/bin/env python3
"""
build_web.py — produce the itch.io web build of Poker Idle.

Pipeline (all output lands in build/, which is gitignored):
  1. Zip the game source into build/PokerIdle.love (entries at the archive
     root, forward-slash paths — what LÖVE / love.js expect). Assets that
     can never be used at runtime are pruned from the package (never from
     the repo): unreferenced sample-pack audio, undecodable .gif files,
     and asset-folder manifests. The referenced-audio list comes from
     data/sounds.lua itself via build-tools/list_shipped_audio.lua.
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

Prereqs: Node.js, love.js installed (`cd build-tools && npm install`), and
`lua` on PATH for the audio-prune helper (skipped with a warning if absent).

Flags:
  --demo         confirm a DEMO build. Required when data/constants.lua has
                 C.DEMO = true, refused when it doesn't — the boolean can no
                 longer ship wrong silently.
  --allow-dirty  package even with uncommitted changes (default: refuse).

Run from anywhere: `python build-tools/build_web.py [--demo] [--allow-dirty]`.
"""

import os
import re
import shutil
import subprocess
import sys
import time
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

ALLOW_DIRTY = "--allow-dirty" in sys.argv
DEMO_BUILD = "--demo" in sys.argv

# Audio folders SoundLoader discovers dynamically — they ship whole (minus
# raw/ subfolders, which the loader itself skips).
DISCOVERY_PREFIXES = ("assets/audio/items/", "assets/audio/room/", "assets/audio/felt/")


def log(msg):
    print(f"[build_web] {msg}")


def check_git_clean():
    try:
        out = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=ROOT, capture_output=True, text=True,
        ).stdout.strip()
    except Exception as e:
        log(f"WARNING: could not check git status ({e})")
        return
    if out:
        log("working tree is DIRTY:")
        for line in out.splitlines():
            print("    " + line)
        if not ALLOW_DIRTY:
            sys.exit("[build_web] refusing to package a dirty tree — a build "
                     "must come from a commit. Pass --allow-dirty to override.")
        log("packaging anyway (--allow-dirty)")


def read_demo_flag():
    txt = open(os.path.join(ROOT, "data", "constants.lua"), encoding="utf-8").read()
    m = re.search(r"^C\.DEMO\s*=\s*(true|false)", txt, re.M)
    if not m:
        sys.exit("[build_web] could not find C.DEMO in data/constants.lua")
    return m.group(1) == "true"


def shipped_audio():
    """The set of audio paths data/sounds.lua references, via the Lua helper.
    None (with a warning) when lua isn't available — pruning is then skipped
    rather than guessed."""
    helper = os.path.join(ROOT, "build-tools", "list_shipped_audio.lua")
    try:
        out = subprocess.run(
            ["lua", helper], cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout
    except Exception as e:
        log(f"WARNING: audio prune skipped (lua helper failed: {e})")
        return None
    refs = set()
    for line in out.splitlines():
        line = line.strip().replace("\\", "/")
        if line:
            refs.add(line)
    if not refs:
        log("WARNING: audio helper returned nothing; prune skipped")
        return None
    return refs


def make_excluder(referenced):
    """Returns (exclude_fn, pruned_list). exclude_fn(arcname, path) -> bool.
    Rules (package-only — the repo keeps every file):
      - .gif under assets/: LÖVE cannot decode gif at all.
      - .md under assets/, and manifest.json under assets/audio/: attribution
        notes for the repo, not runtime data.
      - raw/ subfolders inside the discovery audio dirs (loader skips them).
      - any other assets/audio file data/sounds.lua doesn't reference
        (unused sample-pack subfolders, legacy MP3s)."""
    pruned = []

    def exclude(arc, path):
        a = arc.replace("\\", "/")
        low = a.lower()
        if a.startswith("assets/"):
            if low.endswith(".gif"):
                pruned.append((a, os.path.getsize(path))); return True
            if low.endswith(".md"):
                pruned.append((a, os.path.getsize(path))); return True
        if a.startswith("assets/audio/"):
            if low.endswith("manifest.json"):
                pruned.append((a, os.path.getsize(path))); return True
            for d in DISCOVERY_PREFIXES:
                if a.startswith(d):
                    if "/raw/" in a:
                        pruned.append((a, os.path.getsize(path))); return True
                    return False
            if referenced is not None and a not in referenced:
                pruned.append((a, os.path.getsize(path))); return True
        return False

    return exclude, pruned


def zip_dir(out_path, base_dir, items=None, exclude=None):
    """Zip files at the archive root (forward-slash arcnames). When `items`
    is given, only those top-level entries (under base_dir) are included;
    otherwise the whole base_dir is walked. `exclude(arc, path)` skips."""
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
                        if exclude and exclude(arc, p):
                            continue
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
    check_git_clean()

    demo = read_demo_flag()
    log(f"data/constants.lua: C.DEMO = {str(demo).lower()}")
    if demo and not DEMO_BUILD:
        sys.exit("[build_web] C.DEMO is true — pass --demo to confirm you are "
                 "building the demo, or flip the flag back for a dev build.")
    if DEMO_BUILD and not demo:
        sys.exit("[build_web] --demo passed but data/constants.lua has "
                 "C.DEMO = false. Flip the flag (and commit) first.")

    os.makedirs(BUILD, exist_ok=True)

    log("1/4 packaging .love")
    exclude, pruned = make_excluder(shipped_audio())
    n = zip_dir(LOVE_FILE, ROOT, LOVE_ITEMS, exclude=exclude)
    log(f"      {LOVE_FILE} ({n} entries)")
    if pruned:
        total = sum(sz for _, sz in pruned)
        log(f"      pruned {len(pruned)} unused asset files "
            f"({total / 1024:.0f} KB) — repo untouched:")
        for a, sz in pruned:
            print(f"        - {a} ({sz / 1024:.0f} KB)")

    log("2/4 running love.js (compatibility build)")
    lovejs = find_lovejs()
    # Clear WEB_DIR's *contents* rather than removing the directory itself —
    # on Windows something (a stale file-watcher, seemingly) can hold a raw
    # handle on the directory entry itself long after every file inside it is
    # gone, which makes rmdir/rename fail even on an empty folder. Deleting
    # the children doesn't need that handle at all.
    if os.path.isdir(WEB_DIR):
        for entry in os.listdir(WEB_DIR):
            p = os.path.join(WEB_DIR, entry)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
            else:
                try:
                    os.remove(p)
                except PermissionError:
                    pass
    else:
        os.makedirs(WEB_DIR)
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
