local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)

local TEXTURE_ID = "rbxassetid://121641543712692"
local UPDATE_INTERVAL = 0.05
local SCAN_INTERVAL = 1.25
local RATE_EPSILON = 0.1
local DISTANCE_FALLOFF_START = 220
local DISTANCE_FALLOFF_END = 580

local boatStates = {} --[=[ @[Model] = table ]=]
local awaitingPrimary = setmetatable({}, { __mode = "k" })
local cleanupBuffer = table.create(16)
local requeueBuffer = table.create(16)
local scanTimer = SCAN_INTERVAL

local currentCamera = Workspace.CurrentCamera

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    currentCamera = Workspace.CurrentCamera
end)

local NumberSequenceKeypoint = NumberSequenceKeypoint

local SURFACE_ENGINE_PROPERTIES = {
    Lifetime = NumberRange.new(0.35, 0.55),
    Speed = NumberRange.new(16, 24),
    Acceleration = Vector3.new(0, 7, 0),
    SpreadAngle = Vector2.new(12, 24),
    Rotation = NumberRange.new(0, 360),
    RotSpeed = NumberRange.new(-140, 140),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.35),
        NumberSequenceKeypoint.new(0.25, 0.55),
        NumberSequenceKeypoint.new(1, 0.05),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(0.6, 0.35),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(210, 236, 255), Color3.fromRGB(255, 255, 255)),
    Drag = 1.2,
    EmissionDirection = Enum.NormalId.Back,
}

local SURFACE_BOW_PROPERTIES = {
    Lifetime = NumberRange.new(0.25, 0.4),
    Speed = NumberRange.new(11, 16),
    Acceleration = Vector3.new(0, -Workspace.Gravity * 0.08, 0),
    SpreadAngle = Vector2.new(35, 65),
    Rotation = NumberRange.new(-25, 25),
    RotSpeed = NumberRange.new(-50, 50),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.55),
        NumberSequenceKeypoint.new(0.6, 0.35),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.25),
        NumberSequenceKeypoint.new(0.7, 0.75),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(224, 244, 255)),
    EmissionDirection = Enum.NormalId.Front,
}

local SURFACE_FOAM_PROPERTIES = {
    Lifetime = NumberRange.new(0.55, 0.85),
    Speed = NumberRange.new(5, 7),
    Acceleration = Vector3.new(0, 3, 0),
    SpreadAngle = Vector2.new(45, 55),
    Rotation = NumberRange.new(0, 360),
    RotSpeed = NumberRange.new(-40, 40),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(0.4, 0.55),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.35),
        NumberSequenceKeypoint.new(0.5, 0.55),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(229, 245, 255)),
    EmissionDirection = Enum.NormalId.Top,
}

local SURFACE_TURN_PROPERTIES = {
    Lifetime = NumberRange.new(0.3, 0.5),
    Speed = NumberRange.new(9, 14),
    Acceleration = Vector3.new(0, -Workspace.Gravity * 0.05, 0),
    SpreadAngle = Vector2.new(40, 65),
    Rotation = NumberRange.new(-40, 40),
    RotSpeed = NumberRange.new(-70, 70),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.45),
        NumberSequenceKeypoint.new(0.7, 0.25),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.2),
        NumberSequenceKeypoint.new(0.6, 0.7),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(226, 243, 255)),
    EmissionDirection = Enum.NormalId.Front,
}

local SUBMARINE_ENGINE_PROPERTIES = {
    Lifetime = NumberRange.new(0.85, 1.2),
    Speed = NumberRange.new(13, 18),
    Acceleration = Vector3.new(0, 8, 0),
    SpreadAngle = Vector2.new(18, 28),
    Rotation = NumberRange.new(-20, 20),
    RotSpeed = NumberRange.new(-90, 90),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(0.35, 0.65),
        NumberSequenceKeypoint.new(1, 0.1),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.08),
        NumberSequenceKeypoint.new(0.6, 0.4),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(215, 238, 255), Color3.fromRGB(170, 217, 255)),
    EmissionDirection = Enum.NormalId.Back,
}

local SUBMARINE_HULL_PROPERTIES = {
    Lifetime = NumberRange.new(0.9, 1.4),
    Speed = NumberRange.new(4, 7),
    Acceleration = Vector3.new(0, 5, 0),
    SpreadAngle = Vector2.new(180, 180),
    Rotation = NumberRange.new(0, 360),
    RotSpeed = NumberRange.new(-45, 45),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.55),
        NumberSequenceKeypoint.new(0.5, 0.4),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(200, 228, 255), Color3.fromRGB(150, 205, 255)),
    EmissionDirection = Enum.NormalId.Front,
}

