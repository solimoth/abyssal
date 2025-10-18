local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LOCAL_PLAYER = Players.LocalPlayer
local RAYCAST_DISTANCE = 10
local UPDATE_INTERVAL = 0.05
local DATA_EXPIRATION = 0.35
local AIRBORNE_TIMEOUT = 1.5

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

local lastGroundedInfo = nil
local heartbeatConnection
local stateChangedConnection
local characterConnections = {}
local updateAccumulator = 0
local maintainMomentum = false

local function clearCharacterConnections()
	for _, connection in ipairs(characterConnections) do
		connection:Disconnect()
	end
	table.clear(characterConnections)
end

local function resetGroundedInfo()
        if lastGroundedInfo then
                lastGroundedInfo.boat = nil
                lastGroundedInfo.relativeVelocity = nil
                lastGroundedInfo.boatVelocity = nil
                lastGroundedInfo.lastUpdate = nil
                lastGroundedInfo.airStartTime = nil
                lastGroundedInfo.isAirborne = nil
                lastGroundedInfo.localContactOffset = nil
        end
        lastGroundedInfo = nil
        maintainMomentum = false
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

local function updateGroundedBoat(now)
        if not humanoid or humanoid.Health <= 0 then
                resetGroundedInfo()
                return
        end

        if humanoid.Sit then
                resetGroundedInfo()
                return
        end

        if lastGroundedInfo and lastGroundedInfo.isAirborne then
                if now - (lastGroundedInfo.airStartTime or 0) > AIRBORNE_TIMEOUT then
                        resetGroundedInfo()
                end
                return
        end

        local boat = findBoatBelow()
        if boat and boat.PrimaryPart and rootPart then
                local boatCFrame = boat.PrimaryPart.CFrame
                local localContactOffset = boatCFrame:PointToObjectSpace(rootPart.Position)
                local contactPosition = boatCFrame:PointToWorldSpace(localContactOffset)
                local boatVelocity = boat.PrimaryPart:GetVelocityAtPosition(contactPosition)
                local rootVelocity = rootPart.AssemblyLinearVelocity

                if not lastGroundedInfo then
                        lastGroundedInfo = {}
                end

                local relativeVelocity = Vector3.new(
                        rootVelocity.X - boatVelocity.X,
                        0,
                        rootVelocity.Z - boatVelocity.Z
                )

                lastGroundedInfo.boat = boat
                lastGroundedInfo.boatVelocity = boatVelocity
                lastGroundedInfo.relativeVelocity = relativeVelocity
                lastGroundedInfo.lastUpdate = now
                lastGroundedInfo.localContactOffset = localContactOffset
        else
                if lastGroundedInfo and lastGroundedInfo.lastUpdate then
                        if now - lastGroundedInfo.lastUpdate > DATA_EXPIRATION then
                                resetGroundedInfo()
                        end
                end
        end
end

local function applyBoatMomentum()
        if not rootPart or not lastGroundedInfo or not lastGroundedInfo.lastUpdate then
                return
        end

        local now = os.clock()
        if now - lastGroundedInfo.lastUpdate > DATA_EXPIRATION then
                resetGroundedInfo()
                return
        end

        local boatVelocity = lastGroundedInfo.boatVelocity
        local boat = lastGroundedInfo.boat
        if boat and boat.Parent and boat.PrimaryPart then
                local contactPosition
                if lastGroundedInfo.localContactOffset then
                        contactPosition = boat.PrimaryPart.CFrame:PointToWorldSpace(lastGroundedInfo.localContactOffset)
                elseif rootPart then
                        contactPosition = rootPart.Position
                end

                if contactPosition then
                        boatVelocity = boat.PrimaryPart:GetVelocityAtPosition(contactPosition)
                end
        end

        if not boatVelocity then
                resetGroundedInfo()
                return
        end

        local relativeVelocity = lastGroundedInfo.relativeVelocity or Vector3.zero
        local currentVelocity = rootPart.AssemblyLinearVelocity

        local horizontalBoat = Vector3.new(boatVelocity.X, 0, boatVelocity.Z)
        local newHorizontal = horizontalBoat + relativeVelocity
        local newVelocity = Vector3.new(newHorizontal.X, currentVelocity.Y, newHorizontal.Z)

        rootPart.AssemblyLinearVelocity = newVelocity
        maintainMomentum = true
        lastGroundedInfo.boatVelocity = boatVelocity
        lastGroundedInfo.isAirborne = true
        lastGroundedInfo.airStartTime = now
