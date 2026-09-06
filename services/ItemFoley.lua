-- services/ItemFoley.lua
--
-- One place an item is heard. Its own sound is the file that shares its
-- name (assets/audio/items), damaged when the item is corrupted; the
-- `fallback` (the count's chip tick) when it has none. The grind's
-- item_fired subscriber, the shove's count and the room screen (a click,
-- a delivery) all come through here, so an item sounds the same wherever
-- it is heard.

local SoundService = require("services.SoundService")
local Sounds       = require("data.sounds")

local ItemFoley = {}

-- opts: volume_mult (default the mix's item_fire volume), pitch, fallback
-- (a sound name, played when the item has none), sounds (the service to
-- play through; the shove's harness injects its own, default SoundService).
-- The mix's item_fire min_gap applies per name, so a rapid count of
-- different items is never gated. Returns whether the item's OWN sound played.
function ItemFoley.play(state, id, opts)
    opts = opts or {}
    local sounds = opts.sounds or SoundService
    if not (sounds and sounds.playNamed) or not id then return false end
    local rule    = (Sounds._mix and Sounds._mix.item_fire) or {}
    local damaged = (state and state.isCorrupted and state:isCorrupted(id)) or false
    local played  = sounds.playNamed(id, { volume_mult = opts.volume_mult or rule.volume or 0.5,
                                           pitch       = opts.pitch,
                                           min_gap     = rule.min_gap,
                                           damaged     = damaged })
    if not played and opts.fallback then
        sounds.playNamed(opts.fallback, { pitch = opts.pitch, damaged = damaged })
    end
    return played
end

return ItemFoley
