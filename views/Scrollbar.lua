-- views/Scrollbar.lua
-- Stateless scrollbar helper. Caller owns scroll state (a single scroll_y
-- number) and passes it in along with the track rect + content_h on every
-- call. Returns are pure data; no love.graphics state mutated outside draw.

local Theme = require("views.Theme")

local Scrollbar = {}

function Scrollbar.width()  return Theme.space.scrollbar_w  end
function Scrollbar.margin() return Theme.space.widget_pad_x end

Scrollbar.MIN_HANDLE_H = 15
Scrollbar.WHEEL_NOTCH_PX = 20

function Scrollbar.thumbBounds(track_h, scroll_y, content_h)
    if content_h <= 0 or content_h <= track_h then return 0, 0 end
    local thumb_h    = math.max(Scrollbar.MIN_HANDLE_H,
                                track_h * (track_h / content_h))
    local max_scroll = math.max(0, content_h - track_h)
    local frac       = (max_scroll > 0) and (scroll_y / max_scroll) or 0
    local travel     = track_h - thumb_h
    return travel * frac, thumb_h
end

function Scrollbar.draw(track_x, track_y, track_h, scroll_y, content_h, hovered)
    local thumb_y, thumb_h = Scrollbar.thumbBounds(track_h, scroll_y, content_h)
    if thumb_h <= 0 then return end
    local w = Scrollbar.width()
    Theme.setColor(Theme.bg.sunken, 0.6)
    love.graphics.rectangle("fill", track_x, track_y, w, track_h)
    if hovered then
        Theme.setColor(Theme.fg.heading, 0.85)
    else
        Theme.setColor(Theme.fg.muted, 0.7)
    end
    love.graphics.rectangle("fill", track_x, track_y + thumb_y, w, thumb_h)
end

function Scrollbar.containsPoint(track_x, track_y, track_h, mx, my)
    local w = Scrollbar.width()
    return mx >= track_x and mx < track_x + w
       and my >= track_y and my < track_y + track_h
end

function Scrollbar.containsThumb(track_x, track_y, track_h, scroll_y, content_h, mx, my)
    if not Scrollbar.containsPoint(track_x, track_y, track_h, mx, my) then
        return false
    end
    local thumb_y, thumb_h = Scrollbar.thumbBounds(track_h, scroll_y, content_h)
    if thumb_h <= 0 then return false end
    return my >= track_y + thumb_y and my < track_y + thumb_y + thumb_h
end

function Scrollbar.scrollFromDrag(track_h, drag_dy, scroll_at_drag, content_h)
    local _, thumb_h = Scrollbar.thumbBounds(track_h, scroll_at_drag, content_h)
    local travel     = track_h - thumb_h
    local max_scroll = math.max(0, content_h - track_h)
    if travel <= 0 or max_scroll <= 0 then return scroll_at_drag end
    return math.max(0, math.min(max_scroll,
        scroll_at_drag + drag_dy * (max_scroll / travel)))
end

function Scrollbar.scrollFromTrackClick(track_y, track_h, click_y, content_h)
    local _, thumb_h = Scrollbar.thumbBounds(track_h, 0, content_h)
    local travel     = track_h - thumb_h
    local max_scroll = math.max(0, content_h - track_h)
    if travel <= 0 then return 0 end
    local frac = (click_y - track_y - thumb_h * 0.5) / travel
    return math.max(0, math.min(max_scroll, math.floor(max_scroll * frac + 0.5)))
end

function Scrollbar.clamp(scroll_y, track_h, content_h)
    local max_scroll = math.max(0, content_h - track_h)
    if scroll_y < 0 then return 0 end
    if scroll_y > max_scroll then return max_scroll end
    return scroll_y
end

return Scrollbar
