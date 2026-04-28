-- core/event_bus.lua
--
-- Two ways to listen:
--   subscribe(event, fn)  — called on publishes of that specific event.
--   addTap(fn)            — called on EVERY publish, receives (event, ...).
--
-- Taps are the explicit alternative to a `subscribe("*")` wildcard (which
-- this module deliberately does not support). Use them for cross-cutting
-- consumers that need the full stream.
local EventBus = {
    subscribers = {},
    taps        = {},
}

function EventBus:subscribe(event, callback)
    if not self.subscribers[event] then
        self.subscribers[event] = {}
    end
    table.insert(self.subscribers[event], callback)
end

function EventBus:publish(event, ...)
    if self.subscribers[event] then
        for _, callback in ipairs(self.subscribers[event]) do
            callback(...)
        end
    end
    local taps = self.taps
    if taps and #taps > 0 then
        for i = 1, #taps do
            taps[i](event, ...)
        end
    end
end

function EventBus:addTap(fn)
    if type(fn) ~= "function" then return end
    self.taps[#self.taps + 1] = fn
end

function EventBus:removeTap(fn)
    local taps = self.taps
    for i = 1, #taps do
        if taps[i] == fn then
            table.remove(taps, i)
            return
        end
    end
end

return EventBus
