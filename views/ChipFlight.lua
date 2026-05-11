-- views/ChipFlight.lua
--
-- Unified chip-flight helper. Composes (denomination breakdown, render
-- closures, burst options) and dispatches a flight to FlightSystem.
-- Single seam for "chips fly from anchor A to anchor B" — used by both
-- the script's per-event handlers (views/PokerEventAnims) and the
-- view-side queue drain that consumes GrindController._emit*Chips
-- bursts (views/GrindView).
--
-- Two entry points so callers don't have to pre-break down or compose
-- render functions:
--   * fly(source, dest, amount, stake_id, options)
--       Convenience for "I have a $ amount, fly the right chips."
--   * flyChipsList(source, dest, chip_indices, options)
--       For paths that already broke down the amount (controller queue,
--       where the breakdown happens at queue-push time so the controller
--       isn't pulling in views/Chips). Still wraps the makeRenderFns
--       step + FlightSystem.emitBurst.
--
-- Both honor options.arrival_sound / max_per_event / chip_tint / tier.
-- Engine-side bookkeeping (capping, staggering, bezier arc) stays in
-- services/FlightSystem.

local FlightSystem = require("services.FlightSystem")
local Chips        = require("views.Chips")
local Denoms       = require("services.DenominationBreakdown")
local ChipData     = require("data.chips")

local ChipFlight = {}

local function _palette(stake_id)
    return ChipData.stake_palettes[stake_id] or ChipData.full_palette
end

-- Compose a burst from a dollar amount. Picks a chip-tier (used for
-- denomination weighting) from options.tier or by inferring from the
-- amount. Bails silently if breakdown is empty.
function ChipFlight.fly(source, dest, amount, stake_id, options)
    if not source or not dest then return end
    if not amount or amount <= 0 then return end
    options = options or {}
    local palette = _palette(stake_id)
    local tier    = options.tier or Denoms.tierFromAmount(amount)
    local chips   = Denoms.breakdown(amount, ChipData.denominations,
                                     palette, ChipData.tier_chip_target, tier)
    if not chips or #chips == 0 then return end
    local render_fns = Chips.makeRenderFns(chips, options.chip_tint)
    FlightSystem.emitBurst(source, dest, render_fns, {
        arrival_sound = options.arrival_sound,
        max_per_event = options.max_per_event,
    })
end

-- Burst from a pre-broken-down chip-index list (the controller queue
-- pushes these). Caller has already done Denoms.breakdown; we just
-- handle the render-closure + FlightSystem dispatch.
function ChipFlight.flyChipsList(source, dest, chip_indices, options)
    if not source or not dest then return end
    if not chip_indices or #chip_indices == 0 then return end
    options = options or {}
    local render_fns = Chips.makeRenderFns(chip_indices, options.chip_tint)
    FlightSystem.emitBurst(source, dest, render_fns, {
        arrival_sound = options.arrival_sound,
        max_per_event = options.max_per_event,
    })
end

return ChipFlight
