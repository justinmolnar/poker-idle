// tools/room_editor/editor.js — the room editor, in the browser.
//
// A build mode for data/room_layout.lua. It draws the room exactly as
// views/RoomView does (same projection, anchors, sprite bottoms, sort),
// knows every thing's footprint / top face / height / wall rectangle from
// data/room_surfaces.lua (models/room_space ported), and edits by drag and
// drop: the thing under the pointer is the thing whose drawn pixel is
// there; a thing carried over a top stands on it; feet refuse to cross;
// wall things live on the walls; the result exports as the same Lua file.
//
// Served by serve.py (which also writes the file). window.editor is the
// live state, for drive.py's scripted sessions.

(() => {
'use strict';

const TW = 64, TH = 32;               // one grid cell on screen at ui scale 1
const WALL_TOL = 0.125, INSIDE_TOL = 0.03, LEVEL_EPS = 0.5, WALL_TOUCH = 0.15;
const DRAG_PX = 4;

// ── Data ───────────────────────────────────────────────────────────────

const D = { data: null, images: {}, cells: {}, alpha: {} };   // key -> Image; key -> [canvas per cell]; key -> [ImageData]

function spriteKeyFor(e) {
  const cat = D.catalogById[e.id];
  const name = e.sprite || (cat && cat.sprite) || e.id;
  const key = D.data.aliases[name] || name;
  const anim = D.data.animations[key] || D.data.animations[name];
  const frame = Math.max(1, Math.floor(e.frame || 1));
  if (anim && anim.length) return { key: anim[Math.min(anim.length, frame) - 1], cell: 0, name };
  const info = D.data.sprites[key];
  if (info && info.cells > 1) return { key, cell: Math.min(info.cells, frame) - 1, name };
  return { key, cell: 0, name };
}

function surfaceFor(sk) {
  const s = D.data.surfaces[sk.key];
  if (!s) return null;
  if (s.cells && s.cells.length) return s.cells[Math.min(s.cells.length - 1, sk.cell)] || s;
  return s;
}

function geomFor(sk, entry) {
  const info = D.data.sprites[sk.key];
  const cw = (entry && entry.cell && entry.cell[0]) || (info && info.cell_w);
  const bottom = (entry && entry.bottom) || (info && info.bottoms[sk.cell]);
  if (!cw || !bottom) return null;
  return { cell_w: cw, bottom };
}

// The House's poster is baked at boot by views/HouseArt (the photo, flat
// 38 x 30, sheared onto the wall with a shadow); here the photo itself,
// sheared the same way, stands in for it.
function bakeHousePoster() {
  const FW = 38, FH = 30, SHEAR = 0.5;
  const photo = loadImage('house/photo');
  const make = () => {
    const cv = document.createElement('canvas');
    cv.width = FW + 2; cv.height = FH + Math.ceil(FW * SHEAR) + 2;
    const g = cv.getContext('2d');
    g.imageSmoothingEnabled = true;
    g.fillStyle = 'rgba(0,0,0,0.35)';
    g.transform(1, SHEAR, 0, 1, 1, 1);
    g.fillRect(1, 1, FW, FH);
    g.drawImage(photo, 0, 0, FW, FH);
    D.cells['house_poster_wall'] = [cv];
    D.alpha['house_poster_wall'] = [g.getImageData(0, 0, cv.width, cv.height)];
    D.data.sprites['house_poster_wall'] = { w: cv.width, h: cv.height, cells: 1, cell_w: cv.width, bottoms: [cv.height] };
    dirty();
  };
  const img = new Image();
  D.images['house_poster_wall'] = img;
  if (photo && photo.complete && photo.naturalWidth) make();
  else if (photo) { const prev = photo.onload; photo.onload = () => { if (prev) prev(); make(); }; }
  return img;
}

function loadImage(key) {
  if (key === 'house_poster_wall' && D.images[key] === undefined) return bakeHousePoster();
  if (D.images[key] !== undefined) return D.images[key];
  const img = new Image();
  D.images[key] = img;
  img.onload = () => {
    const info = D.data.sprites[key] || { cells: 1, cell_w: img.width, h: img.height };
    const cells = [];
    for (let c = 0; c < info.cells; c++) {
      const cv = document.createElement('canvas');
      cv.width = info.cell_w; cv.height = info.h;
      const g = cv.getContext('2d');
      g.drawImage(img, c * info.cell_w, 0, info.cell_w, info.h, 0, 0, info.cell_w, info.h);
      cells.push(cv);
    }
    D.cells[key] = cells;
    D.alpha[key] = cells.map(cv => cv.getContext('2d').getImageData(0, 0, cv.width, cv.height));
    dirty();
  };
  img.onerror = () => { D.images[key] = null; };
  img.src = '/sprites/' + key.split('/').map(encodeURIComponent).join('/') + '.png';
  return img;
}

function cellCanvas(sk) {
  loadImage(sk.key);
  const cells = D.cells[sk.key];
  return cells ? cells[Math.min(cells.length - 1, sk.cell)] : null;
}

function alphaAt(sk, u, v) {
  const a = D.alpha[sk.key];
  if (!a) return 1;
  const id = a[Math.min(a.length - 1, sk.cell)];
  const x = Math.min(id.width - 1, Math.max(0, Math.floor(u * id.width)));
  const y = Math.min(id.height - 1, Math.max(0, Math.floor(v * id.height)));
  return id.data[(y * id.width + x) * 4 + 3] / 255;
}

// ── Placement model (models/room_placement.lua) ────────────────────────

function anchorOffset(align, w, h) {
  w = w || 1; h = h || 1;
  if (align === 'left_wall') return [w * 0.5, 0];
  if (align === 'right_wall') return [0, h * 0.5];
  return [w * 0.5, h * 0.5];
}
function otherWall(a) { return a === 'left_wall' ? 'right_wall' : a === 'right_wall' ? 'left_wall' : a; }
function frameOf(f) {
  const [ox, oy] = anchorOffset(f.align, f.w, f.h);
  let H = 1;
  if (f.flip_x) H = -H;
  if (f.align === 'right_wall') H = -H;
  return { ax: f.gx + ox, ay: f.gy + oy, z: f.z_offset || 0, dx: f.dx || 0, H, flip: !!f.flip_x };
}
function toLocal(frame, f) {
  const [ox, oy] = anchorOffset(f.align, f.w, f.h);
  const ex = (f.gx + ox) - frame.ax, ey = (f.gy + oy) - frame.ay;
  const h = { u: (ex - ey) * frame.H, v: ex + ey, z_offset: (f.z_offset || 0) - frame.z,
              dx: ((f.dx || 0) - frame.dx) * frame.H, layer: f.layer || 0, scale: f.scale || 1, f: 3 };
  if (frame.H < 0) { h.align = otherWall(f.align || 'center'); h.w = f.h || 1; h.h = f.w || 1; }
  else { h.align = f.align || 'center'; h.w = f.w || 1; h.h = f.h || 1; }
  const fl = (!!f.flip_x) !== frame.flip;
  if (fl) h.flip_x = true;
  if (h.align === 'center') delete h.align;
  return h;
}
function toWorld(frame, h, out) {
  let align, w, hh;
  if (frame.H < 0) { align = otherWall(h.align || 'center'); w = h.h || 1; hh = h.w || 1; }
  else { align = h.align || 'center'; w = h.w || 1; hh = h.h || 1; }
  const flip = (!!h.flip_x) !== frame.flip;
  const a = (h.u || 0) * frame.H, b = h.v || 0;
  const ex = (a + b) * 0.5, ey = (b - a) * 0.5;
  const [ox, oy] = anchorOffset(align !== 'center' ? align : null, w, hh);
  out.gx = frame.ax + ex - ox; out.gy = frame.ay + ey - oy;
  out.z_offset = frame.z + (h.z_offset || 0);
  out.dx = frame.dx + (h.dx || 0) * frame.H;
  out.flip_x = flip; out.align = align !== 'center' ? align : null;
  out.w = w; out.h = hh;
  if (h.layer != null) out.layer = h.layer;
  if (h.scale != null) out.scale = h.scale;
  return out;
}
// Everything placed is "owned": the editor shows the finished room.
function resolveAll(placed) {
  const byId = {}; for (const o of placed) if (!byId[o.id]) byId[o.id] = o;
  const out = new Map(), visiting = new Set();
  function resolve(o) {
    if (out.has(o)) return out.get(o);
    if (visiting.has(o)) return { fields: Object.assign({}, o), home: 0 };
    visiting.add(o);
    const r = { fields: Object.assign({}, o), home: 0 };
    delete r.fields.homes;
    (o.homes || []).some((h, i) => {
      const parent = h.on && byId[h.on];
      if (!parent || parent === o) return false;
      const pr = resolve(parent);
      toWorld(frameOf(pr.fields), h, r.fields);
      r.home = i + 1;
      return true;
    });
    visiting.delete(o);
    out.set(o, r);
    return r;
  }
  for (const o of placed) resolve(o);
  return out;
}

// ── Space model (models/room_space.lua) ────────────────────────────────

function diffY(f) {
  const w = f.w || 1, h = f.h || 1;
  if (f.align === 'left_wall') return w * 8;
  if (f.align === 'right_wall') return h * 8;
  return (w + h) * 8;
}
function floorElev(f) { return (f.z_offset || 0) + diffY(f) * (1 - (f.scale || 1)); }
function faceElev(f, entry) {
  if (!(entry && entry.v === 'face' && entry.height)) return null;
  return floorElev(f) + entry.height * (f.scale || 1);
}
function artToGrid(x, y) { const a = x / (TW / 2), b = y / (TH / 2); return [(a + b) / 2, (b - a) / 2]; }
function gridToArt(gx, gy) { return [(gx - gy) * (TW / 2), (gx + gy) * (TH / 2)]; }
function spriteToGrid(f, geom, u, v, elev) {
  const fr = frameOf(f), sc = f.scale || 1, hf = f.flip_x ? -1 : 1;
  const x = (f.dx || 0) + (u - geom.cell_w / 2) * sc * hf;
  const y = -(f.z_offset || 0) + (v - (geom.bottom - diffY(f))) * sc + elev;
  const [ex, ey] = artToGrid(x, y);
  return [fr.ax + ex, fr.ay + ey];
}
function cornersToPoly(f, geom, list, elev) {
  const poly = [];
  for (const i of [0, 6, 4, 2]) {
    const [gx, gy] = spriteToGrid(f, geom, list[i] + 0.5, list[i + 1] + 0.5, elev);
    poly.push(gx, gy);
  }
  return poly;
}
function wallPlaneOf(f, entry) {
  if (f.align !== 'left_wall' && f.align !== 'right_wall') return null;
  if (entry && entry.v === 'face') return null;
  const fr = frameOf(f);
  if (Math.abs(fr.ay) <= WALL_TOL) return 'back';
  if (Math.abs(fr.ax) <= WALL_TOL) return 'side';
  return null;
}
// A wall thing: a thing that hangs on a wall rather than standing on the
// floor. By the user's say (obj.wall), else by its align, else by what
// the kit's folder says the sprite is (posters, windows, doors, clocks,
// the AC, the corkboard, the Switch, a mirror). Never a thing with a top.
const WALL_FOLDERS = /\/(Poster|Windows|Doors|Clock_Ani)\//;
const WALL_KEYS = /(Office\/AC$|Office\/Corkboard|Consoles\/Nintendo_Switch|Office\/Blueprint|Mirror|Office\/Sticky|Sticky_Note)/;
function wallSprite(key) { return !!key && (WALL_FOLDERS.test(key) || WALL_KEYS.test(key)); }
function isWallKind(f, entry, sk, obj) {
  if (entry && entry.v === 'face') return false;
  if (obj && obj.wall === false) return false;
  if (obj && obj.wall === true) return true;
  if (f.align === 'left_wall' || f.align === 'right_wall') return true;
  return wallSprite(sk && sk.key);
}
// Which level a thing's foot is on, for who it can bump into: the highest
// top under its foot's centre that it is not well below (the laptop on
// the bed, homed or not), else the floor.
function levelKey(d, descs) {
  if (d.wallKind) return 'wall:' + (d.plane || 'none');
  if (!d.foot) return 'floor';
  const [cx, cy] = centroid(d.foot);
  let best = null;
  for (const p of descs) {
    if (p === d || p.isHand || !p.face || p.wallKind) continue;
    if (d.E < p.F - 8 || d.E > p.F + 30) continue;   // its base near the top (hand-tuned heights ride high)
    if (!pointInPoly(p.face, cx, cy, 0.25)) continue;
    if (!best || p.F > best.F) best = p;
  }
  return best ? 'on:' + best.obj.id : 'floor';
}
function wallRect(f, entry, geom, plane) {
  plane = plane || wallPlaneOf(f, entry);
  if (!(plane && geom)) return null;
  const bb = (entry && entry.bbox) || [0, 0, geom.cell_w - 1, geom.bottom - 1];
  const fr = frameOf(f), sc = f.scale || 1, hf = f.flip_x ? -1 : 1, HW = TW / 2;
  const oy = geom.bottom - diffY(f);
  let xa = (f.dx || 0) + (bb[0] - geom.cell_w / 2) * sc * hf;
  let xb = (f.dx || 0) + (bb[2] + 1 - geom.cell_w / 2) * sc * hf;
  if (xa > xb) [xa, xb] = [xb, xa];
  const ya = -(f.z_offset || 0) + (bb[1] - oy) * sc;
  const yb = -(f.z_offset || 0) + (bb[3] + 1 - oy) * sc;
  const r = { plane };
  if (plane === 'back') { r.t0 = fr.ax + xa / HW; r.t1 = fr.ax + xb / HW; r.z1 = xa / 2 - ya; r.z0 = xb / 2 - yb; }
  else { r.t0 = fr.ay - xb / HW; r.t1 = fr.ay - xa / HW; r.z1 = -xb / 2 - ya; r.z0 = -xa / 2 - yb; }
  if (r.z0 > r.z1) [r.z0, r.z1] = [r.z1, r.z0];
  return r;
}
function rectsOverlap(a, b, eps = 1e-6) {
  return a.t0 < b.t1 - eps && b.t0 < a.t1 - eps && a.z0 < b.z1 - eps && b.z0 < a.z1 - eps;
}
function footPoly(f, entry, geom) {
  if (entry && entry.foot && geom) return cornersToPoly(f, geom, entry.foot, floorElev(f));
  const w = f.w || 1, h = f.h || 1;
  if (entry && entry.bbox && geom) {
    // no detected foot (a duck, a headset): a square under the sprite as
    // wide as its silhouette, never wider than its cell, centred where
    // the sprite's bottom middle lands on the floor
    const bw = (entry.bbox[2] + 1 - entry.bbox[0]) * (f.scale || 1);
    const side = Math.min(Math.max(bw / TW, 0.15), Math.max(w, h));
    const [cx, cy] = spriteToGrid(f, geom, geom.cell_w / 2 + (f.dx || 0) * 0, geom.bottom - diffY(f), floorElev(f));
    const hs = side / 2;
    return [cx - hs, cy - hs, cx + hs, cy - hs, cx + hs, cy + hs, cx - hs, cy + hs];
  }
  return [f.gx, f.gy, f.gx + w, f.gy, f.gx + w, f.gy + h, f.gx, f.gy + h];
}
function facePoly(f, entry, geom) {
  const F = faceElev(f, entry);
  if (!(F != null && entry.face && geom)) return null;
  return cornersToPoly(f, geom, entry.face, F);
}
function centroid(p) { let x = 0, y = 0; const n = p.length / 2; for (let i = 0; i < p.length; i += 2) { x += p[i]; y += p[i + 1]; } return [x / n, y / n]; }
function pointInPoly(poly, px, py, tol = 0) {
  const n = poly.length / 2;
  let area = 0;
  for (let i = 0; i < n; i++) { const j = (i + 1) % n; area += poly[i * 2] * poly[j * 2 + 1] - poly[j * 2] * poly[i * 2 + 1]; }
  const sgn = area >= 0 ? 1 : -1;
  for (let i = 0; i < n; i++) {
    const j = (i + 1) % n;
    const ax = poly[i * 2], ay = poly[i * 2 + 1], bx = poly[j * 2], by = poly[j * 2 + 1];
    const ex = bx - ax, ey = by - ay, len = Math.hypot(ex, ey);
    if (len === 0) continue;
    const nx = -ey / len * sgn, ny = ex / len * sgn;
    if ((px - ax) * nx + (py - ay) * ny < -tol) return false;
  }
  return true;
}
function polyInside(inner, outer, tol) {
  for (let i = 0; i < inner.length; i += 2) if (!pointInPoly(outer, inner[i], inner[i + 1], tol)) return false;
  return true;
}
function project(poly, nx, ny) { let lo = Infinity, hi = -Infinity; for (let i = 0; i < poly.length; i += 2) { const d = poly[i] * nx + poly[i + 1] * ny; if (d < lo) lo = d; if (d > hi) hi = d; } return [lo, hi]; }
function polysOverlap(a, b, eps = 1e-6) {
  for (const poly of [a, b]) {
    const n = poly.length / 2;
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n;
      const nx = -(poly[j * 2 + 1] - poly[i * 2 + 1]), ny = poly[j * 2] - poly[i * 2];
      const [alo, ahi] = project(a, nx, ny), [blo, bhi] = project(b, nx, ny);
      if (ahi <= blo + eps || bhi <= alo + eps) return false;
    }
  }
  return true;
}
function nudgeInside(inner, outer, maxShift, tol = 0) {
  const n = outer.length / 2;
  let area = 0;
  for (let i = 0; i < n; i++) { const j = (i + 1) % n; area += outer[i * 2] * outer[j * 2 + 1] - outer[j * 2] * outer[i * 2 + 1]; }
  const sgn = area >= 0 ? 1 : -1;
  let sx = 0, sy = 0;
  for (let i = 0; i < n; i++) {
    const j = (i + 1) % n;
    const ax = outer[i * 2], ay = outer[i * 2 + 1], bx = outer[j * 2], by = outer[j * 2 + 1];
    const ex = bx - ax, ey = by - ay, len = Math.hypot(ex, ey);
    if (len === 0) continue;
    const nx = -ey / len * sgn, ny = ex / len * sgn;
    let worst = 0;
    for (let k = 0; k < inner.length; k += 2) {
      const depth = (inner[k] - ax) * nx + (inner[k + 1] - ay) * ny;
      if (depth < -tol && -depth > worst) worst = -depth;
    }
    if (worst > 0) { sx += nx * worst; sy += ny * worst; }
  }
  if (sx === 0 && sy === 0) return null;
  if (Math.hypot(sx, sy) > (maxShift == null ? Infinity : maxShift)) return null;
  return [sx, sy];
}
function separate(a, b) {
  let best = Infinity, bnx = 0, bny = 0;
  const [ax, ay] = centroid(a), [bx, by] = centroid(b);
  for (const poly of [a, b]) {
    const n = poly.length / 2;
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n;
      const ex = poly[j * 2] - poly[i * 2], ey = poly[j * 2 + 1] - poly[i * 2 + 1], len = Math.hypot(ex, ey);
      if (len === 0) continue;
      let nx = -ey / len, ny = ex / len;
      const [alo, ahi] = project(a, nx, ny), [blo, bhi] = project(b, nx, ny);
      const overlap = Math.min(ahi - blo, bhi - alo);
      if (overlap <= 0) return null;
      if (overlap < best) {
        best = overlap;
        if ((ax - bx) * nx + (ay - by) * ny < 0) { nx = -nx; ny = -ny; }
        bnx = nx; bny = ny;
      }
    }
  }
  if (best === Infinity) return null;
  return [bnx * (best + 1e-4), bny * (best + 1e-4)];
}
function restZ(parentF, parentEntry, childF) {
  const F = faceElev(parentF, parentEntry);
  if (F == null) return null;
  return Math.round(F - diffY(childF) * (1 - (childF.scale || 1)));
}

