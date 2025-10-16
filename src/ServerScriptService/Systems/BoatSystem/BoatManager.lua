-- BoatManager.lua (FIXED - Memory leaks, performance, and exploits patched)
-- Place in: ServerScriptService/Systems/BoatSystem/BoatManager.lua

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)
local BoatSecurity = require(ReplicatedStorage.Modules.BoatSecurity)
local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)
local SubmarinePhysics = require(ReplicatedStorage.Modules.SubmarinePhysics)
local Remotes = ReplicatedStorage.Remotes.BoatRemotes

-- Boat storage
local ActiveBoats = {}
local BoatConnections = {}
local BoatControllers = {}
local BoatControls = {}
local BoatLastActivity = {}
local BoatPhysicsObjects = {} -- NEW: Track physics objects
local SubmarineStates = {}

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
local PASSIVE_WAVE_DISTANCE = 150 -- NEW: Range for passive wave simulation
local MAX_CONTROL_RATE = 30 -- NEW: Realistic rate limit (30/sec)

-- Submarine pressure damage tuning
local SUB_HEALTH_RECOVERY_RATE = 0.02
local SUB_PRESSURE_BASE_DAMAGE = 1.2
local SUB_PRESSURE_DEPTH_MULTIPLIER = 20
local SUB_PRESSURE_TIME_MULTIPLIER = 2
local SUB_HEALTH_WARNING_STEP = 10
local SUB_DEPTH_WARNING_COOLDOWN = 3
local SUB_SAFE_RECOVERY_COOLDOWN = 2

local SUB_SHAKE_START_RATIO = 0.9
local SUB_SHAKE_MAX_OFFSET = 0.85
local SUB_SHAKE_MAX_ANGLE = math.rad(5)
local SUB_SPEED_MIN_MULTIPLIER = 0.25
local SUB_ACCEL_MIN_MULTIPLIER = 0.35
local SUB_CONTROL_MIN_MULTIPLIER = 0.4
local SUB_CLIENT_SPEED_TOLERANCE = 0.12
local SUB_CLIENT_SPEED_MIN_MARGIN = 4
local SUB_LEAK_THRESHOLD = 0.7
local SUB_LEAK_MAX_RATE = 140
local SUB_LEAK_OFFSET_INTERVAL = 0.8
local SUB_WARNING_LIGHT_THRESHOLD = 0.55
local SUB_WARNING_LIGHT_COLOR = Color3.fromRGB(255, 105, 64)
local SUB_WARNING_LIGHT_BASE_RANGE = 10
local SUB_WARNING_LIGHT_MAX_RANGE = 20
local SUB_WARNING_LIGHT_MIN_BRIGHTNESS = 2.5
local SUB_WARNING_LIGHT_MAX_BRIGHTNESS = 10
local SUB_WARNING_LIGHT_PULSE_SPEED = 6
local SUB_IMPL_DEBRIS_MAX_COUNT = 40
local SUB_IMPL_DEBRIS_LIFETIME = 6
local SUB_IMPL_DEBRIS_MIN_SPEED = 35
local SUB_IMPL_DEBRIS_MAX_SPEED = 80
local SUB_IMPL_DEBRIS_MAX_ANGULAR = math.rad(160)
local SUB_IMPL_DEBRIS_FADE_TIME = 3.5

local SUB_COLLISION_DAMAGE_RATIO = 0.18 -- percent of max hull lost per qualifying collision before modifiers
local SUB_COLLISION_GLOBAL_COOLDOWN = 0.3
local SUB_COLLISION_PART_COOLDOWN = 1.2
local SUB_COLLISION_PRINT_COOLDOWN = 0.75
local SUB_COLLISION_POLL_INTERVAL = 0.05
local SUB_COLLISION_POLL_PART_LIMIT = 8
local SUB_COLLISION_BOX_PADDING = Vector3.new(4, 4, 4)
local SUB_COLLISION_IGNORE_ATTRIBUTE = "IgnoreCollision"

local ZERO_VECTOR = Vector3.new()

local TriggerSubmarineImplosion

local function clearTable(tbl)
        if not tbl then
                return
        end

        for key in pairs(tbl) do
                tbl[key] = nil
        end
end

local function GetOrCreateOverlapParams(state, boat)
        if not state then
                return nil
        end

        local params = state.collisionOverlapParams
        if not params then
                params = OverlapParams.new()
                params.RespectCanCollide = false
                params.FilterType = Enum.RaycastFilterType.Exclude
                state.collisionOverlapParams = params
        end

        local filterList = state.collisionFilterList
        if not filterList then
                filterList = {}
                state.collisionFilterList = filterList
        else
                clearTable(filterList)
        end

        params.MaxParts = 0

        if boat then
                table.insert(filterList, boat)

                local physicsObjects = BoatPhysicsObjects[boat]
                if physicsObjects and physicsObjects.controlPart then
                        table.insert(filterList, physicsObjects.controlPart)
                end
        end

        params.FilterDescendantsInstances = filterList

        return params
end

local function BelongsToPlayerCharacter(part)
        local ancestor = part and part.Parent
        while ancestor do
                if Players:GetPlayerFromCharacter(ancestor) then
                        return true
                end

                ancestor = ancestor.Parent
        end

        return false
end

local function ShouldIgnoreCollision(part)
        if not part or not part:IsA("BasePart") then
                return true
        end

        if part:GetAttribute(SUB_COLLISION_IGNORE_ATTRIBUTE) == true then
                return true
        end

        if BelongsToPlayerCharacter(part) then
                return true
        end

        return false
end

local function GatherCollisionContacts(part, overlapParams, buffer)
        if not part or not part:IsA("BasePart") then
                return buffer
        end

        buffer = buffer or {}

        if part.CanQuery == false then
                part.CanQuery = true
        end

        for existing in pairs(buffer) do
                buffer[existing] = nil
        end

        if part.CanTouch ~= false then
                local touchingParts = part:GetTouchingParts()
                for _, otherPart in ipairs(touchingParts) do
                        if otherPart and otherPart:IsA("BasePart") and not ShouldIgnoreCollision(otherPart) then
                                buffer[otherPart] = true
                        end
                end
        end

        if overlapParams then
                overlapParams.CollisionGroup = part.CollisionGroup

                if Workspace.GetPartsInPart then
                        local success, overlapParts = pcall(Workspace.GetPartsInPart, Workspace, part, overlapParams)
                        if success and overlapParts then
                                for _, otherPart in ipairs(overlapParts) do
                                        if otherPart and otherPart:IsA("BasePart") and not ShouldIgnoreCollision(otherPart) then
                                                buffer[otherPart] = true
                                        end
                                end
                        end
                end

                if Workspace.GetPartBoundsInBox then
                        local size = part.Size + SUB_COLLISION_BOX_PADDING
                        local cframe = part.CFrame
                        local success, overlapParts = pcall(Workspace.GetPartBoundsInBox, Workspace, cframe, size, overlapParams)
                        if success and overlapParts then
                                for _, otherPart in ipairs(overlapParts) do
                                        if otherPart and otherPart:IsA("BasePart") and not ShouldIgnoreCollision(otherPart) then
                                                buffer[otherPart] = true
                                        end
                                end
                        end
                end
        end

        return buffer
