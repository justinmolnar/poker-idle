// Poker Idle analytics ingest — receives the analytics_<save_id>.json blob
// the game writes locally and upserts it into D1. See ../schema.sql for the
// table shapes. No auth: this is anonymous, opt-in, non-credentialed data
// posted from an itch.io-embedded page, so it's just capped and validated.

const MAX_SHOVES = 500;
const MAX_HANDS_PER_SHOVE = 5000;
const MAX_EVENTS_PER_SHOVE = 2000;
const MAX_SAVE_ID_LEN = 64;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function withCors(resp) {
  for (const [k, v] of Object.entries(CORS_HEADERS)) resp.headers.set(k, v);
  return resp;
}

function bad(msg, status = 400) {
  return withCors(new Response(msg, { status }));
}

// Rebuilds one save's data back into the exact shape HandAnalytics.lua
// writes locally ({ save_id, shoves: [...] }) so it can be dropped straight
// into tools/hand_analytics.html.
async function exportSave(env, save_id) {
  const shoveRows = await env.DB.prepare(
    `SELECT * FROM shoves WHERE save_id = ? ORDER BY shove_count`
  ).bind(save_id).all();

  const shoves = [];
  for (const s of shoveRows.results) {
    const hands = await env.DB.prepare(
      `SELECT t_start, duration, won, delta, tier, stake_id, stake_bb, game_type_id,
              hand_pace_mult, deck_id, prototype, hands_played
       FROM hands WHERE save_id = ? AND shove_count = ? ORDER BY t_start`
    ).bind(save_id, s.shove_count).all();

    const events = await env.DB.prepare(
      `SELECT t, type, item_id, level, cost_dollars, bankroll, cost_chips, chips
       FROM events WHERE save_id = ? AND shove_count = ? ORDER BY t`
    ).bind(save_id, s.shove_count).all();

    shoves.push({
      shove_count: s.shove_count,
      started_at: s.started_at,
      deck_id: s.deck_id,
      catalog_levels: JSON.parse(s.catalog_levels || "{}"),
      run_upgrade_levels: JSON.parse(s.run_upgrade_levels || "{}"),
      shove_rate: {
        r1: s.shove_rate_r1, r2: s.shove_rate_r2, r3: s.shove_rate_r3,
        clear: s.shove_rate_clear, catalog: s.shove_rate_catalog,
        mult: s.shove_rate_mult, bankroll: s.shove_rate_bankroll,
      },
      gauntlet_result: s.gauntlet_result,
      chips_earned: s.chips_earned,
      hands: hands.results.map((h) => ({ ...h, won: !!h.won, prototype: !!h.prototype })),
      events: events.results,
    });
  }

  return { save_id, shoves };
}

