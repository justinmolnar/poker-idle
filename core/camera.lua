-- core/camera.lua
local Camera = {}
Camera.__index = Camera

function Camera:new(x, y, scale)
    local instance = setmetatable({}, Camera)
    instance.x = x or 0
    instance.y = y or 0
    instance.scale = scale or 1
    return instance
end

function Camera:apply()
    love.graphics.push()
    love.graphics.scale(self.scale, self.scale)
    love.graphics.translate(-self.x, -self.y)
end

function Camera:remove()
    love.graphics.pop()
end

return Camera
