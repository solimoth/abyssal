--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local FloatingModule = {}

type Player = Players.Player

local config = {
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
	HorizontalMaxForce = 2500,
	VerticalMaxForce = math.huge,
        EnableLOD = true,
        LODActivationRadius = 160,
        LODDeactivationRadius = 210,
        LODCheckInterval = 0.35,
        LODSleepDropDistance = 0.5,
        PositionUpdateThreshold = 0.015,
        VelocityUpdateThreshold = 0.01,
        EnableNetworkOwnershipManagement = true,
        NetworkOwnershipCheckInterval = 0.5,
}

type PartData = {
        sources: { [Instance]: boolean },
        bodyPosition: BodyPosition?,
        alignOrientation: AlignOrientation?,
        orientationAttachment: Attachment?,
        waveOffset: number,
        rotationAngle: number,
        rotationAxis: Vector3,
        horizontalForward: Vector3?,
        tagged: boolean,
        part: BasePart?,
        lastTargetPosition: Vector3?,
        lastMaxForce: Vector3?,
        isActive: boolean?,
        nextDistanceCheck: number?,
        currentOwner: Player?,
        nextOwnershipCheck: number?,
        preSleepAnchored: boolean?,
        preSleepCanCollide: boolean?,
        lodSleeping: boolean?,
        hasActivated: boolean?,
        pendingVelocityDelta: Vector3?,
        pendingVelocityBase: Vector3?,
        pendingVelocityMagnitude: number?,
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
type PlayerInfo = { player: Player, position: Vector3 }
local playerInfoBuffer: { PlayerInfo } = {}
local ZERO_VECTOR = Vector3.new(0, 0, 0)

local function getBodyPositionMaxForce(): Vector3
	local horizontal = math.max(config.HorizontalMaxForce, 0)
	local vertical = math.max(config.VerticalMaxForce, 0)
	return Vector3.new(horizontal, vertical, horizontal)
end

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

local function releaseNetworkOwnership(basePart: BasePart?, data: PartData)
        if not config.EnableNetworkOwnershipManagement then
                data.currentOwner = nil
                return
        end

        data.currentOwner = nil

        if not basePart then
                return
        end

        if not basePart:IsDescendantOf(Workspace) then
                return
        end

        if not basePart.CanSetNetworkOwnership then
                return
        end

        local ok, owner = pcall(function()
                return basePart:GetNetworkOwner()
        end)

        if ok and owner ~= nil then
                local success, message = pcall(function()
                        basePart:SetNetworkOwnershipAuto()
                end)
                if not success and config.DebugMode then
                        debugPrint(string.format("Failed to release network ownership for %s: %s", basePart:GetFullName(), message))
                end
        end
end

local function enterSleepState(basePart: BasePart, data: PartData)
        if data.lodSleeping then
                return
        end

        data.preSleepAnchored = basePart.Anchored
        data.preSleepCanCollide = basePart.CanCollide

        if data.hasActivated then
                local dropDistance = math.max(config.LODSleepDropDistance or 0, 0)
                if dropDistance > 0 then
                        basePart.CFrame = basePart.CFrame + Vector3.new(0, -dropDistance, 0)
                end
        end

        basePart.AssemblyLinearVelocity = ZERO_VECTOR
        basePart.AssemblyAngularVelocity = ZERO_VECTOR
        basePart.Anchored = true
        basePart.CanCollide = false

        data.lodSleeping = true
end

local function exitSleepState(basePart: BasePart, data: PartData)
        if not data.lodSleeping then
                return
        end

        local parent = basePart.Parent
        local okDescendant, isDescendant = pcall(basePart.IsDescendantOf, basePart, game)

        if parent == nil and (not okDescendant or not isDescendant) then
                data.preSleepAnchored = nil
                data.preSleepCanCollide = nil
                data.lodSleeping = false
                return
        end

        local function restore()
                if data.preSleepAnchored ~= nil then
                        basePart.Anchored = data.preSleepAnchored
                else
                        basePart.Anchored = false
                end

                if data.preSleepCanCollide ~= nil then
                        basePart.CanCollide = data.preSleepCanCollide
                else
                        basePart.CanCollide = true
                end
        end

        local success = pcall(restore)
        if not success and config.DebugMode then
                warn("[FloatingModule] Failed to restore sleep state for", basePart)
        end

        data.preSleepAnchored = nil
        data.preSleepCanCollide = nil
        data.lodSleeping = false
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

        if basePart then
                exitSleepState(basePart, data)
        end

        if basePart then
                releaseNetworkOwnership(basePart, data)
                data.nextOwnershipCheck = nil
        else
                data.currentOwner = nil
                data.nextOwnershipCheck = nil
        end

        if data.bodyPosition then
                data.bodyPosition:Destroy()
                data.bodyPosition = nil
                data.lastTargetPosition = nil
                data.lastMaxForce = nil
	end

	if data.alignOrientation then
		data.alignOrientation:Destroy()
		data.alignOrientation = nil
	end

	if data.orientationAttachment then
		data.orientationAttachment:Destroy()
		data.orientationAttachment = nil
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

	data.isActive = nil
	data.nextDistanceCheck = nil
end

local function removeBodyMovers(part: BasePart, data: PartData)
	if data.bodyPosition then
		data.bodyPosition:Destroy()
		data.bodyPosition = nil
		data.lastTargetPosition = nil
		data.lastMaxForce = nil
	end

	if data.alignOrientation then
		data.alignOrientation:Destroy()
		data.alignOrientation = nil
	end

	if data.orientationAttachment then
		data.orientationAttachment:Destroy()
		data.orientationAttachment = nil
	end
end

local function ensureBodyPosition(part: BasePart, data: PartData): BodyPosition
	local bodyPosition = data.bodyPosition
	if not bodyPosition then
		bodyPosition = Instance.new("BodyPosition")
		bodyPosition.Name = "FloatingBodyPosition"
		bodyPosition.MaxForce = getBodyPositionMaxForce()
		bodyPosition.Parent = part
		data.bodyPosition = bodyPosition
		data.lastMaxForce = bodyPosition.MaxForce
		data.lastTargetPosition = nil
	end

	return bodyPosition
end

local function ensureOrientationAttachment(part: BasePart, data: PartData): Attachment
	local attachment = data.orientationAttachment
	if attachment and attachment.Parent ~= part then
		attachment:Destroy()
		attachment = nil
	end

	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "FloatingOrientationAttachment"
		attachment.Parent = part
		data.orientationAttachment = attachment
	end

	return attachment
end

local function ensureAlignOrientation(part: BasePart, data: PartData): AlignOrientation
	local attachment = ensureOrientationAttachment(part, data)
	local align = data.alignOrientation

	if not align then
		align = Instance.new("AlignOrientation")
		align.Name = "FloatingAlignOrientation"
		align.Mode = Enum.OrientationAlignmentMode.OneAttachment
		align.RigidityEnabled = false
		align.Attachment0 = attachment
		align.Parent = part
		data.alignOrientation = align
	else
		align.Attachment0 = attachment
	end

	return align
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
                        alignOrientation = nil,
                        orientationAttachment = nil,
                        waveOffset = math.random() * math.pi * 2,
                        rotationAngle = 0,
                        rotationAxis = axis,
                        tagged = false,
                        part = part,
                        lastTargetPosition = nil,
                        lastMaxForce = nil,
                        horizontalForward = horizontalForward,
                        isActive = nil,
                        nextDistanceCheck = nil,
                        currentOwner = nil,
                        nextOwnershipCheck = nil,
                        preSleepAnchored = nil,
                        preSleepCanCollide = nil,
                        lodSleeping = false,
                        hasActivated = false,
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

	if config.EnableLOD then
		data.isActive = false
		data.nextDistanceCheck = 0
	else
		data.isActive = true
		data.nextDistanceCheck = nil
	end

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
                local alignOrientation = ensureAlignOrientation(part, data)
                local maxSpeed = math.max(config.MaxRotationSpeed, 0)
                local speed = config.RotationSpeed
                if maxSpeed > 0 then
                        speed = math.clamp(speed, -maxSpeed, maxSpeed)
                end
                data.rotationAngle += math.rad(speed) * dt
                local rotation = CFrame.fromAxisAngle(data.rotationAxis, data.rotationAngle)
                local desiredMaxTorque = config.YawMaxTorque > 0 and config.YawMaxTorque or math.huge
                if alignOrientation.MaxTorque ~= desiredMaxTorque then
                        alignOrientation.MaxTorque = desiredMaxTorque
                end

                local desiredResponsiveness = math.max(config.YawResponsiveness, 0)
                if alignOrientation.Responsiveness ~= desiredResponsiveness then
                        alignOrientation.Responsiveness = desiredResponsiveness
                end

                local desiredMaxAngularVelocity = config.YawDamping > 0 and config.YawDamping or math.huge
                if alignOrientation.MaxAngularVelocity ~= desiredMaxAngularVelocity then
                        alignOrientation.MaxAngularVelocity = desiredMaxAngularVelocity
                end

                if alignOrientation.CFrame ~= rotation then
                        alignOrientation.CFrame = rotation
                end
                return
        end

        if data.alignOrientation and not config.EnableRotation and not config.LockYawToInitial then
                data.alignOrientation:Destroy()
		data.alignOrientation = nil
	end

	if not config.EnableRotation and not config.LockYawToInitial and data.orientationAttachment then
		data.orientationAttachment:Destroy()
		data.orientationAttachment = nil
	end

        if config.LockYawToInitial and not config.EnableRotation and config.YawMaxTorque > 0 then
                local alignOrientation = ensureAlignOrientation(part, data)
                local desiredMaxTorque = config.YawMaxTorque
                if alignOrientation.MaxTorque ~= desiredMaxTorque then
                        alignOrientation.MaxTorque = desiredMaxTorque
                end

                local desiredResponsiveness = math.max(config.YawResponsiveness, 0)
                if alignOrientation.Responsiveness ~= desiredResponsiveness then
                        alignOrientation.Responsiveness = desiredResponsiveness
                end

                local desiredMaxAngularVelocity = config.YawDamping > 0 and config.YawDamping or math.huge
                if alignOrientation.MaxAngularVelocity ~= desiredMaxAngularVelocity then
                        alignOrientation.MaxAngularVelocity = desiredMaxAngularVelocity
                end

                if not data.horizontalForward then
                        data.horizontalForward = computeHorizontalForward(part)
                end

                local forward = data.horizontalForward or Vector3.new(0, 0, -1)
                local targetPosition = part.Position + forward
                local desiredCFrame = CFrame.lookAt(part.Position, targetPosition, Vector3.yAxis)
                if alignOrientation.CFrame ~= desiredCFrame then
                        alignOrientation.CFrame = desiredCFrame
                end
        elseif config.LockYawToInitial and not config.EnableRotation and config.YawMaxTorque <= 0 and data.orientationAttachment then
                data.orientationAttachment:Destroy()
                data.orientationAttachment = nil
        elseif not config.EnableRotation and data.alignOrientation then
                data.alignOrientation:Destroy()
		data.alignOrientation = nil
		if not config.LockYawToInitial and data.orientationAttachment then
			data.orientationAttachment:Destroy()
			data.orientationAttachment = nil
		end
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

local function vectorsDiffer(a: Vector3?, b: Vector3?, tolerance: number?): boolean
        if a == nil or b == nil then
                return true
        end

        local epsilon = math.max(tolerance or 1e-4, 0)
        local delta = a - b
        return math.abs(delta.X) > epsilon or math.abs(delta.Y) > epsilon or math.abs(delta.Z) > epsilon
end

local function gatherActivePlayers(buffer: { PlayerInfo }): { PlayerInfo }
        table.clear(buffer)

        for _, player in ipairs(Players:GetPlayers()) do
                local character = player.Character
                if not character then
                        continue
                end

                local root = character:FindFirstChild("HumanoidRootPart")
                if root and root:IsA("BasePart") then
                        buffer[#buffer + 1] = { player = player, position = root.Position }
                end
        end

        return buffer
end

local function shouldPartBeActive(partPosition: Vector3, playerInfos: { PlayerInfo }, wasActive: boolean): boolean
        if #playerInfos == 0 then
                return false
        end

        local activationRadius = math.max(config.LODActivationRadius, 0)
        local deactivationRadius = math.max(config.LODDeactivationRadius, activationRadius)

        local activationThreshold = activationRadius * activationRadius
        local deactivationThreshold = deactivationRadius * deactivationRadius
        local threshold = wasActive and deactivationThreshold or activationThreshold

        for _, info in ipairs(playerInfos) do
                local offset = partPosition - info.position
                if offset:Dot(offset) <= threshold then
                        return true
                end
        end

	return false
end

local function updatePartActivation(basePart: BasePart, data: PartData, now: number, playerInfos: { PlayerInfo }): boolean
        if not config.EnableLOD then
                data.isActive = true
                data.nextDistanceCheck = nil
                return true
        end

	local nextCheck = data.nextDistanceCheck or 0
	if now < nextCheck and data.isActive ~= nil then
		return data.isActive
	end

	local interval = math.max(config.LODCheckInterval, 0)
	if interval == 0 then
		data.nextDistanceCheck = now
	else
		data.nextDistanceCheck = now + interval
	end

        local wasActive = data.isActive == true
        local shouldActivate = shouldPartBeActive(basePart.Position, playerInfos, wasActive)

        if shouldActivate then
                if data.lodSleeping then
                        exitSleepState(basePart, data)
                end
                if not wasActive then
                        data.lastTargetPosition = nil
                        data.lastMaxForce = nil
                end
                data.hasActivated = true
                data.isActive = true
        else
                if wasActive then
                        removeBodyMovers(basePart, data)
                end
                releaseNetworkOwnership(basePart, data)
                enterSleepState(basePart, data)
                data.isActive = false
                data.nextOwnershipCheck = nil
        end

        return data.isActive
end

local function updateNetworkOwnership(basePart: BasePart, data: PartData, now: number, playerInfos: { PlayerInfo })
        if not config.EnableNetworkOwnershipManagement then
                return
        end

        if not basePart.CanSetNetworkOwnership then
                return
        end

        local nextCheck = data.nextOwnershipCheck or 0
        if now < nextCheck then
                return
        end

        local interval = math.max(config.NetworkOwnershipCheckInterval, 0)
        if interval == 0 then
                data.nextOwnershipCheck = now
        else
                data.nextOwnershipCheck = now + interval
        end

        if #playerInfos == 0 then
                if data.currentOwner ~= nil or basePart:GetNetworkOwner() ~= nil then
                        releaseNetworkOwnership(basePart, data)
                end
                return
        end

        local position = basePart.Position
        local closestPlayer: Player? = nil
        local closestDistanceSq = math.huge

        for _, info in ipairs(playerInfos) do
                local offset = position - info.position
                local distanceSq = offset:Dot(offset)
                if distanceSq < closestDistanceSq then
                        closestDistanceSq = distanceSq
                        closestPlayer = info.player
                end
        end

        if not closestPlayer then
                if data.currentOwner ~= nil or basePart:GetNetworkOwner() ~= nil then
                        releaseNetworkOwnership(basePart, data)
                end
                return
        end

        if config.EnableLOD then
                local activationRadius = math.max(config.LODDeactivationRadius, config.LODActivationRadius)
                if activationRadius > 0 then
                        local threshold = activationRadius * activationRadius
                        if closestDistanceSq > threshold then
                                if data.currentOwner ~= nil or basePart:GetNetworkOwner() ~= nil then
                                        releaseNetworkOwnership(basePart, data)
                                end
                                return
                        end
                end
        end

        local ok, owner = pcall(function()
                return basePart:GetNetworkOwner()
        end)

        if ok and owner == closestPlayer then
                data.currentOwner = closestPlayer
                return
        end

        local success, message = pcall(function()
                basePart:SetNetworkOwner(closestPlayer)
        end)

        if success then
                data.currentOwner = closestPlayer
        elseif config.DebugMode then
                debugPrint(string.format("Failed to assign network ownership for %s: %s", basePart:GetFullName(), message))
        end
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
	local maxForce = getBodyPositionMaxForce()
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

        if vectorsDiffer(data.lastTargetPosition, basePosition, config.PositionUpdateThreshold) then
                bodyPosition.Position = basePosition
                data.lastTargetPosition = basePosition
        end

        local velocity = part.AssemblyLinearVelocity
        local originalVelocity = velocity

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

        local delta = velocity - originalVelocity
        if delta.Magnitude > 0 then
                local combinedDelta = delta
                local totalDeltaMagnitude = delta.Magnitude

                if data.pendingVelocityDelta then
                        local baseVelocity = data.pendingVelocityBase
                        if baseVelocity and not vectorsDiffer(originalVelocity, baseVelocity, config.VelocityUpdateThreshold * 0.5) then
                                combinedDelta += data.pendingVelocityDelta
                                totalDeltaMagnitude += data.pendingVelocityMagnitude or 0
                        else
                                data.pendingVelocityDelta = nil
                                data.pendingVelocityBase = nil
                                data.pendingVelocityMagnitude = nil
                        end
                end

                local targetVelocity = originalVelocity + combinedDelta
                local componentChanged = vectorsDiffer(targetVelocity, originalVelocity, config.VelocityUpdateThreshold)
                local magnitudeThreshold = math.max(config.VelocityUpdateThreshold, 1e-5)
                local magnitudeChanged = combinedDelta.Magnitude >= magnitudeThreshold or targetVelocity.Magnitude <= magnitudeThreshold
                local accumulatedExceeded = totalDeltaMagnitude >= magnitudeThreshold

                if componentChanged or magnitudeChanged or accumulatedExceeded then
                        part.AssemblyLinearVelocity = targetVelocity
                        data.pendingVelocityDelta = nil
                        data.pendingVelocityBase = nil
                        data.pendingVelocityMagnitude = nil
                else
                        data.pendingVelocityDelta = combinedDelta
                        data.pendingVelocityBase = originalVelocity
                        data.pendingVelocityMagnitude = totalDeltaMagnitude
                end
        elseif data.pendingVelocityDelta then
                data.pendingVelocityDelta = nil
                data.pendingVelocityBase = nil
                data.pendingVelocityMagnitude = nil
        end

end

local function heartbeatUpdate(dt: number)
        local now = Workspace:GetServerTimeNow()
        local needPlayerData = config.EnableLOD or config.EnableNetworkOwnershipManagement
        local playerInfos = needPlayerData and gatherActivePlayers(playerInfoBuffer) or playerInfoBuffer
        if not needPlayerData then
                table.clear(playerInfos)
        end

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

                if basePart.Anchored and not data.lodSleeping then
                        releaseNetworkOwnership(basePart, data)
                        data.nextOwnershipCheck = nil
                        removeBodyMovers(basePart, data)
                        continue
                end

                if not updatePartActivation(basePart, data, now, playerInfos) then
                        if data.bodyPosition or data.alignOrientation or data.orientationAttachment then
                                removeBodyMovers(basePart, data)
                        end
                        continue
                end

                updateNetworkOwnership(basePart, data, now, playerInfos)
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
