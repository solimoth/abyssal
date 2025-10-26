local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local LightingService = require(ServerScriptService:WaitForChild("Systems")
    :WaitForChild("LightingSystem")
    :WaitForChild("LightingService"))

local LightingSystemFolder = ReplicatedStorage:WaitForChild("LightingSystem")
local ConfigurationsFolder = LightingSystemFolder:WaitForChild("LightingConfigurations")
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local TimeSystemRemotes = RemotesFolder:WaitForChild("TimeSystem")
local UpdateUnderwaterRemote = TimeSystemRemotes:WaitForChild("UpdateUnderwaterState")
local ModulesFolder = ReplicatedStorage:WaitForChild("Modules")
local WaterPhysics = require(ModulesFolder:WaitForChild("WaterPhysics"))
local SwimInteriorUtils = require(ModulesFolder:WaitForChild("SwimInteriorUtils"))

local UNDERWATER_ATTRIBUTE = "IsUnderwater"
local TIME_SOURCE_ID = "time-cycle"
local MIN_CLOCKTIME_STEP = 1 / 240

local UNDERWATER_ENTRY_DEPTH = 0.1
local UNDERWATER_HEAD_THRESHOLD = 0.05
local UNDERWATER_RATE_LIMIT = 6
local UNDERWATER_RATE_CAPACITY = 8
local UNDERWATER_RATE_DECAY = 0.5
local UNDERWATER_RATE_WARN_THRESHOLD = 8
local UNDERWATER_RATE_WARN_COOLDOWN = 5

local osClock = os.clock

local detectorOffsets = {
    Upper = Vector3.new(0, 1, -0.75),
    Lower = Vector3.new(0, -2.572, -0.75),
}

local PHASES = {
    {
        name = "Day",
        configName = "Default",
        duration = 10 * 60,
        overridesLighting = false,
        options = {
            transitionTime = 12,
            easingStyle = Enum.EasingStyle.Sine,
            easingDirection = Enum.EasingDirection.Out,
            priority = 0,
            transitionProgress = 1,
        },
        clockTimeStart = 6,
        clockTimeFinish = 17,
    },
    {
        name = "Sunset",
        configName = "Sunset",
        duration = 90,
        overridesLighting = true,
        options = {
            transitionTime = 18,
            easingStyle = Enum.EasingStyle.Quad,
            easingDirection = Enum.EasingDirection.InOut,
            priority = 1000,
            transitionProgress = 1,
        },
        clockTimeStart = 17,
        clockTimeFinish = 18,
    },
    {
        name = "Night",
        configName = "Night",
        duration = 6 * 60,
        overridesLighting = true,
        options = {
            transitionTime = 18,
            easingStyle = Enum.EasingStyle.Sine,
            easingDirection = Enum.EasingDirection.InOut,
            priority = 1000,
            transitionProgress = 1,
        },
        clockTimeStart = 18,
        clockTimeFinish = 30,
    },
}

local PHASE_COUNT = #PHASES

local playerPhaseState = setmetatable({}, { __mode = "k" })
local attributeConnections = setmetatable({}, { __mode = "k" })
local missingConfigurations = {}
local configurationExistsCache = {}
local configurationCounts = {}

local currentPhaseIndex = 1
local currentPhase = PHASES[currentPhaseIndex]
local currentPhaseElapsed = 0
local currentPhaseDuration = currentPhase and math.max(currentPhase.duration, 0) or 0
local lastClockTime
local underwaterRateState = setmetatable({}, { __mode = "k" })
local underwaterMismatchState = setmetatable({}, { __mode = "k" })

local function incrementConfigurationCount(name)
    if typeof(name) ~= "string" or name == "" then
        return
    end

    configurationCounts[name] = (configurationCounts[name] or 0) + 1
    configurationExistsCache[name] = true
    missingConfigurations[name] = nil
end

local function decrementConfigurationCount(name)
    if typeof(name) ~= "string" or name == "" then
        return
    end

    local count = configurationCounts[name]
    if not count then
        return
    end

    if count <= 1 then
        configurationCounts[name] = nil
        configurationExistsCache[name] = false
    else
        configurationCounts[name] = count - 1
    end
end

local function onConfigurationAdded(instance)
    incrementConfigurationCount(instance.Name)
end

local function onConfigurationRemoved(instance)
    decrementConfigurationCount(instance.Name)
end

for _, descendant in ipairs(ConfigurationsFolder:GetDescendants()) do
    incrementConfigurationCount(descendant.Name)
end

ConfigurationsFolder.DescendantAdded:Connect(onConfigurationAdded)
ConfigurationsFolder.DescendantRemoving:Connect(onConfigurationRemoved)

local function markMissingConfiguration(name)
    if not missingConfigurations[name] then
        missingConfigurations[name] = true
        warn(("[TimeSystem] Lighting configuration '%s' is missing."):format(name))
    end
end

