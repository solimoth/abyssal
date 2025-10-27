local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TEXTURE_ID = "rbxassetid://121641543712692"
local SPEED_THRESHOLD = 2.25
local STEP_INTERVAL_MIN = 0.18
local STEP_INTERVAL_MAX = 0.44
local RAY_DISTANCE = 6

local NumberSequenceKeypoint = NumberSequenceKeypoint
local ColorSequenceKeypoint = ColorSequenceKeypoint

local DEFAULT_COLOR = Color3.fromRGB(241, 243, 245)
local DEFAULT_COLOR_SEQUENCE = ColorSequence.new({
    ColorSequenceKeypoint.new(0, DEFAULT_COLOR:Lerp(Color3.new(1, 1, 1), 0.65)),
    ColorSequenceKeypoint.new(0.35, DEFAULT_COLOR),
    ColorSequenceKeypoint.new(1, DEFAULT_COLOR:Lerp(Color3.new(1, 1, 1), 0.85)),
})

local function createEmitter(parent: Attachment)
    local emitter = Instance.new("ParticleEmitter")
    emitter.Texture = TEXTURE_ID
    emitter.LightInfluence = 0
    emitter.Lifetime = NumberRange.new(0.24, 0.36)
    emitter.Speed = NumberRange.new(6, 9)
    emitter.Acceleration = Vector3.new(0, 22, 0)
    emitter.SpreadAngle = Vector2.new(16, 22)
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.RotSpeed = NumberRange.new(-140, 140)
    emitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.24),
        NumberSequenceKeypoint.new(0.35, 0.4),
        NumberSequenceKeypoint.new(1, 0),
    })
    emitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.08),
        NumberSequenceKeypoint.new(0.3, 0.18),
        NumberSequenceKeypoint.new(1, 1),
    })
    emitter.EmissionDirection = Enum.NormalId.Top
    emitter.Orientation = Enum.ParticleOrientation.FacingCamera
    emitter.LockedToPart = false
    emitter.Rate = 0
    emitter.Drag = 1.4
    emitter.ZOffset = 0.25
    emitter.Parent = parent

    return emitter
end

local function createColorSequence(base: Color3)
    local highlight = base:Lerp(Color3.new(1, 1, 1), 0.65)
    local mid = base:Lerp(Color3.new(1, 1, 1), 0.25)

    return ColorSequence.new({
        ColorSequenceKeypoint.new(0, highlight),
        ColorSequenceKeypoint.new(0.4, mid),
        ColorSequenceKeypoint.new(1, highlight),
    })
end

local function colorsApproxEqual(a: Color3, b: Color3)
    return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
end

local function getFootPart(character: Model, names: {string})
    for _, name in ipairs(names) do
        local part = character:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            return part
        end
    end

    for _, name in ipairs(names) do
        local part = character:WaitForChild(name, 2)
        if part and part:IsA("BasePart") then
            return part
        end
    end

    return nil
end

local function setupFoot(character: Model, part: BasePart?)
    if not part then
        return nil
    end

    local attachment = Instance.new("Attachment")
    attachment.Name = "FootstepAttachment"
    attachment.Position = Vector3.new(0, -part.Size.Y * 0.45, 0)
    attachment.Parent = part

    local emitter = createEmitter(attachment)

    local rayParams = RaycastParams.new()
    rayParams.FilterDescendantsInstances = { character }
    rayParams.FilterType = Enum.RaycastFilterType.Exclude

    return {
        attachment = attachment,
        emitter = emitter,
        rayParams = rayParams,
        lastColor = nil,
    }
end

local function updateEmitterColor(data, baseColor: Color3?)
    if not baseColor then
        if not data.lastColor then
            return
        end

        data.lastColor = nil
        data.emitter.Color = DEFAULT_COLOR_SEQUENCE
        return
    end

    if data.lastColor and colorsApproxEqual(data.lastColor, baseColor) then
        return
    end

    data.lastColor = baseColor
    data.emitter.Color = createColorSequence(baseColor)
