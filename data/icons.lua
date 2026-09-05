-- data/icons.lua
--
-- Logical icon id → sprite name + tint token. Pure data (architecture
-- rule 3): no logic, no requires of other layers. Drop a PNG at
-- assets/sprites/<sprite>.png and the matching id lights up via
-- views/Icons; until then views/Icons stays SILENT for ids with no
-- shipped art (no debug-magenta — that's reserved for genuine bugs).
--
-- `tint` is a dotted Theme token path resolved at draw time against the
-- live (palette-aware) Theme — e.g. "fg.heading", "status.error". nil =
-- the asset's own baked colors (Theme.assetTint).
--
-- The currency `chip` is special-cased in views/Icons.drawChip with a
-- procedural fallback (views/Chips.drawGlyph) so it reads as an icon
-- before any art exists.

return {
    -- Meta-currency (Gold Chip). Procedural fallback in Icons.drawChip.
    chip = { sprite = "ui/icons/chip", tint = nil },
    achip = { sprite = "ui/icons/achip", tint = nil },

    -- Top-bar jargon cells (icon hooks; silent until art lands).
    focus = { sprite = "ui/icons/focus", tint = "fg.heading" },
    shove = { sprite = "ui/icons/shove", tint = "sem.chip" },

    -- Run-upgrade rail (data/run_upgrades.lua `icon` fields reference these).
    sharper_reads = { sprite = "ui/icons/sharper_reads", tint = "fg.heading" },
    pot_control   = { sprite = "ui/icons/pot_control",   tint = "fg.heading" },
    cursor        = { sprite = "ui/icons/cursor",        tint = "fg.heading" },
    cursor_speed  = { sprite = "ui/icons/cursor_speed",  tint = "fg.heading" },
}
