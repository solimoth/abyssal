local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LightingService = require(ServerScriptService:WaitForChild("Systems")
    :WaitForChild("LightingSystem")
    :WaitForChild("LightingService"))

local LightingSystemFolder = ReplicatedStorage:WaitForChild("LightingSystem")
local ConfigurationsFolder = LightingSystemFolder:WaitForChild("LightingConfigurations")

local UNDERWATER_ATTRIBUTE = "IsUnderwater"
local TIME_SOURCE_ID = "time-cycle"

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
    },
}

local playerPhaseState = setmetatable({}, { __mode = "k" })
local attributeConnections = setmetatable({}, { __mode = "k" })
local missingConfigurations = {}

local currentPhaseIndex = 1
local currentPhase = PHASES[currentPhaseIndex]

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

local function applyPhase(phase)
    currentPhase = phase

    for _, player in ipairs(Players:GetPlayers()) do
        updatePlayer(player)
    end
end

local function runCycle()
    while true do
        local phase = PHASES[currentPhaseIndex]
        applyPhase(phase)

        local duration = 0
        if phase and typeof(phase.duration) == "number" then
            duration = math.max(phase.duration, 0)
        end

        if duration > 0 then
            task.wait(duration)
        else
            task.wait()
        end

        currentPhaseIndex += 1
        if currentPhaseIndex > #PHASES then
            currentPhaseIndex = 1
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

runCycle()
