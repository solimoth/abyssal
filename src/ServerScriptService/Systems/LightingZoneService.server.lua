local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LightingService = require(script.Parent:WaitForChild("LightingService"))

local ZONES_FOLDER_NAME = "Zones"
local zones = {}
local folderConnections = {}
local fallbackSourceIds = setmetatable({}, { __mode = "k" })

local function getFallbackSourceId(part)
    local sourceId = fallbackSourceIds[part]
    if not sourceId then
        sourceId = "zone:" .. HttpService:GenerateGUID(false)
        fallbackSourceIds[part] = sourceId
    end

    return sourceId
end

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

local function handlePlayerRemoving(player)
    for _, zoneState in pairs(zones) do
        if zoneState.touchingPlayers[player] then
            zoneState.touchingPlayers[player] = nil
            clearZone(player, zoneState)
        end
    end
end

Players.PlayerRemoving:Connect(handlePlayerRemoving)

Players.PlayerAdded:Connect(function(player)
    player.CharacterRemoving:Connect(function()
        handlePlayerRemoving(player)
    end)
end)

for _, player in ipairs(Players:GetPlayers()) do
    player.CharacterRemoving:Connect(function()
        handlePlayerRemoving(player)
    end)
end

local function onZoneTouched(zoneState, otherPart)
    if not otherPart:IsA("BasePart") then
        return
    end

    local player = getPlayerFromPart(otherPart)
    if not player then
        return
    end

    local record = zoneState.touchingPlayers[player]
    if not record then
        record = {
            parts = {},
            count = 0,
        }
        zoneState.touchingPlayers[player] = record
    end

    if record.parts[otherPart] then
        return
    end

    record.parts[otherPart] = true
    record.count += 1

    if record.count == 1 then
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

    local record = zoneState.touchingPlayers[player]
    if not record or not record.parts[otherPart] then
        return
    end

    record.parts[otherPart] = nil
    record.count -= 1

    if record.count <= 0 then
        zoneState.touchingPlayers[player] = nil
        clearZone(player, zoneState)
    end
end

local function cleanupZone(zoneState)
    for _, connection in ipairs(zoneState.connections) do
        connection:Disconnect()
    end

    for player in pairs(zoneState.touchingPlayers) do
        clearZone(player, zoneState)
        zoneState.touchingPlayers[player] = nil
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
    local sourceId = part:GetAttribute("LightingSourceId")
    if typeof(sourceId) ~= "string" or sourceId == "" then
        sourceId = getFallbackSourceId(part)
    end

    local zoneState = {
        part = part,
        configuration = configurationName,
        transitionTime = transitionTime,
        easingStyle = easingStyle,
        easingDirection = easingDirection,
        priority = typeof(priority) == "number" and priority or 0,
        sourceId = sourceId,
        touchingPlayers = setmetatable({}, { __mode = "k" }),
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
