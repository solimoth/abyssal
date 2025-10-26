local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local replicatedVfx = ReplicatedStorage:WaitForChild("VFXSystem")
local birdFolder = replicatedVfx:WaitForChild("Birds")
local birdTemplate = birdFolder:WaitForChild("BirdSprite1")

local EFFECT_FOLDER_NAME = "VFXSystem"
local MIN_PLAYER_HEIGHT = 898.011
local SPAWN_HEIGHT_MIN = 986
local SPAWN_HEIGHT_MAX = 1026
local MIN_SPAWN_DELAY = 4.5
local MAX_SPAWN_DELAY = 11
local MIN_LIFETIME = 3
local MAX_LIFETIME = 7
local MIN_SPEED = 8
local MAX_SPEED = 15
local MIN_HORIZONTAL_OFFSET = 10
local MAX_HORIZONTAL_OFFSET = 28
local MIN_BOB_AMPLITUDE = 1.5
local MAX_BOB_AMPLITUDE = 4
local MIN_BOB_FREQUENCY = 0.25
local MAX_BOB_FREQUENCY = 0.6
local FADE_PORTION = 0.22

local function getEffectFolder()
    local folder = Workspace:FindFirstChild(EFFECT_FOLDER_NAME)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = EFFECT_FOLDER_NAME
        folder.Parent = Workspace
    end

    folder:SetAttribute("ManagedByClient", true)

    return folder
end

local effectFolder = getEffectFolder()

local function cloneBird()
    local clone = birdTemplate:Clone()
    clone.Anchored = true
    clone.CanCollide = false
    clone.CanTouch = false
    clone.CanQuery = false
    clone.CastShadow = false

    local decals = {}

    for _, descendant in clone:GetDescendants() do
        if descendant:IsA("Decal") or descendant:IsA("Texture") then
            descendant.Transparency = 1
            table.insert(decals, descendant)
        end
    end

    clone.Transparency = 1
    clone.Parent = effectFolder

    return clone, decals
end

local function setVisibility(birdInstance, decals, alpha)
    local visibility = math.clamp(alpha, 0, 1)
    local transparency = 1 - visibility

    for _, decal in ipairs(decals) do
        if decal.Parent then
            decal.Transparency = transparency
        end
    end

    if birdInstance.Transparency ~= 1 then
        birdInstance.Transparency = 1
    end
end

local function getCharacterRoot(player)
    local character = player.Character
    if not character then
        return nil
    end

    local rootPart = character:FindFirstChild("HumanoidRootPart")
    local head = character:FindFirstChild("Head")

    if rootPart and head then
        return rootPart, head
    end

    return nil
end

local function getHorizontalDirection(rng)
    local angle = rng:NextNumber(0, math.pi * 2)
    return Vector3.new(math.cos(angle), 0, math.sin(angle)).Unit
end

local function computeSpawnPosition(rootPart, head, rng)
    local basePosition = head.Position
    local horizontalOffset = rng:NextNumber(MIN_HORIZONTAL_OFFSET, MAX_HORIZONTAL_OFFSET)
    local direction = getHorizontalDirection(rng)
    local offsetPosition = basePosition + direction * horizontalOffset
    local targetHeight = rng:NextNumber(SPAWN_HEIGHT_MIN, SPAWN_HEIGHT_MAX)
    local minimumHeight = head.Position.Y + 6
    local spawnHeight = math.max(targetHeight, minimumHeight)

    return Vector3.new(offsetPosition.X, spawnHeight, offsetPosition.Z), direction
end

local function createBirdData(player, rng, serverTime)
    local rootPart, head = getCharacterRoot(player)
    if not rootPart then
        return nil
    end

    local spawnPosition, horizontalDirection = computeSpawnPosition(rootPart, head, rng)
    local birdInstance, decals = cloneBird()

    local lifetime = rng:NextNumber(MIN_LIFETIME, MAX_LIFETIME)
    local speed = rng:NextNumber(MIN_SPEED, MAX_SPEED)
    local bobAmplitude = rng:NextNumber(MIN_BOB_AMPLITUDE, MAX_BOB_AMPLITUDE)
    local bobFrequency = rng:NextNumber(MIN_BOB_FREQUENCY, MAX_BOB_FREQUENCY)
    local bobPhase = rng:NextNumber(0, math.pi * 2)

    local data = {
        instance = birdInstance,
        decals = decals,
        owner = player,
        spawnTime = serverTime,
        lifetime = lifetime,
        startPosition = spawnPosition,
        direction = horizontalDirection,
        speed = speed,
        baseHeight = spawnPosition.Y,
        bobAmplitude = bobAmplitude,
        bobFrequency = bobFrequency,
        bobPhase = bobPhase,
        fadeTime = lifetime * FADE_PORTION,
    }

    birdInstance.CFrame = CFrame.lookAt(spawnPosition, spawnPosition + horizontalDirection)
    setVisibility(birdInstance, decals, 0)

    return data
