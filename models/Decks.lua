-- models/Decks.lua
--
-- Deck-system model layer. Stateless module of pure functions operating
-- on a GameState instance passed in. No DI capture, no globals. Pairs
-- with services/XpRuleRegistry (engine-agnostic dispatch) and
-- models/deck_xp_rules (poker-specific applicators) the same way the
-- run-upgrade pipeline pairs services/EffectsRegistry with
-- models/poker_effects.
--
-- Effects from all unlocked decks stack into ctx — the active vs.
-- inactive distinction matters only for XP accrual.

local DeckSpecs = require("data.decks")

local Decks = {}

-- Spec lookup. Cached at first call into a local index for O(1) reads
-- thereafter. Specs are immutable data, so the cache is safe forever.
local _by_id = nil
local function _index()
    if _by_id then return _by_id end
    _by_id = {}
    for _, spec in ipairs(DeckSpecs) do
        _by_id[spec.id] = spec
    end
    return _by_id
end

-- All specs in declaration order — for views that iterate the roster.
function Decks.all()
    return DeckSpecs
end

-- Spec for a given id, or nil. Stable references — do not mutate the
-- returned table.
function Decks.specById(id)
    return _index()[id]
end

-- Sprite path for the player's currently active deck, or nil if none is
-- set / the spec is missing. Used by the table + gauntlet card-back
-- renderers so the active deck's art is the back the player sees on
-- every face-down card. Caller chooses the fallback (typically the
-- Constants.GAUNTLET.CARD_BACK_SPRITE default).
function Decks.activeSprite(state)
    if not state then return nil end
    local spec = Decks.specById(state.active_deck_id)
    return spec and spec.sprite or nil
end

-- Whether `spec` is currently unlocked for `state`. A spec without an
-- `unlock` field is always unlocked (the starter deck). Otherwise the
-- spec's unlock condition is dispatched through `unlock_registry`.
-- A spec already in `state.unlocked_decks` is considered unlocked
-- regardless of its current condition (one-way unlock — a deck never
-- re-locks once earned).
local function _isInUnlockedList(state, id)
    if not state or not state.unlocked_decks then return false end
    for _, owned_id in ipairs(state.unlocked_decks) do
        if owned_id == id then return true end
    end
    return false
end

function Decks.isUnlocked(state, spec, unlock_registry)
    if not spec then return false end
    if _isInUnlockedList(state, spec.id) then return true end
    if not spec.unlock then return true end
    if not unlock_registry then return false end
    return unlock_registry:check(spec.unlock, state)
end

-- Walk every spec; for each one not yet in `state.unlocked_decks`,
-- check its unlock condition and (if satisfied) flip it into the
-- unlocked list with fresh L1 / 0 XP entries. Returns the list of
-- newly-unlocked ids so callers can react (toast, FX) — currently
-- unused but the hook is there.
function Decks.checkPendingUnlocks(state, unlock_registry)
    local newly = {}
    if not state then return newly end
    state.unlocked_decks = state.unlocked_decks or {}
    state.deck_levels    = state.deck_levels    or {}
    state.deck_xp        = state.deck_xp        or {}

    for _, spec in ipairs(DeckSpecs) do
        if not _isInUnlockedList(state, spec.id) then
            local unlocked
            if not spec.unlock then
                unlocked = true
            elseif unlock_registry then
                unlocked = unlock_registry:check(spec.unlock, state)
            else
                unlocked = false
            end
            if unlocked then
                state.unlocked_decks[#state.unlocked_decks + 1] = spec.id
                state.deck_levels[spec.id] = 1
                state.deck_xp[spec.id]     = 0
                newly[#newly + 1]          = spec.id
            end
        end
    end
    return newly
end

-- Resolve which level a given total XP value puts the deck at. Always
-- >= 1, capped at spec.max_level.
function Decks.levelForXp(spec, xp)
    local cap = spec.max_level or #spec.xp_curve
    local lvl = 1
    for i = 2, cap do
        if (xp or 0) >= (spec.xp_curve[i] or math.huge) then
            lvl = i
        else
            break
        end
    end
    return lvl
end

-- For a deck currently at `level`, return (xp_into_level, xp_needed_for_next).
-- If level == max_level, returns (xp_into_level, nil) — the "maxed" sentinel.
function Decks.progressInLevel(spec, level, xp)
    local floor_xp = spec.xp_curve[level] or 0
    local next_threshold = spec.xp_curve[level + 1]
    local into = (xp or 0) - floor_xp
    if not next_threshold then
        return into, nil
    end
    return into, next_threshold - floor_xp
end

-- Apply every unlocked deck's banked effects to ctx. Mirrors how
-- GameState:computeEffects walks owned_items + run_upgrade_levels —
-- registry-dispatched, no special-casing per kind.
function Decks.applyEffects(state, registry, ctx)
    if not state.unlocked_decks then return end
    for _, id in ipairs(state.unlocked_decks) do
        local spec = Decks.specById(id)
        local level = (state.deck_levels and state.deck_levels[id]) or 0
        if spec and level > 0 then
            registry:applyN(spec, ctx, level)
        end
    end
end

-- Grant XP to the active deck only and return whether a level-up fired.
-- Reads the active deck's xp_rule, dispatches through the XP registry,
-- and writes back to state.deck_xp / state.deck_levels.
--
-- Returns (xp_gained, leveled_up). Caller invalidates effects_cache on
-- a level-up.
function Decks.gainXp(state, xp_registry, event)
    local active_id = state.active_deck_id
    if not active_id then return 0, false end
    local spec = Decks.specById(active_id)
    if not spec then return 0, false end

    state.deck_levels = state.deck_levels or {}
    local current_level = state.deck_levels[active_id] or 1
    local cap = spec.max_level or #spec.xp_curve
    if current_level >= cap then return 0, false end

    local delta = xp_registry:apply(spec.xp_rule, event)
    if delta <= 0 then return 0, false end

    state.deck_xp = state.deck_xp or {}
    local cur_xp = state.deck_xp[active_id] or 0
    local new_xp = cur_xp + delta
    state.deck_xp[active_id] = new_xp

    local new_level = Decks.levelForXp(spec, new_xp)
    if new_level > current_level then
        state.deck_levels[active_id] = new_level
        return delta, true
    end
    return delta, false
end

return Decks
