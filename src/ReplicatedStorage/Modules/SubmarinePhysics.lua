-- SubmarinePhysics.lua (FIXED - Performance optimizations and cached parsing)
-- Place in: ReplicatedStorage/Modules/SubmarinePhysics.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local SubmarinePhysics = {}

-- Constants
local SURFACE_DETECTION_RANGE = 8
local SURFACE_PULL_STRENGTH = 15
local DEPTH_PRESSURE_DAMAGE = 1

-- Cache for parsed center of mass values
local CenterOfMassCache = {}

-- Helper function to parse and cache center of mass
local function GetCenterOfMass(boat)
	if not boat then return nil end

	-- Check cache first
	if CenterOfMassCache[boat] then
		return CenterOfMassCache[boat]
	end

	local centerOfMassOffset = boat:GetAttribute("CenterOfMassOffset")
	if not centerOfMassOffset then 
		CenterOfMassCache[boat] = nil
		return nil 
	end

	if type(centerOfMassOffset) == "string" then
		local values = string.split(centerOfMassOffset, ",")
		if #values == 3 then
			local parsed = Vector3.new(
				tonumber(values[1]) or 0,
				tonumber(values[2]) or 0,
				tonumber(values[3]) or 0
			)
			CenterOfMassCache[boat] = parsed
			return parsed
		end
	elseif typeof(centerOfMassOffset) == "Vector3" then
		CenterOfMassCache[boat] = centerOfMassOffset
		return centerOfMassOffset
	end

	CenterOfMassCache[boat] = nil
	return nil
end

-- Clean up cache when boat is destroyed
local function ClearCacheForBoat(boat)
	CenterOfMassCache[boat] = nil
end

-- Helper function to get depth
function SubmarinePhysics.GetDepth(position)
        return WaterPhysics.GetWaterLevel(position) - position.Y
end

-- Check if submarine should auto-surface
function SubmarinePhysics.ShouldAutoSurface(position)
	local depth = SubmarinePhysics.GetDepth(position)
	return depth >= 0 and depth <= SURFACE_DETECTION_RANGE
end

-- Helper function to check if position is valid for submarine
function SubmarinePhysics.IsValidDepth(position, config)
        local depth = SubmarinePhysics.GetDepth(position)
        local maxDepth = (config and config.MaxDepth) or math.huge
        local minDepth = (config and config.MinDepth) or -math.huge

        if depth < minDepth then
                return false, "Too high!", depth
        end

        if depth > maxDepth then
                return true, "overDepth", depth
        end

        return true, nil, depth
end

-- Calculate and apply dynamic balance correction for asymmetric submarines
function SubmarinePhysics.ApplyBalanceCorrection(currentCFrame, boat, config, deltaTime)
	if not boat or not boat.PrimaryPart then
		return currentCFrame
	end

	local centerOfMassOffset = GetCenterOfMass(boat)
	if not centerOfMassOffset then
		return currentCFrame
	end

	local x, y, z = currentCFrame:ToEulerAnglesYXZ()

	local balanceCorrectionStrength = 0.5
	local pitchCorrection = 0
	local rollCorrection = 0

	if math.abs(centerOfMassOffset.Z) > 0.5 then
		pitchCorrection = -centerOfMassOffset.Z * 0.01 * balanceCorrectionStrength
	end

	if math.abs(centerOfMassOffset.X) > 0.5 then
		rollCorrection = -centerOfMassOffset.X * 0.01 * balanceCorrectionStrength
	end

	local correctedCFrame = currentCFrame 
		* CFrame.Angles(pitchCorrection * deltaTime, 0, rollCorrection * deltaTime)

	return correctedCFrame
end

-- Enhanced idle movement for asymmetric submarines
function SubmarinePhysics.GetAsymmetricIdleSway(position, time, centerOfMassOffset)
	local swayX = math.sin(time * 0.3) * 0.5 + math.sin(time * 0.7) * 0.2
	local swayY = math.sin(time * 0.4 + 1) * 0.3 + math.sin(time * 0.8) * 0.1
	local swayZ = math.sin(time * 0.35 + 2) * 0.4 + math.sin(time * 0.6) * 0.2

	if centerOfMassOffset then
		local asymmetryFactor = centerOfMassOffset.Magnitude / 10
		asymmetryFactor = math.clamp(asymmetryFactor, 0, 1)

		local reductionFactor = 1 - (asymmetryFactor * 0.7)
		swayX = swayX * reductionFactor
		swayY = swayY * reductionFactor
		swayZ = swayZ * reductionFactor
	end

	local pitchSway = math.sin(time * 0.25) * math.rad(1)
	local rollSway = math.sin(time * 0.3 + 1.5) * math.rad(1.5)
	local yawSway = math.sin(time * 0.2) * math.rad(0.5)

	return swayX, swayY, swayZ, pitchSway, rollSway, yawSway
end

