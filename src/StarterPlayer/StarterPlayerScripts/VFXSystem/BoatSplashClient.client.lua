local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local vfxRemotes = remotesFolder:WaitForChild("VFXSystem")
local boatSplashEvent = vfxRemotes:WaitForChild("BoatSplash")

local TEXTURE_ID = "rbxassetid://121641543712692"
local EFFECT_FOLDER_NAME = "VFXSystem"

local IMPACT_UPWARD_TRANSPARENCY = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(0.4, 0.3),
        NumberSequenceKeypoint.new(1, 1),
})

local IMPACT_MIST_COLOR = ColorSequence.new(Color3.fromRGB(235, 247, 255))
local IMPACT_MIST_TRANSPARENCY = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.35),
        NumberSequenceKeypoint.new(0.8, 0.7),
        NumberSequenceKeypoint.new(1, 1),
})

local UPWARD_COLOR = ColorSequence.new(Color3.new(1, 1, 1))
local WAKE_SPRAY_COLOR = ColorSequence.new(Color3.fromRGB(230, 244, 255))
local WAKE_SPRAY_TRANSPARENCY = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.25),
        NumberSequenceKeypoint.new(0.7, 0.75),
        NumberSequenceKeypoint.new(1, 1),
})

local FULL_ROTATION = NumberRange.new(0, 360)
local IMPACT_SPREAD = Vector2.new(180, 180)
local MIST_SPREAD = Vector2.new(150, 150)
local WAKE_SPREAD = Vector2.new(25, 55)
local ZERO_ROT_SPEED = NumberRange.new(-20, 20)
local IMPACT_ROT_SPEED = NumberRange.new(-45, 45)
local EMIT_TOP = Enum.NormalId.Top
local EMIT_FRONT = Enum.NormalId.Front
local ZERO_LIGHT_INFLUENCE = 0

local effectFolder = Workspace:FindFirstChild(EFFECT_FOLDER_NAME)
if not effectFolder then
        effectFolder = Instance.new("Folder")
        effectFolder.Name = EFFECT_FOLDER_NAME
        effectFolder.Parent = Workspace
end

effectFolder:SetAttribute("ManagedByClient", true)

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = { effectFolder }

local ATTACHMENT_SEARCH_SIZE = Vector3.new(12, 8, 12)

local function findSamplerPart(position, samplerKey)
        if not samplerKey then
                return nil
        end

        local parts = Workspace:GetPartBoundsInBox(CFrame.new(position), ATTACHMENT_SEARCH_SIZE, overlapParams)
        if #parts == 0 then
                return nil
        end

        local bestPart
        local bestDistance = math.huge
        for _, part in ipairs(parts) do
                if part:IsA("BasePart") then
                        local isMatch = false

                        if samplerKey == "Primary" then
                                local parentModel = part.Parent
                                isMatch = parentModel and parentModel:IsA("Model") and parentModel.PrimaryPart == part
                        else
                                isMatch = part.Name == samplerKey
                        end

                        if isMatch then
                                local distance = (part.Position - position).Magnitude
                                if distance < bestDistance then
                                        bestDistance = distance
                                        bestPart = part
                                end
                        end
                end
        end

        return bestPart
end

local function emitImpactBurst(attachment, intensity)
        local impactIntensity = math.clamp(intensity or 0.5, 0, 1)

        local upwardEmitter = Instance.new("ParticleEmitter")
        upwardEmitter.Name = "BoatSplashUpward"
        upwardEmitter.Texture = TEXTURE_ID
        upwardEmitter.Color = UPWARD_COLOR
        upwardEmitter.Transparency = IMPACT_UPWARD_TRANSPARENCY
        upwardEmitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.8 + (impactIntensity * 1.4)),
                NumberSequenceKeypoint.new(0.5, 0.4 + (impactIntensity * 0.6)),
                NumberSequenceKeypoint.new(1, 0),
        })
        upwardEmitter.Lifetime = NumberRange.new(0.4 + impactIntensity * 0.2, 0.7 + impactIntensity * 0.4)
        upwardEmitter.Speed = NumberRange.new(12 + impactIntensity * 10, 18 + impactIntensity * 16)
        upwardEmitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.3, 0)
        upwardEmitter.SpreadAngle = IMPACT_SPREAD
        upwardEmitter.Rotation = FULL_ROTATION
        upwardEmitter.RotSpeed = IMPACT_ROT_SPEED
        upwardEmitter.EmissionDirection = EMIT_TOP
        upwardEmitter.LightInfluence = ZERO_LIGHT_INFLUENCE
        upwardEmitter.Enabled = false
        upwardEmitter.Parent = attachment

        local mistEmitter = Instance.new("ParticleEmitter")
        mistEmitter.Name = "BoatSplashMist"
        mistEmitter.Texture = TEXTURE_ID
        mistEmitter.Color = IMPACT_MIST_COLOR
        mistEmitter.Transparency = IMPACT_MIST_TRANSPARENCY
        mistEmitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1.2 + impactIntensity * 1.8),
                NumberSequenceKeypoint.new(1, 0),
        })
        mistEmitter.Lifetime = NumberRange.new(0.6 + impactIntensity * 0.3, 1 + impactIntensity * 0.5)
        mistEmitter.Speed = NumberRange.new(6 + impactIntensity * 6, 10 + impactIntensity * 8)
        mistEmitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.15, 0)
        mistEmitter.SpreadAngle = MIST_SPREAD
        mistEmitter.Rotation = FULL_ROTATION
        mistEmitter.RotSpeed = ZERO_ROT_SPEED
        mistEmitter.EmissionDirection = EMIT_TOP
        mistEmitter.LightInfluence = ZERO_LIGHT_INFLUENCE
        mistEmitter.Enabled = false
        mistEmitter.Parent = attachment

        local upwardCount = math.max(1, math.floor(6 + impactIntensity * 20))
        local mistCount = math.max(1, math.floor(4 + impactIntensity * 14))

        upwardEmitter:Emit(upwardCount)
        mistEmitter:Emit(mistCount)

        local cleanupDelay = math.max(upwardEmitter.Lifetime.Max, mistEmitter.Lifetime.Max) + 0.5
        Debris:AddItem(attachment, cleanupDelay)
