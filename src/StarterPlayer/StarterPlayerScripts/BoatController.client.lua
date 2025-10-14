-- BoatController.lua (ENHANCED WITH ACCELERATION)
-- Place in: StarterPlayer/StarterPlayerScripts/BoatController.lua
-- Now includes weight-based acceleration and deceleration

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Camera = workspace.CurrentCamera

local player = Players.LocalPlayer
local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)

-- Variables
local currentBoat = nil
local currentSeat = nil
local isControlling = false
local boatConfig = nil
local isSubmarine = false

-- Boat selection
local selectedBoatType = "StarterRaft"
local availableBoats = {"StarterRaft", "TestSubmarine"}
local selectedBoatIndex = 1

-- Camera settings
local cameraConnection = nil
local cameraMode = "Default"
local cameraOffset = Vector3.new(0, 20, 35)
local cameraRotation = 0
local cameraSmoothness = 0.2
local cameraDistance = 35
local targetCameraDistance = 35

-- Submarine controls
local submarineControls = {
	ascend = 0,
	pitch = 0,
	roll = 0
}
local controlUpdateConnection = nil
local lastControlUpdate = 0
local CONTROL_UPDATE_RATE = 1/60
local submarineMode = "surface"
local WATER_LEVEL = 908.935
local activeDiveTask = nil

-- HUD elements
local hudGui = nil
local hudFrame = nil
local hudElements = {}
local hudTweens = {
        throttle = nil,
        speed = nil,
        fade = nil,
}
local hudState = {
        throttleValue = 0,
        speedPercent = 0,
}
local hudFadeToken = 0
local lastHudUpdate = 0

-- ACCELERATION SYSTEM VARIABLES
local currentSpeed = 0
local targetSpeed = 0
local currentTurnSpeed = 0
local targetTurnSpeed = 0
local accelerationRate = 12
local decelerationRate = 8
local turnAccelerationRate = 3
local maxSpeed = 25
local boatWeight = 3

-- Submarine rotation acceleration
local currentPitchSpeed = 0
local targetPitchSpeed = 0
local currentRollSpeed = 0
local targetRollSpeed = 0
local pitchAccelerationRate = 2
local rollAccelerationRate = 2

-- Smooth input handling
local inputSmoothness = 0.15
local smoothedThrottle = 0
local smoothedSteer = 0

