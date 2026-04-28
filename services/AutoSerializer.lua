-- services/AutoSerializer.lua
-- Generic, data-driven model serializer. Each model declares:
--   MODEL.TRANSIENTS = { field_name = true, ... }     fields NOT to save
--   MODEL.REFS       = { field_name = {kind, list} }  fields that are entity
--                                                     refs (other_model → id,
--                                                     list_of_models → ids, etc.)
-- Everything else on the instance saves automatically. Adding a new data
-- field to a model costs zero — it will persist. Only new transients or refs
-- need an entry in the model's declaration.

local AutoSerializer = {}

local function shouldSkipType(v)
    local t = type(v)
    return t == "function" or t == "userdata" or t == "thread"
end

-- Serialize an instance according to its model declarations.
function AutoSerializer.serialize(obj, transients, refs)
    local out = {}
    for k, v in pairs(obj) do
        if transients and transients[k] then
            -- skip
        elseif shouldSkipType(v) then
            -- skip non-serializable (methods etc.)
        elseif refs and refs[k] then
            local r = refs[k]
            if r.list then
                local ids = {}
                for i, item in ipairs(v or {}) do
                    ids[i] = item and item[r.kind] or nil
                end
                out[k] = ids
            else
                out[k] = v and v[r.kind] or nil
            end
        else
            -- Plain data (primitives, pure data tables): copy by reference.
            -- Entity instances should be in `refs` or `transients` — if one
            -- sneaks through here the JSON encoder will barf, which is a
            -- deliberate loud signal to classify the field.
            out[k] = v
        end
    end
    return out
end

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
