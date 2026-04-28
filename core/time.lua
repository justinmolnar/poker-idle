-- core/time.lua
local Time = {}
Time.__index = Time

function Time:new()
    return setmetatable({ total_time = 0, delta_time = 0 }, Time)
end

function Time:update(dt)
    self.delta_time = dt
    self.total_time = self.total_time + dt
end

return Time