local function EnsureHud()
        local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:FindFirstChild("PlayerGui")
        if not playerGui then
                playerGui = player:WaitForChild("PlayerGui", 5)
        end

        if not playerGui then
                return false
        end

        if not hudGui then
                hudGui = Instance.new("ScreenGui")
                hudGui.Name = "BoatHUD"
                hudGui.IgnoreGuiInset = true
                hudGui.ResetOnSpawn = false
                hudGui.DisplayOrder = 5
                hudGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                hudGui.Enabled = false

                hudFrame = Instance.new("Frame")
                hudFrame.Name = "Container"
                hudFrame.AnchorPoint = Vector2.new(0.5, 1)
                hudFrame.Position = UDim2.new(0.5, 0, 1, 30)
                hudFrame.Size = UDim2.new(0, 360, 0, 160)
                hudFrame.BackgroundColor3 = Color3.fromRGB(8, 14, 24)
                hudFrame.BackgroundTransparency = 0.25
                hudFrame.BorderSizePixel = 0
                hudFrame.ZIndex = 2
                hudFrame.Visible = false
                hudFrame.Parent = hudGui

                local shadow = Instance.new("ImageLabel")
                shadow.Name = "Shadow"
                shadow.AnchorPoint = Vector2.new(0.5, 1)
                shadow.Position = UDim2.new(0.5, 0, 1, 12)
                shadow.Size = UDim2.new(1.05, 0, 1.2, 18)
                shadow.Image = "rbxassetid://1316045217"
                shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
                shadow.ImageTransparency = 0.65
                shadow.ScaleType = Enum.ScaleType.Slice
                shadow.SliceCenter = Rect.new(10, 10, 118, 118)
                shadow.BackgroundTransparency = 1
                shadow.ZIndex = 0
                shadow.Parent = hudFrame

                local corner = Instance.new("UICorner")
                corner.CornerRadius = UDim.new(0, 18)
                corner.Parent = hudFrame

                local stroke = Instance.new("UIStroke")
                stroke.Thickness = 1.5
                stroke.Color = Color3.fromRGB(24, 86, 132)
                stroke.Transparency = 0.2
                stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                stroke.Parent = hudFrame

                local gradient = Instance.new("UIGradient")
                gradient.Rotation = 90
                gradient.Color = ColorSequence.new({
                        ColorSequenceKeypoint.new(0, Color3.fromRGB(32, 94, 150)),
                        ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 12, 20)),
                })
                gradient.Transparency = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0.05),
                        NumberSequenceKeypoint.new(1, 0.45),
                })
                gradient.Parent = hudFrame

                local header = Instance.new("TextLabel")
                header.Name = "Header"
                header.BackgroundTransparency = 1
                header.Position = UDim2.new(0, 18, 0, 14)
                header.Size = UDim2.new(0.45, 0, 0, 20)
                header.Font = Enum.Font.GothamSemibold
                header.Text = "NAVIGATION CONSOLE"
                header.TextSize = 14
                header.TextColor3 = Color3.fromRGB(198, 224, 255)
                header.TextTransparency = 0.1
                header.TextXAlignment = Enum.TextXAlignment.Left
                header.Parent = hudFrame

                local boatLabel = Instance.new("TextLabel")
                boatLabel.Name = "BoatLabel"
                boatLabel.BackgroundTransparency = 1
                boatLabel.Position = UDim2.new(0, 18, 0, 36)
                boatLabel.Size = UDim2.new(1, -36, 0, 22)
                boatLabel.Font = Enum.Font.GothamBold
                boatLabel.Text = ""
                boatLabel.TextSize = 18
                boatLabel.TextColor3 = Color3.fromRGB(205, 235, 255)
                boatLabel.TextXAlignment = Enum.TextXAlignment.Left
                boatLabel.Parent = hudFrame

                local speedValue = Instance.new("TextLabel")
                speedValue.Name = "SpeedValue"
                speedValue.BackgroundTransparency = 1
                speedValue.Position = UDim2.new(0, 18, 0, 62)
                speedValue.Size = UDim2.new(0.55, 0, 0, 58)
                speedValue.Font = Enum.Font.GothamBlack
                speedValue.Text = "000"
                speedValue.TextColor3 = Color3.fromRGB(255, 255, 255)
                speedValue.TextTransparency = 0.1
                speedValue.TextScaled = true
                speedValue.TextXAlignment = Enum.TextXAlignment.Left
                speedValue.Parent = hudFrame

                local speedUnit = Instance.new("TextLabel")
                speedUnit.Name = "SpeedUnit"
                speedUnit.BackgroundTransparency = 1
                speedUnit.Position = UDim2.new(0, 190, 0, 76)
                speedUnit.Size = UDim2.new(0, 120, 0, 30)
                speedUnit.Font = Enum.Font.GothamMedium
                speedUnit.Text = "STUDS/SEC"
                speedUnit.TextSize = 16
                speedUnit.TextColor3 = Color3.fromRGB(160, 205, 255)
                speedUnit.TextTransparency = 0.2
                speedUnit.TextXAlignment = Enum.TextXAlignment.Left
                speedUnit.Parent = hudFrame

                local detailLabel = Instance.new("TextLabel")
                detailLabel.Name = "DetailLabel"
                detailLabel.BackgroundTransparency = 1
                detailLabel.Position = UDim2.new(0, 18, 0, 116)
                detailLabel.Size = UDim2.new(0.7, 0, 0, 20)
                detailLabel.Font = Enum.Font.Gotham
                detailLabel.Text = ""
                detailLabel.TextColor3 = Color3.fromRGB(168, 208, 255)
                detailLabel.TextSize = 14
                detailLabel.TextTransparency = 0.15
                detailLabel.TextXAlignment = Enum.TextXAlignment.Left
                detailLabel.Parent = hudFrame

                local cameraLabel = Instance.new("TextLabel")
                cameraLabel.Name = "CameraLabel"
                cameraLabel.BackgroundTransparency = 1
                cameraLabel.Position = UDim2.new(0, 18, 1, -32)
                cameraLabel.Size = UDim2.new(0.4, 0, 0, 18)
                cameraLabel.Font = Enum.Font.GothamSemibold
                cameraLabel.Text = "CAM: DEFAULT"
                cameraLabel.TextSize = 12
                cameraLabel.TextColor3 = Color3.fromRGB(190, 230, 255)
                cameraLabel.TextTransparency = 0.1
                cameraLabel.TextXAlignment = Enum.TextXAlignment.Left
                cameraLabel.Parent = hudFrame

                local statusLabel = Instance.new("TextLabel")
                statusLabel.Name = "StatusLabel"
                statusLabel.BackgroundTransparency = 1
                statusLabel.Position = UDim2.new(1, -160, 0, 16)
                statusLabel.Size = UDim2.new(0, 140, 0, 18)
                statusLabel.Font = Enum.Font.GothamSemibold
                statusLabel.Text = ""
                statusLabel.TextSize = 13
                statusLabel.TextColor3 = Color3.fromRGB(140, 225, 200)
                statusLabel.TextTransparency = 0.15
                statusLabel.TextXAlignment = Enum.TextXAlignment.Right
                statusLabel.Parent = hudFrame

                local speedMeter = Instance.new("Frame")
                speedMeter.Name = "SpeedMeter"
                speedMeter.BackgroundColor3 = Color3.fromRGB(14, 28, 44)
                speedMeter.BackgroundTransparency = 0.2
                speedMeter.BorderSizePixel = 0
                speedMeter.AnchorPoint = Vector2.new(0.5, 1)
                speedMeter.Position = UDim2.new(0.5, 0, 1, -58)
                speedMeter.Size = UDim2.new(0.78, 0, 0, 16)
                speedMeter.Parent = hudFrame

                local speedMeterCorner = Instance.new("UICorner")
                speedMeterCorner.CornerRadius = UDim.new(0, 8)
                speedMeterCorner.Parent = speedMeter

                local speedMeterStroke = Instance.new("UIStroke")
                speedMeterStroke.Thickness = 1
                speedMeterStroke.Color = Color3.fromRGB(40, 120, 190)
                speedMeterStroke.Transparency = 0.45
                speedMeterStroke.Parent = speedMeter

                local speedFill = Instance.new("Frame")
                speedFill.Name = "SpeedFill"
                speedFill.AnchorPoint = Vector2.new(0, 0.5)
                speedFill.Position = UDim2.new(0, 0, 0.5, 0)
                speedFill.Size = UDim2.new(0, 0, 1, 0)
                speedFill.BackgroundColor3 = Color3.fromRGB(60, 190, 255)
                speedFill.BackgroundTransparency = 0
                speedFill.BorderSizePixel = 0
                speedFill.Parent = speedMeter

                local speedFillCorner = Instance.new("UICorner")
                speedFillCorner.CornerRadius = UDim.new(0, 8)
                speedFillCorner.Parent = speedFill

                local speedFillGradient = Instance.new("UIGradient")
                speedFillGradient.Color = ColorSequence.new({
                        ColorSequenceKeypoint.new(0, Color3.fromRGB(74, 232, 255)),
                        ColorSequenceKeypoint.new(1, Color3.fromRGB(46, 146, 255)),
                })
                speedFillGradient.Parent = speedFill

                local throttleContainer = Instance.new("Frame")
                throttleContainer.Name = "ThrottleContainer"
                throttleContainer.BackgroundTransparency = 1
                throttleContainer.Position = UDim2.new(0.11, 0, 1, -34)
                throttleContainer.Size = UDim2.new(0.78, 0, 0, 18)
                throttleContainer.Parent = hudFrame

                local throttleTrack = Instance.new("Frame")
                throttleTrack.Name = "ThrottleTrack"
                throttleTrack.AnchorPoint = Vector2.new(0.5, 0.5)
                throttleTrack.Position = UDim2.new(0.5, 0, 0.5, 0)
                throttleTrack.Size = UDim2.new(1, 0, 0, 6)
                throttleTrack.BackgroundColor3 = Color3.fromRGB(20, 48, 66)
                throttleTrack.BackgroundTransparency = 0.2
                throttleTrack.BorderSizePixel = 0
                throttleTrack.Parent = throttleContainer

                local throttleCorner = Instance.new("UICorner")
                throttleCorner.CornerRadius = UDim.new(0, 3)
                throttleCorner.Parent = throttleTrack

                local throttleIndicator = Instance.new("Frame")
                throttleIndicator.Name = "ThrottleIndicator"
                throttleIndicator.AnchorPoint = Vector2.new(0.5, 0.5)
                throttleIndicator.Position = UDim2.new(0.5, 0, 0.5, 0)
                throttleIndicator.Size = UDim2.new(0, 16, 0, 16)
                throttleIndicator.BackgroundColor3 = Color3.fromRGB(72, 210, 170)
                throttleIndicator.BorderSizePixel = 0
                throttleIndicator.Parent = throttleContainer

                local throttleIndicatorCorner = Instance.new("UICorner")
                throttleIndicatorCorner.CornerRadius = UDim.new(1, 0)
                throttleIndicatorCorner.Parent = throttleIndicator

                local throttleStroke = Instance.new("UIStroke")
                throttleStroke.Thickness = 1
                throttleStroke.Color = Color3.fromRGB(12, 24, 34)
                throttleStroke.Transparency = 0.2
                throttleStroke.Parent = throttleIndicator

                local depthContainer = Instance.new("Frame")
                depthContainer.Name = "DepthContainer"
                depthContainer.AnchorPoint = Vector2.new(1, 0)
                depthContainer.Position = UDim2.new(1, -18, 0, 36)
                depthContainer.Size = UDim2.new(0, 130, 0, 64)
                depthContainer.BackgroundColor3 = Color3.fromRGB(10, 26, 38)
                depthContainer.BackgroundTransparency = 0.2
                depthContainer.BorderSizePixel = 0
                depthContainer.Visible = false
                depthContainer.Parent = hudFrame

                local depthCorner = Instance.new("UICorner")
                depthCorner.CornerRadius = UDim.new(0, 12)
                depthCorner.Parent = depthContainer

                local depthStroke = Instance.new("UIStroke")
                depthStroke.Thickness = 1
                depthStroke.Color = Color3.fromRGB(40, 110, 160)
                depthStroke.Transparency = 0.35
                depthStroke.Parent = depthContainer

                local depthLabel = Instance.new("TextLabel")
                depthLabel.Name = "DepthLabel"
                depthLabel.BackgroundTransparency = 1
                depthLabel.Size = UDim2.new(1, -16, 0, 20)
                depthLabel.Position = UDim2.new(0, 8, 0, 10)
                depthLabel.Font = Enum.Font.GothamSemibold
                depthLabel.Text = "DEPTH"
                depthLabel.TextSize = 13
                depthLabel.TextColor3 = Color3.fromRGB(160, 210, 255)
                depthLabel.TextXAlignment = Enum.TextXAlignment.Left
                depthLabel.Parent = depthContainer

                local depthValue = Instance.new("TextLabel")
                depthValue.Name = "DepthValue"
                depthValue.BackgroundTransparency = 1
                depthValue.Size = UDim2.new(1, -16, 0, 34)
                depthValue.Position = UDim2.new(0, 8, 0, 28)
                depthValue.Font = Enum.Font.GothamBlack
                depthValue.Text = "0.0"
                depthValue.TextScaled = true
                depthValue.TextColor3 = Color3.fromRGB(255, 255, 255)
                depthValue.TextXAlignment = Enum.TextXAlignment.Left
                depthValue.Parent = depthContainer

                hudElements = {
                        boatLabel = boatLabel,
                        speedValue = speedValue,
                        speedUnit = speedUnit,
                        detailLabel = detailLabel,
                        cameraLabel = cameraLabel,
                        statusLabel = statusLabel,
                        speedFill = speedFill,
                        throttleIndicator = throttleIndicator,
                        depthContainer = depthContainer,
                        depthValue = depthValue,
                }
        end

        hudGui.Parent = playerGui
        return true
