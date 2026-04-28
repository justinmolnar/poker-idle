-- Simple class implementation for Lua
local Object = {}
Object.__index = Object

-- Create a new instance of a class
function Object:new(...)
    local instance = setmetatable({}, self)
    if instance.init then
        instance:init(...)
    end
    return instance
end

-- Create a new class that inherits from this one
function Object:extend(name)
    local cls = {}
    cls.__index = cls
    cls.__tostring = function() return tostring(name) end
    cls.super = self
    setmetatable(cls, self)
    return cls
end

-- Call superclass method
function Object:super(method, ...)
    if self.super and self.super[method] then
        return self.super[method](self, ...)
    end
end

return Object