end

local function onHumanoidStateChanged(_, newState)
        if newState == Enum.HumanoidStateType.Freefall
                or newState == Enum.HumanoidStateType.Jumping
                or newState == Enum.HumanoidStateType.FallingDown then
                applyBoatMomentum()
        elseif newState == Enum.HumanoidStateType.Seated
                or newState == Enum.HumanoidStateType.Dead then
                resetGroundedInfo()
        elseif maintainMomentum then
                resetGroundedInfo()
        end
end

local function maintainBoatMomentum()
        if not maintainMomentum or not lastGroundedInfo or not lastGroundedInfo.isAirborne then
                return
        end

        if not humanoid or humanoid.Health <= 0 or humanoid.Sit then
                resetGroundedInfo()
                return
        end

        local now = os.clock()
        if now - (lastGroundedInfo.airStartTime or 0) > AIRBORNE_TIMEOUT then
                resetGroundedInfo()
                return
        end

        if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall
                and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping
                and humanoid:GetState() ~= Enum.HumanoidStateType.FallingDown then
                resetGroundedInfo()
                return
        end

        local boat = lastGroundedInfo.boat
        if not boat or not boat.Parent or not boat.PrimaryPart then
                resetGroundedInfo()
                return
        end

        if not rootPart then
                resetGroundedInfo()
                return
        end

        local boatVelocity
        local contactPosition
        if lastGroundedInfo.localContactOffset then
                contactPosition = boat.PrimaryPart.CFrame:PointToWorldSpace(lastGroundedInfo.localContactOffset)
        else
                contactPosition = rootPart.Position
        end

        if contactPosition then
                boatVelocity = boat.PrimaryPart:GetVelocityAtPosition(contactPosition)
        end
        if not boatVelocity then
                resetGroundedInfo()
                return
        end

        local currentVelocity = rootPart.AssemblyLinearVelocity
        local previousBoatVelocity = lastGroundedInfo.boatVelocity or boatVelocity
        local previousBoatHorizontal = Vector3.new(previousBoatVelocity.X, 0, previousBoatVelocity.Z)
        local storedRelative = lastGroundedInfo.relativeVelocity or Vector3.zero
        local expectedHorizontal = previousBoatHorizontal + storedRelative
        local currentHorizontal = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
        local delta = currentHorizontal - expectedHorizontal

        if delta.Magnitude > 0.01 then
                lastGroundedInfo.relativeVelocity = storedRelative + delta
                storedRelative = lastGroundedInfo.relativeVelocity
        end

        local horizontalBoat = Vector3.new(boatVelocity.X, 0, boatVelocity.Z)
        local desiredHorizontal = horizontalBoat + storedRelative
        local newVelocity = Vector3.new(desiredHorizontal.X, currentVelocity.Y, desiredHorizontal.Z)

        if (newVelocity - currentVelocity).Magnitude > 0.01 then
                rootPart.AssemblyLinearVelocity = newVelocity
        end

        lastGroundedInfo.boatVelocity = boatVelocity
end

local function onHeartbeat(dt)
        maintainBoatMomentum()

        updateAccumulator += dt
        if updateAccumulator < UPDATE_INTERVAL then
                return
        end

	updateAccumulator = 0

	if not humanoid or humanoid.Health <= 0 or not rootPart then
		resetGroundedInfo()
		return
	end

	local now = os.clock()
	updateGroundedBoat(now)
end

local function onCharacterAdded(newCharacter)
	clearCharacterConnections()
	resetGroundedInfo()

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
		humanoid.Died:Connect(resetGroundedInfo),
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				clearCharacterConnections()
				resetGroundedInfo()
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
	resetGroundedInfo()
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