end

local function ToggleHud(visible)
        if not hudGui or not hudFrame then
                return
        end

        if visible then
                hudFadeToken = hudFadeToken + 1
                hudGui.Enabled = true
                hudFrame.Visible = true
                if hudTweens.fade then
                        hudTweens.fade:Cancel()
                        hudTweens.fade = nil
                end
                hudFrame.Position = UDim2.new(0.5, 0, 1, 12)
                local tween = TweenService:Create(hudFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
                        Position = UDim2.new(0.5, 0, 1, -48),
                        BackgroundTransparency = 0.25,
                })
                tween:Play()
                hudTweens.fade = tween
        else
                hudFadeToken = hudFadeToken + 1
                local token = hudFadeToken
                if hudTweens.fade then
                        hudTweens.fade:Cancel()
                        hudTweens.fade = nil
                end

                local tween = TweenService:Create(hudFrame, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                        Position = UDim2.new(0.5, 0, 1, 12),
                        BackgroundTransparency = 0.45,
                })
                tween:Play()
                hudTweens.fade = tween

                task.delay(0.22, function()
                        if hudGui and hudFadeToken == token then
                                hudGui.Enabled = false
                        end
                        if hudFrame and hudFadeToken == token then
                                hudFrame.Visible = false
                        end
                end)
        end
