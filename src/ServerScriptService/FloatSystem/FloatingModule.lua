--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local FloatingModule = {}

local config = {
    MaxForce = Vector3.new(math.huge, math.huge, math.huge),
    OffsetY = 0.05,
    EnableRotation = false,
    RotationSpeed = 0.5,
    DebugMode = false,
    EnableToolFloating = true,
    EnablePartFloating = true,
    BuoyancyForce = Vector3.new(0, 100, 0),
    RotationAxis = Vector3.new(0, 1, 0),
    MaxRotationSpeed = 1,
    DampingFactor = 0,
    EnableWaveEffect = true,
    WaveFrequency = 2,
    WaveAmplitude = 0.1,
    EnableDrag = false,
    DragCoefficient = 0.05,
    EnableBuoyancyVariation = false,
    BuoyancyVariationAmount = 0.2,
    EnableCollisionDetection = false,
    CollisionForceMultiplier = 0.5,
    EnableCustomGravity = false,
    CustomGravity = Vector3.new(0, 0, 0),
    ActivationPadding = 0.5,
}

type PartData = {
    sources: { [Instance]: boolean },
    bodyPosition: BodyPosition?,
    bodyGyro: BodyGyro?,
    waveOffset: number,
    rotationAngle: number,
    rotationAxis: Vector3,
    tagged: boolean,
}

type SourceInfo = {
    parts: { [BasePart]: boolean },
    connections: { RBXScriptConnection },
    handle: BasePart?,
}

type MonitorInfo = {
    attributeConn: RBXScriptConnection?,
    ancestryConn: RBXScriptConnection?,
    destroyingConn: RBXScriptConnection?,
}

local trackedParts: { [BasePart]: PartData } = {}
local sourceRegistry: { [Instance]: SourceInfo } = {}
local monitorRegistry: { [Instance]: MonitorInfo } = {}
local initialized = false
local heartbeatConn: RBXScriptConnection?

local FLOAT_TAG = "WaterFloat"

local function debugPrint(message: string)
    if config.DebugMode then
        print("[FloatingModule]", message)
    end
end

function FloatingModule.SetDebugMode(enableDebug: boolean)
    config.DebugMode = enableDebug
    debugPrint("Debug mode " .. (enableDebug and "enabled" or "disabled"))
end

function FloatingModule.ToggleToolFloating(enable: boolean)
    config.EnableToolFloating = enable
    debugPrint("Tool floating " .. (enable and "enabled" or "disabled"))
end

function FloatingModule.TogglePartFloating(enable: boolean)
    config.EnablePartFloating = enable
    debugPrint("Part floating " .. (enable and "enabled" or "disabled"))
end

local function cleanupPart(part: BasePart)
    local data = trackedParts[part]
    if not data then
        return
    end

    if data.bodyPosition then
        data.bodyPosition:Destroy()
    end

    if data.bodyGyro then
        data.bodyGyro:Destroy()
    end

    if data.tagged then
        CollectionService:RemoveTag(part, FLOAT_TAG)
    end

    trackedParts[part] = nil
end

local function removeBodyMovers(part: BasePart, data: PartData)
    if data.bodyPosition then
        data.bodyPosition:Destroy()
        data.bodyPosition = nil
    end

    if data.bodyGyro then
        data.bodyGyro:Destroy()
        data.bodyGyro = nil
    end
end

local function ensureBodyPosition(part: BasePart, data: PartData): BodyPosition
    local bodyPosition = data.bodyPosition
    if not bodyPosition then
        bodyPosition = Instance.new("BodyPosition")
        bodyPosition.Name = "FloatingBodyPosition"
        bodyPosition.MaxForce = config.MaxForce
        bodyPosition.Parent = part
        data.bodyPosition = bodyPosition
    end

    return bodyPosition
end

local function ensureBodyGyro(part: BasePart, data: PartData): BodyGyro
    local bodyGyro = data.bodyGyro
    if not bodyGyro then
        bodyGyro = Instance.new("BodyGyro")
        bodyGyro.Name = "FloatingBodyGyro"
        bodyGyro.MaxTorque = config.MaxForce
        bodyGyro.Parent = part
        data.bodyGyro = bodyGyro
    end

    return bodyGyro
end

