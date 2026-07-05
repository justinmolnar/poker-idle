-- Poker Idle analytics — one row per (save_id, shove_count[, key]).
-- Clients resend the whole current shove's JSON on every flush, so every
-- insert upserts on its natural key instead of accumulating duplicates.

CREATE TABLE IF NOT EXISTS shoves (
  save_id             TEXT NOT NULL,
  shove_count         INTEGER NOT NULL,
  started_at          INTEGER,
  deck_id             TEXT,
  catalog_levels      TEXT,   -- JSON object
  run_upgrade_levels  TEXT,   -- JSON object
  shove_rate_r1       REAL,
  shove_rate_r2       REAL,
  shove_rate_r3       REAL,
  shove_rate_clear    REAL,
  shove_rate_catalog  REAL,
  shove_rate_mult     REAL,
  shove_rate_bankroll REAL,
  gauntlet_result     TEXT,
  chips_earned        INTEGER,
  received_at         INTEGER,
  PRIMARY KEY (save_id, shove_count)
);

CREATE TABLE IF NOT EXISTS hands (
  save_id        TEXT NOT NULL,
  shove_count    INTEGER NOT NULL,
  t_start        REAL NOT NULL,
  duration       REAL,
  won            INTEGER,
  delta          REAL,
  tier           TEXT,
  stake_id       TEXT,
  stake_bb       REAL,
  game_type_id   TEXT,
  hand_pace_mult REAL,
  deck_id        TEXT,
  prototype      INTEGER,
  hands_played   INTEGER,
  PRIMARY KEY (save_id, shove_count, t_start)
);

CREATE TABLE IF NOT EXISTS events (
  save_id      TEXT NOT NULL,
  shove_count  INTEGER NOT NULL,
  t            REAL NOT NULL,
  type         TEXT NOT NULL,
  item_id      TEXT NOT NULL DEFAULT '',
  level        INTEGER,
  cost_dollars REAL,
  bankroll     REAL,
  cost_chips   INTEGER,
  chips        INTEGER,
  PRIMARY KEY (save_id, shove_count, t, type, item_id)
);

CREATE INDEX IF NOT EXISTS idx_hands_slot ON hands (game_type_id, stake_id);
CREATE INDEX IF NOT EXISTS idx_shoves_result ON shoves (gauntlet_result);
