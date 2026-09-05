-- data/terms.lua
--
-- The mechanic vocabulary, by colour category. Pure data.
--
-- A word in copy that names a mechanic is tinted in that mechanic's colour
-- with the IconText token {c:<category>:<text>} (an underscore in <text>
-- is a space): "{c:heat:Heat}", "{c:tilt:tilted}", "{c:lost:busted}".
-- The categories are the seven meanings of data/theme.lua's `sem` palette.
--
-- This file is NOT read by the renderer: markup is explicit so a verb is
-- never tinted by accident ("focus on that" stays plain). It is read by
-- sim/lint_terms.lua, which flags a bare mechanic word in a copy field, a
-- word tinted outside its category, and a second tinted occurrence in one
-- block; and by the browser tools, which preview and warn the same way.
--
-- Rules for authors (docs/the-house-voice.md carries the long form):
--   1. Tint the noun, not the sentence; never a verb.
--   2. First occurrence per block only, unless the block is a list.
--   3. A category only on a word it owns (the lists below).
--   4. Stake names, game types, money amounts and the House: never tinted.
--   5. Never inside a tooltip's numeric rows.

return {
    -- category → the words it owns (lower case; the lint matches whole
    -- words, case-insensitively, and knows simple plurals).
    words = {
        won       = { "won", "win", "wins", "winning", "payout", "payouts", "spill", "spills" },
        -- "red" is the readout's colour when a table loses money; the word
        -- takes the colour it names.
        lost      = { "lost", "lose", "loss", "losses", "bust", "busted", "busts", "denied", "red" },
        chip      = { "bounty", "bounties", "banked", "bank", "paid", "the door", "door" },
        corrupt   = { "anti-chip", "anti-chips", "corrupt", "corrupted", "corruption", "underflow" },
        heat      = { "heat", "heater", "heaters", "on fire", "hot" },
        tilt      = { "tilt", "tilted", "tilts", "tilting" },
        -- The run upgrades: the rack's cards wear a muted rose face, and the
        -- word is that same rose.
        upgrade   = { "upgrade", "upgrades", "the rack", "upgrade rack", "rack",
                      "sharper reads", "pot control", "focus", "cursor", "cursors", "cursor speed" },
    },
    -- The other UI nouns (catalog, deck, room, readout, stickers, glossary)
    -- are NOT tinted: paper and chrome, no colour of their own to lend.


    -- Words that MAY be tinted (they validate) but the lint never asks for:
    -- the result verbs ("you won", "Winning a stack") and nouns that are
    -- ambiguous in this game's copy ("room" is also the tournament room,
    -- "deck" also a deck of cards, "bank" also the BANK readout).
    optional = {
        "win", "wins", "winning", "won", "lose", "lost", "loss", "losses",
        "spill", "spills", "hot", "bank", "paid", "red",
        "focus",   -- also the verb and the FOCUS meter; tint only the upgrade

    },

    -- Words the lint must never ask to tint, even though they look like
    -- mechanics: identity, not signal (rule 4).
    never = {
        "zoom", "heads-up", "6-max", "tournament", "tournaments", "stake", "stakes",
        "table", "tables", "felt", "the house", "shove", "bankroll", "hand", "hands",
    },
}
