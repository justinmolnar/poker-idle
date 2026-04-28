-- lib/input_dispatcher.lua
-- Routes input events to the first registered handler whose predicate passes.
-- Usage:
--   dispatcher:on(event, predicate_fn_or_nil, handler_fn)
--   dispatcher:dispatch(event, ...)

local InputDispatcher = {}
InputDispatcher.__index = InputDispatcher

function InputDispatcher:new()
    return setmetatable({ _handlers = {} }, InputDispatcher)
end

-- Register a handler for an event.
-- predicate: function(...) → bool, called with the same args as handler. nil = always matches.
-- handler:   function(...) — called when predicate passes. Stops further handlers.
function InputDispatcher:on(event, predicate, handler)
    if not self._handlers[event] then self._handlers[event] = {} end
    table.insert(self._handlers[event], { pred = predicate, fn = handler })
end

-- Dispatch an event. Calls the first handler whose predicate passes, then stops.
function InputDispatcher:dispatch(event, ...)
    for _, h in ipairs(self._handlers[event] or {}) do
        if not h.pred or h.pred(...) then
            h.fn(...)
            return
        end
    end
end

return InputDispatcher
