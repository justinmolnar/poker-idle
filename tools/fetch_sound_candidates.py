"""tools/fetch_sound_candidates.py

Pulls audition candidates for the sounds docs/sound-checklist.md still
lists as missing, from Freesound, into assets/audio/raw/candidates/<slot>/
(the loader skips any folder named `raw`, so nothing here plays), and
writes assets/audio/raw/candidates/CANDIDATES.md with the credits.

Rules, so a candidate is safe to ship as-is:
  - Creative Commons 0 only (public domain: commercial use, no credit
    required; credited anyway in the table).
  - Found on Freesound and credited: an existing upload of any date,
    never a sound generated on request.
  - A duration window per slot (foley short, beds long).
  - Ranked by downloads: what other people kept using.

The file is Freesound's high-quality preview (OGG, ~192 kbps), which is
public; the original upload needs a login. For one-shot game foley the
preview is transparent. Pixabay refuses scripted requests and its API has
no audio, so it is not a source here.

    python tools/fetch_sound_candidates.py            # every slot
    python tools/fetch_sound_candidates.py candle tilt_lands   # some
"""

import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

UA = "Mozilla/5.0 (poker-idle sound audition fetch)"
OUT = os.path.join("assets", "audio", "raw", "candidates")
PER_SLOT = int(os.environ.get("FETCH_PER_SLOT", "3"))
# At most this many full matches from one query (0: no cap), so one broad
# query cannot fill a slot with near-duplicates before the others are asked.
PER_QUERY = int(os.environ.get("FETCH_PER_QUERY", "0"))

