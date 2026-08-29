-- data/hints.lua
--
-- STICKY hints only: full-focus instructions with a button to press. The
-- rest of the teaching lives in data/story.lua (the beats speak once) and
-- data/glossary.lua (the desk remembers). The old [i] info-hint queue is
-- retired: nothing is delivered through missable icons any more.
--
-- A sticky is still STATELESS: it never assumes where the story is. It
-- shows, the screen dims, the target punches through, and it completes on
-- its `done` condition or a bubble click.
--
-- Fields:
--   id      unique slug; keys the persisted state.hints_seen set
--   anchor  AnchorRegistry name(s) to highlight
--   text    bubble copy; {icon} markers render live glyphs
--   trigger condition table (models/hint_rules.lua kinds)
--   done    completion condition (the advance-on-action)
--   retire  if it already passes when the hint would first fire, mark
--           seen without showing
--   sticky  must be true — non-sticky specs are no longer delivered
--
-- Copy rules: no em-dashes, {chip} never the word, cut filler.

return {

    -- The rescue. An instruction with a button, and the one message that
    -- earns stealing focus: the player is stuck and may not know the way
    -- out is free.
    {
        id     = "quick_reset",
        title  = "Quick reset",
        anchor = "btn:quick_reset",
        sticky = true,
        text   = "Stuck? Happens. Free reset to two dollars, and your {chip} come with you.",
        trigger = { kind = "can_quick_reset" },
        done    = { kind = "not", { kind = "can_quick_reset" } },
    },

}
