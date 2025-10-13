-- WaterEffectsClient.lua
-- Place in: StarterPlayer/StarterPlayerScripts/WaterEffectsClient.lua
-- Handles client-side water effects and ambiance

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

-- Water effect settings
local WATER_LEVEL = 908.935
local UNDERWATER_FOG_COLOR = Color3.fromRGB(10, 50, 80)
local SURFACE_FOG_COLOR = Lighting.FogColor
local UNDERWATER_FOG_START = 10
local UNDERWATER_FOG_END = 100

-- Track player state
local isUnderwater = false
local currentBoat = nil
local waterSounds = {}

-- Create water sounds
local function CreateWaterSounds()
	local soundFolder = Instance.new("Folder")
	soundFolder.Name = "WaterSounds"
	soundFolder.Parent = workspace.CurrentCamera

	-- Wave/ocean ambient sound
	local waveSound = Instance.new("Sound")
	waveSound.Name = "WaveAmbience"
	waveSound.SoundId = "rbxasset://sounds/0.mp3" -- Replace with ocean sound ID
	waveSound.Volume = 0.3
	waveSound.Looped = true
	waveSound.Parent = soundFolder
	waterSounds.waves = waveSound

	-- Underwater ambient sound
	local underwaterSound = Instance.new("Sound")
	underwaterSound.Name = "UnderwaterAmbience"
	underwaterSound.SoundId = "rbxasset://sounds/0.mp3" -- Replace with underwater sound ID
	underwaterSound.Volume = 0.5
	underwaterSound.Looped = true
	underwaterSound.Parent = soundFolder
	waterSounds.underwater = underwaterSound

	-- Splash sound for entering/exiting water
	local splashSound = Instance.new("Sound")
	splashSound.Name = "Splash"
	splashSound.SoundId = "rbxasset://sounds/0.mp3" -- Replace with splash sound ID
	splashSound.Volume = 0.7
	splashSound.Parent = soundFolder
	waterSounds.splash = splashSound
end

-- Update underwater effects
local function UpdateUnderwaterEffects()
	local character = player.Character
	if not character then return end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then return end

	local position = humanoidRootPart.Position
	local wasUnderwater = isUnderwater
	isUnderwater = WaterPhysics.IsUnderwater(position)

	-- Transition effects when entering/leaving water
	if isUnderwater ~= wasUnderwater then
		if isUnderwater then
			-- Entering water
			if waterSounds.splash then
				waterSounds.splash:Play()
			end

			-- Tween to underwater fog
			local fogTween = TweenService:Create(
				Lighting,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad),
				{
					FogColor = UNDERWATER_FOG_COLOR,
					FogStart = UNDERWATER_FOG_START,
					FogEnd = UNDERWATER_FOG_END
				}
			)
			fogTween:Play()

			-- Start underwater sound
			if waterSounds.underwater then
				waterSounds.underwater:Play()
			end
			if waterSounds.waves then
				waterSounds.waves:Stop()
			end

			-- Add underwater color correction
			local colorCorrection = Lighting:FindFirstChild("UnderwaterColorCorrection")
			if not colorCorrection then
				colorCorrection = Instance.new("ColorCorrectionEffect")
				colorCorrection.Name = "UnderwaterColorCorrection"
				colorCorrection.TintColor = Color3.fromRGB(150, 200, 255)
				colorCorrection.Brightness = -0.1
				colorCorrection.Contrast = 0.2
				colorCorrection.Parent = Lighting
			end
			colorCorrection.Enabled = true

		else
			-- Exiting water
			if waterSounds.splash then
				waterSounds.splash:Play()
			end

			-- Tween back to normal fog
			local fogTween = TweenService:Create(
				Lighting,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad),
				{
					FogColor = SURFACE_FOG_COLOR,
					FogStart = 0,
					FogEnd = 100000
				}
			)
			fogTween:Play()

			-- Switch to wave sounds
			if waterSounds.underwater then
				waterSounds.underwater:Stop()
			end
			if waterSounds.waves then
				waterSounds.waves:Play()
			end

			-- Remove underwater color correction
			local colorCorrection = Lighting:FindFirstChild("UnderwaterColorCorrection")
			if colorCorrection then
				colorCorrection.Enabled = false
			end
		end
	end

	-- Update depth-based visibility if underwater
	if isUnderwater then
		local visibility = WaterPhysics.GetVisibilityAtDepth(position)
		Lighting.FogEnd = UNDERWATER_FOG_START + (UNDERWATER_FOG_END * visibility)

		-- Adjust color based on depth
		local depth = WATER_LEVEL - position.Y
		local deepColor = Color3.fromRGB(5, 20, 40)
		local shallowColor = Color3.fromRGB(10, 50, 80)
		local depthRatio = math.clamp(depth / 200, 0, 1)
		Lighting.FogColor = shallowColor:Lerp(deepColor, depthRatio)
	end
