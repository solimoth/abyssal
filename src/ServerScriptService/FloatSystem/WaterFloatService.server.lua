--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)
local WaveRegistry = require(ReplicatedStorage.Modules.WaveRegistry)

local FLOAT_TAG = "WaterFloat"
local ATTACHMENT_NAME = "WaterFloatAttachment"
local FORCE_NAME = "WaterFloatForce"

local LINEAR_DAMPING = 3
local HORIZONTAL_DAMPING = 0.6
local WAVE_SURGE_RESPONSE = 1.75
local SURFACE_RESPONSE = 0.85
local HEAVY_DEPTH_MULTIPLIER = 0.75

local MIN_FLOAT_WEIGHT = 1
local MAX_FLOAT_WEIGHT = 10
local DEFAULT_FLOAT_WEIGHT = MIN_FLOAT_WEIGHT

export type FloatData = {
    attachment: Attachment?,
    createdAttachment: boolean,
    force: VectorForce?,
    createdForce: boolean,
    ancestryConn: RBXScriptConnection?,
    weightConn: RBXScriptConnection?,
    weightSource: Instance?,
    weightAlpha: number,
    minImmersion: number,
    lastDisplacement: Vector3?,
}

local floaters: { [BasePart]: FloatData } = {}
local modelConnections: { [Instance]: { RBXScriptConnection } } = {}
local anchoredConnections: { [BasePart]: RBXScriptConnection } = {}

local setupPart: (BasePart) -> ()

local function removeAnchoredListener(part: BasePart)
    local anchoredConn = anchoredConnections[part]
    if anchoredConn then
        anchoredConn:Disconnect()
        anchoredConnections[part] = nil
    end
end

local function cleanupPart(part: BasePart, keepAnchoredListener: boolean?)
    local data = floaters[part]
    if data then
        if data.ancestryConn then
            data.ancestryConn:Disconnect()
        end
        if data.weightConn then
            data.weightConn:Disconnect()
        end
        if data.force and data.force.Parent then
            data.force.Force = Vector3.zero
            if data.createdForce then
                data.force:Destroy()
            end
        end
        if data.attachment and data.createdAttachment and data.attachment.Parent then
            data.attachment:Destroy()
        end
        floaters[part] = nil
    end

    if not keepAnchoredListener then
        removeAnchoredListener(part)
    end
end

local function createVectorForce(part: BasePart)
    local attachment = part:FindFirstChild(ATTACHMENT_NAME)
    local createdAttachment = false
    if not attachment then
        attachment = Instance.new("Attachment")
        attachment.Name = ATTACHMENT_NAME
        attachment.Parent = part
        createdAttachment = true
    end

    local force = attachment:FindFirstChild(FORCE_NAME)
    local createdForce = false
    if not force then
        force = Instance.new("VectorForce")
        force.Name = FORCE_NAME
        force.RelativeTo = Enum.ActuatorRelativeTo.World
        force.ApplyAtCenterOfMass = true
        force.Attachment0 = attachment
        force.Parent = attachment
        createdForce = true
    end

    return attachment, force, createdAttachment, createdForce
end

local function findFloatWeightSource(part: BasePart)
    local current: Instance? = part
    while current do
        local attributeValue = current:GetAttribute("FloatWeight")
        if typeof(attributeValue) == "number" then
            local clamped = math.clamp(attributeValue, MIN_FLOAT_WEIGHT, MAX_FLOAT_WEIGHT)
            return clamped, current
        end
        current = current.Parent
    end

    return DEFAULT_FLOAT_WEIGHT, nil
end

local function updateFloatWeight(part: BasePart)
    local data = floaters[part]
    if not data then
        return
    end

    local weight, source = findFloatWeightSource(part)
    local previousSource = data.weightSource

    if previousSource ~= source then
        if data.weightConn then
            data.weightConn:Disconnect()
            data.weightConn = nil
        end

        data.weightSource = source

        if source then
            data.weightConn = source:GetAttributeChangedSignal("FloatWeight"):Connect(function()
                updateFloatWeight(part)
            end)
        end
    end

    local alpha = (weight - MIN_FLOAT_WEIGHT) / (MAX_FLOAT_WEIGHT - MIN_FLOAT_WEIGHT)
    data.weightAlpha = alpha
    data.minImmersion = 1 - alpha
end

local function setupAnchoredListener(part: BasePart)
    if anchoredConnections[part] then
        return
    end

    anchoredConnections[part] = part:GetPropertyChangedSignal("Anchored"):Connect(function()
        if part.Anchored then
            cleanupPart(part, true)
        else
            updateFloatWeight(part)
            setupPart(part)
        end
    end)
end

