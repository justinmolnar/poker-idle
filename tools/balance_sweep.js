#!/usr/bin/env node
/*
 * tools/balance_sweep.js — catalog balance campaign.
 *
 *   cd tools && npm install        (once)
 *   node balance_sweep.js          full sweep  (~minutes)
 *   node balance_sweep.js --quick  s001/s004/s006 only
 *   node balance_sweep.js --refresh-pace   re-derive sec/hand via `lua sim/gtype_ev.lua`
 *
 * Writes tools/balance/out/*.csv and docs/balance-sweep.md.
 *
 * NO FORKED MATH: every $ number is produced by the game's own
 * models/outcome_math.lua running inside fengari through tools/sim_bridge.lua.
 * This script only loops, differences, and applies the fire-rate
 * ASSUMPTIONS below, which are echoed verbatim into the report.
 */
"use strict";
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const REPO = path.resolve(__dirname, "..");
const OUT_DIR = path.join(__dirname, "balance", "out");
const REPORT = path.join(REPO, "docs", "balance-sweep.md");
const QUICK = process.argv.includes("--quick");
const REFRESH_PACE = process.argv.includes("--refresh-pace");

/* ═══════════════════════ ASSUMPTIONS (echoed in the report) ═══════════════════════ */
const A = {
  // Script-only seconds per hand, from sim/gtype_ev.lua runs (±20% by tier mix).
  SEC_PER_HAND: { six_max: 17.0, hu: 6.2, zoom: 2.2, mtt: 18.4 },
  // P(a random cash table has a live, interruptible hand) = (script s)/(total s) × this.
  PHI_LIVE_SCALE: 0.8,
  // Seconds between knockouts per running tournament (data/procs.lua:35-52 says 30-60 s).
  KO_INTERVAL_S: 45,
  // Fraction of a run still ahead when a run-long payload lands (sharp / ratchet).
  RUN_REMAINING_FRACTION: 0.5,
  // Fraction of tilts that land on an already-tilted table (tank_compress's was_refresh gate).
  TILT_REFRESH_FRACTION: 0.15,
  // For AOE (no `pick`) targets: fraction of the other tables inside the radius on a real board.
  AOE_FRACTION: { 1: 0.5, 2: 0.8 },
  // Chips banked per 20-minute run, by act (sim/run.lua:34-57 + data/catalog.lua header).
  CHIPS_PER_RUN: { act1: 18, act1_fight_night: 24, act2: 84 },
  // Reference boards: what a player is actually running when an item fires.
  BOARDS: {
    act1: { fill: "naked",  overhead: 1.5, bankroll: 20,
            tables: [["s001", "zoom"], ["s001", "hu"], ["s002", "six_max"]] },
    act2: { fill: "mid",    overhead: 0.5, bankroll: 5000,
            tables: [["s004", "six_max"], ["s004", "six_max"], ["s004", "hu"],
                     ["s005", "zoom"], ["s005", "six_max"], ["s004", "mtt"]] },
    late: { fill: "capped", overhead: 0.5, bankroll: 500000,
            tables: [["s006", "six_max"], ["s006", "hu"], ["s007", "six_max"], ["s007", "zoom"],
                     ["s006", "zoom"], ["s007", "hu"], ["s006", "mtt"], ["s007", "mtt"]] },
  },
};

/* ═══════════════════════ engine boot (same as the Sim tab) ═══════════════════════ */
const LUA_SEEDS = ["models.poker_effects", "models.outcome_math", "models.shove_rate",
  "services.EffectsRegistry", "utils.lookups", "data.stakes", "data.game_types",
  "data.pot_tiers", "data.bankroll_tiers", "data.constants", "data.mtt_finish_dist",
  "data.mtt_payouts", "data.mtt_hand_count", "data.run_upgrades", "data.effects",
  "data.catalog", "data.catalog_pages", "data.procs", "data.routers", "data.balance"];

