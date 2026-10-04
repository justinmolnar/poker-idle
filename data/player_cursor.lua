-- data/player_cursor.lua
--
-- The player's own mouse cursor (services/PlayerCursor): a chunky pixel
-- arrow, so it is never lost among the swarm's cursors on a busy board.
-- Each character is one art pixel: "X" outline, "#" fill, "." clear. The
-- hot spot is the tip, the top-left pixel. Each art pixel is drawn
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
    fill    = { 1, 1, 1 },
    px_per_100h = 0.25,
    min_px  = 2,
    max_px  = 4,
}
