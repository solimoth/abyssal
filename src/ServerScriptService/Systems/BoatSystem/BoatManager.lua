-- BoatManager.lua (FIXED - Memory leaks, performance, and exploits patched)
-- Place in: ServerScriptService/Systems/BoatSystem/BoatManager.lua

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")

local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)
local BoatSecurity = require(ReplicatedStorage.Modules.BoatSecurity)
local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)
local Remotes = ReplicatedStorage.Remotes.BoatRemotes

-- Boat storage
local ActiveBoats = {}
local BoatConnections = {}
local BoatControllers = {}
local BoatControls = {}
local BoatLastActivity = {}
local BoatPhysicsObjects = {} -- NEW: Track physics objects

-- ACCELERATION SYSTEM STORAGE
local BoatSpeeds = {}
local BoatTurnSpeeds = {}
local BoatAccelerationData = {}
local PlayerViolations = {} -- NEW: Track violations properly

-- Performance settings
local IDLE_THRESHOLD = 10
local MEMORY_CHECK_INTERVAL = 30
local MAX_UPDATE_DELTA = 0.1
local PHYSICS_THROTTLE_DISTANCE = 500 -- NEW: Don't update physics for far boats
local MAX_CONTROL_RATE = 30 -- NEW: Realistic rate limit (30/sec)

-- Memory management
local MemoryCheckTimer = 0
local BOAT_CLEANUP_QUEUE = {}

-- Constants
local SPAWN_HEIGHT_OFFSET = 2
local SPAWN_DISTANCE = 20
local WATER_LEVEL = 908.935
local MAX_SPAWN_DISTANCE = 200 -- NEW: Limit spawn distance from player

-- Module table
local BoatManager = {}

-- Initialize function
local function Initialize()
	local function createRemote(name, className)
		if not Remotes:FindFirstChild(name) then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = Remotes
		end
	end

	createRemote("SpawnBoat", "RemoteEvent")
	createRemote("DespawnBoat", "RemoteEvent")
	createRemote("UpdateBoatControl", "RemoteEvent")
	createRemote("GetSelectedBoatType", "RemoteFunction")
	createRemote("ValidateBoat", "RemoteEvent")
end

-- Initialize acceleration data for a boat
local function InitializeBoatAcceleration(player, boatType)
	local config = BoatConfig.GetBoatData(boatType)
	if not config then return end

	BoatSpeeds[player] = 0
	BoatTurnSpeeds[player] = 0
	BoatAccelerationData[player] = {
		maxSpeed = config.MaxSpeed or 25,
		weight = config.Weight or 3,
		accelerationRate = BoatConfig.GetAcceleration(boatType),
		decelerationRate = BoatConfig.GetDeceleration(boatType),
		turnAccelerationRate = 3 * (1.5 - (config.Weight / 10))
	}
end

-- Helper function to restore original CanCollide states
local function RestoreCanCollideStates(boat)
	if not boat then return end

	for _, part in pairs(boat:GetDescendants()) do
		if part:IsA("BasePart") then
			local originalCanCollide = part:GetAttribute("OriginalCanCollide")
			if originalCanCollide ~= nil then
				part.CanCollide = originalCanCollide
			end
		end
	end
end

-- Boat validation
local function ValidateBoat(boat)
	if not boat or not boat:IsA("Model") then return false end
	if not boat.PrimaryPart then return false end

	local ownerId = boat:GetAttribute("OwnerId")
	if not ownerId then return false end

	local seat = boat:FindFirstChildOfClass("VehicleSeat")
	if not seat then return false end

	local boatType = boat:GetAttribute("BoatType")
	if boatType then
		local lastValidated = boat:GetAttribute("LastValidated") or 0
		if tick() - lastValidated > 30 then
			boat:SetAttribute("LastValidated", tick())

			local partCount = #boat:GetDescendants()
			local maxParts = boat:GetAttribute("OriginalPartCount")
			if maxParts and partCount > maxParts * 2 then
				warn("Boat tampering detected for", ownerId)
				return false
			end
		end
	end

	return true
end

