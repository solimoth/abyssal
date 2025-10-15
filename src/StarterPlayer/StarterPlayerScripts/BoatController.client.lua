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
local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

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
local CONTROL_SEND_RATE = 20 -- throttle remote updates to stay well under security limits
local CONTROL_UPDATE_INTERVAL = 1 / CONTROL_SEND_RATE
local CONTROL_EARLY_INTERVAL = CONTROL_UPDATE_INTERVAL * 0.75
local CONTROL_DELTA_EPSILON = 0.02
local SPEED_DELTA_EPSILON = 0.5
local submarineMode = "surface"
local activeDiveTask = nil

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
end

-- ENHANCED CONTROL SENDING WITH ACCELERATION
local controlSendAccumulator = CONTROL_UPDATE_INTERVAL
local lastSentControls = nil

local function shouldSendControls(controls)
        if not lastSentControls then
                return true
        end

        if controlSendAccumulator >= CONTROL_UPDATE_INTERVAL then
                return true
        end

        if controlSendAccumulator >= CONTROL_EARLY_INTERVAL then
                if math.abs(controls.throttle - lastSentControls.throttle) > CONTROL_DELTA_EPSILON then
                        return true
                end

                if math.abs(controls.steer - lastSentControls.steer) > CONTROL_DELTA_EPSILON then
                        return true
                end

                if math.abs((controls.ascend or 0) - (lastSentControls.ascend or 0)) > CONTROL_DELTA_EPSILON then
                        return true
                end

                if math.abs((controls.pitch or 0) - (lastSentControls.pitch or 0)) > CONTROL_DELTA_EPSILON then
                        return true
                end

                if math.abs((controls.roll or 0) - (lastSentControls.roll or 0)) > CONTROL_DELTA_EPSILON then
                        return true
                end

                if math.abs(controls.currentSpeed - lastSentControls.currentSpeed) > SPEED_DELTA_EPSILON then
                        return true
                end

                if controls.mode ~= lastSentControls.mode then
                        return true
                end
        end

        return false
end

local function snapshotControls(controls)
        lastSentControls = {
                throttle = controls.throttle,
                steer = controls.steer,
                currentSpeed = controls.currentSpeed,
                ascend = controls.ascend,
                pitch = controls.pitch,
                roll = controls.roll,
                mode = controls.mode,
        }
end

local function SendControlUpdate(deltaTime)
        if not currentSeat or not isControlling then return end

        deltaTime = math.max(deltaTime or CONTROL_UPDATE_INTERVAL, 0)
        controlSendAccumulator += deltaTime

        local now = tick()

        -- Get raw input
        local targetThrottle = currentSeat.ThrottleFloat
        local targetSteer = currentSeat.SteerFloat

        -- Calculate target speeds based on input
        targetSpeed = targetThrottle * maxSpeed
        targetTurnSpeed = targetSteer * (boatConfig and boatConfig.TurnSpeed or 2)

        -- Apply acceleration/deceleration
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
                if shouldSendControls(controls) then
                        ReplicatedStorage.Remotes.BoatRemotes.UpdateBoatControl:FireServer(controls)

                        if controlSendAccumulator >= CONTROL_UPDATE_INTERVAL then
                                controlSendAccumulator = controlSendAccumulator - CONTROL_UPDATE_INTERVAL
                        else
                                controlSendAccumulator = 0
                        end

                        snapshotControls(controls)
                end
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

	-- You can add UI elements here to show:
	-- Current Speed: currentSpeed
	-- Max Speed: maxSpeed
	-- Speed Percentage: (currentSpeed/maxSpeed) * 100
	-- Weight: boatWeight
	-- Acceleration Time: BoatConfig.GetTimeToMaxSpeed(currentBoat:GetAttribute("BoatType"))
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
        controlSendAccumulator = CONTROL_UPDATE_INTERVAL
        lastSentControls = nil
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

                                        if isSubmarine and currentBoat.PrimaryPart then
                                                local surfaceY = WaterPhysics.GetWaterLevel(currentBoat.PrimaryPart.Position)
                                                local depth = surfaceY - currentBoat.PrimaryPart.Position.Y
                                                submarineMode = depth > 8 and "dive" or "surface"
					end

					cameraMode = "Follow"
					cameraConnection = RunService.RenderStepped:Connect(UpdateBoatCamera)
                                        controlUpdateConnection = RunService.Heartbeat:Connect(function(deltaTime)
                                                SendControlUpdate(deltaTime)
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
                                local surfaceY = WaterPhysics.GetWaterLevel(currentBoat.PrimaryPart.Position)
                                local depth = surfaceY - currentBoat.PrimaryPart.Position.Y

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
