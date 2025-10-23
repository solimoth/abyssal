local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwimConstants = require(ReplicatedStorage:WaitForChild("SwimmingSystem"):WaitForChild("SwimConstants"))
local SwimUtils = require(ReplicatedStorage:WaitForChild("SwimmingSystem"):WaitForChild("SwimUtils"))

local playerStates = {}

local function ensureState(player: Player)
    local state = playerStates[player]
    if not state then
        state = {
            oxygen = SwimConstants.MaxOxygenTime,
            lastDamageTime = 0,
            defaultSpeed = nil,
            isDrowning = false,
        }
        playerStates[player] = state
    end
    return state
end

local function resetState(player: Player)
    local state = ensureState(player)
    state.oxygen = SwimConstants.MaxOxygenTime
    state.lastDamageTime = 0
    state.defaultSpeed = nil
    state.isDrowning = false
end

local function getOrCreateAttachment(rootPart: BasePart)
    local attachment = rootPart:FindFirstChild(SwimConstants.BuoyancyAttachmentName)
    if not attachment then
        attachment = Instance.new("Attachment")
        attachment.Name = SwimConstants.BuoyancyAttachmentName
        attachment.Parent = rootPart
    end
    return attachment
end

local function getOrCreateLinearVelocity(attachment: Attachment)
    local linearVelocity = attachment:FindFirstChild(SwimConstants.LinearVelocityName)
    if not linearVelocity then
        linearVelocity = Instance.new("LinearVelocity")
        linearVelocity.Name = SwimConstants.LinearVelocityName
        linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
        linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        linearVelocity.Attachment0 = attachment
        linearVelocity.MaxForce = math.huge
        linearVelocity.Parent = attachment
    end
    return linearVelocity
end

local function disableSwimFor(character: Model)
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        return
    end

    local attachment = rootPart:FindFirstChild(SwimConstants.BuoyancyAttachmentName)
    if attachment then
        local linearVelocity = attachment:FindFirstChild(SwimConstants.LinearVelocityName)
        if linearVelocity then
            linearVelocity.VectorVelocity = Vector3.zero
            linearVelocity.Enabled = false
        end
    end
end

local function updateSwimController(analysis, state, desiredVelocity, deltaTime)
    if not analysis.shouldSwim then
        disableSwimFor(analysis.character)
        return
    end

    local rootPart = analysis.rootPart
    local attachment = getOrCreateAttachment(rootPart)
    local linearVelocity = getOrCreateLinearVelocity(attachment)

    local desired = typeof(desiredVelocity) == "Vector3" and desiredVelocity or Vector3.zero
    local horizontalDesired = Vector3.new(desired.X, 0, desired.Z)

    local maxHorizontal = state.defaultSpeed or SwimConstants.BaseSwimSpeed
    maxHorizontal = math.clamp(maxHorizontal, SwimConstants.MinSwimSpeed, SwimConstants.MaxHorizontalSpeed)

    local horizontalMagnitude = horizontalDesired.Magnitude
    if horizontalMagnitude > maxHorizontal then
        horizontalDesired = horizontalDesired.Unit * maxHorizontal
    end

    local verticalInput = desired.Y
    local targetVertical

    if math.abs(verticalInput) > 0.05 then
        targetVertical = math.clamp(verticalInput, -SwimConstants.MaxVerticalSpeed, SwimConstants.MaxVerticalSpeed)
    else
        local targetSurfaceY = (analysis.surfaceY or rootPart.Position.Y) - SwimConstants.SurfaceHoldOffset
        local positionError = targetSurfaceY - rootPart.Position.Y
        local damping = rootPart.AssemblyLinearVelocity.Y * SwimConstants.SurfaceHoldDamping
        targetVertical = math.clamp((positionError * SwimConstants.SurfaceHoldStiffness) - damping, -SwimConstants.MaxVerticalSpeed, SwimConstants.MaxVerticalSpeed)
    end

    local targetVelocity = Vector3.new(horizontalDesired.X, targetVertical, horizontalDesired.Z)
    local currentVelocity = rootPart.AssemblyLinearVelocity
    local blendAlpha = math.clamp((deltaTime or 0) * 8, 0, 1)
    local finalVelocity = currentVelocity:Lerp(targetVelocity, blendAlpha)

    linearVelocity.VectorVelocity = finalVelocity
    linearVelocity.Enabled = true
