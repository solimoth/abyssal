local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwimConstants = require(ReplicatedStorage:WaitForChild("SwimmingSystem"):WaitForChild("SwimConstants"))
local SwimUtils = require(ReplicatedStorage:WaitForChild("SwimmingSystem"):WaitForChild("SwimUtils"))

SwimUtils.Configure(SwimConstants)

local LOCAL_PLAYER = Players.LocalPlayer
local DESIRED_ATTRIBUTE = SwimConstants.DesiredVelocityAttribute
local UPDATE_THRESHOLD_SQUARED = SwimConstants.DesiredVelocityUpdateThresholdSquared or 0.25

local ASCEND_KEYS = {
    Enum.KeyCode.Space,
    Enum.KeyCode.E,
    Enum.KeyCode.ButtonR1,
    Enum.KeyCode.ButtonR2,
    Enum.KeyCode.DPadUp,
}

local DESCEND_KEYS = {
    Enum.KeyCode.LeftControl,
    Enum.KeyCode.C,
    Enum.KeyCode.ButtonL1,
    Enum.KeyCode.ButtonL2,
    Enum.KeyCode.DPadDown,
}

local currentCharacter: Model? = nil
local lastDesiredVelocity = Vector3.zero
local controls = nil
local analysisBuffer = {}
local characterConnections = {}

local function disconnectCharacterSignals()
    for _, connection in ipairs(characterConnections) do
        connection:Disconnect()
    end
    table.clear(characterConnections)
end

local function clearDesiredVelocity()
    if not currentCharacter then
        return
    end

    local _, rootPart = SwimUtils.GetCharacterComponents(currentCharacter)
    if rootPart then
        rootPart:SetAttribute(DESIRED_ATTRIBUTE, nil)
    end
    lastDesiredVelocity = Vector3.zero
end

local function setCurrentCharacter(character: Model?)
    disconnectCharacterSignals()
    SwimUtils.ClearCharacterCache(currentCharacter)

    currentCharacter = character
    lastDesiredVelocity = Vector3.zero

    if not character then
        return
    end

    SwimUtils.ClearCharacterCache(character)

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        table.insert(characterConnections, humanoid.Died:Connect(function()
            clearDesiredVelocity()
            SwimUtils.ClearCharacterCache(character)
        end))
    end

    table.insert(characterConnections, character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            clearDesiredVelocity()
            SwimUtils.ClearCharacterCache(character)
        end
    end))
end

local function isAnyKeyDown(keys)
    for _, keyCode in ipairs(keys) do
        if UserInputService:IsKeyDown(keyCode) then
            return true
        end
    end
    return false
end

local function ensureHumanoidState(humanoid: Humanoid, shouldSwim: boolean)
    if shouldSwim then
        local state = humanoid:GetState()
        if state ~= Enum.HumanoidStateType.Swimming and state ~= Enum.HumanoidStateType.Dead then
            humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
        end
    else
        if humanoid:GetState() == Enum.HumanoidStateType.Swimming then
            humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end
    end
end

local function computeDesiredVelocity(analysis)
    if not controls then
        return Vector3.zero
    end

    local humanoid: Humanoid = analysis.humanoid
    if humanoid.Health <= 0 then
        return Vector3.zero
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return Vector3.zero
    end

    local moveVector = controls:GetMoveVector()
    if moveVector.Magnitude < 0.05 and math.abs(moveVector.Y) < 0.05 and not humanoid.Jump then
        return Vector3.zero
    end

    local vertical = math.clamp(moveVector.Y, -1, 1)
    local ascendActive = humanoid.Jump or isAnyKeyDown(ASCEND_KEYS)
    local descendActive = isAnyKeyDown(DESCEND_KEYS)

    if math.abs(vertical) < 0.2 then
        if ascendActive and not descendActive then
            vertical = 1
        elseif descendActive and not ascendActive then
            vertical = -1
        elseif ascendActive and descendActive then
            vertical = 0
        else
            vertical = 0
        end
    else
        if ascendActive and descendActive then
            vertical = 0
        end
    end

    local cameraCFrame = camera.CFrame
    local forward = cameraCFrame.LookVector
    local right = cameraCFrame.RightVector

    local desiredDirection = (forward * moveVector.Z) + (right * moveVector.X)

    if math.abs(vertical) > 0.01 then
        desiredDirection += Vector3.new(0, vertical, 0)
    end

    if desiredDirection.Magnitude < 0.05 then
        return Vector3.zero
    end

    desiredDirection = desiredDirection.Unit

    local speed = math.max(humanoid.WalkSpeed, SwimConstants.BaseSwimSpeed)
    return desiredDirection * speed
end

local function update()
    if not currentCharacter then
        return
    end

    local analysis = SwimUtils.AnalyzeCharacter(currentCharacter, analysisBuffer)
    if not analysis then
        clearDesiredVelocity()
        return
    end

    ensureHumanoidState(analysis.humanoid, analysis.shouldSwim)

    if not analysis.shouldSwim then
        clearDesiredVelocity()
        return
    end

    local desiredVelocity = computeDesiredVelocity(analysis)
    local rootPart = analysis.rootPart

    if desiredVelocity == Vector3.zero then
        if lastDesiredVelocity ~= Vector3.zero then
            rootPart:SetAttribute(DESIRED_ATTRIBUTE, Vector3.zero)
            lastDesiredVelocity = Vector3.zero
        end
        return
    end

    local delta = desiredVelocity - lastDesiredVelocity
    if delta:Dot(delta) < UPDATE_THRESHOLD_SQUARED then
        return
    end

    rootPart:SetAttribute(DESIRED_ATTRIBUTE, desiredVelocity)
    lastDesiredVelocity = desiredVelocity
end

LOCAL_PLAYER.CharacterAdded:Connect(setCurrentCharacter)
LOCAL_PLAYER.CharacterRemoving:Connect(function(character)
    clearDesiredVelocity()
    SwimUtils.ClearCharacterCache(character)
    setCurrentCharacter(nil)
end)

if LOCAL_PLAYER.Character then
    setCurrentCharacter(LOCAL_PLAYER.Character)
end

task.defer(function()
    local playerScripts = LOCAL_PLAYER:WaitForChild("PlayerScripts")
    local playerModule = require(playerScripts:WaitForChild("PlayerModule"))
    controls = playerModule:GetControls()
end)

RunService.Heartbeat:Connect(update)
