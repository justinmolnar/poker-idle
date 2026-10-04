-- data/player_cursor.lua
--
-- The player's own mouse cursor (services/PlayerCursor), and the shapes it
-- takes for what is under it (services/CursorIntent picks one per frame).
-- Every shape is the same yellow body, black outline and white rim, so the
-- cursor is always recognisably the player's among the swarm's white ones.
--
-- Art: one character per art pixel. "X" outline, "#" fill (the body),
-- "." clear; in a badge "B" is the badge's colour and "W" white. A `rim`
-- pixel is added around every outline pixel. `hot` is the hot spot in art
-- pixels (before the rim), x then y from the top left. Each art pixel is
-- drawn `px_per_100h` screen pixels per 100 px of window height, rounded,
-- clamped to [min_px, max_px].
--
-- Colours are an { r, g, b } or a Theme token name (views/Theme: a semantic
-- colour such as "chance" or "lost", or a currency such as "achip").
return {
    outline = { 0, 0, 0 },
    fill    = { 1.0, 0.86, 0.12 },
    rim     = { 1, 1, 1 },
    px_per_100h = 0.4,
    min_px  = 3,
    max_px  = 6,

    shapes = {
        arrow = { hot = { 0, 0 }, rows = {
            "X...........",
            "XX..........",
            "X#X.........",
            "X##X........",
            "X###X.......",
            "X####X......",
            "X#####X.....",
            "X######X....",
            "X#######X...",
            "X########X..",
            "X#####XXXXX.",
            "X##X##X.....",
            "X#X.X##X....",
            "XX..X##X....",
            "X....X##X...",
            ".....X##X...",
            "......XX....",
        } },
        -- A click here does something.
        point = { hot = { 4, 0 }, rows = {
            "....XX..........",
            "...X##X.........",
            "...X##X.........",
            "...X##X.........",
            "...X##XXX.......",
            "...X##X##XXX....",
            "...X##X##X##XX..",
            "XX.X##X##X##X#X.",
            "X#XX##########X.",
            "X##X##########X.",
            ".X############X.",
            ".X###########X..",
            "..X##########X..",
            "..X#########X...",
            "...X########X...",
            "...X########X...",
            "...XXXXXXXXXX...",
        } },
        -- This can be picked up (a table's header).
        open = { hot = { 8, 8 }, rows = {
            "....XX.XX.XX.XX..",
            "...X##X##X##X##X.",
            "...X##X##X##X##X.",
            "...X##X##X##X##X.",
            "...X##X##X##X##X.",
            "XX.X##X##X##X##X.",
            "X#XX###########X.",
            "X##X###########X.",
            ".X#############X.",
            ".X#############X.",
            "..X###########X..",
            "..X###########X..",
            "...X#########X...",
            "...X#########X...",
            "...XXXXXXXXXXX...",
        } },
        -- Carrying it.
        fist = { hot = { 8, 8 }, rows = {
            "................",
            "................",
            "................",
            "....XXXXXXXX....",
            "...X#X##X##XX...",
            "..XX#X##X##X#X..",
            ".X##X##X##X##X..",
            ".X############X.",
            ".X############X.",
            "..X##########X..",
            "..X##########X..",
            "...X########X...",
            "...X########X...",
            "...XXXXXXXXXX...",
        } },
        -- The game is holding the click (a story line).
        wait = { hot = { 6, 7 }, rows = {
            "XXXXXXXXXXXX",
            "X..........X",
            ".X########X.",
            ".X########X.",
            "..X######X..",
            "...X####X...",
            "....X##X....",
            "....X##X....",
            "...X.##.X...",
            "..X...#..X..",
            ".X........X.",
            ".X...##...X.",
            "X...####...X",
            "X##########X",
            "XXXXXXXXXXXX",
        } },
    },

    -- Badges on the arrow's lower right (art pixels from the arrow's top
    -- left; the image grows to hold them).
    badge_at = { 7, 10 },
    badges = {
        -- Hovering here explains something (a tooltip, nothing to click).
        info = { color = "chance", rows = {
            ".XXXXXX.",
            "XBBWWBBX",
            "XBWBBWBX",
            "XBBBBWBX",
            "XBBBWBBX",
            "XBBWBBBX",
            "XBBBBBBX",
            "XBBWBBBX",
            ".XXXXXX.",
        } },
        -- A click here is refused (can't afford, would strand, full board).
        no = { color = "lost", rows = {
            ".XXXXXX.",
            "XWBBBBWX",
            "XBWBBWBX",
            "XBBWWBBX",
            "XBBWWBBX",
            "XBWBBWBX",
            "XWBBBBWX",
            ".XXXXXX.",
        } },
        -- Locked: not yet earned.
        lock = { color = { 0.59, 0.59, 0.62 }, rows = {
            "..XXXX..",
            ".X....X.",
            ".X....X.",
            "XXXXXXXX",
            "XBBBBBBX",
            "XBBWWBBX",
            "XBBWWBBX",
            "XBBBBBBX",
            "XXXXXXXX",
        } },
    },

    -- What each cursor kind is made of.
    kinds = {
        arrow = { shape = "arrow" },
        point = { shape = "point" },
        open  = { shape = "open" },
        fist  = { shape = "fist" },
        wait  = { shape = "wait" },
        info  = { shape = "arrow", badge = "info" },
        no    = { shape = "arrow", badge = "no" },
        lock  = { shape = "arrow", badge = "lock" },
    },

    -- Over the focus cap, or after the underflow: now and then the cursor
    -- shows a corrupted frame for a moment. `every` is the gap between
    -- glitches in seconds (a random pick in the range, shortened the
    -- further over focus: divided by 1 + `strain_speedup` per table over);
    -- `show` how long one lasts; `frames` how many corrupted variants each
    -- kind has; their stray pixels take `color`.
    glitch = {
        every  = { 1.5, 4.0 },
        show   = { 0.06, 0.12 },
        frames = 3,
        color  = "achip",
        strain_speedup = 0.5,
    },
}
