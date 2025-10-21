local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LightingService = require(script.Parent:WaitForChild("LightingService"))

local ZONES_FOLDER_NAME = "Zones"
local zones = {}
local folderConnections = {}

local function parseEnum(enumType, value)
    if typeof(value) == "EnumItem" then
        return value
    elseif typeof(value) == "string" and enumType[value] then
        return enumType[value]
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

local function configurationExists(name)
    local configurationsFolder = ReplicatedStorage:FindFirstChild("LightingConfigurations")
    if not configurationsFolder then
        return true
    end

    local configuration = configurationsFolder:FindFirstChild(name)
    return configuration ~= nil
end

local function applyZone(player, zoneState)
    if not configurationExists(zoneState.configuration) then
        if not zoneState.warnedMissing then
            warn(("[LightingZoneService] Zone '%s' references unknown lighting configuration '%s'"):format(
                zoneState.debugName,
                zoneState.configuration
            ))
            zoneState.warnedMissing = true
        end
        return
    end

    zoneState.warnedMissing = nil

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
    if not part:IsA("BasePart") then
        return
    end

    if zones[part] then
        unregisterZone(part)
    end

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
        warnedMissing = nil,
        debugName = part:GetFullName(),
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

local function clearAllZones()
    for part, zoneState in pairs(zones) do
        cleanupZone(zoneState)
        zones[part] = nil
    end
end

local function disconnectFolderConnections()
    for _, connection in ipairs(folderConnections) do
        connection:Disconnect()
    end
    table.clear(folderConnections)
end

local function registerFolder(folder)
    disconnectFolderConnections()
    clearAllZones()

    folderConnections = {
        folder.DescendantAdded:Connect(function(descendant)
            if descendant:IsA("BasePart") then
                registerZone(descendant)
            end
        end),
        folder.DescendantRemoving:Connect(function(descendant)
            if descendant:IsA("BasePart") then
                unregisterZone(descendant)
            end
        end),
        folder.AncestryChanged:Connect(function(_, parent)
            if not parent then
                disconnectFolderConnections()
                clearAllZones()
            end
        end),
    }

    for _, descendant in ipairs(folder:GetDescendants()) do
        if descendant:IsA("BasePart") then
            registerZone(descendant)
        end
    end
end

local function tryAttachToZonesFolder()
    local folder = Workspace:FindFirstChild(ZONES_FOLDER_NAME)
    if folder and folder:IsA("Folder") then
        registerFolder(folder)
    end
end

Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Folder") and child.Name == ZONES_FOLDER_NAME then
        registerFolder(child)
    end
end)

tryAttachToZonesFolder()

return {}
