local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("WaterPhysics"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local vfxRemotes = remotesFolder:WaitForChild("VFXSystem")
local boatSplashEvent = vfxRemotes:WaitForChild("BoatSplash")

local BoatSplashService = {}

local boatStates = setmetatable({}, { __mode = "k" })

local ENTRY_HEIGHT_THRESHOLD = 0.85
local EXIT_HEIGHT_THRESHOLD = 0.2
local MIN_DOWNWARD_SPEED = 8
local HORIZONTAL_WEIGHT = 0.35
local MAX_VERTICAL_SPEED = 60
local MAX_HORIZONTAL_REFERENCE = 50
local SPLASH_COOLDOWN = 0.9
local MAX_VISIBILITY_DISTANCE = 250

local ZERO_VECTOR = Vector3.new()

local function getBoatState(boat)
	local state = boatStates[boat]
	if not state then
		state = {
			lastHeight = nil,
			lastSplashTime = 0,
		}
		boatStates[boat] = state
	end

	return state
end

local function computeIntensity(downwardSpeed, horizontalSpeed)
	downwardSpeed = math.max(downwardSpeed, 0)
	horizontalSpeed = math.max(horizontalSpeed, 0)

	local combined = downwardSpeed + (horizontalSpeed * HORIZONTAL_WEIGHT)
	local maxCombined = MAX_VERTICAL_SPEED + (MAX_HORIZONTAL_REFERENCE * HORIZONTAL_WEIGHT)

	if maxCombined <= 0 then
		return 0
	end

	local normalized = (combined - MIN_DOWNWARD_SPEED) / (maxCombined - MIN_DOWNWARD_SPEED)
	return math.clamp(normalized, 0, 1)
end

function BoatSplashService.ProcessBoat(player, boat, primaryPart, waterSurfaceOffset)
	if not boat or not primaryPart or not primaryPart.Parent then
		return
	end

	local success, waterLevel = pcall(WaterPhysics.GetWaterLevel, primaryPart.Position)
	if not success or typeof(waterLevel) ~= "number" then
		return
	end

	local state = getBoatState(boat)
	local offset = typeof(waterSurfaceOffset) == "number" and waterSurfaceOffset or 0
	local boatSurfaceY = primaryPart.Position.Y + offset
	local heightDelta = boatSurfaceY - waterLevel

	local velocity = primaryPart.AssemblyLinearVelocity or primaryPart.Velocity or ZERO_VECTOR
	local downwardSpeed = math.max(0, -velocity.Y)
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	if state.lastHeight ~= nil then
		local wasAbove = state.lastHeight > ENTRY_HEIGHT_THRESHOLD
		local nowBelow = heightDelta <= EXIT_HEIGHT_THRESHOLD

		if wasAbove and nowBelow and downwardSpeed > MIN_DOWNWARD_SPEED then
			local now = tick()
			if now - state.lastSplashTime >= SPLASH_COOLDOWN then
				local intensity = computeIntensity(downwardSpeed, horizontalSpeed)
				if intensity > 0 then
					BoatSplashService._dispatchSplash(
						Vector3.new(primaryPart.Position.X, waterLevel, primaryPart.Position.Z),
						intensity,
						player
					)
					state.lastSplashTime = now
				end
			end
		end
	end

	state.lastHeight = heightDelta
end

function BoatSplashService._dispatchSplash(position, intensity, owner)
	intensity = math.clamp(intensity, 0, 1)

	local recipients = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local distance = (hrp.Position - position).Magnitude
			if distance <= MAX_VISIBILITY_DISTANCE then
				table.insert(recipients, player)
			end
		end
	end

	if owner and owner.Parent and not table.find(recipients, owner) then
		table.insert(recipients, owner)
	end

	for _, player in ipairs(recipients) do
		boatSplashEvent:FireClient(player, position, intensity)
	end
end

function BoatSplashService.ClearBoat(boat)
	if boat then
		boatStates[boat] = nil
	end
end

return BoatSplashService
