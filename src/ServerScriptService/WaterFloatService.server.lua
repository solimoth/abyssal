--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local FLOAT_TAG = "WaterFloat"
local ATTACHMENT_NAME = "WaterFloatAttachment"
local FORCE_NAME = "WaterFloatForce"
local LINEAR_DAMPING = 3
local HORIZONTAL_DAMPING = 0.6

local floaters: {[BasePart]: {
        attachment: Attachment,
        createdAttachment: boolean,
        force: VectorForce,
        createdForce: boolean,
        ancestryConn: RBXScriptConnection?,
        weightConn: RBXScriptConnection?,
        weightSource: Instance?,
        weightAlpha: number,
        minImmersion: number,
}} = {}
local modelConnections: {[Instance]: {RBXScriptConnection, RBXScriptConnection}} = {}
local anchoredConnections: {[BasePart]: RBXScriptConnection} = {}

local function removeAnchoredListener(part: BasePart)
        local anchoredConn = anchoredConnections[part]
        if anchoredConn then
                anchoredConn:Disconnect()
                anchoredConnections[part] = nil
        end
end

local function cleanupPart(part: BasePart, keepAnchoredListener: boolean?)
        local data = floaters[part]
        if not data then
                if not keepAnchoredListener then
                        removeAnchoredListener(part)
                end
                return
        end

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

local MIN_FLOAT_WEIGHT = 1
local MAX_FLOAT_WEIGHT = 10
local DEFAULT_FLOAT_WEIGHT = MIN_FLOAT_WEIGHT
local HEAVY_DEPTH_MULTIPLIER = 1.5
local SURFACE_STIFFNESS = 0.65

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

local function setupPart(part: BasePart)
        if floaters[part] then
                return
        end

        if not anchoredConnections[part] then
                anchoredConnections[part] = part:GetPropertyChangedSignal("Anchored"):Connect(function()
                        if part.Anchored then
                                cleanupPart(part, true)
                        else
                                setupPart(part)
                        end
                end)
        end

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
        }

        updateFloatWeight(part)

end

local function onTagged(instance: Instance)
        if instance:IsA("BasePart") then
                setupPart(instance)
        elseif instance:IsA("Model") then
                for _, descendant in instance:GetDescendants() do
                        if descendant:IsA("BasePart") then
                                setupPart(descendant)
                        end
                end

                local addedConn = instance.DescendantAdded:Connect(function(descendant)
                        if descendant:IsA("BasePart") then
                                setupPart(descendant)
                        end
                end)

                local removingConn = instance.DescendantRemoving:Connect(function(descendant)
                        if descendant:IsA("BasePart") then
                                cleanupPart(descendant)
                                removeAnchoredListener(descendant)
                        end
                end)

                modelConnections[instance] = { addedConn, removingConn }
        end
end

local function onUntagged(instance: Instance)
        if instance:IsA("BasePart") then
                cleanupPart(instance)
                removeAnchoredListener(instance)
        elseif instance:IsA("Model") then
                local connections = modelConnections[instance]
                if connections then
                        for _, conn in ipairs(connections) do
                                conn:Disconnect()
                        end
                        modelConnections[instance] = nil
                end

                for part, _ in pairs(floaters) do
                        if part:IsDescendantOf(instance) then
                                cleanupPart(part)
                                removeAnchoredListener(part)
                        end
                end

                for part, _ in pairs(anchoredConnections) do
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

RunService.Heartbeat:Connect(function(_dt)
        for part, data in pairs(floaters) do
                if not part:IsDescendantOf(Workspace) then
                        cleanupPart(part)
                        continue
                elseif part.Anchored then
                        cleanupPart(part, true)
                        continue
                end

                local surfaceY = WaterPhysics.TryGetWaterSurface(part.Position)
                if not surfaceY then
                        data.force.Force = Vector3.zero
                        continue
                end

                local _, ratio = WaterPhysics.ComputeBuoyancyForce(part, surfaceY)
                if ratio <= 0 then
                        data.force.Force = Vector3.zero
                        continue
                end

                local mass = part:GetMass()
                local verticalVelocity = part.AssemblyLinearVelocity.Y
                local horizontalVelocity = Vector3.new(part.AssemblyLinearVelocity.X, 0, part.AssemblyLinearVelocity.Z)

                local halfHeight = part.Size.Y * 0.5
                local normalizedWeight = data.weightAlpha or 0
                local depth = surfaceY - part.Position.Y
                local targetDepth = halfHeight + part.Size.Y * normalizedWeight * HEAVY_DEPTH_MULTIPLIER
                local gravity = Workspace.Gravity
                local baseImmersion = math.max(data.minImmersion or 0, ratio)
                local upwardForce = mass * gravity * baseImmersion
                        + (depth - targetDepth) * mass * gravity * SURFACE_STIFFNESS
                if upwardForce < 0 then
                        upwardForce = 0
                end

                local dampingForce = Vector3.new(0, -verticalVelocity * mass * LINEAR_DAMPING, 0)
                local horizontalDamping = -horizontalVelocity * mass * HORIZONTAL_DAMPING

                data.force.Force = Vector3.new(0, upwardForce, 0) + dampingForce + horizontalDamping
        end
end)
