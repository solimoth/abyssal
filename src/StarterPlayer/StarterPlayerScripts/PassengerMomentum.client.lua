local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LOCAL_PLAYER = Players.LocalPlayer
local RAYCAST_DISTANCE = 12
local UPDATE_INTERVAL = 0.05
local DATA_EXPIRATION = 0.35
local AIRBORNE_TIMEOUT = 1.25

local character
local humanoid
local rootPart

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local RAYCAST_OFFSETS = {
    Vector3.new(0, 0, 0),
    Vector3.new(0.85, 0, 0.85),
    Vector3.new(-0.85, 0, 0.85),
    Vector3.new(0.85, 0, -0.85),
    Vector3.new(-0.85, 0, -0.85),
}

local lastGroundedInfo
local airborneState = {
    active = false,
    boat = nil,
    localOffset = nil,
    lastBoatVelocity = nil,
    relativeVelocity = Vector3.zero,
    startTime = 0,
}

local heartbeatConnection
local stateChangedConnection
local characterConnections = {}
local updateAccumulator = 0

local function clearCharacterConnections()
    for _, connection in ipairs(characterConnections) do
        connection:Disconnect()
    end
    table.clear(characterConnections)
end

local function resetTracking()
    lastGroundedInfo = nil
    airborneState.active = false
    airborneState.boat = nil
    airborneState.localOffset = nil
    airborneState.lastBoatVelocity = nil
    airborneState.relativeVelocity = Vector3.zero
    airborneState.startTime = 0
end

local function getBoatFromInstance(instance)
    local current = instance
    while current and current ~= Workspace do
        if current == character then
            return nil
        end

        if current:IsA("Model") then
            if current:GetAttribute("BoatId") or current:GetAttribute("BoatType") then
                return current
            end
        end

        current = current.Parent
    end

    return nil
end

local function findBoatBelow()
    if not rootPart then
        return nil
    end

    local baseCFrame = rootPart.CFrame
    for _, offset in ipairs(RAYCAST_OFFSETS) do
        local origin = baseCFrame:PointToWorldSpace(offset)
        local result = Workspace:Raycast(origin, Vector3.new(0, -RAYCAST_DISTANCE, 0), raycastParams)
        if result and result.Instance then
            local boat = getBoatFromInstance(result.Instance)
            if boat then
                return boat
            end
        end
    end

    return nil
end

local function sampleBoatVelocity(boat, localOffset)
    if not boat or not boat.PrimaryPart then
        return nil
    end

    local contactPosition
    if localOffset then
        contactPosition = boat.PrimaryPart.CFrame:PointToWorldSpace(localOffset)
    else
        contactPosition = boat.PrimaryPart.Position
    end

    return boat.PrimaryPart:GetVelocityAtPosition(contactPosition)
end

local function updateGroundedBoat(now)
    if not humanoid or humanoid.Health <= 0 or humanoid.Sit then
        resetTracking()
        return
    end

    if airborneState.active then
        if now - airborneState.startTime > AIRBORNE_TIMEOUT then
            resetTracking()
        end
        return
    end

    local boat = findBoatBelow()
    if boat and boat.PrimaryPart and rootPart then
        local boatCFrame = boat.PrimaryPart.CFrame
        local localOffset = boatCFrame:PointToObjectSpace(rootPart.Position)
        local boatVelocity = sampleBoatVelocity(boat, localOffset)
        if not boatVelocity then
            return
        end

        local rootVelocity = rootPart.AssemblyLinearVelocity
        local horizontalBoat = Vector3.new(boatVelocity.X, 0, boatVelocity.Z)
        local horizontalRoot = Vector3.new(rootVelocity.X, 0, rootVelocity.Z)

        lastGroundedInfo = lastGroundedInfo or {}
        lastGroundedInfo.boat = boat
        lastGroundedInfo.localOffset = localOffset
        lastGroundedInfo.lastBoatVelocity = horizontalBoat
        lastGroundedInfo.relativeVelocity = horizontalRoot - horizontalBoat
        lastGroundedInfo.lastUpdate = now
    else
        if lastGroundedInfo and lastGroundedInfo.lastUpdate then
            if now - lastGroundedInfo.lastUpdate > DATA_EXPIRATION then
                resetTracking()
            end
        end
    end
end

local function endAirborne()
    airborneState.active = false
    airborneState.boat = nil
    airborneState.localOffset = nil
    airborneState.lastBoatVelocity = nil
    airborneState.startTime = 0
end

