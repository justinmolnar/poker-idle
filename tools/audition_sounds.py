"""tools/audition_sounds.py

A local page for auditioning the sound candidates (tools/fetch_sound_candidates.py
fetches them, tools/normalize_candidates.py levels them): play each one,
compare it against a sound already in the game, pick one per slot, write
notes. Picks and notes save as you go to
assets/audio/raw/candidates/picks.json, which is what Claude reads to
place the chosen files.

    python tools/audition_sounds.py          # opens http://localhost:8765

Only files under assets/audio/ are served, and only to this machine.
"""

import json
import os
import posixpath
import sys
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AUDIO = os.path.join(ROOT, "assets", "audio")
CAND = os.path.join(AUDIO, "raw", "candidates")
PICKS = os.environ.get("AUDITION_PICKS") or os.path.join(CAND, "picks.json")
PAGE = os.path.join(os.path.dirname(__file__), "audition_sounds.html")
PORT = int(os.environ.get("AUDITION_PORT", "8765"))


def references():
    """Every sound the game plays today (raw folders skipped, as the loader does)."""
    out = []
    for dirpath, dirnames, filenames in os.walk(AUDIO):
        dirnames[:] = [d for d in dirnames if d != "raw" and not d.endswith("Copy")]
        for f in filenames:
            if f.lower().endswith((".ogg", ".mp3", ".wav")):
                rel = os.path.relpath(os.path.join(dirpath, f), AUDIO).replace(os.sep, "/")
                if not rel.startswith("music/"):
                    out.append(rel)
    return sorted(out)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            return self._send(200, open(PAGE, "rb").read(), "text/html; charset=utf-8")
        if path == "/api/data":
            data = {
                "candidates": json.load(open(os.path.join(CAND, "candidates.json"), encoding="utf-8")),
                "picks": json.load(open(PICKS, encoding="utf-8")) if os.path.exists(PICKS) else {},
                "references": references(),
            }
            return self._send(200, json.dumps(data).encode("utf-8"), "application/json")
        if path.startswith("/audio/"):
            rel = posixpath.normpath(urllib.parse.unquote(path[len("/audio/"):]))
            full = os.path.abspath(os.path.join(AUDIO, rel))
            if not full.startswith(AUDIO + os.sep) or not os.path.isfile(full):
                return self._send(404, b"not found", "text/plain")
            ext = os.path.splitext(full)[1].lower()
            ctype = {".ogg": "audio/ogg", ".mp3": "audio/mpeg", ".wav": "audio/wav"}.get(ext, "application/octet-stream")
            return self._send(200, open(full, "rb").read(), ctype)
        return self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/api/picks":
            return self._send(404, b"not found", "text/plain")
        n = int(self.headers.get("Content-Length", "0"))
        try:
            picks = json.loads(self.rfile.read(n).decode("utf-8"))
        except ValueError:
            return self._send(400, b"bad json", "text/plain")
        tmp = PICKS + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(picks, f, indent=1, sort_keys=True)
        os.replace(tmp, PICKS)
        return self._send(200, b"{\"ok\":true}", "application/json")


def main():
    if not os.path.exists(os.path.join(CAND, "candidates.json")):
        print("no candidates yet: run tools/fetch_sound_candidates.py first")
        return 1
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = "http://localhost:%d/" % PORT
    print("auditioning at", url, "(Ctrl+C to stop); picks save to", os.path.relpath(PICKS, ROOT))
    if "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