local function ensureConfiguration(name)
    if not name or name == "" then
        return false
    end

    local cached = configurationExistsCache[name]
    if cached ~= nil then
        if cached == false then
            markMissingConfiguration(name)
        end
        return cached
    end

    local configuration = ConfigurationsFolder:FindFirstChild(name, true)
    if configuration then
        if not configurationCounts[name] then
            incrementConfigurationCount(name)
        else
            configurationExistsCache[name] = true
            missingConfigurations[name] = nil
        end
        return true
    end

    configurationExistsCache[name] = false
    markMissingConfiguration(name)
    return false
end

local function cleanupSecurityState(player)
    underwaterRateState[player] = nil
    underwaterMismatchState[player] = nil
end

local function getWaterDepth(position)
    local surfaceY = WaterPhysics.TryGetWaterSurface(position)
    if not surfaceY then
        return 0
    end

    return math.max(0, surfaceY - position.Y)
end

local function computeServerUnderwaterState(player)
    local character = player.Character
    if not character then
        return nil
    end

    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        return nil
    end

    if SwimInteriorUtils.IsInsideShipInterior(character) then
        return false
    end

    local rootCFrame = rootPart.CFrame
    local upperDepth = getWaterDepth(rootCFrame:PointToWorldSpace(detectorOffsets.Upper))
    local lowerDepth = getWaterDepth(rootCFrame:PointToWorldSpace(detectorOffsets.Lower))

    local underwater = upperDepth > UNDERWATER_ENTRY_DEPTH and lowerDepth > UNDERWATER_ENTRY_DEPTH

    if not underwater then
        local head = character:FindFirstChild("Head")
        if head then
            local headDepth = getWaterDepth(head.Position)
            if headDepth > UNDERWATER_HEAD_THRESHOLD and lowerDepth > UNDERWATER_ENTRY_DEPTH then
                underwater = true
            end
        end
    end

    return underwater
end

local function checkUnderwaterRateLimit(player)
    local now = osClock()
    local state = underwaterRateState[player]
    if not state then
        state = {
            tokens = UNDERWATER_RATE_CAPACITY,
            lastUpdate = now,
            violations = 0,
            lastWarn = 0,
        }
        underwaterRateState[player] = state
    end

    local elapsed = now - state.lastUpdate
    state.lastUpdate = now

    state.tokens = math.min(
        UNDERWATER_RATE_CAPACITY,
        state.tokens + (elapsed * UNDERWATER_RATE_LIMIT)
    )

    if state.tokens < 1 then
        state.violations += 1
        if state.violations >= UNDERWATER_RATE_WARN_THRESHOLD then
            if now - state.lastWarn >= UNDERWATER_RATE_WARN_COOLDOWN then
                warn(
                    string.format(
                        "[TimeSystem] %s exceeded underwater update rate limit (%d violations)",
                        player.Name,
                        state.violations
                    )
                )
                state.lastWarn = now
            end
        end
        return false
    end

    state.tokens -= 1
    state.violations = math.max(state.violations - UNDERWATER_RATE_DECAY, 0)
    return true
end

local function clearTimeOverride(player)
    LightingService:ClearSource(player, TIME_SOURCE_ID)

    local state = playerPhaseState[player]
    if state then
        state.active = false
        state.phaseName = nil
    else
        playerPhaseState[player] = {
            active = false,
            phaseName = nil,
        }
    end
end

local function applyPhaseToPlayer(player, phase)
    local state = playerPhaseState[player]
    if not state then
        state = {
            active = false,
            phaseName = nil,
        }
        playerPhaseState[player] = state
    end

    if player:GetAttribute(UNDERWATER_ATTRIBUTE) == true then
        if state.active then
            clearTimeOverride(player)
        end
        return
    end

    if not phase or not phase.overridesLighting then
        if state.active then
            clearTimeOverride(player)
        end
        return
    end

    if not ensureConfiguration(phase.configName) then
        if state.active then
            clearTimeOverride(player)
        end
        return
    end

    if state.active and state.phaseName == phase.name then
        return
    end

    LightingService:SetSource(player, TIME_SOURCE_ID, phase.configName, phase.options)
    state.active = true
    state.phaseName = phase.name
end

local function updatePlayer(player)
    if currentPhase then
        applyPhaseToPlayer(player, currentPhase)
    else
        clearTimeOverride(player)
    end
end

local function connectPlayer(player)
    updatePlayer(player)

    local connection = attributeConnections[player]
    if connection then
        connection:Disconnect()
    end

    attributeConnections[player] = player:GetAttributeChangedSignal(UNDERWATER_ATTRIBUTE):Connect(function()
        updatePlayer(player)
    end)
end

local function disconnectPlayer(player)
    local connection = attributeConnections[player]
    if connection then
        connection:Disconnect()
        attributeConnections[player] = nil
    end

    if playerPhaseState[player] then
        clearTimeOverride(player)
        playerPhaseState[player] = nil
    end

    cleanupSecurityState(player)