local SUBMARINE_BALLAST_PROPERTIES = {
    Lifetime = NumberRange.new(0.45, 0.6),
    Speed = NumberRange.new(10, 15),
    Acceleration = Vector3.new(0, -Workspace.Gravity * 0.05, 0),
    SpreadAngle = Vector2.new(18, 28),
    Rotation = NumberRange.new(-10, 10),
    RotSpeed = NumberRange.new(-40, 40),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.35),
        NumberSequenceKeypoint.new(0.4, 0.5),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.18),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(230, 245, 255), Color3.fromRGB(180, 220, 255)),
    EmissionDirection = Enum.NormalId.Bottom,
}

local SUBMARINE_VENT_PROPERTIES = {
    Lifetime = NumberRange.new(0.7, 1.1),
    Speed = NumberRange.new(7, 11),
    Acceleration = Vector3.new(0, 10, 0),
    SpreadAngle = Vector2.new(50, 70),
    Rotation = NumberRange.new(-20, 20),
    RotSpeed = NumberRange.new(-60, 60),
    Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.45),
        NumberSequenceKeypoint.new(0.6, 0.35),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.25),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Color = ColorSequence.new(Color3.fromRGB(220, 244, 255)),
    EmissionDirection = Enum.NormalId.Top,
}

local function smoothValue(stateTable, key, target, dt, rate)
    rate = math.max(rate or 6, 0)
    dt = math.max(dt, 0)

    local current = stateTable[key]
    if current == nil then
        current = target
    else
        local alpha = 1 - math.exp(-rate * dt)
        current += (target - current) * alpha
    end

    stateTable[key] = current
    return current
end

local function createAttachment(state, name, worldOffset)
    local primary = state.primary
    local attachment = Instance.new("Attachment")
    attachment.Name = name

    if worldOffset then
        attachment.Position = primary.CFrame:VectorToObjectSpace(worldOffset)
    end

    attachment.Parent = primary
    table.insert(state.instances, attachment)
    state.attachments[name] = attachment
    return attachment
end

local function createEmitter(state, attachment, name, properties, overrides)
    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = name
    emitter.Texture = TEXTURE_ID
    emitter.Rate = 0
    emitter.Enabled = false
    emitter.LightInfluence = 0
    emitter.LockedToPart = false
    emitter.VelocityInheritance = 0

    for property, value in pairs(properties) do
        emitter[property] = value
    end

    if overrides then
        for property, value in pairs(overrides) do
            emitter[property] = value
        end
    end

    emitter.Parent = attachment
    state.emitters[name] = emitter
    state.emitterRates[name] = 0
    table.insert(state.instances, emitter)
    return emitter
end

local function disableAllEmitters(state)
    for name, emitter in pairs(state.emitters) do
        if emitter then
            emitter.Rate = 0
            emitter.Enabled = false
            state.emitterRates[name] = 0
        end
    end
end

local function setEmitterRate(state, name, targetRate)
    local emitter = state.emitters[name]
    if not emitter then
        return
    end

    targetRate = math.max(targetRate, 0)
    if targetRate <= RATE_EPSILON then
        if (state.emitterRates[name] or 0) > 0 then
            emitter.Rate = 0
            emitter.Enabled = false
            state.emitterRates[name] = 0
        end

        return
    end

    local current = state.emitterRates[name] or 0
    if math.abs(current - targetRate) > RATE_EPSILON then
        emitter.Rate = targetRate
        emitter.Enabled = true
        state.emitterRates[name] = targetRate
    end
end

local function computeDistanceFactor(distance)
    if distance >= DISTANCE_FALLOFF_END then
        return 0
    end

    if distance <= DISTANCE_FALLOFF_START then
        return 1
    end

    local alpha = (distance - DISTANCE_FALLOFF_START) / (DISTANCE_FALLOFF_END - DISTANCE_FALLOFF_START)
    return 1 - (alpha * alpha)
end

