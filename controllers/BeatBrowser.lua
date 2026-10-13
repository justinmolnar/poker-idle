-- controllers/BeatBrowser.lua
--
-- The beat browser (F9, dev builds only): every House beat in the game's
-- own skin. It parks the real game — a deep copy of the state, saving
-- disabled — builds a throwaway stage with what the beat needs
-- (controllers/beat_stages), plays the beat through the real director and
-- views, and walks it: ←/→ a line, ↑/↓ a beat, Home/End the ends. A
-- panel (top-left) says what the beat is — its trigger, screen, the
-- line's fields, which anchors are lit and which are missing, how many
-- lines and pages the box drew — and holds a note per line (N) or per
-- beat (B), kept in tools/story_notes.json. F9 or Esc restores the game.
--
-- DEV ONLY. main.lua builds it behind FEATURES.DEV_HOTKEYS and the build's
-- cut leaves the module out (build-tools/demo_cut.py CUT_MODULES);
-- every reference in shipped code is nil-guarded.

local Theme     = require("views.Theme")
local HintMarks = require("views.HintMarks")
local Stages    = require("controllers.beat_stages")
local json      = require("lib.json")

local BeatBrowser = {}
BeatBrowser.__index = BeatBrowser

local NOTES_FILE = "tools/story_notes.json"
local PANEL_W    = 440   -- × ui_scale

function BeatBrowser:new(game)
    return setmetatable({
        game     = game,
        on       = false,
        beat_i   = 1,
        snapshot = nil,
        _real_save = nil,
        _driver  = nil,      -- the shove being driven to its hold, or nil
        _hooked  = {},       -- line hooks run on this stage
        _target_line = 1,
        recipe   = nil,
        built    = nil,
        notes    = { version = 1, beats = {} },
        editing  = nil,      -- "line" | "beat" while typing a note
        edit_buf = "",
        _key_repeat_was = nil,
    }, BeatBrowser)
end

function BeatBrowser:active() return self.on end

-- ── The real game, parked and restored ────────────────────────────────

local function deepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[deepCopy(k, seen)] = deepCopy(x, seen) end
    return out
end

local function everyState(game, fn)
    local sm = game.state_machine
    for _, st in pairs((sm and sm.states) or {}) do fn(st) end
end

local function resetAll(game)
    everyState(game, function(st) if type(st.fullReset) == "function" then st:fullReset() end end)
    if game.story and game.story.reset then game.story:reset() end
    if game.hints and game.hints.reset then game.hints:reset() end
end

function BeatBrowser:enter()
    if self.on then return end
    local g  = self.game
    local st = g.state
    local sm = g.state_machine
    if g.grind and g.grind.pool and (sm:current() == "grind" or sm:current() == "room") then
        st.tables = g.grind.pool:serialize()
    end
    self.snapshot = { meta = deepCopy(st:serializeMeta()), run = deepCopy(st:serializeRun()),
                      screen = sm:current() }
    self._real_save = g.save
    g.save = function() return true end          -- nothing the stage does reaches the file
    self.on = true
    self:_loadNotes()
    if love.keyboard and love.keyboard.setKeyRepeat then
        self._key_repeat_was = love.keyboard.hasKeyRepeat and love.keyboard.hasKeyRepeat() or false
        love.keyboard.setKeyRepeat(true)
    end
    print("[beats] browsing; the game is parked (nothing saves until F9)")
    self:gotoBeat(self.beat_i or 1, 1)
end

function BeatBrowser:exit()
    if not self.on then return end
    local g = self.game
    if self.editing then self:_endEdit() end
    g.save = self._real_save or g.save
    self._real_save = nil
    self._driver = nil
    g.state:wipeAll()
    g.state:applySaved(self.snapshot)
    resetAll(g)
    if g.grind then g.grind:invalidateEffects(); g.grind:reloadPool() end
    self.on = false
    if love.keyboard and love.keyboard.setKeyRepeat then love.keyboard.setKeyRepeat(self._key_repeat_was or false) end
    g.state_machine:switch(self.snapshot.screen or "grind")
    self.snapshot = nil
    print("[beats] the game is back")
end

function BeatBrowser:toggle()
    if self.on then self:exit() else self:enter() end
end

-- ── The stage ─────────────────────────────────────────────────────────

function BeatBrowser:beats() return self.game.story.story.beats end

