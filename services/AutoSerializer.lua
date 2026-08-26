-- services/AutoSerializer.lua
-- LOAD side of persistence only. The WRITE side is NOT automatic: the
-- payloads come from GameState:serializeMeta()/serializeRun(), which are
-- hand-maintained allowlists — a new persistent field must be added there
-- (the coverage test in the save suite fails when one is forgotten).
-- MODEL.TRANSIENTS documents the deliberately-unpersisted fields for that
-- same test; MODEL.REFS maps entity-reference fields to ids on apply.

local AutoSerializer = {}

-- Apply serialized data onto an instance. `refs_resolver(kind, id)` returns
-- the live instance for a given ref kind + id. Fields listed in `refs` on
-- the model are resolved through this; other fields are copied verbatim.
function AutoSerializer.apply(instance, data, refs, refs_resolver)
    for k, v in pairs(data or {}) do
        if refs and refs[k] then
            local r = refs[k]
            if r.list then
                local list = {}
                for i, id in ipairs(v or {}) do
                    local item = refs_resolver(r.kind, id)
                    if item then list[#list+1] = item end
                end
                instance[k] = list
            else
                instance[k] = refs_resolver(r.kind, v)
            end
        else
            instance[k] = v
        end
    end
end

return AutoSerializer