local function setupSurfaceBoat(state)
    local primary = state.primary
    local size = state.size
    local cframe = primary.CFrame
    local look = cframe.LookVector
    local right = cframe.RightVector
    local up = cframe.UpVector
    local halfX = size.X * 0.5
    local halfY = size.Y * 0.5
    local halfZ = size.Z * 0.5

    state.surface = {
        engineBaseRate = 18,
        bowBaseRate = 14,
        foamBaseRate = 10,
        turnBaseRate = 12,
    }

    local rearDistance = math.max(halfZ - math.min(halfZ * 0.35, 1.5), halfZ * 0.55)
    local verticalEngine = -up * (halfY * 0.25)
    local lateralEngine = right * (halfX * 0.35)

    local leftOffset = (-look * rearDistance) - lateralEngine + verticalEngine
    local rightOffset = (-look * rearDistance) + lateralEngine + verticalEngine

    local engineLeft = createAttachment(state, "EngineTrailLeft", leftOffset)
    local engineRight = createAttachment(state, "EngineTrailRight", rightOffset)

    createEmitter(state, engineLeft, "EngineTrailLeft", SURFACE_ENGINE_PROPERTIES, { EmissionDirection = Enum.NormalId.Back })
    createEmitter(state, engineRight, "EngineTrailRight", SURFACE_ENGINE_PROPERTIES, { EmissionDirection = Enum.NormalId.Back })

    local bowDistance = math.max(halfZ - math.min(halfZ * 0.25, 1), halfZ * 0.5)
    local bowOffset = (look * bowDistance) - (up * (halfY * 0.25))
    local bowAttachment = createAttachment(state, "BowSpray", bowOffset)
    createEmitter(state, bowAttachment, "BowSpray", SURFACE_BOW_PROPERTIES, { EmissionDirection = Enum.NormalId.Front })

    local foamOffset = (-look * (halfZ * 0.05)) - (up * (halfY * 0.65))
    local foamAttachment = createAttachment(state, "WakeFoam", foamOffset)
    createEmitter(state, foamAttachment, "WakeFoam", SURFACE_FOAM_PROPERTIES, { EmissionDirection = Enum.NormalId.Top })

    local sideBaseOffset = (-look * (halfZ * 0.18)) - (up * (halfY * 0.2))
    local sideLateral = right * (halfX * 0.55)
    local leftTurnAttachment = createAttachment(state, "TurnSprayLeft", sideBaseOffset - sideLateral)
    local rightTurnAttachment = createAttachment(state, "TurnSprayRight", sideBaseOffset + sideLateral)

    createEmitter(state, leftTurnAttachment, "TurnSprayLeft", SURFACE_TURN_PROPERTIES, { EmissionDirection = Enum.NormalId.Left })
    createEmitter(state, rightTurnAttachment, "TurnSprayRight", SURFACE_TURN_PROPERTIES, { EmissionDirection = Enum.NormalId.Right })
end

local function setupSubmarineBoat(state)
    local primary = state.primary
    local size = state.size
    local cframe = primary.CFrame
    local look = cframe.LookVector
    local right = cframe.RightVector
    local up = cframe.UpVector
    local halfX = size.X * 0.5
    local halfY = size.Y * 0.5
    local halfZ = size.Z * 0.5

    state.submarine = {
        rearBaseRate = 26,
        hullBaseRate = 18,
        ballastBaseRate = 22,
        ventBaseRate = 16,
    }

    local rearDistance = math.max(halfZ - math.min(halfZ * 0.3, 1.8), halfZ * 0.6)
    local verticalOffset = -up * (halfY * 0.18)
    local lateralOffset = right * (halfX * 0.28)
    local leftRearOffset = (-look * rearDistance) - lateralOffset + verticalOffset
    local rightRearOffset = (-look * rearDistance) + lateralOffset + verticalOffset

    local leftRear = createAttachment(state, "AftTrailLeft", leftRearOffset)
    local rightRear = createAttachment(state, "AftTrailRight", rightRearOffset)

    createEmitter(state, leftRear, "AftTrailLeft", SUBMARINE_ENGINE_PROPERTIES, { EmissionDirection = Enum.NormalId.Back })
    createEmitter(state, rightRear, "AftTrailRight", SUBMARINE_ENGINE_PROPERTIES, { EmissionDirection = Enum.NormalId.Back })

    local hullAttachment = createAttachment(state, "HullWake", -up * (halfY * 0.1))
    createEmitter(state, hullAttachment, "HullWake", SUBMARINE_HULL_PROPERTIES, { EmissionDirection = Enum.NormalId.Front })

    local ballastAttachment = createAttachment(state, "BallastJets", -up * (halfY * 0.85))
    createEmitter(state, ballastAttachment, "BallastJets", SUBMARINE_BALLAST_PROPERTIES, { EmissionDirection = Enum.NormalId.Bottom })

    local ventAttachment = createAttachment(state, "BallastVent", up * (halfY * 0.75))
    createEmitter(state, ventAttachment, "BallastVent", SUBMARINE_VENT_PROPERTIES, { EmissionDirection = Enum.NormalId.Top })
end