// ── The editor ─────────────────────────────────────────────────────────

const E = window.editor = {
  placed: [], meta: {}, view: { zoom: 2, x: 0, y: 0 }, snap: true,
  hand: null, press: null, sel: null, hover: null, undo: [], redo: [],
  frame: null, status: '', clashes: [], ready: false, pan: null, target: null, showSpace: false,
};
D.catalogById = {};
let canvas, ctx, needDraw = true;
function dirty() { needDraw = true; }

function roomSize() { return E.meta.room_size || 5; }
function gridToRoom(gx, gy) { return [(gx - gy) * (TW / 2), (gx + gy) * (TH / 2)]; }
function roomToGrid(x, y) { return [(x / (TW / 2) + y / (TH / 2)) * 0.5, (y / (TH / 2) - x / (TW / 2)) * 0.5]; }
function roomToScreen(x, y) { return [E.view.x + x * E.view.zoom, E.view.y + y * E.view.zoom]; }
function screenToRoom(sx, sy) { return [(sx - E.view.x) / E.view.zoom, (sy - E.view.y) / E.view.zoom]; }
// a grid point at elevation elev → room px
function gridElevToRoom(gx, gy, elev) { const [x, y] = gridToRoom(gx, gy); return [x, y - (elev || 0)]; }
function roomToGridAt(x, y, elev) { return roomToGrid(x, y + (elev || 0)); }