-- Calculate idle submarine sway for underwater ambiance
function SubmarinePhysics.GetIdleUnderwaterSway(position, time)
	local swayX = math.sin(time * 0.3) * 0.5 + math.sin(time * 0.7) * 0.2
	local swayY = math.sin(time * 0.4 + 1) * 0.3 + math.sin(time * 0.8) * 0.1
	local swayZ = math.sin(time * 0.35 + 2) * 0.4 + math.sin(time * 0.6) * 0.2

	local pitchSway = math.sin(time * 0.25) * math.rad(2)
	local rollSway = math.sin(time * 0.3 + 1.5) * math.rad(3)
	local yawSway = math.sin(time * 0.2) * math.rad(1)

	return swayX, swayY, swayZ, pitchSway, rollSway, yawSway
end

-- Apply idle movement to submarines with asymmetry support
function SubmarinePhysics.ApplyIdleMovement(currentCFrame, config, deltaTime, hasDriver, boat)
	local time = tick()
	local position = currentCFrame.Position
	local depth = SubmarinePhysics.GetDepth(position)

	local centerOfMassOffset = GetCenterOfMass(boat)

	if depth < 2 then
		return currentCFrame, true
	else
		local swayX, swayY, swayZ, pitchSway, rollSway, yawSway

		if centerOfMassOffset then
			swayX, swayY, swayZ, pitchSway, rollSway, yawSway = 
				SubmarinePhysics.GetAsymmetricIdleSway(position, time, centerOfMassOffset)
		else
			swayX, swayY, swayZ, pitchSway, rollSway, yawSway = 
				SubmarinePhysics.GetIdleUnderwaterSway(position, time)
		end

		local swayMultiplier = hasDriver and 0.3 or 1.0

		if centerOfMassOffset and centerOfMassOffset.Magnitude > 5 then
			swayMultiplier = swayMultiplier * 0.5
		end

		local swayedPosition = Vector3.new(
			position.X + (swayX * swayMultiplier * deltaTime),
			position.Y + (swayY * swayMultiplier * deltaTime),
			position.Z + (swayZ * swayMultiplier * deltaTime)
		)

		local x, y, z = currentCFrame:ToEulerAnglesYXZ()

		local swayedCFrame = CFrame.new(swayedPosition)
			* CFrame.Angles(0, y + (yawSway * swayMultiplier), 0)
			* CFrame.Angles(x + (pitchSway * swayMultiplier), 0, z + (rollSway * swayMultiplier))

		if boat then
			swayedCFrame = SubmarinePhysics.ApplyBalanceCorrection(swayedCFrame, boat, config, deltaTime)
		end

		return swayedCFrame, false
	end
end

-- Calculate submarine movement with full 3D rotation
function SubmarinePhysics.CalculateMovement(currentCFrame, inputs, config, deltaTime, isInDiveMode, isIdle)
	local throttle = inputs.throttle or 0
	local steer = inputs.steer or 0
	local ascend = inputs.ascend or 0
	local pitch = inputs.pitch or 0
	local roll = inputs.roll or 0

	-- Handle both Speed and MaxSpeed properties
	local speed = config.Speed or config.MaxSpeed or 28
	local turnSpeed = config.TurnSpeed or 1.8
	local pitchSpeed = config.PitchSpeed or 1.5
	local rollSpeed = config.RollSpeed or 1.0
	local verticalSpeed = config.VerticalSpeed or 18

	-- Weight affects rotation speeds
	local weight = config.Weight or 5
	local rotationWeightFactor = 2.0 - (weight * 0.18)
	rotationWeightFactor = math.clamp(rotationWeightFactor, 0.2, 2.0)

	-- Apply weight factor to all rotation speeds
	turnSpeed = turnSpeed * rotationWeightFactor
	pitchSpeed = pitchSpeed * (rotationWeightFactor * 0.8)
	rollSpeed = rollSpeed * (rotationWeightFactor * 0.7)

	-- Vertical speed is affected by weight
	local verticalWeightFactor = 1.8 - (weight * 0.15)
	verticalWeightFactor = math.clamp(verticalWeightFactor, 0.3, 1.8)
	verticalSpeed = verticalSpeed * verticalWeightFactor

	if isIdle and math.abs(throttle) < 0.01 and math.abs(steer) < 0.01 then
		return currentCFrame
	end

	local shouldSurface = SubmarinePhysics.ShouldAutoSurface(currentCFrame.Position)

	if shouldSurface and not isInDiveMode then
		-- AUTO-SURFACE MODE
                local currentDepth = SubmarinePhysics.GetDepth(currentCFrame.Position)
                local targetY = WaterPhysics.GetWaterLevel(currentCFrame.Position) - 1

		local yDifference = targetY - currentCFrame.Position.Y
		local surfaceSpeed = math.clamp(yDifference * 2, -2, 2) * deltaTime

		local x, y, z = currentCFrame:ToEulerAnglesYXZ()

		-- Weight affects leveling speed
		local levelingSpeed = 0.5 * rotationWeightFactor
		local leveledPitch = x * (1 - levelingSpeed * deltaTime)
		local leveledRoll = z * (1 - levelingSpeed * deltaTime)

		local yawAmount = steer * turnSpeed * deltaTime

		local moveDirection = currentCFrame.LookVector
		local horizontalDir = Vector3.new(moveDirection.X, 0, moveDirection.Z)
		if horizontalDir.Magnitude > 0 then
			moveDirection = horizontalDir.Unit
		end
		local moveDistance = throttle * speed * deltaTime

		local newPosition = Vector3.new(
			currentCFrame.Position.X + (moveDirection.X * moveDistance),
			currentCFrame.Position.Y + surfaceSpeed,
			currentCFrame.Position.Z + (moveDirection.Z * moveDistance)
		)

		if newPosition.Y > targetY then
			newPosition = Vector3.new(newPosition.X, targetY, newPosition.Z)
		end

		local newCFrame = CFrame.new(newPosition) 
			* CFrame.Angles(0, y - yawAmount, 0)
			* CFrame.Angles(leveledPitch, 0, leveledRoll)

		return newCFrame
	else
		-- DIVE MODE
		local yawAmount = steer * turnSpeed * deltaTime
		local pitchAmount = pitch * pitchSpeed * deltaTime
		local rollAmount = config.CanInvert and (roll * rollSpeed * deltaTime) or 0

		local newRotation = currentCFrame 
			* CFrame.Angles(0, -yawAmount, 0)
			* CFrame.Angles(-pitchAmount, 0, 0)
			* CFrame.Angles(0, 0, rollAmount)

		local moveDirection = newRotation.LookVector
		local moveDistance = throttle * speed * deltaTime

		local verticalMovement = 0
		if math.abs(ascend) > 0.01 then
			verticalMovement = ascend * verticalSpeed * deltaTime
		elseif math.abs(pitch) > 0.01 and math.abs(throttle) > 0.01 then
			local pitchVertical = moveDirection.Y * moveDistance
			verticalMovement = pitchVertical
		end

		local newPosition = currentCFrame.Position 
			+ (moveDirection * moveDistance)
			+ Vector3.new(0, verticalMovement, 0)

                local minDepth = config.MinDepth
                if minDepth ~= nil then
                        local currentDepth = SubmarinePhysics.GetDepth(newPosition)
                        if currentDepth < minDepth then
                                newPosition = Vector3.new(
                                        newPosition.X,
                                        WaterPhysics.GetWaterLevel(newPosition) - minDepth,
                                        newPosition.Z
                                )
                        end
                end

                return CFrame.new(newPosition) * newRotation.Rotation
        end
