-- data/rate_ticker.lua
--
-- The rail's earn-rate readout (views/GrindView `_buildRailComponents`,
-- GrindController:boardRate): the small "$/min" line above the bankroll
-- and the line graph in its tooltip. Sibling of data/history_bars.lua,
-- same role: layout knobs as a data table, read by the view, no code.
-- Pixel values are 1x design-space; the view scales them by ui_scale.
return {
    -- How far back a table's hands are counted for its hands-per-minute,
    -- and how much of the run the ticker shows. One number: the rate line
    -- and the graph under it describe the same minute.
    window_s     = 60,
    -- A table open for less than this is measured over this much anyway,
    -- so one quick hand on a fresh table does not read as 60 a minute.
    min_window_s = 5,
    -- The graph: the run's $/min as a line, the whole run, in buckets. A bucket
    -- starts this many seconds wide; past `buckets` of them, neighbours
    -- merge and the width doubles, so the whole run always fits and the
    -- picture compresses as the run grows.
    bucket_s     = 5,
    buckets      = 90,

    -- The graph row in the tooltip.
    w              = 180,
    h              = 36,
    line_w         = 1.5,
    baseline_alpha = 0.18,   -- the zero line
}
