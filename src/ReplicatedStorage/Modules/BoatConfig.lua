-- BoatConfig.lua (ENHANCED WITH WEIGHT & ACCELERATION)
-- Place in: ReplicatedStorage/Modules/BoatConfig.lua
-- Now includes weight-based acceleration physics

local BoatConfig = {}

-- Boat type definitions with weight and acceleration
BoatConfig.Boats = {
	StarterRaft = {
		DisplayName = "Wooden Raft",
		Model = "StarterRaft",
		Type = "Surface",

		-- Movement stats - ENHANCED
		Speed = 25,               -- Add for compatibility
		MaxSpeed = 25,            -- Maximum achievable speed
		TurnSpeed = 2.0,      
		BaseAcceleration = 12,    -- Base acceleration rate
		BaseDeceleration = 8,     -- Base deceleration rate
		Weight = 3,               -- Weight (0-10, affects acceleration)
		Acceleration = 12,        -- Add for compatibility

		-- Storage and capabilities
		MaxStorage = 10,
		DrillPower = 1,
		DrillSpeed = 1,

		-- Costs
		Cost = 0,
		RequiredLevel = 1,

		-- Physics settings
		AlignPosition = {
			MaxForce = 500000,
			MaxVelocity = 30,
			Responsiveness = 40,
		},
		AlignOrientation = {
			MaxTorque = 400000,
			MaxAngularVelocity = 12,
			Responsiveness = 35,
		},

		-- Health
		MaxHealth = 100,
		RepairCost = 10,
	},

	TestSubmarine = {
		DisplayName = "Test Submarine",
		Model = "TestSubmarine",
		Type = "Submarine",

		-- Movement stats - ENHANCED
		Speed = 28,              -- Add Speed for compatibility
		MaxSpeed = 28,
		TurnSpeed = 1.8,
		PitchSpeed = 1.5,
		RollSpeed = 1.2,
		VerticalSpeed = 18,
		BaseAcceleration = 10,
		BaseDeceleration = 6,
		Weight = 6,              -- Heavier than raft
		Acceleration = 10,       -- Add for compatibility

		-- Submarine-specific settings
		MaxDepth = 500,
		MinDepth = -5,
		SurfaceHeight = 3,
		CanInvert = true,

		-- Collision settings
		PhaseThrough = {"WATERTOP"},

		-- Storage and capabilities
		MaxStorage = 50,
		DrillPower = 3,
		DrillSpeed = 2,

		-- Costs
		Cost = 1000,
		RequiredLevel = 5,

		-- Physics settings
		AlignPosition = {
			MaxForce = 1500000,
			MaxVelocity = 35,
			Responsiveness = 80,
		},
		AlignOrientation = {
			MaxTorque = 1000000,
			MaxAngularVelocity = 10,
			Responsiveness = 30,
		},

		-- Health
		MaxHealth = 200,
		RepairCost = 25,
	},

	ImprovedRaft = {
		DisplayName = "Reinforced Raft",
		Model = "ImprovedRaft",
		Type = "Surface",

		-- Movement stats
		MaxSpeed = 32,
		TurnSpeed = 2.5,
		BaseAcceleration = 15,
		BaseDeceleration = 10,
		Weight = 4,              -- Slightly heavier than starter

		-- Storage and capabilities
		MaxStorage = 25,
		DrillPower = 2,
		DrillSpeed = 1.5,

		-- Costs
		Cost = 500,
		RequiredLevel = 5,

		-- Physics settings
		AlignPosition = {
			MaxForce = 750000,
			MaxVelocity = 35,
			Responsiveness = 50,
		},
		AlignOrientation = {
			MaxTorque = 600000,
			MaxAngularVelocity = 15,
			Responsiveness = 40,
		},

		MaxHealth = 150,
		RepairCost = 15,
	},

	SpeedBoat = {
		DisplayName = "Speed Boat",
		Model = "SpeedBoat",
		Type = "Surface",

		-- Fast movement but light weight
		MaxSpeed = 45,
		TurnSpeed = 3.0,
		BaseAcceleration = 20,
		BaseDeceleration = 12,
		Weight = 2,              -- Very light for quick acceleration

		-- Lower storage, built for speed
		MaxStorage = 15,
		DrillPower = 2,
		DrillSpeed = 1.2,

		-- Expensive
		Cost = 2500,
		RequiredLevel = 10,

		-- Very responsive physics
		AlignPosition = {
			MaxForce = 1000000,
			MaxVelocity = 50,
			Responsiveness = 60,
		},
		AlignOrientation = {
			MaxTorque = 800000,
			MaxAngularVelocity = 18,
			Responsiveness = 45,
		},

		MaxHealth = 120,
		RepairCost = 30,
	},

	HeavySubmarine = {
		DisplayName = "Deep Diver",
		Model = "HeavySubmarine",
		Type = "Submarine",

		-- Slower but can go deeper
		MaxSpeed = 22,
		TurnSpeed = 1.4,
		PitchSpeed = 1.2,
		RollSpeed = 1.0,
		VerticalSpeed = 15,
		BaseAcceleration = 8,
		BaseDeceleration = 5,
		Weight = 9,              -- Very heavy, slow acceleration

		-- Can go very deep
		MaxDepth = 1000,
		MinDepth = -5,
		SurfaceHeight = 4,
		CanInvert = true,

		PhaseThrough = {"WATERTOP"},

		-- High storage
		MaxStorage = 100,
		DrillPower = 5,
		DrillSpeed = 3,

		Cost = 5000,
		RequiredLevel = 15,

		-- Heavy but stable physics
		AlignPosition = {
			MaxForce = 2000000,
			MaxVelocity = 30,
			Responsiveness = 60,
		},
		AlignOrientation = {
			MaxTorque = 1500000,
			MaxAngularVelocity = 8,
			Responsiveness = 25,
		},

		MaxHealth = 500,
		RepairCost = 50,
	},

	CargoVessel = {
		DisplayName = "Cargo Vessel",
		Model = "CargoVessel",
		Type = "Surface",

		-- Slow but massive storage
		MaxSpeed = 20,
		TurnSpeed = 1.5,
		BaseAcceleration = 6,
		BaseDeceleration = 4,
		Weight = 10,             -- Maximum weight, very slow acceleration

		-- Massive storage capacity
		MaxStorage = 200,
		DrillPower = 4,
		DrillSpeed = 2,

		Cost = 8000,
		RequiredLevel = 20,

		-- Powerful but slow physics
		AlignPosition = {
			MaxForce = 2500000,
			MaxVelocity = 25,
			Responsiveness = 30,
		},
		AlignOrientation = {
			MaxTorque = 2000000,
			MaxAngularVelocity = 6,
			Responsiveness = 20,
		},

		MaxHealth = 800,
		RepairCost = 75,
	},
}

