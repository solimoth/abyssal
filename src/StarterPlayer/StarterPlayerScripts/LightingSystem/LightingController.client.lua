local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local REMOTE_PATH = { "LightingSystem", "Remotes", "Lighting", "SetConfiguration" }
local WATER_COLOR_ATTRIBUTE = "WaterColor"
local DEFAULT_TRANSITION = {
    transitionTime = 1.5,
    easingStyle = Enum.EasingStyle.Sine,
    easingDirection = Enum.EasingDirection.Out,
}

local LIGHTING_PROPERTIES = {
    "Ambient",
    "Brightness",
    "ColorShift_Bottom",
    "ColorShift_Top",
    "EnvironmentDiffuseScale",
    "EnvironmentSpecularScale",
    "ExposureCompensation",
    "FogColor",
    "FogEnd",
    "FogStart",
    "GeographicLatitude",
    "OutdoorAmbient",
    "ShadowSoftness",
}

local EFFECT_PROPERTY_MAP = {
    Atmosphere = {
        "Color",
        "Decay",
        "Density",
        "Glare",
        "Haze",
        "Offset",
    },
    BloomEffect = {
        "Intensity",
        "Size",
        "Threshold",
    },
    ColorCorrectionEffect = {
        "Brightness",
        "Contrast",
        "Saturation",
        "TintColor",
    },
    DepthOfFieldEffect = {
        "FarIntensity",
        "FocusDistance",
        "InFocusRadius",
        "NearIntensity",
    },
    SunRaysEffect = {
        "Intensity",
        "Spread",
    },
}

local function findRemote()
    local current = ReplicatedStorage
    for _, childName in ipairs(REMOTE_PATH) do
        current = current:WaitForChild(childName)
    end
    return current
end

local Terrain = Workspace.Terrain
local SetConfigurationEvent = findRemote()
local LightingSystemFolder = ReplicatedStorage:WaitForChild("LightingSystem", math.huge)
local ConfigurationsFolder = LightingSystemFolder:WaitForChild("LightingConfigurations", math.huge)
local WaveConfig = require(ReplicatedStorage:WaitForChild("Modules", math.huge):WaitForChild("WaveConfig", math.huge))
local WAVE_CONTAINER_NAME = WaveConfig.ContainerName or "DynamicWaveSurface"
local waveContainer: Instance?
local pendingWaveColor: Color3?

local function getWaveContainer(): Instance?
    if waveContainer and waveContainer.Parent then
        return waveContainer
    end

    waveContainer = Workspace:FindFirstChild(WAVE_CONTAINER_NAME)
    if waveContainer and pendingWaveColor then
        local current = waveContainer:GetAttribute("Color")
        if typeof(current) ~= "Color3" or current ~= pendingWaveColor then
            waveContainer:SetAttribute("Color", pendingWaveColor)
        end
    end
    return waveContainer
end

local function readDefaultConfigurationName()
    local configuredDefault = ConfigurationsFolder:GetAttribute("DefaultConfiguration")
    if typeof(configuredDefault) == "string" and configuredDefault ~= "" then
        return configuredDefault
    end

    return "Default"
end

local defaultConfigurationName = readDefaultConfigurationName()
local initialTerrainWaterColor = Terrain.WaterColor
local activeEffects = {}
local activeTweens = {}
local pendingEffectRemovals = {}

local function mergeOptions(options)
    options = options or {}
    return {
        transitionTime = options.transitionTime or DEFAULT_TRANSITION.transitionTime,
        easingStyle = options.easingStyle or DEFAULT_TRANSITION.easingStyle,
        easingDirection = options.easingDirection or DEFAULT_TRANSITION.easingDirection,
        transitionProgress = math.clamp(options.transitionProgress or 1, 0, 1),
    }
end

local function clamp01(value: number): number
    return math.clamp(value, 0, 1)
end

local function blendValue(baseValue, targetValue, alpha)
    alpha = clamp01(alpha)

    if alpha >= 1 then
        return targetValue
    end

    if baseValue == nil then
        return alpha > 0 and targetValue or baseValue
    end

    local valueType = typeof(targetValue)

    if valueType == "number" then
        if typeof(baseValue) ~= "number" then
            return targetValue
        end
        return baseValue + (targetValue - baseValue) * alpha
    elseif valueType == "Color3" then
        if typeof(baseValue) ~= "Color3" then
            return targetValue
        end
        return baseValue:Lerp(targetValue, alpha)
    end

    return alpha > 0 and targetValue or baseValue
