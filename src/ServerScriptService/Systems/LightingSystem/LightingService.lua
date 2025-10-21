local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LightingService = {}
LightingService.__index = LightingService

local LightingSystemFolder = ReplicatedStorage:WaitForChild("LightingSystem")
local REMOTE = LightingSystemFolder:WaitForChild("Remotes"):WaitForChild("Lighting"):WaitForChild("SetConfiguration")
local CONFIGURATIONS_FOLDER = LightingSystemFolder:FindFirstChild("LightingConfigurations")

local DEFAULT_CONFIGURATION_NAME = "Default"
local DEFAULT_OPTIONS = {
    transitionTime = 1.5,
    easingStyle = Enum.EasingStyle.Sine,
    easingDirection = Enum.EasingDirection.Out,
    priority = 0,
}

local playerStates = {}
local initialized = false

local function cloneOptions(options)
    local copy = {}
    for key, value in pairs(options) do
        copy[key] = value
    end
    return copy
end

local function mergeOptions(base, overrides)
    local merged = cloneOptions(base)
    if overrides then
        if overrides.transitionTime ~= nil then
            merged.transitionTime = overrides.transitionTime
        end

        if overrides.easingStyle ~= nil then
            merged.easingStyle = overrides.easingStyle
        end

        if overrides.easingDirection ~= nil then
            merged.easingDirection = overrides.easingDirection
        end

        if overrides.priority ~= nil then
            merged.priority = overrides.priority
        end
    end

    return merged
end

local function normalizeOptions(options)
    options = options or {}
    local defaults = LightingService._defaultOptions or DEFAULT_OPTIONS

    return {
        transitionTime = options.transitionTime or defaults.transitionTime,
        easingStyle = options.easingStyle or defaults.easingStyle,
        easingDirection = options.easingDirection or defaults.easingDirection,
        priority = options.priority or defaults.priority,
    }
end

local function compareOptionTables(a, b)
    if not a or not b then
        return false
    end

    return a.transitionTime == b.transitionTime
        and a.easingStyle == b.easingStyle
        and a.easingDirection == b.easingDirection
end

local function getState(player)
    local state = playerStates[player]
    if not state then
        state = {
            sources = {},
            currentConfig = nil,
            currentOptions = nil,
        }
        playerStates[player] = state
    end
    return state
end

local function sendConfiguration(player, configName, options)
    REMOTE:FireClient(player, configName, options)
end

local function getDefaultConfiguration()
    return LightingService._defaultConfiguration or DEFAULT_CONFIGURATION_NAME,
        LightingService._defaultOptions or DEFAULT_OPTIONS
end

local function selectBestSource(state)
    local bestSource

    for _, source in pairs(state.sources) do
        if not bestSource then
            bestSource = source
        else
            if source.priority > bestSource.priority then
                bestSource = source
            elseif source.priority == bestSource.priority and source.timestamp > bestSource.timestamp then
                bestSource = source
            end
        end
    end

    if not bestSource then
        local defaultName, defaultOptions = getDefaultConfiguration()
        bestSource = {
            configName = defaultName,
            options = defaultOptions,
        }
    end

    return bestSource
end

local function applyState(player)
    local state = getState(player)
    local bestSource = selectBestSource(state)

    if state.currentConfig ~= bestSource.configName or not compareOptionTables(state.currentOptions, bestSource.options) then
        state.currentConfig = bestSource.configName
        state.currentOptions = cloneOptions(bestSource.options)
        sendConfiguration(player, bestSource.configName, state.currentOptions)
    end
end

local function cleanupPlayer(player)
    playerStates[player] = nil
end

local function initialize()
    if initialized then
        return
    end
    initialized = true

    local defaultName = DEFAULT_CONFIGURATION_NAME
    if CONFIGURATIONS_FOLDER then
        local configuredDefault = CONFIGURATIONS_FOLDER:GetAttribute("DefaultConfiguration")
        if typeof(configuredDefault) == "string" and configuredDefault ~= "" then
            defaultName = configuredDefault
        end
    end

    LightingService._defaultConfiguration = defaultName
    LightingService._defaultOptions = cloneOptions(DEFAULT_OPTIONS)

    Players.PlayerAdded:Connect(function(player)
        task.defer(function()
            applyState(player)
        end)
    end)

    Players.PlayerRemoving:Connect(cleanupPlayer)

    for _, player in ipairs(Players:GetPlayers()) do
        task.defer(function()
            applyState(player)
        end)
    end
end

function LightingService:SetDefaultConfiguration(configName, options)
    initialize()

    assert(typeof(configName) == "string", "configName must be a string")
    self._defaultConfiguration = configName
    self._defaultOptions = mergeOptions(DEFAULT_OPTIONS, options)

    for player, state in pairs(playerStates) do
        if next(state.sources) == nil then
            applyState(player)
        end
    end
end

function LightingService:SetSource(player, sourceId, configName, options)
    initialize()

    assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player")
    assert(typeof(sourceId) == "string", "sourceId must be a string")
    assert(typeof(configName) == "string", "configName must be a string")

    local normalized = normalizeOptions(options)
    local state = getState(player)

    state.sources[sourceId] = {
        configName = configName,
        options = normalized,
        priority = normalized.priority,
        timestamp = os.clock(),
    }

    applyState(player)
end

function LightingService:ClearSource(player, sourceId)
    initialize()

    assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player")
    assert(typeof(sourceId) == "string", "sourceId must be a string")

    local state = playerStates[player]
    if not state then
        return
    end

    state.sources[sourceId] = nil
    applyState(player)
end

function LightingService:ClearAll(player)
    initialize()

    assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player")

    local state = playerStates[player]
    if state then
        table.clear(state.sources)
        applyState(player)
    end
end

function LightingService:ApplyToAll(sourceId, configName, options)
    initialize()

    assert(typeof(sourceId) == "string", "sourceId must be a string")
    assert(typeof(configName) == "string", "configName must be a string")

    local normalized = normalizeOptions(options)
    for _, player in ipairs(Players:GetPlayers()) do
        local state = getState(player)
        state.sources[sourceId] = {
            configName = configName,
            options = normalized,
            priority = normalized.priority,
            timestamp = os.clock(),
        }
        applyState(player)
    end
end

function LightingService:ClearSourceFromAll(sourceId)
    initialize()

    assert(typeof(sourceId) == "string", "sourceId must be a string")

    for player, state in pairs(playerStates) do
        state.sources[sourceId] = nil
        applyState(player)
    end
end

initialize()

return LightingService