end

local function RefreshHudStaticInfo()
        if not EnsureHud() or not hudElements.boatLabel then
                return
        end

        local boatType = currentBoat and currentBoat:GetAttribute("BoatType")
        local displayName = (boatConfig and boatConfig.DisplayName)
                or (boatType and boatType:gsub("%u", function(letter)
                        return " " .. letter
                end):gsub("^ ", ""))
                or "Vessel"

        hudElements.boatLabel.Text = string.upper(displayName)

        if hudElements.statusLabel then
                local vesselType = boatConfig and boatConfig.Type or "Surface"
                hudElements.statusLabel.Text = string.upper(vesselType .. " MODE")
        end

        if hudElements.detailLabel and boatType then
                local accelTime = BoatConfig.GetTimeToMaxSpeed(boatType)
                hudElements.detailLabel.Text = string.format("MAX %d  |  %.1fs TO MAX  |  %dT", math.floor(maxSpeed + 0.5), accelTime, boatWeight)
        elseif hudElements.detailLabel then
                hudElements.detailLabel.Text = string.format("MAX %d  |  %dT", math.floor(maxSpeed + 0.5), boatWeight)
        end
end

local function UpdateCameraIndicator()
        if hudElements.cameraLabel then
                hudElements.cameraLabel.Text = string.format("CAM: %s", string.upper(cameraMode))
        end
end

-- Helper functions
local function GetBoatFromSeat(seat)
	if not seat then return nil end

	local model = seat.Parent
	while model and model.Parent ~= workspace do
		if model:GetAttribute("OwnerId") then
			return model
		end
		model = model.Parent
	end

	return model
end

-- Update acceleration values based on boat config
local function UpdateAccelerationValues()
	if not boatConfig then return end

	-- Get values from config
	maxSpeed = boatConfig.MaxSpeed or 25
	boatWeight = boatConfig.Weight or 3

	-- Calculate acceleration rates based on weight
	accelerationRate = BoatConfig.GetAcceleration(currentBoat:GetAttribute("BoatType"))
	decelerationRate = BoatConfig.GetDeceleration(currentBoat:GetAttribute("BoatType"))

	-- Turn acceleration is also affected by weight
	local weightFactor = 1.5 - (boatWeight / 10)
	turnAccelerationRate = 3 * weightFactor

	-- Submarine rotation acceleration MUCH MORE affected by weight
	-- Light subs (weight 2): factor = 1.64, Heavy subs (weight 10): factor = 0.2
	local rotationAccelFactor = 2.0 - (boatWeight * 0.18)
        rotationAccelFactor = math.clamp(rotationAccelFactor, 0.2, 2.0)

        pitchAccelerationRate = 3 * rotationAccelFactor  -- Much more dramatic
        rollAccelerationRate = 2.5 * rotationAccelFactor  -- Roll is harder

        print(string.format("Boat physics loaded: Weight=%d, MaxSpeed=%d, AccelRate=%.1f, PitchAccel=%.1f",
                boatWeight, maxSpeed, accelerationRate, pitchAccelerationRate))

        RefreshHudStaticInfo()
end

