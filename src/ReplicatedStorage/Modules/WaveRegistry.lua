--!strict
-- WaveRegistry.lua
-- Lightweight global registry that allows the dynamic wave field to expose
-- sampling utilities to systems that require water height queries (boats,
-- characters, particle effects, etc.).

local WaveRegistry = {}

local activeField: any? = nil

function WaveRegistry.SetActiveField(field)
        activeField = field
end

function WaveRegistry.GetActiveField()
        return activeField
end

function WaveRegistry.Sample(position: Vector3): number?
        if activeField then
                return activeField:GetHeight(position)
        end
        return nil
end

return WaveRegistry
