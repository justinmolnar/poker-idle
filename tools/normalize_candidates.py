"""tools/normalize_candidates.py

Levels every audition candidate in assets/audio/raw/candidates/ to the
game's own item sounds, in place, as mono 44.1 kHz OGG (the checklist's
format). Back the folder up first; this overwrites.

The target is read off assets/audio/items/*.ogg, which are peak-normalized
(tops near -1 dBFS) with their average level wherever the recording put
it. So each candidate gets the smaller of two gains:
  - the gain that puts its peak at the items' median peak, and
  - the gain that puts its mean level at the items' median mean.
A sparse click is peak-limited (matched like the items); a dense sound
(a hiss bed, a running tap) is mean-limited, so it does not come out far
louder than everything around it. Integrated LUFS is not used: most of
these are shorter than its 400 ms gate and read as silence.

Each candidate's before and after levels are written into candidates.json
(`level`), which the audition page shows.

    python tools/normalize_candidates.py
"""

import json
import os
import re
import statistics
import subprocess
import sys

CAND = os.path.join("assets", "audio", "raw", "candidates")
ITEMS = os.path.join("assets", "audio", "items")


def levels(path):
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-ac", "1", "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    mean = re.search(r"mean_volume: (-?[\d.]+)", out)
    peak = re.search(r"max_volume: (-?[\d.]+)", out)
    if not (mean and peak):
        return None
    return float(mean.group(1)), float(peak.group(1))


def main():
    ref = [levels(os.path.join(ITEMS, f)) for f in sorted(os.listdir(ITEMS)) if f.endswith(".ogg")]
    ref = [r for r in ref if r]
    t_mean = statistics.median(r[0] for r in ref)
    t_peak = statistics.median(r[1] for r in ref)
    print("target from %d item sounds: mean %.1f dB, peak %.1f dB" % (len(ref), t_mean, t_peak))

    mpath = os.path.join(CAND, "candidates.json")
    manifest = json.load(open(mpath, encoding="utf-8"))
    for slot, m in manifest.items():
        for c in m["candidates"]:
            path = os.path.join(CAND, slot, c["file"])
            if not os.path.exists(path):
                continue
            if c.get("level", {}).get("done"):
                continue  # already levelled; never stack gain twice
            lv = levels(path)
            if not lv:
                print("  unreadable", path)
                continue
            mean, peak = lv
            gain = min(t_peak - peak, t_mean - mean)
            tmp = path + ".tmp.ogg"
            r = subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", path,
                 "-ac", "1", "-ar", "44100", "-af", "volume=%.2fdB" % gain,
                 "-c:a", "libvorbis", "-q:a", "5", tmp],
                capture_output=True, text=True)
            if r.returncode != 0:
                print("  ffmpeg failed", path, r.stderr[-200:])
                continue
            os.replace(tmp, path)
            after = levels(path)
            c["level"] = {"done": True, "gain_db": round(gain, 1),
                          "before": {"mean": mean, "peak": peak},
                          "after": {"mean": after[0], "peak": after[1]} if after else None}
            print("%-22s %-48s %+5.1f dB  peak %6.1f -> %6.1f  mean %6.1f -> %6.1f" % (
                slot, c["file"][:48], gain, peak, after[1], mean, after[0]))
    manifest["_target"] = {"mean": t_mean, "peak": t_peak, "from": len(ref)}
    json.dump(manifest, open(mpath, "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    sys.exit(main())
