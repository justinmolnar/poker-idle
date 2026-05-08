-- utils/sample_set.lua
-- Builds an ordered list of file paths matching the "<prefix><NN>.<ext>"
-- convention used by sample-pack data tables. Engine-agnostic.

return function(prefix, count, ext)
    ext = ext or "wav"
    local t = {}
    for i = 1, count do
        t[i] = string.format("%s%02d.%s", prefix, i, ext)
    end
    return t
end
