-- data/catalog_id_migrations.lua
--
-- Catalog ids that were renamed after saves went public. GameState:applySaved
-- maps any old id found in a save (owned_items, corrupted_items) to its new
-- one, so an existing player keeps what they bought. Add a line per rename;
-- never remove one.

return {
    branded_hat            = "wall_hanger",
    whiteboard             = "corkboard",
    self_help_book         = "stack_of_books",
    stress_ball            = "throw_pillow",
    lucky_coin             = "starter_gift_box",
    worry_stone            = "comfort_bed",
    pocket_cash            = "stash_box",
    headphones             = "space_heater",
    pen                    = "pencil_holder",
    water_cooler           = "desk_plant",
    free_sit               = "desk",
    seat_card              = "desk",
    punch_card             = "rebuy_sticky_note",
    plastic_trophy         = "prize_vase",
    discount_sits          = "rolled_vouchers",
    first_cursor           = "laptop_terminal",
    mouse_pad              = "gaming_keyboard",
    cursor_pool            = "box_of_mice",
    tireless_assistants    = "wacom_tablet",
    the_sink               = "electric_kettle",
    medical_kit            = "first_aid_kit",
    filing_cabinet         = "nightstand",
    copy_machine           = "receipt_printer",
    engraved_plaque        = "framed_diploma",
    study_chart            = "laminated_blueprint",
    big_tv                 = "console_television",
    glass_door             = "high_roller_pass",
    projector              = "window",
    supply_closet          = "bookshelf",
    dishwasher             = "cereal_shelf",
    bathtub                = "blackout_curtains",
    -- 2026-09 drift pass: ids re-aligned with their names. Values above
    -- were updated in the same pass so a chain (punch_card → rebuy_note →
    -- rebuy_sticky_note) resolves in one hop.
    the_tilt               = "tilt",
    fight_night            = "fight_night_poster",
    gift_box               = "starter_gift_box",
    sticky_notes           = "yellow_sticky_note",
    rebuy_note             = "rebuy_sticky_note",
    fridge                 = "compact_fridge",
    nes_console            = "dusty_console",
    gameboy                = "handheld",
    vouchers               = "rolled_vouchers",
    laptop                 = "laptop_terminal",
    kettle                 = "electric_kettle",
    toaster                = "chrome_toaster",
    microwave              = "microwave_oven",
    diploma                = "framed_diploma",
    blueprint              = "laminated_blueprint",
    console_tv             = "console_television",
    pc_tower               = "tower_upgrade",
    unlock_ultra           = "ultra_stake",
}
