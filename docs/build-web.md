# Building the web (HTML5) build for itch.io

The game is a LÖVE 11.4 project. The web build is produced by transpiling a
`.love` package with [love.js](https://github.com/Davidobot/love.js) (the
Emscripten port of LÖVE) and dropping in a custom HTML shell.

A script does all of it: **`python build-tools/build_web.py`**. The rest of
this doc explains the prerequisites, the moving parts, and how to ship.

## TL;DR

```sh
# one-time setup
cd build-tools && npm install && cd ..

# every build
python build-tools/build_web.py
```

Then upload `build/PokerIdle-web.zip` to itch (see [Uploading](#uploading)).

## Prerequisites

- **Node.js** (the love.js CLI runs on it).
- **Python 3** (used only to build the zips with correct entry paths — no
  third-party packages, stdlib `zipfile` only).
- **love.js**, installed into `build-tools/node_modules`:
  ```sh
  cd build-tools && npm install
  ```
  `build-tools/package.json` pins `love.js@^11.4.1`, matching the game's LÖVE
  11.4. (The script will also fall back to an existing
  `build/tools/node_modules` install if that's where love.js already lives.)

## What the script does

`build-tools/build_web.py` runs four steps, all output under `build/` (which
is gitignored):

1. **Package `build/PokerIdle.love`** — zips the game source (`conf.lua`,
   `main.lua`, and the `assets controllers core data lib models services
   shaders states utils views` folders) with entries at the archive root and
   forward-slash paths. Everything else (`build/`, `docs/`, `.git`, `.claude`,
   `.vscode`, `build-tools`) is excluded. To add a new top-level source folder,
   add it to `LOVE_ITEMS` in the script.
2. **Run love.js** in **compatibility mode** (`-c`) into `build/web/`. This
   emits `game.data`, `game.js`, `love.js`, `love.wasm`, a default
   `index.html`, and a `theme/` folder.
3. **Install the custom shell** — overwrites the generated `index.html` with
   `build-tools/index.html`. love.js regenerates a plain `index.html` every
   run, so the custom one is **the tracked source of truth** and gets copied
   in each build (see [The custom shell](#the-custom-shell)).
4. **Package `build/PokerIdle-web.zip`** — zips the contents of `build/web/`
   with `index.html` at the zip root, ready for itch.

love.js is a transpiler; running it does **not** launch the game.

## The custom shell

`build-tools/index.html` is a hand-tuned replacement for love.js's default
page. It is fully self-contained (all CSS inline, loads `game.js` + `love.js`)
and does two things the default doesn't:

- **DPR-aware canvas sizing** — it renders the canvas at
  `viewport_px * devicePixelRatio` and CSS-scales it to fill the iframe, so
  the chunky pixel font stays crisp on HiDPI displays instead of being
  fractionally scaled. The internal render stays at the layout's design size;
  `love.resize` re-fits via `FontService.rebuildInto`.
- **Re-fits after load** — Emscripten's `SDL_CreateWindow` resets the canvas
  to `conf.lua`'s 1600x900 right after the first fit, so the shell dispatches
  `fitAll()` again on a short delay.

If you ever need to regenerate the shell from scratch, run love.js once, take
its generated `index.html`, and re-apply the `fitAll` logic — but normally you
just edit `build-tools/index.html` and rebuild.

> ⚠️ The shell is the only web-specific file that isn't auto-generated. Keep it
> in `build-tools/` (tracked). The copies under `build/` are disposable.

## Why compatibility mode (`-c`)

The non-compat love.js variant uses pthreads, which require
`SharedArrayBuffer` and therefore COOP/COEP response headers. itch.io's web
host doesn't send those, so the threaded build fails there. The compat variant
drops pthreads (the only cost is slightly less robust audio) and runs on itch.

Memory is left at love.js's default initial size with dynamic growth enabled,
so no `-m` flag is needed.

## Uploading

On the game's itch.io edit page:

1. Upload `build/PokerIdle-web.zip`.
2. Mark it **"This file will be played in the browser"** (Kind of project:
   HTML).
3. Set the embed to a **1600x900** viewport (16:9) and enable
   **"Click to launch in fullscreen"** — the shell expects the iframe to take
   the viewport and letterboxes the 16:9 canvas into it.
4. Save. Hard-refresh the page when testing so the browser doesn't serve the
   old cached `game.js` / `love.wasm`.

## Desktop builds

The Windows desktop build lives in `build/PokerIdle-win64/` and
`build/PokerIdle-win64.zip` (love.exe + the fused `.love`). It is not produced
by this script; this doc covers the web build only.