local function gatherMetrics(state)
    local primary = state.primary
    local velocity = primary.AssemblyLinearVelocity
    local cframe = primary.CFrame
    local look = cframe.LookVector
    local right = cframe.RightVector
    local up = cframe.UpVector

    local forwardSpeed = velocity:Dot(look)
    local lateralSpeed = velocity:Dot(right)
    local verticalSpeed = velocity:Dot(up)
    local horizontalVelocity = velocity - (up * verticalSpeed)
    local horizontalSpeed = horizontalVelocity.Magnitude
    local totalSpeed = velocity.Magnitude

    local angularVelocity = primary.AssemblyAngularVelocity
    local yawRate = angularVelocity:Dot(up)

    local distance = 0
    local distanceFactor = 1
    local camera = currentCamera

    if camera then
        distance = (primary.Position - camera.CFrame.Position).Magnitude
        distanceFactor = computeDistanceFactor(distance)
    end

    return {
        forwardSpeed = forwardSpeed,
        lateralSpeed = lateralSpeed,
        verticalSpeed = verticalSpeed,
        horizontalSpeed = horizontalSpeed,
        totalSpeed = totalSpeed,
        yawRate = yawRate,
        distance = distance,
        distanceFactor = distanceFactor,
    }
end

local function updateSurfaceBoat(state, dt, metrics)
    local distanceFactor = metrics.distanceFactor
    if distanceFactor <= 0 then
        disableAllEmitters(state)
        return
    end

    local forwardMagnitude = smoothValue(state, "surfaceForward", math.abs(metrics.forwardSpeed), dt, 6)
    local horizontalSpeed = smoothValue(state, "surfaceHorizontal", metrics.horizontalSpeed, dt, 6)
    local lateralSpeed = smoothValue(state, "surfaceLateral", metrics.lateralSpeed, dt, 6)
    local forwardOnly = smoothValue(state, "surfaceForwardOnly", math.max(metrics.forwardSpeed, 0), dt, 6)

    local engineAlpha = math.clamp((forwardMagnitude - 4) / 32, 0, 1)
    local engineRate = state.surface.engineBaseRate * engineAlpha * distanceFactor
    setEmitterRate(state, "EngineTrailLeft", engineRate)
    setEmitterRate(state, "EngineTrailRight", engineRate)

    local sprayAlpha = math.clamp((forwardOnly - 6) / 32, 0, 1)
    setEmitterRate(state, "BowSpray", state.surface.bowBaseRate * sprayAlpha * distanceFactor)

    local foamAlpha = math.clamp((horizontalSpeed - 3.5) / 22, 0, 1)
    local foamRate = state.surface.foamBaseRate * foamAlpha * distanceFactor

    if foamRate <= RATE_EPSILON and horizontalSpeed > 1 then
        foamRate = state.surface.foamBaseRate * math.clamp(horizontalSpeed / 18, 0, 0.35) * distanceFactor
    end

    setEmitterRate(state, "WakeFoam", foamRate)

    local lateral = lateralSpeed
    local turnAlpha = math.clamp((math.abs(lateral) - 2) / 16, 0, 1)
    local turnRate = state.surface.turnBaseRate * turnAlpha * distanceFactor

    if lateral > 0.5 then
        setEmitterRate(state, "TurnSprayRight", turnRate)
        setEmitterRate(state, "TurnSprayLeft", 0)
    elseif lateral < -0.5 then
        setEmitterRate(state, "TurnSprayLeft", turnRate)
        setEmitterRate(state, "TurnSprayRight", 0)
    else
        setEmitterRate(state, "TurnSprayLeft", 0)
        setEmitterRate(state, "TurnSprayRight", 0)
    end
end

local function updateSubmarineBoat(state, dt, metrics)
    local distanceFactor = metrics.distanceFactor
    if distanceFactor <= 0 then
        disableAllEmitters(state)
        return
    end

    local horizontalSpeed = smoothValue(state, "subHorizontal", metrics.horizontalSpeed, dt, 5)
    local forwardSpeed = smoothValue(state, "subForward", metrics.forwardSpeed, dt, 5)
    local verticalSpeed = smoothValue(state, "subVertical", metrics.verticalSpeed, dt, 5)
    local yawRate = smoothValue(state, "subYaw", metrics.yawRate, dt, 6)

    local engineAlpha = math.clamp((math.abs(forwardSpeed) - 2.5) / 28, 0, 1)
    local baseEngineRate = state.submarine.rearBaseRate * engineAlpha * distanceFactor
    local turnBias = math.clamp(yawRate / 3, -0.6, 0.6)

    setEmitterRate(state, "AftTrailLeft", baseEngineRate * (1 + turnBias * 0.45))
    setEmitterRate(state, "AftTrailRight", baseEngineRate * (1 - turnBias * 0.45))

    local hullAlpha = math.clamp((horizontalSpeed - 3) / 25, 0, 1)
    setEmitterRate(state, "HullWake", state.submarine.hullBaseRate * hullAlpha * distanceFactor)

    local ascendAlpha = math.clamp((verticalSpeed - 1.2) / 10, 0, 1)
    setEmitterRate(state, "BallastJets", state.submarine.ballastBaseRate * ascendAlpha * distanceFactor)

    local descendAlpha = math.clamp((-verticalSpeed - 1.2) / 10, 0, 1)
    setEmitterRate(state, "BallastVent", state.submarine.ventBaseRate * descendAlpha * distanceFactor)