-- ENHANCED CONTROL SENDING WITH ACCELERATION
local function SendControlUpdate()
	if not currentSeat or not isControlling then return end

	local now = tick()
	if now - lastControlUpdate < CONTROL_UPDATE_RATE then
		return
	end
	lastControlUpdate = now

	-- Get raw input
	local targetThrottle = currentSeat.ThrottleFloat
	local targetSteer = currentSeat.SteerFloat

	-- Calculate target speeds based on input
	targetSpeed = targetThrottle * maxSpeed
	targetTurnSpeed = targetSteer * (boatConfig and boatConfig.TurnSpeed or 2)

	-- Apply acceleration/deceleration
	local deltaTime = CONTROL_UPDATE_RATE

	if math.abs(targetSpeed) > math.abs(currentSpeed) then
		-- Accelerating
		local speedDiff = targetSpeed - currentSpeed
		local speedChange = math.sign(speedDiff) * accelerationRate * deltaTime

		if math.abs(speedChange) > math.abs(speedDiff) then
			currentSpeed = targetSpeed
		else
			currentSpeed = currentSpeed + speedChange
		end
	else
		-- Decelerating or maintaining
		local speedDiff = targetSpeed - currentSpeed
		local speedChange = math.sign(speedDiff) * decelerationRate * deltaTime

		if math.abs(speedChange) > math.abs(speedDiff) then
			currentSpeed = targetSpeed
		else
			currentSpeed = currentSpeed + speedChange
		end
	end

	-- Apply turn acceleration
	if math.abs(targetTurnSpeed) > math.abs(currentTurnSpeed) then
		local turnDiff = targetTurnSpeed - currentTurnSpeed
		local turnChange = math.sign(turnDiff) * turnAccelerationRate * deltaTime

		if math.abs(turnChange) > math.abs(turnDiff) then
			currentTurnSpeed = targetTurnSpeed
		else
			currentTurnSpeed = currentTurnSpeed + turnChange
		end
	else
		local turnDiff = targetTurnSpeed - currentTurnSpeed
		local turnChange = math.sign(turnDiff) * (turnAccelerationRate * 1.5) * deltaTime -- Faster turn deceleration

		if math.abs(turnChange) > math.abs(turnDiff) then
			currentTurnSpeed = targetTurnSpeed
		else
			currentTurnSpeed = currentTurnSpeed + turnChange
		end
	end

	-- Convert back to throttle/steer values (0-1 range)
	smoothedThrottle = currentSpeed / maxSpeed
	smoothedSteer = currentTurnSpeed / (boatConfig and boatConfig.TurnSpeed or 2)

	-- Apply additional smoothing
	smoothedThrottle = smoothedThrottle + (targetThrottle - smoothedThrottle) * inputSmoothness
	smoothedSteer = smoothedSteer + (targetSteer - smoothedSteer) * inputSmoothness

	local controls = {
		throttle = smoothedThrottle,
		steer = smoothedSteer,
		currentSpeed = currentSpeed,  -- Send actual speed for server validation
		timestamp = now
	}

	if isSubmarine then
		controls.ascend = submarineControls.ascend
		controls.pitch = submarineControls.pitch
		controls.roll = submarineControls.roll
		controls.mode = submarineMode
	end

	if math.abs(controls.throttle) <= 1 and math.abs(controls.steer) <= 1 then
		ReplicatedStorage.Remotes.BoatRemotes.UpdateBoatControl:FireServer(controls)
	end
end

-- ENHANCED CAMERA WITH SPEED-BASED EFFECTS
local function UpdateBoatCamera()
	if not currentBoat or not currentBoat.PrimaryPart or not isControlling then 
		return 
	end

	local boatPart = currentBoat.PrimaryPart

	if cameraMode == "Follow" then
		-- Dynamic camera based on actual speed (not velocity)
		local speedFactor = math.abs(currentSpeed) / maxSpeed
		targetCameraDistance = 35 + (speedFactor * 15)

		cameraDistance = cameraDistance + (targetCameraDistance - cameraDistance) * 0.05

		-- Smooth camera offset
		local dynamicOffset = isSubmarine and 
			Vector3.new(0, 15 + speedFactor * 5, cameraDistance) or 
			Vector3.new(0, 20 + speedFactor * 5, cameraDistance)

		-- Calculate target position with look-ahead based on current speed
		local lookAheadDistance = math.abs(currentSpeed) * 0.5
		local lookAheadPosition = boatPart.Position + (boatPart.CFrame.LookVector * lookAheadDistance)

		local targetCFrame = CFrame.lookAt(
			boatPart.Position + (boatPart.CFrame:VectorToWorldSpace(dynamicOffset)),
			lookAheadPosition
		)

		Camera.CameraType = Enum.CameraType.Scriptable
		Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, cameraSmoothness)

	elseif cameraMode == "Cinematic" then
		cameraRotation = cameraRotation + 0.2
		if cameraRotation > 360 then
			cameraRotation = cameraRotation - 360
		end

		local distance = isSubmarine and 55 or 45
		local height = isSubmarine and 30 or 25

		local angle = math.rad(cameraRotation)
		local x = math.cos(angle) * distance
		local z = math.sin(angle) * distance

		local verticalOffset = math.sin(angle * 2) * 5

		local targetPosition = boatPart.Position + Vector3.new(x, height + verticalOffset, z)
		local targetCFrame = CFrame.lookAt(targetPosition, boatPart.Position)

		Camera.CameraType = Enum.CameraType.Scriptable
		Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, 0.12)

	elseif cameraMode == "FirstPerson" and isSubmarine then
		Camera.CameraType = Enum.CameraType.Scriptable
		local offset = boatPart.CFrame * CFrame.new(0, 2, -8)
		Camera.CFrame = Camera.CFrame:Lerp(offset, 0.3)

	elseif cameraMode == "Chase" then
		local offset = boatPart.CFrame * CFrame.new(0, 10, 25)
		local targetCFrame = CFrame.lookAt(offset.Position, boatPart.Position)

		Camera.CameraType = Enum.CameraType.Scriptable
		Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, 0.25)

	else
		if Camera.CameraType == Enum.CameraType.Scriptable then
			Camera.CameraType = Enum.CameraType.Custom
			Camera.FieldOfView = 70
		end
	end

	-- Adjust FOV based on actual speed for effect
	if Camera.CameraType == Enum.CameraType.Scriptable then
		local speedFactor = math.abs(currentSpeed) / maxSpeed
		local targetFOV = 70 + (speedFactor * 20) -- Max +20 FOV at max speed
		Camera.FieldOfView = Camera.FieldOfView + (targetFOV - Camera.FieldOfView) * 0.1
	end
