--!strict
-- WaterColorController.lua
-- Shared client-side helper to coordinate water colour overrides between the
-- lighting controller and the wave renderer without requiring either script to
-- know about the other's internal state.

local WaterColorController = {}

type Listener = (Color3?) -> ()

local listeners: { Listener } = {}
local overrideColor: Color3? = nil

local function notifyListeners()
    for _, listener in ipairs(listeners) do
        task.spawn(listener, overrideColor)
    end
end

function WaterColorController.GetOverrideColor(): Color3?
    return overrideColor
end

function WaterColorController.SetOverrideColor(color: Color3?)
    if overrideColor == color then
        return
    end

    overrideColor = color
    notifyListeners()
end

function WaterColorController.OnOverrideChanged(listener: Listener)
    table.insert(listeners, listener)

    task.spawn(listener, overrideColor)

    local connection = {}

    function connection:Disconnect()
        local index = table.find(listeners, listener)
        if index then
            table.remove(listeners, index)
        end
    end

    return connection
end

return WaterColorController

