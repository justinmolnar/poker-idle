# Windows desktop build

The desktop build runs on a **LÖVE 12 nightly**; the web build stays on
love.js 11.4.1 (`docs/build-web.md`). The code is written to run on both:
everything engine-specific is in `conf.lua` (`ON_12`). Why 12 on desktop:
LÖVE 11 opens the OpenAL device once and can't reopen it, so audio dies for
good when Windows' default output changes (headphones die, reconnect,
switch). LÖVE 12 can reopen the device in place (`love.audio.setPlaybackDevice`,
keeping every Source's state). Its own `audiodisconnected` event fires only
when the open device reports disconnected, which a headphone power-off or a
default switch often doesn't; `services/AudioDevice.lua` therefore polls the
system default against the open device once a second and reopens when they
diverge.

## The engine

LÖVE 12.0 is unreleased. The engine's own CI publishes a `love-windows-x64`
artifact for every green run of the main branch. Pinned build:

| | |
|---|---|
| run | `32927750822` |
| commit | `4e167072ae558e114cacec28ad5abb2ec2cdf05c` |
| date | 2026-08-26 |
| location | `C:\love12\engine\love-12.0-win64\` (outside the repo; the 11.5 install in Program Files is untouched) |

Fetch it (GitHub login via `gh` required; artifacts expire after 90 days,
so when this one is gone pick the newest green run of the
`continuous-integration` workflow and update this table):

```
gh run list --repo love2d/love --branch main --limit 5
gh run download <run-id> --repo love2d/love --name love-windows-x64 --dir C:\love12
Expand-Archive C:\love12\love-12.0-win64.zip C:\love12\engine
```

Run the game from source on it: `C:\love12\engine\love-12.0-win64\love.exe .`
from the repo root (`lovec.exe` for a console). Expected console lines on 12:
a deprecation notice for `t.window.highdpi` (kept for 11) and one for
`love.graphics.setNewFont` in the crash screen. Nothing else.

## Assembling `build/PokerIdle-win64/`

There is no committed script (`build/` is gitignored). The steps, which
`build-tools/build_web.py` step 1 also performs for the `.love`:

1. Zip the source manifest into `build/PokerIdle.love` with forward-slash,
   root-relative entries: `conf.lua main.lua assets controllers core data lib
   models services shaders states utils views`. Skip `.gif` files. `sim/`,
   `tools/`, `docs/`, `build*/` are never shipped.
2. `copy /b love.exe + PokerIdle.love PokerIdle.exe` using the engine's
   `love.exe`.
3. Copy the engine's DLL set beside it: `love.dll lua51.dll SDL3.dll
   OpenAL32.dll msvcp140*.dll vcruntime140*.dll` (12 ships SDL3 and the
   VS2015+ runtime; 11 shipped SDL2, `mpg123.dll` and the VS2013 runtime —
   never mix the two sets) and `license.txt`.
4. Zip the folder to `build/PokerIdle-win64.zip`.

The last 11.5 build is kept as `build/PokerIdle-win64-love11.5.zip` as the
rollback until the 12 build has been played through.

## Verifying the audio fix

With music playing: unplug or power off the headphones; audio continues on
the speakers within a second. Plug back in and make them the default again;
audio follows. Repeat mid-shove and mid-hand. Same with a Bluetooth device
dropping. The console prints `[audio] default output changed: ... -> ...` (or
`device disconnected`) followed by `reopened onto the default output` each time.
