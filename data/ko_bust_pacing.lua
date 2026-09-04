-- data/ko_bust_pacing.lua
--
-- Per-finish-position pacing weights for distributing pre-player
-- opponent busts across the tournament's hands. Used by
-- models/KoSession:planRun once finish_position and n_hands are known.
--
-- Each entry is a 3-bucket weight {front, mid, back}. The available
-- hand range (1 .. n_hands-1 if the player busts on the final hand,
-- 1 .. n_hands otherwise) is split into thirds; each pre-bust opp's
-- hand index is sampled from the bucket weights, then jittered inside
-- the bucket uniformly.
--
-- Shape: as `finish` approaches 1, busts cluster toward the back of
-- the tournament (drama — last hands knock the rest out). As `finish`
-- approaches 8, busts cluster front (player went out early so most
-- pre-busts also happened early, with fewer total).
--
-- Pure data — no logic.

return {
    [1] = { front = 0.15, mid = 0.30, back = 0.55 },
    [2] = { front = 0.18, mid = 0.32, back = 0.50 },
    [3] = { front = 0.22, mid = 0.34, back = 0.44 },
    [4] = { front = 0.28, mid = 0.36, back = 0.36 },
    [5] = { front = 0.34, mid = 0.36, back = 0.30 },
    [6] = { front = 0.42, mid = 0.34, back = 0.24 },
    [7] = { front = 0.50, mid = 0.32, back = 0.18 },
    [8] = { front = 0.55, mid = 0.30, back = 0.15 },
}