// Same reconstruction as exportSave, but for every save in 3 flat queries
// total instead of N+1 per save/shove — this is what powers "load
// everything" from the dashboard without downloading saves one at a time.
async function exportAll(env) {
  const [shoveRows, handRows, eventRows] = await Promise.all([
    env.DB.prepare(`SELECT * FROM shoves ORDER BY save_id, shove_count`).all(),
    env.DB.prepare(
      `SELECT save_id, shove_count, t_start, duration, won, delta, tier, stake_id,
              stake_bb, game_type_id, hand_pace_mult, deck_id, prototype, hands_played
       FROM hands ORDER BY save_id, shove_count, t_start`
    ).all(),
    env.DB.prepare(
      `SELECT save_id, shove_count, t, type, item_id, level, cost_dollars, bankroll, cost_chips, chips
       FROM events ORDER BY save_id, shove_count, t`
    ).all(),
  ]);

  const key = (save_id, shove_count) => save_id + "|" + shove_count;

  const handsByShove = {};
  for (const h of handRows.results) {
    const k = key(h.save_id, h.shove_count);
    (handsByShove[k] ||= []).push({
      t_start: h.t_start, duration: h.duration, won: !!h.won, delta: h.delta,
      tier: h.tier, stake_id: h.stake_id, stake_bb: h.stake_bb,
      game_type_id: h.game_type_id, hand_pace_mult: h.hand_pace_mult,
      deck_id: h.deck_id, prototype: !!h.prototype, hands_played: h.hands_played,
    });
  }

  const eventsByShove = {};
  for (const e of eventRows.results) {
    const k = key(e.save_id, e.shove_count);
    (eventsByShove[k] ||= []).push({
      t: e.t, type: e.type, item_id: e.item_id, level: e.level,
      cost_dollars: e.cost_dollars, bankroll: e.bankroll,
      cost_chips: e.cost_chips, chips: e.chips,
    });
  }

  const savesById = {};
  for (const s of shoveRows.results) {
    const k = key(s.save_id, s.shove_count);
    const save = (savesById[s.save_id] ||= { save_id: s.save_id, shoves: [] });
    save.shoves.push({
      shove_count: s.shove_count,
      started_at: s.started_at,
      deck_id: s.deck_id,
      catalog_levels: JSON.parse(s.catalog_levels || "{}"),
      run_upgrade_levels: JSON.parse(s.run_upgrade_levels || "{}"),
      shove_rate: {
        r1: s.shove_rate_r1, r2: s.shove_rate_r2, r3: s.shove_rate_r3,
        clear: s.shove_rate_clear, catalog: s.shove_rate_catalog,
        mult: s.shove_rate_mult, bankroll: s.shove_rate_bankroll,
      },
      gauntlet_result: s.gauntlet_result,
      chips_earned: s.chips_earned,
      hands: handsByShove[k] || [],
      events: eventsByShove[k] || [],
    });
  }

  return { saves: Object.values(savesById) };
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }));
    }

    if (request.method === "GET") {
      const url = new URL(request.url);
      // Reads are the developer's dashboard, not the game: ?all returns
      // every player's full dataset, so GETs require the token set via
      // `wrangler secret put DASHBOARD_TOKEN`. POST (the game's anonymous,
      // capped upload) stays open.
      const auth = request.headers.get("Authorization") || "";
      const token = url.searchParams.get("token") || auth.replace(/^Bearer\s+/i, "");
      if (!env.DASHBOARD_TOKEN || token !== env.DASHBOARD_TOKEN) {
        return bad("unauthorized", 401);
      }
      const save_id = url.searchParams.get("save_id");

      if (url.searchParams.has("all")) {
        return withCors(Response.json(await exportAll(env)));
      }

      if (!save_id) {
        // No save_id given — list what's available so you know what to ask for.
        const rows = await env.DB.prepare(
          `SELECT save_id, COUNT(*) AS shoves, MAX(received_at) AS last_received
           FROM shoves GROUP BY save_id ORDER BY last_received DESC`
        ).all();
        return withCors(Response.json(rows.results));
      }

      const data = await exportSave(env, save_id);
      const resp = Response.json(data);
      resp.headers.set(
        "Content-Disposition",
        `attachment; filename="analytics_${save_id}.json"`
      );
      return withCors(resp);
    }

    if (request.method !== "POST") {
      return bad("method not allowed", 405);
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return bad("invalid json");
    }

    if (!payload || typeof payload.save_id !== "string" || !Array.isArray(payload.shoves)) {
      return bad("bad payload shape");
    }

    const save_id = payload.save_id.slice(0, MAX_SAVE_ID_LEN);
    const now = Math.floor(Date.now() / 1000);
    const stmts = [];

    for (const shove of payload.shoves.slice(0, MAX_SHOVES)) {
      const shove_count = Number(shove.shove_count);
      if (!Number.isFinite(shove_count)) continue;
      const sr = shove.shove_rate || {};

      stmts.push(
        env.DB.prepare(
          `INSERT INTO shoves (
             save_id, shove_count, started_at, deck_id, catalog_levels, run_upgrade_levels,
             shove_rate_r1, shove_rate_r2, shove_rate_r3, shove_rate_clear, shove_rate_catalog,
             shove_rate_mult, shove_rate_bankroll, gauntlet_result, chips_earned, received_at
           ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(save_id, shove_count) DO UPDATE SET
             started_at=excluded.started_at,
             deck_id=excluded.deck_id,
             catalog_levels=excluded.catalog_levels,
             run_upgrade_levels=excluded.run_upgrade_levels,
             shove_rate_r1=excluded.shove_rate_r1,
             shove_rate_r2=excluded.shove_rate_r2,
             shove_rate_r3=excluded.shove_rate_r3,
             shove_rate_clear=excluded.shove_rate_clear,
             shove_rate_catalog=excluded.shove_rate_catalog,
             shove_rate_mult=excluded.shove_rate_mult,
             shove_rate_bankroll=excluded.shove_rate_bankroll,
             gauntlet_result=excluded.gauntlet_result,
             chips_earned=excluded.chips_earned,
             received_at=excluded.received_at`
        ).bind(
          save_id,
          shove_count,
          shove.started_at ?? null,
          shove.deck_id ?? null,
          JSON.stringify(shove.catalog_levels || {}),
          JSON.stringify(shove.run_upgrade_levels || {}),
          sr.r1 ?? null,
          sr.r2 ?? null,
          sr.r3 ?? null,
          sr.clear ?? null,
          sr.catalog ?? null,
          sr.mult ?? null,
          sr.bankroll ?? null,
          shove.gauntlet_result ?? null,
          shove.chips_earned ?? null,
          now
        )
      );

      for (const h of (shove.hands || []).slice(0, MAX_HANDS_PER_SHOVE)) {
        if (typeof h.t_start !== "number") continue;
        stmts.push(
          env.DB.prepare(
            `INSERT OR REPLACE INTO hands (
               save_id, shove_count, t_start, duration, won, delta, tier, stake_id,
               stake_bb, game_type_id, hand_pace_mult, deck_id, prototype, hands_played
             ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`
          ).bind(
            save_id,
            shove_count,
            h.t_start,
            h.duration ?? null,
            h.won ? 1 : 0,
            h.delta ?? null,
            h.tier ?? null,
            h.stake_id ?? null,
            h.stake_bb ?? null,
            h.game_type_id ?? null,
            h.hand_pace_mult ?? null,
            h.deck_id ?? null,
            h.prototype ? 1 : 0,
            h.hands_played ?? null
          )
        );
      }

      for (const e of (shove.events || []).slice(0, MAX_EVENTS_PER_SHOVE)) {
        if (typeof e.t !== "number" || typeof e.type !== "string") continue;
        stmts.push(
          env.DB.prepare(
            `INSERT OR REPLACE INTO events (
               save_id, shove_count, t, type, item_id, level, cost_dollars,
               bankroll, cost_chips, chips
             ) VALUES (?,?,?,?,?,?,?,?,?,?)`
          ).bind(
            save_id,
            shove_count,
            e.t,
            e.type,
            e.item_id ?? "",
            e.level ?? null,
            e.cost_dollars ?? null,
            e.bankroll ?? null,
            e.cost_chips ?? null,
            e.chips ?? null
          )
        );
      }
    }

    if (stmts.length === 0) {
      return withCors(new Response("ok (nothing to write)"));
    }

    await env.DB.batch(stmts);
    return withCors(new Response("ok"));
  },
};
