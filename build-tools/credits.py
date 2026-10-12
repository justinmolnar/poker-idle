#!/usr/bin/env python3
"""
credits.py — write CREDITS.txt for a build: the head (build-tools/
CREDITS.head.txt: the game, the engine, the packs and the art, written by
hand) followed by every sound the asset manifests credit (assets/audio/*/
MANIFEST.md tables, items/manifest.json), as the build ships them.

Coverage: every audio file on the staged tree must be credited — by a
manifest row naming it, or by a `covers: <path prefix>` line in the head
(a pack credited as one). An uncovered file, or a TODO left in the head,
fails the build (a warning with --lenient: a dev or smoke build).

Run: python build-tools/credits.py <stage-dir> <out-file> [--version V] [--lenient]
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEAD = os.path.join(ROOT, "build-tools", "CREDITS.head.txt")
AUDIO_EXT = (".ogg", ".mp3", ".wav", ".flac")


def log(msg):
    print(f"[credits] {msg}")


def parse_tables(md_text):
    """Every markdown table in the text: a list of dict rows keyed by the
    header cells (lowercased)."""
    rows = []
    lines = md_text.splitlines()
    i = 0
    while i < len(lines):
        if lines[i].startswith("|") and i + 1 < len(lines) and re.match(r"^\|[-| :]+\|?$", lines[i + 1]):
            header = [c.strip().lower() for c in lines[i].strip().strip("|").split("|")]
            i += 2
            while i < len(lines) and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if len(cells) == len(header):
                    rows.append(dict(zip(header, cells)))
                i += 1
        else:
            i += 1
    return rows


def strip_md(s):
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)   # [title](url) -> title
    return s.replace("`", "").strip()


def stem(name):
    return os.path.splitext(name)[0].lower()


def manifest_credits():
    """{ (folder, stem): line } from every manifest in the repo. Keyed on
    the stem: a manifest names the download (.mp3), the package ships the
    converted .ogg."""
    out = {}
    audio = os.path.join(ROOT, "assets", "audio")
    for folder in sorted(os.listdir(audio)):
        md = os.path.join(audio, folder, "MANIFEST.md")
        if os.path.isfile(md):
            with open(md, encoding="utf-8") as f:
                rows = parse_tables(f.read())
            for r in rows:
                fname = strip_md(r.get("file", ""))
                if not fname:
                    continue
                title = strip_md(r.get("freesound title") or r.get("original title") or r.get("title") or "")
                author = strip_md(r.get("author") or r.get("artist") or "")
                if "freesound id" in r:
                    src = f"Freesound #{strip_md(r['freesound id'])}, {strip_md(r.get('license') or 'CC0')}"
                elif "pixabay id" in r:
                    src = f"Pixabay #{strip_md(r['pixabay id'])}, Pixabay Content License"
                else:
                    src = ""
                use = strip_md(r.get("used as") or r.get("item") or "")
                line = f"  {fname:<28} {title} — {author}" + (f" ({src})" if src else "")
                if use:
                    line += f"\n{'':30} {use}"
                out[(folder, stem(fname))] = line
        js = os.path.join(audio, folder, "manifest.json")
        if os.path.isfile(js):
            with open(js, encoding="utf-8") as f:
                try:
                    entries = json.load(f)
                except Exception:
                    entries = []
            for e in entries if isinstance(entries, list) else []:
                fname = e.get("file")
                if not fname or (folder, stem(fname)) in out:
                    continue
                src = f"Pixabay #{e.get('pixabay_id', '?')}, Pixabay Content License"
                out[(folder, stem(fname))] = (f"  {fname:<28} {e.get('title', '')} — {e.get('artist', '')} ({src})"
                                        + (f"\n{'':30} {e['name']}" if e.get("name") else ""))
    return out


def shipped_audio(stage):
    out = []
    base = os.path.join(stage, "assets", "audio")
    for dirpath, _, files in os.walk(base):
        for f in files:
            if f.lower().endswith(AUDIO_EXT):
                rel = os.path.relpath(os.path.join(dirpath, f), stage).replace(os.sep, "/")
                out.append(rel)
    return sorted(out)


def run(stage, out_path, version="", lenient=False):
    problems = []
    with open(HEAD, encoding="utf-8") as f:
        head = f.read()
    covers = [l.split(":", 1)[1].strip() for l in head.splitlines() if l.strip().lower().startswith("covers:")]
    head_text = "\n".join(l for l in head.splitlines() if not l.strip().lower().startswith("covers:"))
    if "TODO" in head_text:
        problems.append("CREDITS.head.txt still has a TODO")

    credits = manifest_credits()
    shipped = shipped_audio(stage)
    by_folder = {}
    for rel in shipped:
        parts = rel.split("/")
        folder = parts[2] if len(parts) > 3 else ""
        fname = parts[-1]
        if (folder, stem(fname)) in credits:
            by_folder.setdefault(folder, []).append(credits[(folder, stem(fname))])
        elif any(rel.startswith(c) for c in covers):
            pass
        else:
            problems.append(f"no credit for {rel}")

    lines = [f"{head_text.strip()}", ""]
    if version:
        lines.insert(1, f"build {version}")
    lines.append("SOUNDS, BY FOLDER")
    for folder in sorted(by_folder):
        lines.append("")
        lines.append(folder.upper())
        lines.extend(by_folder[folder])
    text = "\n".join(lines).rstrip() + "\n"
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    log(f"wrote {out_path} ({sum(len(v) for v in by_folder.values())} credited sounds, {len(shipped)} shipped)")
    for p in problems:
        log(("warning: " if lenient else "ERROR: ") + p)
    if problems and not lenient:
        sys.exit("[credits] attribution is incomplete; fix build-tools/CREDITS.head.txt or the manifests")
    return text


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        sys.exit(__doc__)
    version = ""
    if "--version" in sys.argv:
        version = sys.argv[sys.argv.index("--version") + 1]
    run(args[0], args[1], version=version, lenient="--lenient" in sys.argv)
