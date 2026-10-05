-- data/gtype_items.lua
--
-- The catalog items that make one game type better, by game type: the
-- add-table rows show the ones you own as small icons beside the stake
-- (views/GrindView, through IconText's {item:id}), so choosing a table
-- shows what you have built toward. Items that act everywhere are not
-- listed; only those whose effect reads the game type (or its neighbours,
-- for the 6-Max tank and the tournament's knockouts).
return {
    hu = {
        "mirror", "fight_night_poster",
    },
    zoom = {
        "energy_drink", "handheld", "washing_machine", "hybrid_console", "headset",
        "receipt_printer", "replay_tv",
    },
    six_max = {
        "desk_plant", "red_rug", "comfort_bed", "space_heater", "floor_plant",
        "blackout_curtains", "fire_extinguisher", "console_television", "microwave_oven",
    },
    ko = {
        "prize_vase", "rubber_duck", "first_aid_kit", "medical_poster", "hot_bath",
        "fresh_towel", "box_of_tissues", "shower_head", "window",
    },
}
