#!/usr/bin/env python
"""Drive the room editor the way a person would, headless, and check it.

    python tools/room_editor/drive.py [--show] [--only NAME] [--out DIR]

Starts serve.py on a spare port, opens the page in Chrome through
Playwright, then runs a session: hover, drags by the pointer onto tops,
the floor and the walls, the shelf, cancel, undo, export. After every
step it writes a frame to --out (default: a shots/ folder here, which is
gitignored) and checks what a person would see: the hand's sprite follows
the pointer, a drop lands where the hand was drawn, a thing dropped on a
top is homed on it, nothing vanishes, the Lua parses.

Dev tooling: needs `pip install playwright` (uses the installed Chrome).
"""
import os, sys, time, json, subprocess, argparse
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PORT = 8799


class Session:
    def __init__(self, page, out):
        self.page, self.out, self.n, self.fails, self.checks = page, out, 0, [], 0
        os.makedirs(out, exist_ok=True)

    def ok(self, cond, msg):
        self.checks += 1
        if not cond:
            self.fails.append(msg)
            print("  FAIL", msg)
        else:
            print("  ok  ", msg)
        return bool(cond)

    def shot(self, name):
        self.n += 1
        path = os.path.join(self.out, "%02d_%s.png" % (self.n, name))
        self.page.wait_for_timeout(60)
        self.page.screenshot(path=path)
        return path

    def ev(self, js):
        return self.page.evaluate(js)

    def canvas_origin(self):
        r = self.ev("(() => { const r = document.getElementById('room').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
        return r

    def to_page(self, xy):
        ox, oy, _, _ = self.canvas_origin()
        return ox + xy[0], oy + xy[1]

    def desc(self, id):
        return self.ev("(() => { const d = editor.descOf(%s); if (!d) return null; return { id: d.obj.id, on: d.on, f: d.f, draw: {x: d.draw.x, y: d.draw.y, w: d.draw.w, h: d.draw.h}, E: d.E, F: d.F, hasFace: !!d.face, wall: d.wall, plane: d.plane }; })()" % json.dumps(id))

    def body_point(self, id):
        return self.ev("editor.bodyPoint(%s)" % json.dumps(id))

    def centre(self, id, which):
        return self.ev("(() => { const d = editor.descOf(%s); return d ? editor.centreOf(d, %s) : null; })()" % (json.dumps(id), json.dumps(which)))

    def hand_draw(self):
        return self.ev("(() => { const h = editor.frame && editor.frame.handDesc; if (!h) return null; return { x: h.draw.x, y: h.draw.y, w: h.draw.w, h: h.draw.h, id: h.obj.id, status: editor.hand.fit && editor.hand.fit.status, target: editor.target && (editor.target.kind === 'top' ? editor.target.desc.obj.id : editor.target.plane), overlaps: editor.hand.fit ? editor.hand.fit.overlaps.map(d => d.obj.id) : [], against: editor.hand.fit && editor.hand.fit.against ? editor.hand.fit.against.obj.id : null, wallKind: editor.hand.wallKind, align: editor.hand.f.align, flip: editor.hand.f.flip_x, layer: editor.hand.f.layer || 0 }; })()")

    def redraw(self):
        self.ev("editor.dirty()")
        self.page.wait_for_timeout(40)

    # ── gestures ──
    def drag(self, frm, to, name, steps=12, release=True):
        """Press at canvas point frm, move to canvas point to in steps, release."""
        m = self.page.mouse
        x0, y0 = self.to_page(frm); x1, y1 = self.to_page(to)
        m.move(x0, y0); m.down()
        m.move(x0 + 3, y0 + 3)
        m.move(x0 + 8, y0 + 6)
        m.move(x1, y1, steps=steps)
        self.page.wait_for_timeout(60)
        self.redraw()
        hand = self.hand_draw()
        self.shot(name + "_carry")
        if release:
            m.up()
            self.page.wait_for_timeout(60)
            self.redraw()
        return hand

    def key(self, k):
        self.page.keyboard.press(k)
        self.page.wait_for_timeout(30)
        self.redraw()


def near(a, b, tol):
    return abs(a - b) <= tol


def run(page, out, only=None):
    S = Session(page, out)
    page.goto("http://127.0.0.1:%d/" % PORT)
    page.wait_for_function("window.editor && editor.ready")
    # every placed thing's art decoded
    page.wait_for_function("(() => { editor.buildFrame(); return editor.frame.descs.every(d => d.draw.cv || d.artMissing); })()", timeout=30000)
    S.redraw()
    S.shot("rest")
    n0 = S.ev("editor.placed.length")
    S.ok(n0 >= 40, "the layout loaded: %d things" % n0)
    missing = S.ev("editor.frame.descs.filter(d => !d.draw.cv).map(d => d.obj.id)")
    S.ok(len(missing) == 0, "every placed thing has art (missing: %s)" % missing)
    S.ok(S.ev("editor.frame.descs.filter(d => d.face).length") >= 15, "faces resolved for the room's tops: %d" % S.ev("editor.frame.descs.filter(d => d.face).length"))

    def want(name):
        return only is None or only == name

    # ── hover: the thing under the pointer is the one drawn there
    if want("hover"):
        print("[hover]")
        bp = S.body_point("desk")
        S.ok(bp is not None, "a pixel of the desk to point at")
        if bp:
            page.mouse.move(*S.to_page(bp)); S.redraw()
            S.ok(S.ev("editor.hover && editor.hover.id") == "desk", "hovering the desk's pixels names the desk")
            S.shot("hover_desk")
        bp = S.body_point("prize_vase")
        if bp:
            page.mouse.move(*S.to_page(bp)); S.redraw()
            S.ok(S.ev("editor.hover && editor.hover.id") == "prize_vase", "hovering the vase names the vase")

    # ── onto a top: the calculator onto the desk, by its pixels, to the desk's face centre
    if want("top"):
        print("[top] calculator -> desk")
        frm = S.body_point("calculator"); to = S.centre("desk", "face")
        S.ok(frm and to, "grab point and the desk's face centre")
        if frm and to:
            before = S.desc("calculator")
            hand = S.drag(frm, to, "calc_to_desk")
            S.ok(hand and hand["target"] == "desk", "carried over the desk, the target is the desk (%s)" % (hand and hand["target"]))
            S.ok(hand and hand["status"] in ("on", "overhang"), "...and the hand stands ON it (%s)" % (hand and hand["status"]))
            S.shot("calc_on_desk")
            after = S.desc("calculator")
            S.ok(after is not None, "the calculator is still in the room")
            if after and hand:
                S.ok(after["on"] == "desk", "dropped, it is homed on the desk (on=%s)" % after["on"])
                S.ok(near(after["draw"]["x"], hand["x"], 1.5) and near(after["draw"]["y"], hand["y"], 1.5),
                     "it is drawn where the hand showed it (%.1f,%.1f vs %.1f,%.1f)" % (after["draw"]["x"], after["draw"]["y"], hand["x"], hand["y"]))
                S.ok(S.ev("editor.placed.length") == n0, "nothing vanished (%d things)" % S.ev("editor.placed.length"))
            # the pointer is now over the calculator on the desk: hovering it names it
            page.mouse.move(*S.to_page(to)); S.redraw()
            hv = S.ev("editor.hover && editor.hover.id")
            S.ok(hv in ("calculator", "desk"), "what is under the pointer after the drop is the calculator or the desk (%s)" % hv)

    # ── the gift box onto the bookshelf, then the fridge
    if want("shelf"):
        for tgt in ("bookshelf", "compact_fridge"):
            print("[top] starter_gift_box ->", tgt)
            frm = S.body_point("starter_gift_box"); to = S.centre(tgt, "face")
            S.ok(frm and to, "grab point and %s's face centre" % tgt)
            if frm and to:
                hand = S.drag(frm, to, "gift_to_" + tgt)
                S.ok(hand and hand["target"] == tgt, "the target is %s (%s)" % (tgt, hand and hand["target"]))
                after = S.desc("starter_gift_box")
                S.shot("gift_on_" + tgt)
                S.ok(after and after["on"] == tgt, "dropped, it is homed on %s (on=%s)" % (tgt, after and after["on"]))
                S.ok(after and hand and near(after["draw"]["x"], hand["x"], 1.5) and near(after["draw"]["y"], hand["y"], 1.5), "drawn where the hand showed it")

    # ── onto the floor: the gift box to an empty spot; it leaves its parent
    if want("floor"):
        print("[floor] starter_gift_box -> the floor at 3.5,3.5")
        frm = S.body_point("starter_gift_box")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(3.5, 3.5, 0))")
        if frm:
            hand = S.drag(frm, to, "gift_to_floor")
            after = S.desc("starter_gift_box")
            S.shot("gift_on_floor")
            S.ok(hand and hand["target"] is None, "the target is the floor (%s)" % (hand and hand["target"]))
            S.ok(after and after["on"] is None, "dropped on the floor it has no parent (on=%s)" % (after and after["on"]))
            S.ok(after and 2.5 <= after["f"]["gx"] <= 4.5 and 2.5 <= after["f"]["gy"] <= 4.5, "...near where it was dropped (%.2f, %.2f)" % ((after or {"f": {"gx": -1, "gy": -1}})["f"]["gx"], (after or {"f": {"gx": -1, "gy": -1}})["f"]["gy"]))
            S.ok(after and near(after["draw"]["x"], hand["x"], 1.5) and near(after["draw"]["y"], hand["y"], 1.5), "drawn where the hand showed it")

    # ── refusal: the vase pushed into the book stack slides to its edge
    if want("push"):
        print("[push] prize_vase into stack_of_books")
        frm = S.body_point("prize_vase")
        books = S.desc("stack_of_books")
        if frm and books:
            to = S.ev("(() => { const d = editor.descOf('stack_of_books'); const [gx, gy] = editor.centroid(d.foot); return editor.roomToScreen(...editor.gridElevToRoom(gx, gy, 0)); })()")
            hand = S.drag(frm, to, "vase_into_books", release=False)
            S.ok(hand and "stack_of_books" not in hand["overlaps"], "aimed at the books' centre the vase does not cross them (%s)" % (hand and hand["overlaps"]))
            page.keyboard.press("Escape"); page.mouse.up(); S.redraw()
            S.ok(S.ev("editor.hand") is None and S.desc("prize_vase") is not None, "Esc puts the vase back")

    # ── walls: the sticky note to the side wall, then the clock along the back wall
    if want("wall"):
        print("[wall] yellow_sticky_note -> the side wall")
        frm = S.body_point("yellow_sticky_note")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(0, 3, 45))")
        if frm:
            hand = S.drag(frm, to, "sticky_to_side_wall")
            after = S.desc("yellow_sticky_note")
            S.shot("sticky_on_side_wall")
            S.ok(hand and hand["target"] == "side", "the target is the side wall (%s)" % (hand and hand["target"]))
            S.ok(after and after["f"]["align"] == "right_wall" and abs(after["f"]["gx"]) < 0.01, "dropped, it is on the gx=0 wall (align %s, gx %s)" % (after and after["f"]["align"], after and after["f"]["gx"]))
            S.ok(after and 2 <= after["f"]["gy"] <= 4, "...around gy 3 (%.2f)" % ((after or {"f": {"gy": -1}})["f"]["gy"]))
            S.ok(after and near(after["draw"]["x"], hand["x"], 1.5) and near(after["draw"]["y"], hand["y"], 1.5), "drawn where the hand showed it")
        print("[wall] wall_clock along the back wall")
        frm = S.body_point("wall_clock")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(3.5, 0, 60))")
        if frm:
            hand = S.drag(frm, to, "clock_to_back_wall")
            after = S.desc("wall_clock")
            S.shot("clock_on_back_wall")
            S.ok(after and after["f"]["align"] == "left_wall" and abs(after["f"]["gy"]) < 0.01, "the clock is on the gy=0 wall (align %s)" % (after and after["f"]["align"]))
            S.ok(after and near(after["draw"]["x"], hand["x"], 1.5) and near(after["draw"]["y"], hand["y"], 1.5), "drawn where the hand showed it")

    # ── a parent moves with its children: the desk to the back corner
    if want("parent"):
        print("[parent] desk -> 2.5,1.5 with everything on it")
        kids_before = S.ev("editor.frame.descs.filter(d => d.on === 'desk').map(d => d.obj.id)")
        frm = S.body_point("desk")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(3.0, 2.0, 0))")
        if frm:
            hand = S.drag(frm, to, "desk_moves")
            S.shot("desk_moved")
            kids_after = S.ev("editor.frame.descs.filter(d => d.on === 'desk').map(d => d.obj.id)")
            S.ok(sorted(kids_before) == sorted(kids_after), "the desk's children still sit on it (%d)" % len(kids_after))
            after = S.desc("desk")
            S.ok(after and near(after["draw"]["x"], hand["x"], 1.5) and near(after["draw"]["y"], hand["y"], 1.5), "the desk is drawn where the hand showed it")

    # ── the shelf: a flavour thing dragged in; a catalog thing already placed moves
    if want("fromshelf"):
        print("[shelf] a thumbnail into the room")
        page.fill("#filter", "Duck")
        page.wait_for_timeout(100)
        cell = page.query_selector(".cell")
        S.ok(cell is not None, "the filter finds a duck")
        if cell:
            box = cell.bounding_box()
            to = S.to_page(S.ev("editor.roomToScreen(...editor.gridElevToRoom(4.0, 4.0, 0))"))
            n_before = S.ev("editor.placed.length")
            page.mouse.move(box["x"] + 30, box["y"] + 30); page.mouse.down()
            page.mouse.move(box["x"] + 40, box["y"] + 20); page.mouse.move(to[0], to[1], steps=10)
            page.wait_for_timeout(60); S.redraw()
            hand = S.hand_draw()
            S.shot("shelf_duck_carry")
            S.ok(hand is not None, "the duck is in the hand off the shelf")
            page.mouse.up(); S.redraw()
            S.shot("shelf_duck_dropped")
            n_after = S.ev("editor.placed.length")
            S.ok(n_after >= n_before, "dropped in the room it is placed (%d -> %d)" % (n_before, n_after))
        page.fill("#filter", "")
        page.wait_for_timeout(100)

    # ── bumping: the chair (homed on the desk) carried into the bed stops at it
    if want("bump"):
        print("[bump] gaming_chair into comfort_bed")
        frm = S.body_point("gaming_chair")
        to = S.ev("(() => { const d = editor.descOf('comfort_bed'); const [gx, gy] = editor.centroid(d.foot); return editor.roomToScreen(...editor.gridElevToRoom(gx, gy, 0)); })()")
        if frm:
            hand = S.drag(frm, to, "chair_into_bed", release=False)
            S.ok(hand and (hand["against"] == "comfort_bed" or "comfort_bed" in hand["overlaps"]), "the chair meets the bed on the floor (against %s, crossing %s)" % (hand and hand["against"], hand and hand["overlaps"]))
            page.keyboard.press("Escape"); page.mouse.up(); S.redraw()
        print("[bump] prize_vase into the desk")
        frm = S.body_point("prize_vase")
        to = S.ev("(() => { const d = editor.descOf('desk'); const [gx, gy] = editor.centroid(d.foot); return editor.roomToScreen(...editor.gridElevToRoom(gx, gy, 0)); })()")
        if frm:
            # aimed at the desk's foot centre the pointer is over the desk's pixels, so the top is the target;
            # with Shift the desk's top is still the target but neighbours are ignored — so aim beside the desk's foot instead
            to2 = S.ev("editor.roomToScreen(...editor.gridElevToRoom(1.1, 2.0, 0))")
            hand = S.drag(frm, to2, "vase_beside_desk", release=False)
            S.ok(hand and hand["target"] is None and (hand["against"] == "desk" or "desk" in hand["overlaps"] or hand["overlaps"] == []), "beside the desk the vase is on the floor and meets the desk or sits clear (against %s, crossing %s)" % (hand and hand["against"], hand and hand["overlaps"]))
            page.keyboard.press("Escape"); page.mouse.up(); S.redraw()

    # ── wall things: a poster off the shelf is a wall thing on the wall it is pointed at;
    #    one carried to the other wall mirrors and changes wall
    if want("poster"):
        print("[poster] Poster_1 off the shelf onto the back wall")
        page.fill("#filter", "Poster_1")
        page.wait_for_timeout(100)
        cell = page.query_selector(".cell")
        S.ok(cell is not None, "the filter finds Poster_1")
        if cell:
            box = cell.bounding_box()
            to = S.to_page(S.ev("editor.roomToScreen(...editor.gridElevToRoom(3.5, 0, 50))"))
            n_before = S.ev("editor.placed.length")
            page.mouse.move(box["x"] + 30, box["y"] + 30); page.mouse.down()
            page.mouse.move(box["x"] + 40, box["y"] + 20); page.mouse.move(to[0], to[1], steps=10)
            page.wait_for_timeout(60); S.redraw()
            hand = S.hand_draw()
            S.shot("poster_carry")
            S.ok(hand and hand["wallKind"] and hand["target"] == "back", "off the shelf the poster is a wall thing on the back wall (%s, %s)" % (hand and hand["wallKind"], hand and hand["target"]))
            page.mouse.up(); S.redraw()
            S.shot("poster_dropped")
            S.ok(S.ev("editor.placed.length") == n_before + 1, "dropped, it is placed")
            pid = S.ev("editor.placed[editor.placed.length - 1].id")
            d = S.desc(pid)
            S.ok(d and d["f"]["align"] == "left_wall" and abs(d["f"]["gy"]) < 0.01 and d["f"]["flip_x"], "...on the gy=0 wall, mirrored for it (align %s, flip %s)" % (d and d["f"]["align"], d and d["f"]["flip_x"]))
            S.ok(d and hand and near(d["draw"]["x"], hand["x"], 1.5) and near(d["draw"]["y"], hand["y"], 1.5), "drawn where the hand showed it")
            # now to the side wall: it changes wall and un-mirrors
            frm = S.body_point(pid)
            to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(0, 3.5, 50))")
            if frm:
                hand = S.drag(frm, to, "poster_to_side")
                d = S.desc(pid)
                S.shot("poster_on_side")
                S.ok(d and d["f"]["align"] == "right_wall" and abs(d["f"]["gx"]) < 0.01 and not d["f"]["flip_x"], "carried to the side wall it is on the gx=0 wall, mirrored back (align %s, flip %s)" % (d and d["f"]["align"], d and d["f"]["flip_x"]))
                S.ok(d and hand and near(d["draw"]["x"], hand["x"], 1.5) and near(d["draw"]["y"], hand["y"], 1.5), "drawn where the hand showed it")
        page.fill("#filter", "")
        page.wait_for_timeout(100)
        print("[poster] dogs_playing_poker from the side wall to the back wall")
        before = S.desc("dogs_playing_poker")
        frm = S.body_point("dogs_playing_poker")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(2.0, 0, 55))")
        if frm and before:
            hand = S.drag(frm, to, "dogs_to_back")
            d = S.desc("dogs_playing_poker")
            S.ok(d and d["f"]["align"] == "left_wall" and d["f"]["flip_x"] != before["f"]["flip_x"], "the dogs poster changes wall and mirrors (align %s, flip %s -> %s)" % (d and d["f"]["align"], before["f"]["flip_x"], d and d["f"]["flip_x"]))
            S.ok(d and 1 <= d["f"]["gx"] <= 3 and 40 <= d["f"]["z_offset"] <= 70, "...where it was carried along and up the wall (gx %.2f, z %s)" % ((d or {"f": {"gx": -1}})["f"]["gx"], d and d["f"]["z_offset"]))

    # ── layers: Z while dragging raises the layer; the panel's buttons too
    if want("layer"):
        print("[layer] prize_vase up two layers while dragging")
        before = S.desc("prize_vase")
        frm = S.body_point("prize_vase")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(2.0, 3.0, 0))")
        if frm and before:
            m = page.mouse
            x0, y0 = S.to_page(frm); x1, y1 = S.to_page(to)
            m.move(x0, y0); m.down(); m.move(x0 + 8, y0 + 6); m.move(x1, y1, steps=8)
            page.wait_for_timeout(40); S.redraw()
            h0 = S.hand_draw()
            page.keyboard.press("z"); page.keyboard.press("z"); page.wait_for_timeout(40); S.redraw()
            hand = S.hand_draw()
            S.ok(h0 and hand and hand["layer"] == h0["layer"] + 2, "two Z presses: layer %s -> %s" % (h0 and h0["layer"], hand and hand["layer"]))
            m.up(); S.redraw()
            d = S.desc("prize_vase")
            S.ok(d and hand and d["f"]["layer"] == hand["layer"], "dropped, the layer is kept (%s)" % (d and d["f"]["layer"]))
            page.mouse.click(*S.to_page(S.body_point("prize_vase") or to)); S.redraw()
            page.click("#p_layer_dn"); S.redraw()
            d = S.desc("prize_vase")
            S.ok(d and hand and d["f"]["layer"] == hand["layer"] - 1, "the panel's Layer - lowers it (%s)" % (d and d["f"]["layer"]))

    # ── undo
    if want("undo"):
        print("[undo]")
        before = S.ev("JSON.stringify(editor.placed)")
        frm = S.body_point("prize_vase")
        to = S.ev("editor.roomToScreen(...editor.gridElevToRoom(2.0, 4.0, 0))")
        if frm:
            S.drag(frm, to, "vase_moves")
            moved = S.ev("JSON.stringify(editor.placed)")
            S.ok(moved != before, "the move changed the room")
            S.key("Control+z")
            S.ok(S.ev("JSON.stringify(editor.placed)") == before, "Ctrl+Z put it back exactly")
            S.key("Control+y")
            S.ok(S.ev("JSON.stringify(editor.placed)") == moved, "Ctrl+Y redid it")
            S.key("Control+z")

    # ── export: the Lua parses and has every thing
    if want("export"):
        print("[export]")
        lua = S.ev("editor.layoutString()")
        tmp = os.path.join(out, "export.lua")
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(lua + "\n")
        chk = subprocess.run(["lua", "-e", "local t = dofile(%s); local n = 0; for k in pairs(t) do if k ~= '__meta' then n = n + 1 end end; print(n)" % json.dumps(tmp.replace("\\", "/"))],
                             capture_output=True, text=True, cwd=ROOT)
        S.ok(chk.returncode == 0, "the exported Lua loads: " + chk.stderr.strip())
        if chk.returncode == 0:
            S.ok(int(chk.stdout.strip()) == S.ev("editor.placed.length"), "...with every thing in it (%s)" % chk.stdout.strip())

    print("drive: %d checks, %d failures" % (S.checks, len(S.fails)))
    for f in S.fails:
        print("  FAIL", f)
    return len(S.fails)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--only")
    ap.add_argument("--out", default=os.path.join(HERE, "shots"))
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--height", type=int, default=950)
    a = ap.parse_args()
    env = dict(os.environ, ROOM_EDITOR_PORT=str(PORT))
    srv = subprocess.Popen([sys.executable, os.path.join(HERE, "serve.py"), "--no-browser"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    from playwright.sync_api import sync_playwright
    fails = 1
    try:
        with sync_playwright() as p:
            b = p.chromium.launch(channel="chrome", headless=not a.show)
            page = b.new_page(viewport={"width": a.width, "height": a.height})
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("console", lambda m: print("  [console]", m.text) if m.type in ("error", "warning") else None)
            fails = run(page, a.out, a.only)
            if errors:
                print("page errors:")
                for e in errors:
                    print("  ", e)
                fails += len(errors)
            b.close()
    finally:
        srv.terminate()
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
