local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local vfxRemotes = remotesFolder:WaitForChild("VFXSystem")
local boatSplashEvent = vfxRemotes:WaitForChild("BoatSplash")

local TEXTURE_ID = "rbxassetid://121641543712692"
local EFFECT_FOLDER_NAME = "VFXSystem"

local effectFolder = Workspace:FindFirstChild(EFFECT_FOLDER_NAME)
if not effectFolder then
        effectFolder = Instance.new("Folder")
        effectFolder.Name = EFFECT_FOLDER_NAME
        effectFolder.Parent = Workspace
end

effectFolder:SetAttribute("ManagedByClient", true)

local function createSplashEffect(position, intensity)
        intensity = math.clamp(intensity or 0.5, 0, 1)

        local attachment = Instance.new("Attachment")
        attachment.WorldPosition = position
        attachment.Parent = effectFolder

        local upwardEmitter = Instance.new("ParticleEmitter")
        upwardEmitter.Name = "BoatSplashUpward"
        upwardEmitter.Texture = TEXTURE_ID
        upwardEmitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
        upwardEmitter.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.1),
                NumberSequenceKeypoint.new(0.4, 0.3),
                NumberSequenceKeypoint.new(1, 1),
        })
        upwardEmitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.8 + (intensity * 1.4)),
                NumberSequenceKeypoint.new(0.5, 0.4 + (intensity * 0.6)),
                NumberSequenceKeypoint.new(1, 0),
        })
        upwardEmitter.Lifetime = NumberRange.new(0.4 + intensity * 0.2, 0.7 + intensity * 0.4)
        upwardEmitter.Speed = NumberRange.new(12 + intensity * 10, 18 + intensity * 16)
        upwardEmitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.3, 0)
        upwardEmitter.SpreadAngle = Vector2.new(180, 180)
        upwardEmitter.Rotation = NumberRange.new(0, 360)
        upwardEmitter.RotSpeed = NumberRange.new(-45, 45)
        upwardEmitter.EmissionDirection = Enum.NormalId.Top
        upwardEmitter.LightInfluence = 0
        upwardEmitter.Enabled = false
        upwardEmitter.Parent = attachment

        local mistEmitter = Instance.new("ParticleEmitter")
        mistEmitter.Name = "BoatSplashMist"
        mistEmitter.Texture = TEXTURE_ID
        mistEmitter.Color = ColorSequence.new(Color3.fromRGB(235, 247, 255))
        mistEmitter.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.35),
                NumberSequenceKeypoint.new(0.8, 0.7),
                NumberSequenceKeypoint.new(1, 1),
        })
        mistEmitter.Size = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1.2 + intensity * 1.8),
                NumberSequenceKeypoint.new(1, 0),
        })
        mistEmitter.Lifetime = NumberRange.new(0.6 + intensity * 0.3, 1 + intensity * 0.5)
        mistEmitter.Speed = NumberRange.new(6 + intensity * 6, 10 + intensity * 8)
        mistEmitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.15, 0)
        mistEmitter.SpreadAngle = Vector2.new(150, 150)
        mistEmitter.Rotation = NumberRange.new(0, 360)
        mistEmitter.RotSpeed = NumberRange.new(-20, 20)
        mistEmitter.EmissionDirection = Enum.NormalId.Top
        mistEmitter.LightInfluence = 0
        mistEmitter.Enabled = false
        mistEmitter.Parent = attachment

        local upwardCount = math.max(1, math.floor(6 + intensity * 20))
        local mistCount = math.max(1, math.floor(4 + intensity * 14))

        upwardEmitter:Emit(upwardCount)
        mistEmitter:Emit(mistCount)

        local cleanupDelay = math.max(upwardEmitter.Lifetime.Max, mistEmitter.Lifetime.Max) + 0.5
        Debris:AddItem(attachment, cleanupDelay)
end

boatSplashEvent.OnClientEvent:Connect(createSplashEffect)