end

Players.PlayerRemoving:Connect(disconnectPlayer)

UpdateUnderwaterRemote.OnServerEvent:Connect(function(player, isUnderwater)
    if typeof(isUnderwater) ~= "boolean" then
        return
    end

    if not checkUnderwaterRateLimit(player) then
        return
    end

    local computedState = computeServerUnderwaterState(player)
    if computedState == nil then
        return
    end

    if computedState ~= isUnderwater then
        local mismatch = underwaterMismatchState[player]
        local now = osClock()
        if not mismatch then
            mismatch = {
                count = 0,
                lastWarn = 0,
            }
            underwaterMismatchState[player] = mismatch
        end

        mismatch.count += 1
        if mismatch.count >= 5 and now - mismatch.lastWarn >= 10 then
            warn(
                string.format(
                    "[TimeSystem] Ignored underwater state from %s (client=%s, server=%s)",
                    player.Name,
                    tostring(isUnderwater),
                    tostring(computedState)
                )
            )
            mismatch.lastWarn = now
        end
    else
        underwaterMismatchState[player] = nil
    end

    if player:GetAttribute(UNDERWATER_ATTRIBUTE) ~= computedState then
        player:SetAttribute(UNDERWATER_ATTRIBUTE, computedState)
    end
end)

local function getPhaseDuration(phase)
    if not phase then
        return 0
    end

    if typeof(phase.duration) ~= "number" then
        return 0
    end

    return math.max(phase.duration, 0)
end

local function computeClockTime(phase, elapsed)
    if not phase then
        return nil
    end

    local startTime = phase.clockTimeStart
    local finishTime = phase.clockTimeFinish
    if typeof(startTime) ~= "number" or typeof(finishTime) ~= "number" then
        return nil
    end

    local duration = getPhaseDuration(phase)
    if duration <= 0 then
        return finishTime % 24
    end

    local progress = math.clamp(elapsed / duration, 0, 1)
    local absoluteTime = startTime + (finishTime - startTime) * progress
    return absoluteTime % 24
end

local function applyClockTime(phase, elapsed)
    local clockTime = computeClockTime(phase, elapsed)
    if clockTime == nil then
        return
    end

    if lastClockTime == nil then
        lastClockTime = clockTime
        Lighting.ClockTime = clockTime
        return
    end

    local difference = math.abs(clockTime - lastClockTime)
    if difference > 12 then
        difference = 24 - difference
    end

    if difference >= MIN_CLOCKTIME_STEP then
        lastClockTime = clockTime
        Lighting.ClockTime = clockTime
    end
end

local function setPhase(phase, elapsedIntoPhase)
    currentPhase = phase
    currentPhaseDuration = getPhaseDuration(phase)

    local elapsed = math.max(elapsedIntoPhase or 0, 0)
    if currentPhaseDuration <= 0 then
        elapsed = 0
    end

    currentPhaseElapsed = elapsed

    applyClockTime(currentPhase, elapsed)

    for _, player in ipairs(Players:GetPlayers()) do
        updatePlayer(player)
    end
end

local function advancePhase(elapsedIntoNextPhase)
    currentPhaseIndex += 1
    if currentPhaseIndex > PHASE_COUNT then
        currentPhaseIndex = 1
    end

    setPhase(PHASES[currentPhaseIndex], elapsedIntoNextPhase)
end

local function onHeartbeat(deltaTime)
    currentPhaseElapsed += math.max(deltaTime or 0, 0)

    local safetyCounter = 0

    while true do
        if not currentPhase then
            advancePhase()
            return
        end

        if currentPhaseDuration <= 0 then
            applyClockTime(currentPhase, currentPhaseDuration)
            advancePhase(0)
        else
            if currentPhaseElapsed >= currentPhaseDuration then
                applyClockTime(currentPhase, currentPhaseDuration)
                local overflow = currentPhaseElapsed - currentPhaseDuration
                advancePhase(overflow)
            else
                applyClockTime(currentPhase, currentPhaseElapsed)
                break
            end
        end

        safetyCounter += 1
        if safetyCounter > PHASE_COUNT + 1 then
            warn("[TimeSystem] Phase advancement safety triggered, resetting cycle timing.")
            setPhase(PHASES[currentPhaseIndex], 0)
            break
        end
    end
end

local dayPhase = PHASES[1]
if ensureConfiguration(dayPhase.configName) then
    LightingService:SetDefaultConfiguration(dayPhase.configName, dayPhase.options)
end

for _, player in ipairs(Players:GetPlayers()) do
    task.defer(connectPlayer, player)
end

Players.PlayerAdded:Connect(function(player)
    task.defer(connectPlayer, player)
end)

LightingService:ClearSourceFromAll(TIME_SOURCE_ID)

setPhase(currentPhase)

RunService.Heartbeat:Connect(onHeartbeat)