local function beginAirborne()
    if not rootPart or not lastGroundedInfo or not lastGroundedInfo.boat then
        return
    end

    local now = os.clock()
    local boatVelocity = sampleBoatVelocity(lastGroundedInfo.boat, lastGroundedInfo.localOffset)
    if not boatVelocity then
        return
    end

    local currentVelocity = rootPart.AssemblyLinearVelocity
    local horizontalBoat = Vector3.new(boatVelocity.X, 0, boatVelocity.Z)
    local relativeVelocity = lastGroundedInfo.relativeVelocity
        or (Vector3.new(currentVelocity.X, 0, currentVelocity.Z) - horizontalBoat)
    local adjustedVelocity = Vector3.new(
        horizontalBoat.X + relativeVelocity.X,
        currentVelocity.Y,
        horizontalBoat.Z + relativeVelocity.Z
    )

    rootPart.AssemblyLinearVelocity = adjustedVelocity

    airborneState.active = true
    airborneState.boat = lastGroundedInfo.boat
    airborneState.localOffset = lastGroundedInfo.localOffset
    airborneState.lastBoatVelocity = horizontalBoat
    airborneState.relativeVelocity = relativeVelocity
    airborneState.startTime = now
end

local function maintainAirborneMomentum()
    if not airborneState.active or not rootPart then
        return
    end

    if not humanoid or humanoid.Health <= 0 or humanoid.Sit then
        endAirborne()
        return
    end

    local state = humanoid:GetState()
    if state ~= Enum.HumanoidStateType.Freefall
        and state ~= Enum.HumanoidStateType.Jumping
        and state ~= Enum.HumanoidStateType.FallingDown then
        endAirborne()
        return
    end

    local boat = airborneState.boat
    if not boat or not boat.Parent then
        endAirborne()
        return
    end

    local now = os.clock()
    if now - airborneState.startTime > AIRBORNE_TIMEOUT then
        endAirborne()
        return
    end

    local boatVelocity = sampleBoatVelocity(boat, airborneState.localOffset)
    if not boatVelocity then
        endAirborne()
        return
    end

    local horizontalBoat = Vector3.new(boatVelocity.X, 0, boatVelocity.Z)
    local lastBoatVelocity = airborneState.lastBoatVelocity or horizontalBoat
    local delta = horizontalBoat - lastBoatVelocity

    if delta.X ~= 0 or delta.Z ~= 0 then
        local currentVelocity = rootPart.AssemblyLinearVelocity
        rootPart.AssemblyLinearVelocity = Vector3.new(
            currentVelocity.X + delta.X,
            currentVelocity.Y,
            currentVelocity.Z + delta.Z
        )
    end

    airborneState.lastBoatVelocity = horizontalBoat
    airborneState.relativeVelocity = Vector3.new(
        rootPart.AssemblyLinearVelocity.X - horizontalBoat.X,
        0,
        rootPart.AssemblyLinearVelocity.Z - horizontalBoat.Z
    )
end

local function onHumanoidStateChanged(_, newState)
    if newState == Enum.HumanoidStateType.Freefall
        or newState == Enum.HumanoidStateType.Jumping
        or newState == Enum.HumanoidStateType.FallingDown then
        if not airborneState.active then
            beginAirborne()
        end
    else
        endAirborne()
    end
end

local function onHeartbeat(dt)
    maintainAirborneMomentum()

    updateAccumulator += dt
    if updateAccumulator < UPDATE_INTERVAL then
        return
    end

    updateAccumulator = 0

    local now = os.clock()
    updateGroundedBoat(now)
end

local function onCharacterAdded(newCharacter)
    clearCharacterConnections()
    resetTracking()

    character = newCharacter
    if not character then
        return
    end

    raycastParams.FilterDescendantsInstances = { character }

    humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
    rootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)

    if not humanoid or not rootPart then
        return
    end

    characterConnections = {
        humanoid.Died:Connect(resetTracking),
        character.AncestryChanged:Connect(function(_, parent)
            if not parent then
                clearCharacterConnections()
                resetTracking()
                humanoid = nil
                rootPart = nil
                character = nil
            end
        end),
    }

    if stateChangedConnection then
        stateChangedConnection:Disconnect()
    end
    stateChangedConnection = humanoid.StateChanged:Connect(onHumanoidStateChanged)
end

local function onCharacterRemoving()
    clearCharacterConnections()
    resetTracking()

    if stateChangedConnection then
        stateChangedConnection:Disconnect()
        stateChangedConnection = nil
    end

    humanoid = nil
    rootPart = nil
    character = nil
    raycastParams.FilterDescendantsInstances = {}
end

if heartbeatConnection then
    heartbeatConnection:Disconnect()
end
heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)

LOCAL_PLAYER.CharacterAdded:Connect(onCharacterAdded)
LOCAL_PLAYER.CharacterRemoving:Connect(onCharacterRemoving)

if LOCAL_PLAYER.Character then
    onCharacterAdded(LOCAL_PLAYER.Character)
end
