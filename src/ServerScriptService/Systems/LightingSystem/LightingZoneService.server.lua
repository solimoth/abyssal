local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local LightingService = require(script.Parent:WaitForChild("LightingService"))

local LightingSystemFolder = ReplicatedStorage:WaitForChild("LightingSystem")

local ZONES_FOLDER_NAME = "Zones"
local zones = {}
local folderConnections = {}
local fallbackSourceIds = setmetatable({}, { __mode = "k" })

local clearTable = table.clear or function(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local function getCharacterRootPart(player)
    local character = player.Character
    if not character then
        return nil
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root
    end

    local primary = character.PrimaryPart
    if primary and primary:IsA("BasePart") then
        return primary
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("BasePart") then
            return child
        end
    end

    return nil
end

local function distanceFromPart(part, position)
    local localPosition = part.CFrame:PointToObjectSpace(position)
    local halfSize = part.Size * 0.5

    local dx = math.max(math.abs(localPosition.X) - halfSize.X, 0)
    local dy = math.max(math.abs(localPosition.Y) - halfSize.Y, 0)
    local dz = math.max(math.abs(localPosition.Z) - halfSize.Z, 0)

    if dx == 0 and dy == 0 and dz == 0 then
        return 0
    end

    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

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
    local configurationsFolder = LightingSystemFolder:FindFirstChild("LightingConfigurations")
    if not configurationsFolder then
        return true
    end

    local configuration = configurationsFolder:FindFirstChild(name, true)
    return configuration ~= nil
end

local PROGRESS_EPSILON = 0.01

local function applyZone(player, zoneState, progress)
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

    local options = {
        easingStyle = zoneState.easingStyle,
        easingDirection = zoneState.easingDirection,
        priority = zoneState.priority,
        transitionProgress = progress,
    }

    if zoneState.transitionTime ~= nil then
        options.transitionTime = zoneState.transitionTime
    end

    LightingService:SetSource(player, zoneState.sourceId, zoneState.configuration, options)
end

local function clearZone(player, zoneState)
    LightingService:ClearSource(player, zoneState.sourceId)
end

local function handlePlayerRemoving(player)
    for _, zoneState in pairs(zones) do
        if zoneState.touchingPlayers[player] then
            zoneState.touchingPlayers[player] = nil
            zoneState.playerStates[player] = nil
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

local heartbeatConnection

local function updateZoneOccupancy(zoneState, playerPositions)
    local overlappingParts

    local success, result = pcall(function()
        return Workspace:GetPartsInPart(zoneState.part)
    end)

    if success then
        overlappingParts = result
    else
        warn(("[LightingZoneService] Failed to query parts for zone '%s': %s"):format(
            zoneState.debugName,
            result
        ))
        overlappingParts = {}
    end

    local currentPlayers = zoneState.nearbyPlayers
    clearTable(currentPlayers)

    for _, otherPart in ipairs(overlappingParts) do
        local player = getPlayerFromPart(otherPart)
        if player then
            local existing = currentPlayers[player]
            if existing == nil or existing > 0 then
                currentPlayers[player] = 0
            end
        end
    end

    if zoneState.transitionDistance > 0 and playerPositions then
        local threshold = zoneState.transitionDistance
        local part = zoneState.part

        for player, position in pairs(playerPositions) do
            if not currentPlayers[player] then
                local distance = distanceFromPart(part, position)
                if distance <= threshold then
                    currentPlayers[player] = distance
                end
            end
        end
    end

    for player, distance in pairs(currentPlayers) do
        local inside = distance == 0
        local targetProgress

        if inside then
            targetProgress = 1
        elseif zoneState.transitionDistance > 0 then
            targetProgress = math.clamp(1 - (distance / zoneState.transitionDistance), 0, 1)
        else
            targetProgress = 0
        end

        if targetProgress > 0 then
            local playerState = zoneState.playerStates[player]
            if not playerState then
                playerState = {
                    progress = -math.huge,
                }
                zoneState.playerStates[player] = playerState
            end

            if math.abs(targetProgress - playerState.progress) >= PROGRESS_EPSILON then
                applyZone(player, zoneState, targetProgress)
                playerState.progress = targetProgress
            elseif inside and playerState.progress ~= 1 then
                applyZone(player, zoneState, 1)
                playerState.progress = 1
            end

            if not zoneState.touchingPlayers[player] then
                zoneState.touchingPlayers[player] = true
            end
        elseif zoneState.touchingPlayers[player] then
            zoneState.touchingPlayers[player] = nil
            zoneState.playerStates[player] = nil
            clearZone(player, zoneState)
        end
    end

    for player in pairs(zoneState.touchingPlayers) do
        if not currentPlayers[player] then
            zoneState.touchingPlayers[player] = nil
            zoneState.playerStates[player] = nil
            clearZone(player, zoneState)
        end
    end
end

local function updateZones()
    local playerPositions
    local positionsComputed = false

    for _, zoneState in pairs(zones) do
        if zoneState.transitionDistance > 0 then
            if not positionsComputed then
                positionsComputed = true
                playerPositions = {}

                for _, player in ipairs(Players:GetPlayers()) do
                    local rootPart = getCharacterRootPart(player)
                    if rootPart then
                        playerPositions[player] = rootPart.Position
                    end
                end
            end

            updateZoneOccupancy(zoneState, playerPositions)
        else
            updateZoneOccupancy(zoneState)
        end
    end
end

local function updateHeartbeatConnection()
    if next(zones) ~= nil then
        if not heartbeatConnection then
            heartbeatConnection = RunService.Heartbeat:Connect(updateZones)
        end
    elseif heartbeatConnection then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
end

local function cleanupZone(zoneState)
    for _, connection in ipairs(zoneState.connections) do
        connection:Disconnect()
    end

    for player in pairs(zoneState.touchingPlayers) do
        clearZone(player, zoneState)
        zoneState.touchingPlayers[player] = nil
        zoneState.playerStates[player] = nil
    end

    clearTable(zoneState.playerStates)
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
    local transitionDistance = part:GetAttribute("TransitionDistance")
    if typeof(transitionDistance) ~= "number" or transitionDistance <= 0 then
        transitionDistance = 0
    end
    if typeof(sourceId) ~= "string" or sourceId == "" then
        sourceId = getFallbackSourceId(part)
    end

    if not part.CanQuery then
        warn(("[LightingZoneService] Zone part '%s' has CanQuery disabled; lighting zone detection may not work as expected."):format(
            part:GetFullName()
        ))
    end

    local zoneState = {
        part = part,
        configuration = configurationName,
        transitionTime = transitionTime,
        easingStyle = easingStyle,
        easingDirection = easingDirection,
        priority = typeof(priority) == "number" and priority or 0,
        sourceId = sourceId,
        transitionDistance = transitionDistance,
        touchingPlayers = setmetatable({}, { __mode = "k" }),
        nearbyPlayers = {},
        playerStates = setmetatable({}, { __mode = "k" }),
        connections = {},
        warnedMissing = nil,
        debugName = part:GetFullName(),
    }

    zoneState.connections = {
        part.AncestryChanged:Connect(function(_, parent)
            if not parent then
                cleanupZone(zoneState)
                zones[part] = nil
                updateHeartbeatConnection()
            end
        end),
    }

    zones[part] = zoneState
    updateHeartbeatConnection()
    updateZoneOccupancy(zoneState)
end

local function unregisterZone(part)
    local zoneState = zones[part]
    if not zoneState then
        return
    end

    cleanupZone(zoneState)
    zones[part] = nil
    updateHeartbeatConnection()
end

local function clearAllZones()
    for part, zoneState in pairs(zones) do
        cleanupZone(zoneState)
        zones[part] = nil
    end

    updateHeartbeatConnection()
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
