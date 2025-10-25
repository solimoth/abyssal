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

local UNDERWATER_ATTRIBUTE = "IsUnderwater"
local TIME_SOURCE_ID = "time-cycle"
local MIN_CLOCKTIME_STEP = 1 / 240

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

local playerPhaseState = setmetatable({}, { __mode = "k" })
local attributeConnections = setmetatable({}, { __mode = "k" })
local missingConfigurations = {}

local currentPhaseIndex = 1
local currentPhase = PHASES[currentPhaseIndex]
local currentPhaseStartTime = os.clock()
local currentPhaseDuration = currentPhase and math.max(currentPhase.duration, 0) or 0
local lastClockTime

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

    local configuration = ConfigurationsFolder:FindFirstChild(name, true)
    if configuration then
        missingConfigurations[name] = nil
        return true
    end

    markMissingConfiguration(name)
    return false
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
end

Players.PlayerRemoving:Connect(disconnectPlayer)

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

    currentPhaseStartTime = os.clock() - elapsed

    applyClockTime(currentPhase, elapsed)

    for _, player in ipairs(Players:GetPlayers()) do
        updatePlayer(player)
    end
end

local function advancePhase(elapsedIntoNextPhase)
    currentPhaseIndex += 1
    if currentPhaseIndex > #PHASES then
        currentPhaseIndex = 1
    end

    setPhase(PHASES[currentPhaseIndex], elapsedIntoNextPhase)
end

local function onHeartbeat()
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
            local elapsed = os.clock() - currentPhaseStartTime
            if elapsed >= currentPhaseDuration then
                applyClockTime(currentPhase, currentPhaseDuration)
                advancePhase(elapsed - currentPhaseDuration)
            else
                applyClockTime(currentPhase, elapsed)
                break
            end
        end

        safetyCounter += 1
        if safetyCounter > #PHASES + 1 then
            warn("[TimeSystem] Phase advancement safety triggered, resetting cycle timing.")
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