function BeatBrowser:gotoBeat(i, line)
    local beats = self:beats()
    local n = #beats
    if n == 0 then return end
    self.beat_i = ((i - 1) % n) + 1
    self._target_line = line or 1
    self:buildStage()
end

function BeatBrowser:buildStage()
    local g = self.game
    local beat = self:beats()[self.beat_i]
    if g.story.beat then g.story:reset() end
    g.state:wipeAll()
    resetAll(g)
    self.recipe  = Stages.forBeat(beat)
    self._hooked = {}
    self.built   = Stages.apply(self.recipe, g)
    g.state_machine:switch(self.recipe.screen)
    if self.recipe.shove then
        self._driver = { to = self.recipe.shove.to or "result", t = 0 }
    else
        self._driver = nil
        self:_play()
    end
end

-- The shove, driven to its phase or hold a frame at a time (the view's
-- skip lands on the next hold; the book and the flyer land after).
function BeatBrowser:_drive(dt)
    local d  = self._driver
    local ss = self.game.state_machine.states.shove
    local sv = ss and ss.view
    if not (d and sv) then self._driver = nil; return end
    d.t = d.t + dt
    local phase = sv.phase
    if phase == "room" or phase == "buildup" then
        sv:skip()
        return
    elseif phase == "ready_to_deal" or phase == "idle" then
        return                                   -- the state fires the gauntlet on its tick
    end
    if d.to == "running" then
        if phase == "running" then d.done = true end
    elseif sv.hold_id == d.to then
        d.done = true
    elseif phase == "running" or phase == "hold" then
        sv:skip()
        return
    end
    if not d.done then return end
    -- What the beat points at has to have landed.
    local cm, fl = ss.catalog_modal, ss.deck_flyer
    if cm and cm.isLanded and not (cm:isLanded() or cm:isOpen()) then return end
    if fl and fl.isLanded and not (fl:isLanded() or fl:isOpen()) then return end
    self._driver = nil
    self:_play()
end

-- Play the beat on the stage and walk to the target line.
function BeatBrowser:_play()
    local g = self.game
    g.story:playBeat(self.beat_i, { browse = true })
    self:_runHooks()
    for _ = 2, self._target_line do
        if not g.story:stepLine(1) then break end
        self:_runHooks()
    end
end

function BeatBrowser:_runHooks()
    local hooks = self.recipe and self.recipe.at_line
    local i = self:lineIndex()
    if not (hooks and i) then return end
    for at, name in pairs(hooks) do
        if at <= i and not self._hooked[at] then
            self._hooked[at] = true
            Stages.hook(name, self.game)
        end
    end
end

function BeatBrowser:lineIndex()
    local line = self.game.story:currentLine()
    return line and line.index or nil
end

-- ── Walking ───────────────────────────────────────────────────────────