end

-- Display speed info (optional UI element)
local function UpdateSpeedDisplay()
        if not isControlling or not currentBoat then return end

        local now = tick()
        if now - lastHudUpdate < 1/30 then
                return
        end
        lastHudUpdate = now

        if not EnsureHud() then
                return
        end

        if hudGui and not hudGui.Enabled then
                ToggleHud(true)
        end

        UpdateCameraIndicator()

        local speedAbs = math.abs(currentSpeed)
        local speedPercent = (maxSpeed > 0) and math.clamp(speedAbs / maxSpeed, 0, 1) or 0

        if hudElements.speedValue then
                hudElements.speedValue.Text = string.format("%03d", math.floor(speedAbs + 0.5))
        end

        if hudElements.speedUnit then
                hudElements.speedUnit.Text = string.format("STUDS/SEC  •  %d%%", math.floor((speedPercent * 100) + 0.5))
        end

        if hudElements.speedFill and math.abs(speedPercent - hudState.speedPercent) > 0.01 then
                if hudTweens.speed then
                        hudTweens.speed:Cancel()
                end
                hudTweens.speed = TweenService:Create(hudElements.speedFill, TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
                        Size = UDim2.new(speedPercent, 0, 1, 0),
                })
                hudTweens.speed:Play()
                hudState.speedPercent = speedPercent
        end

        local throttleValue = math.clamp(smoothedThrottle, -1, 1)
        if hudElements.throttleIndicator and math.abs(throttleValue - hudState.throttleValue) > 0.01 then
                hudState.throttleValue = throttleValue
                if hudTweens.throttle then
                        hudTweens.throttle:Cancel()
                end

                local throttleColor = throttleValue >= 0 and Color3.fromRGB(72, 210, 170) or Color3.fromRGB(255, 120, 120)
                local throttleTween = TweenService:Create(hudElements.throttleIndicator, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                        Position = UDim2.new(0.5 + 0.45 * throttleValue, 0, 0.5, 0),
                        BackgroundColor3 = throttleColor,
                })
                hudTweens.throttle = throttleTween
                throttleTween:Play()
        end

        if hudElements.statusLabel then
                local throttlePercent = math.floor(math.abs(throttleValue) * 100 + 0.5)
                local statusPrefix
                if isSubmarine then
                        statusPrefix = string.upper(submarineMode)
                else
                        statusPrefix = throttleValue >= 0 and "AHEAD" or "ASTERN"
                end

                hudElements.statusLabel.Text = string.format("%s • %d%% PWR", statusPrefix, throttlePercent)
        end

        if hudElements.depthContainer then
                hudElements.depthContainer.Visible = isSubmarine
                if isSubmarine and currentBoat.PrimaryPart then
                        local depth = math.max(0, WATER_LEVEL - currentBoat.PrimaryPart.Position.Y)
                        hudElements.depthValue.Text = string.format("%.1f", depth)

                        if depth < 8 then
                                hudElements.depthValue.TextColor3 = Color3.fromRGB(190, 245, 220)
                        elseif depth < 40 then
                                hudElements.depthValue.TextColor3 = Color3.fromRGB(120, 210, 255)
                        else
                                hudElements.depthValue.TextColor3 = Color3.fromRGB(255, 140, 140)
                        end
                end
        end

end

-- Cleanup
local function CleanupBoatSession()
	if activeDiveTask then
		task.cancel(activeDiveTask)
		activeDiveTask = nil
	end

	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
		Camera.CameraType = Enum.CameraType.Custom
		Camera.FieldOfView = 70
	end

        if controlUpdateConnection then
                controlUpdateConnection:Disconnect()
                controlUpdateConnection = nil
        end

        if hudTweens.throttle then
                hudTweens.throttle:Cancel()
                hudTweens.throttle = nil
        end

        if hudTweens.speed then
                hudTweens.speed:Cancel()
                hudTweens.speed = nil
        end

        if hudTweens.fade then
                hudTweens.fade:Cancel()
                hudTweens.fade = nil
        end

        if hudGui and hudGui.Enabled then
                ToggleHud(false)
        end

        hudState.throttleValue = 0
        hudState.speedPercent = 0

        if hudElements.speedFill then
                hudElements.speedFill.Size = UDim2.new(0, 0, 1, 0)
        end

        if hudElements.throttleIndicator then
                hudElements.throttleIndicator.Position = UDim2.new(0.5, 0, 0.5, 0)
                hudElements.throttleIndicator.BackgroundColor3 = Color3.fromRGB(72, 210, 170)
        end

        if hudElements.depthContainer then
                hudElements.depthContainer.Visible = false
        end

        lastHudUpdate = 0

        -- Reset all variables including speed and rotation speeds
        submarineControls = {ascend = 0, pitch = 0, roll = 0}
        smoothedThrottle = 0
	smoothedSteer = 0
	currentSpeed = 0
	targetSpeed = 0
	currentTurnSpeed = 0
	targetTurnSpeed = 0
	currentPitchSpeed = 0
	targetPitchSpeed = 0
	currentRollSpeed = 0
	targetRollSpeed = 0
	isControlling = false
	currentBoat = nil
	currentSeat = nil
	boatConfig = nil
	isSubmarine = false
	cameraMode = "Default"
	submarineMode = "surface"
	cameraDistance = 35
	targetCameraDistance = 35
