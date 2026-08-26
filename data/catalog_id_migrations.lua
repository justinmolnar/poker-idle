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
    lucky_coin             = "gift_box",
    worry_stone            = "comfort_bed",
    pocket_cash            = "stash_box",
    headphones             = "space_heater",
    pen                    = "pencil_holder",
    water_cooler           = "desk_plant",
    free_sit               = "desk",
    seat_card              = "desk",
    punch_card             = "rebuy_note",
    plastic_trophy         = "prize_vase",
    discount_sits          = "vouchers",
    first_cursor           = "laptop",
    mouse_pad              = "gaming_keyboard",
    cursor_pool            = "box_of_mice",
    tireless_assistants    = "wacom_tablet",
    the_sink               = "kettle",
    medical_kit            = "first_aid_kit",
    filing_cabinet         = "nightstand",
    copy_machine           = "receipt_printer",
    engraved_plaque        = "diploma",
    study_chart            = "blueprint",
    big_tv                 = "console_tv",
    glass_door             = "high_roller_pass",
    projector              = "window",
    supply_closet          = "bookshelf",
    dishwasher             = "cereal_shelf",
    bathtub                = "blackout_curtains",
}
