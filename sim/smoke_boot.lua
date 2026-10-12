-- sim/smoke_boot.lua
--
-- Boots as much of the game as can be booted without a graphics card.
--
-- Why this exists: the sim suite drives the ENGINE — hands, procs, payouts —
-- and never touches a view or a service, so a file that passes `luac -p`
-- and crashes the moment love.load calls it had no coverage at all. That is
-- exactly how a preload calling an undefined upvalue shipped: every
-- headless check was green and the game would not start.
--
-- Three passes:
--   0. Scan every file for a local read before its declaration. Legal Lua,
--      silent under `luac -p`, nil at run time. That is what crashed.
--   1. require() every module under the source directories. Catches syntax
--      errors, bad require paths, and anything that throws at load.
--   2. Run the boot work that only exists under the engine: scan the real
--      assets/sprites tree, hold the loader to its lazy contract, decode
--      the boot manifest, and confirm every name the game data asks for
--      resolves to a file.
--
-- The view and service caches are checked separately, in sim/smoke_views.
--
-- The LOVE shim below is deeper than sim/harness.lua's: love.filesystem
-- reads the REAL disk and love.image reports the REAL pixel dimensions
-- (out of the PNG header), because both are what the sprite loader's
-- decisions turn on. Nothing here draws.
--
-- Standalone: `lua sim/smoke_boot.lua` from the repo root.

package.path = package.path .. ";./?.lua"

