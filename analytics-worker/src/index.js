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
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function withCors(resp) {
  for (const [k, v] of Object.entries(CORS_HEADERS)) resp.headers.set(k, v);
  return resp;
}

function bad(msg, status = 400) {
  return withCors(new Response(msg, { status }));
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }));
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
