-- build-tools/list_shipped_audio.lua
--
-- Prints every audio file path data/sounds.lua actually references, one per
-- line. build_web.py runs this (plain `lua`, from the repo root) to decide
-- which files inside the uVegas sample pack and the legacy top-level MPGs
-- are dead weight for the web build — the repo keeps everything, the
-- package ships only what the sound table can reach. Folders SoundLoader
-- discovers dynamically (assets/audio/items|room|felt) always ship whole
-- and are not judged here.

package.path = "./?.lua;" .. package.path

local Sounds = require("data.sounds")   -- pure data; requires only utils/sample_set

local seen = {}

local function collect(entry)
    if type(entry) ~= "table" then return end
    if entry.file then seen[entry.file] = true end
    if type(entry.files) == "table" then
        for _, f in ipairs(entry.files) do seen[f] = true end
    end
    if entry.layer then collect(entry.layer) end
end

for name, entry in pairs(Sounds) do
    if name ~= "_mix" then collect(entry) end
end

local out = {}
for p in pairs(seen) do out[#out + 1] = p end
table.sort(out)
for _, p in ipairs(out) do print(p) end
