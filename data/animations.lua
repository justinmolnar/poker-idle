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

}