-- ENHANCED PHYSICS SETUP
local function SetupBoatPhysics(boat, config)
	local primaryPart = boat.PrimaryPart
	if not primaryPart then 
		warn("Boat has no PrimaryPart!")
		return false 
	end

	boat:SetAttribute("OriginalPartCount", #boat:GetDescendants())

	-- Clean up any existing physics objects first
	local oldAttachment = primaryPart:FindFirstChild("BoatAttachment")
	if oldAttachment then oldAttachment:Destroy() end

	-- Create attachments
	local boatAttachment = Instance.new("Attachment")
	boatAttachment.Name = "BoatAttachment"
	boatAttachment.Position = Vector3.new(0, 0, 0)
	boatAttachment.CFrame = CFrame.new(0, 0, 0)
	boatAttachment.Parent = primaryPart

	-- Create control part with unique name
	local controlPart = Instance.new("Part")
	controlPart.Name = "BoatControlPart_" .. HttpService:GenerateGUID(false)
	controlPart.Transparency = 1
	controlPart.CanCollide = false
	controlPart.Anchored = true
	controlPart.Size = Vector3.new(1, 1, 1)
	controlPart.CFrame = primaryPart.CFrame
	controlPart:SetAttribute("OwnerUserId", boat:GetAttribute("OwnerId"))
	controlPart:SetAttribute("BoatId", boat:GetAttribute("BoatId"))
	controlPart.Parent = workspace

	local controlAttachment = Instance.new("Attachment")
	controlAttachment.Name = "ControlAttachment"
	controlAttachment.CFrame = CFrame.new(0, 0, 0)
	controlAttachment.Parent = controlPart

	-- Movement constraints with weight consideration
	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "BoatAlignPosition"
	alignPos.Attachment0 = boatAttachment
	alignPos.Attachment1 = controlAttachment

	-- Adjust physics based on weight
	local weightFactor = 1 + (config.Weight / 10)

	if config.Type == "Submarine" then
		alignPos.MaxForce = 2000000 * weightFactor
		alignPos.MaxVelocity = config.MaxSpeed + 10
		alignPos.Responsiveness = 100 / (1 + config.Weight * 0.05)
		alignPos.RigidityEnabled = true
	else
		alignPos.MaxForce = 1000000 * weightFactor
		alignPos.MaxVelocity = config.MaxSpeed + 10
		alignPos.Responsiveness = 50 / (1 + config.Weight * 0.05)
		alignPos.RigidityEnabled = true
	end

	alignPos.Parent = primaryPart

	-- Rotation constraints with weight consideration
	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = "BoatAlignOrientation"
	alignOri.Attachment0 = boatAttachment
	alignOri.Attachment1 = controlAttachment

	if config.Type == "Submarine" then
		alignOri.MaxTorque = 1000000 * weightFactor
		alignOri.MaxAngularVelocity = 8 / (1 + config.Weight * 0.1)
		alignOri.Responsiveness = 25 / (1 + config.Weight * 0.05)
		alignOri.RigidityEnabled = false
	else
		alignOri.MaxTorque = 800000 * weightFactor
		alignOri.MaxAngularVelocity = 10 / (1 + config.Weight * 0.1)
		alignOri.Responsiveness = 30 / (1 + config.Weight * 0.05)
		alignOri.RigidityEnabled = false
	end

	alignOri.Parent = primaryPart

	-- BodyVelocity for momentum simulation
	local bodyVel = Instance.new("BodyVelocity")
	bodyVel.Name = "BoatBodyVelocity"
	bodyVel.MaxForce = Vector3.new(4000 * weightFactor, 4000 * weightFactor, 4000 * weightFactor)
	bodyVel.Velocity = Vector3.new(0, 0, 0)
	bodyVel.Parent = primaryPart

	controlPart:SetAttribute("HasBodyVelocity", true)

	-- Store physics objects for proper cleanup
	if not BoatPhysicsObjects[boat] then
		BoatPhysicsObjects[boat] = {}
	end
	BoatPhysicsObjects[boat] = {
		controlPart = controlPart,
		alignPos = alignPos,
		alignOri = alignOri,
		bodyVel = bodyVel,
		boatAttachment = boatAttachment,
		controlAttachment = controlAttachment
	}

	return controlPart
end

-- Enhanced cleanup function
local function CleanupBoat(player)
	-- Clean up acceleration data
	BoatSpeeds[player] = nil
	BoatTurnSpeeds[player] = nil
	BoatAccelerationData[player] = nil
	PlayerViolations[player] = nil

	-- Clean up boat and physics
	local boat = ActiveBoats[player]
	if boat then
		-- Clean up physics objects first
		local physicsObjs = BoatPhysicsObjects[boat]
		if physicsObjs then
			for _, obj in pairs(physicsObjs) do
				if obj and obj.Parent then
					pcall(function() obj:Destroy() end)
				end
			end
			BoatPhysicsObjects[boat] = nil
		end

		-- Clean up boat parts
		pcall(function()
			RestoreCanCollideStates(boat)
			for _, desc in pairs(boat:GetDescendants()) do
				if desc:IsA("Constraint") or desc:IsA("BodyMover") then
					desc:Destroy()
				end
			end
			boat:Destroy()
		end)
		ActiveBoats[player] = nil
	end

	-- Clean up controller
	local controller = BoatControllers[player]
	if controller then
		pcall(function() controller:Destroy() end)
		BoatControllers[player] = nil
	end

	-- Clean up connections
	local connections = BoatConnections[player]
	if connections then
		for _, conn in pairs(connections) do
			if conn then
				pcall(function() conn:Disconnect() end)
			end
		end
		BoatConnections[player] = nil
	end

	BoatControls[player] = nil
	BoatLastActivity[player] = nil
	BoatSecurity.CleanupPlayer(player)
end

-- Process cleanup queue
local function ProcessCleanupQueue()
	for _, player in ipairs(BOAT_CLEANUP_QUEUE) do
		CleanupBoat(player)
	end
	BOAT_CLEANUP_QUEUE = {}
end

-- Spawn boat function with improved validation
function BoatManager.SpawnBoat(player, boatType, customSpawnPosition, customSpawnCFrame)
	boatType = boatType or "StarterRaft"

	-- Security checks
	local canSpawn, message = BoatSecurity.CanSpawnBoat(player)
	if not canSpawn then
		return false, message
	end

	canSpawn, message = BoatSecurity.CanServerHandleMoreBoats()
	if not canSpawn then
		return false, message
	end

	if ActiveBoats[player] then
		return false, "You already have an active boat"
	end

	local config = BoatConfig.GetBoatData(boatType)
	if not config then
		return false, "Invalid boat type"
	end

	local valid, secMessage = BoatSecurity.ValidateBoatConfig(boatType, config)
	if not valid then
		return false, secMessage
	end

	local boatTemplate = ServerStorage.Boats:FindFirstChild(config.Model)
	if not boatTemplate then
		return false, "Boat model not found"
	end

	local boat
	local success = pcall(function()
		boat = boatTemplate:Clone()
	end)

	if not success or not boat then
		return false, "Failed to create boat"
	end

	-- Set attributes
	local boatId = HttpService:GenerateGUID(false)
	boat:SetAttribute("BoatId", boatId)
	boat:SetAttribute("OwnerId", tostring(player.UserId))
	boat:SetAttribute("OwnerName", player.Name)
	boat:SetAttribute("BoatType", boatType)
	boat:SetAttribute("SpawnTime", tick())
	boat:SetAttribute("LastValidated", tick())
	boat:SetAttribute("Weight", config.Weight or 3)
	boat:SetAttribute("MaxSpeed", config.MaxSpeed or 25)

	-- Calculate spawn position with validation
	local spawnPosition
	local spawnDirection = Vector3.new(0, 0, -1)

	if customSpawnCFrame then
		spawnPosition = customSpawnCFrame.Position
		spawnDirection = customSpawnCFrame.LookVector
	elseif customSpawnPosition then
		-- Validate custom spawn position
		if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			local distance = (customSpawnPosition - player.Character.HumanoidRootPart.Position).Magnitude
			if distance > MAX_SPAWN_DISTANCE then
				return false, "Spawn position too far away"
			end
		end
		spawnPosition = customSpawnPosition
	else
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			local hrp = character.HumanoidRootPart
			spawnDirection = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
			spawnPosition = hrp.Position + (spawnDirection * SPAWN_DISTANCE)
		else
			spawnPosition = Vector3.new(0, 0, -30)
		end
	end

	if config.Type == "Submarine" then
		spawnPosition = Vector3.new(spawnPosition.X, WATER_LEVEL - 1, spawnPosition.Z)
	else
		spawnPosition = Vector3.new(spawnPosition.X, WATER_LEVEL + 2, spawnPosition.Z)
	end

	local desiredYaw = math.atan2(spawnDirection.X, -spawnDirection.Z)
	boat:SetPrimaryPartCFrame(CFrame.new(spawnPosition) * CFrame.Angles(0, desiredYaw, 0))

	-- Set up physics
	for _, part in pairs(boat:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "BoatControlPart" then
			local originalCanCollide = part.CanCollide
			part:SetAttribute("OriginalCanCollide", originalCanCollide)
			part.Anchored = false

			if part == boat.PrimaryPart then
				part.Massless = false
				part.RootPriority = config.Type == "Submarine" and 127 or 100

				local density = 0.3 + (config.Weight * 0.05)
				local properties = PhysicalProperties.new(
					config.Type == "Submarine" and density * 1.5 or density,
					0.3,
					0.1,
					1,
					1
				)
				part.CustomPhysicalProperties = properties
			else
				part.Massless = true
			end
		end
	end

	local controlPart = SetupBoatPhysics(boat, config)
	if not controlPart then
		boat:Destroy()
		return false, "Failed to set up boat physics"
	end

	BoatControllers[player] = controlPart

	local seat = boat:FindFirstChildOfClass("VehicleSeat")
	if not seat then
		boat:Destroy()
		controlPart:Destroy()
		return false, "Invalid boat model"
	end

	seat:SetAttribute("BoatOwner", tostring(player.UserId))
	seat:SetAttribute("BoatType", boatType)
	seat.MaxSpeed = config.MaxSpeed or config.Speed
	seat.TurnSpeed = config.TurnSpeed
	seat.Torque = 10
	seat.HeadsUpDisplay = false
	seat.Anchored = false

	-- Initialize acceleration system for this boat
	InitializeBoatAcceleration(player, boatType)

	ActiveBoats[player] = boat
	BoatConnections[player] = {}
	BoatLastActivity[player] = tick()

	local function onOccupantChanged()
		local humanoid = seat.Occupant
		if humanoid then
			local seatPlayer = Players:GetPlayerFromCharacter(humanoid.Parent)
			if seatPlayer and seatPlayer ~= player then
				task.wait(0.1)
				if seat and seat.Parent and seat.Occupant == humanoid then
					humanoid.Sit = false
				end
			else
				BoatLastActivity[player] = tick()
			end
		else
			-- Reset speed when no driver
			BoatSpeeds[player] = 0
			BoatTurnSpeeds[player] = 0
		end
	end

	BoatConnections[player].occupant = seat:GetPropertyChangedSignal("Occupant"):Connect(onOccupantChanged)
	boat.Parent = workspace

	return true
end

-- Despawn function
function BoatManager.DespawnBoat(player)
	CleanupBoat(player)
	return true
end

-- ENHANCED CONTROL UPDATE WITH BETTER VALIDATION
local function UpdateBoatControl(player, controls)
	-- Better rate limiting
	if not BoatSecurity.CheckRemoteRateLimit(player, "UpdateBoatControl", MAX_CONTROL_RATE) then
		return
	end

	-- Validate inputs
	local throttle = controls.throttle
	local steer = controls.steer

	if type(throttle) ~= "number" or type(steer) ~= "number" then
		warn("Invalid control types from", player.Name)
		return
	end

	throttle = math.clamp(throttle, -1, 1)
	steer = math.clamp(steer, -1, 1)

	local ascend = math.clamp(controls.ascend or 0, -1, 1)
	local pitch = math.clamp(controls.pitch or 0, -1, 1)
	local roll = math.clamp(controls.roll or 0, -1, 1)

	-- Validate speed from client with stricter checks
	local clientSpeed = controls.currentSpeed
	if clientSpeed and BoatAccelerationData[player] then
		local maxAllowed = BoatAccelerationData[player].maxSpeed
		if math.abs(clientSpeed) > maxAllowed then
			-- Track violations
			PlayerViolations[player] = (PlayerViolations[player] or 0) + 1

			if PlayerViolations[player] > 50 then
				warn("Excessive speed violations from", player.Name)
				player:Kick("Movement security violation")
			end
			return
		end
	end

	if not BoatSecurity.ValidateInput(throttle, steer) then
		warn("Invalid boat control input from", player.Name)
		return
	end

	BoatControls[player] = {
		throttle = throttle,
		steer = steer,
		ascend = ascend,
		pitch = pitch,
		roll = roll
	}

	BoatLastActivity[player] = tick()
end

-- ENHANCED PHYSICS UPDATE WITH PERFORMANCE OPTIMIZATIONS
local function UpdateBoatPhysics(player, boat, deltaTime)
	if not boat or not boat.Parent then
		CleanupBoat(player)
		return
	end

	if not ValidateBoat(boat) then
		CleanupBoat(player)
		return
	end

	local controlPart = BoatControllers[player]
	if not controlPart or not controlPart.Parent then 
		CleanupBoat(player)
		return 
	end

	local seat = boat:FindFirstChildOfClass("VehicleSeat")
	if not seat then 
		CleanupBoat(player)
		return 
	end

	local config = BoatConfig.GetBoatData(boat:GetAttribute("BoatType"))
	if not config then return end

	local accelData = BoatAccelerationData[player]
	if not accelData then 
		InitializeBoatAcceleration(player, boat:GetAttribute("BoatType"))
		accelData = BoatAccelerationData[player]
		if not accelData then return end
	end

	-- Performance: Check distance to nearest player for physics throttling
	local shouldThrottle = true
	for _, otherPlayer in pairs(Players:GetPlayers()) do
		if otherPlayer.Character and otherPlayer.Character:FindFirstChild("HumanoidRootPart") then
			local distance = (boat.PrimaryPart.Position - otherPlayer.Character.HumanoidRootPart.Position).Magnitude
			if distance < PHYSICS_THROTTLE_DISTANCE then
				shouldThrottle = false
				break
			end
		end
	end

	-- Skip some physics updates for far boats
	if shouldThrottle and math.random() > 0.3 then
		return
	end

	-- Check activity
	local lastActivity = BoatLastActivity[player] or tick()
	local isIdle = (tick() - lastActivity) > IDLE_THRESHOLD

	if isIdle and not seat.Occupant then
		if boat.PrimaryPart then
			local currentPos = controlPart.CFrame.Position
			local boatPos = boat.PrimaryPart.CFrame.Position
			if (currentPos - boatPos).Magnitude > 5 then
				controlPart.CFrame = boat.PrimaryPart.CFrame
			end

			-- Reset speeds when idle
			BoatSpeeds[player] = 0
			BoatTurnSpeeds[player] = 0
		end
		return
	end

	local isSubmarine = config.Type == "Submarine"

	-- Get inputs
	local throttle = 0
	local steer = 0
	local ascend = 0
	local pitch = 0
	local roll = 0
	local hasDriver = false

	if seat.Occupant then
		hasDriver = true
		throttle = seat.ThrottleFloat
		steer = seat.SteerFloat

		local humanoid = seat.Occupant
		local seatPlayer = Players:GetPlayerFromCharacter(humanoid.Parent)
		if seatPlayer and seatPlayer ~= player then
			humanoid.Sit = false
			return
		end

		if isSubmarine and BoatControls[player] then
			ascend = BoatControls[player].ascend or 0
			pitch = BoatControls[player].pitch or 0
			roll = BoatControls[player].roll or 0
		end
	else
		if boat.PrimaryPart then
			controlPart.CFrame = boat.PrimaryPart.CFrame

			local bodyVel = boat.PrimaryPart:FindFirstChild("BoatBodyVelocity")
			if bodyVel then
				bodyVel.Velocity = Vector3.new(0, 0, 0)
			end

			-- Reset speeds when no driver
			BoatSpeeds[player] = 0
			BoatTurnSpeeds[player] = 0
		end
		return
	end

	-- CALCULATE ACCELERATION
	local currentSpeed = BoatSpeeds[player] or 0
	local currentTurnSpeed = BoatTurnSpeeds[player] or 0

	local targetSpeed = throttle * accelData.maxSpeed
	local targetTurnSpeed = steer * config.TurnSpeed

	-- Apply acceleration/deceleration
	if math.abs(targetSpeed) > math.abs(currentSpeed) then
		-- Accelerating
		local speedDiff = targetSpeed - currentSpeed
		local speedChange = math.sign(speedDiff) * accelData.accelerationRate * deltaTime

		if math.abs(speedChange) > math.abs(speedDiff) then
			currentSpeed = targetSpeed
		else
			currentSpeed = currentSpeed + speedChange
		end
	else
		-- Decelerating
		local speedDiff = targetSpeed - currentSpeed
		local speedChange = math.sign(speedDiff) * accelData.decelerationRate * deltaTime

		if math.abs(speedChange) > math.abs(speedDiff) then
			currentSpeed = targetSpeed
		else
			currentSpeed = currentSpeed + speedChange
		end
	end

	-- Apply turn acceleration
	local turnDiff = targetTurnSpeed - currentTurnSpeed
	local turnChange = math.sign(turnDiff) * accelData.turnAccelerationRate * deltaTime

	if math.abs(turnChange) > math.abs(turnDiff) then
		currentTurnSpeed = targetTurnSpeed
	else
		currentTurnSpeed = currentTurnSpeed + turnChange
	end

	-- Store updated speeds
	BoatSpeeds[player] = currentSpeed
	BoatTurnSpeeds[player] = currentTurnSpeed

	-- CALCULATE MOVEMENT WITH ACTUAL SPEED
	local currentCFrame = controlPart.CFrame
	local newCFrame

	if isSubmarine then
		local SubmarinePhysics = require(ReplicatedStorage.Modules.SubmarinePhysics)

		local adjustedInputs = {
			throttle = currentSpeed / accelData.maxSpeed,
			steer = currentTurnSpeed / config.TurnSpeed,
			ascend = ascend,
			pitch = pitch,
			roll = roll
		}

		local subConfig = {}
		for k, v in pairs(config) do
			subConfig[k] = v
		end
		subConfig.Speed = subConfig.Speed or subConfig.MaxSpeed or 28

		newCFrame = SubmarinePhysics.CalculateMovement(
			currentCFrame, 
			adjustedInputs, 
			subConfig, 
			deltaTime,
			math.abs(ascend) > 0.01,
			false
		)

		if SubmarinePhysics.ShouldAutoSurface(newCFrame.Position) then
			local floatingCFrame, _ = WaterPhysics.ApplyFloatingPhysics(
				newCFrame, 
				"Surface",
				deltaTime
			)
			newCFrame = floatingCFrame
		end
	else
		-- Calculate turning with actual turn speed
		local turnAmount = currentTurnSpeed * deltaTime
		local newRotation = currentCFrame * CFrame.Angles(0, -turnAmount, 0)

		-- Calculate forward movement with actual speed
		local moveDirection = newRotation.LookVector
		local moveDistance = currentSpeed * deltaTime
		local newPosition = currentCFrame.Position + (moveDirection * moveDistance)

		newCFrame = CFrame.new(newPosition) * newRotation.Rotation

		-- Apply water physics
		newCFrame, _ = WaterPhysics.ApplyFloatingPhysics(
			newCFrame,
			"Surface",
			deltaTime
		)
	end

	-- Validate movement
	local valid, message, shouldKick = BoatSecurity.ValidateBoatMovement(
		player, boat, newCFrame.Position, deltaTime
	)

	if shouldKick then
		PlayerViolations[player] = (PlayerViolations[player] or 0) + 10

		if PlayerViolations[player] > 100 then
			player:Kick("Movement security violation")
			CleanupBoat(player)
			return
		end
	end

	-- Update position
	controlPart.CFrame = newCFrame

	-- Update BodyVelocity for momentum
	if boat.PrimaryPart then
		local bodyVel = boat.PrimaryPart:FindFirstChild("BoatBodyVelocity")
		if bodyVel then
			local velocityDirection = newCFrame.LookVector
			local momentumFactor = 0.3 * (1 + config.Weight * 0.05)
			local targetVelocity = velocityDirection * currentSpeed * momentumFactor
			bodyVel.Velocity = bodyVel.Velocity:Lerp(targetVelocity, 0.1)
		end
	end

	BoatLastActivity[player] = tick()
end

-- Main update loop
local function UpdateAllBoats(deltaTime)
	deltaTime = math.min(deltaTime, MAX_UPDATE_DELTA)

	if #BOAT_CLEANUP_QUEUE > 0 then
		ProcessCleanupQueue()
	end

	MemoryCheckTimer = MemoryCheckTimer + deltaTime
	if MemoryCheckTimer > MEMORY_CHECK_INTERVAL then
		MemoryCheckTimer = 0

		local orphanCount = 0

		-- Clean up orphaned control parts
		for _, obj in pairs(workspace:GetChildren()) do
			if string.find(obj.Name, "BoatControlPart_") then
				local ownerId = obj:GetAttribute("OwnerUserId")
				local ownerFound = false

				for _, player in pairs(Players:GetPlayers()) do
					if tostring(player.UserId) == ownerId then
						ownerFound = true
						break
					end
				end

				if not ownerFound then
					pcall(function() obj:Destroy() end)
					orphanCount = orphanCount + 1
				end
			end
		end

		-- Clean up orphaned boats
		for _, obj in pairs(workspace:GetChildren()) do
			if obj:GetAttribute("OwnerId") and obj:IsA("Model") then
				local ownerId = obj:GetAttribute("OwnerId")
				local ownerFound = false

				for _, player in pairs(Players:GetPlayers()) do
					if tostring(player.UserId) == ownerId then
						ownerFound = true
						break
					end
				end

				if not ownerFound then
					-- Clean up physics objects first
					local physicsObjs = BoatPhysicsObjects[obj]
					if physicsObjs then
						for _, physObj in pairs(physicsObjs) do
							pcall(function() physObj:Destroy() end)
						end
						BoatPhysicsObjects[obj] = nil
					end

					pcall(function() obj:Destroy() end)
					orphanCount = orphanCount + 1
				end
			end
		end

		if orphanCount > 0 then
			warn("Cleaned up", orphanCount, "orphaned objects")
		end
	end

	-- Update all boats
	for player, boat in pairs(ActiveBoats) do
		if player.Parent then -- Check if player is still in game
			UpdateBoatPhysics(player, boat, deltaTime)
		else
			CleanupBoat(player)
		end
	end
end

-- Get player's boat
function BoatManager.GetPlayerBoat(player)
	return ActiveBoats[player]
end

-- Get boat speed
function BoatManager.GetBoatSpeed(player)
	return BoatSpeeds[player] or 0
end

-- Get boat acceleration data
function BoatManager.GetBoatAccelerationData(player)
	return BoatAccelerationData[player]
end

-- Initialize
function BoatManager.Initialize()
	Initialize()

	RunService.Heartbeat:Connect(function(deltaTime)
		local success, err = pcall(UpdateAllBoats, deltaTime)
		if not success then
			warn("Boat physics update error:", err)
		end
	end)

	-- Remote handlers with better validation
	Remotes.SpawnBoat.OnServerEvent:Connect(function(player, boatType, spawnPosition)
		if not BoatSecurity.CheckRemoteRateLimit(player, "SpawnBoat", 1) then
			return
		end

		-- Validate boat type
		if type(boatType) ~= "string" then
			warn("Invalid boat type from", player.Name)
			return
		end

		-- Validate spawn position
		if spawnPosition then
			if typeof(spawnPosition) ~= "Vector3" then
				warn("Invalid spawn position type from", player.Name)
				return
			end

			if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
				local distance = (spawnPosition - player.Character.HumanoidRootPart.Position).Magnitude
				if distance > MAX_SPAWN_DISTANCE then
					warn("Spawn position too far from", player.Name)
					return
				end
			end
		end

		BoatManager.SpawnBoat(player, boatType, spawnPosition)
	end)

	Remotes.DespawnBoat.OnServerEvent:Connect(function(player)
		if not BoatSecurity.CheckRemoteRateLimit(player, "DespawnBoat", 1) then
			return
		end
		local boat = ActiveBoats[player]
		if boat and BoatSecurity.ValidateOwnership(player, boat) then
			BoatManager.DespawnBoat(player)
		end
	end)

	Remotes.UpdateBoatControl.OnServerEvent:Connect(function(player, controls)
		if type(controls) ~= "table" then
			warn("Invalid controls from", player.Name)
			return
		end
		UpdateBoatControl(player, controls)
	end)

	Remotes.ValidateBoat.OnServerEvent:Connect(function(player)
		local boat = ActiveBoats[player]
		if boat and not ValidateBoat(boat) then
			warn("Boat validation failed for", player.Name)
			CleanupBoat(player)
		end
	end)

	-- Character handling
	local function OnCharacterDied(character)
		local player = Players:GetPlayerFromCharacter(character)
		if player and ActiveBoats[player] then
			CleanupBoat(player)
		end
	end

	local function OnCharacterAdded(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			local deathConnection
			deathConnection = humanoid.Died:Connect(function()
				OnCharacterDied(character)
				if deathConnection then
					deathConnection:Disconnect()
				end
			end)

			-- Store connection for cleanup
			local player = Players:GetPlayerFromCharacter(character)
			if player and BoatConnections[player] then
				BoatConnections[player].death = deathConnection
			end
		end
	end

	for _, player in pairs(Players:GetPlayers()) do
		if player.Character then
			OnCharacterAdded(player.Character)
		end
		player.CharacterAdded:Connect(OnCharacterAdded)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(OnCharacterAdded)
	end)

	Players.PlayerRemoving:Connect(function(player)
		CleanupBoat(player)
	end)

	print("Enhanced BoatManager initialized with full fixes")
end

return BoatManager