local fails, checks = {}, 0
local c_decodes
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails[#fails + 1] = what end
    return cond
end

-- --- The disk, as LOVE sees it -----------------------------------------
-- One `dir /s /b` per tree rather than one per directory: the sprite kit is
-- a few hundred folders and a process spawn each would dominate the run.

local FILES, DIRS = {}, {}

local function cwd()
    local p = io.popen("cd")
    local d = p and p:read("*l") or "."
    if p then p:close() end
    return (d:gsub("\\", "/"))
end
local ROOT = cwd()

local function harvest(tree)
    for _, spec in ipairs({ { "/a-d", FILES }, { "/ad", DIRS } }) do
        local cmd = string.format('dir /s /b %s "%s" 2>nul', spec[1], (tree:gsub("/", "\\")))
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                local rel = line:gsub("\\", "/")
                if rel:sub(1, #ROOT) == ROOT then rel = rel:sub(#ROOT + 2) end
                spec[2][rel] = true
            end
            p:close()
        end
    end
    DIRS[tree] = true
end
harvest("assets")
harvest("shaders")

local function children(dir)
    local out, seen = {}, {}
    local prefix = (dir == "" or dir == ".") and "" or (dir .. "/")
    for _, set in ipairs({ FILES, DIRS }) do
        for path in pairs(set) do
            if path:sub(1, #prefix) == prefix then
                local rest = path:sub(#prefix + 1)
                local head = rest:match("^([^/]+)")
                if head and head ~= "" and not seen[head] then
                    seen[head] = true
                    out[#out + 1] = head
                end
            end
        end
    end
    table.sort(out)
    return out
end

-- PNG dimensions from the IHDR chunk. The loader's strip test is
-- `width % height == 0 and width / height >= 3`, so faking the size would
-- fake away the only decision the decode makes.
-- Every real PNG decode goes through pngSize, so counting here counts
-- decodes. The whole point of the lazy loader is that this stays at zero
-- through the scan.
local DECODES = 0

local function pngSize(path)
    DECODES = DECODES + 1
    local f = io.open(path, "rb")
    if not f then return nil end
    local hdr = f:read(24)
    f:close()
    if not hdr or #hdr < 24 or hdr:sub(2, 4) ~= "PNG" then return nil end
    local function be(s)
        local n = 0
        for i = 1, 4 do n = n * 256 + s:byte(i) end
        return n
    end
    return be(hdr:sub(17, 20)), be(hdr:sub(21, 24))
end

-- --- The shim ----------------------------------------------------------

local function noops(t)
    return setmetatable(t or {}, { __index = function(tt, k)
        local f = function() end
        rawset(tt, k, f)
        return f
    end })
end

local function fakeImage(w, h)
    return {
        getWidth      = function() return w end,
        getHeight     = function() return h end,
        getDimensions = function() return w, h end,
        setFilter     = function() end,
        getFilter     = function() return "nearest", "nearest" end,
        setWrap       = function() end,
        release       = function() end,
        type          = function() return "Image" end,
        typeOf        = function() return true end,
    }
end

love = love or {}
love.math = noops({
    random = function(a, b)
        if a and b then return math.random(a, b) end
        if a then return math.random(a) end
        return math.random()
    end,
    triangulate = function(p) return { p } end,
    colorFromBytes = function(r, g, b, a)
        return r / 255, g / 255, b / 255, (a or 255) / 255
    end,
})
love.timer = noops({
    getTime  = function() return 0 end,
    getDelta = function() return 1 / 60 end,
    getFPS   = function() return 60 end,
})

love.filesystem = noops({
    getInfo = function(path)
        path = (path or ""):gsub("\\", "/"):gsub("/+$", "")
        if DIRS[path] then return { type = "directory" } end
        if FILES[path] then return { type = "file", size = 0 } end
        return nil
    end,
    getDirectoryItems = function(path)
        return children((path or ""):gsub("\\", "/"):gsub("/+$", ""))
    end,
    read = function(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local c = f:read("*a")
        f:close()
        return c, #c
    end,
    write   = function() return true end,
    remove  = function() return true end,
    getSaveDirectory    = function() return "." end,
    getWorkingDirectory = function() return "." end,
    getSource           = function() return "." end,
    isFused             = function() return false end,
})

love.image = noops({
    newImageData = function(a, b)
        if type(a) == "string" then
            local w, h = pngSize(a)
            if not w then error("not a readable png: " .. a) end
            return { getWidth = function() return w end,
                     getHeight = function() return h end,
                     paste = function() end, release = function() end }
        end
        local w, h = a or 1, b or 1
        return { getWidth = function() return w end,
                 getHeight = function() return h end,
                 paste = function() end, release = function() end }
    end,
})

love.graphics = noops({
    getDimensions = function() return 1600, 900 end,
    getWidth      = function() return 1600 end,
    getHeight     = function() return 900 end,
    getColor      = function() return 1, 1, 1, 1 end,
    getCanvas     = function() return nil end,
    newImage = function(src)
        if type(src) == "string" then
            local w, h = pngSize(src)
            return fakeImage(w or 1, h or 1)
        end
        return fakeImage(src and src.getWidth and src:getWidth() or 1,
                         src and src.getHeight and src:getHeight() or 1)
    end,
    newCanvas = function(w, h)
        local c = fakeImage(w or 1600, h or 900)
        c.newImageData = function() return love.image.newImageData(w or 1600, h or 900) end
        c.renderTo = function(_, fn) if fn then fn() end end
        return c
    end,
    newFont = function()
        return noops({ getWidth  = function() return 8 end,
                       getHeight = function() return 16 end,
                       setFilter = function() end })
    end,
    newSpriteBatch  = function() return noops({ getCount = function() return 0 end }) end,
    newQuad         = function() return noops({}) end,
    newShader       = function() return noops({ hasUniform = function() return false end }) end,
    getSupported    = function() return {} end,
    getRendererInfo = function() return "none", "0", "none", "none" end,
})

love.window = noops({
    getMode = function() return 1600, 900, {} end,
    getDesktopDimensions = function() return 1920, 1080 end,
    getFullscreen = function() return false end,
})
love.mouse    = noops({ getPosition = function() return -1, -1 end,
                        isDown = function() return false end })
love.keyboard = noops({ isDown = function() return false end })
love.system   = noops({ getOS = function() return "Windows" end })
love.audio    = noops({
    newSource = function()
        return setmetatable({}, { __index = function(_, k)
            if k == "isPlaying"   then return function() return false end end
            if k == "getDuration" then return function() return 0.1 end end
            if k == "clone"       then return function() return love.audio.newSource() end end
            return function() end
        end })
    end,
    getActiveSourceCount = function() return 0 end,
})
love.sound = noops({})
love.event = noops({})
love.getVersion = function() return 11, 4, 0, "Mysterious Mysteries" end

-- --- Pass 0: nothing reads a local before it is declared ---------------
--
-- The failure this catches: a file-level `local function foo` used by a
-- function DEFINED ABOVE it. Lua compiles that happily — the name is just a
-- global read that resolves to nil — so `luac -p` is silent and the module
-- loads fine. It only blows up when the caller actually runs, which for a
-- boot or draw path can be the first thing a player sees.
--
-- The test: compile each file and look for a global read whose name is also
-- a file-level local somewhere in that same file. That combination has no
-- legitimate form; either the local is meant and the read cannot see it, or
-- the name collides with a real global, which is its own bug.

local function forwardRefs(path)
    local hits = {}
    local f = io.open(path, "r")
    if not f then return hits end
    local decl, line_no = {}, 0
    for line in f:lines() do
        line_no = line_no + 1
        local name = line:match("^local%s+function%s+([%a_][%w_]*)")
        if name then
            if not decl[name] then decl[name] = line_no end
        else
            local names = line:match("^local%s+([%a_][%w_,%s]*)")
            if names then
                for nm in names:gmatch("[%a_][%w_]*") do
                    if not decl[nm] then decl[nm] = line_no end
                end
            end
        end
    end
    f:close()
    if not next(decl) then return hits end

    local p = io.popen(string.format('luac -p -l -l "%s" 2>&1', path))
    if not p then return hits end
    local seen = {}
    for line in p:lines() do
        local at, name = line:match("%[(%d+)%].-TABUP.-; _ENV \"([%a_][%w_]*)\"")
        if name and decl[name] and not seen[name] then
            seen[name] = true
            hits[#hits + 1] = string.format("%s:%s reads '%s' as a global; it is a local declared at line %d",
                                            path, at, name, decl[name])
        end
    end
    p:close()
    return hits
end

local function everyLuaFile()
    local out = {}
    local p = io.popen('dir /s /b "*.lua" 2>nul')
    if p then
        for line in p:lines() do
            local rel = line:gsub("\\", "/")
            if rel:sub(1, #ROOT) == ROOT then rel = rel:sub(#ROOT + 2) end
            local skip = rel:match("^lib/") or rel:match("^build/") or rel:match("^%.git/")
                      or rel:match("node_modules")
            if not skip then out[#out + 1] = rel end
        end
        p:close()
    end
    table.sort(out)
    return out
end

local all_lua = everyLuaFile()
local fwd = 0
for _, path in ipairs(all_lua) do
    for _, hit in ipairs(forwardRefs(path)) do
        fwd = fwd + 1
        ok(false, hit)
    end
end
checks = checks + #all_lua
print(string.format("[smoke] %d files scanned for forward references, %d found", #all_lua, fwd))

-- --- Pass 1: every module loads ----------------------------------------

local SRC_DIRS = { "core", "controllers", "data", "models", "services", "states", "utils", "views" }

-- Thread entry points, not modules: LOVE runs each in a fresh Lua state
-- where `require("love.filesystem")` is the engine's own loader. Nothing
-- ever require()s them, so loading them here would only prove that plain
-- Lua has no love.dll. They are still covered by the syntax and
-- forward-reference passes that run over every file.
local NOT_MODULES = {
    ["services.save_worker"]  = true,
    ["services.music_worker"] = true,
}

local function luaModules()
    local mods = {}
    for _, dir in ipairs(SRC_DIRS) do
        local p = io.popen(string.format('dir /s /b "%s\\*.lua" 2>nul', dir))
        if p then
            for line in p:lines() do
                local rel = line:gsub("\\", "/")
                if rel:sub(1, #ROOT) == ROOT then rel = rel:sub(#ROOT + 2) end
                local mod = (rel:gsub("%.lua$", ""):gsub("/", "."))
                if not NOT_MODULES[mod] then mods[#mods + 1] = mod end
            end
            p:close()
        end
    end
    table.sort(mods)
    return mods
end

local mods = luaModules()
local loaded = 0
for _, mod in ipairs(mods) do
    local good, err = pcall(require, mod)
    if good then loaded = loaded + 1 end
    ok(good, string.format("require %s: %s", mod, tostring(err)))
end
print(string.format("[smoke] %d/%d modules loaded", loaded, #mods))

-- --- Pass 2: the boot decode, for real ---------------------------------

local SpriteLoader = require("services.SpriteLoader")
local Manifest     = require("models.sprite_manifest")

local sl = SpriteLoader:new()
local good, err = pcall(function() sl:loadAll() end)
ok(good, "SpriteLoader:loadAll: " .. tostring(err))

local indexed = 0
for _ in pairs(sl.paths) do indexed = indexed + 1 end
ok(indexed > 500, "sprite index looks empty: " .. indexed .. " names")
print(string.format("[smoke] %d sprite names indexed", indexed))

-- The loader must stay lazy. Indexing the tree is a directory walk; the
-- pixels are not touched until something asks for a sprite. This is the
-- contract the boot-time saving rests on, and it is invisible from the
-- outside — a loader that decoded everything would pass every other check
-- here and just cost eight seconds of boot.
c_decodes = DECODES
ok(c_decodes == 0, "the scan decoded " .. c_decodes .. " images; it must decode none")

local sample
for name in pairs(sl.paths) do
    if name:sub(1, 6) ~= "cards/" and sl.sprites[name] == nil then sample = name; break end
end
ok(sample ~= nil, "no undecoded sprite to sample")
if sample then
    DECODES = 0
    ok(sl:hasSprite(sample) == true, "hasSprite finds an indexed sprite")
    ok(DECODES == 0, "hasSprite decoded " .. DECODES .. " images; it must decode none")
    ok(sl:hasSprite("no/such/sprite/anywhere") == false, "hasSprite is false for an unknown name")

    DECODES = 0
    ok(sl:getSprite(sample) ~= nil, "getSprite returns an image")
    ok(DECODES == 1, "the first getSprite decoded " .. DECODES .. " images; expected 1")
    DECODES = 0
    ok(sl:getSprite(sample) ~= nil, "getSprite still returns it")
    ok(DECODES == 0, "the second getSprite decoded again; the cache is not holding")
end

local wanted
good, err = pcall(function() wanted = Manifest.onScreenAtBoot() end)
ok(good, "sprite_manifest.onScreenAtBoot: " .. tostring(err))
wanted = wanted or {}
ok(#wanted > 50, "boot manifest looks empty: " .. #wanted .. " names")

-- Every name the data asks for must resolve to a file. A miss is art that
-- silently does not draw, which is how a renamed folder hides for weeks.
--
-- Four kinds of miss are already known and are NOT failures. They are
-- listed rather than filtered by pattern so each one has to be justified,
-- and they are printed every run so they stay visible instead of rotting
-- into an ignored allowlist. Anything not on this list fails.
local KNOWN_GAPS = {
    -- Baked procedurally into the pool AFTER the preload runs, by
    -- views/HouseArt.bake. Never files.
    house_poster_wall  = "baked at boot by HouseArt",
    -- A room_layout id whose art is the baked house_poster_wall above; the
    -- manifest asks for both the id and its sprite field.
    the_house_poster   = "layout id, draws through house_poster_wall",
    -- Catalog entries with no sprite of their own: the manifest falls back
    -- to the id, and there is no file by that name. They draw as text.
    tilt               = "catalog item ships without art",
    -- The whole icon set. There is no assets/sprites/ui directory and there
    -- never was one (confirmed against the pre-existing build/PokerIdle.love,
    -- which contains zero sprites/ui entries), so every {icon} in copy has
    -- always fallen back to its text form.
    ["ui/icons/achip"]         = "no assets/sprites/ui directory exists",
    ["ui/icons/chip"]          = "no assets/sprites/ui directory exists",
    ["ui/icons/cursor"]        = "no assets/sprites/ui directory exists",
    ["ui/icons/cursor_speed"]  = "no assets/sprites/ui directory exists",
    ["ui/icons/focus"]         = "no assets/sprites/ui directory exists",
    ["ui/icons/heater"]        = "no assets/sprites/ui directory exists",
    ["ui/icons/pot_control"]   = "no assets/sprites/ui directory exists",
    ["ui/icons/settings"]      = "no assets/sprites/ui directory exists",
    ["ui/icons/sharper_reads"] = "no assets/sprites/ui directory exists",
    ["ui/icons/shove"]         = "no assets/sprites/ui directory exists",
    ["ui/icons/tilt"]          = "no assets/sprites/ui directory exists",
    -- Four decks name a .gif back. LOVE cannot decode GIF at all, so these
    -- four have never had a back texture. Converting them to PNG would
    -- change what the player sees, so it is a content decision, not a fix
    -- this test should make.
    ["cards/backs/01-robot"]   = "ships as .gif; LOVE cannot decode GIF",
    ["cards/backs/02-castle"]  = "ships as .gif; LOVE cannot decode GIF",
    ["cards/backs/04-hand"]    = "ships as .gif; LOVE cannot decode GIF",
    ["cards/backs/07-beach"]   = "ships as .gif; LOVE cannot decode GIF",
}

local missing, known = {}, {}
for _, name in ipairs(wanted) do
    if not sl:hasSprite(name) then
        if KNOWN_GAPS[name] then known[name] = true else missing[#missing + 1] = name end
    end
end
if next(known) then
    local names = {}
    for name in pairs(known) do names[#names + 1] = name end
    table.sort(names)
    print(string.format("[smoke] %d known art gaps (unchanged, not failures):", #names))
    for _, name in ipairs(names) do
        print(string.format("          %-26s %s", name, KNOWN_GAPS[name]))
    end
end
if #missing > 0 then
    table.sort(missing)
    ok(false, string.format("%d manifest sprites do not resolve: %s",
        #missing, table.concat(missing, ", ")))
end

local n
good, err = pcall(function() n = sl:preload(wanted, "cards/") end)
ok(good, "SpriteLoader:preload: " .. tostring(err))
print(string.format("[smoke] %d sprites decoded by the boot preload", n or 0))
ok((n or 0) > 50, "preload decoded almost nothing: " .. tostring(n))

-- The deck colour pass. A synthetic back: a pale 3px border, and a body
-- that is 60% red and 40% blue in stripes. The answer is the body's mean
-- (a red-leaning purple), never a pure stripe and never the border.
do
    local W, H = 48, 64
    local fake = {
        getWidth  = function() return W end,
        getHeight = function() return H end,
        getPixel  = function(_, x, y)
            if x < 3 or y < 3 or x >= W - 3 or y >= H - 3 then return 0.95, 0.93, 0.85, 1 end
            if (x % 5) < 3 then return 0.85, 0.10, 0.12, 1 end
            return 0.10, 0.15, 0.80, 1
        end,
    }
    local col = SpriteLoader.backColorOf(fake)
    ok(col ~= nil, "backColorOf returned nothing for a readable back")
    if col then
        ok(col[1] > col[3] and col[1] < 0.75 and col[3] > 0.25 and col[2] < 0.3,
           string.format("back colour should be the body's red-leaning mean, got %.2f %.2f %.2f",
                         col[1], col[2], col[3]))
    end
    ok(SpriteLoader.backColorOf({ getWidth = function() return 10 end,
                                  getHeight = function() return 10 end }) == nil,
       "backColorOf must return nil when the data cannot be read")
    ok(sl:backColor("cards/backs/03-fish") == nil,
       "headless: no colour for a back whose pixels were not readable")
end

-- Every card, since the felt shows them the instant it opens.
local cards = 0
for name in pairs(sl.paths) do
    if name:sub(1, 6) == "cards/" then
        cards = cards + 1
        if sl.sprites[name] == nil then
            ok(false, "card not decoded by preload: " .. name)
        end
    end
end
print(string.format("[smoke] %d card sprites, all decoded", cards))

-- --- Report ------------------------------------------------------------

for _, f in ipairs(fails) do print("  FAIL " .. f) end
print(string.format("%d checks, %d failures", checks, #fails))
os.exit(#fails == 0 and 0 or 1)
