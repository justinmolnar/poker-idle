# Room editor

The build-mode editor for `data/room_layout.lua`, in the browser.

    python tools/room_editor/serve.py

opens http://127.0.0.1:8765/ in your browser. It draws the room the way
the game does (same projection, anchors, sprite bottoms and draw order)
and knows every thing's footprint, top face, height and wall rectangle
from `data/room_surfaces.lua`.

- **Drag** a thumbnail off the shelf on the left, or anything in the
  room by its pixels. Release to drop; right-click or Esc cancels.
- **Over a top** (desk, shelf, fridge…) the top lights and the thing
  stands on it; the drop parents it there. Over something that sits on a
  top, the top underneath is the target. Elsewhere it goes on the floor.
- **Snap** is on by default (G toggles, Alt holds it off): half cells on
  the floor, quarter cells on tops; walls slide in quarter cells and 4 px.
- **Feet refuse to cross**: pushed into a neighbour a thing slides along
  it until they touch; what still crosses shows red, and the top bar
  names it.
- **Wall things** (posters, clocks, the corkboard) ride the wall you point
  at, along it and up it.
- **Click** selects; the panel on the right edits it (z, dx, layer, scale,
  frame, flip, align, size, lock, its homes). Delete, Ctrl+D copy, R flip,
  Z / X layer, 7 / 8 height, ← → pixel nudge, [ ] frame, Shift+wheel scale.
  The same keys work on the thing in hand.
- **Wheel** zooms at the pointer; middle-drag, right-drag or Space+drag
  pans; Fit recentres. Ctrl+Z / Ctrl+Y undo and redo.
- **Save** (Ctrl+S) writes `data/room_layout.lua` and moves the dev
  build's autosaved draft aside (it would otherwise shadow the file).
  **Lua** shows what would be written.

Unsaved edits are kept in the browser; the page offers them back next
time.

## Checking it

    pip install playwright
    python tools/room_editor/drive.py          # add --show to watch

drives the editor like a person (hover, drags onto tops, the floor and
the walls, the shelf, pushes, cancel, undo, export) and checks each move;
a frame of every step lands in `tools/room_editor/shots/`.

Needs `lua` on the PATH (the data files are Lua) and Pillow
(`tools/requirements-dev.txt`).