function BeatBrowser:step(dir)
    local g = self.game
    if self._driver then return end
    local beats = self:beats()
    local i = self:lineIndex() or 1
    if dir > 0 then
        if g.story.beat == nil or not g.story:stepLine(1) then
            self:gotoBeat(self.beat_i + 1, 1)
            return
        end
        if g.story.beat == nil then self:gotoBeat(self.beat_i + 1, 1); return end
        self:_runHooks()
    else
        if i <= 1 then
            local prev = ((self.beat_i - 2) % #beats) + 1
            self:gotoBeat(prev, #beats[prev].lines)
        else
            self._target_line = i - 1
            self:buildStage()
        end
    end
end

-- ── Input (routed here by controllers/InputController while active) ───

function BeatBrowser:keypressed(key)
    if self.editing then
        if key == "escape" then self:_endEdit()
        elseif key == "return" or key == "kpenter" then self.edit_buf = self.edit_buf .. "\n"
        elseif key == "backspace" then
            local b = self.edit_buf
            self.edit_buf = b:sub(1, (utf8 and utf8.offset(b, -1) or #b) - 1)
        end
        return true
    end
    if key == "f9" or key == "escape" then self:exit()
    elseif key == "right" then self:step(1)
    elseif key == "left"  then self:step(-1)
    elseif key == "down"  then self:gotoBeat(self.beat_i + 1, 1)
    elseif key == "up"    then self:gotoBeat(self.beat_i - 1, 1)
    elseif key == "home"  then self:gotoBeat(1, 1)
    elseif key == "end"   then self:gotoBeat(#self:beats(), 1)
    elseif key == "r"     then self:buildStage()
    elseif key == "n"     then self:_beginEdit("line")
    elseif key == "b"     then self:_beginEdit("beat")
    else return false end
    return true
end

function BeatBrowser:textinput(text)
    if not self.editing then return false end
    self.edit_buf = self.edit_buf .. text
    return true
end

function BeatBrowser:update(dt)
    if not self.on then return end
    if self._driver then self:_drive(dt) end
end

-- ── Notes (tools/story_notes.json) ────────────────────────────────────

local function sourcePath()
    local src = love.filesystem and love.filesystem.getSource and love.filesystem.getSource()
    if not src or src == "" or src:match("%.love$") or src:match("%.exe$") then return nil end
    return src .. "/" .. NOTES_FILE
end

function BeatBrowser:_loadNotes()
    local text
    local p = sourcePath()
    if p then
        local f = io.open(p, "rb")
        if f then text = f:read("*a"); f:close() end
    end
    if not text and love.filesystem.getInfo("story_notes.json") then
        text = love.filesystem.read("story_notes.json")
    end
    local ok, data = pcall(json.decode, text or "")
    if ok and type(data) == "table" and type(data.beats) == "table" then
        self.notes = data
    else
        self.notes = { version = 1, beats = {} }
    end
end

function BeatBrowser:_saveNotes()
    local ok, text = pcall(json.encode, self.notes, true)
    if not ok then print("[beats] notes not saved: " .. tostring(text)); return end
    local p = sourcePath()
    if p then
        local f = io.open(p, "wb")
        if f then f:write(text); f:close(); print("[beats] notes written to " .. NOTES_FILE); return end
    end
    love.filesystem.write("story_notes.json", text)
    local dir = love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory() or "the save directory"
    print("[beats] notes written to " .. dir .. "/story_notes.json")
end

function BeatBrowser:_noteSlot(kind)
    local beat = self:beats()[self.beat_i]
    local b = self.notes.beats[beat.id]
    if not b then b = { note = "", lines = {} }; self.notes.beats[beat.id] = b end
    b.lines = b.lines or {}
    if kind == "beat" then return b, "note" end
    local i = tostring(self:lineIndex() or 1)
    return b.lines, i
end

function BeatBrowser:_beginEdit(kind)
    local t, k = self:_noteSlot(kind)
    self.editing  = kind
    self.edit_buf = t[k] or ""
end

function BeatBrowser:_endEdit()
    local t, k = self:_noteSlot(self.editing)
    local text = self.edit_buf:gsub("%s+$", "")
    t[k] = (text ~= "") and text or nil
    self.editing, self.edit_buf = nil, ""
    self:_saveNotes()
end

-- ── The panel ─────────────────────────────────────────────────────────

-- A condition in words: its kind and fields, nested for all/any/not.
local function condProse(c)
    if type(c) ~= "table" then return tostring(c) end
    if c.kind == "all" or c.kind == "any" then
        local parts = {}
        for _, sub in ipairs(c) do parts[#parts + 1] = condProse(sub) end
        return c.kind .. "{ " .. table.concat(parts, (c.kind == "all") and " & " or " | ") .. " }"
    elseif c.kind == "not" then
        return "not " .. condProse(c[1])
    end
    local fields = {}
    for k, v in pairs(c) do
        if k ~= "kind" and type(k) == "string" then
            local vs = type(v) == "table" and ("{" .. table.concat(v, ",") .. "}") or tostring(v)
            fields[#fields + 1] = k .. "=" .. vs
        end
    end
    table.sort(fields)
    return tostring(c.kind) .. (#fields > 0 and (" " .. table.concat(fields, " ")) or "")
end

local function anchorList(a)
    if type(a) == "string" then return { a } end
    return a or {}
end

local function wrap(font, text, w)
    if font.getWrap then
        local _, lines = font:getWrap(text, w)
        return lines
    end
    return { text }
end

function BeatBrowser:_lengthOf(line)
    local rv = self.game.story_view and self.game.story_view._reveal
    if not (rv and line) then return nil end
    if rv.key ~= tostring(line.beat or "") .. ":" .. tostring(line.index or 0) then return nil end
    local per_page = {}
    for _, pg in ipairs(rv.pages) do
        local n = 1
        for _ in pg:gmatch("\n") do n = n + 1 end
        per_page[#per_page + 1] = n
    end
    local words = 0
    for _ in tostring(rv.text or ""):gmatch("%S+") do words = words + 1 end
    return { pages = #rv.pages, lines = per_page, words = words }
end

function BeatBrowser:draw()
    if not self.on then return end
    local g = self.game
    local fonts = g.fonts
    local font = fonts and fonts.sm
    if not font then return end
    local s  = g.ui_scale or 1
    local fl = math.floor
    local D  = Theme.debug
    local beats = self:beats()
    local beat = beats[self.beat_i]
    local line = g.story:currentLine()
    local li   = line and line.index or self._target_line
    local src  = beat.lines[li or 1]

    local rows = {}   -- { text, color }
    local function row(text, color) rows[#rows + 1] = { text, color or D.hud_text } end
    row(("beat %d/%d  %s   screen %s%s%s%s"):format(self.beat_i, #beats, beat.id, beat.screen,
        beat.pause and "   pause" or "", beat.sound and ("   sound " .. beat.sound) or "",
        beat.recheck and "   recheck" or ""), D.hud_accent)
    row("trigger: " .. condProse(beat.trigger), D.hud_dim)
    if self._driver then
        row("building the shove… (" .. tostring(self._driver.to) .. ")", D.hud_warn)
    end
    local f = {}
    if src then
        if src.force then f[#f + 1] = "force" end
        if src.cue then f[#f + 1] = ('cue "' .. src.cue .. '"') end
        if src.wait then f[#f + 1] = "wait " .. condProse(src.wait) .. (src.wait_fresh and " (fresh)" or "") end
        if src.show then f[#f + 1] = "show " .. condProse(src.show) end
        if src.hold ~= nil then f[#f + 1] = "hold " .. tostring(src.hold)
        elseif not src.wait then f[#f + 1] = "hold click" end
        if src.delay then f[#f + 1] = "delay " .. tostring(src.delay) end
        if src.grant then f[#f + 1] = "grant " .. tostring(src.grant) end
    end
    row(("line %d/%d   %s"):format(li or 0, #beat.lines, table.concat(f, " | ")))
    local names = anchorList(src and src.anchor)
    if #names == 0 then
        row("anchors: none", D.hud_dim)
    else
        for _, a in ipairs(names) do
            local lit = HintMarks.freshAnchor(a) ~= nil
            row((lit and "  + " or "  - ") .. a .. (lit and "" or "   (not on screen)"), lit and D.hud_accent or D.hud_warn)
        end
    end
    local len = self:_lengthOf(line)
    if len then
        row(("length: %d page%s · %s line%s · %d words"):format(len.pages, len.pages == 1 and "" or "s",
            table.concat(len.lines, " + "), (#len.lines == 1 and len.lines[1] == 1) and "" or "s", len.words), D.hud_dim)
    end
    if self.recipe then
        row("stage: " .. tostring(self.recipe.desc) .. ((self.recipe.at_line and " · line hooks") or ""), D.hud_dim)
    end
    local nb = self.notes.beats[beat.id]
    local beat_note = nb and nb.note
    local line_note = nb and nb.lines and nb.lines[tostring(li or 1)]
    if self.editing == "beat" then row("beat note (typing, Esc saves): " .. self.edit_buf .. "_", D.hud_hot)
    elseif beat_note then row("beat note: " .. beat_note, D.hud_hot) end
    if self.editing == "line" then row("line note (typing, Esc saves): " .. self.edit_buf .. "_", D.hud_hot)
    elseif line_note then row("line note: " .. line_note, D.hud_hot) end
    row("[←/→] line   [↑/↓] beat   [Home/End]   [R] rebuild   [N] line note   [B] beat note   [F9/Esc] back", D.hud_dim)

    local pad = fl(8 * s)
    local w   = fl(PANEL_W * s)
    local lh  = font:getHeight()
    local lines = {}
    for _, r in ipairs(rows) do
        for _, l in ipairs(wrap(font, r[1], w - pad * 2)) do lines[#lines + 1] = { l, r[2] } end
    end
    local h = pad * 2 + #lines * lh
    local x, y = fl(8 * s), fl(8 * s)
    love.graphics.setColor(D.hud_bg)
    love.graphics.rectangle("fill", x, y, w, h, fl(3 * s))
    love.graphics.setColor(D.hud_border)
    love.graphics.rectangle("line", x, y, w, h, fl(3 * s))
    love.graphics.setFont(font)
    local cy = y + pad
    for _, l in ipairs(lines) do
        love.graphics.setColor(l[2])
        love.graphics.print(l[1], x + pad, cy)
        cy = cy + lh
    end
    love.graphics.setColor(1, 1, 1, 1)
end

return BeatBrowser