end

-- Memory management
local MemoryCheckTimer = 0
local BOAT_CLEANUP_QUEUE = {}

-- Constants
local SPAWN_DISTANCE = 20
local MAX_SPAWN_DISTANCE = 200 -- NEW: Limit spawn distance from player

local function getWaterLevel(position: Vector3?): number
        return WaterPhysics.GetWaterLevel(position)
end

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
                baseMaxSpeed = config.MaxSpeed or 25,
                maxSpeed = config.MaxSpeed or 25,
                weight = config.Weight or 3,
                accelerationRate = BoatConfig.GetAcceleration(boatType),
                baseAccelerationRate = BoatConfig.GetAcceleration(boatType),
                decelerationRate = BoatConfig.GetDeceleration(boatType),
                baseDecelerationRate = BoatConfig.GetDeceleration(boatType),
                turnAccelerationRate = 3 * (1.5 - (config.Weight / 10)),
                baseTurnAccelerationRate = 3 * (1.5 - (config.Weight / 10))
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
        SubmarineStates[player] = nil
end

-- Process cleanup queue
local function UpdateSubmarineStressMetrics(state)
        if not state then
                return 1, 1, 1, 0
        end

        local integrityRatio = 1
        if state.maxHealth > 0 then
                integrityRatio = math.clamp(state.health / state.maxHealth, 0, 1)
        end

        local speedMultiplier = SUB_SPEED_MIN_MULTIPLIER + (1 - SUB_SPEED_MIN_MULTIPLIER) * integrityRatio
        if integrityRatio >= 0.995 then
                speedMultiplier = 1
        end

        local accelMultiplier = SUB_ACCEL_MIN_MULTIPLIER + (1 - SUB_ACCEL_MIN_MULTIPLIER) * integrityRatio
        if integrityRatio >= 0.995 then
                accelMultiplier = 1
        end

        local shakeIntensity = 0
        if integrityRatio < SUB_SHAKE_START_RATIO then
                shakeIntensity = math.clamp((SUB_SHAKE_START_RATIO - integrityRatio) / SUB_SHAKE_START_RATIO, 0, 1)
        end

        state.integrityRatio = integrityRatio
        state.speedMultiplier = speedMultiplier
        state.accelMultiplier = accelMultiplier
        state.shakeIntensity = shakeIntensity

        return integrityRatio, speedMultiplier, accelMultiplier, shakeIntensity
end

local function GetOrCreateSubmarineState(player, config)
        local state = SubmarineStates[player]
        local maxHealth = (config and config.MaxHealth) or (state and state.maxHealth) or 100

        if not state then
                state = {
                        maxHealth = maxHealth,
                        health = maxHealth,
                        lastHealthPercentPrint = 100,
                        timeOverDepth = 0,
                        wasOverDepth = false,
                        lastWarningTime = 0,
                        lastSafeMessageTime = 0,
                        isImploding = false,
                        lastDepth = 0,
                        integrityRatio = 1,
                        speedMultiplier = 1,
                        accelMultiplier = 1,
                        shakeIntensity = 0,
                        lastStressOffset = ZERO_VECTOR,
                        currentJitterAllowance = 0,
                        hullRadius = nil,
                        hullRadiusPart = nil,
                        lastStressOffsetDelta = 0,
                        lastLeakEmissionRate = 0,
                        lastWarningRange = 0,
                        lastWarningBrightness = 0,
                        lastCollisionTime = 0,
                        recentCollisionParts = {},
                        lastCollisionPrint = 0,
                }
                state.shakeRandom = Random.new()
                state.warningPhase = math.random()
                SubmarineStates[player] = state
        else
                if state.maxHealth ~= maxHealth then
                        state.maxHealth = maxHealth
                        state.health = math.clamp(state.health, 0, maxHealth)
                end

                state.recentCollisionParts = state.recentCollisionParts or {}
        end

        UpdateSubmarineStressMetrics(state)
        return state
end

local INSTANT_KILL_ATTRIBUTE_NAMES = {
        "SubInstantKill",
        "InstantSubKill",
        "InstantKill",
        "KillOnTouch",
}

local INSTANT_KILL_TAGS = {
        SubInstantKill = true,
        InstantKill = true,
        SubmarineInstantKill = true,
}

local function FindFirstAttributeInAncestors(instance, attributeName)
        local current = instance
        while current do
                if current:GetAttribute(attributeName) ~= nil then
                        return current:GetAttribute(attributeName), current
                end
                current = current.Parent
        end

        return nil, nil
end

local function DescribeInstantKill(part)
        if not part or not part:IsA("BasePart") then
                return nil
        end

        for _, attributeName in ipairs(INSTANT_KILL_ATTRIBUTE_NAMES) do
                local value, source = FindFirstAttributeInAncestors(part, attributeName)
                if value ~= nil then
                        local sourceName = source and source:GetFullName() or part:GetFullName()
                        return string.format("attribute '%s' on %s", attributeName, sourceName)
                end
        end

        local success, tags = pcall(CollectionService.GetTags, CollectionService, part)
        if success then
                for _, tag in ipairs(tags) do
                        if INSTANT_KILL_TAGS[tag] then
                                return string.format("CollectionService tag '%s'", tag)
                        end
                end
        end

        return nil
end

local function GetCollisionDamageMultiplier(part)
        if not part or not part:IsA("BasePart") then
                return 1
        end

        local multiplier, source = FindFirstAttributeInAncestors(part, "SubDamageMultiplier")
        if typeof(multiplier) == "number" and multiplier > 0 then
                return multiplier
        elseif typeof(multiplier) == "number" and multiplier == 0 and source then
                return 0
        end

        return 1
end