# slot, what it is for, live target, (min s, max s), queries in order of preference
SLOTS = [
    # ── items (assets/audio/items/<id>.ogg) ──────────────────────────────
    ("gaming_poster", "a boxing bell: one bright ring-bell strike (any single bell ding that reads as the round bell)", "items/gaming_poster.ogg", (0.3, 6), ["boxing bell", "boxing ring bell", "ring bell ding", "fight bell", "round bell", "bell knockout", "service bell", "desk bell", "school bell single"]),
    ("tally_book", "a pencil scratch, one stroke", "items/tally_book.ogg", (0.1, 2), ["pencil scratch", "pencil writing short"]),
    ("bonsai", "leaves brushed, a snip", "items/bonsai.ogg", (0.1, 2), ["scissors snip", "pruning shears cut", "leaves rustle short"]),
    ("house_cat", "one short meow", "items/house_cat.ogg", (0.2, 2), ["cat meow", "kitten meow"]),
    ("candle", "a match strike, short", "items/candle.ogg", (0.3, 3), ["match strike", "match lighting"]),
    ("trophy_shelf", "a small cup set down on wood", "items/trophy_shelf.ogg", (0.1, 3), ["trophy", "metal cup", "cup set down", "metal object set down", "put down metal"]),
    ("dusty_console", "a quick blow of air, like blowing into a game cartridge or on a mic", "items/dusty_console.ogg", (0.1, 3), ["mic blow", "blowing into microphone", "blow microphone", "blow air", "puff of air", "blowing dust", "blow"]),
    ("handheld", "a handheld's power tone or button click", "items/handheld.ogg", (0.05, 3), ["gameboy", "game boy", "handheld game", "electronic beep short", "power on beep"]),
    ("red_rug", "a rug or carpet: shaken out, flapped, or beaten once", "items/red_rug.ogg", (0.2, 4), ["rug shake", "shaking rug", "carpet beat", "carpet beating", "rug beating", "rug flap", "blanket shake", "shaking blanket", "blanket flap", "fabric shake", "cloth shake", "sheet shake", "carpet thump", "carpet"]),
    ("dish_soap", "a squeeze bottle, short", "items/dish_soap.ogg", (0.1, 2), ["squeeze bottle", "plastic bottle squeeze", "soap squirt"]),
    ("bottle_of_wine", "a cork", "items/bottle_of_wine.ogg", (0.1, 2), ["cork pop", "wine cork"]),
    ("desk_lamp", "a lamp switch, click", "items/desk_lamp.ogg", (0.05, 1), ["lamp switch click", "light switch click"]),
    ("telephone", "a phone: one ring, a ringtone, or keypad / dial tones", "items/telephone.ogg", (0.1, 4), ["telephone ring single", "old phone ring", "phone ring", "phone dial tone", "dtmf", "phone keypad beep", "telephone ring"]),
    ("old_keyboard", "one stuck key", "items/old_keyboard.ogg", (0.05, 1), ["mechanical keyboard single key", "typewriter key single", "keyboard key press"]),
    ("medical_poster", "a body / medical sound: a heartbeat, a heart-monitor beep", "items/medical_poster.ogg", (0.2, 4), ["heartbeat", "heart monitor beep", "ecg beep", "heart monitor", "stethoscope", "pulse beep"]),
    ("hybrid_console", "a game console turning on: startup beeps", "items/hybrid_console.ogg", (0.1, 4), ["console startup", "console power on", "startup sound", "power on beep", "boot up", "startup beep", "power up beep", "electronic startup"]),
    ("washing_machine", "a washing machine running, thumping", "items/washing_machine.ogg", (1, 8), ["washing machine running", "washing machine thump", "washer spin cycle", "washing machine spin", "dryer thump", "laundry machine", "washing machine"]),
    ("floor_plant", "big leaves, brushed", "items/floor_plant.ogg", (0.2, 2.5), ["leaves brush", "plant leaves rustle", "foliage rustle"]),
    ("gas_stove", "an igniter click", "items/gas_stove.ogg", (0.1, 2), ["gas stove igniter", "stove ignition click", "gas lighter click"]),
    ("cast_iron_pan", "a pan set on a burner, clang", "items/cast_iron_pan.ogg", (0.1, 2.5), ["pan on stove", "frying pan set down", "pan clang"]),
    ("hot_bath", "water, a tap run for a second", "items/hot_bath.ogg", (0.5, 3), ["bath tap water", "faucet running short", "tap water"]),
    ("fresh_towel", "a towel snap: a towel whipped so it cracks", "items/fresh_towel.ogg", (0.05, 2), ["towel snap", "towel whip", "wet towel snap", "towel flick", "towel crack", "cloth whip", "fabric snap", "cloth snap", "sheet snap", "whip crack"]),
    ("replay_tv", "tape whir, a deck loading", "items/replay_tv.ogg", (0.3, 4), ["vhs", "vcr", "cassette insert", "tape deck"]),
    ("shower_head", "a shower running, short", "items/shower_head.ogg", (0.5, 6), ["shower turn on", "shower", "shower water"]),
    ("box_of_tissues", "one tissue pulled", "items/box_of_tissues.ogg", (0.1, 1.5), ["tissue pull", "tissue box", "paper tissue"]),
    ("kitchen_bin", "a bin lid", "items/kitchen_bin.ogg", (0.1, 2), ["trash can lid", "pedal bin lid", "bin lid close"]),
    ("cleaning_robot", "a home-gadget sound: a robot vacuum, a servo, a remote-control or sci-fi device beep", "items/cleaning_robot.ogg", (0.2, 4), ["robot vacuum", "roomba", "vacuum cleaner", "robot beep", "servo", "scifi device", "futuristic beep", "rc car", "robot"]),
    # ── the House ───────────────────────────────────────────────────────
    ("house_stinger", "ONE low sustained note left to ring (1.5-4 s), a dramatic sting when the House makes a point", "felt/house_stinger.ogg (wire)", (1.5, 8), ["piano low note", "low piano note", "cello low note", "cello note", "double bass note", "contrabass note", "low organ note", "organ note", "low string note", "deep bell toll", "bell toll"]),
    # ── music beds ──────────────────────────────────────────────────────
    ("music_layer_hiss", "tape hiss / vinyl crackle bed, loopable", "music layer (wire)", (20, 200), ["vinyl crackle loop", "tape hiss", "record crackle"]),
    ("music_gauntlet_drone", "one sustained low tone, pitchable", "music layer (wire)", (3, 60), ["low drone", "sustained low tone", "dark drone"]),
    # ── the shove ───────────────────────────────────────────────────────
    ("paper_thud", "a heavy thud for the book landing on the felt", "felt/paper_thud.ogg", (0.1, 1.5), ["book drop", "book thud", "heavy book table"]),
    ("paper_slap", "a light slap for the pamphlet", "felt/paper_slap.ogg", (0.05, 1), ["paper slap", "paper drop table", "magazine drop"]),
    # ── the grind ───────────────────────────────────────────────────────
    ("table_open", "a UI 'open' sound (ideally one of a matching open/close pair)", "felt/table_open.ogg (wire)", (0.05, 2), ["ui open", "menu open", "interface open", "inventory open", "popup open", "panel open", "ui whoosh"]),
    ("table_close", "a UI 'close' sound, the match to table_open (ideally the same pair)", "felt/table_close.ogg (wire)", (0.05, 2), ["ui close", "menu close modern", "inventory close", "menu close", "interface close", "popup close", "panel close"]),
    ("tilt_lands", "a 'negative' UI sound: an error / wrong-answer / denied beep", "felt/tilt.ogg (wire)", (0.05, 2), ["negative ui", "ui error", "error beep", "wrong answer", "fail ui", "denied beep", "negative feedback", "error sound"]),
    ("heater_lands", "a match strike, short (not the candle's take)", "felt/heater.ogg (wire)", (0.2, 2), ["lighter flick", "zippo lighter", "match ignite"]),
    ("punch", "fist on a table", "felt/punch.ogg (wire)", (0.05, 1), ["fist table", "punch table", "fist bang wood"]),
    ("focus_overload", "a short strained tone", "felt/focus_overload.ogg", (0.3, 2), ["tape slow down", "power down", "strained tone"]),
    ("deck", "one bright note or a card fan", "felt/deck.ogg (wire)", (0.2, 2.5), ["card fan", "cards shuffle", "card riffle", "playing cards"]),
    ("underflow", "a deep thud with a tail", "felt/underflow.ogg (wire)", (0.5, 3), ["deep boom", "sub thud", "low impact boom"]),
    ("glyph_tear", "a tiny digital glitch under the broken money readouts after the Act 3 underflow, very short (pick three)", "felt/glyph_tear_1..3.ogg (wire)", (0.05, 0.5), ["digital glitch short", "glitch", "data corruption", "digital error", "bit crush glitch", "static glitch"]),
    # ── paper and interface ─────────────────────────────────────────────
    ("button_click", "one soft click, the same everywhere", "ui/click.ogg (wire)", (0.02, 0.4), ["soft click ui", "button click soft", "mouse click"]),
    ("modal_open", "a paper or panel slide in", "ui/modal_open.ogg (wire)", (0.1, 1), ["paper slide", "paper swipe", "paper slide table"]),
    ("modal_close", "a paper or panel slide out", "ui/modal_close.ogg (wire)", (0.1, 1), ["paper slide", "paper whoosh", "paper rustle short"]),
    ("page_turn", "two or three page turns", "ui/page_turn.ogg", (0.2, 1.5), ["page turn", "book page flip"]),
    ("stamp", "one rubber stamp thunk", "ui/stamp.ogg (wire)", (0.05, 1), ["rubber stamp", "stamp paper", "stamp thud"]),
    # ── clicks: a surface sound under every click (2026-10-03) ──────────
    ("click_felt", "felt: a soft cloth tap (a table's playing area, the shove felt)", "ui/click_felt.ogg (wire)", (0.02, 1.0), ["cloth tap", "fabric tap", "canvas tap", "finger tap", "soft tap", "cloth hit"]),
    ("click_chrome", "chrome: a hard tick (Settings and other mechanical modals, sidebars, panel headers)", "ui/click_chrome.ogg (wire)", (0.02, 0.6), ["metal tick", "plastic tick", "menu tick", "metal click", "plastic click"]),
    ("click_rail", "rail: a deeper knock, like rapping a desk edge (the bottom bar)", "ui/click_rail.ogg (wire)", (0.03, 0.6), ["knock wood desk", "knock on table", "desk knock", "wood knock"]),
    ("click_empty", "an empty slot: a hollow knock", "ui/click_empty.ogg (wire)", (0.03, 1.0), ["hollow knock", "hollow wood", "box knock", "knock box", "hollow tap", "hollow"]),
    ("click_wall", "the wall and floor: a muffled thump (the background, the room)", "ui/click_wall.ogg (wire)", (0.03, 1.0), ["muffled thump", "soft thud", "thump", "muffled knock", "body thud", "soft impact"]),
    ("click_paper", "paper: a paper tap (the catalog, the pamphlet, the House poster, the story band)", "ui/click_paper.ogg (wire)", (0.02, 1.0), ["paper tap", "paper hit", "paper flick", "flick paper", "cardboard tap", "paper touch"]),
    ("click_denied", "denied: a dull thunk (a button that can't act, e.g. an upgrade you can't afford)", "ui/click_denied.ogg (wire)", (0.03, 1.0), ["dull thud", "wood thunk", "dull knock", "wood thud", "thunk", "error buzz"]),
]