end

local function emitFootstep(data, origin: Vector3)
    local raycastResult = Workspace:Raycast(origin, Vector3.new(0, -RAY_DISTANCE, 0), data.rayParams)

    if raycastResult and raycastResult.Instance and raycastResult.Instance:IsA("BasePart") then
        updateEmitterColor(data, raycastResult.Instance.Color)
    else
        updateEmitterColor(data, nil)
    end

    local emitCount = 4
    local character = data.attachment.Parent and data.attachment.Parent.Parent
    if character and character:IsA("Model") then
        local root = character:FindFirstChild("HumanoidRootPart")
        if root and root:IsA("BasePart") then
            local horizontalVelocity = root.AssemblyLinearVelocity
            local speed = Vector3.new(horizontalVelocity.X, 0, horizontalVelocity.Z).Magnitude
            emitCount = math.clamp(math.floor(2 + speed * 0.18), 3, 8)
            data.emitter.EmissionDirection = speed > 8 and Enum.NormalId.Top or Enum.NormalId.Back
        end
    end

    data.emitter:Emit(emitCount)
end

local function attachToCharacter(character: Model)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")

    if not humanoid or not root then
        return nil
    end

    local rigType = humanoid.RigType
    local leftFootPart
    local rightFootPart

    if rigType == Enum.HumanoidRigType.R6 then
        leftFootPart = getFootPart(character, { "Left Leg" })
        rightFootPart = getFootPart(character, { "Right Leg" })
    else
        leftFootPart = getFootPart(character, { "LeftFoot", "LeftLowerLeg" })
        rightFootPart = getFootPart(character, { "RightFoot", "RightLowerLeg" })
    end

    local leftData = setupFoot(character, leftFootPart)
    local rightData = setupFoot(character, rightFootPart)

    if not leftData and not rightData then
        return nil
    end

    local running = true
    local swap = false
    local accumulator = 0

    local function onHeartbeat(dt)
        if not running or not character.Parent then
            return
        end

        if humanoid.Health <= 0 then
            running = false
            return
        end

        local horizontalVelocity = root.AssemblyLinearVelocity
        local horizontalSpeed = Vector3.new(horizontalVelocity.X, 0, horizontalVelocity.Z).Magnitude
        local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

        if grounded and horizontalSpeed > SPEED_THRESHOLD then
            accumulator -= dt

            local clampedSpeed = math.clamp(horizontalSpeed, 0, 20)
            local interval = STEP_INTERVAL_MAX - ((STEP_INTERVAL_MAX - STEP_INTERVAL_MIN) * (clampedSpeed / 20))

            if accumulator <= 0 then
                accumulator = interval
                swap = not swap

                local current = swap and leftData or rightData
                if current then
                    emitFootstep(current, current.attachment.WorldPosition)
                end
            end
        else
            accumulator = 0
        end
    end

    local connection = RunService.RenderStepped:Connect(onHeartbeat)

    local cleanupConnections = table.create(2)

    cleanupConnections[1] = humanoid.Died:Connect(function()
        running = false
    end)

    cleanupConnections[2] = character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            running = false
        end
    end)

    local function cleanup()
        running = false

        connection:Disconnect()

        for _, conn in ipairs(cleanupConnections) do
            conn:Disconnect()
        end

        if leftData and leftData.attachment.Parent then
            leftData.attachment:Destroy()
        end

        if rightData and rightData.attachment.Parent then
            rightData.attachment:Destroy()
        end
    end

    return cleanup
end

local localPlayer = Players.LocalPlayer
local currentCleanup

local function onCharacterAdded(character: Model)
    if currentCleanup then
        currentCleanup()
        currentCleanup = nil
    end

    currentCleanup = attachToCharacter(character)
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)

if localPlayer.Character then
    onCharacterAdded(localPlayer.Character)
end

localPlayer.CharacterRemoving:Connect(function()
    if currentCleanup then
        currentCleanup()
        currentCleanup = nil
    end
end)