end

local function ensureSwimmingState(humanoid: Humanoid, shouldSwim: boolean)
    if shouldSwim then
        if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming and humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
            humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
        end
    else
        if humanoid:GetState() == Enum.HumanoidStateType.Swimming then
            humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end
    end
end

local function updateSwimmingSpeed(humanoid: Humanoid, analysis, state)
    if not state.defaultSpeed then
        state.defaultSpeed = humanoid.WalkSpeed
    end

    local targetSpeed = math.clamp(SwimConstants.BaseSwimSpeed - (analysis.depth * SwimConstants.DepthSlowFactor), SwimConstants.MinSwimSpeed, SwimConstants.BaseSwimSpeed)

    if math.abs(humanoid.WalkSpeed - targetSpeed) > 0.1 then
        humanoid.WalkSpeed = targetSpeed
    end
end

local function restoreWalkingSpeed(humanoid: Humanoid, state)
    if state.defaultSpeed and math.abs(humanoid.WalkSpeed - state.defaultSpeed) > 0.1 then
        humanoid.WalkSpeed = state.defaultSpeed
    end
end

local function updateOxygen(player, analysis, state, deltaTime)
    if analysis.insideInterior then
        state.oxygen = SwimConstants.MaxOxygenTime
        state.isDrowning = false
        state.lastDamageTime = 0
        return
    end

    if analysis.headUnderwater then
        state.oxygen = math.max(0, state.oxygen - deltaTime)
        if state.oxygen <= 0 then
            state.isDrowning = true
            local now = time()
            if now - state.lastDamageTime >= SwimConstants.DrowningDamageInterval then
                analysis.humanoid:TakeDamage(SwimConstants.DrowningDamage)
                state.lastDamageTime = now
            end
        else
            state.isDrowning = false
        end
    else
        state.isDrowning = false
        state.lastDamageTime = 0
        state.oxygen = math.min(SwimConstants.MaxOxygenTime, state.oxygen + (SwimConstants.OxygenRecoveryRate * deltaTime))
    end
end

local function processPlayer(player: Player, deltaTime)
    local character = player.Character
    if not character then
        return
    end

    local analysis = SwimUtils.AnalyzeCharacter(character)
    if not analysis then
        return
    end

    local state = ensureState(player)
    ensureSwimmingState(analysis.humanoid, analysis.shouldSwim)

    local desiredVelocity = analysis.rootPart:GetAttribute(SwimConstants.DesiredVelocityAttribute)
    if not analysis.shouldSwim then
        desiredVelocity = Vector3.zero
    end

    updateSwimController(analysis, state, desiredVelocity, deltaTime)

    if analysis.shouldSwim and analysis.rootUnderwater then
        updateSwimmingSpeed(analysis.humanoid, analysis, state)
    else
        restoreWalkingSpeed(analysis.humanoid, state)
    end

    updateOxygen(player, analysis, state, deltaTime)
end

Players.PlayerAdded:Connect(function(player)
    ensureState(player)

    player.CharacterAdded:Connect(function(character)
        resetState(player)
        SwimUtils.ClearCharacterCache(character)
    end)

    player.CharacterRemoving:Connect(function(character)
        SwimUtils.ClearCharacterCache(character)
        resetState(player)
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    playerStates[player] = nil
end)

local lastUpdate = time()

RunService.Heartbeat:Connect(function()
    local now = time()
    local deltaTime = now - lastUpdate
    lastUpdate = now

    for _, player in ipairs(Players:GetPlayers()) do
        processPlayer(player, deltaTime)
    end
end)
