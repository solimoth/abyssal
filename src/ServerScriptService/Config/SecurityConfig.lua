-- SecurityConfig.lua
-- Place in: ServerScriptService/Config/SecurityConfig.lua
-- Central configuration for all security settings

local SecurityConfig = {}

-- =====================================
-- BOAT SYSTEM SECURITY
-- =====================================
SecurityConfig.Boats = {
	-- Spawning limits
	MIN_SPAWN_COOLDOWN = 5,        -- Seconds between boat spawns
	MAX_BOATS_PER_SERVER = 50,     -- Maximum boats in one server
	MAX_BOATS_PER_PLAYER = 1,      -- Maximum boats per player

	-- Movement validation
	MAX_BOAT_SPEED = 50,            -- Maximum studs/second
	MAX_TELEPORT_DISTANCE = 100,   -- Max distance in one frame
	SPEED_HACK_TOLERANCE = 1.5,    -- 50% tolerance for lag

	-- Position boundaries
	MAX_DISTANCE_FROM_SPAWN = 2000, -- Maximum distance from any spawn point
	WATER_LEVEL_TOLERANCE = 10,    -- How far from water level is allowed

	-- Physics limits
	MAX_ALIGN_FORCE = 200000,      -- Maximum AlignPosition force
	MAX_ALIGN_VELOCITY = 50,       -- Maximum AlignPosition velocity
	MAX_ALIGN_TORQUE = 200000,     -- Maximum AlignOrientation torque
	MAX_ANGULAR_VELOCITY = 20,     -- Maximum rotation speed
}

-- =====================================
-- PLAYER SECURITY
-- =====================================
SecurityConfig.Players = {
	-- Movement limits
	MAX_WALK_SPEED = 16,           -- Default Roblox walk speed
	MAX_JUMP_POWER = 50,           -- Default Roblox jump power
	MAX_HEALTH = 100,              -- Maximum player health

	-- Teleportation detection
	MAX_TELEPORT_SPEED = 100,      -- Studs/second before considered teleporting
	TELEPORT_RUBBERBAND = true,    -- Teleport player back if detected

	-- Character modifications
	ALLOW_FLY_DETECTION = true,    -- Detect and prevent flying
	ALLOW_NOCLIP_DETECTION = true, -- Detect and prevent noclip
}

-- =====================================
-- REMOTE EVENT SECURITY
-- =====================================
SecurityConfig.Remotes = {
	-- Rate limiting (calls per second)
	SPAWN_BOAT_RATE = 1,           -- Max spawn boat calls/sec
	DESPAWN_BOAT_RATE = 1,         -- Max despawn boat calls/sec
	UPDATE_CONTROL_RATE = 60,      -- Max control update calls/sec
	DEFAULT_RATE_LIMIT = 10,       -- Default for unnamed remotes

	-- Timeout settings
	REMOTE_TIMEOUT = 5,            -- Seconds before remote call times out
	MAX_PENDING_CALLS = 10,        -- Max pending remote calls per player
}

-- =====================================
-- ANTI-EXPLOIT ACTIONS
-- =====================================
SecurityConfig.Punishments = {
	-- Warning thresholds before action
	SPEED_HACK_WARNINGS = 5,       -- Warnings before kick for speed hacking
	TELEPORT_WARNINGS = 3,         -- Warnings before kick for teleporting
	EXPLOIT_WARNINGS = 3,          -- General exploit warnings before kick

	-- Kick messages
	KICK_MESSAGES = {
		SPEED_HACK = "Speed hacking detected",
		TELEPORT = "Teleportation detected",
		EXPLOIT = "Exploiting detected",
		SPAM = "Spamming detected",
		TAMPERING = "Game tampering detected",
	},

	-- Ban settings (if you implement banning)
	ENABLE_BANS = false,           -- Enable permanent bans
	BAN_AFTER_KICKS = 3,          -- Kicks before permanent ban
}

-- =====================================
-- PERFORMANCE & MEMORY
-- =====================================
SecurityConfig.Performance = {
	-- Memory limits
	MEMORY_WARNING_MB = 500,       -- Warn at this memory usage
	MEMORY_CRITICAL_MB = 750,      -- Take action at this memory usage

	-- Part limits
	MAX_PARTS_PER_PLAYER = 500,    -- Maximum parts owned by one player
	MAX_TOTAL_PARTS = 10000,       -- Maximum parts in workspace

	-- Cleanup intervals
	ORPHAN_CLEANUP_INTERVAL = 30,  -- Seconds between orphan boat checks
	MEMORY_CHECK_INTERVAL = 30,    -- Seconds between memory checks

	-- Physics
	MIN_PHYSICS_FPS = 30,          -- Minimum acceptable physics FPS
	PHYSICS_THROTTLE_ACTION = "warn", -- "warn", "kick", or "none"
}

-- =====================================
-- LOGGING & MONITORING
-- =====================================
SecurityConfig.Logging = {
	-- What to log
	LOG_EXPLOITS = true,           -- Log exploit attempts
	LOG_KICKS = true,              -- Log when players are kicked
	LOG_WARNINGS = true,           -- Log warnings
	LOG_BOAT_SPAWNS = false,       -- Log every boat spawn
	LOG_BOAT_DESPAWNS = false,     -- Log every boat despawn

	-- Where to log (implement these separately)
	USE_DATASTORE = false,         -- Save logs to DataStore
	USE_WEBHOOK = false,           -- Send to Discord/Slack webhook
	USE_CONSOLE = true,            -- Print to console

	-- Log retention
	KEEP_LOGS_DAYS = 7,           -- How long to keep logs
}

-- =====================================
-- VALIDATION FUNCTIONS
-- =====================================

-- Validate a configuration value is within bounds
function SecurityConfig.ValidateValue(value, min, max, name)
	if value < min or value > max then
		warn(string.format("Security Config: %s value %d outside bounds [%d, %d]", 
			name, value, min, max))
		return math.clamp(value, min, max)
	end
	return value
end

-- Get a config value with fallback
function SecurityConfig.GetValue(category, key, default)
	if SecurityConfig[category] and SecurityConfig[category][key] ~= nil then
		return SecurityConfig[category][key]
	end
	return default
end

-- Initialize and validate all settings
function SecurityConfig.Initialize()
	-- Validate boat settings
	SecurityConfig.Boats.MAX_BOAT_SPEED = SecurityConfig.ValidateValue(
		SecurityConfig.Boats.MAX_BOAT_SPEED, 10, 200, "MAX_BOAT_SPEED"
	)

	-- Validate player settings
	SecurityConfig.Players.MAX_WALK_SPEED = SecurityConfig.ValidateValue(
		SecurityConfig.Players.MAX_WALK_SPEED, 16, 50, "MAX_WALK_SPEED"
	)

	print("Security Configuration initialized")
	print("Anti-exploit systems: ACTIVE")
	print("Memory monitoring: ACTIVE")
	print("Rate limiting: ACTIVE")
end

-- Initialize on require
SecurityConfig.Initialize()

return SecurityConfig