local function ApplySubmarineCollisionDamage(player, boat, config, hitPart, otherPart)
        if not boat or not boat.Parent or not otherPart or not otherPart:IsA("BasePart") then
                return
        end

        if ShouldIgnoreCollision(otherPart) then
                return
        end

        if otherPart:IsDescendantOf(boat) then
                return
        end

        local primaryPart = boat.PrimaryPart
        if not primaryPart then
                return
        end

        if otherPart == primaryPart or (otherPart.AssemblyRootPart and otherPart.AssemblyRootPart == primaryPart) then
                return
        end

        local otherParent = otherPart.Parent
        if otherParent then
                if Players:GetPlayerFromCharacter(otherParent) then
                        return
                end

                local humanoid = otherParent:FindFirstChildOfClass("Humanoid")
                if humanoid then
                        return
                end
        end

        if otherPart.Material == Enum.Material.Water then
                return
        end

        local otherName = string.lower(otherPart.Name or "")
        if otherName == "water" or otherName == "ocean" or otherName == "sea" then
                return
        end

        local state = GetOrCreateSubmarineState(player, config)
        if not state or state.isImploding then
                return
        end

        local now = tick()
        if (now - (state.lastCollisionTime or 0)) < SUB_COLLISION_GLOBAL_COOLDOWN then
                return
        end

        state.recentCollisionParts = state.recentCollisionParts or {}
        for trackedPart, hitTime in pairs(state.recentCollisionParts) do
                if not hitTime or (now - hitTime) > (SUB_COLLISION_PART_COOLDOWN * 2) or (trackedPart and not trackedPart.Parent) then
                        state.recentCollisionParts[trackedPart] = nil
                end
        end
        local lastForPart = state.recentCollisionParts[otherPart]
        if lastForPart and (now - lastForPart) < SUB_COLLISION_PART_COOLDOWN then
                return
        end

        state.lastCollisionTime = now
        state.recentCollisionParts[otherPart] = now

        local instantReason = DescribeInstantKill(otherPart)
        if instantReason then
                print(string.format(
                        "[Submarine] Instant hull failure triggered by collision with %s (%s).",
                        otherPart:GetFullName(),
                        instantReason
                ))

                state.health = 0
                TriggerSubmarineImplosion(player, boat, config)
                return
        end

        if not state.maxHealth or state.maxHealth <= 0 then
                return
        end

        local boatVelocity = primaryPart.AssemblyLinearVelocity or ZERO_VECTOR
        local hitVelocity = hitPart and (hitPart.AssemblyLinearVelocity or hitPart.Velocity) or ZERO_VECTOR
        if hitVelocity.Magnitude > boatVelocity.Magnitude then
                boatVelocity = hitVelocity
        elseif boatVelocity.Magnitude < 0.5 and primaryPart.Velocity then
                boatVelocity = primaryPart.Velocity
        end

        local otherVelocity = otherPart.AssemblyLinearVelocity or otherPart.Velocity or ZERO_VECTOR
        local relativeSpeed = (boatVelocity - otherVelocity).Magnitude

        local boatMass = primaryPart.AssemblyMass or primaryPart:GetMass()
        local otherMass = otherPart.AssemblyMass or otherPart:GetMass()
        local massFactor = 1
        if boatMass and boatMass > 0 and otherMass and otherMass > 0 then
                massFactor = math.clamp(otherMass / boatMass, 0.4, 2.5)
        elseif otherPart.Anchored then
                massFactor = 1.35
        end

        local anchoredFactor = otherPart.Anchored and 1.2 or 1
        local damageMultiplier = GetCollisionDamageMultiplier(otherPart)

        local damage = state.maxHealth
                * SUB_COLLISION_DAMAGE_RATIO
                * massFactor
                * anchoredFactor
                * damageMultiplier
        if damage <= 0 then
                return
        end

        state.health = math.max(state.health - damage, 0)
        UpdateSubmarineStressMetrics(state)

        local currentPercent = math.clamp(math.floor((state.health / state.maxHealth) * 100), 0, 100)
        if state.health <= 0 then
                local impactSource
                if hitPart and hitPart.Parent == boat then
                        impactSource = string.format("%s -> %s", hitPart:GetFullName(), otherPart:GetFullName())
                else
                        impactSource = otherPart:GetFullName()
                end

                print(string.format(
                        "[Submarine] Hull collapsed after collision between %s (reported speed %.1f studs/s).",
                        impactSource,
                        relativeSpeed
                ))
                TriggerSubmarineImplosion(player, boat, config)
                return
        end

        if not state.lastHealthPercentPrint or currentPercent <= state.lastHealthPercentPrint - SUB_HEALTH_WARNING_STEP then
                print(string.format(
                        "[Submarine] Hull integrity at %d%% after collision with %s (reported speed %.1f).",
                        currentPercent,
                        otherPart:GetFullName(),
                        relativeSpeed
                ))
                state.lastHealthPercentPrint = currentPercent
        elseif (now - (state.lastCollisionPrint or 0)) > SUB_COLLISION_PRINT_COOLDOWN then
                print(string.format(
                        "[Submarine] Collision registered with %s (reported speed %.1f).",
                        otherPart:GetFullName(),
                        relativeSpeed
                ))
                state.lastCollisionPrint = now
        end
end

local function SetupSubmarineCollisionMonitoring(player, boat, config)
        if not boat or not boat.PrimaryPart then
                return
        end

        local state = GetOrCreateSubmarineState(player, config)
        state.lastCollisionTime = 0
        state.lastCollisionPrint = 0
        state.recentCollisionParts = state.recentCollisionParts or {}
        for trackedPart in pairs(state.recentCollisionParts) do
                state.recentCollisionParts[trackedPart] = nil
        end

        if state.collisionPollConnection then
                state.collisionPollConnection:Disconnect()
                state.collisionPollConnection = nil
        end

        state.collisionPollParts = state.collisionPollParts or {}
        clearTable(state.collisionPollParts)
        state.collisionPollIndex = 0
        state.nextCollisionPoll = 0

        local connections = BoatConnections[player]
        if not connections then
                connections = {}
                BoatConnections[player] = connections
        end

        local hitboxParts = {}
        for _, desc in ipairs(boat:GetDescendants()) do
                if desc:IsA("BasePart") and string.lower(desc.Name) == "hitbox" then
                        if desc.CanTouch == false then
                                desc.CanTouch = true
                        end
                        local connection = desc.Touched:Connect(function(otherPart)
                                ApplySubmarineCollisionDamage(player, boat, config, desc, otherPart)
                        end)
                        table.insert(connections, connection)
                        table.insert(hitboxParts, desc)
                end
        end

        if #hitboxParts == 0 then
                warn(string.format("[Submarine] No Hitbox part found for %s; collision damage may not register.", boat:GetFullName()))
        else
                state.collisionPollParts = hitboxParts
                state.collisionOverlapParams = GetOrCreateOverlapParams(state, boat)
                local ancestryConnection = boat.AncestryChanged:Connect(function(_, parent)
                        if not parent then
                                for _, part in ipairs(hitboxParts) do
                                        state.recentCollisionParts[part] = nil
                                end
                                clearTable(hitboxParts)
                                clearTable(state.collisionPollParts)
                                state.collisionPollIndex = 0
                        end
                end)
                table.insert(connections, ancestryConnection)

                state.collisionPollConnection = RunService.Heartbeat:Connect(function()
                        if state.isImploding then
                                return
                        end

                        if not boat.Parent then
                                return
                        end

                        local primaryPart = boat.PrimaryPart
                        if not primaryPart then
                                return
                        end

                        if primaryPart:GetNetworkOwner() == nil then
                                return
                        end

                        local now = tick()
                        if now < (state.nextCollisionPoll or 0) then
                                return
                        end

                        local pollParts = state.collisionPollParts
                        local totalParts = pollParts and #pollParts or 0
                        if totalParts == 0 then
                                return
                        end

                        state.nextCollisionPoll = now + SUB_COLLISION_POLL_INTERVAL

                        local index = state.collisionPollIndex or 0
                        local checksRemaining = math.min(totalParts, SUB_COLLISION_POLL_PART_LIMIT)
                        local checked = 0

                        while checked < checksRemaining and totalParts > 0 do
                                index += 1
                                if index > totalParts then
                                        index = 1
                                end

                                local part = pollParts[index]
                                if not part or not part.Parent or not part:IsDescendantOf(boat) then
                                        table.remove(pollParts, index)
                                        totalParts -= 1
                                        if totalParts == 0 then
                                                index = 0
                                                break
                                        end
                                        if index > totalParts then
                                                index = 0
                                        else
                                                index -= 1
                                        end
                                else
                                        checked += 1
                                        local contactBuffer = state.collisionContactBuffer
                                        contactBuffer = GatherCollisionContacts(part, state.collisionOverlapParams, contactBuffer)
                                        state.collisionContactBuffer = contactBuffer

                                        if contactBuffer then
                                                for otherPart in pairs(contactBuffer) do
                                                        if otherPart and otherPart:IsA("BasePart") then
                                                                ApplySubmarineCollisionDamage(player, boat, config, part, otherPart)
                                                        end
                                                        contactBuffer[otherPart] = nil
                                                end
                                        end
                                end
                        end

                        state.collisionPollIndex = index
                end)
                table.insert(connections, state.collisionPollConnection)
        end
