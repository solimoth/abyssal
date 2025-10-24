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
    EnableBobbing = true,
    BobbingFrequency = 2,
    BobbingAmplitude = 0.1,
    LockYawToInitial = true,
    YawMaxTorque = 5000,
    YawResponsiveness = 2000,
    YawDamping = 200,
    PreventYawSpin = true,
    AngularDamping = 2,
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
    horizontalForward: Vector3?,
    tagged: boolean,
    part: BasePart?,
    lastTargetPosition: Vector3?,
    lastMaxForce: Vector3?,
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

local trackedParts: { [Instance]: PartData } = setmetatable({}, { __mode = "k" })
local partLookup: { [BasePart]: Instance } = setmetatable({}, { __mode = "k" })
local sourceRegistry: { [Instance]: SourceInfo } = setmetatable({}, { __mode = "k" })
local monitorRegistry: { [Instance]: MonitorInfo } = setmetatable({}, { __mode = "k" })
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

local function resolveBasePart(part: Instance, data: PartData?): BasePart?
    if part:IsA("BasePart") then
        return part
    end

    if data and data.part then
        return data.part
    end

    local parent = part.Parent
    if parent and parent:IsA("BasePart") then
        return parent
    end

    return nil
end

local function computeHorizontalForward(part: BasePart): Vector3
    local forward = part.CFrame.LookVector
    local horizontal = Vector3.new(forward.X, 0, forward.Z)

    if horizontal.Magnitude < 1e-4 then
        local right = part.CFrame.RightVector
        horizontal = Vector3.new(right.X, 0, right.Z)
        if horizontal.Magnitude < 1e-4 then
            horizontal = Vector3.new(0, 0, -1)
        end
    end

    return horizontal.Unit
end

local function findTrackedEntryForBasePart(basePart: BasePart): (Instance?, PartData?)
    for trackedPart, trackedData in pairs(trackedParts) do
        local resolved = resolveBasePart(trackedPart, trackedData)
        if resolved == basePart then
            return trackedPart, trackedData
        end
    end

    return nil, nil
end

local function cleanupPart(part: Instance)
    local data = trackedParts[part]

    if not data and part:IsA("BasePart") then
        local lookup = partLookup[part]
        if lookup then
            local lookupData = trackedParts[lookup]
            if lookupData then
                part = lookup
                data = lookupData
            else
                partLookup[part] = nil
            end
        end
    end

    if not data and part:IsA("BasePart") then
        local bodyPosition = part:FindFirstChild("FloatingBodyPosition")
        if bodyPosition and bodyPosition:IsA("BodyPosition") then
            local bodyData = trackedParts[bodyPosition]
            if bodyData then
                part = bodyPosition
                data = bodyData
            end
        end
    end

    if not data and part:IsA("BasePart") then
        local trackedPart, trackedData = findTrackedEntryForBasePart(part)
        if trackedPart and trackedData then
            part = trackedPart
            data = trackedData
        end
    end

    if not data then
        return
    end

    local basePart = resolveBasePart(part, data)

    if data.bodyPosition then
        data.bodyPosition:Destroy()
        data.bodyPosition = nil
        data.lastTargetPosition = nil
        data.lastMaxForce = nil
    end

    if data.bodyGyro then
        data.bodyGyro:Destroy()
        data.bodyGyro = nil
    end

    if basePart and data.tagged then
        CollectionService:RemoveTag(basePart, FLOAT_TAG)
    end

    trackedParts[part] = nil

    if basePart then
        partLookup[basePart] = nil
    end

    if basePart and basePart ~= part then
        trackedParts[basePart] = nil
    end
end

local function removeBodyMovers(part: BasePart, data: PartData)
    if data.bodyPosition then
        data.bodyPosition:Destroy()
        data.bodyPosition = nil
        data.lastTargetPosition = nil
        data.lastMaxForce = nil
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
        data.lastMaxForce = config.MaxForce
        data.lastTargetPosition = nil
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

    local trackedPart: Instance = partLookup[part] or part
    local data = trackedParts[trackedPart]

    if not data and trackedPart ~= part then
        partLookup[part] = nil
        trackedPart = part
        data = trackedParts[part]
    end

    if not data then
        local bodyPosition = part:FindFirstChild("FloatingBodyPosition")
        if bodyPosition and bodyPosition:IsA("BodyPosition") then
            local bodyData = trackedParts[bodyPosition]
            if bodyData then
                trackedPart = bodyPosition
                data = bodyData
                trackedParts[bodyPosition] = nil
            end
        end
    end

    if not data and partLookup[part] then
        local existingPart, existingData = findTrackedEntryForBasePart(part)
        if existingPart and existingData then
            trackedParts[existingPart] = nil
            data = existingData
            trackedPart = existingPart
        end
    end

    if not data then
        local axis = config.RotationAxis.Magnitude > 0 and config.RotationAxis.Unit or Vector3.new(0, 1, 0)
        local horizontalForward = computeHorizontalForward(part)

        data = {
            sources = {},
            bodyPosition = nil,
            bodyGyro = nil,
            waveOffset = math.random() * math.pi * 2,
            rotationAngle = 0,
            rotationAxis = axis,
            tagged = false,
            part = part,
            lastTargetPosition = nil,
            lastMaxForce = nil,
            horizontalForward = horizontalForward,
        }
        trackedParts[part] = data
    elseif trackedPart ~= part then
        trackedParts[trackedPart] = nil
        trackedParts[part] = data
    end

    data.part = part

    if not data.horizontalForward then
        data.horizontalForward = computeHorizontalForward(part)
    end

    partLookup[part] = part

    data.sources[source] = true

    if not data.tagged then
        CollectionService:AddTag(part, FLOAT_TAG)
        data.tagged = true
    end

    debugPrint(string.format("Registered %s for floating", part:GetFullName()))