function tileSet() { return E.meta.tile_set || D.data.tiles.default_set; }
function courses() { return E.meta.wall_courses || D.data.tiles.default_courses; }
function wallHeightRoom() { const set = tileSet(); const A = D.data.tiles.anchors[String(set)]; return courses() * A.course_px * (64 / set); }

// Entry → the resolved world fields, its sprite, surfaces entry and geometry.
function describe(o, f) {
  const sk = spriteKeyFor(o);
  const entry = surfaceFor(sk);
  const geom = geomFor(sk, entry);
  const d = { obj: o, f, sk, entry, geom, E: floorElev(f), F: faceElev(f, entry) };
  d.wallKind = isWallKind(f, entry, sk, o);
  d.plane = d.wallKind ? wallPlaneOf(f, entry) : null;
  d.foot = d.wallKind ? null : (geom ? footPoly(f, entry, geom) : footPoly(f, null, null));
  d.face = (entry && geom) ? facePoly(f, entry, geom) : null;
  d.wall = d.plane ? wallRect(f, entry, geom, d.plane) : null;
  return d;
}

// The frame: everything resolved, described, sorted, with draw records.
function buildFrame() {
  const list = E.placed.slice();
  let handEntry = null;
  if (E.hand) {
    handEntry = Object.assign({}, E.hand.f, { id: E.hand.id, homes: null, __hand: true });
    list.push(handEntry);
  }
  const res = resolveAll(list);
  const descs = [], byObj = new Map(), onOf = {};
  for (const o of list) {
    const r = res.get(o);
    const f = r.fields;
    const d = describe(o, f);
    d.res = r;
    d.on = r.home > 0 && o.homes ? o.homes[r.home - 1].on : null;
    if (o.__hand) d.isHand = true;
    descs.push(d); byObj.set(o, d); onOf[o.id] = d.on;
  }
  // descendants of the hand ride with it and are never targets
  function isDesc(id, anc) { let cur = onOf[id], g = 0; while (cur && g++ < 64) { if (cur === anc) return true; cur = onOf[cur]; } return false; }
  for (const d of descs) d.ridesHand = !!(E.hand && !d.isHand && isDesc(d.obj.id, E.hand.id));
  for (const d of descs) d.level = levelKey(d, descs);
  // the game's sort: layer, then depth, then z
  const order = descs.slice().sort((a, b) => {
    const la = a.f.layer || 0, lb = b.f.layer || 0;
    if (la !== lb) return la - lb;
    const da = a.f.gx + (a.f.w || 1) * 0.5 + a.f.gy + (a.f.h || 1) * 0.5;
    const db = b.f.gx + (b.f.w || 1) * 0.5 + b.f.gy + (b.f.h || 1) * 0.5;
    if (Math.abs(da - db) < 0.001) return (a.f.z_offset || 0) - (b.f.z_offset || 0);
    return da - db;
  });
  for (const d of order) d.draw = drawRecord(d);
  const fr = { descs, order, byObj, handDesc: handEntry ? byObj.get(handEntry) : null };
  fr.clashes = clashes(descs.filter(d => !d.isHand));
  E.frame = fr;
  return fr;
}

function drawRecord(d) {
  const f = d.f, cv = cellCanvas(d.sk);
  const info = D.data.sprites[d.sk.key];
  d.artMissing = !info || D.images[d.sk.key] === null;
  const cw = cv ? cv.width : (info ? info.cell_w : 32), ch = cv ? cv.height : (info ? info.h : 32);
  const fr = frameOf(f);
  const [ax, ay] = gridToRoom(fr.ax, fr.ay);
  const sc = f.scale || 1;
  const bottom = info ? info.bottoms[Math.min(info.bottoms.length - 1, d.sk.cell)] : ch;
  const ox = cw * 0.5, oy = bottom - diffY(f);
  const px = ax + (f.dx || 0), py = ay - (f.z_offset || 0);
  return { cv, cw, ch, px, py, ox, oy, sc, flip: !!f.flip_x,
           x: px - ox * sc, y: py - oy * sc, w: cw * sc, h: ch * sc };
}

function clashes(descs) {
  const out = [];
  const byId = {}; for (const d of descs) byId[d.obj.id] = d;
  for (let i = 0; i < descs.length; i++) {
    const a = descs[i];
    for (let j = i + 1; j < descs.length; j++) {
      const b = descs[j];
      const related = a.on === b.obj.id || b.on === a.obj.id;
      if (related) continue;
      if (a.foot && b.foot) {
        if (a.level === b.level && polysOverlap(a.foot, b.foot)) out.push({ a, b, kind: 'overlap' });
      } else if (a.wall && b.wall) {
        if (a.wall.plane === b.wall.plane && rectsOverlap(a.wall, b.wall)) out.push({ a, b, kind: 'overlap' });
      }
    }
    const p = a.on && byId[a.on];
    if (p && p.face && a.foot && Math.abs(a.E - p.F) < LEVEL_EPS && !polyInside(a.foot, p.face, INSIDE_TOL)) out.push({ a, b: p, kind: 'overhang' });
  }
  return out;
}

// What is under a screen point: the last-drawn thing whose pixel is there.
function pick(sx, sy, excludeHand) {
  const fr = E.frame; if (!fr) return null;
  const [x, y] = screenToRoom(sx, sy);
  for (let i = fr.order.length - 1; i >= 0; i--) {
    const d = fr.order[i];
    if (excludeHand && (d.isHand || d.ridesHand)) continue;
    const r = d.draw;
    if (x < r.x || x >= r.x + r.w || y < r.y || y >= r.y + r.h) continue;
    let u = (x - r.x) / r.w; const v = (y - r.y) / r.h;
    if (r.flip) u = 1 - u;
    if (alphaAt(d.sk, u, v) > 0.1) return d;
  }
  return null;
}

// Which wall plane a screen point is over (the walls' drawn rectangles).
function wallUnder(sx, sy) {
  const [x, y] = screenToRoom(sx, sy);
  const n = roomSize(), H = wallHeightRoom();
  const polyB = [], polyS = [];
  const [bx0, by0] = gridToRoom(0, 0), [bx1, by1] = gridToRoom(n, 0), [sx1, sy1] = gridToRoom(0, n);
  polyB.push(bx0, by0, bx1, by1, bx1, by1 - H, bx0, by0 - H);
  polyS.push(bx0, by0, sx1, sy1, sx1, sy1 - H, bx0, by0 - H);
  if (pointInPoly(polyB, x, y)) return 'back';
  if (pointInPoly(polyS, x, y)) return 'side';
  return null;
}

// ── The hand ───────────────────────────────────────────────────────────

function snapTo(v, step) { return Math.round(v / step) * step; }

function beginGrab(d, sx, sy) {
  if (d.obj.locked) return false;
  const o = d.obj;
  const idx = E.placed.indexOf(o);
  if (idx < 0) return false;
  const f = Object.assign({}, d.f);
  const fr = frameOf(f);
  const [ax, ay] = gridToRoom(fr.ax, fr.ay);
  const [cx, cy] = screenToRoom(sx, sy);
  // where the anchor sits relative to the pointer, in room px, on the thing's own plane
  const elev = d.wallKind ? 0 : d.E;
  E.hand = {
    kind: 'placed', entry: o, origIdx: idx, id: o.id, f,
    off: { x: ax - cx, y: (ay - (f.z_offset || 0)) - cy },   // anchor DRAW point (with z) relative to the pointer
    satOn: d.on, zNudge: 0, wallKind: d.wallKind, plane: d.plane || (f.align === 'left_wall' ? 'back' : f.align === 'right_wall' ? 'side' : (fr.ay <= fr.ax ? 'back' : 'side')),
    sk: d.sk, entrySurf: d.entry, geom: d.geom,
  };
  if (d.on) {
    const pd = E.frame.descs.find(x => x.obj.id === d.on);
    if (pd && pd.entry) { const rz = restZ(pd.f, pd.entry, f); if (rz != null) E.hand.zNudgeHome = (f.z_offset || 0) - rz; }
  }
  pushUndo();
  E.placed.splice(idx, 1);
  E.sel = null;
  snapshotPending = true;
  return true;
}

function beginNew(spec, sx, sy) {
  const existing = E.placed.find(o => o.id === spec.id);
  if (existing && spec.catalog) {
    const d = E.frame.byObj.get(existing);
    if (d) {
      beginGrab(d, sx, sy);
      const fr = frameOf(E.hand.f);
      E.hand.off = { x: 0, y: 0 };
      return true;
    }
  }
  const f = { gx: 0, gy: 0, w: 1, h: 1, z_offset: 0, dx: 0, layer: 0, scale: 1, flip_x: false, align: null,
              sh: 16, color: [1, 1, 1], frame: spec.frame || undefined };
  const sk = spriteKeyFor({ id: spec.id, sprite: spec.sprite, frame: f.frame });
  const entry = surfaceFor(sk);
  const wk = isWallKind(f, entry, sk, null);
  if (wk) { f.align = 'left_wall'; f.flip_x = true; f.z_offset = 40; }
  E.hand = { kind: 'new', spec, id: spec.id, f, off: { x: 0, y: 0 }, satOn: null, zNudge: 0,
             wallKind: wk, plane: 'back', sk, entrySurf: entry, geom: geomFor(sk, entry) };
  E.sel = null;
  pushUndo();
  snapshotPending = true;
  return true;
}

