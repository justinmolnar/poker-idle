-- lib/json.lua
-- Pure-Lua JSON encoder and decoder.
-- Handles objects, arrays, strings, numbers, booleans, null, and nesting.

local json = {}

-- ── ENCODE ────────────────────────────────────────────────────────────────────

local encode  -- forward declaration

local function encode_string(s)
    return '"' .. s
        :gsub('\\', '\\\\')
        :gsub('"',  '\\"')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t')
        .. '"'
end

local function is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

-- Cycle detection: tables currently on the stack are tracked in `seen`. When
-- an already-in-progress table is re-encountered we emit "null" rather than
-- recursing forever (which otherwise blows Lua's C stack). Without this, a
-- single accidental back-ref (e.g. trip → source_client → cargo → trip)
-- crashes the whole save.
encode = function(val, pretty, level, seen)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return "null" end  -- NaN guard
        return tostring(val)
    elseif t == "string" then
        return encode_string(val)
    elseif t == "table" then
        if seen[val] then return "null" end  -- cycle
        seen[val] = true

        local nl   = pretty and "\n"  or ""
        local pad  = pretty and string.rep("  ", level)     or ""
        local pad1 = pretty and string.rep("  ", level + 1) or ""
        local sep  = pretty and ": " or ":"

        local result
        if is_array(val) then
            if #val == 0 then
                result = "[]"
            else
                local items = {}
                for _, v in ipairs(val) do
                    table.insert(items, pad1 .. encode(v, pretty, level + 1, seen))
                end
                result = "[" .. nl .. table.concat(items, "," .. nl) .. nl .. pad .. "]"
            end
        else
            -- Non-array table → JSON object. Stringify integer keys too so
            -- sparse integer-keyed tables (district_map[sci], zone_seg_v[y][x],
            -- road_nodes[ry][rx], etc.) round-trip; SaveService's coerceIntKeys
            -- flips them back to numbers on decode.
            local items = {}
            for k, v in pairs(val) do
                local kt = type(k)
                if kt == "string" then
                    table.insert(items, pad1 .. encode_string(k) .. sep .. encode(v, pretty, level + 1, seen))
                elseif kt == "number" then
                    table.insert(items, pad1 .. encode_string(tostring(k)) .. sep .. encode(v, pretty, level + 1, seen))
                end
            end
            if #items == 0 then
                result = "{}"
            else
                table.sort(items)
                result = "{" .. nl .. table.concat(items, "," .. nl) .. nl .. pad .. "}"
            end
        end

        seen[val] = nil  -- allow sibling subtrees to see this table normally
        return result
    else
        error("json.encode: unsupported type '" .. t .. "'")
    end
end

--- Encode a Lua value as a JSON string.
-- @param val  any Lua value (table, string, number, boolean, nil)
-- @param pretty  if true, output is indented for readability
function json.encode(val, pretty)
    return encode(val, pretty or false, 0, {})
end

-- ── DECODE ────────────────────────────────────────────────────────────────────

local decode_value  -- forward declaration

local function skip_ws(s, i)
    while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end
    return i
end

local function decode_string(s, i)
    i = i + 1  -- skip opening "
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == '\\' then
            i = i + 1
            local esc = s:sub(i, i)
            if     esc == '"'  then table.insert(parts, '"')
            elseif esc == '\\' then table.insert(parts, '\\')
            elseif esc == '/'  then table.insert(parts, '/')
            elseif esc == 'n'  then table.insert(parts, '\n')
            elseif esc == 'r'  then table.insert(parts, '\r')
            elseif esc == 't'  then table.insert(parts, '\t')
            elseif esc == 'b'  then table.insert(parts, '\b')
            elseif esc == 'f'  then table.insert(parts, '\f')
            elseif esc == 'u'  then
                local hex = s:sub(i + 1, i + 4)
                table.insert(parts, utf8 and utf8.char(tonumber(hex, 16)) or '?')
                i = i + 4
            end
        else
            table.insert(parts, c)
        end
        i = i + 1
    end
    error("json.decode: unterminated string")
end

local function decode_number(s, i)
    local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not num_str then error("json.decode: invalid number at position " .. i) end
    return tonumber(num_str), i + #num_str
end

local function decode_object(s, i)
    local obj = {}
    i = i + 1  -- skip {
    i = skip_ws(s, i)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        i = skip_ws(s, i)
        if s:sub(i, i) ~= '"' then
            error("json.decode: expected string key at position " .. i)
        end
        local key
        key, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then
            error("json.decode: expected ':' at position " .. i)
        end
        i = skip_ws(s, i + 1)
        local val
        val, i = decode_value(s, i)
        obj[key] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == '}' then return obj, i + 1 end
        if c ~= ',' then error("json.decode: expected ',' or '}' at position " .. i) end
        i = i + 1
    end
end

local function decode_array(s, i)
    local arr = {}
    i = i + 1  -- skip [
    i = skip_ws(s, i)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
        i = skip_ws(s, i)
        local val
        val, i = decode_value(s, i)
        table.insert(arr, val)
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ']' then return arr, i + 1 end
        if c ~= ',' then error("json.decode: expected ',' or ']' at position " .. i) end
        i = i + 1
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if     c == '"' then return decode_string(s, i)
    elseif c == '{' then return decode_object(s, i)
    elseif c == '[' then return decode_array(s, i)
    elseif c == 't' then
        if s:sub(i, i + 3) == 'true'  then return true,  i + 4 end
        error("json.decode: invalid token at position " .. i)
    elseif c == 'f' then
        if s:sub(i, i + 4) == 'false' then return false, i + 5 end
        error("json.decode: invalid token at position " .. i)
    elseif c == 'n' then
        if s:sub(i, i + 3) == 'null'  then return nil,   i + 4 end
        error("json.decode: invalid token at position " .. i)
    elseif c:match("[-0-9]") then
        return decode_number(s, i)
    else
        error("json.decode: unexpected character '" .. c .. "' at position " .. i)
    end
end

--- Decode a JSON string into a Lua value.
-- @return value, nil on success; nil, error_message on failure
function json.decode(s)
    local ok, result = pcall(decode_value, s, 1)
    if ok then
        return result, nil
    else
        return nil, result
    end
end

return json
