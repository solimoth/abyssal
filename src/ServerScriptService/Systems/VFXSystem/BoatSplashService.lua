local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("WaterPhysics"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local vfxRemotes = remotesFolder:WaitForChild("VFXSystem")
local boatSplashEvent = vfxRemotes:WaitForChild("BoatSplash")

local BoatSplashService = {}

local boatStates = setmetatable({}, { __mode = "k" })

local recipientsBuffer = table.create(8)
local payloadBuffer = {}

local clock = os.clock

local DEFAULT_ENTRY_HEIGHT = 0.18
local DEFAULT_EXIT_HEIGHT = -0.05
local DEFAULT_MIN_DROP = 0.055
local DEFAULT_MIN_DOWNWARD_SPEED = 0.9
local HORIZONTAL_WEIGHT = 0.3
local MAX_VERTICAL_SPEED = 45
local MAX_HORIZONTAL_REFERENCE = 45
local SPLASH_COOLDOWN = 0.65
local DEFAULT_WAKE_COOLDOWN = 0.2
local DEFAULT_WAKE_SPEED_THRESHOLD = 8
local DEFAULT_WAKE_MAX_SPEED = 65
local DEFAULT_WAKE_MIN_RATE = 2.5
local DEFAULT_WAKE_MAX_RATE = 10
local MAX_WAKE_EMISSIONS_PER_STEP = 3
local MAX_VISIBILITY_DISTANCE = 250
local MAX_SAMPLE_DELTA = 1.25

local ZERO_VECTOR = Vector3.new()
local WATER_SURFACE_OFFSET_ATTRIBUTE = "WaterSurfaceOffset"

local SAMPLE_POINTS = {
        {
                key = "Primary",
                entryHeight = 0.22,
                exitHeight = -0.05,
                minDrop = 0.12,
                minDownwardSpeed = 1.5,
                cooldown = 0.7,
                intensityMultiplier = 1,
                getPart = function(boat)
                        return boat.PrimaryPart
                end,
        },
        {
                key = "BoatFront",
                partName = "BoatFront",
                entryHeight = 0.18,
                exitHeight = -0.1,
                minDrop = 0.07,
                minDownwardSpeed = 0.85,
                cooldown = 0.5,
                intensityMultiplier = 1.1,
                wakeCooldown = 0.18,
                wakeSpeedThreshold = 7,
                wakeMaxSpeed = 58,
                wakeIntensityMultiplier = 0.6,
        },
        {
                key = "BoatBack",
                partName = "BoatBack",
                entryHeight = 0.18,
                exitHeight = -0.1,
                minDrop = 0.07,
                minDownwardSpeed = 0.85,
                cooldown = 0.5,
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

local function resolveWaterLevel(position)
        local success, level = pcall(WaterPhysics.TryGetWaterSurface, position)
        if success and typeof(level) == "number" then
                return level
        end

        success, level = pcall(WaterPhysics.GetWaterLevel, position)
        if success and typeof(level) == "number" then
                return level
        end

        return nil
end

local function processSample(player, boat, sampler, state, baseOffset)
        local part = getSamplerPart(boat, sampler)
        if not part or not part.Parent or not part:IsA("BasePart") then
                local sampleState = state.samples[sampler.key]
                if sampleState then
                        sampleState.lastHeight = nil
                        sampleState.lastPosition = nil
                end
                return
        end

        local offset = baseOffset
        local partOffset = part:GetAttribute(WATER_SURFACE_OFFSET_ATTRIBUTE)
        if typeof(partOffset) == "number" then
                offset = partOffset
        end

        local waterLevel = resolveWaterLevel(part.Position)
        if typeof(waterLevel) ~= "number" then
                return
        end

        local sampleState = state.samples[sampler.key]
        if not sampleState then
                sampleState = {
                        lastHeight = nil,
                        lastSplashTime = 0,
                        lastUpdateTime = nil,
                        lastWaterLevel = nil,
                        lastPosition = nil,
                        wakeAccumulator = 0,
                }
                state.samples[sampler.key] = sampleState
        end

        local surfaceY = part.Position.Y + (typeof(offset) == "number" and offset or 0)
        local heightDelta = surfaceY - waterLevel

        local velocity = getVelocity(part)
        local now = clock()
        local lastUpdate = sampleState.lastUpdateTime
        local deltaTime
        local waterVelocity = 0

        if typeof(sampleState.lastWaterLevel) == "number" and typeof(lastUpdate) == "number" then
                deltaTime = now - lastUpdate
                if deltaTime > 1e-3 then
                        local effectiveDeltaTime = math.clamp(deltaTime, 1e-3, MAX_SAMPLE_DELTA)
                        waterVelocity = (waterLevel - sampleState.lastWaterLevel) / effectiveDeltaTime
                end
        end

        local relativeVelocityY = velocity.Y - waterVelocity
        local downwardSpeed = math.max(0, -relativeVelocityY)
        local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
        local horizontalSpeed = horizontalVelocity.Magnitude

        if not deltaTime and typeof(lastUpdate) == "number" then
                deltaTime = now - lastUpdate
        end

        if deltaTime and deltaTime > 1e-3 then
                local lastPosition = sampleState.lastPosition
                if lastPosition then
                        local displacement = part.Position - lastPosition
                        local horizontalDisplacement = Vector3.new(displacement.X, 0, displacement.Z)
                        local effectiveDeltaTime = math.clamp(deltaTime, 1e-3, MAX_SAMPLE_DELTA)
                        local fallbackHorizontalSpeed = horizontalDisplacement.Magnitude / effectiveDeltaTime
                        if fallbackHorizontalSpeed > horizontalSpeed then
                                horizontalSpeed = fallbackHorizontalSpeed
                        end
                end
        end

        local entryHeight = sampler.entryHeight or DEFAULT_ENTRY_HEIGHT
        local exitHeight = sampler.exitHeight or DEFAULT_EXIT_HEIGHT
        local minDrop = sampler.minDrop or DEFAULT_MIN_DROP
        local minDownwardSpeed = sampler.minDownwardSpeed or DEFAULT_MIN_DOWNWARD_SPEED
        local cooldown = sampler.cooldown or SPLASH_COOLDOWN

        local lastHeight = sampleState.lastHeight
        if lastHeight ~= nil then
                local drop = lastHeight - heightDelta
                local wasHigh = lastHeight > entryHeight
                local nearSurface = heightDelta <= entryHeight
                local nowBelow = heightDelta <= exitHeight
                local strongDrop = drop >= minDrop
                local dropSpeed = 0

                if drop > 0 and deltaTime and deltaTime > 1e-3 then
                        local effectiveDeltaTime = math.clamp(deltaTime, 1e-3, MAX_SAMPLE_DELTA)
                        dropSpeed = math.max(drop / effectiveDeltaTime, 0)
                end

                local effectiveDownwardSpeed = math.max(downwardSpeed, dropSpeed)

                if (nowBelow or (nearSurface and wasHigh)) and strongDrop and effectiveDownwardSpeed > minDownwardSpeed then
                        if now - sampleState.lastSplashTime >= cooldown then
                                local intensity = computeIntensity(effectiveDownwardSpeed, horizontalSpeed, minDownwardSpeed)
                                if intensity > 0 then
                                        local dropReference = sampler.dropReference or (minDrop + 0.55)
                                        local dropFactor = math.clamp(drop / dropReference, 0, 1.5)
                                        local impactMultiplier = sampler.intensityMultiplier or 1
                                        intensity = math.clamp(intensity * (0.6 + dropFactor * 0.6) * impactMultiplier, 0, 1)

                                        BoatSplashService._dispatchSplash(
                                                Vector3.new(part.Position.X, waterLevel, part.Position.Z),
                                                intensity,
                                                player,
                                                sampler.key,
                                                "Impact"
                                        )

                                        sampleState.lastSplashTime = now
                                end
                        end
                end
        end

        local wakeSpeedThreshold = sampler.wakeSpeedThreshold or DEFAULT_WAKE_SPEED_THRESHOLD
        if wakeSpeedThreshold > 0 and sampler.key == "BoatFront" then
                local nearSurface = heightDelta <= entryHeight

                if nearSurface then
                        local wakeMaxSpeed = sampler.wakeMaxSpeed or DEFAULT_WAKE_MAX_SPEED
                        local wakeIntensityMultiplier = sampler.wakeIntensityMultiplier or 1
                        local speedRange = math.max(wakeMaxSpeed - wakeSpeedThreshold, 1)
                        local horizontalRatio = math.clamp((horizontalSpeed - wakeSpeedThreshold) / speedRange, 0, 1)

                        if horizontalRatio > 0 then
                                local wakeMinRate = sampler.wakeMinRate or DEFAULT_WAKE_MIN_RATE
                                local wakeMaxRate = sampler.wakeMaxRate or DEFAULT_WAKE_MAX_RATE
                                local wakeRateRange = math.max(wakeMaxRate - wakeMinRate, 0)
                                local targetRate = wakeMinRate + (wakeRateRange * horizontalRatio)
                                local intensity = math.clamp(horizontalRatio * wakeIntensityMultiplier, 0, 1)
                                local effectiveDeltaTime = deltaTime and math.clamp(deltaTime, 1e-3, MAX_SAMPLE_DELTA) or nil

                                if effectiveDeltaTime then
                                        local accumulator = (sampleState.wakeAccumulator or 0) + (targetRate * effectiveDeltaTime)
                                        local emissions = math.clamp(math.floor(accumulator), 0, MAX_WAKE_EMISSIONS_PER_STEP)

                                        if emissions > 0 then
                                                accumulator -= emissions

                                                for _ = 1, emissions do
                                                        BoatSplashService._dispatchSplash(
                                                                Vector3.new(part.Position.X, waterLevel, part.Position.Z),
                                                                intensity,
                                                                player,
                                                                sampler.key,
                                                                "Wake"
                                                        )
                                                end

                                                sampleState.lastWakeTime = now
                                        end

                                        sampleState.wakeAccumulator = accumulator
                                else
                                        sampleState.wakeAccumulator = 0
                                        local wakeCooldown = sampler.wakeCooldown or DEFAULT_WAKE_COOLDOWN
                                        local lastWake = sampleState.lastWakeTime or 0

                                        if now - lastWake >= wakeCooldown then
                                                BoatSplashService._dispatchSplash(
                                                        Vector3.new(part.Position.X, waterLevel, part.Position.Z),
                                                        intensity,
                                                        player,
                                                        sampler.key,
                                                        "Wake"
                                                )

                                                sampleState.lastWakeTime = now
                                        end
                                end
                        else
                                sampleState.wakeAccumulator = 0
                        end
                else
                        sampleState.wakeAccumulator = 0
                end
        end

        sampleState.lastHeight = heightDelta
        sampleState.lastUpdateTime = now
        sampleState.lastWaterLevel = waterLevel
        sampleState.lastPosition = part.Position
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

function BoatSplashService._dispatchSplash(position, intensity, owner, samplerKey, effectType)
        intensity = math.clamp(intensity, 0, 1)
        if intensity <= 0 then
                return
        end

        table.clear(recipientsBuffer)

        local players = Players:GetPlayers()
        for index = 1, #players do
                local player = players[index]
                local character = player.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")
                if hrp then
                        local distance = (hrp.Position - position).Magnitude
                        if distance <= MAX_VISIBILITY_DISTANCE then
                                recipientsBuffer[#recipientsBuffer + 1] = player
                        end
                end
        end

        if owner and owner.Parent then
                local alreadyPresent = false
                for index = 1, #recipientsBuffer do
                        if recipientsBuffer[index] == owner then
                                alreadyPresent = true
                                break
                        end
                end

                if not alreadyPresent then
                        recipientsBuffer[#recipientsBuffer + 1] = owner
                end
        end

        if #recipientsBuffer == 0 then
                return
        end

        payloadBuffer.position = position
        payloadBuffer.intensity = intensity
        payloadBuffer.samplerKey = samplerKey
        payloadBuffer.effectType = effectType

        for index = 1, #recipientsBuffer do
                boatSplashEvent:FireClient(recipientsBuffer[index], payloadBuffer)
        end
end

function BoatSplashService.ClearBoat(boat)
	if boat then
		boatStates[boat] = nil
	end
end

return BoatSplashService