end

local function getDefaultConfigurationFolder(): Instance?
    return ConfigurationsFolder:FindFirstChild(defaultConfigurationName, true)
end

local function getDefaultLightingAttribute(propertyName: string)
    local defaultConfiguration = getDefaultConfigurationFolder()
    if defaultConfiguration then
        local value = defaultConfiguration:GetAttribute(propertyName)
        if value ~= nil then
            return value
        end
    end

    return nil
end

local function getLightingBaseValue(propertyName: string, targetValue)
    local defaultValue = getDefaultLightingAttribute(propertyName)
    if defaultValue ~= nil and typeof(defaultValue) == typeof(targetValue) then
        return defaultValue
    end

    local success, currentValue = pcall(function()
        return Lighting[propertyName]
    end)

    if success and typeof(currentValue) == typeof(targetValue) then
        return currentValue
    end

    return defaultValue
end

local function getDefaultEffectTemplate(effectName: string): Instance?
    local defaultConfiguration = getDefaultConfigurationFolder()
    if not defaultConfiguration then
        return nil
    end

    return defaultConfiguration:FindFirstChild(effectName)
end

local function getBaseWaterColor()
    local defaultConfiguration = ConfigurationsFolder:FindFirstChild(defaultConfigurationName, true)
    if defaultConfiguration then
        local attributeValue = defaultConfiguration:GetAttribute(WATER_COLOR_ATTRIBUTE)
        if typeof(attributeValue) == "Color3" then
            return attributeValue
        end
    end

    return initialTerrainWaterColor
end

local function stopActiveTweens()
    for _, tween in ipairs(activeTweens) do
        tween:Cancel()
    end
    table.clear(activeTweens)
end

local function tweenProperties(instance, goals, tweenInfo)
    if not next(goals) then
        return
    end

    local tween = TweenService:Create(instance, tweenInfo, goals)
    tween:Play()
    table.insert(activeTweens, tween)
    tween.Completed:Connect(function()
        local index = table.find(activeTweens, tween)
        if index then
            table.remove(activeTweens, index)
        end
    end)
end

local function buildTweenInfo(options)
    local transitionTime = math.max(0, options.transitionTime or 0)
    return TweenInfo.new(transitionTime, options.easingStyle, options.easingDirection)
end

local function collectLightingGoals(configuration, progress)
    local goals = {}

    for _, propertyName in ipairs(LIGHTING_PROPERTIES) do
        local attributeValue = configuration:GetAttribute(propertyName)
        if attributeValue ~= nil then
            local baseValue = getLightingBaseValue(propertyName, attributeValue)
            goals[propertyName] = blendValue(baseValue, attributeValue, progress)
        end
    end

    return goals
end

local function ensureEffect(effectTemplate)
    local existing = Lighting:FindFirstChild(effectTemplate.Name)
    if existing and existing.ClassName ~= effectTemplate.ClassName then
        pendingEffectRemovals[existing] = nil
        existing:Destroy()
        existing = nil
    end

    if not existing then
        existing = effectTemplate:Clone()
        existing.Parent = Lighting
    end

    pendingEffectRemovals[existing] = nil

    return existing
end

local function collectEffectGoals(effectTemplate, progress)
    local propertyList = EFFECT_PROPERTY_MAP[effectTemplate.ClassName]
    if not propertyList then
        return nil
    end

    local goals = {}
    local hasGoals = false
    local defaultTemplate = getDefaultEffectTemplate(effectTemplate.Name)
    for _, propertyName in ipairs(propertyList) do
        local success, value = pcall(function()
            return effectTemplate[propertyName]
        end)

        if success and value ~= nil then
            local baseValue

            if defaultTemplate then
                local ok, defaultValue = pcall(function()
                    return defaultTemplate[propertyName]
                end)

                if ok then
                    baseValue = defaultValue
                end
            end

            if baseValue == nil then
                local existing = Lighting:FindFirstChild(effectTemplate.Name)
                if existing then
                    local ok, existingValue = pcall(function()
                        return existing[propertyName]
                    end)

                    if ok then
                        baseValue = existingValue
                    end
                end
            end

            goals[propertyName] = blendValue(baseValue, value, progress)
            hasGoals = true
        end
    end

    if not hasGoals then
        return nil
    end

    return goals
