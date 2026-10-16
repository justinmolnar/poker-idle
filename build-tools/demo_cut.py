#!/usr/bin/env python3
"""
demo_cut.py — cut the full game's Act 2+ content out of a STAGED copy of the
source. build.py runs it on build/stage for --demo and --playtest builds and
then runs demo_lint.lua over what is left. The repo is never touched.

One mechanism: remove an entry from a Lua table by rule. The scanner walks a
file's braces and knows Lua strings and comments, so an entry is the whole
`{ ... }` (or `name = { ... }`) that opens at a given indent, however many
lines it spans, plus the comment lines directly above it. MANIFEST (bottom)
says, per file, which entries go:

  data/catalog.lua        an Act 2 card becomes a STUB — its id, name, art,
                          flavour, price and place, `act = 2` and
                          `demo_locked = true`, nothing else: the book keeps
                          the card under a FULL GAME sticker, the demo ships
                          none of what it does; a retired Act 2 card and an
                          Act 3 card (requires_act3) go
  data/stakes.lua         everything above KEEP_STAKES
  data/story.lua          CUT_BEATS
  data/catalog_pages.lua  cut item ids out of every department; a
                          department left empty goes
  data/decks.lua          every deck but the starter
  data/room_layout.lua    entries keyed by a cut item
  data/room_lights.lua    emitters keyed by a cut item
  data/procs.lua          procs nothing in the staged tree names

What STAYS, on purpose — the demo shows the player what it does not have:
every full-game card's place in the book (the stubs above), the 6-MAX and
TOURNAMENTS keys on the strip (data/game_types.lua and pot_tiers.lua keep
ko and six_max; their gates never open in the demo), the Prize Vase's
"???" card (its mystery is the R1 win the demo never records), and the
glossary's "???" rows for 6-Max, tournaments, knockouts and decks (their
beats are cut, so they are never taught).
  assets/sprites/aliases.json   aliases of cut items
  data/run_upgrades.lua   every derived ladder (fill_scaled, maxes_at) is
                          priced on the FULL data first and written in as
                          `costs` + `max_level`, so the demo prices exactly
                          as the full game's Act 1 (UpgradePricing leaves a
                          priced upgrade alone)
  CUT_MODULES             dev tooling and the ending, required lazily behind
                          their flags in the code

Run: python build-tools/demo_cut.py <stage-dir>
"""

import json
import os
import re
import subprocess
import sys

CUT_IDS      = set()
KEEP_STAKES  = {"s001", "s002", "s003"}
CUT_BEATS    = {"six_max_open", "first_tournament", "act2", "act2_decks",
                "the_top_table", "underflow"}
