-- WaterPhysics.lua
-- Place in: ReplicatedStorage/Modules/WaterPhysics.lua
-- Handles water simulation, buoyancy, and wave effects

local WaterPhysics = {}

-- Constants
local WATER_LEVEL = 908.935 -- Your water level
local WAVE_AMPLITUDE = 1.5 -- Height of waves
local WAVE_FREQUENCY = 0.5 -- Speed of wave oscillation
local WAVE_LENGTH = 50 -- Distance between wave peaks
local SWAY_AMOUNT = 3 -- Degrees of tilt
local BOB_SPEED = 1.2 -- Speed of bobbing
local BUOYANCY_THRESHOLD = 5 -- Distance from water surface to apply buoyancy
local SPLASH_THRESHOLD = 10 -- Speed threshold for splash effects

-- Different wave patterns for variety
local WavePatterns = {
	Calm = {
		amplitude = 0.5,
		frequency = 0.3,
		swayAmount = 1,
		bobSpeed = 0.8
	},
	Normal = {
		amplitude = 1.5,
		frequency = 0.5,
		swayAmount = 3,
		bobSpeed = 1.2
	},
	Rough = {
		amplitude = 3,
		frequency = 0.7,
		swayAmount = 5,
		bobSpeed = 1.5
	},
	Storm = {
		amplitude = 5,
		frequency = 1,
		swayAmount = 8,
		bobSpeed = 2
	}
}

-- Current water conditions (can be changed dynamically)
local currentConditions = "Normal"

-- Get current wave pattern
function WaterPhysics.GetCurrentConditions()
	return WavePatterns[currentConditions] or WavePatterns.Normal
end

-- Set water conditions (for weather system later)
function WaterPhysics.SetConditions(conditionName)
	if WavePatterns[conditionName] then
		currentConditions = conditionName
	end
end

-- Calculate wave height at a specific position
function WaterPhysics.GetWaveHeight(x, z, time)
	local conditions = WaterPhysics.GetCurrentConditions()

	-- Create complex wave pattern using multiple sine waves
	local wave1 = math.sin((x / WAVE_LENGTH) + (time * conditions.frequency)) * conditions.amplitude
	local wave2 = math.sin((z / WAVE_LENGTH) + (time * conditions.frequency * 0.8)) * conditions.amplitude * 0.5
	local wave3 = math.sin(((x + z) / (WAVE_LENGTH * 1.5)) + (time * conditions.frequency * 1.2)) * conditions.amplitude * 0.3

	return wave1 + wave2 + wave3
end

-- Calculate buoyancy force based on depth
function WaterPhysics.GetBuoyancyForce(position)
	local depth = WATER_LEVEL - position.Y

	if depth > BUOYANCY_THRESHOLD then
		-- Fully submerged, no buoyancy needed (submarine mode)
		return 0
	elseif depth > -BUOYANCY_THRESHOLD then
		-- Near surface, apply buoyancy
		-- Stronger force the deeper underwater
		local buoyancyStrength = math.clamp(depth / BUOYANCY_THRESHOLD, -1, 1)
		return buoyancyStrength * 50 -- Adjust multiplier as needed
	else
		-- Above water, apply gravity
		return -20
	end
end

-- Calculate boat orientation based on waves (pitch and roll)
function WaterPhysics.GetWaveOrientation(position, time, heading)
	local conditions = WaterPhysics.GetCurrentConditions()

	-- Sample wave heights around the boat to determine tilt
	local sampleDistance = 10
	local frontHeight = WaterPhysics.GetWaveHeight(
		position.X + math.sin(heading) * sampleDistance,
		position.Z + math.cos(heading) * sampleDistance,
		time
	)
	local backHeight = WaterPhysics.GetWaveHeight(
		position.X - math.sin(heading) * sampleDistance,
		position.Z - math.cos(heading) * sampleDistance,
		time
	)
	local leftHeight = WaterPhysics.GetWaveHeight(
		position.X + math.cos(heading) * sampleDistance,
		position.Z - math.sin(heading) * sampleDistance,
		time
	)
	local rightHeight = WaterPhysics.GetWaveHeight(
		position.X - math.cos(heading) * sampleDistance,
		position.Z + math.sin(heading) * sampleDistance,
		time
	)

	-- Calculate pitch (front/back tilt)
	local pitch = math.atan2(frontHeight - backHeight, sampleDistance * 2)
	pitch = pitch * (conditions.swayAmount / 3)

	-- Calculate roll (left/right tilt)
	local roll = math.atan2(rightHeight - leftHeight, sampleDistance * 2)
	roll = roll * (conditions.swayAmount / 3)

	-- Add some random sway for realism
	local randomSway = math.sin(time * conditions.bobSpeed * 2.1) * math.rad(conditions.swayAmount * 0.3)
	roll = roll + randomSway

	return pitch, roll
