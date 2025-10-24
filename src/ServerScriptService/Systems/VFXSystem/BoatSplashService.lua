local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("WaterPhysics"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local vfxRemotes = remotesFolder:WaitForChild("VFXSystem")
local boatSplashEvent = vfxRemotes:WaitForChild("BoatSplash")

local BoatSplashService = {}

local boatStates = setmetatable({}, { __mode = "k" })

local DEFAULT_ENTRY_HEIGHT = 0.5
local DEFAULT_EXIT_HEIGHT = 0.1
local DEFAULT_MIN_DROP = 0.3
local DEFAULT_MIN_DOWNWARD_SPEED = 6
local HORIZONTAL_WEIGHT = 0.35
local MAX_VERTICAL_SPEED = 60
local MAX_HORIZONTAL_REFERENCE = 50
local SPLASH_COOLDOWN = 0.9
local MAX_VISIBILITY_DISTANCE = 250

local ZERO_VECTOR = Vector3.new()
local WATER_SURFACE_OFFSET_ATTRIBUTE = "WaterSurfaceOffset"

local SAMPLE_POINTS = {
        {
                key = "Primary",
                entryHeight = 0.5,
                exitHeight = 0.1,
                minDrop = 0.35,
                minDownwardSpeed = 5,
                cooldown = 0.75,
                intensityMultiplier = 1,
                getPart = function(boat)
                        return boat.PrimaryPart
                end,
        },
        {
                key = "BoatFront",
                partName = "BoatFront",
                entryHeight = 0.4,
                exitHeight = 0,
                minDrop = 0.25,
                minDownwardSpeed = 3,
                cooldown = 0.6,
                intensityMultiplier = 1.1,
        },
        {
                key = "BoatBack",
                partName = "BoatBack",
                entryHeight = 0.4,
                exitHeight = 0,
                minDrop = 0.25,
                minDownwardSpeed = 3,
                cooldown = 0.6,
                intensityMultiplier = 1.1,
        },
}

local function getBoatState(boat)
        local state = boatStates[boat]
        if not state then
                state = {
                        samples = {},
                }
                boatStates[boat] = state
        end

        return state
end

local function computeIntensity(downwardSpeed, horizontalSpeed, minDownwardSpeed)
        minDownwardSpeed = math.max(minDownwardSpeed or DEFAULT_MIN_DOWNWARD_SPEED, 0)
        downwardSpeed = math.max(downwardSpeed, 0)
        horizontalSpeed = math.max(horizontalSpeed, 0)

        local combined = downwardSpeed + (horizontalSpeed * HORIZONTAL_WEIGHT)
        local maxCombined = MAX_VERTICAL_SPEED + (MAX_HORIZONTAL_REFERENCE * HORIZONTAL_WEIGHT)

        if maxCombined <= minDownwardSpeed then
                return 0
        end

        local normalized = (combined - minDownwardSpeed) / (maxCombined - minDownwardSpeed)
        return math.clamp(normalized, 0, 1)
end

local function getSamplerPart(boat, sampler)
        if sampler.getPart then
                return sampler.getPart(boat)
        end

        if sampler.partName then
                return boat:FindFirstChild(sampler.partName)
        end

        return nil
end

local function getVelocity(part)
        if not part then
                return ZERO_VECTOR
        end

        local success, velocity = pcall(part.GetVelocityAtPosition, part, part.Position)
        if success and typeof(velocity) == "Vector3" then
                return velocity
        end

        if part.AssemblyLinearVelocity then
                return part.AssemblyLinearVelocity
        end

        if part.Velocity then
                return part.Velocity
        end

        return ZERO_VECTOR
end

local function processSample(player, boat, sampler, state, baseOffset)
        local part = getSamplerPart(boat, sampler)
        if not part or not part.Parent or not part:IsA("BasePart") then
                local sampleState = state.samples[sampler.key]
                if sampleState then
                        sampleState.lastHeight = nil
                end
                return
        end

        local offset = baseOffset
        local partOffset = part:GetAttribute(WATER_SURFACE_OFFSET_ATTRIBUTE)
        if typeof(partOffset) == "number" then
                offset = partOffset
        end

        local success, waterLevel = pcall(WaterPhysics.GetWaterLevel, part.Position)
        if not success or typeof(waterLevel) ~= "number" then
                return
        end

        local sampleState = state.samples[sampler.key]
        if not sampleState then
                sampleState = {
                        lastHeight = nil,
                        lastSplashTime = 0,
                }
                state.samples[sampler.key] = sampleState
        end

        local surfaceY = part.Position.Y + (typeof(offset) == "number" and offset or 0)
        local heightDelta = surfaceY - waterLevel

        local velocity = getVelocity(part)
        local downwardSpeed = math.max(0, -velocity.Y)
        local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

        local entryHeight = sampler.entryHeight or DEFAULT_ENTRY_HEIGHT
        local exitHeight = sampler.exitHeight or DEFAULT_EXIT_HEIGHT
        local minDrop = sampler.minDrop or DEFAULT_MIN_DROP
        local minDownwardSpeed = sampler.minDownwardSpeed or DEFAULT_MIN_DOWNWARD_SPEED
        local cooldown = sampler.cooldown or SPLASH_COOLDOWN

        local lastHeight = sampleState.lastHeight
        if lastHeight ~= nil then
                local drop = lastHeight - heightDelta
                local crossedSurface = lastHeight > entryHeight and heightDelta <= exitHeight
                local strongDrop = drop >= minDrop
                local nowBelow = heightDelta <= exitHeight

                if (crossedSurface or (nowBelow and strongDrop)) and downwardSpeed > minDownwardSpeed then
                        local now = tick()
                        if now - sampleState.lastSplashTime >= cooldown then
                                local intensity = computeIntensity(downwardSpeed, horizontalSpeed, minDownwardSpeed)
                                if intensity > 0 then
                                        local dropReference = sampler.dropReference or (minDrop + 0.55)
                                        local dropFactor = math.clamp(drop / dropReference, 0, 1.5)
                                        intensity = math.clamp(intensity * (0.6 + dropFactor * 0.6) * (sampler.intensityMultiplier or 1), 0, 1)

                                        BoatSplashService._dispatchSplash(
                                                Vector3.new(part.Position.X, waterLevel, part.Position.Z),
                                                intensity,
                                                player
                                        )

                                        sampleState.lastSplashTime = now
                                end
                        end
                end
        end

        sampleState.lastHeight = heightDelta
end

function BoatSplashService.ProcessBoat(player, boat, primaryPart, waterSurfaceOffset)
        if not boat or not primaryPart or not primaryPart.Parent then
                return
        end

        local state = getBoatState(boat)
        if not state.samples then
                state.samples = {}
        end
        local offset = typeof(waterSurfaceOffset) == "number" and waterSurfaceOffset or 0

        for _, sampler in ipairs(SAMPLE_POINTS) do
                processSample(player, boat, sampler, state, offset)
        end
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
