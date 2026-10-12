#!/usr/bin/env python3
"""
build.py — build the game: the web (itch) and win64 (Steam, itch) targets,
a dev build or the demo, from a STAGED copy of the source. The repo is never
rewritten; C.DEMO stays false here forever.

    python build-tools/build.py --target web|win64|all [--demo | --playtest]
                                [--version 0.1.0] [--allow-dirty] [--smoke]
                                [--skip-tests]

Steps (output under build/<version>/, gitignored):
  1. preflight   a clean tree (or --allow-dirty); C.DEMO false in the repo;
                 the suites and lints (or --skip-tests)
  2. stage       copy the source manifest (LOVE_ITEMS) to build/stage with
                 the package-only prune: .gif, asset .md and manifest.json,
                 raw/ audio folders, audio data/sounds.lua never references
  3. stamp       C.BUILD = version; --demo: C.DEMO = true and a demo save
                 identity; --playtest: the same plus C.PLAYTEST = true;
                 C.STEAM_URL from build-tools/build.toml; the window title
                 asserted equal to C.TITLE
  4. cut + lint  --demo/--playtest: demo_cut.py on the stage, then
                 demo_lint.lua over it (fails the build)
  5. credits     credits.py writes CREDITS.txt into the stage (the title's
                 Credits reads it) and beside the artefacts
  6. .love       the staged tree zipped, forward-slash entries at the root
  7. web         love.js (compat variant) + the custom shell, zipped for itch
  8. win64       the engine from build-tools/engine.lock (hash-checked),
                 love.exe + .love fused, the DLL set, license and credits,
                 the icon and version info through rcedit when present,
                 zipped
  9. report      sizes and sha256 of every artefact in BUILD.txt

--smoke: a throwaway build to look at — unplaced room items, credit TODOs
and a missing icon are warnings instead of failures.

Prereqs: Python 3.11+, lua on PATH, Node.js with love.js installed
(`cd build-tools && npm install`), the LÖVE 12 build the lock names (for
win64), and optionally build-tools/bin/rcedit-x64.exe. See docs/build.md.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tomllib
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "build-tools")
BUILD = os.path.join(ROOT, "build")
STAGE = os.path.join(BUILD, "stage")
SLUG = "IHardlyKnower"

LOVE_ITEMS = [
    "conf.lua", "main.lua",
    "assets", "controllers", "core", "data", "lib",
    "models", "services", "shaders", "states", "utils", "views",
]
# Audio folders SoundLoader discovers at runtime: they ship whole (minus raw/).
DISCOVERY_PREFIXES = ("assets/audio/items/", "assets/audio/room/", "assets/audio/felt/",
                      "assets/audio/radio/", "assets/audio/music/", "assets/audio/layers/",
                      "assets/audio/ui/")
LOVEJS_CANDIDATES = [os.path.join(TOOLS, "node_modules", "love.js", "index.js")]
SUITES = ["sim/test_everything.lua", "sim/smoke_views.lua", "sim/smoke_boot.lua", "sim/smoke_bar.lua",
          "sim/smoke_ui.lua", "sim/smoke_storybox.lua", "sim/smoke_demo_end.lua", "sim/smoke_settings.lua", "sim/smoke_tooltip.lua",
          "sim/lint_copy.lua", "sim/lint_terms.lua", "sim/lint_catalog_economy.lua", "sim/iconize_check.lua",
          "sim/smoke_story_copy.lua"]
ENGINE_DLLS_REQUIRED = ["love.dll", "lua51.dll", "SDL3.dll", "OpenAL32.dll"]


def log(msg):
    print(f"[build] {msg}")


def die(msg):
    sys.exit(f"[build] {msg}")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def constant(text, name):
    m = re.search(r'^C\.%s\s*=\s*"([^"]*)"' % re.escape(name), text, re.M)
    return m.group(1) if m else None


def config():
    p = os.path.join(TOOLS, "build.toml")
    if not os.path.isfile(p):
        return {}
    with open(p, "rb") as f:
        return tomllib.load(f)


# ── 1. preflight ─────────────────────────────────────────────────────────

def preflight(args):
    out = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if out:
        log("the working tree is DIRTY:")
        for line in out.splitlines():
            print("    " + line)
        if not args.allow_dirty:
            die("a build comes from a commit; pass --allow-dirty to override")
    consts = read(os.path.join(ROOT, "data", "constants.lua"))
    if re.search(r"^C\.DEMO\s*=\s*true", consts, re.M):
        die("data/constants.lua has C.DEMO = true: the repo keeps it false, the build sets it on the stage")
    if not args.skip_tests:
        for suite in SUITES:
            log(f"running {suite}")
            r = subprocess.run(["lua", suite], cwd=ROOT, capture_output=True, text=True)
            tail = (r.stdout + r.stderr).strip().splitlines()[-1:] or [""]
            print("    " + tail[0])
            if r.returncode != 0:
                die(f"{suite} failed")
        subprocess.run(["git", "checkout", "-q", "docs/sim-audit.md"], cwd=ROOT)


# ── 2. stage ─────────────────────────────────────────────────────────────

def shipped_audio():
    helper = os.path.join(TOOLS, "list_shipped_audio.lua")
    out = subprocess.run(["lua", helper], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    refs = {line.strip().replace("\\", "/") for line in out.splitlines() if line.strip()}
    if not refs:
        die("list_shipped_audio.lua returned nothing")
    return refs


def excluder(referenced):
    pruned = []

    def exclude(arc, path):
        a = arc.replace("\\", "/")
        low = a.lower()
        if a.startswith("assets/") and (low.endswith(".gif") or low.endswith(".md")):
            pruned.append(a); return True
        if a.startswith("assets/audio/"):
            if low.endswith("manifest.json"):
                pruned.append(a); return True
            for d in DISCOVERY_PREFIXES:
                if a.startswith(d):
                    if "/raw/" in a:
                        pruned.append(a); return True
                    return False
            if a not in referenced:
                pruned.append(a); return True
        return False
    return exclude, pruned


def stage():
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    os.makedirs(STAGE)
    exclude, pruned = excluder(shipped_audio())
    n = 0
    for item in LOVE_ITEMS:
        src = os.path.join(ROOT, item)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(STAGE, item)); n += 1
            continue
        for dirpath, _, files in os.walk(src):
            for f in files:
                p = os.path.join(dirpath, f)
                arc = os.path.relpath(p, ROOT).replace(os.sep, "/")
                if exclude(arc, p):
                    continue
                dst = os.path.join(STAGE, arc)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(p, dst); n += 1
    log(f"staged {n} files to build/stage ({len(pruned)} pruned)")


# ── 3. stamp ─────────────────────────────────────────────────────────────

def stamp(args, cfg):
    cp = os.path.join(STAGE, "data", "constants.lua")
    consts = read(cp)
    title = constant(consts, "TITLE")
    repo_build = constant(consts, "BUILD")
    version = args.version or repo_build
    steam_url = cfg.get("steam_url", "") or constant(consts, "STEAM_URL") or ""

    def set_const(text, name, value):
        new, n = re.subn(r'^(C\.%s\s*=\s*)("[^"]*"|true|false)' % re.escape(name),
                         lambda m: m.group(1) + value, text, flags=re.M)
        if n != 1:
            die(f"could not stamp C.{name} on the stage")
        return new
    consts = set_const(consts, "BUILD", f'"{version}"')
    consts = set_const(consts, "STEAM_URL", f'"{steam_url}"')
    if args.demo or args.playtest:
        consts = set_const(consts, "DEMO", "true")
    if args.playtest:
        consts = set_const(consts, "PLAYTEST", "true")
    write(cp, consts)

    conf = os.path.join(STAGE, "conf.lua")
    text = read(conf)
    m = re.search(r'^\s*t\.window\.title\s*=\s*"([^"]*)"', text, re.M)
    if not m or m.group(1) != title:
        die(f"conf.lua's window title ({m and m.group(1)}) is not C.TITLE ({title})")
    identity = "poker-idle"
    if args.playtest:
        identity = "poker-idle-playtest"
    elif args.demo:
        identity = "poker-idle-demo"
    text, n = re.subn(r'^(\s*t\.identity\s*=\s*)"[^"]*"', lambda mm: mm.group(1) + f'"{identity}"', text, flags=re.M)
    if n != 1:
        die("could not stamp t.identity on the stage")
    write(conf, text)
    kind = "playtest" if args.playtest else "demo" if args.demo else "dev"
    log(f"stamped {kind} build {version} (identity {identity}, STEAM_URL {'set' if steam_url else 'empty'})")
    return version, title, steam_url


# ── 4. cut + lint ────────────────────────────────────────────────────────

def cut_and_lint(args):
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "demo_cut.py"), STAGE])
    if r.returncode != 0:
        die("demo_cut.py failed")
    cmd = ["lua", os.path.join(TOOLS, "demo_lint.lua"), STAGE]
    if args.smoke:
        cmd.append("--allow-unplaced")
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode != 0:
        die("demo_lint.lua failed; the stage is in build/stage for a look")


# ── 5. credits ───────────────────────────────────────────────────────────

def credits(args, version, out_dir):
    strict = (args.demo or args.playtest) and not args.smoke
    dst = os.path.join(STAGE, "CREDITS.txt")
    cmd = [sys.executable, os.path.join(TOOLS, "credits.py"), STAGE, dst, "--version", version]
    if not strict:
        cmd.append("--lenient")
    r = subprocess.run(cmd)
    if r.returncode != 0:
        die("credits.py failed")
    shutil.copyfile(dst, os.path.join(out_dir, "CREDITS.txt"))


# ── 6. the .love ─────────────────────────────────────────────────────────

def zip_tree(out_path, base_dir):
    n = 0
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _, files in os.walk(base_dir):
            for f in sorted(files):
                p = os.path.join(dirpath, f)
                z.write(p, os.path.relpath(p, base_dir).replace(os.sep, "/"))
                n += 1
    return n


# ── 7. web ───────────────────────────────────────────────────────────────

def build_web(love_file, out_dir, title):
    lovejs = next((c for c in LOVEJS_CANDIDATES if os.path.isfile(c)), None)
    if not lovejs:
        die("love.js not found: cd build-tools && npm install")
    web_dir = os.path.join(out_dir, "web")
    if os.path.isdir(web_dir):
        for entry in os.listdir(web_dir):
            p = os.path.join(web_dir, entry)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.remove(p)
    else:
        os.makedirs(web_dir)
    # love.js refuses an initial memory smaller than the package; twice its
    # size (at least 64 MB), in 64 KB pages, with growth still on.
    mem = max(64 << 20, 2 * os.path.getsize(love_file))
    mem = (mem + 0xFFFF) & ~0xFFFF
    r = subprocess.run(["node", lovejs, "-c", "-t", title, "-m", str(mem), love_file, web_dir])
    if r.returncode != 0:
        die("love.js failed")
    shell = read(os.path.join(TOOLS, "index.html"))
    shell = re.sub(r"<title>.*?</title>", f"<title>{title}</title>", shell, count=1)
    write(os.path.join(web_dir, "index.html"), shell)
    icon = os.path.join(ROOT, "assets", "icon.png")
    if os.path.isfile(icon):
        shutil.copyfile(icon, os.path.join(web_dir, "favicon.png"))
    shutil.copyfile(os.path.join(STAGE, "CREDITS.txt"), os.path.join(web_dir, "CREDITS.txt"))
    zip_path = os.path.join(out_dir, f"{SLUG}-web.zip")
    n = zip_tree(zip_path, web_dir)
    log(f"web: {zip_path} ({n} entries)")
    return zip_path


# ── 8. win64 ─────────────────────────────────────────────────────────────

def engine():
    lock_path = os.path.join(TOOLS, "engine.lock")
    if not os.path.isfile(lock_path):
        die("build-tools/engine.lock is missing (docs/build.md: the engine)")
    with open(lock_path, "rb") as f:
        lock = tomllib.load(f)
    z = lock.get("zip", "")
    if not os.path.isfile(z):
        die(f"the engine zip the lock names is not here: {z}")
    got = sha256(z)
    if got != lock.get("sha256"):
        die(f"the engine zip's hash ({got[:12]}…) is not the lock's ({str(lock.get('sha256'))[:12]}…)")
    d = lock.get("dir", "")
    if not os.path.isfile(os.path.join(d, "love.exe")):
        die(f"the unpacked engine the lock names has no love.exe: {d}")
    return d, lock


def build_win64(args, love_file, out_dir, version, title):
    eng, lock = engine()
    dist = os.path.join(out_dir, "win64", SLUG)
    if os.path.isdir(os.path.dirname(dist)):
        shutil.rmtree(os.path.dirname(dist))
    os.makedirs(dist)
    exe = os.path.join(dist, f"{SLUG}.exe")
    with open(exe, "wb") as out, open(os.path.join(eng, "love.exe"), "rb") as a, open(love_file, "rb") as b:
        shutil.copyfileobj(a, out)
        shutil.copyfileobj(b, out)
    dlls = sorted(f for f in os.listdir(eng) if f.lower().endswith(".dll"))
    for need in ENGINE_DLLS_REQUIRED:
        if need not in dlls:
            die(f"the engine has no {need}")
    for f in dlls:
        shutil.copyfile(os.path.join(eng, f), os.path.join(dist, f))
    for f in ("license.txt",):
        if os.path.isfile(os.path.join(eng, f)):
            shutil.copyfile(os.path.join(eng, f), os.path.join(dist, f))
    shutil.copyfile(os.path.join(STAGE, "CREDITS.txt"), os.path.join(dist, "CREDITS.txt"))

    rcedit = os.path.join(TOOLS, "bin", "rcedit-x64.exe")
    ico = os.path.join(ROOT, "assets", "icon.ico")
    if os.path.isfile(rcedit):
        cmd = [rcedit, exe,
               "--set-version-string", "ProductName", title,
               "--set-version-string", "FileDescription", title,
               "--set-version-string", "CompanyName", lock.get("company", ""),
               "--set-version-string", "LegalCopyright", lock.get("copyright", ""),
               "--set-file-version", re.sub(r"[^0-9.]", "", version).strip(".") or "0.0.0",
               "--set-product-version", version]
        if os.path.isfile(ico):
            cmd += ["--set-icon", ico]
        else:
            (log if args.smoke else log)("warning: assets/icon.ico is missing; the exe keeps LÖVE's icon")
        subprocess.run(cmd, check=True)
    else:
        log("warning: build-tools/bin/rcedit-x64.exe is missing; no icon or version info on the exe")
    zip_path = os.path.join(out_dir, f"{SLUG}-win64.zip")
    n = zip_tree(zip_path, os.path.dirname(dist))
    log(f"win64: {zip_path} ({n} entries, engine {lock.get('label', '?')})")
    return zip_path


# ── main ─────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="build the web and win64 targets")
    ap.add_argument("--target", choices=["web", "win64", "all"], default="all")
    ap.add_argument("--demo", action="store_true", help="the demo: Act 1, the rest cut")
    ap.add_argument("--playtest", action="store_true", help="the demo with the hand log on")
    ap.add_argument("--version", help="the build string (default: C.BUILD)")
    ap.add_argument("--allow-dirty", action="store_true")
    ap.add_argument("--smoke", action="store_true", help="a throwaway build: lenient checks")
    ap.add_argument("--skip-tests", action="store_true")
    args = ap.parse_args()
    cfg = config()

    log("1/9 preflight")
    preflight(args)
    log("2/9 stage")
    stage()
    log("3/9 stamp")
    version, title, _ = stamp(args, cfg)
    out_dir = os.path.join(BUILD, version + ("-demo" if args.demo else "-playtest" if args.playtest else ""))
    os.makedirs(out_dir, exist_ok=True)
    if args.demo or args.playtest:
        log("4/9 cut + lint")
        cut_and_lint(args)
    else:
        log("4/9 cut + lint: a dev build, nothing cut")
    log("5/9 credits")
    credits(args, version, out_dir)
    icon = os.path.join(ROOT, "assets", "icon.png")
    if not os.path.isfile(icon):
        log("warning: assets/icon.png is missing; the window keeps LÖVE's icon")
    log("6/9 .love")
    love_file = os.path.join(out_dir, f"{SLUG}.love")
    n = zip_tree(love_file, STAGE)
    log(f"      {love_file} ({n} entries)")
    artefacts = [love_file]
    if args.target in ("web", "all"):
        log("7/9 web")
        artefacts.append(build_web(love_file, out_dir, title))
    if args.target in ("win64", "all"):
        log("8/9 win64")
        artefacts.append(build_win64(args, love_file, out_dir, version, title))
    log("9/9 report")
    lines = [f"{title} {version}" + (" demo" if args.demo else " playtest" if args.playtest else ""), ""]
    for a in artefacts:
        lines.append(f"{os.path.basename(a):<28} {os.path.getsize(a) / 1048576:7.1f} MB  sha256 {sha256(a)}")
    write(os.path.join(out_dir, "BUILD.txt"), "\n".join(lines) + "\n")
    print("\n".join(lines))
    log(f"done: {out_dir}")


if __name__ == "__main__":
    main()
