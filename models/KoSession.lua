-- models/KoSession.lua
--
-- Per-table tournament state. Composed onto Table for any game type with
-- `chip_stack_table = true` (the 8-max KO mode). Cash tables instantiate
-- it and leave it at hands_won = 0 / state = nil.
--
-- A tournament is a cash table whose money is the chips on it: every seat
-- sits down with starting_stack_bb, every hand plays through the cash
-- pipeline (models/Table:deal) priced in the tournament's growing big
-- blind (Table:koBigBlind), the chips never leave the table, and the
-- order the seats bust is the finish. This session only knows whether a
-- tournament is running and what it paid.
--
-- ─── Lifecycle ────────────────────────────────────────────────────────
--
--   • :begin()        — flag the session live (every deal; idempotent).
--   • :winHand()      — bump the hands-won counter (deck XP, stats).
--   • :settle(...)    — finish: look up the payout, stop the session.
--   • :drainPayout()  — the controller pulls the cash payout.
--   • :reset()        — REBUY / save-clear.
--
-- Persistence: every field rides in Table:serialize (pending_payout too,
-- so a payout settled just before a quit is not lost). An old save's
-- `plan` field is ignored.

local KoSession = {}
KoSession.__index = KoSession

function KoSession:new()
    return setmetatable({
        hands_won      = 0,
        -- Tournaments finished at this table, ever. Backs High Roller Pass
        -- (controllers/GrindController). Incremented in Table:_endTournament.
        finish_count   = 0,
        state          = nil,    -- nil | "playing"
        pending_payout = nil,    -- $ amount, until the controller drains it
        last_finish    = nil,    -- finish position from the most recent settle
    }, KoSession)
end

function KoSession:serialize()
    return {
        hands_won      = self.hands_won,
        finish_count   = self.finish_count,
        state          = self.state,
        pending_payout = self.pending_payout,
        last_finish    = self.last_finish,
    }
end

function KoSession.restore(rec)
    local s = KoSession:new()
    if type(rec) ~= "table" then return s end
    s.hands_won      = rec.hands_won or 0
    s.finish_count   = rec.finish_count or 0
    s.state          = rec.state
    s.pending_payout = rec.pending_payout
    s.last_finish    = rec.last_finish
    return s
end

function KoSession:begin()
    if self.state == nil then self.state = "playing" end
end

function KoSession:isPlaying()
    return self.state == "playing"
end

function KoSession:winHand()
    self.hands_won = self.hands_won + 1
end

-- Resolve the payout for a finish position (1 = won). The ko_payouts
-- ladder is keyed by (n_seats - finish + 1), so places outside the top
-- three pay nothing. Stashes pending_payout for the controller to drain
-- and ends the session, so the next :begin starts a fresh tournament.
function KoSession:settle(buy_in, payouts_for_boost, finish_position, n_seats)
    local key  = (n_seats or 0) - (finish_position or 0) + 1
    local mult = (payouts_for_boost and payouts_for_boost[key]) or 0
    self.pending_payout = mult * (buy_in or 0)
    self.last_finish    = finish_position
    self.state          = nil
end

-- Pop the pending payout (or nil if none). The controller applies it to
-- the bankroll, fires the chip burst and resets the hands counter.
function KoSession:drainPayout()
    local p = self.pending_payout
    self.pending_payout = nil
    return p
end

function KoSession:reset()
    self.hands_won      = 0
    self.state          = nil
    self.pending_payout = nil
    self.last_finish    = nil
end

return KoSession