end

-- Seat handler
local function OnCharacterSeated(active, seatPart)
	CleanupBoatSession()

	if active and seatPart and seatPart:IsA("VehicleSeat") then
		local boatOwner = seatPart:GetAttribute("BoatOwner")
		if boatOwner then
			currentBoat = GetBoatFromSeat(seatPart)
			currentSeat = seatPart

			if currentBoat then
				local isOwner = (tostring(player.UserId) == boatOwner)
				local boatType = currentBoat:GetAttribute("BoatType")

				local success, config = pcall(function()
					return BoatConfig.GetBoatData(boatType)
				end)

                                if success then
                                        boatConfig = config
                                        isSubmarine = boatConfig and boatConfig.Type == "Submarine"

                                        -- Update acceleration values for this boat
                                        UpdateAccelerationValues()
                                end

                                if isOwner then
                                        isControlling = true

                                        if EnsureHud() then
                                                ToggleHud(true)
                                                hudState.throttleValue = 0
                                                hudState.speedPercent = 0
                                                lastHudUpdate = 0

                                                if hudElements.throttleIndicator then
                                                        hudElements.throttleIndicator.Position = UDim2.new(0.5, 0, 0.5, 0)
                                                        hudElements.throttleIndicator.BackgroundColor3 = Color3.fromRGB(72, 210, 170)
                                                end

                                                if hudElements.speedFill then
                                                        hudElements.speedFill.Size = UDim2.new(0, 0, 1, 0)
                                                end

                                                RefreshHudStaticInfo()
                                                UpdateCameraIndicator()
                                        end

                                        if isSubmarine and currentBoat.PrimaryPart then
                                                local depth = WATER_LEVEL - currentBoat.PrimaryPart.Position.Y
                                                submarineMode = depth > 8 and "dive" or "surface"
                                        end

					cameraMode = "Follow"
					cameraConnection = RunService.RenderStepped:Connect(UpdateBoatCamera)
					controlUpdateConnection = RunService.Heartbeat:Connect(function()
						SendControlUpdate()
						UpdateSpeedDisplay()
					end)

					print(string.format("Controlling %s (Weight: %d, Max Speed: %d)", 
						boatType or "Unknown", boatWeight, maxSpeed))
					print("C - Camera | G - Dive (submarines)")
				else
					print("Passenger in " .. (boatType or "Unknown"))
				end
			end
		end
	end
end

-- Character handling
local function OnCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid then
		humanoid.Seated:Connect(OnCharacterSeated)
	end

	task.spawn(function()
		while character.Parent do
			if isControlling and isSubmarine and currentBoat and currentBoat.PrimaryPart then
				local depth = WATER_LEVEL - currentBoat.PrimaryPart.Position.Y

				if depth < 5 and submarineMode == "dive" and 
					not activeDiveTask and 
					math.abs(submarineControls.ascend) < 0.1 then
					submarineMode = "surface"
					submarineControls = {ascend = 0, pitch = 0, roll = 0}
					print("Surfaced - Press G to dive again")
				end
			end
			task.wait(1)
		end
	end)
end

if player.Character then
        OnCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(OnCharacterAdded)

local function WatchPlayerGui(gui)
        if not gui then
                return
        end

        local function hookBoatHud(screenGui)
                task.defer(EnsureHud)

                screenGui:GetAttributeChangedSignal(HUD_ENABLE_ATTRIBUTE):Connect(function()
                        task.defer(EnsureHud)
                end)

                screenGui:GetAttributeChangedSignal(HUD_RUNTIME_ATTRIBUTE):Connect(function()
                        task.defer(EnsureHud)
                end)
        end

        for _, descendant in ipairs(gui:GetDescendants()) do
                if descendant:IsA("ScreenGui") and descendant.Name == "BoatHUD" then
                        hookBoatHud(descendant)
                end
        end

        gui.DescendantAdded:Connect(function(descendant)
                if descendant:IsA("ScreenGui") and descendant.Name == "BoatHUD" then
                        hookBoatHud(descendant)
                end
        end)
end

task.defer(EnsureHud)

local existingGui = player:FindFirstChildOfClass("PlayerGui") or player:FindFirstChild("PlayerGui")
if existingGui then
        WatchPlayerGui(existingGui)
end

player.ChildAdded:Connect(function(child)
        if child:IsA("PlayerGui") then
                WatchPlayerGui(child)
                task.defer(EnsureHud)
        end
end)

-- Input handling
local keysPressed = {}
local lastInputTime = 0
local INPUT_COOLDOWN = 0.05

