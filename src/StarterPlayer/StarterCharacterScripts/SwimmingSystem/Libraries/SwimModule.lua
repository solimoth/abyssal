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
        UpdateSurfaceState = noop,
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
local surfaceState
local surfaceOffset
local depthOffset
local lastSurfaced = false

local SURFACE_RESPONSIVENESS = 6
local SURFACE_FLOAT_OFFSET = 0 -- keep the humanoid root aligned with the wave crest so the swimmer rides midway on the surface

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
        local moveDirection = humanoid.MoveDirection
        local moving = moveDirection.Magnitude > 0
        local desiredVelocityY: number? = nil

        if surfaceState then
            local rootSample = surfaceState.RootSample
            local surfacedHeight: number? = nil
            if surfaceState.Surfaced and rootSample and rootSample.DynamicHeight then
                surfacedHeight = rootSample.DynamicHeight
            end

            if surfacedHeight then
                local descending = moveDirection.Y < -0.1
                if descending then
                    surfaceOffset = nil
                    lastSurfaced = false
                    depthOffset = nil
                else
                    if not lastSurfaced or surfaceOffset == nil then
                        surfaceOffset = SURFACE_FLOAT_OFFSET
                    end

                    local targetY = surfacedHeight + surfaceOffset
                    desiredVelocityY = math.clamp((targetY - rootPart.Position.Y) * SURFACE_RESPONSIVENESS, -20, 20)
                    lastSurfaced = true
                    depthOffset = nil
                end
            else
                surfaceOffset = nil
                lastSurfaced = false

                local lowerSample = surfaceState.LowerSample
                if lowerSample and lowerSample.EffectiveHeight and not moving then
                    if depthOffset == nil then
                        depthOffset = rootPart.Position.Y - lowerSample.EffectiveHeight
                    end

                    local targetY = lowerSample.EffectiveHeight + depthOffset
                    desiredVelocityY = math.clamp((targetY - rootPart.Position.Y) * SURFACE_RESPONSIVENESS, -20, 20)
                else
                    depthOffset = nil
                end
            end
        else
            surfaceOffset = nil
            depthOffset = nil
            lastSurfaced = false
        end

        local velocity = rootPart.AssemblyLinearVelocity

        if desiredVelocityY then
            local newX = moving and velocity.X or 0
            local newZ = moving and velocity.Z or 0

            if velocity.X ~= newX or velocity.Y ~= desiredVelocityY or velocity.Z ~= newZ then
                rootPart.AssemblyLinearVelocity = Vector3.new(newX, desiredVelocityY, newZ)
            end
        elseif not moving then
            if math.abs(velocity.X) > 1e-3 or math.abs(velocity.Z) > 1e-3 then
                rootPart.AssemblyLinearVelocity = Vector3.new(0, velocity.Y, 0)
            end
        end
    end)
end

function swimModule:Stop()
    if not self.Enabled then
        return
    end

    self.Enabled = false
    humStates(true, Enum.HumanoidStateType.Freefall)
    antiGrav(false)
    surfaceState = nil
    surfaceOffset = nil
    depthOffset = nil
    lastSurfaced = false

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

function swimModule:UpdateSurfaceState(state)
    if not self.Enabled then
        surfaceState = nil
        surfaceOffset = nil
        depthOffset = nil
        lastSurfaced = false
        return
    end

    surfaceState = state
    if not state then
        surfaceOffset = nil
        depthOffset = nil
        lastSurfaced = false
        return
    end

    if state.Surfaced then
        depthOffset = nil
    else
        surfaceOffset = nil
        lastSurfaced = false
    end
end

return setmetatable({ Enabled = false }, swimModule)