end

local function teardownBoat(state)
    if not state then
        return
    end

    for _, connection in ipairs(state.connections) do
        connection:Disconnect()
    end
    state.connections = {}

    disableAllEmitters(state)

    for _, instance in ipairs(state.instances) do
        if instance and instance.Parent then
            instance:Destroy()
        end
    end

    state.instances = {}
    state.attachments = {}
    state.emitters = {}
    state.emitterRates = {}

    boatStates[state.boat] = nil
end

local function setupBoat(boat)
    if boatStates[boat] then
        return
    end

    if not boat:IsA("Model") then
        return
    end

    if not boat:IsDescendantOf(Workspace) then
        return
    end

    local primary = boat.PrimaryPart
    if not primary then
        awaitingPrimary[boat] = true
        return
    end

    awaitingPrimary[boat] = nil

    local boatTypeName = boat:GetAttribute("BoatType")
    local config = boatTypeName and BoatConfig.GetBoatData(boatTypeName) or nil
    local class = (config and config.Type == "Submarine") and "Submarine" or "Surface"

    local state = {
        boat = boat,
        primary = primary,
        size = boat:GetExtentsSize(),
        class = class,
        emitters = {},
        emitterRates = {},
        attachments = {},
        instances = {},
        connections = {},
        updateAccumulator = math.random() * UPDATE_INTERVAL,
    }

    boatStates[boat] = state

    if class == "Submarine" then
        setupSubmarineBoat(state)
    else
        setupSurfaceBoat(state)
    end

    table.insert(state.connections, boat:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
        if boatStates[boat] == state then
            awaitingPrimary[boat] = true
        end
    end))

    table.insert(state.connections, boat.Destroying:Connect(function()
        awaitingPrimary[boat] = nil
    end))
end

local function rescanWorkspace()
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") and child:GetAttribute("BoatId") then
            setupBoat(child)
        end
    end
end

rescanWorkspace()

Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child:GetAttribute("BoatId") then
        setupBoat(child)
    end
end)

RunService.Heartbeat:Connect(function(dt)
    for boat in pairs(awaitingPrimary) do
        if not boat.Parent then
            awaitingPrimary[boat] = nil
        elseif boat.PrimaryPart then
            awaitingPrimary[boat] = nil
            setupBoat(boat)
        end
    end

    local cleanupCount = 0
    for boat, state in pairs(boatStates) do
        local primary = boat.PrimaryPart
        if not boat.Parent then
            cleanupCount += 1
            cleanupBuffer[cleanupCount] = boat
            requeueBuffer[cleanupCount] = false
        elseif not primary or primary ~= state.primary then
            cleanupCount += 1
            cleanupBuffer[cleanupCount] = boat
            requeueBuffer[cleanupCount] = true
        else
            state.updateAccumulator += dt
            while state.updateAccumulator >= UPDATE_INTERVAL do
                state.updateAccumulator -= UPDATE_INTERVAL
                local metrics = gatherMetrics(state)
                if state.class == "Submarine" then
                    updateSubmarineBoat(state, UPDATE_INTERVAL, metrics)
                else
                    updateSurfaceBoat(state, UPDATE_INTERVAL, metrics)
                end
            end
        end
    end

    for index = 1, cleanupCount do
        local boat = cleanupBuffer[index]
        local state = boatStates[boat]
        if state then
            teardownBoat(state)
        end

        if requeueBuffer[index] and boat.Parent then
            awaitingPrimary[boat] = true
        else
            awaitingPrimary[boat] = nil
        end

        cleanupBuffer[index] = nil
        requeueBuffer[index] = nil
    end

    scanTimer -= dt
    if scanTimer <= 0 then
        scanTimer = SCAN_INTERVAL
        rescanWorkspace()
    end
end)