end

-- Check if player is in a boat
local function CheckBoatStatus()
	local character = player.Character
	if not character then 
		currentBoat = nil
		return 
	end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then 
		currentBoat = nil
		return 
	end

	if humanoid.Sit then
		-- Check if sitting in a boat
		for _, boat in pairs(workspace:GetChildren()) do
			if boat:GetAttribute("OwnerId") then
				local seat = boat:FindFirstChildOfClass("VehicleSeat")
				if seat and seat.Occupant == humanoid then
					currentBoat = boat
					return
				end
			end
		end
	end

	currentBoat = nil
end

-- Create screen water droplets effect (optional)
local function CreateWaterDroplets()
	local screenGui = player.PlayerGui:FindFirstChild("WaterEffects")
	if not screenGui then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "WaterEffects"
		screenGui.IgnoreGuiInset = true
		screenGui.Parent = player.PlayerGui
	end

	-- Create droplet frames (simple version)
	for i = 1, 5 do
		local droplet = Instance.new("Frame")
		droplet.Size = UDim2.new(0, math.random(2, 5), 0, math.random(10, 20))
		droplet.Position = UDim2.new(math.random(), 0, -0.1, 0)
		droplet.BackgroundColor3 = Color3.new(0.7, 0.8, 1)
		droplet.BackgroundTransparency = 0.3
		droplet.BorderSizePixel = 0
		droplet.Parent = screenGui

		-- Animate droplet falling
		local fallTween = TweenService:Create(
			droplet,
			TweenInfo.new(
				math.random() * 2 + 1,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			),
			{
				Position = UDim2.new(droplet.Position.X.Scale, 0, 1.1, 0),
				BackgroundTransparency = 1
			}
		)

		fallTween.Completed:Connect(function()
			droplet:Destroy()
		end)

		fallTween:Play()
	end
end

-- Main update loop
local function UpdateWaterEffects()
	UpdateUnderwaterEffects()
	CheckBoatStatus()

	-- Add water droplets when emerging from water
	if not isUnderwater and player.Character then
		local hrp = player.Character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp.AssemblyLinearVelocity.Y > 10 then
			-- Moving up quickly (jumping out of water)
			CreateWaterDroplets()
		end
	end

	-- Update wave sounds volume based on distance to water
	if not isUnderwater and waterSounds.waves then
		local character = player.Character
		if character and character.PrimaryPart then
			local distanceToWater = math.abs(character.PrimaryPart.Position.Y - WATER_LEVEL)
			local volume = math.clamp(1 - (distanceToWater / 50), 0, 0.5)
			waterSounds.waves.Volume = volume
		end
	end
end

-- Initialize
CreateWaterSounds()

-- Start near-surface wave sounds
if waterSounds.waves then
	waterSounds.waves:Play()
end

-- Connect update loop
RunService.Heartbeat:Connect(UpdateWaterEffects)

print("Water Effects system initialized")
print("Features: Underwater fog, depth visibility, water sounds, splash effects")