end

local function emitWakeBurst(attachment, intensity)
        local wakeIntensity = math.clamp(intensity or 0.35, 0, 1)

        local parentPart = attachment.Parent
        if parentPart and parentPart:IsA("BasePart") then
                local forward = parentPart.CFrame.LookVector
                local horizontalForward = Vector3.new(forward.X, 0, forward.Z)
                if horizontalForward.Magnitude > 1e-3 then
                        local lookAt = attachment.WorldPosition + horizontalForward.Unit
                        local targetCFrame = CFrame.lookAt(attachment.WorldPosition, lookAt)
                        attachment.CFrame = parentPart.CFrame:ToObjectSpace(targetCFrame)
                end
        end

        local sprayEmitter = Instance.new("ParticleEmitter")
        sprayEmitter.Name = "BoatWakeSpray"
        sprayEmitter.Texture = TEXTURE_ID
        sprayEmitter.Color = WAKE_SPRAY_COLOR
        sprayEmitter.Transparency = WAKE_SPRAY_TRANSPARENCY
        sprayEmitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.45 + wakeIntensity * 0.55),
                NumberSequenceKeypoint.new(1, 0),
        })
        sprayEmitter.Lifetime = NumberRange.new(0.35 + wakeIntensity * 0.2, 0.55 + wakeIntensity * 0.35)
        sprayEmitter.Speed = NumberRange.new(7 + wakeIntensity * 6, 11 + wakeIntensity * 10)
        sprayEmitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.12, 0)
        sprayEmitter.SpreadAngle = WAKE_SPREAD
        sprayEmitter.Rotation = FULL_ROTATION
        sprayEmitter.RotSpeed = ZERO_ROT_SPEED
        sprayEmitter.EmissionDirection = EMIT_FRONT
        sprayEmitter.LightInfluence = ZERO_LIGHT_INFLUENCE
        sprayEmitter.Enabled = false
        sprayEmitter.Parent = attachment

        local sprayCount = math.max(1, math.floor(3 + wakeIntensity * 8))
        sprayEmitter:Emit(sprayCount)

        local cleanupDelay = sprayEmitter.Lifetime.Max + 0.4
        Debris:AddItem(attachment, cleanupDelay)
end

local function createSplashEffect(payload, legacyIntensity)
        local eventPayload = payload

        if typeof(payload) ~= "table" then
                eventPayload = {
                        position = payload,
                        intensity = legacyIntensity,
                        effectType = "Impact",
                }
        end

        if typeof(eventPayload) ~= "table" then
                return
        end

        local position = eventPayload.position
        if typeof(position) ~= "Vector3" then
                return
        end

        local samplerKey = eventPayload.samplerKey
        local effectType = eventPayload.effectType or "Impact"
        local intensity = math.clamp(eventPayload.intensity or 0, 0, 1)

        local targetPart = findSamplerPart(position, samplerKey)
        local attachment = Instance.new("Attachment")

        if targetPart then
                attachment.Parent = targetPart
        else
                attachment.Parent = effectFolder
        end

        attachment.WorldPosition = position

        if effectType == "Wake" then
                emitWakeBurst(attachment, intensity)
        else
                emitImpactBurst(attachment, intensity)
        end
end

boatSplashEvent.OnClientEvent:Connect(createSplashEffect)