// Where the hand is for this pointer. Sets E.hand.f and E.target / E.hand.fit.
function updateHand(sx, sy) {
  const h = E.hand; if (!h) return;
  const fr = E.frame;
  const [cx, cy] = screenToRoom(sx, sy);
  const ax = cx + h.off.x, ay = cy + h.off.y;       // the anchor's draw point (room px, z folded in)
  const f = h.f;
  const n = roomSize();
  const snap = E.snap && !keys.alt;
  const under = pick(sx, sy, true);
  E.target = null;
  const fit = { status: 'floor', overlaps: [], parent: null };
  h.fit = fit;
  if (h.wallKind) {
    // on a wall: slide along it and up it
    let plane = wallUnder(sx, sy) || h.plane;
    if (plane !== h.plane) { f.flip_x = !f.flip_x; h.plane = plane; }   // the other wall: the art mirrors
    f.align = plane === 'back' ? 'left_wall' : 'right_wall';
    let t, z;
    if (plane === 'back') { t = ax / (TW / 2); z = ax / 2 - ay; }
    else { t = -ax / (TW / 2); z = -ax / 2 - ay; }
    if (snap) { t = snapTo(t, 0.25); z = snapTo(z, 4); }
    const w = f.w || 1, hh = f.h || 1;
    if (plane === 'back') { t = Math.max(w / 2, Math.min(n - w / 2, t)); f.gx = t - w / 2; f.gy = 0; }
    else { t = Math.max(hh / 2, Math.min(n - hh / 2, t)); f.gy = t - hh / 2; f.gx = 0; }
    f.z_offset = Math.round(z);
    const myRect = wallRect(f, h.entrySurf, h.geom, plane);
    fit.wall = myRect; fit.status = 'wall';
    if (myRect) {
      for (let k = 0; k < 3; k++) {
        const hit = fr.descs.find(d => !d.isHand && !d.ridesHand && d.wall && d.wall.plane === plane && rectsOverlap(d.wall, myRect));
        if (!hit) break;
        const left = myRect.t1 - hit.wall.t0, right = hit.wall.t1 - myRect.t0;
        const push = left < right ? -left : right;
        if (plane === 'back') f.gx += push; else f.gy += push;
        const r2 = wallRect(f, h.entrySurf, h.geom, plane);
        Object.assign(myRect, r2);
      }
      fit.overlaps = fr.descs.filter(d => !d.isHand && !d.ridesHand && d.wall && d.wall.plane === plane && rectsOverlap(d.wall, myRect));
      if (myRect.z1 > wallHeightRoom() + 4) fit.overWall = true;
    }
    E.target = { kind: 'wall', plane };
    return;
  }
  // a floor thing: on the top under the pointer when it has one, else the floor
  let parent = under;
  for (let g = 0; parent && !(parent.face && !parent.wallKind) && g < 8; g++) parent = parent.on ? fr.descs.find(d => d.obj.id === parent.on) || null : null;
  if (parent && parent.isHand) parent = null;
  const [ox, oy] = anchorOffset(f.align, f.w, f.h);
  function placeAt(elev, step) {
    let [gx, gy] = roomToGridAt(ax, ay, elev);      // the anchor on the plane
    if (snap) { gx = snapTo(gx, step); gy = snapTo(gy, step); }
    f.gx = gx - ox; f.gy = gy - oy;
  }
  function foot() { return footPoly(f, h.entrySurf, h.geom); }
  if (parent) {
    const rz = restZ(parent.f, parent.entry, f);
    const nudge = (h.satOn === parent.obj.id ? (h.zNudgeHome || 0) : 0) + h.zNudge;
    f.z_offset = (rz == null ? 0 : rz) + nudge;
    placeAt(parent.F, 0.25);
    let ft = foot();
    const [fcx, fcy] = centroid(ft);
    if (!pointInPoly(parent.face, fcx, fcy, INSIDE_TOL)) {
      const nd = nudgeInside(ft, parent.face, 1.0, INSIDE_TOL);
      if (nd) { f.gx += nd[0]; f.gy += nd[1]; ft = foot(); }
      const [c2x, c2y] = centroid(ft);
      if (!pointInPoly(parent.face, c2x, c2y, INSIDE_TOL)) parent = null;
    }
    if (parent) {
      fit.parent = parent; fit.status = polyInside(ft, parent.face, INSIDE_TOL) ? 'on' : 'overhang';
      E.target = { kind: 'top', desc: parent };
      f.layer = Math.max(f.layer || 0, (parent.f.layer || 0) + 1);
    }
  }
  if (!parent) {
    f.z_offset = h.zNudge;
    placeAt(0, 0.5);
    f.gx = Math.max(0, Math.min(n - (f.w || 1), f.gx));
    f.gy = Math.max(0, Math.min(n - (f.h || 1), f.gy));
  }
  // feet refuse to cross: slide out of a neighbour on this level, by up
  // to three quarters of a cell (further than that it just shows red);
  // on a top never off it; Shift held ignores neighbours altogether
  const myLevel = parent ? 'on:' + parent.obj.id : 'floor';
  fit.level = fr.descs.filter(d => !d.isHand && !d.ridesHand && d.foot && d !== parent && d.level === myLevel);
  const others = keys.shift ? [] : fit.level;
  fit.against = null;
  let slid = 0;
  for (let k = 0; k < 4; k++) {
    const ft = foot();
    const hit = others.find(d => polysOverlap(d.foot, ft));
    if (!hit) break;
    const sep = separate(ft, hit.foot);
    if (!sep) break;
    const len = Math.hypot(sep[0], sep[1]);
    if (slid + len > 0.75) break;
    fit.against = hit;
    const ogx = f.gx, ogy = f.gy;
    f.gx += sep[0]; f.gy += sep[1];
    if (!parent) {
      f.gx = Math.max(0, Math.min(n - (f.w || 1), f.gx));
      f.gy = Math.max(0, Math.min(n - (f.h || 1), f.gy));
    } else {
      const [c2x, c2y] = centroid(foot());
      if (!pointInPoly(parent.face, c2x, c2y, INSIDE_TOL)) { f.gx = ogx; f.gy = ogy; break; }
    }
    slid += len;
  }
  const ftFinal = foot();
  fit.foot = ftFinal;
  fit.overlaps = others.filter(d => polysOverlap(d.foot, ftFinal));
  if (parent) fit.status = polyInside(ftFinal, parent.face, INSIDE_TOL) ? 'on' : 'overhang';
}

function cancelHand() {
  const h = E.hand; if (!h) return false;
  if (h.kind === 'placed') { E.placed.splice(Math.min(h.origIdx, E.placed.length), 0, h.entry); E.sel = h.entry; }
  E.hand = null; E.target = null;
  if (snapshotPending) { E.undo.pop(); snapshotPending = false; }
  dirty(); return true;
}

function uniqueId(base) {
  const taken = new Set(E.placed.map(o => o.id));
  if (!taken.has(base)) return base;
  let n = 2; while (taken.has(base + '_' + n)) n++;
  return base + '_' + n;
}

function dropHand() {
  const h = E.hand; if (!h) return false;
  const fit = h.fit || { status: 'floor' };
  snapshotPending = false;
  let entry = h.entry;
  if (h.kind === 'new') {
    entry = { id: h.spec.catalog ? h.spec.id : uniqueId(h.spec.id), w: 1, h: 1, sh: 16, color: [1, 1, 1], scale: 1, flip_x: false, align: null, dx: 0, layer: 0, z_offset: 0, gx: 0, gy: 0 };
    if (!h.spec.catalog) entry.sprite = h.spec.sprite || h.spec.id;
    if (h.spec.frame) entry.frame = h.spec.frame;
    if (h.f.frame) entry.frame = h.f.frame;
    h.origIdx = E.placed.length;
  }
  E.placed.splice(Math.min(h.origIdx, E.placed.length), 0, entry);
  entry.w = h.f.w || 1; entry.h = h.f.h || 1;
  if (h.wallKind) entry.wall = true; else if (wallSprite(h.sk && h.sk.key)) entry.wall = false; else delete entry.wall;
  const world = { gx: h.f.gx, gy: h.f.gy, z_offset: Math.round(h.f.z_offset || 0), dx: h.f.dx || 0, layer: h.f.layer || 0,
                  align: h.f.align || null, flip_x: !!h.f.flip_x, scale: h.f.scale || 1, w: entry.w, h: entry.h };
  const res = resolveAll(E.placed);
  if (fit.parent) {
    const parent = fit.parent.obj;
    const pr = res.get(parent);
    const home = toLocal(frameOf(pr.fields), world);
    home.on = parent.id;
    const rest = (entry.homes || []).filter(x => x.on !== parent.id);
    entry.homes = [home].concat(rest);
    setStatus(entry.id + ' sits on ' + parent.id);
  } else {
    // on the floor (or a wall): no home may resolve, so what you see is what is written
    const present = new Set(E.placed.map(o => o.id));
    if (entry.homes) {
      entry.homes = entry.homes.filter(x => !present.has(x.on));
      if (!entry.homes.length) delete entry.homes;
    }
    Object.assign(entry, world);
    if (!entry.align) entry.align = null;
    setStatus(entry.id + (h.wallKind ? ' on the ' + h.plane + ' wall' : ' on the floor'));
  }
  E.sel = entry;
  E.hand = null; E.target = null;
  saveDraft();
  dirty();
  return true;
}

// ── Undo ───────────────────────────────────────────────────────────────

let snapshotPending = false;
function deep(x) { return JSON.parse(JSON.stringify(x)); }
function pushUndo() { E.undo.push(deep(E.placed)); if (E.undo.length > 100) E.undo.shift(); E.redo = []; }
function undoStep() { if (!E.undo.length) return false; if (E.hand) cancelHand(); E.redo.push(deep(E.placed)); E.placed = E.undo.pop(); E.sel = null; saveDraft(); dirty(); return true; }
function redoStep() { if (!E.redo.length) return false; if (E.hand) cancelHand(); E.undo.push(deep(E.placed)); E.placed = E.redo.pop(); E.sel = null; saveDraft(); dirty(); return true; }