local function OnInputBegan(input, gameProcessed)
	if gameProcessed then return end

	keysPressed[input.KeyCode] = true

	-- Boat selection (T key)
	if input.KeyCode == Enum.KeyCode.T and not isControlling then
		local now = tick()
		if now - lastInputTime < INPUT_COOLDOWN then return end
		lastInputTime = now

		selectedBoatIndex = selectedBoatIndex % #availableBoats + 1
		selectedBoatType = availableBoats[selectedBoatIndex]

		local config = BoatConfig.GetBoatData(selectedBoatType)
		local displayName = config and config.DisplayName or selectedBoatType
		local weight = config and config.Weight or 3
		local timeToMax = BoatConfig.GetTimeToMaxSpeed(selectedBoatType)

		print(string.format("Selected: %s (Weight: %d, Time to max: %.1fs)", 
			displayName, weight, timeToMax))

		pcall(function()
			game.StarterGui:SetCore("SendNotification", {
				Title = "Boat Selection",
				Text = string.format("%s (Weight: %d)", displayName, weight),
				Duration = 2,
			})
		end)
	end

	-- Submarine dive (G key)
	if input.KeyCode == Enum.KeyCode.G and isControlling and isSubmarine then
		local now = tick()
		if now - lastInputTime < INPUT_COOLDOWN then return end
		lastInputTime = now

		if submarineMode == "surface" then
			if activeDiveTask then
				task.cancel(activeDiveTask)
				activeDiveTask = nil
			end

			submarineMode = "dive"
			print("Initiating dive sequence...")

			activeDiveTask = task.spawn(function()
				local startTime = tick()
				local duration = 3

				submarineControls.ascend = -1.0

				while tick() - startTime < duration do
					if not isControlling then 
						submarineControls.ascend = 0
						break 
					end

					local t = (tick() - startTime) / duration
					if t > 0.7 then
						submarineControls.ascend = -1.0 * (1 - ((t - 0.7) / 0.3))
					else
						submarineControls.ascend = -1.0
					end

					task.wait(0.03)
				end

				submarineControls.ascend = 0
				activeDiveTask = nil
				print("Dive complete")
			end)
		else
			print("Already underwater - Use pitch up (R) + forward to surface")
		end
	end

	-- Camera mode (C key)
	if input.KeyCode == Enum.KeyCode.C and isControlling then
		local now = tick()
		if now - lastInputTime < INPUT_COOLDOWN then return end
		lastInputTime = now

		local modes = isSubmarine and 
			{"Default", "Follow", "Chase", "FirstPerson", "Cinematic"} or
			{"Default", "Follow", "Chase", "Cinematic"}

		local currentIndex = table.find(modes, cameraMode) or 1
		currentIndex = currentIndex % #modes + 1
		cameraMode = modes[currentIndex]

                if cameraMode == "Follow" then
                        cameraSmoothness = 0.2
                elseif cameraMode == "Chase" then
                        cameraSmoothness = 0.25
                elseif cameraMode == "Cinematic" then
                        cameraSmoothness = 0.12
                end

                UpdateCameraIndicator()
                print("Camera:", cameraMode)
        end
end

local function OnInputEnded(input, gameProcessed)
	keysPressed[input.KeyCode] = nil
end

-- Submarine control updates
RunService.Heartbeat:Connect(function()
	if not isControlling or not isSubmarine then
		submarineControls = {ascend = 0, pitch = 0, roll = 0}
		return
	end

	if submarineMode == "dive" then
		local targetPitch = (keysPressed[Enum.KeyCode.R] and 1 or 0) - 
			(keysPressed[Enum.KeyCode.F] and 1 or 0)
		local targetRoll = 0

		if boatConfig and boatConfig.CanInvert then
			targetRoll = (keysPressed[Enum.KeyCode.E] and 1 or 0) - 
				(keysPressed[Enum.KeyCode.Q] and 1 or 0)
		end

		submarineControls.pitch = submarineControls.pitch + (targetPitch - submarineControls.pitch) * 0.2
		submarineControls.roll = submarineControls.roll + (targetRoll - submarineControls.roll) * 0.2
	else
		submarineControls.pitch = submarineControls.pitch * 0.9
		submarineControls.roll = submarineControls.roll * 0.9
	end
end)

-- Mouse wheel zoom
local function OnMouseWheel(input)
	if not isControlling or cameraMode ~= "Follow" then return end

	local direction = input.Position.Z
	local zoomSpeed = 0.9

	if direction > 0 then
		cameraOffset = cameraOffset * zoomSpeed
	else
		cameraOffset = cameraOffset / zoomSpeed
	end

	local magnitude = cameraOffset.Magnitude
	if magnitude < 15 then
		cameraOffset = cameraOffset.Unit * 15
	elseif magnitude > 80 then
		cameraOffset = cameraOffset.Unit * 80
	end
end

-- Connect inputs
UserInputService.InputBegan:Connect(OnInputBegan)
UserInputService.InputEnded:Connect(OnInputEnded)
UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if not gameProcessed and input.UserInputType == Enum.UserInputType.MouseWheel then
		OnMouseWheel(input)
	end
end)

-- Boat type remote
local getBoatTypeRemote = ReplicatedStorage.Remotes.BoatRemotes:WaitForChild("GetSelectedBoatType", 5)
if getBoatTypeRemote then
	getBoatTypeRemote.OnClientInvoke = function()
		return selectedBoatType
	end
end

-- Cleanup on leave
Players.PlayerRemoving:Connect(function()
	CleanupBoatSession()
end)

print("Enhanced Boat Controller loaded with acceleration system!")
print("T - Select boat | C - Camera | G - Dive")