end

local function updateEffect(effectTemplate, tweenInfo, progress)
    local target = ensureEffect(effectTemplate)
    local goals = collectEffectGoals(effectTemplate, progress)

    if goals then
        tweenProperties(target, goals, tweenInfo)
    else
        target:Destroy()
        target = effectTemplate:Clone()
        target.Parent = Lighting
    end

    activeEffects[target.Name] = target
    pendingEffectRemovals[target] = nil
end

local function disableEffect(effectInstance, tweenInfo)
    local propertyList = EFFECT_PROPERTY_MAP[effectInstance.ClassName]
    if propertyList then
        local goals = {}
        local hasNumericGoal = false

        for _, propertyName in ipairs(propertyList) do
            local value = effectInstance[propertyName]
            local valueType = typeof(value)

            if valueType == "number" then
                goals[propertyName] = 0
                hasNumericGoal = true
            elseif valueType == "Color3" then
                goals[propertyName] = Color3.new()
                hasNumericGoal = true
            end
        end

        if hasNumericGoal then
            tweenProperties(effectInstance, goals, tweenInfo)
            local token = {}
            pendingEffectRemovals[effectInstance] = token

            task.delay(tweenInfo.Time, function()
                if pendingEffectRemovals[effectInstance] ~= token then
                    return
                end

                pendingEffectRemovals[effectInstance] = nil

                if effectInstance.Parent and activeEffects[effectInstance.Name] ~= effectInstance then
                    effectInstance.Parent = nil
                    effectInstance:Destroy()
                end
            end)
            return
        end
    end

    pendingEffectRemovals[effectInstance] = nil

    effectInstance.Parent = nil
    effectInstance:Destroy()
end

local function applyConfiguration(configurationName, options)
    options = mergeOptions(options)
    local progress = options.transitionProgress

    local configuration = ConfigurationsFolder:FindFirstChild(configurationName, true)
    if not configuration then
        warn(("[LightingController] Unknown configuration '%s'"):format(configurationName))
        return
    end

    stopActiveTweens()

    local tweenInfo = buildTweenInfo(options)
    local lightingGoals = collectLightingGoals(configuration, progress)
    tweenProperties(Lighting, lightingGoals, tweenInfo)

    local fallbackWaterColor = getBaseWaterColor()
    local targetWaterColor = configuration:GetAttribute(WATER_COLOR_ATTRIBUTE)
    if typeof(targetWaterColor) ~= "Color3" then
        targetWaterColor = fallbackWaterColor
    end

    local blendedWaterColor = blendValue(fallbackWaterColor, targetWaterColor, progress)
    pendingWaveColor = blendedWaterColor
    local waveContainerInstance = getWaveContainer()
    if waveContainerInstance and blendedWaterColor then
        local currentColor = waveContainerInstance:GetAttribute("Color")
        if typeof(currentColor) ~= "Color3" or currentColor ~= blendedWaterColor then
            waveContainerInstance:SetAttribute("Color", blendedWaterColor)
        end
    end

    if blendedWaterColor and Terrain.WaterColor ~= blendedWaterColor then
        tweenProperties(Terrain, { WaterColor = blendedWaterColor }, tweenInfo)
    end

    local processedEffects = {}
    for _, child in ipairs(configuration:GetChildren()) do
        if child:IsA("PostEffect") or child:IsA("Atmosphere") or child:IsA("Sky") then
            updateEffect(child, tweenInfo, progress)
            processedEffects[child.Name] = true
        end
    end

    for effectName, effectInstance in pairs(activeEffects) do
        if not processedEffects[effectName] then
            activeEffects[effectName] = nil
            if effectInstance.Parent == Lighting then
                disableEffect(effectInstance, tweenInfo)
            end
        end
    end

end

local function onConfigurationEvent(configurationName, options)
    applyConfiguration(configurationName, options)
end

ConfigurationsFolder:GetAttributeChangedSignal("DefaultConfiguration"):Connect(function()
    defaultConfigurationName = readDefaultConfigurationName()
end)

if ConfigurationsFolder:FindFirstChild(defaultConfigurationName, true) then
    applyConfiguration(defaultConfigurationName, DEFAULT_TRANSITION)
else
    warn(("[LightingController] Default configuration '%s' does not exist."):format(defaultConfigurationName))
end

SetConfigurationEvent.OnClientEvent:Connect(onConfigurationEvent)
