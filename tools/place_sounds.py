"""tools/place_sounds.py

Processes the sounds picked in the audition (tools/audition_sounds.py,
assets/audio/raw/candidates/picks.json) into their live names, once each:

  1. source: the un-levelled original from the audio backup (one encode, not
     two), else the candidate file
  2. crop: to the start/end saved in the audition, sample-accurate
  3. trim: only true silence (below -60 dB) at the head and the tail; a decay
     tail is louder than that and survives
  4. fades: 3 ms in, out min(25 ms, 15% of the length); none on a loop
  5. level: the smaller of the gain to the item sounds' median peak and to
     their median mean (tools/normalize_candidates.py's rule), then a -1 dBFS
     limiter
  6. loops: the drone is made seamless with a tail-into-head crossfade
  7. encode: mono 44.1 kHz OGG Vorbis q6

and credits every file in its folder's MANIFEST.md (items also in
manifest.json). Slots marked "none" or undecided are skipped. A live file
that already exists is left alone unless --force.

    python tools/place_sounds.py            # place everything decided
    python tools/place_sounds.py --dry      # print the plan, write nothing
    python tools/place_sounds.py --force    # overwrite live files
"""

import datetime
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AUDIO = os.path.join(ROOT, "assets", "audio")
CAND = os.path.join(AUDIO, "raw", "candidates")
BACKUP = os.path.join(os.path.dirname(ROOT), "poker-idle-audio-backup-2026-10-03")
TODAY = datetime.date.today().isoformat()

# slot -> (live path under assets/audio, what it is, loop crossfade seconds or None)
# Items are added below from their slot name.
LIVE = {
    "paper_thud":           ("felt/catalog_thud.ogg",  "the book landing on the felt", None),
    "paper_slap":           ("felt/flyer_slap.ogg",    "the pamphlet landing on the felt", None),
    "focus_overload":       ("felt/focus_overload.ogg", "the board going over the focus cap", None),
    "heater_lands":         ("felt/heater_lands.ogg",  "a heater appearing on a table", None),
    "punch":                ("felt/punch.ogg",         "a slam's fist landing; a shove, quieter", None),
    "deck":                 ("felt/deck_up.ogg",       "a deck levelling up or unlocking", None),
    "underflow":            ("felt/underflow.ogg",     "the Act 3 underflow", None),
    "button_click":         ("ui/button_click.ogg",    "every button press; the cursors, quieter", None),
    "modal_open":           ("ui/modal_open.ogg",      "a modal or the book opening", None),
    "modal_close":          ("ui/modal_close.ogg",     "a modal or the book closing", None),
    "page_turn":            ("ui/page_turn.ogg",       "a catalog page turning", None),
    "stamp":                ("ui/stamp.ogg",           "ORDERED stamped on a bought item", None),
    "click_felt":           ("ui/click_felt.ogg",      "a click on felt (a table's playing area, the shove felt)", None),
    "click_chrome":         ("ui/click_chrome.ogg",    "a click on chrome (Settings and other mechanical modals, sidebars, panel headers)", None),
    "click_rail":           ("ui/click_rail.ogg",      "a click on the rail (the bottom bar)", None),
    "click_empty":          ("ui/click_empty.ogg",     "a click on an empty slot", None),
    "click_wall":           ("ui/click_wall.ogg",      "a click on the wall or floor (the background, the room)", None),
    "click_paper":          ("ui/click_paper.ogg",     "a click on paper (the catalog, the pamphlet, the House poster, the story band)", None),
    "click_denied":         ("ui/click_denied.ogg",    "a button that can't act", None),
    "house_stinger":        ("felt/house_stinger.ogg", "the House making a point: the first cheat card, the Act 2 lede, the underflow, the deck running out", None),
    "table_open":           ("ui/table_open.ogg",      "a table opening", None),
    "table_close":          ("ui/table_close.ogg",     "a table closing or cashing out", None),
    "tilt_lands":           ("felt/tilt_lands.ogg",    "a tilt appearing on a table", None),
    "music_layer_hiss":     ("layers/hiss.ogg",        "the Act 3 vinyl bed, louder after the underflow", "whole"),
    "music_gauntlet_drone": ("layers/gauntlet_drone.ogg", "the gauntlet's drone, up a step per runout", 1.5),
}
ITEMS_DIR = "items"
# Slots that take several files, picked as candidate numbers in the slot's
# note ("1, 2, 4"): slot -> (live path with a %d for 1..n, what).
MULTI = {
    "glyph_tear": ("felt/glyph_tear_%d.ogg", "the broken readouts' glitch after the underflow (one of three, now and then)"),
}
# Silence is trimmed relative to the sound's own peak: an absolute -60 dB
# floor ate a whole recording that peaked at -44 dB before levelling.
TRIM_BELOW_PEAK = 55
FFMPEG = "ffmpeg"


