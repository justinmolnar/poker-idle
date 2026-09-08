-- sim/cases/gates.lua
--
-- Every catalog unlock at threshold-1 and threshold, every deck unlock
-- the same way, and every deck's XP rule: the event it counts earns the
-- XP the rule promises, the level turns at the curve.
return function(T)
    local H, E, check, wanted = T.H, T.E, T.check, T.wanted
    local Decks = require("models.Decks")
    local GameState = require("models.GameState")

    -- A state where `cond` reads `n`, for every unlock kind in the game.
    local function stateReading(cond, n)
        local st = GameState:new()
        local k = cond.kind
        if k == "total_hands_at_gtype" or k == "hands_at_gtype" then
            st.total_hands_by_gtype = { [cond.gtype] = n }
        elseif k == "decks_unlocked_count" then
            st.unlocked_decks = {}
            for i = 1, n do st.unlocked_decks[i] = "deck" .. i end
        elseif k == "decks_maxed" then
            st.unlocked_decks, st.deck_levels, st.deck_xp = {}, {}, {}
            local i = 0
            for _, spec in ipairs(Decks.all()) do
                if i < n then
                    i = i + 1
                    st.unlocked_decks[#st.unlocked_decks + 1] = spec.id
                    st.deck_levels[spec.id] = spec.max_level or 5
                end
            end
        elseif k == "has_shoved" or k == "shove_r1_won" or k == "hu_unlocked" then
            st[k] = (n >= 1)
        else
            st[k] = n
        end
        return st
    end

    local function describe(cond)
        return cond.kind .. (cond.gtype and ("@" .. cond.gtype) or "") .. (cond.threshold and (" >= " .. tostring(cond.threshold)) or "")
    end

    -- ── catalog gates ─────────────────────────────────────────────────
    local w = T.world()
    local reg = w.game.unlock_rules
    for _, it in ipairs(T.liveItems()) do
        local key = "item:" .. it.id
        if it.unlock and wanted(key) then
            local th = it.unlock.threshold or 1
            local below = reg:check(it.unlock, stateReading(it.unlock, th - 1))
            local at    = reg:check(it.unlock, stateReading(it.unlock, th))
            check(key, "gate", below == false and at == true,
                ("unlocks at %s: closed at %s, open at %s"):format(describe(it.unlock), tostring(th - 1), tostring(th)))
        end
    end

    -- ── deck gates and XP ─────────────────────────────────────────────
    local XP_EVENT = {
        money_won      = function(rule) return { won = true, delta = 100, gtype = rule.gtype or "hu", board_pure = true, stake_tier_idx = 8 }, 100 end,
        chips_banked   = function() return { type = "bounty", n = 3 }, 3 end,
        heaters_caught = function() return { type = "heater" }, 1 end,
        stack_dollars  = function() return { won = true, tier = "stack", delta = 100 }, 100 end,
        cursor_deals   = function() return { type = "cursor_deal" }, 1 end,
        tilts_absorbed = function() return { type = "tilt_absorbed" }, 1 end,
        knockouts      = function() return { type = "ko", n = 2 }, 2 end,
        bankroll_peak  = function(_rule, spec) return { bankroll = spec.xp_curve[1] }, spec.xp_curve[1] end,
    }
    -- the same rule, fed the event it must NOT count
    local XP_MISS = {
        money_won = function(rule)
            if rule.gtype then return { won = true, delta = 100, gtype = "ko", stake_tier_idx = 8 }, "a win at a tournament" end
            if rule.pure_only then return { won = true, delta = 100, gtype = "hu", board_pure = false, stake_tier_idx = 8 }, "a win on a mixed board" end
            if rule.tier_min then return { won = true, delta = 100, gtype = "hu", stake_tier_idx = rule.tier_min - 1 }, ("a win at stake %d"):format(rule.tier_min - 1) end
            return { won = false, delta = -100, gtype = "hu", stake_tier_idx = 8 }, "a loss"
        end,
        stack_dollars = function() return { won = true, tier = "large", delta = 100 }, "a large win" end,
        chips_banked  = function() return { type = "ko", n = 3 }, "a knockout" end,
    }
    for _, spec in ipairs(Decks.all()) do
        local key = ("deck:%s:1"):format(spec.id)
        if wanted(key) then
            if spec.unlock then
                local th = spec.unlock.threshold or 1
                local below = Decks.isUnlocked(stateReading(spec.unlock, th - 1), spec, reg)
                local at    = Decks.isUnlocked(stateReading(spec.unlock, th), spec, reg)
                check(key, "unlock", below == false and at == true,
                    ("the deck unlocks at %s: locked at %s, unlocked at %s"):format(describe(spec.unlock), tostring(th - 1), tostring(th)))
            else
                check(key, "unlock", true, "no unlock condition: the deck is open from the start")
            end
            local rule = spec.xp_rule or {}
            local mk = XP_EVENT[rule.kind]
            if not mk then
                check(key, "xp", false, ("no XP event shape known for rule kind %s"):format(tostring(rule.kind)))
            else
                local st = GameState:new()
                st.active_deck_id = spec.id
                st.unlocked_decks, st.deck_levels, st.deck_xp = { spec.id }, { [spec.id] = 0 }, { [spec.id] = 0 }
                local ev, worth = mk(rule, spec)
                local delta = Decks.gainXp(st, w.game.xp_rules, ev, 1)
                local ok_xp = (delta == worth)
                -- the level turns at the curve: sit one XP short, then earn
                local st2 = GameState:new()
                st2.active_deck_id = spec.id
                st2.unlocked_decks, st2.deck_levels = { spec.id }, { [spec.id] = 0 }
                st2.deck_xp = { [spec.id] = rule.absolute and 0 or (spec.xp_curve[1] - 1) }
                local ev2 = mk(rule, spec)
                local _, leveled = Decks.gainXp(st2, w.game.xp_rules, ev2, 1)
                local ok_level = leveled == true and st2.deck_levels[spec.id] == 1
                local miss_text = ""
                local ok_miss = true
                local miss = XP_MISS[rule.kind]
                if miss then
                    local mev, what = miss(rule)
                    local st3 = GameState:new()
                    st3.active_deck_id = spec.id
                    st3.unlocked_decks, st3.deck_levels, st3.deck_xp = { spec.id }, { [spec.id] = 0 }, { [spec.id] = 0 }
                    local d3 = Decks.gainXp(st3, w.game.xp_rules, mev, 1)
                    ok_miss = (d3 == 0)
                    miss_text = ("; %s earns %s"):format(what, tostring(d3))
                end
                check(key, "xp", ok_xp and ok_level and ok_miss,
                    ("levels on %s: the counted event earns %s XP (rule %s); at %s XP the deck turns L1%s"):format(
                        spec.levels_on or "?", tostring(delta), rule.kind, tostring(spec.xp_curve[1]), miss_text))
            end
        end
    end
end
