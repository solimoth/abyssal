-- BoatSecurity.lua (ENHANCED - Proper anti-exploit system)
-- Place in: ReplicatedStorage/Modules/BoatSecurity.lua

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BoatSecurity = {}

-- Security constants
local MAX_BOATS_PER_SERVER = 50
local MAX_SPEED_TOLERANCE = 2.05 -- Only 5% tolerance
local MAX_TELEPORT_DISTANCE = 50 -- Max distance boat can move in one frame
local RATE_LIMIT_WINDOW = 1 -- Time window in seconds
local MAX_POSITION_HISTORY = 10

-- Player data storage
local PlayerData = {}
local RemoteRateLimits = {}
local BoatPositionHistory = {}
local LastValidPositions = {}

-- Initialize player data
local function InitializePlayer(player)
	if not PlayerData[player] then
		PlayerData[player] = {
			spawnCount = 0,
			lastSpawnTime = 0,
			violations = 0,
			lastViolationTime = 0,
			boatSpawnedAt = 0
		}
	end

	if not RemoteRateLimits[player] then
		RemoteRateLimits[player] = {}
	end

	if not BoatPositionHistory[player] then
		BoatPositionHistory[player] = {}
	end
end

-- Clean up player data
function BoatSecurity.CleanupPlayer(player)
	PlayerData[player] = nil
	RemoteRateLimits[player] = nil
	BoatPositionHistory[player] = nil
	LastValidPositions[player] = nil
end

-- Check if player can spawn a boat
function BoatSecurity.CanSpawnBoat(player)
	InitializePlayer(player)

	local data = PlayerData[player]
	local currentTime = tick()

	-- Check if player just spawned a boat
	if currentTime - data.lastSpawnTime < 3 then
		return false, "Please wait before spawning another boat"
	end

	-- Check spawn rate (max 10 boats per minute)
	if data.spawnCount > 10 and currentTime - data.boatSpawnedAt < 60 then
		return false, "Spawning boats too quickly"
	end

	-- Reset counter after a minute
	if currentTime - data.boatSpawnedAt > 60 then
		data.spawnCount = 0
		data.boatSpawnedAt = currentTime
	end

	data.spawnCount = data.spawnCount + 1
	data.lastSpawnTime = currentTime

	return true
end

-- Check if server can handle more boats
function BoatSecurity.CanServerHandleMoreBoats()
	local boatCount = 0

	for _, obj in pairs(workspace:GetChildren()) do
		if obj:GetAttribute("OwnerId") and obj:IsA("Model") then
			boatCount = boatCount + 1
		end
	end

	if boatCount >= MAX_BOATS_PER_SERVER then
		return false, "Server boat limit reached"
	end

	return true
end

-- Validate boat configuration
function BoatSecurity.ValidateBoatConfig(boatType, config)
	if not config then
		return false, "Invalid boat configuration"
	end

	-- Check for suspicious values
	local maxSpeed = config.MaxSpeed or config.Speed or 0
	if maxSpeed > 200 then -- No boat should go this fast
		return false, "Invalid boat speed"
	end

	if config.Weight and (config.Weight < 0 or config.Weight > 10) then
		return false, "Invalid boat weight"
	end

	return true
end

-- Enhanced remote rate limiting
function BoatSecurity.CheckRemoteRateLimit(player, remoteName, maxCallsPerSecond)
	InitializePlayer(player)

	local currentTime = tick()
	local limits = RemoteRateLimits[player]

	if not limits[remoteName] then
		limits[remoteName] = {
			calls = {},
			violations = 0
		}
	end

	local remoteData = limits[remoteName]

	-- Clean old calls
	local validCalls = {}
	for _, callTime in ipairs(remoteData.calls) do
		if currentTime - callTime < RATE_LIMIT_WINDOW then
			table.insert(validCalls, callTime)
		end
	end
	remoteData.calls = validCalls

	-- Check rate
	if #remoteData.calls >= maxCallsPerSecond then
		remoteData.violations = remoteData.violations + 1

		if remoteData.violations > 10 then
			warn("Player", player.Name, "exceeded rate limit for", remoteName)

			-- Kick for excessive violations
			if remoteData.violations > 50 then
				player:Kick("Rate limit violation")
			end
		end

		return false
	end

	-- Add current call
	table.insert(remoteData.calls, currentTime)
	return true
end

-- Validate boat ownership
function BoatSecurity.ValidateOwnership(player, boat)
	if not boat then return false end

	local ownerId = boat:GetAttribute("OwnerId")
	if not ownerId then return false end

	return tostring(player.UserId) == ownerId
end