end

local function updateBird(data, serverTime)
    local elapsed = serverTime - data.spawnTime
    if elapsed >= data.lifetime then
        return false
    end

    local direction = data.direction
    local distanceTravelled = data.speed * elapsed
    local horizontalPosition = data.startPosition + direction * distanceTravelled
    local bobOffset = math.sin((elapsed * data.bobFrequency * math.pi * 2) + data.bobPhase) * data.bobAmplitude
    local currentPosition = Vector3.new(horizontalPosition.X, data.baseHeight + bobOffset, horizontalPosition.Z)

    local lookVector = (direction + Vector3.new(0, 0.04, 0)).Unit
    data.instance.CFrame = CFrame.lookAt(currentPosition, currentPosition + lookVector)

    local visibility = 1
    if elapsed < data.fadeTime then
        visibility = elapsed / data.fadeTime
    else
        local remaining = data.lifetime - elapsed
        if remaining < data.fadeTime then
            visibility = remaining / data.fadeTime
        end
    end

    setVisibility(data.instance, data.decals, visibility)

    return true
end

local activeBirds = {}
local playerState = {}

local baseSeed = math.floor(Workspace:GetServerTimeNow() * 1000)

local function ensurePlayerState(player)
    local state = playerState[player]
    if state then
        return state
    end

    local seed = (player.UserId % 2^31) + baseSeed
    local rng = Random.new(seed)

    state = {
        rng = rng,
        nextSpawn = Workspace:GetServerTimeNow() + rng:NextNumber(MIN_SPAWN_DELAY, MAX_SPAWN_DELAY),
        active = 0,
    }

    playerState[player] = state

    return state
end

local function queueNextSpawn(state, serverTime)
    local delay = state.rng:NextNumber(MIN_SPAWN_DELAY, MAX_SPAWN_DELAY)
    state.nextSpawn = serverTime + delay
end

local MAX_BIRDS_PER_PLAYER = 3

local function spawnBirdForPlayer(player, state, serverTime)
    local birdData = createBirdData(player, state.rng, serverTime)
    if not birdData then
        queueNextSpawn(state, serverTime)
        return
    end

    table.insert(activeBirds, birdData)
    state.active = state.active + 1
    queueNextSpawn(state, serverTime)
end

local function cleanupPlayerState(player)
    for index = #activeBirds, 1, -1 do
        if activeBirds[index].owner == player then
            removeBird(index)
        end
    end

    playerState[player] = nil
end

for _, player in ipairs(Players:GetPlayers()) do
    ensurePlayerState(player)
end

Players.PlayerAdded:Connect(function(player)
    ensurePlayerState(player)
end)
Players.PlayerRemoving:Connect(function(player)
    cleanupPlayerState(player)
end)

local function removeBird(index)
    local data = activeBirds[index]
    local instance = data.instance

    if instance then
        instance:Destroy()
    end

    local state = playerState[data.owner]
    if state then
        state.active = math.max(0, state.active - 1)
    end

    table.remove(activeBirds, index)
end

RunService.Heartbeat:Connect(function()
    local serverTime = Workspace:GetServerTimeNow()

    for index = #activeBirds, 1, -1 do
        local data = activeBirds[index]
        if not updateBird(data, serverTime) then
            removeBird(index)
        end
    end

    for player, state in pairs(playerState) do
        local rootPart = getCharacterRoot(player)
        if rootPart then
            local rootPosition = rootPart.Position
            if rootPosition.Y < MIN_PLAYER_HEIGHT then
                state.nextSpawn = math.max(state.nextSpawn, serverTime + 1)
            elseif state.active < MAX_BIRDS_PER_PLAYER and serverTime >= state.nextSpawn then
                spawnBirdForPlayer(player, state, serverTime)
            end
        end
    end
end)