end

local function ApplySubmarineStressEffects(player, boat, config, targetCFrame, deltaTime)
        local state = SubmarineStates[player]
        if not state or state.isImploding or not boat or not boat.PrimaryPart then
                if state then
                        state.currentJitterAllowance = 0
                        state.lastStressOffset = ZERO_VECTOR
                        state.lastStressOffsetDelta = 0
                end
                return targetCFrame
        end

        local integrityRatio = state.integrityRatio or 1
        local primaryPart = boat.PrimaryPart
        local baseCFrame = targetCFrame
        local previousStressOffset = state.lastStressOffset or ZERO_VECTOR
        local jitterAllowance = 0

        if state.shakeIntensity and state.shakeIntensity > 0 then
                local randomGen = state.shakeRandom or Random.new()
                state.shakeRandom = randomGen

                local offsetMagnitude = SUB_SHAKE_MAX_OFFSET * state.shakeIntensity
                local angleMagnitude = SUB_SHAKE_MAX_ANGLE * state.shakeIntensity

                local offset = Vector3.new(
                        randomGen:NextNumber(-offsetMagnitude, offsetMagnitude),
                        randomGen:NextNumber(-offsetMagnitude, offsetMagnitude),
                        randomGen:NextNumber(-offsetMagnitude, offsetMagnitude)
                )

                local rotX = randomGen:NextNumber(-angleMagnitude, angleMagnitude)
                local rotY = randomGen:NextNumber(-angleMagnitude, angleMagnitude)
                local rotZ = randomGen:NextNumber(-angleMagnitude, angleMagnitude)

                local stressOffsetWorld = baseCFrame:VectorToWorldSpace(offset)
                targetCFrame = baseCFrame * CFrame.new(offset) * CFrame.Angles(rotX, rotY, rotZ)

                local hullRadius = state.hullRadius
                if not hullRadius or state.hullRadiusPart ~= primaryPart then
                        hullRadius = primaryPart.Size.Magnitude * 0.5
                        state.hullRadius = hullRadius
                        state.hullRadiusPart = primaryPart
                end

                local offsetDelta = (stressOffsetWorld - previousStressOffset).Magnitude
                local baselineAllowance = offsetMagnitude * 0.35
                if hullRadius then
                        baselineAllowance = baselineAllowance + math.min(hullRadius, 1) * (angleMagnitude * 0.5)
                end

                jitterAllowance = math.max(offsetDelta, baselineAllowance)
                state.lastStressOffset = stressOffsetWorld
                state.lastStressOffsetDelta = offsetDelta
        end

        if integrityRatio < SUB_LEAK_THRESHOLD then
                local attachment = state.damageAttachment
                if not attachment or attachment.Parent ~= primaryPart then
                        attachment = Instance.new("Attachment")
                        attachment.Name = "HullLeakAttachment"
                        attachment.Position = Vector3.new(0, -primaryPart.Size.Y * 0.4, 0)
                        attachment.Parent = primaryPart
                        state.damageAttachment = attachment
                end

                local currentTime = tick()
                if (currentTime - (state.lastLeakOffsetTime or 0)) > SUB_LEAK_OFFSET_INTERVAL then
                        state.lastLeakOffsetTime = currentTime
                        local randomGen = state.shakeRandom or Random.new()
                        local offset = Vector3.new(
                                randomGen:NextNumber(-primaryPart.Size.X * 0.45, primaryPart.Size.X * 0.45),
                                randomGen:NextNumber(-primaryPart.Size.Y * 0.45, primaryPart.Size.Y * 0.2),
                                randomGen:NextNumber(-primaryPart.Size.Z * 0.45, primaryPart.Size.Z * 0.45)
                        )
                        attachment.Position = offset
                end

                local emitter = state.damageEmitter
                if not emitter or emitter.Parent ~= attachment then
                        emitter = Instance.new("ParticleEmitter")
                        emitter.Name = "HullLeakBubbles"
                        emitter.Rate = 0
                        emitter.Speed = NumberRange.new(5, 9)
                        emitter.Lifetime = NumberRange.new(0.8, 1.4)
                        emitter.Size = NumberSequence.new({
                                NumberSequenceKeypoint.new(0, 0.4),
                                NumberSequenceKeypoint.new(0.5, 0.9),
                                NumberSequenceKeypoint.new(1, 0.3)
                        })
                        emitter.Transparency = NumberSequence.new({
                                NumberSequenceKeypoint.new(0, 0),
                                NumberSequenceKeypoint.new(1, 1)
                        })
                        emitter.Color = ColorSequence.new(Color3.fromRGB(214, 238, 255))
                        emitter.Acceleration = Vector3.new(0, 14, 0)
                        emitter.SpreadAngle = Vector2.new(45, 45)
                        emitter.Parent = attachment
                        state.damageEmitter = emitter
                        state.lastLeakEmissionRate = 0
                end

                local emissionRate = math.clamp(30 + (1 - integrityRatio) * SUB_LEAK_MAX_RATE, 20, SUB_LEAK_MAX_RATE)
                if math.abs((state.lastLeakEmissionRate or 0) - emissionRate) > 1 then
                        state.damageEmitter.Rate = emissionRate
                        state.lastLeakEmissionRate = emissionRate
                end

                local shouldEnableEmitter = emissionRate > 0
                if state.damageEmitter.Enabled ~= shouldEnableEmitter then
                        state.damageEmitter.Enabled = shouldEnableEmitter
                end
        elseif state.damageEmitter then
                if state.damageEmitter.Rate ~= 0 then
                        state.damageEmitter.Rate = 0
                end
                if state.damageEmitter.Enabled then
                        state.damageEmitter.Enabled = false
                end
                state.lastLeakEmissionRate = 0
        end

        if integrityRatio < SUB_WARNING_LIGHT_THRESHOLD then
                local light = state.warningLight
                if not light or light.Parent ~= primaryPart then
                        light = Instance.new("PointLight")
                        light.Name = "HullWarningLight"
                        light.Color = SUB_WARNING_LIGHT_COLOR
                        light.Shadows = false
                        light.Range = SUB_WARNING_LIGHT_BASE_RANGE
                        light.Brightness = SUB_WARNING_LIGHT_MIN_BRIGHTNESS
                        light.Enabled = true
                        light.Parent = primaryPart
                        state.warningLight = light
                        state.lastWarningRange = light.Range
                        state.lastWarningBrightness = light.Brightness
                end

                local pulse = 0.5 + 0.5 * math.sin((tick() * SUB_WARNING_LIGHT_PULSE_SPEED) + (state.warningPhase or 0))
                local intensityFactor = (1 - integrityRatio)
                if not light.Enabled then
                        light.Enabled = true
                end

                local targetRange = SUB_WARNING_LIGHT_BASE_RANGE
                        + intensityFactor * (SUB_WARNING_LIGHT_MAX_RANGE - SUB_WARNING_LIGHT_BASE_RANGE)
                if math.abs((state.lastWarningRange or 0) - targetRange) > 0.25 then
                        light.Range = targetRange
                        state.lastWarningRange = targetRange
                end

                local targetBrightness = SUB_WARNING_LIGHT_MIN_BRIGHTNESS
                        + pulse * (SUB_WARNING_LIGHT_MAX_BRIGHTNESS - SUB_WARNING_LIGHT_MIN_BRIGHTNESS) * intensityFactor
                if math.abs((state.lastWarningBrightness or 0) - targetBrightness) > 0.25 then
                        light.Brightness = targetBrightness
                        state.lastWarningBrightness = targetBrightness
                end

        elseif state.warningLight then
                if state.warningLight.Enabled then
                        state.warningLight.Enabled = false
                end
        end

        if jitterAllowance == 0 then
                jitterAllowance = previousStressOffset.Magnitude
                state.lastStressOffset = ZERO_VECTOR
                state.lastStressOffsetDelta = jitterAllowance
        end

        if jitterAllowance < 0.05 then
                jitterAllowance = 0
                state.lastStressOffsetDelta = 0
        end

        state.currentJitterAllowance = jitterAllowance

        return targetCFrame
