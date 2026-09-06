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
        -- "heater" is the noun in rule copy; "on fire" and "hot" are the
        -- House's words (story_only below) and validate only there.
        heat      = { "heater", "heaters", "on fire", "hot" },
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

    -- ── The style sheet (docs/copy-style.md), enforced by sim/lint_copy.lua ──

    -- Words the House may say in a story beat that rule copy may not.
    story_only = { "on fire", "hot" },

    -- Spellings, matched exactly as written (case matters).
    banned_case = {
        ["6-max"] = "6-Max",
        ["6-MAX"] = "6-Max",
    },

    -- Retired words: phrase → what to write instead. Checked in every copy
    -- field except story beats. A phrase of plain words matches whole
    -- words, case-insensitively; anything with punctuation matches as is.
    banned = {
        -- the nouns
        ["tier"]          = "a glyph, or 'size'",
        ["tiers"]         = "glyphs, or 'sizes'",
        ["nearby"]        = "the table beside it",
        ["neighbour"]     = "the table beside it",
        ["neighbor"]      = "the table beside it",
        ["neighbouring"]  = "the table beside it",
        ["neighboring"]   = "the table beside it",
        ["another table"] = "a random table",
        ["status"]        = "a heater or a tilt",
        ["statuses"]      = "heaters and tilts",
        ["ratchet"]       = "the plain rule: +1% win chance at every table for the run",
        ["ratchets"]      = "the plain rule",
        ["sweep"]         = "settles",
        ["resolves"]      = "settles",
        ["cascade"]       = "settles",
        ["unbanked"]      = "unpaid",
        ["capacity"]      = "tables at full FOCUS",
        ["heats"]         = "catches a heater",
        ["heats up"]      = "catches a heater",
        ["heat up"]       = "catches a heater",
        ["burnt-out"]     = "ends",
        ["runs its course"] = "ends",
        ["spent"]         = "lands / ends",
        -- the number words: the form is the operation (+N%, ×N, 1 in N)
        ["double"]        = "×2",
        ["doubles"]       = "×2",
        ["quadruple"]     = "×4",
        ["twice"]         = "×2",
        ["thrice"]        = "×3",
        ["% more"]        = "×N or +N%",
        ["% less"]        = "×N or -N%",
        ["% stronger"]    = "+N%",
        ["% softer"]      = "×N",
        ["% heavier"]     = "×N",
        ["% bigger"]      = "×N",
        ["% faster"]      = "×N",
        ["× bigger"]      = "×N",
        ["softer"]        = "×N",
        ["heavier"]       = "×N",
        ["half the time"] = "1 in 2 chance",
        ["a third"]       = "1 in 3 chance",
        ["% chance"]      = "1 in N chance",
        ["sometimes"]     = "1 in N chance",
        ["may "]          = "1 in N chance",
        -- the verbs that stood in for a glyph and an arrow
        ["boost"]         = "{from} {arrow} {to}",
        ["boosts"]        = "{from} {arrow} {to}",
        ["soften"]        = "{from} {arrow} {to}",
        ["softens"]       = "{from} {arrow} {to}",
        ["bumps"]         = "lands one size up",
        ["bumped"]        = "lands one size up",
        ["reads a"]       = "lands one size up",
        ["read a"]        = "lands one size up",
        ["read one"]      = "{from} {arrow} {to}",
        ["reach a"]       = "lands one size up",
    },
}
