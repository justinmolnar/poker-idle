# Building and publishing

One tool builds every target from a staged copy of the source; the repo is
never rewritten and `C.DEMO` stays `false` in it forever.

```sh
# one-time setup
cd build-tools && npm install && cd ..          # love.js (web)
#   + the LÖVE 12 build build-tools/engine.lock names (win64; below)
#   + optionally build-tools/bin/rcedit-x64.exe (icon + version info on the exe)

# a dev build (nothing cut; credits lenient)
python build-tools/build.py --target all

# THE DEMO: Act 1, the rest cut out of the staged files, linted, credited
python build-tools/build.py --target all --demo --version 0.1.0

# a playtest build: the demo with the local hand log on
python build-tools/build.py --target win64 --playtest --version 0.1.0

# a throwaway build to look at (unplaced items, credit TODOs, no icon = warnings)
python build-tools/build.py --target web --demo --smoke --allow-dirty
```

Output lands in `build/<version>[-demo|-playtest]/`: `IHardlyKnower.love`,
`IHardlyKnower-web.zip` (itch, HTML5), `win64/IHardlyKnower/` and
`IHardlyKnower-win64.zip` (Steam, itch), `CREDITS.txt`, and `BUILD.txt`
with each artefact's size and sha256. `build/` is gitignored.

## What the build does

1. **Preflight.** A clean tree (`--allow-dirty` to override), `C.DEMO = false`
   in the repo, and every suite and lint in `SUITES` (`--skip-tests` to skip).
2. **Stage.** `LOVE_ITEMS` copied to `build/stage/` with the package-only
   prune: `.gif` and `.md` under assets, audio `manifest.json`, `raw/` audio
   folders, and any audio `data/sounds.lua` never references
   (`list_shipped_audio.lua`). The furniture kit ships whole.
3. **Stamp.** `C.BUILD` = the version; `C.STEAM_URL` from `build.toml`;
   `--demo` sets `C.DEMO = true` and the save identity `poker-idle-demo`
   (`--playtest`: `C.PLAYTEST = true`, `poker-idle-playtest`), so a demo
   save never meets a dev or full-game save. The window title in `conf.lua`
   must equal `C.TITLE`.
4. **Cut + lint** (demo and playtest). `demo_cut.py` removes the Act 2+
   content from the staged files — its docstring is the manifest — and
   `demo_lint.lua` checks what is left and boots it headless (200 hands,
   every screen drawn). The lint **fails on Act 1 items with no place in
   the room**: the editor's EXPORT writes `data/room_layout.lua`, and the
   build reads it as exported. Nothing else to do for the room.
5. **Credits.** `credits.py` writes `CREDITS.txt` from
   `build-tools/CREDITS.head.txt` (by hand: the game, engine, packs, art)
   plus every sound the asset manifests credit. Every shipped audio file
   must be covered; a `TODO` in the head fails a demo build.
6. **.love**, 7. **web** (love.js `-c`, the shell `build-tools/index.html`
   with the real title and `favicon.png` from `assets/icon.png`), 8. **win64**
   (below), 9. **report**.

## The demo cut

The demo is Act 1: Zoom and Heads-Up at NL2–NL100, the first shove, the
cheat, the flyer. `demo_cut.py` cuts, from the staged copy only: what Act 2
catalog cards DO (each becomes a stub — id, name, art, flavour, price,
place, `demo_locked` — under a FULL GAME sticker; retired Act 2 and Act 3
cards go); stakes above `s003`; the Act 2
story beats; every deck but the starter; room layout and light entries of
cut items; procs nothing names; sprite aliases of cut items; and the dev
modules. What stays is the promise of more: every card's place in the
book, the 6-MAX and TOURNAMENTS keys on the strip (locked; nothing in the demo opens them), the Prize Vase's
"???" card, the glossary's "???" rows (`RoomLayersPanel`, `ShoveDebugOverlay`,
`Profiler`, `InputController`, `CreditsState`). `maxes_at = "s005"` on the
run upgrades becomes the level it resolved to, so the demo prices exactly
as the full game's Act 1. The code keeps its flags (`DEMO_CUT` forces the
R2 loss and caps R1's readout; `DEV_HOTKEYS`, `DECKS`, `ANALYTICS` off).

## The engine (win64)

The desktop build runs a **LÖVE 12** nightly (it reopens the audio device
when Windows' default output changes; 11 cannot — `services/AudioDevice`).
`build-tools/engine.lock` names the zip, its sha256 and the unpacked
folder; the build refuses anything else. To move to a newer build:

```
gh run list --repo love2d/love --branch main --limit 5
gh run download <run-id> --repo love2d/love --name love-windows-x64 --dir C:\love12
Expand-Archive C:\love12\love-12.0-win64.zip C:\love12\engine
sha256sum C:\love12\love-12.0-win64.zip      # into engine.lock, with the label
```

then play it through before committing the lock. Run from source on it:
`C:\love12\engine\love-12.0-win64\lovec.exe .` (expected console lines: a
deprecation notice for `t.window.highdpi`, one for `setNewFont` in the
crash screen; nothing else).

The win64 folder: `love.exe + .love` fused into `IHardlyKnower.exe`, every
DLL from the engine folder (12 ships SDL3 and the VS2015+ runtime; never mix
with 11's SDL2/mpg123 set), `license.txt`, `CREDITS.txt`. With
`build-tools/bin/rcedit-x64.exe` present (https://github.com/electron/rcedit
releases; the folder is gitignored) and `assets/icon.ico`, the exe gets the
icon and version info; otherwise a warning.

## Publishing

`build-tools/build.toml` holds the store URL, the Steam login and the demo's
app/depot ids, the itch target. Then:

```sh
python build-tools/publish.py --version 0.1.0 --demo --steam    # steamcmd upload
python build-tools/publish.py --version 0.1.0 --demo --itch     # butler push web + win64
python build-tools/publish.py --version 0.1.0 --demo --tag      # git tag demo-v0.1.0
```

Steam: `app_build.vdf`/`depot_build.vdf` are written under `build/steam/`
and `steamcmd +login <user> +run_app_build … +quit` runs (its own password
and Steam Guard prompts). Setting the build live on a branch stays a click
in Steamworks → App → Builds. Tools: [steamcmd](https://developer.valvesoftware.com/wiki/SteamCMD),
[butler](https://itch.io/docs/butler/) (`butler login` once).

itch, the web build: upload is the `web` folder (or the zip by hand);
"This file will be played in the browser", a 1600×900 viewport, "Click to
launch in fullscreen" on — the shell letterboxes the 16:9 canvas into the
iframe. Hard-refresh when testing so the browser drops the old `game.js`.

## The web build's engine

love.js 11.4.1, compatibility variant (`-c`): the threaded variant needs
COOP/COEP headers itch does not send. `conf.lua` is where 11 and 12 diverge
(`ON_12`). When the web target moves to 12, the candidate is
`rozenmad/love-web-builder`.