end

-- Set up collision filtering for phasing through water
function SubmarinePhysics.SetupCollisionFiltering(submarine, config)
	if not config.PhaseThrough then return end

	local PhysicsService = game:GetService("PhysicsService")

	pcall(function()
		PhysicsService:RegisterCollisionGroup("Submarines")
		PhysicsService:RegisterCollisionGroup("WaterParts")
	end)

	for _, part in pairs(submarine:GetDescendants()) do
		if part:IsA("BasePart") then
			pcall(function()
				part.CollisionGroup = "Submarines"
			end)
		end
	end

	for _, partName in pairs(config.PhaseThrough) do
		local waterParts = workspace:GetDescendants()
		for _, part in pairs(waterParts) do
			if part:IsA("BasePart") and part.Name == partName then
				pcall(function()
					part.CollisionGroup = "WaterParts"
				end)
			end
		end
	end

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable("Submarines", "WaterParts", false)
	end)
end

-- Get submarine display info
function SubmarinePhysics.GetSubmarineInfo(submarine, config)
	if not submarine or not submarine.PrimaryPart then
		return {
			depth = 0,
			speed = 0,
			heading = 0,
			pitch = 0,
			roll = 0,
			mode = "surface"
		}
	end

	local primaryPart = submarine.PrimaryPart
	local depth = SubmarinePhysics.GetDepth(primaryPart.Position)
	local shouldSurface = SubmarinePhysics.ShouldAutoSurface(primaryPart.Position)

	local cf = primaryPart.CFrame
	local x, y, z = cf:ToEulerAnglesYXZ()

	return {
		depth = math.floor(depth),
		speed = primaryPart.AssemblyLinearVelocity.Magnitude,
		heading = math.deg(y),
		pitch = math.deg(x),
		roll = math.deg(z),
		depthPercent = (depth / config.MaxDepth) * 100,
		mode = shouldSurface and "surface" or "dive"
	}
end

-- Check if submarine should take pressure damage
function SubmarinePhysics.CheckPressureDamage(submarine, config)
	if not submarine or not submarine.PrimaryPart then return 0 end

	local depth = SubmarinePhysics.GetDepth(submarine.PrimaryPart.Position)

	if depth > config.MaxDepth * 0.9 then
		local damagePercent = (depth - config.MaxDepth * 0.9) / (config.MaxDepth * 0.1)
		return DEPTH_PRESSURE_DAMAGE * damagePercent
	end

	return 0
end

-- Cleanup function for cache management
function SubmarinePhysics.CleanupBoat(boat)
	ClearCacheForBoat(boat)
end

return SubmarinePhysics