def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("ffmpeg failed: %s\n%s" % (" ".join(args[:6]), r.stderr[-600:]))
    return r.stderr


def levels(path, af=None):
    chain = "volumedetect" if not af else af + ",volumedetect"
    out = run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-ac", "1", "-af", chain, "-f", "null", "-"])
    mean = re.search(r"mean_volume: (-?[\d.]+)", out)
    peak = re.search(r"max_volume: (-?[\d.]+)", out)
    if not (mean and peak):
        return -91.0, -91.0
    return float(mean.group(1)), float(peak.group(1))


def duration(path):
    # Counted from the decoded samples: ffprobe reports N/A for some WAVs.
    out = run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-ac", "1", "-af", "volumedetect", "-f", "null", "-"])
    # volumedetect prints n_samples twice; the first is always 0.
    ns = [int(x) for x in re.findall(r"n_samples: (\d+)", out)]
    sr = re.search(r"(\d+) Hz", out)
    n = max(ns) if ns else 0
    if not (n and sr):
        raise RuntimeError("no samples decoded from " + path)
    return n / int(sr.group(1))


def trim_chain(peak):
    sr = "silenceremove=start_periods=1:start_threshold=%.1fdB:start_silence=0.005" % (peak - TRIM_BELOW_PEAK)
    return [sr, "areverse", sr, "areverse"]


def target():
    """The item sounds' median mean and peak, measured on their sounding part
    (silence trimmed the way a pick is), so a tight crop is compared with the
    items like for like, not against their silent padding."""
    items = os.path.join(AUDIO, ITEMS_DIR)
    ref = []
    for f in sorted(os.listdir(items)):
        if f.endswith(".ogg"):
            path = os.path.join(items, f)
            _, peak = levels(path)
            ref.append(levels(path, ",".join(trim_chain(peak))))
    return statistics.median(r[0] for r in ref), statistics.median(r[1] for r in ref)


def item_ids():
    """The catalog's item ids, read off data/catalog.lua without running Lua."""
    src = open(os.path.join(ROOT, "data", "catalog.lua"), encoding="utf-8").read()
    return set(re.findall(r'\bid\s*=\s*"([a-z0-9_]+)"', src))


