--!strict
-- DynamicWaveService.server.lua
-- Bootstraps the editable-mesh based ocean surface and keeps it updated on the
-- server so that physics and visuals remain consistent for all players.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaveConfig = require(ReplicatedStorage.Modules.WaveConfig)
local WaveField = require(ReplicatedStorage.Modules.WaveField)

local waveField = WaveField.new(WaveConfig)

RunService.Heartbeat:Connect(function(dt)
        if waveField then
                waveField:Step(dt)
        end
end)

-- Clean up automatically when the script is disabled or destroyed.
script.Destroying:Connect(function()
        if waveField then
                waveField:Destroy()
                waveField = nil
        end
end)
