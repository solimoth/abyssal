local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local swimModule = {}
swimModule.__index = swimModule

if RunService:IsServer() then
    local noop = function() end
    return setmetatable({
        Enabled = false,
        Start = noop,
        Stop = noop,
        ClearAntiGrav = noop,
        CreateAntiGrav = noop,
        GetOut = noop,
        ActivateStates = noop,
    }, swimModule)
end

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()

repeat
    RunService.Heartbeat:Wait()
until character:FindFirstChildOfClass("Humanoid")

local humanoid = character:FindFirstChildOfClass("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

local attachments = {}
local forces = {}

local function humStates(activate: boolean, newState: Enum.HumanoidStateType)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, activate)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, activate)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, activate)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, activate)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, activate)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, activate)

    humanoid:ChangeState(newState)
end

local function antiGrav(enable: boolean)
    if enable then
        if #attachments > 0 or #forces > 0 then
            return
        end

        local mass = rootPart.AssemblyMass

        local attachment = Instance.new("Attachment")
        attachment.Name = "SwimAttachment"
        attachment.WorldPosition = rootPart.Position
        attachment.Parent = rootPart
        table.insert(attachments, attachment)

        local vectorForce = Instance.new("VectorForce")
        vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
        vectorForce.Force = Vector3.new(0, workspace.Gravity * mass, 0)
        vectorForce.Attachment0 = attachment
        vectorForce.ApplyAtCenterOfMass = true
        vectorForce.Name = "SwimVectorForce"
        vectorForce.Parent = rootPart
        table.insert(forces, vectorForce)

        return attachment, vectorForce
    end

    for index = #attachments, 1, -1 do
        local attachment = attachments[index]
        attachments[index] = nil
        attachment:Destroy()
    end

    for index = #forces, 1, -1 do
        local force = forces[index]
        forces[index] = nil
        force:Destroy()
    end
end

function swimModule:Start()
    if self.Enabled then
        return
    end

    humStates(false, Enum.HumanoidStateType.Swimming)
    antiGrav(true)

    self.Enabled = true

    self.heartbeatConnection = RunService.Heartbeat:Connect(function()
        if humanoid.MoveDirection.Magnitude > 0 then
            return
        end
        rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    end)
end

function swimModule:Stop()
    if not self.Enabled then
        return
    end

    self.Enabled = false
    humStates(true, Enum.HumanoidStateType.Freefall)
    antiGrav(false)

    if self.heartbeatConnection then
        self.heartbeatConnection:Disconnect()
        self.heartbeatConnection = nil
    end
end

function swimModule:ClearAntiGrav()
    antiGrav(false)
end

function swimModule:CreateAntiGrav()
    task.delay(0.05, function()
        rootPart.AssemblyLinearVelocity = Vector3.new()
    end)
    antiGrav(true)
end

function swimModule:GetOut()
    humStates(true, Enum.HumanoidStateType.Jumping)
end

function swimModule:ActivateStates()
    humStates(false, Enum.HumanoidStateType.Swimming)
end

return setmetatable({ Enabled = false }, swimModule)