def process(src, dst, crop, loop, t_mean, t_peak):
    tmp = tempfile.mkdtemp(prefix="place-")
    a = os.path.join(tmp, "a.wav")
    # Crop and trim to a mono WAV first, so the fades and the gain are worked
    # out on what will actually play.
    chain = []
    if crop:
        chain.append("atrim=start=%.4f:end=%.4f" % (crop["start"], crop["end"]))
        chain.append("asetpts=PTS-STARTPTS")
    if loop is None:
        _, crop_peak = levels(src, ",".join(chain) if chain else None)
        chain += trim_chain(crop_peak)
    af = ",".join(chain) if chain else "anull"
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-ac", "1", "-ar", "44100",
         "-af", af, "-c:a", "pcm_s16le", a])

    if isinstance(loop, (int, float)) and not isinstance(loop, bool):
        # Tail-into-head crossfade: the last X seconds faded out over the
        # first X faded in, then the middle. The wrap from the end of the
        # middle to the start of the mix is the original's own continuity.
        L, X = duration(a), float(loop)
        b = os.path.join(tmp, "b.wav")
        fc = ("[0]asplit=3[s1][s2][s3];"
              "[s1]atrim=start=%.4f:end=%.4f,asetpts=PTS-STARTPTS,afade=t=out:d=%.4f:curve=qsin[t];"
              "[s2]atrim=start=0:end=%.4f,asetpts=PTS-STARTPTS,afade=t=in:d=%.4f:curve=qsin[h];"
              "[t][h]amix=inputs=2:normalize=0[x];"
              "[s3]atrim=start=%.4f:end=%.4f,asetpts=PTS-STARTPTS[m];"
              "[x][m]concat=n=2:v=0:a=1[o]") % (L - X, L, X, X, X, X, L - X)
        run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", a, "-filter_complex", fc,
             "-map", "[o]", "-c:a", "pcm_s16le", b])
        a = b

    length = duration(a)
    mean, peak = levels(a)
    gain = min(t_peak - peak, t_mean - mean)
    chain = ["volume=%.2fdB" % gain]
    if loop is None:
        fade_out = max(0.001, min(0.025, 0.15 * length))
        chain.append("afade=t=in:d=0.003")
        chain.append("afade=t=out:st=%.4f:d=%.4f" % (max(0.0, length - fade_out), fade_out))
    # -1 dBFS ceiling; level=0 keeps the limiter from auto-raising the output,
    # latency=1 keeps its lookahead from delaying the attack.
    chain.append("alimiter=limit=0.891:level=0:latency=1")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", a, "-ac", "1", "-ar", "44100",
         "-af", ",".join(chain), "-c:a", "libvorbis", "-q:a", "6", dst])
    out_mean, out_peak = levels(dst)
    return {"length": round(duration(dst), 3), "gain_db": round(gain, 1),
            "before": {"mean": mean, "peak": peak}, "after": {"mean": out_mean, "peak": out_peak}}


def credit_row(slot, c, crop, live_name, what):
    crop_s = ("%.2f–%.2fs" % (crop["start"], crop["end"])) if crop else "whole"
    return "| `%s` | %s | [%s](%s) | %s | %s | %s | CC0 |" % (
        live_name, what, c["title"].replace("|", "/"), c["page"], c["user"], c["id"], crop_s)


def write_manifests(placed):
    by_dir = {}
    for p in placed:
        by_dir.setdefault(p["dir"], []).append(p)
    head = ("| file | used as | Freesound title | author | Freesound id | crop | license |\n"
            "|---|---|---|---|---|---|---|")
    for d, rows in by_dir.items():
        path = os.path.join(AUDIO, d, "MANIFEST.md")
        section = ("## Freesound (CC0), added %s\n\n"
                   "Picked in the audition (`tools/audition_sounds.py`) and processed by `tools/place_sounds.py`: "
                   "cropped, trimmed of silence (%d dB under its own peak), faded, levelled to the item sounds, mono 44.1 kHz OGG. "
                   "Creative Commons 0 (public domain, commercial use, no attribution required; credited anyway). "
                   "Found on Freesound and credited below.\n\n%s\n%s\n"
                   % (TODAY, TRIM_BELOW_PEAK, head, "\n".join(r["row"] for r in rows)))
        if os.path.exists(path):
            text = open(path, encoding="utf-8").read()
            marker = "## Freesound (CC0), added %s" % TODAY
            if marker in text:
                text = text[:text.index(marker)].rstrip() + "\n"
            text = text.rstrip() + "\n\n" + section
        else:
            title = {"felt": "Felt and grind sounds", "ui": "Interface sounds", "layers": "Music beds"}.get(d, d)
            intro = "# %s: manifest and attribution\n\n" % title
            if d == "felt":
                intro += ("`card_degraded_1..3.ogg` are rendered in-house from the uVegas pack's card deal "
                          "(build-tools/render_felt_sounds.py).\n\n")
            if d == "layers":
                intro += ("Looping beds under the music, played by `services/MusicLayers.lua`. Not in `music/`: the "
                          "director plays every file there as a track.\n\n")
            text = intro + section
        open(path, "w", encoding="utf-8", newline="\n").write(text)

    items = [p for p in placed if p["dir"] == ITEMS_DIR]
    if items:
        mpath = os.path.join(AUDIO, ITEMS_DIR, "manifest.json")
        data = json.load(open(mpath, encoding="utf-8"))
        ids = {p["slot"] for p in items}
        data = [e for e in data if not (e.get("source") == "freesound" and e.get("id") in ids)]
        for p in items:
            c = p["cand"]
            data.append({"id": p["slot"], "file": os.path.basename(p["live"]), "source": "freesound",
                         "license": "CC0", "freesound_id": c["id"], "artist": c["user"], "title": c["title"],
                         "page": c["page"], "original_file": c["file"], "crop": p["crop"],
                         "processed": TODAY})
        json.dump(data, open(mpath, "w", encoding="utf-8", newline="\n"), indent=2, ensure_ascii=False)