end

-- Apply floating physics to a boat/submarine
function WaterPhysics.ApplyFloatingPhysics(currentCFrame, boatType, deltaTime)
	local position = currentCFrame.Position
	local time = tick()

	-- Get depth from surface
	local depth = WATER_LEVEL - position.Y

	-- Check if boat should float
	local shouldFloat = false
	local targetY = position.Y

	if boatType == "Surface" then
		-- Surface boats always float
		shouldFloat = true
		local waveHeight = WaterPhysics.GetWaveHeight(position.X, position.Z, time)
		targetY = WATER_LEVEL + waveHeight + 2 -- 2 studs above water

	elseif boatType == "Submarine" then
		-- Submarines only float when VERY close to surface
		-- Reduced threshold from 2 to 0.5 for tighter surface detection
		if depth < 0.5 and depth > -0.5 then
			shouldFloat = true
			local waveHeight = WaterPhysics.GetWaveHeight(position.X, position.Z, time)
			targetY = WATER_LEVEL + waveHeight - 1 -- Slightly submerged
		else
			-- Submarine is properly underwater or above water - no floating physics
			return currentCFrame, false
		end
	end

	if shouldFloat then
		-- Apply buoyancy (smooth vertical movement)
		local yDifference = targetY - position.Y
		-- Reduced buoyancy strength for submarines to make diving easier
		local buoyancyMultiplier = boatType == "Submarine" and 2 or 5
		local buoyancySpeed = math.clamp(yDifference * buoyancyMultiplier, -10, 10)
		local newY = position.Y + (buoyancySpeed * deltaTime)

		-- Get wave-based orientation
		local _, currentYaw = currentCFrame:ToEulerAnglesYXZ()
		local pitch, roll = WaterPhysics.GetWaveOrientation(position, time, currentYaw)

		-- Apply wave tilting (reduced for submarines)
		if boatType == "Submarine" then
			pitch = pitch * 0.3 -- Less pitch effect on submarines
			roll = roll * 0.3   -- Less roll effect on submarines
		end

		local newCFrame = CFrame.new(position.X, newY, position.Z)
			* CFrame.Angles(0, currentYaw, 0)  -- Maintain heading
			* CFrame.Angles(pitch, 0, roll)    -- Apply wave tilt

		return newCFrame, true
	end

	return currentCFrame, false
end

-- Create splash effect (for later implementation)
function WaterPhysics.CreateSplash(position, velocity)
	-- This would create particle effects
	-- For now, just a placeholder
	if velocity.Magnitude > SPLASH_THRESHOLD then
		-- Create splash particles at position
	end
end

-- Check if position is underwater
function WaterPhysics.IsUnderwater(position)
	return position.Y < WATER_LEVEL
end

-- Get water pressure at depth (for submarine damage)
function WaterPhysics.GetPressure(position)
	local depth = math.max(0, WATER_LEVEL - position.Y)
	-- Pressure increases with depth
	return depth / 100 -- Simple linear pressure
end

-- Simulate underwater drag
function WaterPhysics.GetWaterDrag(velocity, isSubmerged)
	if not isSubmerged then
		return velocity -- No drag above water
	end

	-- Apply drag force opposite to velocity
	local dragCoefficient = 0.95 -- How much velocity is retained per frame
	return velocity * dragCoefficient
end

-- Get visibility at depth (for fog effects)
function WaterPhysics.GetVisibilityAtDepth(position)
	local depth = math.max(0, WATER_LEVEL - position.Y)

	if depth <= 0 then
		return 1 -- Full visibility above water
	elseif depth < 50 then
		return 1 - (depth / 100) -- Gradually decrease
	elseif depth < 200 then
		return 0.5 - ((depth - 50) / 300)
	else
		return 0.1 -- Very dark at deep depths
	end
end

return WaterPhysics