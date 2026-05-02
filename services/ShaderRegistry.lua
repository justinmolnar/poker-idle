-- services/ShaderRegistry.lua
--
-- Compile-once-on-boot, look-up-by-name shader registry. Engine-neutral —
-- the registry just owns compiled love.graphics.Shader objects keyed by
-- string. Game-specific code (views/TablePanel etc.) calls
-- ShaderRegistry.get(name) for a draw-time shader binding.
--
-- Compilation can fail (driver doesn't support the GLSL version, syntax
-- error, etc.) — failures log a warning and the entry stays nil. Callers
-- always nil-check before binding so a missing shader degrades to plain
-- rendering instead of crashing.
--
-- Usage:
--   ShaderRegistry.loadFromFile("radial_glow", "shaders/radial_glow.frag")
--   local sh = ShaderRegistry.get("radial_glow")
--   if sh then
--       love.graphics.setShader(sh)
--       sh:send("u_intensity", 0.7)
--       love.graphics.rectangle("fill", x, y, w, h)
--       love.graphics.setShader()
--   end

local ShaderRegistry = {}

local _shaders = {}    -- name → love.graphics.Shader (or nil on failure)

-- Load a fragment shader from a file path. Compiles on first call; later
-- calls with the same name no-op (won't recompile). Returns the compiled
-- shader or nil on failure. Reads the file source explicitly via
-- love.filesystem rather than passing the path to newShader directly —
-- some LÖVE versions try to interpret the string as GLSL source if the
-- auto-detect doesn't kick in, which silently produces a garbage shader.
function ShaderRegistry.loadFromFile(name, path)
    if _shaders[name] then return _shaders[name] end
    if not (love and love.graphics and love.graphics.newShader) then return nil end
    local source
    if love.filesystem and love.filesystem.read then
        source = love.filesystem.read(path)
    end
    if not source then
        print(string.format("[ShaderRegistry] file not found or unreadable: %s", tostring(path)))
        return nil
    end
    local ok, sh = pcall(love.graphics.newShader, source)
    if not ok or not sh then
        print(string.format("[ShaderRegistry] failed to compile %s: %s",
            tostring(name), tostring(sh)))
        return nil
    end
    _shaders[name] = sh
    print(string.format("[ShaderRegistry] loaded %s OK", tostring(name)))
    return sh
end

-- Load from raw GLSL source (alternative to loadFromFile).
function ShaderRegistry.loadFromSource(name, glsl_source)
    if _shaders[name] then return _shaders[name] end
    if not (love and love.graphics and love.graphics.newShader) then return nil end
    local ok, sh = pcall(love.graphics.newShader, glsl_source)
    if not ok or not sh then
        print(string.format("[ShaderRegistry] failed to compile %s: %s",
            tostring(name), tostring(sh)))
        return nil
    end
    _shaders[name] = sh
    return sh
end

function ShaderRegistry.get(name)
    return _shaders[name]
end

function ShaderRegistry.has(name)
    return _shaders[name] ~= nil
end

return ShaderRegistry