end

local function CreateSubmarineImplosionDebris(boat, primaryPart)
        if not boat or not primaryPart then
                return
        end

        local randomGen = Random.new()
        local created = 0

        for _, desc in ipairs(boat:GetDescendants()) do
                if created >= SUB_IMPL_DEBRIS_MAX_COUNT then
                        break
                end

                if desc:IsA("BasePart") and desc.Transparency < 1 and desc.Size.Magnitude > 0 then
                        local success, debrisPart = pcall(function()
                                return desc:Clone()
                        end)

                        if success and debrisPart and debrisPart:IsA("BasePart") then
                                created += 1

                                debrisPart.Name = desc.Name .. "_Debris"
                                debrisPart.Anchored = false
                                debrisPart.CanCollide = false
                                debrisPart.CanTouch = false
                                debrisPart.CanQuery = false
                                debrisPart.Massless = false
                                debrisPart.CFrame = desc.CFrame
                                debrisPart.Parent = workspace
                                debrisPart:BreakJoints()

                                for _, child in ipairs(debrisPart:GetDescendants()) do
                                        if child:IsA("Weld") or child:IsA("Motor6D") or child:IsA("Constraint") or child:IsA("BodyMover") then
                                                child:Destroy()
                                        elseif child:IsA("ParticleEmitter") then
                                                child.Enabled = false
                                                child.Rate = 0
                                        elseif child:IsA("Light") then
                                                child.Enabled = false
                                        end
                                end

                                local direction = (debrisPart.Position - primaryPart.Position)
                                if direction.Magnitude < 0.001 then
                                        direction = Vector3.new(
                                                randomGen:NextNumber(-1, 1),
                                                randomGen:NextNumber(-1, 1),
                                                randomGen:NextNumber(-1, 1)
                                        )
                                end
                                direction = direction.Unit

                                local speed = randomGen:NextNumber(SUB_IMPL_DEBRIS_MIN_SPEED, SUB_IMPL_DEBRIS_MAX_SPEED)
                                local angular = SUB_IMPL_DEBRIS_MAX_ANGULAR

                                debrisPart.AssemblyLinearVelocity = direction * speed
                                debrisPart.AssemblyAngularVelocity = Vector3.new(
                                        randomGen:NextNumber(-angular, angular),
                                        randomGen:NextNumber(-angular, angular),
                                        randomGen:NextNumber(-angular, angular)
                                )

                                if TweenService then
                                        local fadeTween = TweenService:Create(
                                                debrisPart,
                                                TweenInfo.new(SUB_IMPL_DEBRIS_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                                                {Transparency = 1}
                                        )
                                        fadeTween:Play()
                                end

                                Debris:AddItem(debrisPart, SUB_IMPL_DEBRIS_LIFETIME)
                        elseif debrisPart then
                                debrisPart:Destroy()
                        end
                end
        end
end

TriggerSubmarineImplosion = function(player, boat, config)
        local state = SubmarineStates[player]
        if state then
                if state.isImploding then
                        return
                end
                state.isImploding = true
        end

        local playerName = player and player.Name or "Unknown"
        print(('[Submarine] CRITICAL: %s\'s submarine has imploded under pressure!'):format(playerName))

        local primaryPart = boat and boat.PrimaryPart
        if primaryPart then
                local effectPart = Instance.new("Part")
                effectPart.Name = "SubImplosionEffect"
                effectPart.Anchored = true
                effectPart.CanCollide = false
                effectPart.Transparency = 1
                effectPart.Size = Vector3.new(1, 1, 1)
                effectPart.CFrame = primaryPart.CFrame
                effectPart.Parent = workspace

                local bubbleBurst = Instance.new("ParticleEmitter")
                bubbleBurst.Name = "ImplosionBubbles"
                bubbleBurst.Rate = 0
                bubbleBurst.Speed = NumberRange.new(25, 35)
                bubbleBurst.Lifetime = NumberRange.new(0.35, 0.6)
                bubbleBurst.Size = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 6),
                        NumberSequenceKeypoint.new(1, 0)
                })
                bubbleBurst.Transparency = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0),
                        NumberSequenceKeypoint.new(1, 1)
                })
                bubbleBurst.Acceleration = Vector3.new(0, -60, 0)
                bubbleBurst.Color = ColorSequence.new(Color3.fromRGB(210, 235, 255), Color3.fromRGB(32, 120, 255))
                bubbleBurst.SpreadAngle = Vector2.new(360, 360)
                bubbleBurst.LightEmission = 0.8
                bubbleBurst.Parent = effectPart
                bubbleBurst:Emit(200)

                local shockwave = Instance.new("ParticleEmitter")
                shockwave.Name = "ImplosionShockwave"
                shockwave.Rate = 0
                shockwave.Speed = NumberRange.new(15, 18)
                shockwave.Lifetime = NumberRange.new(0.2, 0.35)
                shockwave.Size = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 2),
                        NumberSequenceKeypoint.new(0.3, 8),
                        NumberSequenceKeypoint.new(1, 12)
                })
                shockwave.Transparency = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0),
                        NumberSequenceKeypoint.new(1, 1)
                })
                shockwave.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
                shockwave.LightEmission = 1
                shockwave.Parent = effectPart
                shockwave:Emit(35)

                Debris:AddItem(effectPart, 3)

                local implosionFlash = Instance.new("Explosion")
                implosionFlash.Name = "SubImplosionFlash"
                implosionFlash.BlastPressure = 0
                implosionFlash.BlastRadius = 0
                implosionFlash.DestroyJointRadiusPercent = 0
                implosionFlash.Position = primaryPart.Position
                implosionFlash.Visible = true
                implosionFlash.Parent = workspace

                CreateSubmarineImplosionDebris(boat, primaryPart)

                if state.damageEmitter then
                        state.damageEmitter.Rate = 0
                        state.damageEmitter.Enabled = false
                end
                if state.warningLight then
                        state.warningLight.Enabled = false
                end

                for _, desc in ipairs(boat:GetDescendants()) do
                        if desc:IsA("BasePart") then
                                desc.CanCollide = false
                                desc.Transparency = 1
                        elseif desc:IsA("ParticleEmitter") then
                                desc.Rate = 0
                        end
                end
        end

        task.defer(function()
                CleanupBoat(player)
        end)
