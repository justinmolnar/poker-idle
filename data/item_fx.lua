-- data/item_fx.lua
--
-- What an item firing shows on the board (views/ItemStream): its icon pops
-- on the table it affected, with a short word for what it did, and flies
-- there first when it came from another table. The word comes from the
-- proc's payload (data/procs.lua) or, for the passive kinds that announce
-- through GrindController:itemFired, from the effect kind. Colours are
-- Theme semantic tokens.
return {
    -- By proc payload kind (and, for statuses, by status).
    payload = {
        apply_status = {
            heater = { text = "heater",  color = "heat" },
            tilt   = { text = "tilt",    color = "tilt" },
        },
        deal              = { text = "dealt",        color = "won" },
        deal_next         = { text = "deals itself", color = "won" },
        free_rebuy        = { text = "free rebuy",   color = "won" },
        next_win_tier_up  = { text = "next win up",  color = "chip" },
        pay_biggest_buyin = { text = "buy-in paid",  color = "won" },
        ratchet           = { text = "+odds",        color = "chance" },
        refund_buyin      = { text = "buy-in back",  color = "won" },
    },
    -- By effect kind (GrindController:itemFired).
    kinds = {
        zoom_fast_fold        = { text = "dealt now",   color = "won" },
        first_bounty_bonus    = { text = "+chip",       color = "chip" },
        stack_chip_add        = { text = "+1 chip",     color = "chip" },
        chip_award_mult       = { text = "bounty up",   color = "chip" },
        bounty_double_chance  = { text = "bounty x2",   color = "chip" },
        copy_first_denied     = { text = "copied",      color = "chip" },
        copy_denied_chance    = { text = "copied",      color = "chip" },
        void_first_stack_loss = { text = "loss voided", color = "won" },
        void_first_loss       = { text = "loss voided", color = "won" },
        bust_refund_pct       = { text = "refund",      color = "won" },
        free_rebuy_chance     = { text = "free rebuy",  color = "won" },
        tank_absorb_bumps     = { text = "next win up", color = "chip" },
    },
    -- A router moved a delivery to another table.
    routed = { text = "redirected", color = "muted" },

    -- The look.
    icon_h       = 40,     -- px, capped by the table's size (icon_of_table)
    icon_of_table = 0.34,  -- an icon is at most this fraction of its table's height
    pop_life     = 1.2,    -- s an icon stays on its table
    pop_rise     = 26,     -- px it drifts up while there
    fly_time     = 0.45,   -- s to fly from one table to another
    fly_arc      = 40,     -- px the flight bows up
    merge_window = 1.0,    -- s: the same item on the same table again merges (xN)
    max_live     = 80,     -- icons at once; the oldest goes first
}
