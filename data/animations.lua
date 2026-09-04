-- data/animations.lua
--
-- Named animation presets. Pure data. The AnimationSystem reads this to
-- instantiate animations by name — call sites never hardcode durations or
-- curves.
--
-- Preset schema:
--   {
--     type     = "flip" | "bounce" | "fade" | "progress" | "timer",
--     duration = seconds,
--     -- type-specific extras:
--     height   = px,           -- bounce only
--     from     = number,       -- fade only
--     to       = number,       -- fade only
--     direction = 1 | -1,      -- progress only
--     initial  = number,       -- progress only
--   }
--
-- Usage at call site (AnimationSystem comes from the injected DI container —
-- never via a global):
--   local anim = self.game.animations:create("card_flip", { on_complete = fn })
--   anim:start()

return {

    card_flip = {
        type     = "flip",
        duration = 0.4,
    },

    card_bounce_in = {
        type     = "bounce",
        duration = 0.5,
        height   = 20,
    },

    shove_fade_in = {
        type     = "fade",
        duration = 1.0,
        from     = 0,
        to       = 1,
    },

    shove_fade_out = {
        type     = "fade",
        duration = 0.6,
        from     = 1,
        to       = 0,
    },

    pot_pulse = {
        type     = "bounce",
        duration = 0.3,
        height   = 6,
    },

    -- ── Shove cinematic ─────────────────────────────────────────────
    -- Per-card reveal as cards land on the felt. card_deal_slide is the
    -- normal pace for the flop / turn / river. cheat_card_dealt is the
    -- slow, weighty pace used for the 6th and 7th board cards — the
    -- dealer's cheat. The duration delta IS the visual emphasis.
    -- PROGRESS, not fade: views/ShoveView dealPos reads getProgress to
    -- move the card from the dealer's hands to its seat (a fade object has
    -- no progress, and for a long time the cards just faded in on the
    -- spot). Alpha comes off the same progress in the view.
    card_deal_slide = {
        type      = "progress",
        duration  = 0.42,
        direction = 1,
        initial   = 0,
    },

    cheat_card_dealt = {
        type      = "progress",
        duration  = 0.7,
        direction = 1,
        initial   = 0,
    },

    -- ── The grind deal (views/PokerEventAnims, views/TablePanel) ─────
    -- Plain numbers, not presets: the felt deals through FlightSystem.
    --   card    seconds a card is in the air, dealer button to seat
    --   stagger seconds between one card and the next
    --   flip    seconds a landed card takes to turn face-up
    --   muck    seconds the previous hand takes to slide off
    --   arc     px of arc on the throw
    --   floor   the shortest a card flight compresses to on a fast table
    grind_deal = {
        card    = 0.30,
        stagger = 0.06,
        flip    = 0.22,
        muck    = 0.25,
        arc     = 40,
        floor   = 0.08,
    },

    -- Hole-card face-down → face-up. Progress-curve drives a horizontal
    -- scale flip (1 → 0 → 1) with the texture swap happening at the
    -- midpoint (progress = 0.5) when the card is edge-on.
    hole_card_flip = {
        type      = "progress",
        duration  = 0.5,
        direction = 1,
        initial   = 0,
    },

    -- The dealer's showdown flip. Slower than a deal-speed flip on purpose:
    -- this is the reveal the whole hand has been waiting on, and 0.5s reads
    -- as a card being turned, not a hand being shown.
    showdown_flip = {
        type      = "progress",
        duration  = 0.95,
        direction = 1,
        initial   = 0,
    },

}