function edit(fn) { if (!E.sel) return false; pushUndo(); fn(E.sel); saveDraft(); dirty(); renderProps(); return true; }

// Write world fields onto the selection through its active home (the
// parent's frame) or onto its base.
function writeWorld(o, fields) {
  const res = resolveAll(E.placed);
  const r = res.get(o);
  if (r.home > 0 && o.homes && o.homes[r.home - 1]) {
    const h = o.homes[r.home - 1];
    const parent = E.placed.find(p => p.id === h.on);
    const pr = res.get(parent);
    const world = Object.assign({}, r.fields, fields);
    const nh = toLocal(frameOf(pr.fields), world);
    nh.on = h.on;
    o.homes[r.home - 1] = nh;
  } else {
    Object.assign(o, fields);
  }
}

function deleteSel() { if (!E.sel) return false; pushUndo(); E.placed = E.placed.filter(o => o !== E.sel); E.sel = null; saveDraft(); dirty(); renderProps(); return true; }
function duplicateSel() {
  if (!E.sel) return false;
  pushUndo();
  const c = deep(E.sel);
  const base = (c.id.match(/^(.*)_\d+$/) || [])[1] || c.id;
  c.id = uniqueId(base);
  c.sprite = c.sprite || (D.catalogById[E.sel.id] ? (D.catalogById[E.sel.id].sprite || E.sel.id) : base);
  delete c.homes;
  const r = resolveAll(E.placed).get(E.sel).fields;
  Object.assign(c, { gx: r.gx + 0.5, gy: r.gy + 0.5, z_offset: r.z_offset, dx: r.dx, align: r.align || null, flip_x: r.flip_x, scale: r.scale, layer: r.layer, w: r.w, h: r.h });
  E.placed.push(c); E.sel = c; saveDraft(); dirty(); renderProps(); return true;
}

// ── Export (RoomView:layoutString) ─────────────────────────────────────

function q(s) { return JSON.stringify(String(s)); }
function f3(n) { return (Number(n) || 0).toFixed(3); }
function f2(n) { return (Number(n) || 0).toFixed(2); }
function di(n) { return String(Math.round(Number(n) || 0)); }
function pad(s, n) { return s + ' '.repeat(Math.max(0, n - s.length)); }

function layoutString() {
  const m = E.meta, L = [];
  L.push('return {');
  L.push('    __meta = {');
  L.push(`        room_size = ${di(m.room_size || 5)},`);
  L.push(`        floor_theme = ${q(m.floor_theme || 'Default')},`);
  L.push(`        wall_theme = ${q(m.wall_theme || 'Default')},`);
  L.push(`        tile_set = ${di(m.tile_set || D.data.tiles.default_set)},`);
  L.push(`        wall_courses = ${di(m.wall_courses || D.data.tiles.default_courses)},`);
  if (m.floor_flip) L.push('        floor_flip = true,');
  if (m.wall_flip) L.push('        wall_flip = true,');
  const v = m.view || { zoom: 1.9, dy: 0.06 };
  L.push(`        view = { zoom = ${f2(v.zoom)}, dy = ${f2(v.dy)} },`);
  L.push('    },');
  const sorted = E.placed.slice().sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  for (const o of sorted) {
    let s = '';
    if (o.scale != null) s += `, scale = ${f2(o.scale)}`;
    if (o.flip_x) s += ', flip_x = true';
    if (o.align && o.align !== 'center') s += `, align = ${q(o.align)}`;
    if (o.anim_room === false) s += ', anim_room = false'; else if (o.anim_room === true) s += ', anim_room = true';
    if (o.fps) s += `, fps = ${di(o.fps)}`;
    if (o.frame) s += `, frame = ${di(o.frame)}`;
    if (o.shader) s += `, shader = ${q(o.shader)}`;
    if (o.dx) s += `, dx = ${di(o.dx)}`;
    if (o.sprite && o.sprite !== o.id) s += `, sprite = ${q(o.sprite)}`;
    if (o.layer) s += `, layer = ${di(o.layer)}`;
    if (o.hidden_when && o.hidden_when.length) s += `, hidden_when = { ${o.hidden_when.map(q).join(', ')} }`;
    if (o.homes && o.homes.length) {
      const hs = o.homes.map(h => {
        let extra = '';
        if (h.dx) extra += `, dx = ${di(h.dx)}`;
        if (h.flip_x) extra += ', flip_x = true';
        if (h.align && h.align !== 'center') extra += `, align = ${q(h.align)}`;
        extra += `, layer = ${di(h.layer || 0)}, scale = ${f2(h.scale == null ? 1 : h.scale)}`;
        return `{ on = ${q(h.on)}, u = ${f3(h.u)}, v = ${f3(h.v)}, z_offset = ${di(h.z_offset)}, w = ${di(h.w || 1)}, h = ${di(h.h || 1)}${extra}, f = 3 }`;
      });
      s += `, homes = { ${hs.join(', ')} }`;
    }
    const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(o.id) ? o.id : `[${q(o.id)}]`;
    const c = o.color || [1, 1, 1];
    L.push(`    ${pad(key, 20)} = { gx = ${f3(o.gx)}, gy = ${f3(o.gy)}, w = ${di(o.w || 1)}, h = ${di(o.h || 1)}, z_offset = ${di(o.z_offset)}, sh = ${di(o.sh || 16)}, color = { ${f2(c[0])}, ${f2(c[1])}, ${f2(c[2])} }${s} },`);
  }
  L.push('}');
  return L.join('\n');
}

async function save() {
  const body = layoutString();
  try {
    const r = await fetch('/api/save', { method: 'POST', body });
    const j = await r.json();
    if (j.ok) setStatus('saved ' + j.path.replace(/\\/g, '/').split('/').slice(-2).join('/') + (j.moved.length ? ' (old draft moved aside)' : ''));
    else setStatus('save failed: ' + JSON.stringify(j));
    localStorage.removeItem('room_editor_draft');
  } catch (e) { setStatus('save failed: ' + e); }
}

function saveDraft() { try { localStorage.setItem('room_editor_draft', JSON.stringify({ placed: E.placed, at: Date.now() })); } catch (e) {} }

// ── Drawing ────────────────────────────────────────────────────────────

const COL = { bg: '#1b1a17', floorA: '#3a3330', floorB: '#36302c', grid: 'rgba(255,255,255,0.08)', foot: 'rgba(90,200,110,', face: 'rgba(240,195,80,', wall: 'rgba(150,170,210,', bad: 'rgba(230,90,80,', sel: '#f6d36c', hover: 'rgba(255,255,255,0.35)' };

function drawPoly(pts, fill, stroke, lw) {
  ctx.beginPath();
  for (let i = 0; i < pts.length; i += 2) { if (i === 0) ctx.moveTo(pts[i], pts[i + 1]); else ctx.lineTo(pts[i], pts[i + 1]); }
  ctx.closePath();
  if (fill) { ctx.fillStyle = fill; ctx.fill(); }
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = lw || 1 / E.view.zoom; ctx.stroke(); }
}
function gridPolyToRoom(poly, elev) { const out = []; for (let i = 0; i < poly.length; i += 2) { const [x, y] = gridElevToRoom(poly[i], poly[i + 1], elev); out.push(x, y); } return out; }
function wallRectToRoom(r) {
  const pts = [];
  for (const [t, z] of [[r.t0, r.z0], [r.t1, r.z0], [r.t1, r.z1], [r.t0, r.z1]]) {
    const [x, y] = r.plane === 'back' ? gridElevToRoom(t, 0, z) : gridElevToRoom(0, t, z);
    pts.push(x, y);
  }
  return pts;
}