local function registerPart(part: BasePart, source: Instance)
    if not part:IsDescendantOf(Workspace) then
        return
    end

    local data = trackedParts[part]
    if not data then
        local axis = config.RotationAxis.Magnitude > 0 and config.RotationAxis.Unit or Vector3.new(0, 1, 0)
        data = {
            sources = {},
            bodyPosition = nil,
            bodyGyro = nil,
            waveOffset = math.random() * math.pi * 2,
            rotationAngle = 0,
            rotationAxis = axis,
            tagged = false,
        }
        trackedParts[part] = data
    end

    data.sources[source] = true

    if not data.tagged then
        CollectionService:AddTag(part, FLOAT_TAG)
        data.tagged = true
    end

    debugPrint(string.format("Registered %s for floating", part:GetFullName()))
end

local function unregisterPart(part: BasePart, source: Instance)
    local data = trackedParts[part]
    if not data then
        return
    end

    data.sources[source] = nil

    if next(data.sources) then
        return
    end

    cleanupPart(part)
end

local function gatherModelParts(model: Model)
    local parts: { BasePart } = {}
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            parts[#parts + 1] = descendant
        end
    end
    return parts
end

local function shouldRegisterInstance(instance: Instance): boolean
    if instance:IsA("BasePart") then
        return config.EnablePartFloating
    elseif instance:IsA("Model") then
        return config.EnablePartFloating
    elseif instance:IsA("Tool") then
        return config.EnableToolFloating
    end
    return false
end

local function isFloatable(instance: Instance): boolean
    return instance:GetAttribute("ObjectFloatable") == true
end

local function teardownSource(instance: Instance)
    local info = sourceRegistry[instance]
    if not info then
        return
    end

    for part in pairs(info.parts) do
        unregisterPart(part, instance)
    end

    for _, conn in ipairs(info.connections) do
        conn:Disconnect()
    end

    sourceRegistry[instance] = nil
end

local function setupModelSource(model: Model, info: SourceInfo)
    for _, part in ipairs(gatherModelParts(model)) do
        info.parts[part] = true
        registerPart(part, model)
    end

    info.connections[#info.connections + 1] = model.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            info.parts[descendant] = true
            registerPart(descendant, model)
        end
    end)

    info.connections[#info.connections + 1] = model.DescendantRemoving:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            info.parts[descendant] = nil
            unregisterPart(descendant, model)
        end
    end)
end

local function setupToolSource(tool: Tool, info: SourceInfo)
    local function registerHandle(handle: BasePart)
        info.handle = handle
        info.parts[handle] = true
        registerPart(handle, tool)
    end

    local handle = tool:FindFirstChild("Handle")
    if handle and handle:IsA("BasePart") then
        registerHandle(handle)
    end

    info.connections[#info.connections + 1] = tool.ChildAdded:Connect(function(child)
        if child.Name == "Handle" and child:IsA("BasePart") then
            registerHandle(child)
        end
    end)

    info.connections[#info.connections + 1] = tool.ChildRemoved:Connect(function(child)
        if child == info.handle then
            info.parts[child] = nil
            unregisterPart(child, tool)
            info.handle = nil
        end
    end)
end

local function setupSource(instance: Instance)
    if sourceRegistry[instance] then
        return
    end

    if not shouldRegisterInstance(instance) then
        return
    end

    local info: SourceInfo = {
        parts = {},
        connections = {},
        handle = nil,
    }
    sourceRegistry[instance] = info

    if instance:IsA("Model") then
        setupModelSource(instance, info)
    elseif instance:IsA("Tool") then
        setupToolSource(instance, info)
    elseif instance:IsA("BasePart") then
        info.parts[instance] = true
        registerPart(instance, instance)
    end
end

local function disconnectMonitor(instance: Instance)
    local monitor = monitorRegistry[instance]
    if not monitor then
        return
    end

    if monitor.attributeConn then
        monitor.attributeConn:Disconnect()
    end
    if monitor.ancestryConn then
        monitor.ancestryConn:Disconnect()
    end
    if monitor.destroyingConn then
        monitor.destroyingConn:Disconnect()
    end

    monitorRegistry[instance] = nil
end

local function monitorInstance(instance: Instance)
    if monitorRegistry[instance] then
        return
    end

    if not (instance:IsA("BasePart") or instance:IsA("Model") or instance:IsA("Tool")) then
        return
    end

    local monitorInfo: MonitorInfo = {}
    monitorRegistry[instance] = monitorInfo

    local function handleAttribute()
        if isFloatable(instance) then
            setupSource(instance)
        else
            teardownSource(instance)
        end
    end

    monitorInfo.attributeConn = instance:GetAttributeChangedSignal("ObjectFloatable"):Connect(handleAttribute)

    monitorInfo.ancestryConn = instance.AncestryChanged:Connect(function(_, parent)
        if not parent then
            teardownSource(instance)
            disconnectMonitor(instance)
        end
    end)

    monitorInfo.destroyingConn = instance.Destroying:Connect(function()
        teardownSource(instance)
        disconnectMonitor(instance)
    end)

    handleAttribute()
end

local function updateRotation(part: BasePart, data: PartData, dt: number)
    if not config.EnableRotation then
        if data.bodyGyro then
            data.bodyGyro:Destroy()
            data.bodyGyro = nil
        end
        return
    end

    local bodyGyro = ensureBodyGyro(part, data)
    local maxSpeed = math.max(config.MaxRotationSpeed, 0)
    local speed = config.RotationSpeed
    if maxSpeed > 0 then
        speed = math.clamp(speed, -maxSpeed, maxSpeed)
    end
    data.rotationAngle += math.rad(speed) * dt
    local rotation = CFrame.fromAxisAngle(data.rotationAxis, data.rotationAngle)
    bodyGyro.MaxTorque = config.MaxForce
    bodyGyro.CFrame = rotation
end

local function applyForces(part: BasePart, data: PartData, dt: number)
    local surfaceY = WaterPhysics.TryGetWaterSurface(part.Position)
    if not surfaceY then
        removeBodyMovers(part, data)
        return
    end

    local halfHeight = part.Size.Y * 0.5
    local bottomY = part.Position.Y - halfHeight
    if bottomY > surfaceY + config.ActivationPadding then
        removeBodyMovers(part, data)
        return
    end

    local bodyPosition = ensureBodyPosition(part, data)
    bodyPosition.MaxForce = config.MaxForce

    local now = Workspace:GetServerTimeNow()
    local basePosition = Vector3.new(part.Position.X, surfaceY + config.OffsetY, part.Position.Z)

    if config.EnableWaveEffect then
        local waveOffset = math.sin((now * config.WaveFrequency) + data.waveOffset) * config.WaveAmplitude
        basePosition += Vector3.new(0, waveOffset, 0)
    end

    if config.EnableBuoyancyVariation then
        local variation = math.sin((now + data.waveOffset) * 1.7) * config.BuoyancyVariationAmount
        basePosition += Vector3.new(0, variation, 0)
    end

    bodyPosition.Position = basePosition

    if config.EnableCustomGravity then
        bodyPosition.Velocity = config.CustomGravity
    else
        bodyPosition.Velocity = Vector3.zero
    end

    updateRotation(part, data, dt)

    if config.DampingFactor > 0 then
        local damping = math.clamp(1 - config.DampingFactor, 0, 1)
        part.Velocity = part.Velocity * damping
    end

    if config.EnableDrag then
        local drag = math.clamp(1 - config.DragCoefficient, 0, 1)
        part.Velocity = part.Velocity * drag
    end
end

local function heartbeatUpdate(dt: number)
    for part, data in pairs(trackedParts) do
        if not part.Parent or not part:IsDescendantOf(Workspace) then
            cleanupPart(part)
            continue
        end

        if not next(data.sources) then
            cleanupPart(part)
            continue
        end

        if part.Anchored then
            removeBodyMovers(part, data)
            continue
        end

        applyForces(part, data, dt)
    end
end

function FloatingModule.Initialize()
    if initialized then
        return
    end

    initialized = true

    for _, descendant in ipairs(Workspace:GetDescendants()) do
        monitorInstance(descendant)
    end

    Workspace.DescendantAdded:Connect(monitorInstance)

    heartbeatConn = RunService.Heartbeat:Connect(heartbeatUpdate)

    debugPrint("FloatingModule initialized")
end

return FloatingModule
