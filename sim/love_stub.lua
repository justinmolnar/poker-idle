-- sim/love_stub.lua
--
-- The parts of LOVE that headless checks need, in one place.
--
-- sim/harness.lua has its own minimal shim for the ENGINE suite (a clock, a
-- seeded rng, mute audio) and does not need any of this. What the view and
-- service checks need is different and was being rewritten per file: a font
-- with deterministic, content-dependent widths; a graphics table that
-- RECORDS the primitives it was asked to draw; an in-memory filesystem.
-- Five scratch harnesses each carried their own copy.
--
-- Nothing here decides anything. A check installs the base, layers on the
-- one specialisation it needs, and reads back what the code under test did.

local Stub = {}

-- A table whose every unread key is a no-op function. The escape hatch for
-- the long tail of love.graphics state calls no check cares about.
function Stub.noops(t)
    return setmetatable(t or {}, { __index = function(tt, k)
        local f = function() end
        rawset(tt, k, f)
        return f
    end })
end

-- A font whose widths depend on the string, so a cache that mixes two
-- strings or two fonts shows up as a wrong number rather than passing by
-- luck. Half the height per character, which is close enough to the real
-- 8/16/24 faces for layout code to behave.
function Stub.font(h)
    h = h or 16
    local per = math.floor(h / 2)
    local font
    font = {
        getHeight   = function() return h end,
        getWidth    = function(_, s) return #tostring(s) * per end,
        getBaseline = function() return h - 2 end,
        getAscent   = function() return h - 3 end,
        getDescent  = function() return -3 end,
        setFilter   = function() end,
        getWrap     = function(_, s, w)
            local out, cur = {}, ""
            for word in tostring(s):gmatch("%S+") do
                local try = (cur == "") and word or (cur .. " " .. word)
                if #try * per > w and cur ~= "" then
                    out[#out + 1] = cur
                    cur = word
                else
                    cur = try
                end
            end
            out[#out + 1] = cur
            return w, out
        end,
    }
    return font
end

-- An in-memory filesystem. Returns the backing table so a check can inspect
-- exactly what landed on "disk" and how many times.
function Stub.memoryFS()
    local files = { _writes = 0 }
    love.filesystem = Stub.noops({
        getInfo = function(p) return files[p] and { type = "file", size = #files[p] } or nil end,
        read    = function(p) return files[p] end,
        write   = function(p, s) files._writes = files._writes + 1; files[p] = s; return true end,
        remove  = function(p) files[p] = nil; return true end,
        getSaveDirectory    = function() return "" end,
        getWorkingDirectory = function() return "." end,
        getDirectoryItems   = function() return {} end,
        isFused             = function() return false end,
    })
    return files
end

-- Swap love.graphics for one that counts primitives and simulates canvases.
-- The handle's `calls` is keyed by primitive name; `canvases` counts how
-- many render targets were allocated since the last reset.
function Stub.recorder()
    local h = { calls = {}, canvases = 0 }
    local stack = {}
    local function note(k) h.calls[k] = (h.calls[k] or 0) + 1 end
    local function canvas(w, ht)
        h.canvases = h.canvases + 1
        return { _w = w, _h = ht,
                 setFilter = function() end,
                 release   = function() end,
                 getWidth  = function(s) return s._w end,
                 getHeight = function(s) return s._h end }
    end
    function h.reset() h.calls = {}; h.canvases = 0 end
    function h.total()
        local n = 0
        for _, v in pairs(h.calls) do n = n + v end
        return n
    end

    love.graphics = Stub.noops({
        getDimensions = function() return 1600, 900 end,
        getWidth      = function() return 1600 end,
        getHeight     = function() return 900 end,
        getColor      = function() return 1, 1, 1, 1 end,
        getFont       = function() return nil end,
        newCanvas     = function(w, ht) return canvas(w, ht) end,
        -- No transform stack here, so a point maps to itself. Returning
        -- nothing (the default no-op) made every anchor the views register
        -- through it nil, which the readers then did arithmetic on.
        transformPoint = function(x, y) return x, y end,
        inverseTransformPoint = function(x, y) return x, y end,
        getCanvas     = function() return stack[#stack] end,
        setCanvas     = function(c)
            if c then stack[#stack + 1] = c else stack[#stack] = nil end
        end,
        circle    = function() note("circle") end,
        arc       = function() note("arc") end,
        polygon   = function() note("polygon") end,
        rectangle = function() note("rectangle") end,
        line      = function() note("line") end,
        print     = function() note("print") end,
        printf    = function() note("print") end,
        draw      = function() note("draw") end,
    })
    return h
end

-- The baseline: enough love for a view or service module to load and run.
-- Graphics is inert; call Stub.recorder() after this to make it count.
function Stub.base()
    -- The game runs on LuaJIT (Lua 5.1 semantics), which has math.log10;
    -- 5.2 removed it and these checks run under 5.4. Restoring it here
    -- rather than editing the game keeps the game's code the code that
    -- ships.
    if not math.log10 then math.log10 = function(x) return math.log(x, 10) end end

    love = love or {}
    love.math = Stub.noops({
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
    love.timer = Stub.noops({
        getTime  = function() return os.clock() end,
        getDelta = function() return 1 / 60 end,
        getFPS   = function() return 60 end,
    })
    love.graphics = Stub.noops({
        getDimensions = function() return 1600, 900 end,
        getWidth      = function() return 1600 end,
        getHeight     = function() return 900 end,
        getColor      = function() return 1, 1, 1, 1 end,
        getFont       = function() return nil end,
        getCanvas     = function() return nil end,
        -- No transform stack here, so a point maps to itself. Returning
        -- nothing (the default no-op) made every anchor the views register
        -- through it nil, which the readers then did arithmetic on.
        transformPoint = function(x, y) return x, y end,
        inverseTransformPoint = function(x, y) return x, y end,
    })
    love.mouse    = Stub.noops({ getPosition = function() return -1, -1 end,
                                 getX = function() return -1 end,
                                 getY = function() return -1 end,
                                 isDown = function() return false end })
    love.keyboard = Stub.noops({ isDown = function() return false end })
    love.system   = Stub.noops({ getOS = function() return "Windows" end })
    love.window   = Stub.noops({ getMode = function() return 1600, 900, {} end,
                                 getDesktopDimensions = function() return 1920, 1080 end })
    love.audio    = Stub.noops({
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
    love.sound = Stub.noops({})
    love.event = Stub.noops({})
    love.getVersion = function() return 11, 4, 0, "Mysterious Mysteries" end
    return love
end

-- A tiny collecting assertion set. Checks accumulate instead of throwing so
-- one run reports every failure rather than the first.
function Stub.checker()
    local c = { fails = {}, checks = 0 }
    function c.ok(cond, what)
        c.checks = c.checks + 1
        if not cond then c.fails[#c.fails + 1] = what end
        return cond
    end
    function c.eq(a, b, what)
        return c.ok(a == b, string.format("%s: %s ~= %s", what, tostring(a), tostring(b)))
    end
    function c.report(title)
        for _, f in ipairs(c.fails) do print("  FAIL " .. f) end
        print(string.format("%s: %d checks, %d failures", title, c.checks, #c.fails))
        return #c.fails
    end
    return c
end

return Stub