-- Calculate actual acceleration based on weight
function BoatConfig.GetAcceleration(boatType)
	local config = BoatConfig.Boats[boatType]
	if not config then return 8 end

	-- Weight affects acceleration: 0 = 150% speed, 10 = 50% speed
	local weightFactor = 1.5 - (config.Weight / 10)
	return config.BaseAcceleration * weightFactor
end

-- Calculate actual deceleration based on weight
function BoatConfig.GetDeceleration(boatType)
	local config = BoatConfig.Boats[boatType]
	if not config then return 6 end

	-- Weight affects deceleration: heavier boats take longer to stop
	local weightFactor = 1.5 - (config.Weight / 10)
	return config.BaseDeceleration * weightFactor
end

-- Get time to reach max speed
function BoatConfig.GetTimeToMaxSpeed(boatType)
	local config = BoatConfig.Boats[boatType]
	if not config then return 3 end

	local acceleration = BoatConfig.GetAcceleration(boatType)
	return config.MaxSpeed / acceleration
end

-- Helper functions
function BoatConfig.GetBoatData(boatType)
	return BoatConfig.Boats[boatType]
end

function BoatConfig.CanAfford(player, boatType)
	local config = BoatConfig.Boats[boatType]
	if not config then return false end

	-- TODO: Implement when currency system is added
	-- local playerCoins = PlayerDataManager.GetCoins(player)
	-- return playerCoins >= config.Cost

	return true -- For testing
end

-- Get all boats player can access at their level
function BoatConfig.GetAvailableBoats(playerLevel)
	playerLevel = playerLevel or 1
	local available = {}

	for boatType, config in pairs(BoatConfig.Boats) do
		if config.RequiredLevel <= playerLevel then
			table.insert(available, {
				type = boatType,
				config = config
			})
		end
	end

	-- Sort by cost
	table.sort(available, function(a, b)
		return a.config.Cost < b.config.Cost
	end)

	return available
end

-- Get upgrade path for a boat
function BoatConfig.GetUpgradeOptions(currentBoatType)
	local currentConfig = BoatConfig.Boats[currentBoatType]
	if not currentConfig then return {} end

	local upgrades = {}
	for boatType, config in pairs(BoatConfig.Boats) do
		-- Find boats that are better but same type
		if config.Type == currentConfig.Type and 
			config.Cost > currentConfig.Cost then
			table.insert(upgrades, {
				type = boatType,
				config = config,
				costDifference = config.Cost - currentConfig.Cost
			})
		end
	end

	-- Sort by cost difference
	table.sort(upgrades, function(a, b)
		return a.costDifference < b.costDifference
	end)

	return upgrades
end

return BoatConfig