-- models/poker_effects.lua
--
-- Poker-specific effect kind registrations. Lives in models/ (not services/)
-- because the kind names (`shove_rate_add`, `vs_fish_mult`, etc.) are
-- poker-specific data — services/EffectsRegistry stays generic, just owning
-- the registry mechanism.
--
-- Adding a new effect kind:
--   1. Add an entry to data/effects.lua (documentation).
--   2. Register here with a single :register() call. The applicator reads
--      effect.value and mutates ctx.
--   3. Use the kind in data/catalog.lua, data/run_upgrades.lua, or any
--      effect-emitting source.
--
-- THERE IS NO if/elseif chain on `kind` strings ANYWHERE. If you find
-- yourself writing one, you're doing it wrong — register a function instead.

local PokerEffects = {}

function PokerEffects.registerAll(reg)
    reg:register("shove_rate_add", function(e, ctx)
        ctx.shove_rate = (ctx.shove_rate or 0) + e.value
    end)

    reg:register("earnings_mult", function(e, ctx)
        ctx.earnings_mult = (ctx.earnings_mult or 1) * e.value
    end)

    reg:register("hands_per_min_add", function(e, ctx)
        ctx.hands_per_min = (ctx.hands_per_min or 0) + e.value
    end)

    -- Per-playstyle situational multipliers. Each style targeted independently
    -- by catalog/run-upgrade items. Skill levels are not targetable — they're
    -- a flat additive penalty per opponent (see opponent_types.lua).
    reg:register("vs_fish_mult", function(e, ctx)
        ctx.vs_fish = (ctx.vs_fish or 1) * e.value
    end)
    reg:register("vs_tag_mult", function(e, ctx)
        ctx.vs_tag = (ctx.vs_tag or 1) * e.value
    end)
    reg:register("vs_lag_mult", function(e, ctx)
        ctx.vs_lag = (ctx.vs_lag or 1) * e.value
    end)
    reg:register("vs_nit_mult", function(e, ctx)
        ctx.vs_nit = (ctx.vs_nit or 1) * e.value
    end)

    reg:register("rep_decay_slow", function(e, ctx)
        ctx.rep_decay = (ctx.rep_decay or 1) * e.value
    end)

    -- Focus / efficiency mechanic. focus_capacity_add raises the table
    -- count below which no focus penalty applies (default base is
    -- Constants.GAMEPLAY.FOCUS_BASE_CAPACITY, seeded by GrindController
    -- when it reads ctx). focus_penalty_reduce_mult shrinks the
    -- per-extra-table penalty so capacity-light / penalty-light builds
    -- diverge.
    reg:register("focus_capacity_add", function(e, ctx)
        ctx.focus_capacity = (ctx.focus_capacity or 0) + e.value
    end)
    reg:register("focus_penalty_reduce_mult", function(e, ctx)
        ctx.focus_penalty_reduce_mult = (ctx.focus_penalty_reduce_mult or 1) * e.value
    end)

    -- Win-rate / pot math hooks. win_rate_add is the additive sharpen-reads
    -- knob; loss_mult shrinks losing-hand deltas; the *_penalty_mult kinds
    -- target a single skill tier via the skill entry's ctx_key (so calm_hands
    -- lowers the pro penalty without an `if opp.skill == "pro"` chain).
    -- gtype_offset_mult tames the game-type baseline offset (HU specialist).
    reg:register("win_rate_add", function(e, ctx)
        ctx.win_rate_add = (ctx.win_rate_add or 0) + e.value
    end)
    reg:register("loss_mult", function(e, ctx)
        ctx.loss_mult = (ctx.loss_mult or 1) * e.value
    end)
    reg:register("vs_pro_penalty_mult", function(e, ctx)
        ctx.vs_pro_penalty = (ctx.vs_pro_penalty or 1) * e.value
    end)
    reg:register("vs_grind_penalty_mult", function(e, ctx)
        ctx.vs_grind_penalty = (ctx.vs_grind_penalty or 1) * e.value
    end)
    reg:register("gtype_offset_mult", function(e, ctx)
        ctx.gtype_offset_mult = (ctx.gtype_offset_mult or 1) * e.value
    end)

    -- Discovery / opponent-reading hooks.
    reg:register("reveal_chance_add", function(e, ctx)
        ctx.reveal_chance_add = (ctx.reveal_chance_add or 0) + e.value
    end)
    reg:register("revealed_at_start_count", function(e, ctx)
        ctx.revealed_at_start_count = (ctx.revealed_at_start_count or 0) + e.value
    end)

    -- Meta-progression perks. Consumed at well-defined seams:
    --   start_bankroll_add / start_table_count → GameState:applyStartingPerks
    --   buy_in_mult                            → GrindController:addTable
    --   run_upgrade_cost_mult                  → GrindController:buyRunUpgrade
    --   pp_award_mult                          → GrindController:update PP branch
    reg:register("start_bankroll_add", function(e, ctx)
        ctx.start_bankroll_add = (ctx.start_bankroll_add or 0) + e.value
    end)
    reg:register("start_table_count", function(e, ctx)
        ctx.start_table_count = (ctx.start_table_count or 0) + e.value
    end)
    reg:register("buy_in_mult", function(e, ctx)
        ctx.buy_in_mult = (ctx.buy_in_mult or 1) * e.value
    end)
    reg:register("run_upgrade_cost_mult", function(e, ctx)
        ctx.run_upgrade_cost_mult = (ctx.run_upgrade_cost_mult or 1) * e.value
    end)
    reg:register("pp_award_mult", function(e, ctx)
        ctx.pp_award_mult = (ctx.pp_award_mult or 1) * e.value
    end)
end

return PokerEffects