end

local function unregisterPart(part: BasePart, source: Instance)
    local trackedPart: Instance = partLookup[part] or part
    local data = trackedParts[trackedPart]

    if not data and trackedPart ~= part then
        partLookup[part] = nil
        trackedPart = part
        data = trackedParts[part]
    end

    if not data then
        local bodyPosition = part:FindFirstChild("FloatingBodyPosition")
        if bodyPosition and bodyPosition:IsA("BodyPosition") then
            local bodyData = trackedParts[bodyPosition]
            if bodyData then
                trackedPart = bodyPosition
                data = bodyData
            end
        end
    end

    if not data and partLookup[part] then
        local existingPart, existingData = findTrackedEntryForBasePart(part)
        if existingPart and existingData then
            trackedPart = existingPart
            data = existingData
        end
    end

    if not data then
        return
    end

    data.sources[source] = nil

    if next(data.sources) then
        return
    end

    cleanupPart(trackedPart)
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
    if config.EnableRotation then
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
        return
    end

    if data.bodyGyro and not config.LockYawToInitial then
        data.bodyGyro:Destroy()
        data.bodyGyro = nil
    end

    if config.LockYawToInitial and config.YawMaxTorque > 0 then
        local bodyGyro = ensureBodyGyro(part, data)
        bodyGyro.MaxTorque = Vector3.new(0, config.YawMaxTorque, 0)
        bodyGyro.P = config.YawResponsiveness
        bodyGyro.D = config.YawDamping

        if not data.horizontalForward then
            data.horizontalForward = computeHorizontalForward(part)
        end

        local forward = data.horizontalForward or Vector3.new(0, 0, -1)
        local targetPosition = part.Position + forward
        bodyGyro.CFrame = CFrame.lookAt(part.Position, targetPosition, Vector3.yAxis)
    elseif data.bodyGyro then
        data.bodyGyro:Destroy()
        data.bodyGyro = nil
    end

    local angularVelocity = part.AssemblyAngularVelocity
    local adjusted = false

    if config.PreventYawSpin and math.abs(angularVelocity.Y) > 1e-4 then
        angularVelocity = Vector3.new(angularVelocity.X, 0, angularVelocity.Z)
        adjusted = true
    end

    if config.AngularDamping > 0 then
        local damping = math.clamp(1 - (config.AngularDamping * dt), 0, 1)
        if damping < 1 then
            angularVelocity = Vector3.new(angularVelocity.X * damping, angularVelocity.Y, angularVelocity.Z * damping)
            adjusted = true
        end
    end

    if adjusted then
        part.AssemblyAngularVelocity = angularVelocity
    end
end

local function vectorsDiffer(a: Vector3?, b: Vector3?): boolean
    if a == nil or b == nil then
        return true
    end

    local delta = a - b
    return math.abs(delta.X) > 1e-4 or math.abs(delta.Y) > 1e-4 or math.abs(delta.Z) > 1e-4
end

local function applyForces(part: BasePart, data: PartData, dt: number, now: number)
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
    local maxForce = config.MaxForce
    if vectorsDiffer(data.lastMaxForce, maxForce) then
        bodyPosition.MaxForce = maxForce
        data.lastMaxForce = maxForce
    end

    local basePosition = Vector3.new(part.Position.X, surfaceY + config.OffsetY, part.Position.Z)

    if config.EnableBobbing then
        if config.BobbingAmplitude ~= 0 and config.BobbingFrequency ~= 0 then
            local bobOffset = math.sin((now * config.BobbingFrequency) + data.waveOffset) * config.BobbingAmplitude
            if bobOffset ~= 0 then
                basePosition += Vector3.new(0, bobOffset, 0)
            end
        end
    end

    if config.EnableBuoyancyVariation then
        if config.BuoyancyVariationAmount ~= 0 then
            local variation = math.sin((now + data.waveOffset) * 1.7) * config.BuoyancyVariationAmount
            if variation ~= 0 then
                basePosition += Vector3.new(0, variation, 0)
            end
        end
    end

    if vectorsDiffer(data.lastTargetPosition, basePosition) then
        bodyPosition.Position = basePosition
        data.lastTargetPosition = basePosition
    end

    local velocity = part.AssemblyLinearVelocity

    if config.EnableCustomGravity then
        velocity = velocity + (config.CustomGravity * dt)
    end

    updateRotation(part, data, dt)

    if config.DampingFactor > 0 then
        local damping = math.clamp(1 - config.DampingFactor, 0, 1)
        velocity = velocity * damping
    end

    if config.EnableDrag then
        local drag = math.clamp(1 - config.DragCoefficient, 0, 1)
        velocity = velocity * drag
    end

    part.AssemblyLinearVelocity = velocity
end

local function heartbeatUpdate(dt: number)
    local now = Workspace:GetServerTimeNow()
    for part, data in pairs(trackedParts) do
        local basePart = resolveBasePart(part, data)

        if not basePart or not basePart.Parent or not basePart:IsDescendantOf(Workspace) then
            cleanupPart(part)
            continue
        end

        if not next(data.sources) then
            cleanupPart(part)
            continue
        end

        data.part = basePart
        partLookup[basePart] = part

        if basePart.Anchored then
            removeBodyMovers(basePart, data)
            continue
        end

        applyForces(basePart, data, dt, now)
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
