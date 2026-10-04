-- data/player_cursor.lua
--
-- The player's own mouse cursor (services/PlayerCursor): a chunky pixel
-- arrow, so it is never lost among the swarm's cursors on a busy board.
-- Each character is one art pixel: "X" outline, "#" fill, "." clear. A
-- `rim` pixel is added around the outline on every side (so the arrow
-- reads on dark felt and on bright cards alike). The hot spot is the tip.
-- Each art pixel is drawn
-- `px_per_100h` screen pixels per 100 px of window height, rounded,
-- clamped to [min_px, max_px].
return {
    rows = {
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
    },
    outline = { 0, 0, 0 },
    -- A colour nothing else on the board wears: the swarm is white.
    fill    = { 1.0, 0.86, 0.12 },
    rim     = { 1, 1, 1 },
    px_per_100h = 0.4,
    min_px  = 3,
    max_px  = 6,
}