function drawRoom() {
  const dpr = window.devicePixelRatio || 1;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  if (canvas.width !== Math.round(W * dpr) || canvas.height !== Math.round(H * dpr)) { canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = COL.bg; ctx.fillRect(0, 0, W, H);
  ctx.imageSmoothingEnabled = false;
  const Z = E.view.zoom;
  ctx.setTransform(dpr * Z, 0, 0, dpr * Z, dpr * E.view.x, dpr * E.view.y);
  const n = roomSize();
  const tiles = D.data.tiles, set = tileSet(), A = tiles.anchors[String(set)];
  const k = 64 / set;
  // walls
  const wallL = E.meta.wall_theme && E.meta.wall_theme !== 'Default' ? `${tiles.folder.replace('%d', set).replace('%d', set)}Wall_L_${set}_${E.meta.wall_theme}` : null;
  const wallR = wallL ? wallL.replace('Wall_L_', 'Wall_R_') : null;
  const floorK = E.meta.floor_theme && E.meta.floor_theme !== 'Default' ? `${tiles.folder.replace('%d', set).replace('%d', set)}Floor_${set}_${E.meta.floor_theme}` : null;
  const imgL = wallL && loadImage(wallL), imgR = wallR && loadImage(wallR), imgF = floorK && loadImage(floorK);
  const Hw = wallHeightRoom();
  if (imgL && imgL.complete && imgL.naturalWidth && imgR && imgR.complete && imgR.naturalWidth) {
    const flip = !!E.meta.wall_flip;
    const back = flip ? imgL : imgR, side = flip ? imgR : imgL;
    const ba = flip ? A.wall_l : A.wall_r, sa = flip ? A.wall_r : A.wall_l;
    const wsx = flip ? -k : k;
    const cdy = A.course_px * k;
    for (let x = 0; x < n; x++) { const [wx, wy] = gridToRoom(x, 0); for (let lv = 0; lv < courses(); lv++) blit(back, wx, wy - lv * cdy, wsx, k, ba.ox, ba.oy); }
    for (let y = 0; y < n; y++) { const [wx, wy] = gridToRoom(0, y); for (let lv = 0; lv < courses(); lv++) blit(side, wx, wy - lv * cdy, wsx, k, sa.ox, sa.oy); }
  } else {
    const [x0, y0] = gridToRoom(0, 0), [x1, y1] = gridToRoom(n, 0), [x2, y2] = gridToRoom(0, n);
    drawPoly([x0, y0, x1, y1, x1, y1 - Hw, x0, y0 - Hw], '#4a4440', '#5a544e');
    drawPoly([x0, y0, x2, y2, x2, y2 - Hw, x0, y0 - Hw], '#443e3a', '#5a544e');
  }
  // floor
  for (let x = 0; x < n; x++) for (let y = 0; y < n; y++) {
    const [tx, ty] = gridToRoom(x, y);
    if (imgF && imgF.complete && imgF.naturalWidth) blit(imgF, tx, ty, E.meta.floor_flip ? -k : k, k, A.floor.ox, A.floor.oy);
    else { const [bx, by] = gridToRoom(x + 1, y), [cx2, cy2] = gridToRoom(x + 1, y + 1), [dx2, dy2] = gridToRoom(x, y + 1); drawPoly([tx, ty, bx, by, cx2, cy2, dx2, dy2], (x + y) % 2 ? COL.floorB : COL.floorA); }
  }
  if (E.snap) for (let x = 0; x < n; x++) for (let y = 0; y < n; y++) {
    const [tx, ty] = gridToRoom(x, y), [bx, by] = gridToRoom(x + 1, y), [cx2, cy2] = gridToRoom(x + 1, y + 1), [dx2, dy2] = gridToRoom(x, y + 1);
    drawPoly([tx, ty, bx, by, cx2, cy2, dx2, dy2], null, COL.grid);
  }
  // things, in the game's order
  const fr = buildFrame();
  const inClash = new Set(); for (const c of fr.clashes) { inClash.add(c.a); inClash.add(c.b); }
  for (const d of fr.order) {
    const r = d.draw;
    if (!r.cv) { drawPoly([r.x, r.y, r.x + r.w, r.y, r.x + r.w, r.y + r.h, r.x, r.y + r.h], 'rgba(200,60,200,0.3)', '#c040c0'); continue; }
    ctx.save();
    ctx.translate(r.px, r.py);
    ctx.scale(r.flip ? -r.sc : r.sc, r.sc);
    if (d.isHand) ctx.globalAlpha = 1; else if (d.ridesHand) ctx.globalAlpha = 0.9;
    ctx.drawImage(r.cv, -r.ox, -r.oy);
    ctx.restore();
  }
  // clashes at rest: the feet (or wall rectangles) that cross, in red
  if (!E.hand) for (const d of inClash) {
    if (d.foot) drawPoly(gridPolyToRoom(d.foot, d.E), COL.bad + '0.10)', COL.bad + '0.8)');
    else if (d.wall) drawPoly(wallRectToRoom(d.wall), COL.bad + '0.10)', COL.bad + '0.8)');
  }
  // F: the whole space model at rest — every foot, top and wall rectangle
  if (E.showSpace) for (const d of fr.descs) {
    if (d.isHand) continue;
    if (d.foot) drawPoly(gridPolyToRoom(d.foot, d.E), COL.foot + '0.08)', COL.foot + '0.7)');
    if (d.face) drawPoly(gridPolyToRoom(d.face, d.F), COL.face + '0.10)', COL.face + '0.8)');
    if (d.wall) drawPoly(wallRectToRoom(d.wall), COL.wall + '0.10)', COL.wall + '0.8)');
  }
  // the overlay: hover, selection, the hand's foot and target
  const hov = E.hover && !E.hand ? fr.byObj.get(E.hover) : null;
  if (hov) { outline(hov, COL.hover, 1.5); if (hov.foot) drawPoly(gridPolyToRoom(hov.foot, hov.E), null, COL.foot + '0.7)'); if (hov.face) drawPoly(gridPolyToRoom(hov.face, hov.F), COL.face + '0.08)', COL.face + '0.6)'); if (hov.wall) drawPoly(wallRectToRoom(hov.wall), null, COL.wall + '0.8)'); }
  const sel = E.sel ? fr.byObj.get(E.sel) : null;
  if (sel) { outline(sel, COL.sel, 2); if (sel.face) drawPoly(gridPolyToRoom(sel.face, sel.F), COL.face + '0.12)', COL.face + '0.8)'); if (sel.foot) drawPoly(gridPolyToRoom(sel.foot, sel.E), null, COL.foot + '0.8)'); if (sel.wall) drawPoly(wallRectToRoom(sel.wall), COL.wall + '0.12)', COL.wall + '0.8)'); }
  if (E.hand && E.hand.fit) {
    const fit = E.hand.fit, h = E.hand;
    const bad = fit.overlaps.length > 0 || fit.status === 'overhang' || fit.overWall;
    const col = bad ? COL.bad : COL.foot;
    if (E.target && E.target.kind === 'top') drawPoly(gridPolyToRoom(E.target.desc.face, E.target.desc.F), COL.face + '0.28)', COL.face + '1)', 2 / Z);
    if (fit.wall) drawPoly(wallRectToRoom(fit.wall), col + '0.25)', col + '1)', 2 / Z);
    else if (fit.foot) {
      const pts = gridPolyToRoom(fit.foot, floorElev(h.f));
      drawPoly(pts, col + '0.35)', col + '1)', 2 / Z);
      // the drop line: from the foot's centre down to the floor
      if (floorElev(h.f) > 1) { const [cgx, cgy] = centroid(fit.foot); const [tx, ty] = gridElevToRoom(cgx, cgy, floorElev(h.f)); const [bx, by] = gridElevToRoom(cgx, cgy, 0); ctx.strokeStyle = col + '0.7)'; ctx.setLineDash([3 / Z, 3 / Z]); ctx.lineWidth = 1 / Z; ctx.beginPath(); ctx.moveTo(tx, ty); ctx.lineTo(bx, by); ctx.stroke(); ctx.setLineDash([]); }
    }
    for (const d of (fit.level || [])) if (d.foot) drawPoly(gridPolyToRoom(d.foot, d.E), null, COL.foot + '0.35)');
    if (fit.against && fit.against.foot) drawPoly(gridPolyToRoom(fit.against.foot, fit.against.E), COL.foot + '0.18)', COL.foot + '1)', 2 / Z);
    for (const d of fit.overlaps) if (d.foot) drawPoly(gridPolyToRoom(d.foot, d.E), COL.bad + '0.2)', COL.bad + '0.9)');
    if (fr.handDesc) outline(fr.handDesc, bad ? COL.bad + '1)' : 'rgba(255,255,255,0.7)', 1.5);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  renderHud();
}
function blit(img, x, y, sx, sy, ox, oy) {
  ctx.save(); ctx.translate(x, y); ctx.scale(sx, sy); ctx.drawImage(img, -ox, -oy); ctx.restore();
}
function outline(d, col, lw) {
  const r = d.draw;
  ctx.strokeStyle = col; ctx.lineWidth = lw / E.view.zoom;
  ctx.strokeRect(r.x, r.y, r.w, r.h);
}

// ── HUD / DOM ──────────────────────────────────────────────────────────

const $ = s => document.querySelector(s);
function setStatus(s) { E.status = s; const el = $('#status'); if (el) el.textContent = s; }
function renderHud() {
  const fr = E.frame;
  const el = $('#hud');
  if (!el || !fr) return;
  const n = fr.clashes.length;
  el.innerHTML = `<b>${E.placed.length}</b> things · <span class="${n ? 'bad' : ''}">${n} clash${n === 1 ? '' : 'es'}</span> · snap <b>${E.snap ? 'ON' : 'off'}</b> (G, hold Alt) · zoom ${E.view.zoom.toFixed(2)}`
    + (E.hand ? ` · <b>${E.hand.id}</b> ${E.target ? (E.target.kind === 'top' ? 'onto ' + E.target.desc.obj.id : 'on the ' + E.target.plane + ' wall') : 'on the floor'} · layer ${E.hand.f.layer || 0} (Z/X)${E.hand.wallKind ? '' : ' · W: make it a wall thing'}${E.hand.fit && E.hand.fit.against ? ' · against <b>' + E.hand.fit.against.obj.id + '</b>' : ''}${E.hand.fit && E.hand.fit.overlaps.length ? ' <span class="bad">crossing ' + E.hand.fit.overlaps.map(d => d.obj.id).join(', ') + '</span>' : ''}${keys.shift ? ' · <b>free</b> (Shift)' : ''}` : '')
    + (E.hover && !E.hand ? ` · ${E.hover.id}` : '');
}

function renderProps() {
  const el = $('#props'); if (!el) return;
  const o = E.sel;
  if (!o) { el.innerHTML = '<div class="muted">Click a thing to select it. Drag to move. H for the keys.</div>'; return; }
  const fr = E.frame, d = fr && fr.byObj.get(o);
  const f = d ? d.f : o;
  const on = d && d.on ? d.on : (d && d.wallKind ? d.plane + ' wall' : 'the floor');
  const rows = [
    ['id', `<b>${o.id}</b>${o.sprite && o.sprite !== o.id ? '<div class="muted">' + o.sprite + '</div>' : ''}`],
    ['on', on],
    ['z', num('z_offset', f.z_offset, 1)], ['dx', num('dx', f.dx || 0, 1)], ['layer', num('layer', f.layer || 0, 1)],
    ['scale', num('scale', f.scale || 1, 0.05)], ['frame', num('frame', o.frame || 0, 1)],
    ['flip', `<input type=checkbox id=p_flip ${f.flip_x ? 'checked' : ''}>`],
    ['align', `<select id=p_align>${['center', 'left_wall', 'right_wall'].map(a => `<option ${(f.align || 'center') === a ? 'selected' : ''}>${a}</option>`).join('')}</select>`],
    ['size', `w ${num('w', o.w || 1, 1)} h ${num('h', o.h || 1, 1)}`],
    ['locked', `<input type=checkbox id=p_locked ${o.locked ? 'checked' : ''}>`],
    ['wall thing', `<input type=checkbox id=p_wall ${d && d.wallKind ? 'checked' : ''}> <span class=muted>${d && d.wallKind ? (d.plane ? 'on the ' + d.plane + ' wall' : 'off the wall line') : 'stands on the floor'}</span>`],
  ];
  if (o.homes && o.homes.length) rows.push(['homes', o.homes.map((h, i) => `${i + 1}. ${h.on}${d && d.res.home === i + 1 ? ' <b>(active)</b>' : ''}`).join('<br>')]);
  if (o.hidden_when) rows.push(['hidden when', o.hidden_when.join(', ')]);
  el.innerHTML = rows.map(([k, v]) => `<div class=row><span class=k>${k}</span><span class=v>${v}</span></div>`).join('')
    + `<div class=row><button id=p_layer_dn title="X">Layer −</button> <button id=p_layer_up title="Z">Layer +</button> <button id=p_front>Draw last</button> <button id=p_back>Draw first</button></div>`
    + `<div class=row><button id=p_del>Delete</button> <button id=p_dup>Duplicate</button></div>`
    + `<div class="row muted">Drag it to move. R flip · 7/8 height · ←→ nudge · [ ] frame · Shift+wheel scale</div>`;
  function num(name, v, step) { return `<input type=number step=${step} id=p_${name} value="${Number(v).toFixed(step < 1 ? 2 : 0)}">`; }
  for (const name of ['z_offset', 'dx', 'layer', 'scale', 'frame', 'w', 'h']) {
    const inp = $('#p_' + name); if (!inp) continue;
    inp.onchange = () => edit(x => {
      const v = Number(inp.value);
      if (name === 'frame') { if (v >= 1) x.frame = Math.round(v); else delete x.frame; return; }
      if (name === 'w' || name === 'h') { x[name] = Math.max(1, Math.round(v)); return; }
      writeWorld(x, { [name]: name === 'scale' ? v : Math.round(v) });
    });
  }
  $('#p_flip').onchange = () => edit(x => writeWorld(x, { flip_x: $('#p_flip').checked }));
  $('#p_align').onchange = () => edit(x => { const a = $('#p_align').value; writeWorld(x, { align: a === 'center' ? null : a }); });
  $('#p_locked').onchange = () => edit(x => { x.locked = $('#p_locked').checked || undefined; });
  $('#p_wall').onchange = () => edit(x => {
    const on = $('#p_wall').checked;
    const r = resolveAll(E.placed).get(x).fields;
    if (on) {
      const fr2 = frameOf(r);
      const back = fr2.ay <= fr2.ax;
      x.wall = true;
      writeWorld(x, back ? { align: 'left_wall', gy: 0, gx: r.gx } : { align: 'right_wall', gx: 0, gy: r.gy });
    } else { x.wall = false; writeWorld(x, { align: null }); }
  });
  $('#p_layer_up').onclick = () => edit(x => writeWorld(x, { layer: (resolveAll(E.placed).get(x).fields.layer || 0) + 1 }));
  $('#p_layer_dn').onclick = () => edit(x => writeWorld(x, { layer: (resolveAll(E.placed).get(x).fields.layer || 0) - 1 }));
  $('#p_back').onclick = () => edit(x => { E.placed = E.placed.filter(y => y !== x); E.placed.unshift(x); });
  $('#p_del').onclick = deleteSel; $('#p_dup').onclick = duplicateSel;
  $('#p_front').onclick = () => edit(x => { E.placed = E.placed.filter(y => y !== x); E.placed.push(x); });
}

// The shelf: the catalog, then the kit by folder.
function buildShelf() {
  const shelf = $('#shelf'), filter = $('#filter');
  const specs = [];
  for (const it of D.data.catalog) if (!it.hidden && !it.retired && it.id !== 'no_poster_handicap') specs.push({ id: it.id, name: it.name || it.id, sprite: it.sprite, catalog: true, group: 'Catalog', frame: it.frame });
  const keys = Object.keys(D.data.sprites).sort();
  for (const key of keys) {
    if (!(key.startsWith('TinyHouse_0.17(') || key.startsWith('house/'))) continue;
    if (/Floor_Wall_Tiles/.test(key)) continue;
    const clean = key.replace(/^[^/]+\//, '');
    const m = clean.match(/^([^/]+)\/(.+)$/);
    const folder = m ? m[1] : 'Furniture', label = m ? m[2] : clean;
    specs.push({ id: key, name: label, sprite: key, catalog: false, group: folder });
  }
  E.specs = specs;
  const groups = [];
  const byName = {};
  for (const s of specs) { let g = byName[s.group]; if (!g) { g = { name: s.group, items: [], open: s.group === 'Catalog' }; byName[s.group] = g; groups.push(g); } g.items.push(s); }
  E.shelfGroups = groups;
  function render() {
    const q = filter.value.trim().toLowerCase();
    shelf.innerHTML = '';
    for (const g of groups) {
      const items = q ? g.items.filter(s => s.name.toLowerCase().includes(q) || s.id.toLowerCase().includes(q)) : g.items;
      if (!items.length) continue;
      const head = document.createElement('div'); head.className = 'ghead'; head.textContent = `${g.open || q ? '▾' : '▸'} ${g.name} (${items.length})`;
      head.onclick = () => { g.open = !g.open; render(); };
      shelf.appendChild(head);
      if (!(g.open || q)) continue;
      const grid = document.createElement('div'); grid.className = 'ggrid';
      for (const s of items) {
        const cell = document.createElement('div'); cell.className = 'cell'; cell.title = s.id;
        if (s.catalog && E.placed.some(o => o.id === s.id)) cell.classList.add('placed');
        const cv = document.createElement('canvas'); cv.width = 56; cv.height = 56;
        cell.appendChild(cv);
        const lab = document.createElement('div'); lab.className = 'lab'; lab.textContent = s.name; cell.appendChild(lab);
        cell.dataset.spec = specs.indexOf(s);
        cell.onmousedown = ev => { if (ev.button !== 0) return; ev.preventDefault(); E.press = { x: ev.clientX, y: ev.clientY, spec: s, moved: false }; };
        grid.appendChild(cell);
        thumb(cv, s);
      }
      shelf.appendChild(grid);
    }
  }
  filter.oninput = render;
  render();
  E.renderShelf = render;
}
function thumb(cv, s) {
  const sk = spriteKeyFor({ id: s.id, sprite: s.sprite, frame: s.frame });
  const img = loadImage(sk.key);
  const paint = () => {
    const c = cellCanvas(sk); if (!c) return;
    const g = cv.getContext('2d'); g.imageSmoothingEnabled = false;
    const k = Math.min(52 / c.width, 52 / c.height);
    g.clearRect(0, 0, 56, 56);
    g.drawImage(c, (56 - c.width * k) / 2, (56 - c.height * k) / 2, c.width * k, c.height * k);
  };
  if (D.cells[sk.key]) paint(); else if (img) { const prev = img.onload; img.onload = () => { if (prev) prev(); paint(); }; }
}

// ── Input ──────────────────────────────────────────────────────────────

const keys = { alt: false, space: false, shift: false };
let mouse = { x: 0, y: 0 };

function onDown(ev) {
  const r = canvas.getBoundingClientRect();
  const x = ev.clientX - r.left, y = ev.clientY - r.top;
  if (ev.button === 1 || (ev.button === 0 && keys.space) || ev.button === 2 && !E.hand) { E.pan = { x: ev.clientX, y: ev.clientY, vx: E.view.x, vy: E.view.y }; ev.preventDefault(); return; }
  if (ev.button === 2) { if (E.hand) cancelHand(); return; }
  if (ev.button !== 0) return;
  if (E.hand) { dropHand(); renderProps(); E.renderShelf && E.renderShelf(); return; }
  const d = pick(x, y, false);
  E.press = { x: ev.clientX, y: ev.clientY, desc: d, moved: false, cx: x, cy: y };
}
function onMove(ev) {
  const r = canvas.getBoundingClientRect();
  mouse = { x: ev.clientX - r.left, y: ev.clientY - r.top };
  if (E.pan) { E.view.x = E.pan.vx + (ev.clientX - E.pan.x); E.view.y = E.pan.vy + (ev.clientY - E.pan.y); dirty(); return; }
  const p = E.press;
  if (p && !p.moved && (Math.abs(ev.clientX - p.x) > DRAG_PX || Math.abs(ev.clientY - p.y) > DRAG_PX)) {
    p.moved = true;
    if (p.spec) beginNew(p.spec, mouse.x, mouse.y);
    else if (p.desc) beginGrab(p.desc, p.cx, p.cy);
  }
  if (E.hand) { updateHand(mouse.x, mouse.y); dirty(); return; }
  const d = pick(mouse.x, mouse.y, false);
  const h = d ? d.obj : null;
  if (h !== E.hover) { E.hover = h; dirty(); }
}
function onUp(ev) {
  if (E.pan) { E.pan = null; return; }
  const p = E.press; E.press = null;
  if (ev.button !== 0) return;
  if (E.hand) {
    const r = canvas.getBoundingClientRect();
    const inside = ev.clientX >= r.left && ev.clientX < r.right && ev.clientY >= r.top && ev.clientY < r.bottom;
    if (inside) { updateHand(ev.clientX - r.left, ev.clientY - r.top); dropHand(); } else cancelHand();
    renderProps(); E.renderShelf && E.renderShelf();
    return;
  }
  if (p && !p.moved && !p.spec) { E.sel = p.desc ? p.desc.obj : null; renderProps(); dirty(); }
}
function onWheel(ev) {
  ev.preventDefault();
  const r = canvas.getBoundingClientRect();
  const x = ev.clientX - r.left, y = ev.clientY - r.top;
  if (ev.shiftKey && E.sel && !E.hand) {
    edit(o => { const cur = resolveAll(E.placed).get(o).fields.scale || 1; const nv = Math.max(0.1, Math.min(4, cur + (ev.deltaY < 0 ? 0.05 : -0.05))); writeWorld(o, { scale: Number(nv.toFixed(2)) }); });
    return;
  }
  const k = ev.deltaY < 0 ? 1.15 : 1 / 1.15;
  const nz = Math.max(0.5, Math.min(8, E.view.zoom * k));
  const [rx, ry] = screenToRoom(x, y);
  E.view.zoom = nz;
  E.view.x = x - rx * nz; E.view.y = y - ry * nz;
  if (E.hand) updateHand(x, y);
  dirty();
}
function onKey(ev) {
  const tag = (ev.target.tagName || '').toLowerCase();
  if (tag === 'input' || tag === 'select' || tag === 'textarea') { if (ev.key === 'Escape') ev.target.blur(); return; }
  const ctrl = ev.ctrlKey || ev.metaKey;
  if (ev.key === 'Alt') { keys.alt = true; ev.preventDefault(); if (E.hand) { updateHand(mouse.x, mouse.y); dirty(); } return; }
  if (ev.key === 'Shift') { keys.shift = true; if (E.hand) { updateHand(mouse.x, mouse.y); dirty(); } return; }
  if (ev.key === 'f' || ev.key === 'F') { E.showSpace = !E.showSpace; dirty(); return; }
  if (ev.key === ' ') { keys.space = true; ev.preventDefault(); return; }
  if (ev.key === 'Escape') { if (E.hand) cancelHand(); else { E.sel = null; renderProps(); dirty(); } return; }
  if (ctrl && ev.key.toLowerCase() === 'z') { ev.preventDefault(); undoStep(); renderProps(); return; }
  if (ctrl && ev.key.toLowerCase() === 'y') { ev.preventDefault(); redoStep(); renderProps(); return; }
  if (ctrl && ev.key.toLowerCase() === 's') { ev.preventDefault(); save(); return; }
  if (ctrl && ev.key.toLowerCase() === 'd') { ev.preventDefault(); duplicateSel(); return; }
  if (ev.key === 'g' || ev.key === 'G') { E.snap = !E.snap; dirty(); return; }
  if (ev.key === 'h' || ev.key === 'H') { $('#help').classList.toggle('hidden'); return; }
  if (ev.key === 'Delete' || ev.key === 'Backspace') { if (!E.hand) deleteSel(); return; }
  if (E.hand) {
    const h = E.hand;
    if (ev.key === 'r' || ev.key === 'R') h.f.flip_x = !h.f.flip_x;
    else if (ev.key === 'z') h.f.layer = (h.f.layer || 0) + 1;
    else if (ev.key === 'x') h.f.layer = (h.f.layer || 0) - 1;
    else if (ev.key === 'w' || ev.key === 'W') {
      h.wallKind = !h.wallKind;
      if (h.wallKind) { h.plane = wallUnder(mouse.x, mouse.y) || h.plane || 'back'; h.f.align = h.plane === 'back' ? 'left_wall' : 'right_wall'; if (!h.f.z_offset) h.f.z_offset = 40; }
      else { h.f.align = null; h.f.z_offset = 0; }
    }
    else if (ev.key === '7') h.zNudge -= 4; else if (ev.key === '8') h.zNudge += 4;
    else if (ev.key === '[') h.f.frame = Math.max(1, (h.f.frame || 1) - 1); else if (ev.key === ']') h.f.frame = (h.f.frame || 1) + 1;
    else if (ev.key === 'ArrowLeft') h.f.dx = (h.f.dx || 0) - 1; else if (ev.key === 'ArrowRight') h.f.dx = (h.f.dx || 0) + 1;
    else return;
    if (ev.key === '[' || ev.key === ']') { h.sk = spriteKeyFor({ id: h.id, sprite: h.f.sprite || (h.spec && h.spec.sprite), frame: h.f.frame }); h.entrySurf = surfaceFor(h.sk); h.geom = geomFor(h.sk, h.entrySurf); }
    updateHand(mouse.x, mouse.y); dirty(); return;
  }
  if (E.sel) {
    const cur = () => resolveAll(E.placed).get(E.sel).fields;
    if (ev.key === 'r' || ev.key === 'R') return void edit(o => writeWorld(o, { flip_x: !cur().flip_x }));
    if (ev.key === 'z') return void edit(o => writeWorld(o, { layer: (cur().layer || 0) + 1 }));
    if (ev.key === 'x') return void edit(o => writeWorld(o, { layer: (cur().layer || 0) - 1 }));
    if (ev.key === '7') return void edit(o => writeWorld(o, { z_offset: (cur().z_offset || 0) - 4 }));
    if (ev.key === '8') return void edit(o => writeWorld(o, { z_offset: (cur().z_offset || 0) + 4 }));
    if (ev.key === 'ArrowLeft') return void edit(o => writeWorld(o, { dx: (cur().dx || 0) - 1 }));
    if (ev.key === 'ArrowRight') return void edit(o => writeWorld(o, { dx: (cur().dx || 0) + 1 }));
    if (ev.key === '[') return void edit(o => { const n = (o.frame || 1) - 1; if (n >= 1) o.frame = n; else delete o.frame; });
    if (ev.key === ']') return void edit(o => { o.frame = (o.frame || 1) + 1; });
  }
}
function onKeyUp(ev) {
  if (ev.key === 'Alt') { keys.alt = false; if (E.hand) { updateHand(mouse.x, mouse.y); dirty(); } }
  if (ev.key === 'Shift') { keys.shift = false; if (E.hand) { updateHand(mouse.x, mouse.y); dirty(); } }
  if (ev.key === ' ') keys.space = false;
}

// ── Boot ───────────────────────────────────────────────────────────────

function fitView() {
  const W = canvas.clientWidth, H = canvas.clientHeight, n = roomSize();
  const [x0] = gridToRoom(0, n), [x1] = gridToRoom(n, 0);
  const [, y0] = gridToRoom(0, 0), [, y1] = gridToRoom(n, n);
  const roomW = x1 - x0, roomH = y1 - (y0 - wallHeightRoom());
  const Z = Math.max(1, Math.min(4, Math.floor(Math.min(W / (roomW + 80), H / (roomH + 80)) * 4) / 4));
  E.view.zoom = Z;
  E.view.x = W / 2 - ((x0 + x1) / 2) * Z;
  E.view.y = H / 2 - ((y0 - wallHeightRoom() + y1) / 2) * Z;
}

async function boot() {
  canvas = $('#room'); ctx = canvas.getContext('2d');
  const r = await fetch('/api/data'); D.data = await r.json();
  if (D.data.error) { setStatus('data error: ' + D.data.error); return; }
  for (const it of D.data.catalog) D.catalogById[it.id] = it;
  const L = D.data.layout;
  E.meta = L.__meta || {};
  E.placed = [];
  for (const id of Object.keys(L).sort()) {
    if (id === '__meta') continue;
    const info = L[id];
    E.placed.push({ id, sprite: info.sprite || ((id.match(/^(.*)_\d+$/) || [])[1]) || undefined, gx: info.gx || 0, gy: info.gy || 0, w: info.w || 1, h: info.h || 1,
      z_offset: info.z_offset || 0, dx: info.dx || 0, layer: info.layer || 0, sh: info.sh || 16, color: info.color || [1, 1, 1], scale: info.scale == null ? 1 : info.scale,
      flip_x: !!info.flip_x, align: info.align && info.align !== 'center' ? info.align : null, anim_room: info.anim_room, fps: info.fps, frame: info.frame, shader: info.shader,
      hidden_when: info.hidden_when, homes: info.homes, wall: info.wall });
  }
  // a draft from a previous session in this browser
  try {
    const dr = JSON.parse(localStorage.getItem('room_editor_draft') || 'null');
    if (dr && dr.placed && JSON.stringify(dr.placed) !== JSON.stringify(E.placed)) {
      const bar = $('#draftbar'); bar.classList.remove('hidden');
      $('#draft_yes').onclick = () => { pushUndo(); E.placed = dr.placed; bar.classList.add('hidden'); dirty(); E.renderShelf(); };
      $('#draft_no').onclick = () => { localStorage.removeItem('room_editor_draft'); bar.classList.add('hidden'); };
    }
  } catch (e) {}
  buildShelf();
  renderProps();
  fitView();
  canvas.addEventListener('mousedown', onDown);
  window.addEventListener('mousemove', onMove);
  window.addEventListener('mouseup', onUp);
  canvas.addEventListener('wheel', onWheel, { passive: false });
  canvas.addEventListener('contextmenu', ev => ev.preventDefault());
  window.addEventListener('keydown', onKey);
  window.addEventListener('keyup', onKeyUp);
  window.addEventListener('resize', () => dirty());
  $('#save').onclick = save; $('#undo').onclick = () => { undoStep(); renderProps(); }; $('#redo').onclick = () => { redoStep(); renderProps(); };
  $('#snap').onclick = () => { E.snap = !E.snap; dirty(); }; $('#fit').onclick = () => { fitView(); dirty(); };
  $('#helpbtn').onclick = () => $('#help').classList.toggle('hidden');
  $('#export').onclick = () => { const t = $('#exportbox'); t.value = layoutString(); t.classList.toggle('hidden'); };
  E.ready = true;
  setStatus('ready: ' + E.placed.length + ' things');
  (function loop() { if (needDraw) { needDraw = false; drawRoom(); } requestAnimationFrame(loop); })();
}

// for drive.py: the pieces a scripted session needs
Object.assign(E, { pick, updateHand, beginGrab, beginNew, dropHand, cancelHand, undoStep, redoStep, layoutString, buildFrame, drawRoom,
  roomToScreen, screenToRoom, gridToRoom, gridElevToRoom, centroid, resolveAll, frameOf, dirty, fitView, deleteSel, duplicateSel, save,
  centreOf(d, which) {   // screen point: the centre of a thing's face / foot / wall rect / body
    if (which === 'face' && d.face) { const [gx, gy] = centroid(d.face); const [x, y] = gridElevToRoom(gx, gy, d.F); return roomToScreen(x, y); }
    if (which === 'wall' && d.wall) { const r = d.wall; const t = (r.t0 + r.t1) / 2, z = (r.z0 + r.z1) / 2; const [x, y] = r.plane === 'back' ? gridElevToRoom(t, 0, z) : gridElevToRoom(0, t, z); return roomToScreen(x, y); }
    const r = d.draw; return roomToScreen(r.x + r.w / 2, r.y + r.h / 2);
  },
  descOf(id) { return E.frame && E.frame.descs.find(d => d.obj.id === id) || null; },
  bodyPoint(id) {   // a screen point on the thing's own opaque pixels, near its centre
    const d = E.descOf(id); if (!d) return null;
    const r = d.draw;
    for (let ring = 0; ring < 12; ring++) for (let a = 0; a < 16; a++) {
      const u = 0.5 + Math.cos(a / 16 * Math.PI * 2) * ring * 0.04, v = 0.5 + Math.sin(a / 16 * Math.PI * 2) * ring * 0.04;
      if (u < 0 || u > 1 || v < 0 || v > 1) continue;
      const [sx, sy] = roomToScreen(r.x + u * r.w, r.y + v * r.h);
      const p = pick(sx, sy, false);
      if (p && p.obj === d.obj) return [sx, sy];
    }
    return null;
  },
});

window.addEventListener('DOMContentLoaded', boot);
})();