-- Validate input values
function BoatSecurity.ValidateInput(throttle, steer)
	-- Check types
	if type(throttle) ~= "number" or type(steer) ~= "number" then
		return false
	end

	-- Check ranges
	if math.abs(throttle) > 1.01 or math.abs(steer) > 1.01 then
		return false
	end

	-- Check for NaN
	if throttle ~= throttle or steer ~= steer then
		return false
	end

	return true
end

-- Enhanced boat movement validation
function BoatSecurity.ValidateBoatMovement(player, boat, newPosition, deltaTime)
	InitializePlayer(player)

	if not boat or not boat.PrimaryPart then
		return false, "Invalid boat", false
	end

	-- Check for NaN or infinite values
	if newPosition.X ~= newPosition.X or
		newPosition.Y ~= newPosition.Y or
		newPosition.Z ~= newPosition.Z or
		math.abs(newPosition.X) == math.huge or
		math.abs(newPosition.Y) == math.huge or
		math.abs(newPosition.Z) == math.huge then
		return false, "Invalid position", true
	end

	-- Boats are physically moved by AlignPosition constraints which can lag
	-- slightly behind the server controlled "target" position. When checking
	-- for suspicious movement we therefore compare against the last validated
	-- target position if we have one instead of the boat's physical location.
	local referencePosition = LastValidPositions[player] or boat.PrimaryPart.Position
	local distance = (newPosition - referencePosition).Magnitude

	-- Store position history
	local history = BoatPositionHistory[player]
	table.insert(history, {
		position = newPosition,
		time = tick(),
		distance = distance
	})

	-- Keep only recent history
	if #history > MAX_POSITION_HISTORY then
		table.remove(history, 1)
	end

	-- Check for teleporting
	local maxAllowedDistance = MAX_TELEPORT_DISTANCE * math.max(deltaTime, 0.03)
	if distance > maxAllowedDistance then
		PlayerData[player].violations = PlayerData[player].violations + 1

		-- Use last valid position if available
		if LastValidPositions[player] then
			return false, "Teleport detected", PlayerData[player].violations > 10
		end

		return false, "Teleport detected", false
	end

	-- Check speed over time
	if #history >= 3 then
		local totalDistance = 0
		local totalTime = 0

		for i = 2, #history do
			totalDistance = totalDistance + history[i].distance
			totalTime = totalTime + (history[i].time - history[i-1].time)
		end

		if totalTime > 0 then
			local averageSpeed = totalDistance / totalTime
			local config = require(game.ReplicatedStorage.Modules.BoatConfig).GetBoatData(boat:GetAttribute("BoatType"))

			if config then
				local maxSpeed = (config.MaxSpeed or config.Speed or 30) * MAX_SPEED_TOLERANCE

				if averageSpeed > maxSpeed then
					PlayerData[player].violations = PlayerData[player].violations + 1

					if PlayerData[player].violations > 20 then
						return false, "Speed violation", true
					end

					return false, "Speed warning", false
				end
			end
		end
	end

	-- Store last valid position
	LastValidPositions[player] = newPosition

	-- Clear violations if player has been good for a while
	if tick() - PlayerData[player].lastViolationTime > 30 then
		PlayerData[player].violations = math.max(0, PlayerData[player].violations - 1)
	end

	return true, "Valid", false
end

-- Check for suspicious boat modifications
function BoatSecurity.ValidateBoatIntegrity(boat)
	if not boat or not boat.PrimaryPart then
		return false
	end

	-- Check part count
	local partCount = 0
	for _, desc in pairs(boat:GetDescendants()) do
		if desc:IsA("BasePart") then
			partCount = partCount + 1
		end
	end

	local originalCount = boat:GetAttribute("OriginalPartCount")
	if originalCount and partCount > originalCount * 1.5 then
		return false
	end

	-- Check for suspicious properties
	local primaryPart = boat.PrimaryPart
	if primaryPart.Massless and boat:GetAttribute("BoatType") then
		local config = require(game.ReplicatedStorage.Modules.BoatConfig).GetBoatData(boat:GetAttribute("BoatType"))
		if config and config.Type ~= "Submarine" then
			-- Surface boats shouldn't have massless primary parts
			return false
		end
	end

	return true
end

-- Monitor player behavior patterns
function BoatSecurity.MonitorPlayer(player)
	InitializePlayer(player)

	local data = PlayerData[player]

	-- Check for suspicious patterns
	if data.violations > 50 then
		return false, "Too many violations"
	end

	return true
end

-- Get security statistics for debugging
function BoatSecurity.GetPlayerStats(player)
	InitializePlayer(player)

	return {
		violations = PlayerData[player].violations,
		spawnCount = PlayerData[player].spawnCount,
		lastSpawnTime = PlayerData[player].lastSpawnTime
	}
end

return BoatSecurity