function bootEngine() {
  const sources = new Map(); const queue = [...LUA_SEEDS];
  while (queue.length) {
    const mod = queue.pop();
    if (sources.has(mod)) continue;
    const p = path.join(REPO, mod.replace(/\./g, "/") + ".lua");
    if (!fs.existsSync(p)) throw new Error("missing module " + mod);
    const src = fs.readFileSync(p, "utf8");
    sources.set(mod, src);
    for (const m of src.matchAll(/require\(\s*["']([\w.]+)["']\s*\)/g)) queue.push(m[1]);
  }
  sources.set("json", fs.readFileSync(path.join(__dirname, "vendor", "json.lua"), "utf8"));
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  lua.lua_getglobal(L, to_luastring("package"));
  lua.lua_getfield(L, -1, to_luastring("preload"));
  for (const [mod, src] of sources) {
    if (lauxlib.luaL_loadbuffer(L, to_luastring(src), src.length, to_luastring("@" + mod)) !== lua.LUA_OK)
      throw new Error(mod + ": " + to_jsstring(lua.lua_tolstring(L, -1)));
    lua.lua_setfield(L, -2, to_luastring(mod));
  }
  lua.lua_pop(L, 2);
  const bridge = fs.readFileSync(path.join(__dirname, "sim_bridge.lua"), "utf8");
  if (lauxlib.luaL_loadbuffer(L, to_luastring(bridge), bridge.length, to_luastring("@sim_bridge")) !== lua.LUA_OK ||
      lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK)
    throw new Error("bridge: " + to_jsstring(lua.lua_tolstring(L, -1)));
  lua.lua_pop(L, 1);
  return L;
}
const L = bootEngine();
function callBridge(fn, arg) {
  lua.lua_getglobal(L, to_luastring("Bridge"));
  lua.lua_getfield(L, -1, to_luastring(fn));
  lua.lua_remove(L, -2);
  lua.lua_pushstring(L, to_luastring(JSON.stringify(arg)));
  if (lua.lua_pcall(L, 1, 1, 0) !== lua.LUA_OK) {
    const e = to_jsstring(lua.lua_tolstring(L, -1)); lua.lua_pop(L, 1);
    throw new Error(fn + ": " + e);
  }
  const out = to_jsstring(lua.lua_tolstring(L, -1)); lua.lua_pop(L, 1);
  return JSON.parse(out);
}
const INFO = callBridge("info", {});
let evalCount = 0;
function evalBatch(reqs) {
  const out = [];
  for (let i = 0; i < reqs.length; i += 200) {
    const chunk = reqs.slice(i, i + 200);
    evalCount += chunk.length;
    out.push(...callBridge("batch", chunk));
  }
  return out;
}
function evalOne(req) { evalCount++; return callBridge("eval", req); }

/* ═══════════════════════ golden check ═══════════════════════ */
{
  const g = evalOne({ equipped: [], stake_id: "s001", gtype_id: "six_max", opts: {} }).ev_per_hand;
  if (Math.abs(g - 0.320189) > 1e-5) {
    console.error(`GOLDEN DRIFT: naked s001/six_max ev = ${g.toFixed(6)} (was 0.320189). ` +
      "The game's outcome math changed — fine if intentional; update this constant.");
    if (!process.argv.includes("--force")) process.exit(2);
  }
}

/* ═══════════════════════ data helpers ═══════════════════════ */
const STAKES = INFO.stakes.filter(s => s.id !== "s010");   // Ultra excluded from rankings
const STAKE_BY = Object.fromEntries(INFO.stakes.map(s => [s.id, s]));
const GTYPES = INFO.gtypes;
const GT_BY = Object.fromEntries(GTYPES.map(g => [g.id, g]));
const CATALOG = INFO.catalog.filter(c => !c.hidden);
const CAT_BY = Object.fromEntries(INFO.catalog.map(c => [c.id, c]));
const ITEMS = CATALOG.filter(c => c.phase !== "system" && !c.gate);   // ownable
const PROCS = INFO.procs;
const RUN_MINUTES = INFO.balance.RUN_MINUTES || 20;
const K_SHOVE = INFO.balance.K_SHOVE_PER_ITEM || 0.01;
const SWEEP_STAKES = QUICK ? ["s001", "s004", "s006"] : STAKES.map(s => s.id);
const FILLS = ["naked", "mid", "capped"];

if (REFRESH_PACE) {
  try {
    const txt = execSync("lua sim/gtype_ev.lua 12345 live capped s001 20000", { cwd: REPO, encoding: "utf8" });
    for (const g of Object.keys(A.SEC_PER_HAND)) {
      const m = txt.match(new RegExp("^\\s*" + g + "\\s+\\S+\\s+([\\d.]+)", "m"));
      if (m) A.SEC_PER_HAND[g] = Number(m[1]) - (g === "mtt" ? 0 : 0.5); // strip the sim's cursor overhead
    }
    console.log("refreshed SEC_PER_HAND:", JSON.stringify(A.SEC_PER_HAND));
  } catch (e) { console.warn("--refresh-pace failed, using constants: " + e.message); }
}

function fillLevels(stakeId, preset) {
  const fw = STAKE_BY[stakeId].fill_window || { start: 0, complete: 5 };
  let n = 0;
  if (preset === "capped") n = fw.complete;
  else if (preset === "mid") n = Math.round(fw.start + 0.5 * (fw.complete - fw.start));
  return n > 0 ? { sharper_reads: n, pot_control: n } : {};
}
function mkReq(stakeId, gtypeId, opts) {
  opts = opts || {};
  return {
    equipped: opts.equipped || [], corrupted: opts.corrupted || [],
    upgrades: opts.upgrades || {}, extra_effects: opts.extra || undefined,
    stake_id: stakeId, gtype_id: gtypeId,
    transient: { active_tables_count: opts.tables || 1 },
    opts: { bankroll: opts.bankroll || 0, use_focus: !!opts.focus, corner: false },
  };
}
function secPerHand(gtypeId, pace, overhead) {
  return A.SEC_PER_HAND[gtypeId] / (pace || 1) + (gtypeId === "mtt" ? 0 : (overhead || 0));
}
function perHour(r, gtypeId, overhead) {
  return r.ev_per_hand * 3600 / secPerHand(gtypeId, r.hand_pace_mult, overhead);
}
// Stake-independent twin: big blinds per hour. Bands are authored in bb, so
// this is the unit that makes s001 and s006 comparable.
function perHourBB(r, gtypeId, overhead) {
  return r.ev_bb * 3600 / secPerHand(gtypeId, r.hand_pace_mult, overhead);
}
function fmtBB(v, d) { return (v >= 0 ? "+" : "") + v.toFixed(d != null ? d : Math.abs(v) < 1 ? 3 : 1) + "bb"; }
const MODELED_KINDS = new Set(["win_chance_shift", "wc_mult", "earnings_mult", "loss_mult",
  "win_dist_shift", "loss_dist_shift", "win_tier_shift", "loss_tier_shift", "jackpot_mult",
  "tier_bump_chance", "payout_double_chance", "earnings_per_tier", "earnings_scale_by_bankroll",
  "win_tier_floor", "loss_tier_ceiling", "auto_win_chance", "win_chance_fill", "win_dist_fill",
  "loss_dist_fill", "fill_window_widen", "fill_cascade", "run_upgrade_strength_mult",
  "run_upgrade_bonus_levels", "mtt_payout_boost", "focus_capacity_add",
  "focus_penalty_reduce_mult", "focus_penalty_immune", "solo_table_bonus", "corner_win_chance"]);
const THROUGHPUT_KINDS = new Set(["hand_pace_mult", "solo_table_pace"]);
function coverage(effects) {
  const kinds = (effects || []).map(e => e.kind).filter(k => k !== "shove_rate_add");
  if (!kinds.length) return "inert";
  const m = kinds.filter(k => MODELED_KINDS.has(k)).length;
  const t = kinds.filter(k => THROUGHPUT_KINDS.has(k)).length;
  const p = kinds.filter(k => k === "proc" || k === "router").length;
  if (m === kinds.length) return "modeled";
  if (m + t === kinds.length) return "modeled($/hr)";
  if (p === kinds.length) return "proc";
  if (m + t > 0) return "partial";
  return "not modeled";
}
function band(item) {
  if (item.phase === "demo") return "A";
  if (item.act !== 2) return "B";
  return item.phase === "late" ? "D" : "C";
}
const BAND_STAKES_AUTHORED = { A: ["s001", "s002"], B: ["s002", "s003"], C: ["s004", "s005", "s006"], D: ["s004", "s005", "s006", "s007"] };
// Home stakes actually present in this sweep (quick mode lacks s002/s003):
// fall back to the nearest swept stake by ladder index.
const BAND_STAKES = {};
for (const [b, list] of Object.entries(BAND_STAKES_AUTHORED)) {
  const present = list.filter(s => SWEEP_STAKES.includes(s));
  if (present.length) { BAND_STAKES[b] = present; continue; }
  const idx = id => INFO.stakes.findIndex(s => s.id === id);
  const want = idx(list[0]);
  BAND_STAKES[b] = [SWEEP_STAKES.slice().sort((a, c) => Math.abs(idx(a) - want) - Math.abs(idx(c) - want))[0]];
}
function stakeBand(stakeId) { return STAKE_BY[stakeId].band; }
function itemCost(item, variant) {
  if (variant === "corrupt") return item.corrupt ? item.corrupt.cost_achip : null;
  return Math.max(1, Math.floor(item.cost_chip * (RUN_MINUTES / 20) + 0.5));
}
function pct(v, d) { return (v * 100).toFixed(d == null ? 2 : d) + "%"; }
function money(v, d) { const a = Math.abs(v); return (v < 0 ? "-$" : "$") + a.toFixed(d != null ? d : a < 1 ? 4 : a < 100 ? 2 : 0); }
function csv(rows, cols) {
  const esc = v => { const s = v == null ? "" : String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
  return cols.join(",") + "\n" + rows.map(r => cols.map(c => esc(r[c])).join(",")).join("\n") + "\n";
}
function mdTable(header, rows) {
  return "| " + header.join(" | ") + " |\n|" + header.map(() => "---").join("|") + "|\n" +
    rows.map(r => "| " + r.map(v => String(v).replace(/\|/g, "\\|")).join(" | ") + " |").join("\n") + "\n";
}
function median(a) { const s = a.slice().sort((x, y) => x - y); const n = s.length; return n ? (n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2) : 0; }
function stddev(a) { const m = a.reduce((x, y) => x + y, 0) / (a.length || 1); return Math.sqrt(a.reduce((x, y) => x + (y - m) ** 2, 0) / (a.length || 1)); }
const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);

/* ═══════════════════════ Layer 1 — solo sweep (exact) ═══════════════════════ */
log("Layer 1: solo sweep over", SWEEP_STAKES.length, "stakes ×", GTYPES.length, "gtypes ×", FILLS.length, "fills");
const solo = [];   // rows
const variants = [];
for (const it of ITEMS) {
  variants.push({ item: it, variant: "base", equipped: [it.id], corrupted: [] });
  if (it.corrupt) variants.push({ item: it, variant: "corrupt", equipped: [it.id], corrupted: [it.id] });
}
const baselineCache = {};  // key stake/gtype/fill -> response
for (const stakeId of SWEEP_STAKES) for (const g of GTYPES) for (const fill of FILLS) {
  const up = fillLevels(stakeId, fill);
  const base = evalOne(mkReq(stakeId, g.id, { upgrades: up }));
  baselineCache[`${stakeId}/${g.id}/${fill}`] = base;
  const reqs = variants.map(v => mkReq(stakeId, g.id, { equipped: v.equipped, corrupted: v.corrupted, upgrades: up }));
  const res = evalBatch(reqs);
  res.forEach((r, i) => {
    if (r.err) return;
    const v = variants[i];
    const dev = r.ev_per_hand - base.ev_per_hand;
    const dhr = perHour(r, g.id, 1.0) - perHour(base, g.id, 1.0);
    const dbb = r.ev_bb - base.ev_bb;
    const dbbhr = perHourBB(r, g.id, 1.0) - perHourBB(base, g.id, 1.0);
    const cost = itemCost(v.item, v.variant) || 1;
    solo.push({
      id: v.item.id, name: v.item.name, variant: v.variant, band: band(v.item), cost,
      coverage: coverage(v.variant === "corrupt" ? v.item.corrupt.effects : v.item.effects),
      stake: stakeId, stake_band: stakeBand(stakeId), gtype: g.id, fill,
      base_ev: base.ev_per_hand, base_ev_bb: base.ev_bb, ev: r.ev_per_hand, d_ev: dev, d_hr: dhr, d_hr_per_chip: dhr / cost,
      d_bb: dbb, d_bbhr: dbbhr, d_bbhr_per_chip: dbbhr / cost,
      d_stack: r.stack_pct - base.stack_pct, d_wc: r.wc - base.wc,
      rel: base.ev_per_hand !== 0 ? dev / Math.abs(base.ev_per_hand) : 0,
    });
  });
}
log("Layer 1 done:", solo.length, "rows,", evalCount, "evals");

/* ═══════════════════════ Layer 2 — pair synergy (exact) ═══════════════════════ */
log("Layer 2: pair synergy");
const modeledItems = ITEMS.filter(it => /^modeled/.test(coverage(it.effects)));
const pairs = [];
for (let i = 0; i < modeledItems.length; i++) for (let j = i + 1; j < modeledItems.length; j++) pairs.push([modeledItems[i], modeledItems[j]]);
const pairRows = [];
const PAIR_STAKES = QUICK ? ["s001", "s004"] : ["s001", "s004", "s006"];
for (const stakeId of PAIR_STAKES) for (const g of GTYPES) for (const fill of ["naked", "capped"]) {
  const up = fillLevels(stakeId, fill);
  const base = baselineCache[`${stakeId}/${g.id}/${fill}`] || evalOne(mkReq(stakeId, g.id, { upgrades: up }));
  const singles = {};
  const sres = evalBatch(modeledItems.map(it => mkReq(stakeId, g.id, { equipped: [it.id], upgrades: up })));
  modeledItems.forEach((it, i) => { singles[it.id] = perHourBB(sres[i], g.id, 1.0) - perHourBB(base, g.id, 1.0); });
  const pres = evalBatch(pairs.map(([a, b]) => mkReq(stakeId, g.id, { equipped: [a.id, b.id], upgrades: up })));
  pairs.forEach(([a, b], i) => {
    if (pres[i].err) return;
    const both = perHourBB(pres[i], g.id, 1.0) - perHourBB(base, g.id, 1.0);
    const syn = both - singles[a.id] - singles[b.id];
    const denom = Math.abs(singles[a.id]) + Math.abs(singles[b.id]) || 1e-9;
    pairRows.push({ a: a.id, b: b.id, stake: stakeId, gtype: g.id, fill, d_a: singles[a.id], d_b: singles[b.id],
      d_both: both, synergy: syn, synergy_rel: syn / denom });
  });
}
log("Layer 2 done:", pairRows.length, "rows,", evalCount, "evals");

/* ═══════════════════════ board evaluation helper ═══════════════════════ */
function boardStats(boardName, equipped, corrupted) {
  const B = A.BOARDS[boardName];
  const n = B.tables.length;
  const reqs = B.tables.map(([s, g]) => mkReq(s, g, { equipped, corrupted, upgrades: fillLevels(s, B.fill),
    tables: n, focus: true, bankroll: B.bankroll }));
  const res = evalBatch(reqs);
  const tables = res.map((r, i) => {
    const [s, g] = B.tables[i];
    const sec = secPerHand(g, r.hand_pace_mult, B.overhead);
    const script_sec = A.SEC_PER_HAND[g] / (r.hand_pace_mult || 1);
    return Object.assign({ stake: s, gtype: g, isMtt: g === "mtt", sec, hands_hr: 3600 / sec,
      phi: g === "mtt" ? 0 : (script_sec / sec) * A.PHI_LIVE_SCALE,
      dollars_hr: r.ev_per_hand * 3600 / sec }, r);
  });
  return { name: boardName, n, tables, focus_mult: res[0] && res[0].focus_mult != null ? res[0].focus_mult : 1,
    dollars_hr: tables.reduce((a, t) => a + t.dollars_hr, 0) };
}

/* ═══════════════════════ Layer 3 — build trajectories (exact) ═══════════════════════ */
log("Layer 3: build trajectories");
function requiresOk(item, owned) { return !item.requires || owned.has(item.requires) || !CAT_BY[item.requires]; }
function orderCheapest() {
  const owned = new Set(); const order = [];
  const pool = ITEMS.slice();
  while (order.length < ITEMS.length) {
    const cands = pool.filter(it => !owned.has(it.id) && requiresOk(it, owned))
      .sort((a, b) => itemCost(a) - itemCost(b) || ITEMS.indexOf(a) - ITEMS.indexOf(b));
    if (!cands.length) break;
    owned.add(cands[0].id); order.push(cands[0]);
  }
  return order;
}
function orderAuthored() {
  const order = []; const seen = new Set(); const owned = new Set();
  const flat = INFO.pages.flatMap(p => p.items || []).map(id => CAT_BY[id]).filter(c => c && ITEMS.includes(c));
  for (const it of ITEMS) if (!flat.includes(it)) flat.push(it);
  // authored order, but an item whose parent hasn't been reached waits for it
  const deferred = [];
  const tryPush = it => { if (seen.has(it.id)) return; if (!requiresOk(it, owned)) { deferred.push(it); return; }
    seen.add(it.id); owned.add(it.id); order.push(it);
    for (const d of deferred.splice(0)) tryPush(d); };
  for (const it of flat) tryPush(it);
  for (const d of deferred) if (!seen.has(d.id)) { seen.add(d.id); order.push(d); }
  return order;
}
function orderGreedy(boardName) {
  const owned = new Set(); const order = [];
  let cur = boardStats(boardName, [], []).dollars_hr;
  while (order.length < ITEMS.length) {
    const cands = ITEMS.filter(it => !owned.has(it.id) && requiresOk(it, owned));
    if (!cands.length) break;
    let best = null, bestScore = -Infinity, bestHr = cur;
    for (const it of cands) {
      const hr = boardStats(boardName, [...owned, it.id], []).dollars_hr;
      const score = (hr - cur) / itemCost(it);
      if (score > bestScore) { bestScore = score; best = it; bestHr = hr; }
    }
    owned.add(best.id); order.push(best); cur = bestHr;
  }
  return order;
}
const trajRows = [];
function trajectory(name, order) {
  const owned = [];
  let chips = 0;
  let step = 0;
  // baseline row
  const b1 = boardStats("act1", [], []).dollars_hr, b2 = boardStats("act2", [], []).dollars_hr;
  trajRows.push({ order: name, step: 0, item: "(none)", cost: 0, cum_chips: 0, hr_act1: b1, hr_act2: b2, shove_t3: 0 });
  for (const it of order) {
    owned.push(it.id); chips += itemCost(it); step++;
    const s1 = boardStats("act1", owned, []).dollars_hr;
    const s2 = boardStats("act2", owned, []).dollars_hr;
    trajRows.push({ order: name, step, item: it.id, cost: itemCost(it), cum_chips: chips,
      hr_act1: s1, hr_act2: s2, shove_t3: Math.min(0.99, K_SHOVE * owned.length * 3) });
  }
}
trajectory("cheapest_first", orderCheapest());
trajectory("authored_pages", orderAuthored());
if (!QUICK) trajectory("greedy_per_chip_act2", orderGreedy("act2"));
log("Layer 3 done,", evalCount, "evals");

/* ═══════════════════════ Layer 4 — run upgrades vs items ═══════════════════════ */
log("Layer 4: run upgrades");
const upgRows = [];
for (const stakeId of SWEEP_STAKES) {
  const fw = STAKE_BY[stakeId].fill_window || { complete: 5 };
  for (const g of GTYPES) {
    for (const u of INFO.upgrades.filter(x => x.fill_scaled)) {
      let prev = evalOne(mkReq(stakeId, g.id, { upgrades: {} }));
      let prevHr = perHour(prev, g.id, 1.0);
      const maxL = Math.min(fw.complete, u.max_level);
      for (let lvl = 1; lvl <= maxL; lvl++) {
        const r = evalOne(mkReq(stakeId, g.id, { upgrades: { [u.id]: lvl } }));
        const hr = perHour(r, g.id, 1.0);
        const cost = (u.costs || [])[lvl - 1] || 0;
        const d = hr - prevHr;
        upgRows.push({ stake: stakeId, gtype: g.id, upgrade: u.id, level: lvl, cost, d_hr: d,
          d_hr_per_dollar: cost > 0 ? d / cost : null, payback_hours: d > 0 ? cost / d : null,
          below_window: lvl <= (fw.start || 0), ev_per_hand: r.ev_per_hand, hr });
        prev = r; prevHr = hr;
      }
    }
  }
}
log("Layer 4 done,", evalCount, "evals");

/* ═══════════════════════ Layer 5 — proc-driven items (estimated) ═══════════════════════ */
log("Layer 5: proc estimates");
function boardRates(bs) {
  const cash = bs.tables.filter(t => !t.isMtt);
  const mtts = bs.tables.filter(t => t.isMtt);
  const hands_won = bs.tables.reduce((a, t) => a + t.hands_hr * t.wc, 0);
  const hands_played = bs.tables.reduce((a, t) => a + t.hands_hr, 0);
  const jackpot_wins = cash.reduce((a, t) => a + t.hands_hr * t.wc * (t.wd.jackpot || 0), 0);
  const stack_losses = cash.reduce((a, t) => a + t.hands_hr * (1 - t.wc) * (t.ld.jackpot || 0), 0);
  const stack_losses_six = cash.filter(t => t.gtype === "six_max")
    .reduce((a, t) => a + t.hands_hr * (1 - t.wc) * (t.ld.jackpot || 0), 0);
  const ko = mtts.length * 3600 / A.KO_INTERVAL_S;
  let tourney_wins = 0, tourney_misses = 0, tournaments = 0;
  for (const t of mtts) {
    const per_hr = 3600 / (t.mtt.exp_hands * t.sec);
    tournaments += per_hr;
    const pp = t.mtt.pos_probs || [];
    tourney_wins += per_hr * (pp[0] || 0);
    tourney_misses += per_hr * pp.slice(3).reduce((a, b) => a + b, 0);
  }
  // the_tilt (granted at start): tilt arrivals from cooler_tilt (six_max stack loss → r1 neighbor)
  // and miss_tilt (tournament miss → AOE r1). Landing on a random other table.
  const tilt_arrivals = stack_losses_six + tourney_misses * A.AOE_FRACTION[1] * Math.max(0, bs.n - 1);
  const six_share = cash.filter(t => t.gtype === "six_max").length / Math.max(1, bs.n - 1);
  return { hands_won, hands_played, jackpot_wins, stack_losses, stack_losses_six, ko, tournaments, tourney_wins, tourney_misses,
    tilt_arrivals, tilts_on_six: tilt_arrivals * six_share, n_cash: cash.length, n_mtt: mtts.length, six_share };
}
function heaterValue(t) { return t.isMtt ? 0 : (1 - t.wc) * (t.w_cash + t.l_cash) + t.phi * (1 - t.wc) * t.w_cash; }
function tiltValue(t)   { return t.isMtt ? 0 : -((t.wc) * (t.w_cash + t.l_cash) + t.phi * t.wc * t.w_cash); }
function avgOver(tables, fn) { const v = tables.map(fn); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : 0; }
function extraDelta(bs, table, extra) {
  const B = A.BOARDS[bs.name];
  const r = evalOne(mkReq(table.stake, table.gtype, { upgrades: fillLevels(table.stake, B.fill),
    tables: bs.n, focus: true, bankroll: B.bankroll, extra }));
  return r.ev_per_hand - table.ev_per_hand;
}
function payloadValue(proc, bs, rates) {
  // returns { per_fire, note }
  const p = proc.payload || {};
  const tgt = proc.target || {};
  const cash = bs.tables.filter(t => !t.isMtt);
  const others = bs.tables;
  let targets;
  if (tgt.kind === "self") targets = null;
  else if (tgt.kind === "gtype") targets = bs.tables.filter(t => t.gtype === tgt.gtype);
  else if (tgt.kind === "none") targets = [];
  else targets = tgt.where && tgt.where.chip_stack_table === false ? cash : others;
  const aoeMult = (tgt.kind === "board_near" && !tgt.pick) ? (A.AOE_FRACTION[tgt.radius || 1] || 0.5) * Math.max(1, bs.n - 1) : 1;
  const avgT = fn => targets === null ? null : avgOver(targets, fn) * aoeMult;
  switch (p.kind) {
    case "apply_status": {
      if (p.status === "heater") {
        if (targets === null) return { per_fire: avgOver(cash, heaterValue), note: "heater on self (avg cash table)" };
        if (tgt.kind === "gtype") return { per_fire: targets.reduce((a, t) => a + heaterValue(t), 0), note: `heater on every ${tgt.gtype}` };
        return { per_fire: avgT(heaterValue), note: aoeMult > 1 ? `heater AOE ≈${aoeMult.toFixed(1)} tables` : "heater on a random table" };
      }
      if (p.status === "tilt") {
        if (targets === null) return { per_fire: avgOver(cash, tiltValue), note: "tilt on self" };
        return { per_fire: avgT(tiltValue), note: aoeMult > 1 ? `tilt AOE ≈${aoeMult.toFixed(1)} tables` : "tilt on a random table" };
      }
      if (p.status === "marked" || p.status === "stacked_mark") {
        const fn = t => t.isMtt ? 0 : extraDelta(bs, t, [{ kind: "tier_bump_chance", value: 1 }]);
        const v = targets === null ? avgOver(cash, fn) : avgT(fn);
        return { per_fire: v, note: "one pot bumped a tier (both sides; via engine)" };
      }
      if (p.status === "sharp") {
        const mag = p.magnitude || 0.005;
        const extra = [["small", "medium"], ["medium", "large"], ["large", "jackpot"]]
          .map(([f, to]) => ({ kind: "win_tier_shift", from: f, to, chance: mag }));
        const hands_left = t => t.hands_hr * (RUN_MINUTES / 60) * A.RUN_REMAINING_FRACTION;
        const fn = t => t.isMtt ? 0 : extraDelta(bs, t, extra) * hands_left(t);
        const v = targets === null ? avgOver(cash.filter(t => t.gtype === "six_max"), fn)
          : targets.reduce((a, t) => a + fn(t), 0);
        return { per_fire: v, note: `sharp +${mag} for the rest of the run (${A.RUN_REMAINING_FRACTION} run left)` };
      }
      return { per_fire: 0, note: "unknown status " + p.status };
    }
    case "ratchet": {
      const eff = Object.assign({}, p.effect || { kind: "win_chance_shift" });
      eff[eff.mag_field || "amount"] = p.magnitude; delete eff.mag_field;
      const v = bs.tables.reduce((a, t) => a + (t.isMtt ? 0 : extraDelta(bs, t, [eff]) * t.hands_hr * (RUN_MINUTES / 60) * A.RUN_REMAINING_FRACTION), 0);
      return { per_fire: v, note: `+${p.magnitude} ${eff.kind} on every table for the rest of the run` };
    }
    case "refund_buyin": {
      const v = avgOver(cash, t => (p.chance || 1) * t.buy_in);
      return { per_fire: v, note: "buy-in refunded on a random cash table" };
    }
    case "pay_biggest_buyin": return { per_fire: Math.max(...bs.tables.map(t => t.buy_in)), note: "pays the biggest open buy-in" };
    case "resolve_now": {
      const zoom = cash.filter(t => t.gtype === "zoom");
      const v = zoom.reduce((a, t) => a + t.phi * 0.5 * t.ev_per_hand, 0);
      return { per_fire: v, note: "zoom tables settle now: ≈half a hand of time compression each (rough)" };
    }
    case "cleanse": return { per_fire: 0.1 * Math.abs(avgOver(cash, t => t.wc * (t.w_cash + t.l_cash))), note: "≈0.1 active tilts cleared (rough)" };
    case "timed_buff": return { per_fire: 0, note: "cursor speed ×2 for 10 s: throughput only, unvalued" };
    case "bank": return { per_fire: 0, note: "banks sharp for later zoom tables — folded into millennium" };
    default: return { per_fire: 0, note: "payload " + p.kind + " unvalued" };
  }
}
function fireRate(proc, rates) {
  const c = proc.chance != null ? proc.chance : 1;
  switch (proc.trigger) {
    case "on_hand_won": return proc.every ? rates.hands_won / proc.every * c : rates.hands_won * c;
    case "on_hand_played": return proc.every ? rates.hands_played / proc.every * c : rates.hands_played * c;
    case "on_jackpot_win": return rates.jackpot_wins * c;
    case "on_stack_loss": return (proc.source && proc.source.gtype === "six_max" ? rates.stack_losses_six : rates.stack_losses) * c;
    case "on_ko": return rates.ko * c;
    case "on_tournament_win": return rates.tourney_wins * c;
    case "on_tournament_miss": return rates.tourney_misses * c;
    case "on_tilt_spent": return rates.tilt_arrivals * c;
    case "on_status_applied": {
      let r = rates.tilt_arrivals;
      if (proc.source && proc.source.gtype === "six_max") r = rates.tilts_on_six;
      if (proc.when && proc.when.was_refresh) r *= A.TILT_REFRESH_FRACTION;
      return r * c;
    }
    default: return 0;
  }
}
const procRows = [];
const boardCache = {};
for (const bname of Object.keys(A.BOARDS)) {
  const bs = boardStats(bname, [], []);
  boardCache[bname] = bs;
  const rates = boardRates(bs);
  for (const it of CATALOG) {
    for (const variant of ["base", "corrupt"]) {
      const effects = variant === "corrupt" ? (it.corrupt && it.corrupt.effects) : it.effects;
      if (!effects) continue;
      const procIds = effects.filter(e => e.kind === "proc").map(e => e.proc);
      if (!procIds.length) continue;
      for (const pid of procIds) {
        const proc = PROCS[pid];
        if (!proc) { procRows.push({ board: bname, item: it.id, variant, proc: pid, err: "unknown proc" }); continue; }
        const fires = fireRate(proc, rates);
        const pv = payloadValue(proc, bs, rates);
        const hr = fires * pv.per_fire * bs.focus_mult;
        procRows.push({ board: bname, item: it.id, name: it.name, variant, proc: pid, trigger: proc.trigger,
          every: proc.every || "", chance: proc.chance != null ? proc.chance : 1,
          target: (proc.target || {}).kind, payload: (proc.payload || {}).kind + ((proc.payload || {}).status ? ":" + proc.payload.status : ""),
          fires_hr: fires, per_fire: pv.per_fire, est_hr: hr, note: pv.note,
          cost: itemCost(it, variant), est_hr_per_chip: hr / (itemCost(it, variant) || 1),
          board_hr: bs.dollars_hr });
      }
    }
  }
}
log("Layer 5 done,", evalCount, "evals");

/* ═══════════════════════ analysis + flags ═══════════════════════ */
// Per item: best scenario, band-relative score, coverage.
const itemSummary = [];
for (const it of ITEMS) {
  for (const variant of ["base", "corrupt"]) {
    const rows = solo.filter(r => r.id === it.id && r.variant === variant);
    if (!rows.length) continue;
    const best = rows.reduce((a, r) => (r.d_bbhr_per_chip > a.d_bbhr_per_chip ? r : a), rows[0]);
    const home = rows.filter(r => BAND_STAKES[band(it)].includes(r.stake));
    // Per game type, the median over home stakes × fills; the item's home score
    // is its BEST game type (so a Heads-Up-only item isn't zeroed by 3 other gtypes).
    const perG = GTYPES.map(g => ({ g: g.id, med: median(home.filter(r => r.gtype === g.id).map(r => r.d_bbhr_per_chip)) }));
    const bestG = perG.reduce((a, x) => (x.med > a.med ? x : a), perG[0] || { g: "?", med: 0 });
    const homeMed = bestG.med;
    const homeGtype = bestG.g;
    const homeAllMed = median(home.map(r => r.d_bbhr_per_chip));
    const homeBest = home.reduce((a, r) => Math.max(a, r.d_bbhr_per_chip), -Infinity);
    const procEst = procRows.filter(r => r.item === it.id && r.variant === variant);
    const procHr = { act1: 0, act2: 0, late: 0 };
    for (const r of procEst) procHr[r.board] += r.est_hr || 0;
    itemSummary.push({ id: it.id, name: it.name, variant, band: band(it), cost: itemCost(it, variant),
      coverage: coverage(variant === "corrupt" ? it.corrupt.effects : it.effects),
      best_stake: best.stake, best_gtype: best.gtype, best_fill: best.fill, best_d_hr: best.d_hr, best_d_hr_per_chip: best.d_hr_per_chip,
      best_d_bbhr: best.d_bbhr, best_d_bbhr_per_chip: best.d_bbhr_per_chip,
      home_median_bbhr_per_chip: homeMed, home_gtype: homeGtype, home_allgtype_median: homeAllMed, home_best_bbhr_per_chip: homeBest,
      home_median_d_hr_per_chip: median(home.map(r => r.d_hr_per_chip)),
      proc_hr_act1: procHr.act1, proc_hr_act2: procHr.act2, proc_hr_late: procHr.late,
      hr_per_chip_act1: (procHr.act1 + (solo.find(r => r.id === it.id && r.variant === variant && r.stake === "s001" && r.gtype === "six_max" && r.fill === "naked") || { d_hr: 0 }).d_hr) / (itemCost(it, variant) || 1) });
  }
}

const flags = [];
// OP within band (base variants, home stakes, per gtype) — one row per item
const opHits = {};
for (const b of ["A", "B", "C", "D"]) for (const g of GTYPES) {
  const rows = solo.filter(r => r.variant === "base" && r.band === b && r.gtype === g.id && BAND_STAKES[b].includes(r.stake) && /^modeled/.test(r.coverage));
  const vals = rows.map(r => r.d_bbhr_per_chip);
  if (vals.length < 4) continue;
  const med = median(vals), sd = stddev(vals);
  for (const r of rows) if (r.d_bbhr_per_chip > med + 2 * sd && r.d_bbhr_per_chip > 0)
    (opHits[r.id] = opHits[r.id] || []).push({ r, med, sd, sigma: (r.d_bbhr_per_chip - med) / (sd || 1) });
}
for (const [id, hits] of Object.entries(opHits)) {
  hits.sort((x, y) => y.sigma - x.sigma);
  const top = hits[0];
  flags.push({ kind: "OP", item: id, evidence: `${hits.length} scenario(s) >2σ over its band median; strongest ${top.r.gtype} ${top.r.stake}/${top.r.fill}: ${fmtBB(top.r.d_bbhr)}/hr for ${top.r.cost} chips = ${fmtBB(top.r.d_bbhr_per_chip)}/hr/chip vs median ${fmtBB(top.med)} (+${top.sigma.toFixed(1)}σ). Also: ${hits.slice(1, 4).map(h => `${h.r.gtype} ${h.r.stake}/${h.r.fill}`).join(", ") || "—"}` });
}
// negative at home: modeled item whose median home-band Δ is below zero somewhere it should help
for (const s of itemSummary.filter(x => x.variant === "base" && /^modeled/.test(x.coverage))) {
  const home = solo.filter(r => r.id === s.id && r.variant === "base" && BAND_STAKES[s.band].includes(r.stake));
  const neg = home.filter(r => r.d_bbhr < -1e-6);
  if (neg.length >= Math.max(2, home.length * 0.25)) {
    const worst = neg.reduce((a, r) => (r.d_bbhr < a.d_bbhr ? r : a), neg[0]);
    flags.push({ kind: "negative-home", item: s.id, evidence: `hurts in ${neg.length}/${home.length} home-band scenarios; worst ${worst.gtype} ${worst.stake}/${worst.fill}: ${fmtBB(worst.d_bbhr)}/hr (tier bumps / shifts apply to the loss side too)` });
  }
}
// corrupt >5× base
for (const it of ITEMS.filter(i => i.corrupt)) {
  const b = solo.filter(r => r.id === it.id && r.variant === "base"), c = solo.filter(r => r.id === it.id && r.variant === "corrupt");
  const bb = median(b.map(r => r.d_bbhr)), cc = median(c.map(r => r.d_bbhr));
  if (bb > 0 && cc > 5 * bb) flags.push({ kind: "OP(corrupt)", item: it.id, evidence: `corrupt median Δ ${fmtBB(cc)}/hr vs base ${fmtBB(bb)}/hr (×${(cc / bb).toFixed(1)})` });
  if (bb > 0 && cc < 0) flags.push({ kind: "corrupt-negative", item: it.id, evidence: `corrupt median Δ ${fmtBB(cc)}/hr is net-negative EV while base is ${fmtBB(bb)}/hr (may be the intended risk trade)` });
}
// weak modeled
for (const s of itemSummary.filter(x => x.variant === "base" && /^modeled/.test(x.coverage))) {
  const bandRows = itemSummary.filter(x => x.variant === "base" && x.band === s.band && /^modeled/.test(x.coverage));
  const med = median(bandRows.map(x => x.home_median_bbhr_per_chip));
  if (med > 0 && s.home_median_bbhr_per_chip < 0.25 * med)
    flags.push({ kind: "weak", item: s.id, evidence: `home-band median ${fmtBB(s.home_median_bbhr_per_chip)}/hr/chip vs band median ${fmtBB(med)} (${pct(s.home_median_bbhr_per_chip / med, 0)})` });
  if (s.best_d_bbhr <= 1e-9) flags.push({ kind: "zero", item: s.id, evidence: "no positive Δ in any scenario (needs context the sweep doesn't supply: corner slot / table count / upgrade cap)" });
}
// misplaced: best scenario's stake band differs from authored band
for (const s of itemSummary.filter(x => x.variant === "base" && /^modeled/.test(x.coverage) && x.best_d_bbhr > 0)) {
  const sb = stakeBand(s.best_stake);
  if (sb !== "low" && (s.band === "A" || s.band === "B")) {
    const homeBest = s.home_best_bbhr_per_chip;
    if (homeBest > 0 && s.best_d_bbhr_per_chip / homeBest > 3)
      flags.push({ kind: "misplaced-late", item: s.id, evidence: `authored band ${s.band} but bb/hr-per-chip at ${s.best_stake}/${s.best_gtype}/${s.best_fill} (${fmtBB(s.best_d_bbhr_per_chip)}) is ${(s.best_d_bbhr_per_chip / homeBest).toFixed(1)}× its home-band best (${fmtBB(homeBest)})` });
    else if (homeBest <= 0)
      flags.push({ kind: "misplaced-late", item: s.id, evidence: `authored band ${s.band} but contributes nothing at its home stakes; first pays at ${s.best_stake}/${s.best_gtype}/${s.best_fill} (${fmtBB(s.best_d_bbhr)}/hr)` });
  }
  const capOnly = solo.filter(r => r.id === s.id && r.variant === "base" && BAND_STAKES[s.band].includes(r.stake));
  const naked = capOnly.filter(r => r.fill === "naked").map(r => r.d_bbhr), capped = capOnly.filter(r => r.fill === "capped").map(r => r.d_bbhr);
  if ((s.band === "A" || s.band === "B") && median(naked) <= 1e-6 && median(capped) > 0)
    flags.push({ kind: "capped-only", item: s.id, evidence: `Act-1 item that pays nothing naked (median ${fmtBB(median(naked))}/hr) but ${fmtBB(median(capped))}/hr at capped fill` });
}
// identity check: gtype-scoped items
for (const it of ITEMS) {
  const scoped = (it.effects || []).filter(e => e.gtype).map(e => e.gtype);
  if (!scoped.length) continue;
  const named = scoped[0];
  const byG = {};
  for (const g of GTYPES) byG[g.id] = median(solo.filter(r => r.id === it.id && r.variant === "base" && r.gtype === g.id).map(r => r.d_bbhr));
  const bestG = Object.keys(byG).reduce((a, k) => (byG[k] > byG[a] ? k : a), named);
  if (bestG !== named && byG[bestG] > 1e-9) flags.push({ kind: "identity", item: it.id, evidence: `names ${named} but Δbb/hr is larger at ${bestG} (${fmtBB(byG[bestG])} vs ${fmtBB(byG[named])})` });
}
// synergy outliers
const synAgg = {};
for (const r of pairRows) { const k = r.a + "+" + r.b; (synAgg[k] = synAgg[k] || []).push(r); }
const synSummary = Object.entries(synAgg).map(([k, rows]) => ({ pair: k, mean_syn: rows.reduce((a, r) => a + r.synergy, 0) / rows.length,
  max_syn: Math.max(...rows.map(r => r.synergy)), min_syn: Math.min(...rows.map(r => r.synergy)),
  mean_rel: rows.reduce((a, r) => a + r.synergy_rel, 0) / rows.length }));
synSummary.sort((a, b) => b.mean_rel - a.mean_rel);

/* ═══════════════════════ outputs ═══════════════════════ */
fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(path.join(OUT_DIR, "solo.csv"), csv(solo, ["id", "name", "variant", "band", "cost", "coverage", "stake", "stake_band", "gtype", "fill", "base_ev", "base_ev_bb", "ev", "d_ev", "d_hr", "d_hr_per_chip", "d_bb", "d_bbhr", "d_bbhr_per_chip", "d_stack", "d_wc", "rel"]));
fs.writeFileSync(path.join(OUT_DIR, "pairs.csv"), csv(pairRows, ["a", "b", "stake", "gtype", "fill", "d_a", "d_b", "d_both", "synergy", "synergy_rel"]));
fs.writeFileSync(path.join(OUT_DIR, "trajectories.csv"), csv(trajRows, ["order", "step", "item", "cost", "cum_chips", "hr_act1", "hr_act2", "shove_t3"]));
fs.writeFileSync(path.join(OUT_DIR, "upgrades.csv"), csv(upgRows, ["stake", "gtype", "upgrade", "level", "cost", "d_hr", "d_hr_per_dollar", "payback_hours", "below_window", "ev_per_hand", "hr"]));
fs.writeFileSync(path.join(OUT_DIR, "procs.csv"), csv(procRows, ["board", "item", "name", "variant", "proc", "trigger", "every", "chance", "target", "payload", "fires_hr", "per_fire", "est_hr", "cost", "est_hr_per_chip", "board_hr", "note"]));
fs.writeFileSync(path.join(OUT_DIR, "items.csv"), csv(itemSummary, ["id", "name", "variant", "band", "cost", "coverage", "best_stake", "best_gtype", "best_fill", "best_d_hr", "best_d_hr_per_chip", "best_d_bbhr", "best_d_bbhr_per_chip", "home_median_bbhr_per_chip", "home_gtype", "home_allgtype_median", "home_best_bbhr_per_chip", "home_median_d_hr_per_chip", "proc_hr_act1", "proc_hr_act2", "proc_hr_late"]));

/* ── report ── */
const R = [];
R.push(`# Catalog balance sweep`);
R.push(`> Generated by \`tools/balance_sweep.js\` on ${new Date().toISOString().slice(0, 16).replace("T", " ")}${QUICK ? " (--quick)" : ""}. Do not hand-edit — rerun the script. ${evalCount.toLocaleString()} engine evaluations in ${((Date.now() - t0) / 1000).toFixed(0)} s. Every $ figure comes from the game's own \`models/outcome_math.lua\` via \`tools/sim_bridge.lua\`; this script only loops and differences.\n`);
R.push(`## How to read this\n`);
R.push(`- **Δ$/hr** = $/hour with the item minus without it, one table, no focus penalty, hands/hour from the sec/hand table below. **Δ$/hr per chip** divides by the item's derived chip cost (corrupt variants: by anti-chip cost).`);
R.push(`- **Confidence tiers**: *modeled* (analytic, exact given the engine) · *modeled($/hr)* (pace only) · *proc* (Layer 5 estimate: fires/hour × value per fire, assumptions below) · *partial* · *not modeled* (economy / cursors / one-shots — listed, not scored).`);
R.push(`- Stakes: ${SWEEP_STAKES.join(", ")}. Fills: naked (no upgrades), mid (half the stake's fill window), capped (window complete). Ultra excluded from rankings.\n`);
R.push(`### Assumptions (edit at the top of the script)\n`);
R.push(mdTable(["constant", "value", "meaning"], [
  ["SEC_PER_HAND", JSON.stringify(A.SEC_PER_HAND), "script seconds per hand (sim/gtype_ev.lua); ÷ hand_pace_mult + cursor overhead"],
  ["PHI_LIVE_SCALE", A.PHI_LIVE_SCALE, "P(live interruptible hand) = script/total seconds × this — the heater/tilt interrupt half"],
  ["KO_INTERVAL_S", A.KO_INTERVAL_S, "seconds between knockouts per running tournament"],
  ["RUN_REMAINING_FRACTION", A.RUN_REMAINING_FRACTION, "run left when a run-long payload (sharp, ratchet) lands"],
  ["TILT_REFRESH_FRACTION", A.TILT_REFRESH_FRACTION, "share of tilts landing on an already-tilted table"],
  ["AOE_FRACTION", JSON.stringify(A.AOE_FRACTION), "share of other tables inside radius r for AOE (no-pick) targets"],
  ["CHIPS_PER_RUN", JSON.stringify(A.CHIPS_PER_RUN), "chips banked per 20-min run by act"],
]));
R.push(`Reference boards (procs are valued on these):\n`);
R.push(mdTable(["board", "fill", "overhead s", "bankroll", "tables", "board $/hr (naked catalog)"],
  Object.entries(A.BOARDS).map(([n, b]) => [n, b.fill, b.overhead, "$" + b.bankroll, b.tables.map(t => t.join("/")).join(", "), money(boardCache[n].dollars_hr)])));

// Layer 0 — baseline EV by stake × gtype × fill (no items). Read this first.
R.push(`\n## 0 · Baseline EV without items (ev in bb/hand · win chance) — read this first\n`);
R.push(`Negative cells mean the table loses money at that stake and fill level before any catalog item. Items are valued as deltas on top of these.\n`);
for (const fill of FILLS) {
  R.push(`**${fill}**\n`);
  R.push(mdTable(["stake", ...GTYPES.map(g => g.id)], SWEEP_STAKES.map(st => [st, ...GTYPES.map(g => {
    const b = baselineCache[`${st}/${g.id}/${fill}`]; if (!b) return "—";
    return g.id === "mtt" ? `${fmtBB(b.ev_bb, 2)} · ROI ${b.mtt.roi_pct.toFixed(0)}%` : `${fmtBB(b.ev_bb, 2)} · wc ${pct(b.wc, 0)}`;
  })])));
}
R.push(`Units note: the leaderboards below use **bb/hour per chip** so stakes are comparable (a big blind is 1000× larger at s006 than s001; raw $ deltas are in the CSVs).\n`);

// Flags
R.push(`\n## Flags\n`);
if (!flags.length) R.push("_No heuristic flags fired._\n");
else {
  const order = ["OP", "OP(corrupt)", "negative-home", "corrupt-negative", "misplaced-late", "capped-only", "identity", "weak", "zero"];
  flags.sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind) || a.item.localeCompare(b.item));
  R.push(mdTable(["flag", "item", "evidence"], flags.map(f => [f.kind, `**${f.item}** (${CAT_BY[f.item].name})`, f.evidence])));
}
R.push(`\n### Code findings (from the exploration that preceded this sweep — not changed by the script)\n`);
R.push(`- \`data/statuses.lua\`: heater and tilt have \`effects = {}\`; their \`magnitude\` and \`t\` are inert everywhere except tilt's visual lean. So \`ko_heater.escalate\` (busted_total × 0.12) and every authored \`t = 4/5/6/8\` do nothing.`);
R.push(`- \`controllers/GrindController.lua\` gates bounty / cascade / jackpot counters on \`not r.flipped\`: a heater-manufactured jackpot never pays a {chip} and never triggers on_jackpot_win procs.`);
R.push(`- \`data/balance.lua\`: \`ACT1_ITEM_COUNT = 67\` is the whole catalog, but it feeds \`ITEMS_AT_WIN\` and sim/run.lua's Act-1 completion % (Act 1 = bands A+B = 33 items). \`catalog_loader.chipsPerRun\` defaults \`act1_spend = 111\` vs the 237 the header sums.`);
R.push(`- \`data/run_upgrades.lua\` header says the full lineup costs "$38M cumulative"; the arrays now sum to ~$85B for Pot Control alone.`);
R.push(`- \`every = N\` procs count lifetime wins across all tables and never reset on prestige (ProcRegistry:123 reads \`state.total_hands_won\`).\n`);

// Layer 1 leaderboard
R.push(`## 1 · Solo value — per-chip leaderboard (base variants, home-band stakes, best scenario)\n`);
const lead = itemSummary.filter(s => s.variant === "base" && s.best_d_bbhr > 0).sort((a, b) => b.home_median_bbhr_per_chip - a.home_median_bbhr_per_chip);
R.push(`Home score = median Δbb/hr-per-chip over the item's home-band stakes × fills, at its best game type (so a Heads-Up-only item is judged at Heads-Up).\n`);
R.push(mdTable(["#", "item", "band", "cost", "coverage", "home score (bb/hr/chip)", "at", "home stakes", "best scenario", "best Δbb/hr", "best Δ$/hr"],
  lead.map((s, i) => [i + 1, `${s.name} \`${s.id}\``, s.band, s.cost, s.coverage, fmtBB(s.home_median_bbhr_per_chip), s.home_gtype, BAND_STAKES[s.band].join("/"), `${s.best_stake}/${s.best_gtype}/${s.best_fill}`, fmtBB(s.best_d_bbhr), money(s.best_d_hr)])));
R.push(`\n### Items with no analytic signal (proc / economy / one-shot)\n`);
const noSig = itemSummary.filter(s => s.variant === "base" && s.best_d_bbhr <= 1e-9);
R.push(noSig.map(s => `\`${s.id}\` (${s.coverage}${s.proc_hr_act2 ? `, proc est. ${money(s.proc_hr_act2)}/hr on act2 board` : ""})`).join(" · ") + "\n");

// per gtype × stake matrix for modeled items at capped fill (compact): show d_hr at s001/s004/s006 capped six_max & hu
R.push(`\n### Δbb/hr by scenario (base variants, capped fill)\n`);
const showStakes = ["s001", "s004", "s006"].filter(s => SWEEP_STAKES.includes(s));
const cols = []; for (const s of showStakes) for (const g of GTYPES) cols.push(`${s}/${g.id}`);
R.push(mdTable(["item", ...cols], lead.map(s => [`\`${s.id}\``, ...cols.map(c => { const [st, g] = c.split("/"); const r = solo.find(x => x.id === s.id && x.variant === "base" && x.stake === st && x.gtype === g && x.fill === "capped"); return r ? fmtBB(r.d_bbhr) : "—"; })])));

// corrupt vs base
R.push(`\n### Corrupt vs base (median Δbb/hr over all scenarios)\n`);
const cvb = ITEMS.filter(i => i.corrupt).map(it => {
  const b = median(solo.filter(r => r.id === it.id && r.variant === "base").map(r => r.d_bbhr));
  const c = median(solo.filter(r => r.id === it.id && r.variant === "corrupt").map(r => r.d_bbhr));
  return { row: [`\`${it.id}\``, fmtBB(b), fmtBB(c), b > 0 ? "×" + (c / b).toFixed(1) : "—", itemCost(it), it.corrupt.cost_achip], keep: Math.abs(b) > 1e-9 || Math.abs(c) > 1e-9 };
}).filter(x => x.keep).map(x => x.row);
R.push(mdTable(["item", "base Δbb/hr", "corrupt Δbb/hr", "ratio", "chips", "anti"], cvb));

// Layer 2
R.push(`\n## 2 · Pair synergy (modeled items; ${PAIR_STAKES.join("/")} × all gtypes × naked/capped)\n`);
R.push(`synergy = Δ(A+B) − Δ(A) − Δ(B) in bb/hr; rel = synergy ÷ (|ΔA|+|ΔB|).\n`);
R.push(`**Strongest positive**\n\n` + mdTable(["pair", "mean rel", "mean bb/hr", "max bb/hr"], synSummary.slice(0, 12).map(s => [s.pair, pct(s.mean_rel, 1), fmtBB(s.mean_syn), fmtBB(s.max_syn)])));
R.push(`**Strongest negative (anti-synergy / redundancy)**\n\n` + mdTable(["pair", "mean rel", "mean bb/hr", "min bb/hr"], synSummary.slice(-8).reverse().map(s => [s.pair, pct(s.mean_rel, 1), fmtBB(s.mean_syn), fmtBB(s.min_syn)])));

// Layer 3
R.push(`\n## 3 · Build trajectories ($/hr on the act1 and act2 boards vs chips spent)\n`);
for (const name of [...new Set(trajRows.map(r => r.order))]) {
  const rows = trajRows.filter(r => r.order === name);
  const marks = [0, 50, 100, 200, 300, 400, 600, 800];
  R.push(`**${name}** — ` + marks.map(m => { const r = rows.filter(x => x.cum_chips <= m).pop(); return r ? `${m}c: ${money(r.hr_act1, 2)} / ${money(r.hr_act2, 0)}` : null; }).filter(Boolean).join(" · ") + `\n`);
  R.push(`first 12: ` + rows.slice(1, 13).map(r => `${r.item}(${r.cost})`).join(" → ") + "\n");
}
R.push(`(act1 board $/hr shown first, act2 second, at cumulative chip marks; full curves in trajectories.csv)\n`);

// Layer 4
R.push(`\n## 4 · Run upgrades — payback per level (hours of play at one table to recoup the level's cost)\n`);
R.push(`"·" = level sits below this stake's fill window (it was bought for a lower stake and adds nothing here); "∞" = the level's Δ is zero or negative at this table.\n`);
for (const u of INFO.upgrades.filter(x => x.fill_scaled)) {
  R.push(`**${u.name}**\n`);
  const rows = [];
  for (const st of showStakes) {
    for (const g of ["six_max", "hu"]) {
      const r = upgRows.filter(x => x.stake === st && x.gtype === g && x.upgrade === u.id);
      rows.push([`${st}/${g}`, ...r.slice(0, 11).map(x => x.below_window ? "·" : x.payback_hours == null ? "∞" : x.payback_hours < 100 ? x.payback_hours.toFixed(1) + "h" : ">100h")]);
    }
  }
  R.push(mdTable(["stake/gtype", ...Array.from({ length: 11 }, (_, i) => "L" + (i + 1))], rows));
}
R.push(`Chips↔time frame: Act 1 ≈ ${A.CHIPS_PER_RUN.act1} chips per ${RUN_MINUTES}-min run (${(A.CHIPS_PER_RUN.act1 * 60 / RUN_MINUTES).toFixed(0)}/hr); Act 2 ≈ ${A.CHIPS_PER_RUN.act2}/run (${(A.CHIPS_PER_RUN.act2 * 60 / RUN_MINUTES).toFixed(0)}/hr). A 10-chip item is ~${(10 / A.CHIPS_PER_RUN.act1 * RUN_MINUTES).toFixed(0)} min of Act-1 grinding.\n`);

// Layer 5
R.push(`\n## 5 · Proc-driven items — estimated $/hr on each reference board\n`);
R.push(`Estimate = fires/hour × value per fire × board focus multiplier. Heater value/fire = (1−wc)(W+L) forced-hand half + φ(1−wc)W interrupt half; tilt is the mirror. Marked/sharp/ratchet payloads are valued by re-running the engine with the payload's effect injected (\`extra_effects\`). Rough rows are marked in the note.\n`);
for (const bname of Object.keys(A.BOARDS)) {
  const rows = procRows.filter(r => r.board === bname && !r.err).sort((a, b) => b.est_hr - a.est_hr);
  R.push(`**${bname} board** (${money(boardCache[bname].dollars_hr)}/hr baseline, focus ×${boardCache[bname].focus_mult.toFixed(2)})\n`);
  R.push(mdTable(["item", "variant", "proc", "trigger", "fires/hr", "value/fire", "est Δ$/hr", "per chip", "note"],
    rows.map(r => [`\`${r.item}\``, r.variant, r.proc, `${r.trigger}${r.every ? " every " + r.every : ""}${r.chance !== 1 ? " ×" + r.chance : ""}`, r.fires_hr.toFixed(2), money(r.per_fire), money(r.est_hr), money(r.est_hr_per_chip), r.note])));
}
R.push(`\n_Not valued at all (economy / cursor / one-shot kinds): ` + ITEMS.filter(i => coverage(i.effects) === "not modeled").map(i => `\`${i.id}\``).join(", ") + "._\n");

fs.writeFileSync(REPORT, R.join("\n"));
log("wrote", REPORT, "and", OUT_DIR, "—", evalCount.toLocaleString(), "evals");
