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
    "ClockTime",
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
local WaterColorController = require(ReplicatedStorage.Modules.WaterColorController)

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
    }
end

local function getBaseWaterColor()
    local defaultConfiguration = ConfigurationsFolder:FindFirstChild(defaultConfigurationName)
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

local function collectLightingGoals(configuration)
    local goals = {}

    for _, propertyName in ipairs(LIGHTING_PROPERTIES) do
        local attributeValue = configuration:GetAttribute(propertyName)
        if attributeValue ~= nil then
            goals[propertyName] = attributeValue
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

local function collectEffectGoals(effectTemplate)
    local propertyList = EFFECT_PROPERTY_MAP[effectTemplate.ClassName]
    if not propertyList then
        return nil
    end

    local goals = {}
    for _, propertyName in ipairs(propertyList) do
        local success, value = pcall(function()
            return effectTemplate[propertyName]
        end)

        if success and value ~= nil then
            goals[propertyName] = value
        end
    end

    return goals
end

local function updateEffect(effectTemplate, tweenInfo)
    local target = ensureEffect(effectTemplate)
    local goals = collectEffectGoals(effectTemplate)

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

    local configuration = ConfigurationsFolder:FindFirstChild(configurationName)
    if not configuration then
        warn(("[LightingController] Unknown configuration '%s'"):format(configurationName))
        return
    end

    stopActiveTweens()

    local tweenInfo = buildTweenInfo(options)
    local lightingGoals = collectLightingGoals(configuration)
    tweenProperties(Lighting, lightingGoals, tweenInfo)

    local fallbackWaterColor = getBaseWaterColor()
    local targetWaterColor = configuration:GetAttribute(WATER_COLOR_ATTRIBUTE)
    if typeof(targetWaterColor) ~= "Color3" then
        targetWaterColor = fallbackWaterColor
    end

    WaterColorController.SetOverrideColor(targetWaterColor)

    if targetWaterColor and Terrain.WaterColor ~= targetWaterColor then
        tweenProperties(Terrain, { WaterColor = targetWaterColor }, tweenInfo)
    end

    local processedEffects = {}
    for _, child in ipairs(configuration:GetChildren()) do
        if child:IsA("PostEffect") or child:IsA("Atmosphere") or child:IsA("Sky") then
            updateEffect(child, tweenInfo)
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

if ConfigurationsFolder:FindFirstChild(defaultConfigurationName) then
    applyConfiguration(defaultConfigurationName, DEFAULT_TRANSITION)
else
    warn(("[LightingController] Default configuration '%s' does not exist."):format(defaultConfigurationName))
end

SetConfigurationEvent.OnClientEvent:Connect(onConfigurationEvent)