end

local function ApplySubmarineDepthDamage(player, boat, config, targetPosition, deltaTime)
        if not config or not config.MaxDepth then
                return false
        end

        local state = GetOrCreateSubmarineState(player, config)
        if state.isImploding then
                return true
        end

        local depth = SubmarinePhysics.GetDepth(targetPosition)
        state.lastDepth = depth

        local overDepth = depth - config.MaxDepth
        if overDepth <= 0 then
                if state.wasOverDepth then
                        state.wasOverDepth = false
                        state.timeOverDepth = math.max(state.timeOverDepth - deltaTime, 0)

                        if (tick() - (state.lastSafeMessageTime or 0)) > SUB_SAFE_RECOVERY_COOLDOWN then
                                local playerName = player and player.Name or "Unknown"
                                print(('[Submarine] Hull integrity stabilizing for %s\'s submarine.'):format(playerName))
                                state.lastSafeMessageTime = tick()
                        end
                else
                        state.timeOverDepth = math.max(state.timeOverDepth - deltaTime, 0)
                end

                if state.health < state.maxHealth then
                        local regenAmount = state.maxHealth * SUB_HEALTH_RECOVERY_RATE * deltaTime
                        state.health = math.min(state.maxHealth, state.health + regenAmount)
                        if state.health >= state.maxHealth then
                                state.lastHealthPercentPrint = 100
                        end
                end

                UpdateSubmarineStressMetrics(state)
                return false
        end

        state.wasOverDepth = true
        state.timeOverDepth = state.timeOverDepth + deltaTime

        if (tick() - (state.lastWarningTime or 0)) > SUB_DEPTH_WARNING_COOLDOWN then
                local playerName = player and player.Name or "Unknown"
                print(('[Submarine] WARNING: %s\'s submarine has exceeded its safe depth! Hull under extreme pressure.'):format(playerName))
                state.lastWarningTime = tick()
        end

        local safeMaxDepth = math.max(config.MaxDepth, 1)
        local depthRatio = overDepth / safeMaxDepth
        local sustainedFactor = state.timeOverDepth * SUB_PRESSURE_TIME_MULTIPLIER
        local damageRate = SUB_PRESSURE_BASE_DAMAGE + (depthRatio * SUB_PRESSURE_DEPTH_MULTIPLIER) + sustainedFactor
        local damage = damageRate * deltaTime
        state.health = math.max(state.health - damage, 0)

        local currentPercent = math.clamp(math.floor((state.health / state.maxHealth) * 100), 0, 100)
        if not state.lastHealthPercentPrint or currentPercent <= state.lastHealthPercentPrint - SUB_HEALTH_WARNING_STEP then
                local playerName = player and player.Name or "Unknown"
                print(('[Submarine] Hull integrity at %d%% for %s\'s submarine.'):format(currentPercent, playerName))
                state.lastHealthPercentPrint = currentPercent
        end

        UpdateSubmarineStressMetrics(state)
        if state.health <= 0 then
                TriggerSubmarineImplosion(player, boat, config)
                return true
        end

        return false
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

        local waterLevel = getWaterLevel(spawnPosition)
        if config.Type == "Submarine" then
                spawnPosition = Vector3.new(spawnPosition.X, waterLevel - 1, spawnPosition.Z)
        else
                spawnPosition = Vector3.new(spawnPosition.X, waterLevel + 2, spawnPosition.Z)
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

        if config.Type == "Submarine" then
                local state = GetOrCreateSubmarineState(player, config)
                state.health = state.maxHealth
                state.lastHealthPercentPrint = 100
                state.timeOverDepth = 0
                state.wasOverDepth = false
                local now = tick()
                state.lastWarningTime = now - SUB_DEPTH_WARNING_COOLDOWN
                state.lastSafeMessageTime = now
                state.isImploding = false
        else
                SubmarineStates[player] = nil
        end

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

        if config.Type == "Submarine" then
                SetupSubmarineCollisionMonitoring(player, boat, config)
        end

        local teleportPart = boat:FindFirstChild("TeleportPart", true)
        if teleportPart and teleportPart:IsA("BasePart") then
                BoatSecurity.RegisterSafeTeleport(player, boat.PrimaryPart and boat.PrimaryPart.Position or teleportPart.Position)

                task.defer(function()
                        local character = player.Character
                        if not character then
                                return
                        end

                        local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
                        if not humanoidRootPart then
                                return
                        end

                        local teleportCFrame = teleportPart.CFrame
                        if character.Parent then
                                character:PivotTo(teleportCFrame)
                        else
                                humanoidRootPart.CFrame = teleportCFrame
                        end
                end)
        end

        return true