def main():
    dry, force = "--dry" in sys.argv, "--force" in sys.argv
    picks = json.load(open(os.path.join(CAND, "picks.json"), encoding="utf-8"))
    cands = json.load(open(os.path.join(CAND, "candidates.json"), encoding="utf-8"))
    ids = item_ids()
    t_mean, t_peak = target()
    print("level target from the item sounds: mean %.1f dB, peak %.1f dB" % (t_mean, t_peak))
    placed = []
    # Expand the multi-file slots into one job per numbered candidate.
    jobs = []
    for slot, s in sorted(picks.get("slots", {}).items()):
        if slot in MULTI and slot in cands:
            nums = [int(n) for n in re.findall(r"\d+", s.get("note") or "")]
            by_num = {int(c["file"].split("-", 1)[0]): c["file"] for c in cands[slot]["candidates"]}
            for i, n in enumerate([n for n in nums if n in by_num], 1):
                jobs.append((slot, by_num[n], MULTI[slot][0] % i, MULTI[slot][1]))
        else:
            jobs.append((slot, s.get("choice"), None, None))
    for slot, choice, multi_live, multi_what in jobs:
        if not choice or choice == "none":
            continue
        if multi_live:
            live, what, loop = multi_live, multi_what, None
        elif slot in LIVE:
            live, what, loop = LIVE[slot]
        elif slot in ids:
            live, what, loop = "%s/%s.ogg" % (ITEMS_DIR, slot), cands[slot]["what"], None
        else:
            print("  SKIP %s: no live name" % slot)
            continue
        c = next((x for x in cands[slot]["candidates"] if x["file"] == choice), None)
        if not c:
            print("  SKIP %s: %s is not among its candidates" % (slot, choice))
            continue
        crop = (picks.get("crops", {}).get(slot) or {}).get(choice)
        src = os.path.join(BACKUP, "raw", "candidates", slot, choice)
        if not os.path.exists(src):
            src = os.path.join(CAND, slot, choice)
        dst = os.path.join(AUDIO, *live.split("/"))
        entry = {"slot": slot, "live": live, "dir": live.split("/")[0], "cand": c, "crop": crop,
                 "row": credit_row(slot, c, crop, os.path.basename(live), what)}
        if os.path.exists(dst) and not force:
            print("  KEEP %-22s %s exists (use --force)" % (slot, live))
            placed.append(entry)
            continue
        if dry:
            print("  would place %-22s -> %-28s crop %s" % (slot, live, crop))
            continue
        r = process(src, dst, crop, loop, t_mean, t_peak)
        entry["result"] = r
        placed.append(entry)
        print("  %-22s -> %-28s %6.3fs  gain %+5.1f  peak %6.1f -> %5.1f  mean %6.1f -> %6.1f" % (
            slot, live, r["length"], r["gain_db"], r["before"]["peak"], r["after"]["peak"],
            r["before"]["mean"], r["after"]["mean"]))
    if not dry:
        write_manifests(placed)
        print("credited %d files" % len(placed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