setupPart = function(part: BasePart)
    if floaters[part] then
        return
    end

    setupAnchoredListener(part)

    if part.Anchored then
        return
    end

    local attachment, force, createdAttachment, createdForce = createVectorForce(part)

    floaters[part] = {
        attachment = attachment,
        createdAttachment = createdAttachment,
        force = force,
        createdForce = createdForce,
        ancestryConn = part.AncestryChanged:Connect(function(_, parent)
            if not parent then
                cleanupPart(part)
                return
            end
            updateFloatWeight(part)
        end),
        weightConn = nil,
        weightSource = nil,
        weightAlpha = 0,
        minImmersion = 1,
        lastDisplacement = nil,
    }

    updateFloatWeight(part)
end

local function setupModel(model: Model)
    for _, descendant in model:GetDescendants() do
        if descendant:IsA("BasePart") then
            setupPart(descendant)
        end
    end

    local addedConn = model.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            setupPart(descendant)
        end
    end)

    local removingConn = model.DescendantRemoving:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            cleanupPart(descendant)
            removeAnchoredListener(descendant)
        end
    end)

    modelConnections[model] = { addedConn, removingConn }
end

local function onTagged(instance: Instance)
    if instance:IsA("BasePart") then
        setupPart(instance)
    elseif instance:IsA("Model") then
        setupModel(instance)
    end
end

local function onUntagged(instance: Instance)
    if instance:IsA("BasePart") then
        cleanupPart(instance)
        removeAnchoredListener(instance)
    elseif instance:IsA("Model") then
        local connections = modelConnections[instance]
        if connections then
            for _, connection in ipairs(connections) do
                connection:Disconnect()
            end
            modelConnections[instance] = nil
        end

        for part in pairs(floaters) do
            if part:IsDescendantOf(instance) then
                cleanupPart(part)
                removeAnchoredListener(part)
            end
        end

        for part in pairs(anchoredConnections) do
            if part:IsDescendantOf(instance) then
                removeAnchoredListener(part)
            end
        end
    end
end

for _, instance in ipairs(CollectionService:GetTagged(FLOAT_TAG)) do
    onTagged(instance)
end

CollectionService:GetInstanceAddedSignal(FLOAT_TAG):Connect(onTagged)
CollectionService:GetInstanceRemovedSignal(FLOAT_TAG):Connect(onUntagged)

local function sampleWaterSurface(part: BasePart)
    local position = part.Position
    local surfaceSample = WaveRegistry.SampleSurface(position)
    if surfaceSample then
        return surfaceSample, surfaceSample.Height
    end

    local surfaceY = WaterPhysics.TryGetWaterSurface(position)
    if not surfaceY then
        return nil, nil
    end

    return nil, surfaceY
end

RunService.Heartbeat:Connect(function(dt)
    for part, data in pairs(floaters) do
        if not part:IsDescendantOf(Workspace) then
            cleanupPart(part)
            continue
        elseif part.Anchored then
            cleanupPart(part, true)
            continue
        end

        local surfaceSample, surfaceY = sampleWaterSurface(part)
        if not surfaceY then
            if data.force then
                data.force.Force = Vector3.zero
            end
            continue
        end

        local buoyantForce, ratio = WaterPhysics.ComputeBuoyancyForce(part, surfaceY)
        if ratio <= 0 and surfaceY < part.Position.Y then
            if data.force then
                data.force.Force = Vector3.zero
            end
            data.lastDisplacement = nil
            continue
        end

        local halfHeight = part.Size.Y * 0.5
        local bottomY = part.Position.Y - halfHeight
        local depth = surfaceY - bottomY
        local targetDepth = halfHeight + part.Size.Y * data.weightAlpha * HEAVY_DEPTH_MULTIPLIER

        local gravity = Workspace.Gravity
        local mass = part.AssemblyMass
        local verticalVelocity = part.AssemblyLinearVelocity.Y
        local horizontalVelocity = Vector3.new(part.AssemblyLinearVelocity.X, 0, part.AssemblyLinearVelocity.Z)

        local targetImmersion = math.max(data.minImmersion, ratio)
        local depthError = targetDepth - depth
        local correctiveForce = depthError * SURFACE_RESPONSE * mass * gravity
        local dampingForceY = -verticalVelocity * mass * LINEAR_DAMPING
        local verticalForce = (targetImmersion * mass * gravity) + correctiveForce + dampingForceY
        if verticalForce < 0 then
            verticalForce = 0
        end

        local horizontalForce = -horizontalVelocity * mass * HORIZONTAL_DAMPING
        if surfaceSample then
            local displacement = Vector3.new(surfaceSample.Displacement.X, 0, surfaceSample.Displacement.Z)
            local previousDisplacement = data.lastDisplacement or displacement
            local displacementVelocity = (displacement - previousDisplacement) / math.max(dt, 1e-3)
            horizontalForce += displacementVelocity * mass * WAVE_SURGE_RESPONSE
            data.lastDisplacement = displacement
        else
            data.lastDisplacement = nil
        end

        if data.force then
            data.force.Force = Vector3.new(horizontalForce.X, verticalForce, horizontalForce.Z) + buoyantForce
        end
    end
end)
