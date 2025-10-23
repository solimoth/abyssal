local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("WaterPhysics"))
local SwimInteriorUtils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SwimInteriorUtils"))

local Libraries = script:WaitForChild("Libraries")
local swimModule = require(Libraries:WaitForChild("SwimModule"))
local lightingModule = require(Libraries:WaitForChild("UnderwaterLighting"))

local player = Players.LocalPlayer
local character = script.Parent
if not character or not character:IsA("Model") then
    character = player.Character or player.CharacterAdded:Wait()
end

repeat
    RunService.Heartbeat:Wait()
until character:FindFirstChildOfClass("Humanoid")

local humanoid = character:FindFirstChildOfClass("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

local isTouchScreen = UserInputService.TouchEnabled

local detectorOffsets = {
    Upper = Vector3.new(0, 1, -0.75),
    Lower = Vector3.new(0, -2.572, -0.75),
    Head = Vector3.new(0, 1.322, -0.75),
}

local CONFIG = {
    AscendForceScale = 1.12,
    IdleForceScale = 0.88,
    EntryDepth = 0.1,
    HeadDepth = 0.05,
    MobileExitCooldown = 0.25,
}

local function isInputDown(keyCodes, pressed)
    for _, keyCode in ipairs(keyCodes) do
        if pressed[keyCode] then
            return true
        end
    end
    return false
end

local function buildPressedKeySet()
    local set = {}
    for _, input in ipairs(UserInputService:GetKeysPressed()) do
        set[input.KeyCode] = true
    end
    return set
end

local gotOut = false
local tapConnection
local debounce = false
local heartbeatConnection

local function gOut()
    if not swimModule.Enabled then
        return
    end

    swimModule:GetOut()
    swimModule:Stop()
    gotOut = true

    if isTouchScreen then
        debounce = true
        task.delay(CONFIG.MobileExitCooldown, function()
            debounce = false
        end)
    end
end

local function depthAt(position: Vector3)
    local surfaceY = WaterPhysics.TryGetWaterSurface(position)
    if not surfaceY then
        return 0
    end
    return math.max(0, surfaceY - position.Y)
end

local function computeDetectorStatus(rootCFrame: CFrame, insideInterior: boolean)
    if insideInterior then
        return false, false, false, false
    end

    local upperPosition = rootCFrame:PointToWorldSpace(detectorOffsets.Upper)
    local lowerPosition = rootCFrame:PointToWorldSpace(detectorOffsets.Lower)
    local headPosition = rootCFrame:PointToWorldSpace(detectorOffsets.Head)

    local upperDepth = depthAt(upperPosition)
    local lowerDepth = depthAt(lowerPosition)
    local headDepth = depthAt(headPosition)

    local isUpperIn = upperDepth > CONFIG.EntryDepth
    local isLowerIn = lowerDepth > CONFIG.EntryDepth
    local isHeadIn = headDepth > CONFIG.HeadDepth

    local camera = Workspace.CurrentCamera
    local isCameraIn = false
    if camera then
        local cameraDepth = depthAt(camera.CFrame.Position)
        isCameraIn = cameraDepth > CONFIG.EntryDepth
    end

    return isUpperIn, isLowerIn, isHeadIn, isCameraIn
end

local function onHeartbeat()
    if debounce then
        return
    end

    if tapConnection then
        tapConnection:Disconnect()
        tapConnection = nil
    end

    local insideInterior = SwimInteriorUtils.IsInsideShipInterior(character)

    local rootCFrame = rootPart.CFrame
    local isUpperIn, isLowerIn, isHeadIn, isCameraIn = computeDetectorStatus(rootCFrame, insideInterior)

    if not insideInterior and not isUpperIn and not isLowerIn then
        gotOut = false
    end

    local pressed = buildPressedKeySet()
    local jumpKeys = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA }

    if (pressed[Enum.KeyCode.Space] or pressed[Enum.KeyCode.ButtonA]) and not isHeadIn and isLowerIn then
        gOut()
    end

    if isUpperIn and isLowerIn and not insideInterior then
        swimModule:Start()
        if gotOut then
            swimModule:CreateAntiGrav()
            gotOut = false
        end
    elseif not isUpperIn and not isLowerIn then
        swimModule:Stop()
    elseif not isUpperIn and isLowerIn then
        swimModule:ClearAntiGrav()
        gotOut = true
    end

    local force = rootPart:FindFirstChildOfClass("VectorForce")
    if force then
        local defaultForce = rootPart.AssemblyMass * Workspace.Gravity
        if isInputDown(jumpKeys, pressed) then
            force.Force = Vector3.new(0, defaultForce * CONFIG.AscendForceScale, 0)
        else
            if humanoid.MoveDirection.Magnitude == 0 then
                if isHeadIn then
                    force.Force = Vector3.new(0, defaultForce * CONFIG.IdleForceScale, 0)
                else
                    force.Force = Vector3.new(0, defaultForce, 0)
                end
            else
                force.Force = Vector3.new(0, defaultForce, 0)
            end
        end
    end

    tapConnection = UserInputService.TouchTapInWorld:Connect(function()
        if not swimModule.Enabled or isHeadIn or not isLowerIn then
            return
        end
        gOut()
    end)

    if isCameraIn and not insideInterior then
        lightingModule:Add()
    else
        lightingModule:Remove()
    end
end

heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)

local function onDied()
    lightingModule:Remove()
    if heartbeatConnection then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
    if tapConnection then
        tapConnection:Disconnect()
        tapConnection = nil
    end
    SwimInteriorUtils.ClearCharacterCache(character)
end

if humanoid then
    humanoid.Died:Connect(onDied)
end

script.Destroying:Connect(function()
    onDied()
    swimModule:Stop()
    lightingModule:Destroy()
    SwimInteriorUtils.ClearCharacterCache(character)
end)
