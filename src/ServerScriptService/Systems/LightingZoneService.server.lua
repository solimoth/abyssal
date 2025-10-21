local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local LightingService = require(script.Parent:WaitForChild("LightingService"))

local TAG_NAME = "LightingZone"

local zones = {}

local function parseEnum(enum, value)
    if typeof(value) == "EnumItem" then
        return value
    elseif typeof(value) == "string" and enum[value] then
        return enum[value]
    end

    return nil
end

local function getPlayerFromPart(part)
    local character = part.Parent
    if not character then
        return nil
    end

    local player = Players:GetPlayerFromCharacter(character)
    if player then
        return player
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Parent then
        player = Players:GetPlayerFromCharacter(humanoid.Parent)
    end

    return player
end

local function applyZone(player, zoneState)
    LightingService:SetSource(player, zoneState.sourceId, zoneState.configuration, {
        transitionTime = zoneState.transitionTime,
        easingStyle = zoneState.easingStyle,
        easingDirection = zoneState.easingDirection,
        priority = zoneState.priority,
    })
end

local function clearZone(player, zoneState)
    LightingService:ClearSource(player, zoneState.sourceId)
end

local function onZoneTouched(zoneState, otherPart)
    if not otherPart:IsA("BasePart") then
        return
    end

    local player = getPlayerFromPart(otherPart)
    if not player then
        return
    end

    local counts = zoneState.touchingPlayers
    local current = counts[player] or 0
    counts[player] = current + 1

    if current == 0 then
        applyZone(player, zoneState)
    end
end

local function onZoneTouchEnded(zoneState, otherPart)
    if not otherPart:IsA("BasePart") then
        return
    end

    local player = getPlayerFromPart(otherPart)
    if not player then
        return
    end

    local counts = zoneState.touchingPlayers
    local current = counts[player]
    if not current then
        return
    end

    current -= 1
    if current <= 0 then
        counts[player] = nil
        clearZone(player, zoneState)
    else
        counts[player] = current
    end
end

local function cleanupZone(zoneState)
    for _, connection in ipairs(zoneState.connections) do
        connection:Disconnect()
    end

    for player in pairs(zoneState.touchingPlayers) do
        clearZone(player, zoneState)
    end
end

local function registerZone(part)
    local configurationName = part:GetAttribute("LightingConfiguration") or part.Name
    local transitionTime = part:GetAttribute("LightingTransitionTime")
    local easingStyle = parseEnum(Enum.EasingStyle, part:GetAttribute("LightingEasingStyle"))
    local easingDirection = parseEnum(Enum.EasingDirection, part:GetAttribute("LightingEasingDirection"))
    local priority = part:GetAttribute("LightingPriority")
    local sourceId = part:GetAttribute("LightingSourceId") or ("zone:" .. part:GetDebugId())

    local zoneState = {
        part = part,
        configuration = configurationName,
        transitionTime = transitionTime,
        easingStyle = easingStyle,
        easingDirection = easingDirection,
        priority = typeof(priority) == "number" and priority or 0,
        sourceId = sourceId,
        touchingPlayers = {},
        connections = {},
    }

    zoneState.connections = {
        part.Touched:Connect(function(otherPart)
            onZoneTouched(zoneState, otherPart)
        end),
        part.TouchEnded:Connect(function(otherPart)
            onZoneTouchEnded(zoneState, otherPart)
        end),
        part.AncestryChanged:Connect(function(_, parent)
            if not parent then
                cleanupZone(zoneState)
                zones[part] = nil
            end
        end),
    }

    zones[part] = zoneState
end

local function unregisterZone(part)
    local zoneState = zones[part]
    if not zoneState then
        return
    end

    cleanupZone(zoneState)
    zones[part] = nil
end

for _, part in ipairs(CollectionService:GetTagged(TAG_NAME)) do
    if part:IsA("BasePart") then
        registerZone(part)
    end
end

CollectionService:GetInstanceAddedSignal(TAG_NAME):Connect(function(part)
    if part:IsA("BasePart") then
        registerZone(part)
    end
end)

CollectionService:GetInstanceRemovedSignal(TAG_NAME):Connect(unregisterZone)