KEEP_DECKS   = {"standard"}
CUT_MODULES  = ["views/RoomLayersPanel.lua", "views/ShoveDebugOverlay.lua",
                "services/Profiler.lua", "controllers/InputController.lua",
                "states/CreditsState.lua",
                "controllers/BeatBrowser.lua", "controllers/beat_stages.lua",
                "views/RoomEditorSpace.lua"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PRICE_LUA = r"""
package.path = STAGE .. "/?.lua;" .. ROOT .. "/?.lua;" .. package.path
require("sim.love_stub").base()
local RunUpgrades = require("data.run_upgrades")
local reg = require("services.EffectsRegistry"):new()
require("models.poker_effects").registerAll(reg)
require("models.UpgradePricing").apply(RunUpgrades, reg)
for _, u in ipairs(RunUpgrades) do
    if u.costs and #u.costs > 0 then
        io.write(u.id, " ", tostring(u.max_level or #u.costs))
        for _, c in ipairs(u.costs) do io.write(" ", string.format("%.17g", c)) end
        io.write("\n")
    end
end
"""


def log(msg):
    print(f"[demo_cut] {msg}")


# ── The scanner ──────────────────────────────────────────────────────────

def _skip_string(text, i):
    q = text[i]
    i += 1
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == q:
            return i + 1
        i += 1
    return i


def _long_bracket_end(text, i):
    """text[i] == '['. The index past a long bracket [=*[ ... ]=*], or None."""
    m = re.match(r"\[(=*)\[", text[i:])
    if not m:
        return None
    close = "]" + m.group(1) + "]"
    j = text.find(close, i + len(m.group(0)))
    return len(text) if j < 0 else j + len(close)


def match_brace(text, i):
    """text[i] == '{'. The index just past its matching '}'."""
    depth = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "-" and text.startswith("--", i):
            if text.startswith("--[", i):
                e = _long_bracket_end(text, i + 2)
                if e:
                    i = e
                    continue
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in "\"'":
            i = _skip_string(text, i)
            continue
        if c == "[":
            e = _long_bracket_end(text, i)
            if e:
                i = e
                continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced braces")


ENTRY_RE = re.compile(r'^( *)((?:local\s+)?(?:\[\s*"[^"]*"\s*\]|[\w.]+)\s*=\s*)?\{', re.M)


def entries(text, indent):
    """Every entry whose opening line sits at exactly `indent` spaces:
    (start, end, key, body). start takes in the comment lines directly
    above the entry at the same indent; end is past the closing line."""
    out = []
    pos = 0
    while True:
        m = ENTRY_RE.search(text, pos)
        if not m:
            break
        if len(m.group(1)) != indent:
            pos = m.end()
            continue
        open_i = m.end() - 1
        close_i = match_brace(text, open_i)
        eol = text.find("\n", close_i)
        end = len(text) if eol < 0 else eol + 1
        start = m.start()
        while start > 0:
            prev = text.rfind("\n", 0, start - 1) + 1
            if re.match(r"^ {%d}--" % indent, text[prev:start]):
                start = prev
            else:
                break
        key = m.group(2)
        if key:
            key = re.sub(r"^local\s+", "", key).rstrip("= \t").strip()
            key = key.strip("[]").strip().strip('"')
        out.append((start, end, key, text[m.start():end]))
        pos = end
    return out


def field(body, name):
    m = re.search(r'^\s*%s\s*=\s*"([^"]+)"' % re.escape(name), body, re.M)
    return m.group(1) if m else None


def inline_field(body, name):
    """A field anywhere in the body (a department's `{ id = "x", ...` line)."""
    m = re.search(r'\b%s\s*=\s*"([^"]+)"' % re.escape(name), body)
    return m.group(1) if m else None


def prune_homes(text, cut_ids):
    """In a room layout, drop every `homes` entry that sits on a cut item;
    a `homes` left empty goes with its comma."""
    out, pos, n = [], 0, 0
    while True:
        m = re.search(r",?\s*homes\s*=\s*\{", text[pos:])
        if not m:
            break
        open_i = pos + m.end() - 1
        close_i = match_brace(text, open_i)
        inner = text[open_i + 1:close_i - 1]
        kept, i = [], 0
        while True:
            j = inner.find("{", i)
            if j < 0:
                break
            k = match_brace(inner, j)
            entry = inner[j:k]
            if inline_field(entry, "on") in cut_ids:
                n += 1
            else:
                kept.append(entry)
            i = k
        out.append(text[pos:pos + m.start()])
        if kept:
            out.append(", homes = { " + ", ".join(kept) + " }")
        pos = close_i
    out.append(text[pos:])
    return "".join(out), n


def cut_entries(path, indent, rule, label):
    """Remove every entry at `indent` for which rule(key, body) is true;
    a rule returning a string REPLACES the entry with that text instead.
    Returns the removed entries' keys/ids."""
    text = read(path)
    gone = []
    for start, end, key, body in reversed(entries(text, indent)):
        r = rule(key, body)
        if isinstance(r, str):
            text = text[:start] + r + text[end:]
        elif r:
            gone.append(key or field(body, "id") or inline_field(body, "id") or "?")
            text = text[:start] + text[end:]
    text = re.sub(r"\n{3,}", "\n\n", text)
    write(path, text)
    gone.reverse()
    log(f"{label}: cut {len(gone)}" + (f" ({', '.join(gone)})" if gone else ""))
    return gone


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


STUB_FIELDS = ("name", "sprite", "description", "phase", "cost_chip", "authored_cost_chip")


def stub_entry(body):
    """A full-game card's stub: the fields the book needs to print its
    place, and nothing it does. Raw field text is kept as written."""
    lines = []
    iid = field(body, "id")
    lines.append(f'        id          = "{iid}",')
    for name in STUB_FIELDS:
        m = re.search(r'^\s*%s\s*=\s*("(?:[^"\\]|\\.)*"|[^,\n]+)' % name, body, re.M)
        if m:
            lines.append(f"        {name:<11} = {m.group(1).strip()},")
    m = re.search(r"^\s*position\s*=\s*(\{[^}]*\})", body, re.M)
    if m:
        lines.append(f"        position    = {m.group(1)},")
    lines.append("        act         = 2,")
    lines.append("        demo_locked = true,   -- the demo's stub: the card's place, under a FULL GAME sticker (demo_cut.py)")
    return "    {\n" + "\n".join(lines) + "\n    },\n"


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def replace_once(path, old, new, label):
    text = read(path)
    if text.count(old) != 1:
        sys.exit(f"[demo_cut] {label}: expected exactly one match in {path}")
    write(path, text.replace(old, new, 1))


# ── The manifest ─────────────────────────────────────────────────────────

def run(stage):
    stage = os.path.abspath(stage)
    data = lambda name: os.path.join(stage, "data", name)

    # 0. The run upgrades' ladders, priced on the FULL data and written
    #    into the staged file before any of it leaves.
    lua_src = PRICE_LUA.replace("STAGE", repr(stage.replace("\\", "/"))).replace("ROOT", repr(ROOT.replace("\\", "/")))
    try:
        out = subprocess.run(["lua", "-e", lua_src], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(f"[demo_cut] pricing the run upgrades failed:\n{e.stderr}")
    priced = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and not line.startswith("SaveService"):
            priced[parts[0]] = (parts[1], parts[2:])
    rp = data("run_upgrades.lua")
    text = read(rp)
    n_priced = 0
    for start, end, key, body in reversed(entries(text, 4)):
        uid = field(body, "id")
        if uid not in priced:
            continue
        max_level, costs = priced[uid]
        costs_line = "        costs       = { " + ", ".join(costs) + " },   -- the full game's ladder (demo_cut.py)\n"
        new = body
        if re.search(r"^\s*fill_scaled\s*=\s*true", new, re.M):
            new = re.sub(r"^(\s*)max_level\s*=\s*nil,[^\n]*\n", lambda m: f"{m.group(1)}max_level   = {max_level},\n", new, count=1, flags=re.M)
            new = re.sub(r"^(\s*fill_scaled\s*=\s*true,[^\n]*\n)", lambda m: m.group(1) + costs_line, new, count=1, flags=re.M)
        elif re.search(r'^\s*maxes_at\s*=\s*"', new, re.M):
            new = re.sub(r'^\s*maxes_at\s*=\s*"[^"]*",[^\n]*\n', costs_line, new, count=1, flags=re.M)
        else:
            continue
        text = text[:start] + text[start:end].replace(body, new, 1) + text[end:]
        n_priced += 1
    write(rp, text)
    log(f"run_upgrades: wrote {n_priced} priced ladders")

    # 1. The catalog: an Act 2 card becomes its stub; a retired one and an
    #    Act 3 card go. `cut_ids` is everything that no longer works
    #    (stubs included: nothing can own them); `gone_ids` what left the
    #    book, for the pages and the art.
    cut_ids, gone_ids, stub_ids = set(CUT_IDS), set(CUT_IDS), set()

    def catalog_rule(key, body):
        iid = field(body, "id")
        if iid is None:
            return False
        act2 = re.search(r"^\s*act\s*=\s*2\b", body, re.M) is not None
        act3 = re.search(r"^\s*requires_act3\b", body, re.M) is not None
        retired = re.search(r"^\s*retired\s*=\s*true", body, re.M) is not None
        if iid in CUT_IDS or act3 or (act2 and retired):
            cut_ids.add(iid); gone_ids.add(iid)
            return True
        if act2:
            cut_ids.add(iid); stub_ids.add(iid)
            return stub_entry(body)
        return False
    cut_entries(data("catalog.lua"), 4, catalog_rule, "catalog")
    log(f"catalog: {len(stub_ids)} stubs ({', '.join(sorted(stub_ids))})")

    # 2. Stakes.
    cut_stakes = set(cut_entries(data("stakes.lua"), 4,
                                 lambda k, b: field(b, "id") is not None and field(b, "id") not in KEEP_STAKES,
                                 "stakes"))

    # 3. Story beats.
    cut_entries(data("story.lua"), 8, lambda k, b: field(b, "id") in CUT_BEATS, "story")

    # 6. Catalog pages: the gone items out of every department, then the
    #    empties (a stub keeps its place).
    text = read(data("catalog_pages.lua"))
    for iid in sorted(gone_ids):
        text = re.sub(r'"%s",?[ \t]*' % re.escape(iid), "", text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    write(data("catalog_pages.lua"), text)
    cut_entries(data("catalog_pages.lua"), 4,
                lambda k, b: inline_field(b, "id") is not None and re.search(r"items\s*=\s*\{\s*\}", b) is not None,
                "catalog_pages (empty departments)")

    # 7. Decks: the starter stays (the default deck; the system is off).
    cut_entries(data("decks.lua"), 4,
                lambda k, b: field(b, "id") is not None and field(b, "id") not in KEEP_DECKS, "decks")

    # 8. The room: entries and emitters keyed by a cut item.
    cut_entries(data("room_layout.lua"), 4, lambda k, b: k in cut_ids, "room_layout")
    text, n_homes = prune_homes(read(data("room_layout.lua")), cut_ids)
    write(data("room_layout.lua"), text)
    log(f"room_layout: dropped {n_homes} home(s) on cut items")
    cut_entries(data("room_lights.lua"), 8, lambda k, b: k in cut_ids, "room_lights")

    # 10. The modules: dev tooling and the ending.
    for rel in CUT_MODULES:
        p = os.path.join(stage, rel)
        if os.path.isfile(p):
            os.remove(p)
    log(f"modules: removed {len(CUT_MODULES)}")

    # 11. Procs nothing left in the tree names.
    named = set()
    for dirpath, _, files in os.walk(stage):
        for f in files:
            if not f.endswith(".lua"):
                continue
            p = os.path.join(dirpath, f)
            if os.path.relpath(p, stage).replace(os.sep, "/") == "data/procs.lua":
                continue
            named |= set(re.findall(r'"([a-z0-9_]+)"', read(p)))
    cut_entries(data("procs.lua"), 4, lambda k, b: k is not None and k not in named, "procs")

    # 12. Sprite aliases of cut items.
    ap = os.path.join(stage, "assets", "sprites", "aliases.json")
    if os.path.isfile(ap):
        with open(ap, encoding="utf-8") as f:
            aliases = json.load(f)
        before = len(aliases.get("aliases", {}))
        aliases["aliases"] = {k: v for k, v in aliases.get("aliases", {}).items() if k not in gone_ids}
        with open(ap, "w", encoding="utf-8", newline="\n") as f:
            json.dump(aliases, f, indent=2, ensure_ascii=False)
            f.write("\n")
        log(f"aliases: cut {before - len(aliases['aliases'])}")

    log(f"done: {len(stub_ids)} catalog stubs, {len(gone_ids)} catalog items gone, {len(cut_stakes)} stakes, "
        f"{len(CUT_BEATS)} beats; the stubs, the locked keys, the ??? card and the ??? glossary rows stay")
    return sorted(cut_ids)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    run(sys.argv[1])