end

-- Despawn function
function BoatManager.DespawnBoat(player)
	CleanupBoat(player)
	return true
end

-- ENHANCED CONTROL UPDATE WITH BETTER VALIDATION
local function sanitizeControlAxis(value)
        if typeof(value) ~= "number" then
                return 0
        end

        if value ~= value or math.abs(value) == math.huge then
                return 0
        end

        return math.clamp(value, -1, 1)
end

local function UpdateBoatControl(player, controls)
        -- Better rate limiting
        if not BoatSecurity.CheckRemoteRateLimit(player, "UpdateBoatControl", MAX_CONTROL_RATE) then
                return
        end

        local boat = ActiveBoats[player]
        if not boat or not boat.Parent then
                return
        end

        if not BoatSecurity.ValidateOwnership(player, boat) then
                return
        end

        if not BoatControllers[player] or not BoatControllers[player].Parent then
                return
        end

        local boatType = boat:GetAttribute("BoatType")
        local boatConfig = boatType and BoatConfig.GetBoatData(boatType) or nil
        local isSubmarine = boatConfig and boatConfig.Type == "Submarine"

        -- Validate inputs
        local throttle = sanitizeControlAxis(controls.throttle)
        local steer = sanitizeControlAxis(controls.steer)
        local ascend = sanitizeControlAxis(controls.ascend)
        local pitch = sanitizeControlAxis(controls.pitch)
        local roll = sanitizeControlAxis(controls.roll)

        -- Validate speed from client with stricter checks
        local clientSpeed = controls.currentSpeed
        if clientSpeed ~= nil then
                if typeof(clientSpeed) ~= "number" or clientSpeed ~= clientSpeed or math.abs(clientSpeed) == math.huge then
                        warn("Invalid speed value from", player.Name)
                        return
                end

        end

        local accelData = BoatAccelerationData[player]
        if clientSpeed and accelData then
                local baseMax = math.abs(accelData.baseMaxSpeed or accelData.maxSpeed or 0)
                local maxAllowed = math.abs(accelData.maxSpeed or baseMax)

                if isSubmarine then
                        local stressMax = math.abs(accelData.currentStressMaxSpeed or accelData.maxSpeed or baseMax)
                        maxAllowed = math.max(baseMax, stressMax)
                        if maxAllowed == 0 then
                                maxAllowed = baseMax
                        end

                        local margin = math.max(baseMax * SUB_CLIENT_SPEED_TOLERANCE, SUB_CLIENT_SPEED_MIN_MARGIN)
                        maxAllowed += margin
                end

                if maxAllowed > 0 and math.abs(clientSpeed) > maxAllowed then
                        -- Track violations
                        PlayerViolations[player] = (PlayerViolations[player] or 0) + 1

                        if PlayerViolations[player] > 50 then
                                warn("Excessive speed violations from", player.Name)
                                player:Kick("Movement security violation")
                        end
                        return
                elseif PlayerViolations[player] then
                        PlayerViolations[player] = math.max(PlayerViolations[player] - 0.25, 0)
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

        local primaryPart = boat.PrimaryPart
        if not primaryPart then
                CleanupBoat(player)
                return
        end

        -- Performance: Check distance to nearest player for physics throttling
        local shouldThrottle = true
        local nearestPlayerDistance = math.huge
        for _, otherPlayer in pairs(Players:GetPlayers()) do
                if otherPlayer.Character and otherPlayer.Character:FindFirstChild("HumanoidRootPart") then
                        local distance = (primaryPart.Position - otherPlayer.Character.HumanoidRootPart.Position).Magnitude
                        if distance < nearestPlayerDistance then
                                nearestPlayerDistance = distance
                        end
                        if distance < PHYSICS_THROTTLE_DISTANCE then
                                shouldThrottle = false
                                if distance <= PASSIVE_WAVE_DISTANCE then
                                        break
                                end
                        end
                end
        end

        local isPlayerNearby = nearestPlayerDistance <= PASSIVE_WAVE_DISTANCE

        -- Skip some physics updates for far boats
        if shouldThrottle and math.random() > 0.3 then
                return
        end

	-- Check activity
	local lastActivity = BoatLastActivity[player] or tick()
	local isIdle = (tick() - lastActivity) > IDLE_THRESHOLD

        local waveBoatType = config.Type == "Submarine" and "Submarine" or "Surface"

        local function syncToBoatWithPassiveWaves()
                local boatCFrame = primaryPart.CFrame
                local targetCFrame = boatCFrame

                if isPlayerNearby then
                        local floatingCFrame, applied = WaterPhysics.ApplyFloatingPhysics(boatCFrame, waveBoatType, deltaTime)
                        if applied then
                                targetCFrame = floatingCFrame
                        end
                end

                if (controlPart.CFrame.Position - boatCFrame.Position).Magnitude > 5 then
                        targetCFrame = boatCFrame
                end

                if config.Type == "Submarine" then
                        targetCFrame = ApplySubmarineStressEffects(player, boat, config, targetCFrame, deltaTime)
                end

                controlPart.CFrame = targetCFrame

                local bodyVel = primaryPart:FindFirstChild("BoatBodyVelocity")
                if bodyVel then
                        bodyVel.Velocity = Vector3.new(0, 0, 0)
                end

                BoatSpeeds[player] = 0
                BoatTurnSpeeds[player] = 0
        end

        if isIdle and not seat.Occupant then
                syncToBoatWithPassiveWaves()
                return
        end

        local isSubmarine = config.Type == "Submarine"
        local stressState
        local integrityRatio = 1
        local stressSpeedMultiplier = 1
        local stressAccelMultiplier = 1

        if isSubmarine then
                stressState = GetOrCreateSubmarineState(player, config)
                integrityRatio, stressSpeedMultiplier, stressAccelMultiplier = UpdateSubmarineStressMetrics(stressState)
        end

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
                syncToBoatWithPassiveWaves()
                return
        end

	-- CALCULATE ACCELERATION
	local currentSpeed = BoatSpeeds[player] or 0
	local currentTurnSpeed = BoatTurnSpeeds[player] or 0

        local baseMaxSpeed = accelData.baseMaxSpeed or accelData.maxSpeed or 0
        local effectiveMaxSpeed = accelData.maxSpeed or baseMaxSpeed
        if isSubmarine then
                effectiveMaxSpeed = baseMaxSpeed * stressSpeedMultiplier
                accelData.maxSpeed = effectiveMaxSpeed
                accelData.currentStressMaxSpeed = effectiveMaxSpeed
        else
                accelData.currentStressMaxSpeed = effectiveMaxSpeed
        end

        local targetSpeed = throttle * effectiveMaxSpeed

        local baseTurnSpeed = config.TurnSpeed or 0
        if isSubmarine then
                baseTurnSpeed = baseTurnSpeed * stressSpeedMultiplier
        end
        local targetTurnSpeed = steer * baseTurnSpeed

        local accelerationRate = accelData.baseAccelerationRate or accelData.accelerationRate
        local decelerationRate = accelData.baseDecelerationRate or accelData.decelerationRate
        local turnAccelerationRate = accelData.baseTurnAccelerationRate or accelData.turnAccelerationRate

        if isSubmarine then
                accelerationRate = accelerationRate * stressAccelMultiplier
                decelerationRate = decelerationRate * math.max(stressAccelMultiplier, 0.5)
                turnAccelerationRate = turnAccelerationRate * math.max(stressAccelMultiplier, 0.6)
        end

        -- Apply acceleration/deceleration
        if math.abs(targetSpeed) > math.abs(currentSpeed) then
                -- Accelerating
                local speedDiff = targetSpeed - currentSpeed
                local speedChange = math.sign(speedDiff) * accelerationRate * deltaTime

                if math.abs(speedChange) > math.abs(speedDiff) then
                        currentSpeed = targetSpeed
                else
                        currentSpeed = currentSpeed + speedChange
                end
        else
                -- Decelerating
                local speedDiff = targetSpeed - currentSpeed
                local speedChange = math.sign(speedDiff) * decelerationRate * deltaTime

                if math.abs(speedChange) > math.abs(speedDiff) then
                        currentSpeed = targetSpeed
                else
                        currentSpeed = currentSpeed + speedChange
                end
        end

        -- Apply turn acceleration
        local turnDiff = targetTurnSpeed - currentTurnSpeed
        local turnChange = math.sign(turnDiff) * turnAccelerationRate * deltaTime

        if math.abs(turnChange) > math.abs(turnDiff) then
                currentTurnSpeed = targetTurnSpeed
        else
                currentTurnSpeed = currentTurnSpeed + turnChange
        end

        if isSubmarine then
                local maxSpeed = effectiveMaxSpeed
                if maxSpeed and maxSpeed > 0 then
                        currentSpeed = math.clamp(currentSpeed, -maxSpeed, maxSpeed)
                end

                local maxTurn = baseTurnSpeed
                if maxTurn ~= 0 then
                        currentTurnSpeed = math.clamp(currentTurnSpeed, -math.abs(maxTurn), math.abs(maxTurn))
                end
        end

        -- Store updated speeds
        BoatSpeeds[player] = currentSpeed
        BoatTurnSpeeds[player] = currentTurnSpeed

        -- CALCULATE MOVEMENT WITH ACTUAL SPEED
	local currentCFrame = controlPart.CFrame
	local newCFrame

        if isSubmarine then
                local throttleInput = 0
                if effectiveMaxSpeed ~= 0 then
                        throttleInput = currentSpeed / effectiveMaxSpeed
                end

                local steerInput = 0
                local turnSpeedValue = baseTurnSpeed ~= 0 and baseTurnSpeed or (config.TurnSpeed or 0)
                if turnSpeedValue ~= 0 then
                        steerInput = currentTurnSpeed / turnSpeedValue
                end

                local controlMultiplier = isSubmarine and math.max(stressAccelMultiplier, SUB_CONTROL_MIN_MULTIPLIER) or 1

                local adjustedInputs = {
                        throttle = throttleInput,
                        steer = steerInput,
                        ascend = ascend * controlMultiplier,
                        pitch = pitch * controlMultiplier,
                        roll = roll * controlMultiplier
                }

                local subConfig = {}
                for k, v in pairs(config) do
                        subConfig[k] = v
                end

                local baseSpeedValue = (subConfig.Speed or subConfig.MaxSpeed or 28)
                local controlSpeedMultiplier = isSubmarine and stressSpeedMultiplier or 1
                local controlTurnMultiplier = isSubmarine and math.max(stressAccelMultiplier, SUB_CONTROL_MIN_MULTIPLIER) or 1

                subConfig.Speed = baseSpeedValue * controlSpeedMultiplier
                subConfig.MaxSpeed = (subConfig.MaxSpeed or baseSpeedValue) * controlSpeedMultiplier
                subConfig.TurnSpeed = (subConfig.TurnSpeed or 1.8) * controlSpeedMultiplier
                subConfig.PitchSpeed = (subConfig.PitchSpeed or 1.5) * controlTurnMultiplier
                subConfig.RollSpeed = (subConfig.RollSpeed or 1.0) * controlTurnMultiplier
                subConfig.VerticalSpeed = (subConfig.VerticalSpeed or 18) * controlMultiplier

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

                newCFrame = ApplySubmarineStressEffects(player, boat, config, newCFrame, deltaTime)
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

        if isSubmarine then
                if ApplySubmarineDepthDamage(player, boat, config, newCFrame.Position, deltaTime) then
                        return
                end
        end

        -- Validate movement
        local securityOptions
        if isSubmarine and stressState then
                local jitterAllowance = stressState.currentJitterAllowance or 0
                if jitterAllowance > 0 then
                        securityOptions = {
                                jitterAllowance = jitterAllowance,
                                shakeDelta = stressState.lastStressOffsetDelta or jitterAllowance,
                        }
                end
        end

        local valid, message, shouldKick = BoatSecurity.ValidateBoatMovement(
                player, boat, newCFrame.Position, deltaTime, securityOptions
        )

        if not valid then
                if message then
                        warn("Rejected boat movement for", player.Name, "-", message)
                end

                PlayerViolations[player] = (PlayerViolations[player] or 0) + 1

                if shouldKick then
                        PlayerViolations[player] = PlayerViolations[player] + 9
                end

                if PlayerViolations[player] > 100 or shouldKick then
                        if shouldKick then
                                player:Kick("Movement security violation")
                        end
                        CleanupBoat(player)
                        return
                end

                local lastValidPosition = BoatSecurity.GetLastValidPosition(player)
                if lastValidPosition then
                        local fallbackCFrame = CFrame.new(lastValidPosition, lastValidPosition + currentCFrame.LookVector)
                        controlPart.CFrame = fallbackCFrame
                else
                        controlPart.CFrame = currentCFrame
                end

                if boat.PrimaryPart then
                        local bodyVel = boat.PrimaryPart:FindFirstChild("BoatBodyVelocity")
                        if bodyVel then
                                bodyVel.Velocity = Vector3.new(0, 0, 0)
                        end
                end

                return
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

