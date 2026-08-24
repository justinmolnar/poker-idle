-- data/house_lines.lua
--
-- What the House says on the shove screen, keyed by line id. Pure data.
-- views/ShoveView schedules these on its timeline with say(at, id); the
-- bubble is the tutorial's hint bubble, tail to the House poster.
--
--   text   captor voice. {icon} markers render, same as hints.
--   once   true = plays a single time per save (gated on hints_seen with
--          the key "house:<id>"). Absent = plays every shove.
--
-- Copy rules: no em-dashes, {chip} never the word, cut filler. The act
-- ledes came out of the prestige modal that used to cover the felt.
--
-- Reveal rule: anything that can play BEFORE the player has won a runout
-- must not name a runout, a cheat, or a card count. The panic lines are
-- safe because they only ever follow a runout WIN.
return {
    arrive          = { text = "All of it? Good." },
    loss            = { text = "That is how it goes." },
    -- (banked_stays was cut: "those stay yours" pointed at a {chip} count the
    -- catalog was covering. A line that refers to something off-screen is
    -- worse than no line.)

    -- The panic. Only reachable after a runout win.
    panic_wait      = { text = "Wait." },
    panic_won       = { text = "You... won? Already?" },
    panic_no        = { text = "No." },
    panic_new_card  = { text = "New card. Try again later." },
    panic_again     = { text = "Twice. Nobody does this twice." },
    panic_no_more   = { text = "You get nothing. Ever." },

    clear           = { text = "There is nothing left to take from you.", once = true },

    -- Act ledes, spoken after the robbery on the shove that opened the act.
    act2            = { text = "The second hand does not count your catalog. Only your decks. Max five and The Master comes out.", once = true },
    act3            = { text = "Your multiplier is zero. Forever. Money cannot buy the last hand.", once = true },
}