def get(url, tries=3):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001 - retry anything transient
            if k == tries - 1:
                raise
            time.sleep(2 + 2 * k)


ATTR = re.compile(r'data-([a-z-]+)="([^"]*)"')


def search(query, dmin, dmax):
    f = 'license:"Creative Commons 0" duration:[%s TO %s]' % (dmin, dmax)
    url = "https://freesound.org/search/?" + urllib.parse.urlencode(
        {"q": query, "f": f, "s": "Downloads (most first)"})
    page = get(url).decode("utf-8", "replace")
    out = []
    for block in page.split('class="bw-player"')[1:]:
        head = block[:2500]
        a = dict(ATTR.findall(head))
        if "sound-id" not in a or "ogg" not in a:
            continue
        out.append({
            "id": a["sound-id"],
            "user": a.get("username", "?"),
            "title": html.unescape(a.get("title", "?")),
            "duration": float(a.get("duration", "0") or 0),
            "downloads": int(a.get("num-downloads", "0") or 0),
            "ogg": a["ogg"].replace("-lq.ogg", "-hq.ogg"),
        })
    return out


def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:40] or "sound"


def main():
    only = set(sys.argv[1:])
    os.makedirs(OUT, exist_ok=True)
    manifest_path = os.path.join(OUT, "candidates.json")
    manifest = {}
    if os.path.exists(manifest_path):
        manifest = json.load(open(manifest_path, encoding="utf-8"))
    for name, what, target, (dmin, dmax), queries in SLOTS:
        if only and name not in only:
            continue
        # Title relevance first (how many of the query's words the title
        # carries), downloads second: downloads alone ranked a matchbox
        # shake above a match strike. Titles carrying EVERY word of a query
        # are taken across all the queries first; partial matches only fill
        # what is left ("Paper Scrawling" for "paper tap" filled the slot
        # before "paper flick" was ever asked).
        full, partial, seen = [], [], set()
        for q in queries:
            if len(full) >= PER_SLOT:
                break
            try:
                results = search(q, dmin, dmax)
            except Exception as e:  # noqa: BLE001
                print("  search failed", name, q, e)
                continue
            words = [w for w in q.lower().split() if len(w) > 2]
            for r in results:
                t = r["title"].lower()
                r["rel"] = sum(1 for w in words if w.rstrip("s") in t)
                r["query"] = q
            results.sort(key=lambda r: (-r["rel"], -r["downloads"]))
            took = 0
            for r in results:
                if r["rel"] == 0 or r["id"] in seen:
                    continue
                if r["rel"] >= len(words):
                    if PER_QUERY and took >= PER_QUERY:
                        continue
                    took += 1
                    full.append(r)
                else:
                    partial.append(r)
                seen.add(r["id"])
            time.sleep(1.0)
        picked = (full + partial)[:PER_SLOT]
        d = os.path.join(OUT, name)
        os.makedirs(d, exist_ok=True)
        for k, r in enumerate(picked, 1):
            fn = "%d-%s-%s.ogg" % (k, r["id"], slug(r["title"]))
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                try:
                    data = get(r["ogg"])
                    open(path, "wb").write(data)
                except Exception as e:  # noqa: BLE001
                    print("  download failed", name, r["id"], e)
                    continue
                time.sleep(0.5)
            r["file"] = fn
            r["page"] = "https://freesound.org/people/%s/sounds/%s/" % (r["user"], r["id"])
        manifest[name] = {"what": what, "target": target, "candidates": [r for r in picked if "file" in r]}
        print("%-22s %d candidates" % (name, len(manifest[name]["candidates"])))
        json.dump(manifest, open(manifest_path, "w", encoding="utf-8"), indent=1)

    lines = [
        "# Sound candidates",
        "",
        "Audition files for the sounds `docs/sound-checklist.md` lists as missing, fetched by",
        "`tools/fetch_sound_candidates.py` from Freesound. Every file is Creative Commons 0",
        "(public domain, commercial use, no credit required), found on Freesound and",
        "credited, not generated on request. The folder is under `raw/`, so the game",
        "never plays it.",
        "",
        "To use one: copy it to the live target (or say which and it gets trimmed to mono",
        "and placed), and add its row to the folder's MANIFEST.",
        "",
    ]
    for name, what, target, _, _ in SLOTS:
        m = manifest.get(name)
        if not m:
            continue
        lines.append("## `%s` — %s" % (name, what))
        lines.append("")
        lines.append("Target: `%s`" % target)
        lines.append("")
        lines.append("| file | title | by | length | downloads |")
        lines.append("|---|---|---|---|---|")
        for r in m["candidates"]:
            lines.append("| `%s` | [%s](%s) | %s | %.2fs | %d |" % (
                r["file"], r["title"].replace("|", "/"), r["page"], r["user"], r["duration"], r["downloads"]))
        if not m["candidates"]:
            lines.append("| (none found under the rules) | | | | |")
        lines.append("")
    open(os.path.join(OUT, "CANDIDATES.md"), "w", encoding="utf-8").write("\n".join(lines))
    print("wrote", os.path.join(OUT, "CANDIDATES.md"))


if __name__ == "__main__":
    main()
