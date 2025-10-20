local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)
local SubmarinePhysics = require(ReplicatedStorage.Modules.SubmarinePhysics)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui
local controlFrame
local compassNeedle
local healthBar
local speedBar
local healthLabel
local speedLabel
local pressureLabel
local coordinatesLabel
local depthLabel

local updateConnection
local boatConnection
local guiAncestryConnection

local currentBoat
local currentConfig
local currentSeat

local updateAccumulator = 0
local UPDATE_INTERVAL = 0.05

local zeroCoordinateText = "0, 0, 0"

local COORDINATE_ORIGIN = Vector3.new(304.32, 0, -26.161)
local COORDINATE_DECIMALS = 2

local function round(value, decimals)
    local multiplier = 10 ^ decimals
    return math.floor(value * multiplier + 0.5) / multiplier
end

-- Meters rotate across a 180° arc by default unless overridden via attributes.
local DEFAULT_METER_RANGE = 180

local lastHealthPercent
local lastSpeedPercent

local meterStates = {}
local labelPulses = {}
local lastLabelTexts = {}
local compassState = {
    currentRotation = nil,
    targetRotation = nil,
}

local METER_LERP_SPEED = 12
local COMPASS_LERP_SPEED = 10
local METER_ALIGNMENT_EPSILON = 0.01
local COMPASS_ALIGNMENT_EPSILON = 0.05

local LABEL_PULSE_GROW = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LABEL_PULSE_SHRINK = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function getSmoothingAlpha(speed, deltaTime)
    return 1 - math.exp(-math.max(speed, 0) * math.max(deltaTime, 0))
end

local function getPulseState(label)
    if not label then
        return nil
    end

    local state = labelPulses[label]
    if state then
        return state
    end

    local scale = label:FindFirstChildWhichIsA("UIScale")
    if not scale then
        scale = Instance.new("UIScale")
        scale.Scale = 1
        scale.Name = "AutoPulseScale"
        scale.Parent = label
    end

    state = {
        scale = scale,
    }

    labelPulses[label] = state
    return state
end

local function stopPulse(label)
    if not label then
        return
    end

    local state = labelPulses[label]
    if not state then
        return
    end

    if state.growTween then
        state.growTween:Cancel()
        state.growTween = nil
    end
    if state.shrinkTween then
        state.shrinkTween:Cancel()
        state.shrinkTween = nil
    end
    if state.growConnection then
        state.growConnection:Disconnect()
        state.growConnection = nil
    end
    if state.shrinkConnection then
        state.shrinkConnection:Disconnect()
        state.shrinkConnection = nil
    end

    if state.scale then
        state.scale.Scale = 1
    end
end

local function playLabelPulse(label)
    if not label then
        return
    end

    local state = getPulseState(label)
    if not state or not state.scale then
        return
    end

    stopPulse(label)

    local growTween = TweenService:Create(state.scale, LABEL_PULSE_GROW, { Scale = 1.08 })
    local shrinkTween = TweenService:Create(state.scale, LABEL_PULSE_SHRINK, { Scale = 1 })

    state.growTween = growTween
    state.shrinkTween = shrinkTween

    state.growConnection = growTween.Completed:Connect(function(playbackState)
        if state.growConnection then
            state.growConnection:Disconnect()
            state.growConnection = nil
        end

        state.growTween = nil
        if playbackState == Enum.PlaybackState.Completed and state.shrinkTween then
            state.shrinkTween:Play()
        end
    end)

    state.shrinkConnection = shrinkTween.Completed:Connect(function()
        if state.shrinkConnection then
            state.shrinkConnection:Disconnect()
            state.shrinkConnection = nil
        end

        state.shrinkTween = nil
    end)

    growTween:Play()
end

local function stepMeterAnimations(deltaTime)
    if deltaTime <= 0 then
        return
    end

    local alpha = getSmoothingAlpha(METER_LERP_SPEED, deltaTime)
    for wheel, state in pairs(meterStates) do
        if not wheel or not wheel.Parent then
            meterStates[wheel] = nil
        elseif state.targetRotation then
            local currentRotation = state.currentRotation
            if currentRotation == nil then
                currentRotation = wheel.Rotation
            end

            local delta = state.targetRotation - currentRotation
            if math.abs(delta) <= METER_ALIGNMENT_EPSILON then
                currentRotation = state.targetRotation
            else
                currentRotation += delta * alpha
            end

            state.currentRotation = currentRotation
            if wheel.Rotation ~= currentRotation then
                wheel.Rotation = currentRotation
            end
        end
    end
end

local function stepCompassAnimation(deltaTime)
    if not compassNeedle then
        return
    end

    local target = compassState.targetRotation
    local current = compassState.currentRotation
    if target == nil then
        return
    end

    if current == nil then
        compassState.currentRotation = target
        compassNeedle.Rotation = target
        return
    end

    local alpha = getSmoothingAlpha(COMPASS_LERP_SPEED, deltaTime)
    local difference = ((target - current + 180) % 360) - 180

    if math.abs(difference) <= COMPASS_ALIGNMENT_EPSILON then
        current = target
    else
        current += difference * alpha
    end

    compassState.currentRotation = current
    if compassNeedle.Rotation ~= current then
        compassNeedle.Rotation = current
    end
end

local function stepAnimations(deltaTime)
    stepMeterAnimations(deltaTime)
    stepCompassAnimation(deltaTime)
end

local function updateLabelText(label, key, text)
    if not label then
        lastLabelTexts[key] = nil
        return
    end

    if lastLabelTexts[key] ~= text then
        label.Text = text
        lastLabelTexts[key] = text
    end
end

local function configureMeter(wheel, referencePercent)
    if not wheel then
        return nil
    end

    local state = meterStates[wheel]
    if state then
        return state
    end

    local currentAnchor = wheel.AnchorPoint
    local targetAnchor = Vector2.new(0.5, 0.5)
    if currentAnchor.X ~= targetAnchor.X or currentAnchor.Y ~= targetAnchor.Y then
        local size = wheel.Size
        local position = wheel.Position

        wheel.AnchorPoint = targetAnchor
        wheel.Position = UDim2.new(
            position.X.Scale + (targetAnchor.X - currentAnchor.X) * size.X.Scale,
            position.X.Offset + (targetAnchor.X - currentAnchor.X) * size.X.Offset,
            position.Y.Scale + (targetAnchor.Y - currentAnchor.Y) * size.Y.Scale,
            position.Y.Offset + (targetAnchor.Y - currentAnchor.Y) * size.Y.Offset
        )
    end

    local range = wheel:GetAttribute("MeterRange")
    if typeof(range) ~= "number" or range <= 0 then
        range = DEFAULT_METER_RANGE
    end

    local minRotation = wheel:GetAttribute("MeterMinRotation")
    local maxRotation = wheel:GetAttribute("MeterMaxRotation")
    if typeof(minRotation) == "number" and typeof(maxRotation) == "number" then
        range = maxRotation - minRotation
        if range < 0 then
            range = -range
            minRotation, maxRotation = maxRotation, minRotation
        end
        state = {
            baseRotation = minRotation,
            referencePercent = 0,
            range = range,
        }
    else
        local basePercent = typeof(referencePercent) == "number" and referencePercent or nil
        state = {
            baseRotation = wheel.Rotation,
            referencePercent = basePercent,
            range = range,
        }
    end

    state.currentRotation = wheel.Rotation
    state.targetRotation = wheel.Rotation

    meterStates[wheel] = state
    return state
end

local function setMeterRotation(wheel, percent, instant)
    if not wheel then
        return
    end

    local clamped = math.clamp(percent, 0, 100)
    local state = meterStates[wheel]
    if not state then
        state = configureMeter(wheel, clamped)
    end
    if not state then
        return
    end

    if state.referencePercent == nil then
        state.referencePercent = clamped
        state.baseRotation = wheel.Rotation
    end

    local offsetPercent = clamped - state.referencePercent
    local rotation = state.baseRotation + (offsetPercent / 100) * state.range
    if not instant and state.targetRotation ~= nil and math.abs(state.targetRotation - rotation) <= METER_ALIGNMENT_EPSILON then
        return
    end

    state.targetRotation = rotation

    if instant or state.currentRotation == nil then
        state.currentRotation = rotation
        if wheel.Rotation ~= rotation then
            wheel.Rotation = rotation
        end
    end
end

local function resetUi()
    updateLabelText(healthLabel, "health", "100%")
    updateLabelText(speedLabel, "speed", "0%")
    updateLabelText(pressureLabel, "pressure", "0%")
    updateLabelText(depthLabel, "depth", "0m")
    updateLabelText(coordinatesLabel, "coordinates", zeroCoordinateText)
    if compassNeedle then
        compassNeedle.Rotation = 0
    end

    compassState.currentRotation = 0
    compassState.targetRotation = 0

    setMeterRotation(healthBar, 100, true)
    setMeterRotation(speedBar, 0, true)

    stopPulse(healthLabel)
    stopPulse(speedLabel)

    lastHealthPercent = nil
    lastSpeedPercent = nil

    if controlFrame and controlFrame.Parent then
        controlFrame.Visible = false
    end
end

local function disconnectBoatConnection()
    if boatConnection then
        boatConnection:Disconnect()
        boatConnection = nil
    end
end

local function stopTracking()
    if updateConnection then
        updateConnection:Disconnect()
        updateConnection = nil
    end

    disconnectBoatConnection()

    currentBoat = nil
    currentSeat = nil
    currentConfig = nil
    updateAccumulator = 0

    resetUi()
end

local function clearGuiReferences()
    if guiAncestryConnection then
        guiAncestryConnection:Disconnect()
        guiAncestryConnection = nil
    end

    gui = nil
    controlFrame = nil
    compassNeedle = nil
    healthBar = nil
    speedBar = nil
    healthLabel = nil
    speedLabel = nil
    pressureLabel = nil
    coordinatesLabel = nil
    depthLabel = nil
    lastHealthPercent = nil
    lastSpeedPercent = nil
    lastLabelTexts = {}
    for label in pairs(labelPulses) do
        stopPulse(label)
    end
    labelPulses = {}
    meterStates = {}
    compassState = {
        currentRotation = nil,
        targetRotation = nil,
    }
end

local function getBoatFromSeat(seat)
    local ancestor = seat and seat.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("Model") and ancestor:GetAttribute("BoatType") then
            return ancestor
        end
        ancestor = ancestor.Parent
    end
    return nil
end

local function getBoatConfig(boat)
    if not boat then
        return nil
    end

    local boatType = boat:GetAttribute("BoatType")
    if not boatType then
        return nil
    end

    local success, data = pcall(BoatConfig.GetBoatData, boatType)
    if success then
        return data
    end

    warn("Failed to fetch boat config for", boatType, data)
    return nil
end

local function formatCoordinate(value)
    local rounded = round(value, COORDINATE_DECIMALS)
    local epsilon = 0.5 / (10 ^ COORDINATE_DECIMALS)
    if math.abs(rounded) < epsilon then
        rounded = 0
    end
    return string.format("%." .. COORDINATE_DECIMALS .. "f", rounded)
end

zeroCoordinateText = string.format(
    "%s, %s, %s",
    formatCoordinate(0),
    formatCoordinate(0),
    formatCoordinate(0)
)

local function ensureGui()
    if controlFrame and controlFrame.Parent then
        return true
    end

    local guiInstance = playerGui:FindFirstChild("SubmarineControlGUI")
    if not guiInstance then
        return false
    end

    -- Acquire fresh references to the GUI hierarchy.
    stopTracking()
    clearGuiReferences()

    gui = guiInstance
    controlFrame = guiInstance:WaitForChild("SubmarineControlFrame")
    compassNeedle = controlFrame:WaitForChild("CompassNeedle")
    healthBar = controlFrame:WaitForChild("HealthAmountLine")
    speedBar = controlFrame:WaitForChild("SpeedAmountLine")
    healthLabel = controlFrame:WaitForChild("HealthPercentLabel")
    speedLabel = controlFrame:WaitForChild("SpeedPercentLabel")
    pressureLabel = controlFrame:WaitForChild("HullPressurePercentLabel")
    coordinatesLabel = controlFrame:WaitForChild("CoordinatesLabel")
    depthLabel = controlFrame:WaitForChild("DepthAmountLabel")

    if depthLabel then
        local anchor = depthLabel.AnchorPoint
        local targetAnchor = Vector2.new(0.5, 0.5)
        if anchor.X ~= targetAnchor.X or anchor.Y ~= targetAnchor.Y then
            local size = depthLabel.Size
            local position = depthLabel.Position

            depthLabel.AnchorPoint = targetAnchor
            depthLabel.Position = UDim2.new(
                position.X.Scale + (targetAnchor.X - anchor.X) * size.X.Scale,
                position.X.Offset + (targetAnchor.X - anchor.X) * size.X.Offset,
                position.Y.Scale + (targetAnchor.Y - anchor.Y) * size.Y.Scale,
                position.Y.Offset + (targetAnchor.Y - anchor.Y) * size.Y.Offset
            )
        end
    end

    configureMeter(healthBar)
    configureMeter(speedBar)

    guiAncestryConnection = guiInstance.AncestryChanged:Connect(function(_, parent)
        if not parent then
            stopTracking()
            clearGuiReferences()
        end
    end)

    resetUi()
    return true
end

local function updateTelemetry()
    if not ensureGui() then
        stopTracking()
        return
    end

    local boat = currentBoat
    if not boat or not boat.Parent then
        stopTracking()
        return
    end

    local primaryPart = boat.PrimaryPart
    if not primaryPart then
        return
    end

    local config = currentConfig
    if not config then
        config = getBoatConfig(boat)
        if not config then
            return
        end
        if config.Type ~= "Submarine" then
            stopTracking()
            return
        end
        currentConfig = config
    end

    local success, info = pcall(SubmarinePhysics.GetSubmarineInfo, boat, config)
    if not success then
        warn("Failed to fetch submarine info", info)
        return
    end

    local healthPercent = boat:GetAttribute("SubmarineHealthPercent")
    if typeof(healthPercent) ~= "number" then
        healthPercent = 100
    end
    healthPercent = math.clamp(math.floor(healthPercent + 0.5), 0, 100)

    local maxSpeed = config.MaxSpeed or config.Speed or 0
    local speedPercent = 0
    if maxSpeed > 0 then
        speedPercent = math.floor(((info.speed or 0) / maxSpeed) * 100 + 0.5)
        speedPercent = math.clamp(speedPercent, 0, 999)
    end

    local pressurePercent = boat:GetAttribute("SubmarinePressurePercent")
    if typeof(pressurePercent) ~= "number" then
        if config.MaxDepth and config.MaxDepth > 0 then
            pressurePercent = math.floor(((info.depth or 0) / config.MaxDepth) * 100 + 0.5)
        else
            pressurePercent = 0
        end
    end
    pressurePercent = math.clamp(pressurePercent, 0, 999)

    local depthMeters = math.max(math.floor((info.depth or 0) + 0.5), 0)
    local position = primaryPart.Position
    local relativePosition = Vector3.new(
        position.X - COORDINATE_ORIGIN.X,
        position.Y - COORDINATE_ORIGIN.Y,
        position.Z - COORDINATE_ORIGIN.Z
    )

    updateLabelText(healthLabel, "health", string.format("%d%%", healthPercent))
    updateLabelText(speedLabel, "speed", string.format("%d%%", speedPercent))
    updateLabelText(pressureLabel, "pressure", string.format("%d%%", pressurePercent))
    updateLabelText(depthLabel, "depth", string.format("%dm", depthMeters))
    updateLabelText(
        coordinatesLabel,
        "coordinates",
        string.format(
            "%s, %s, %s",
            formatCoordinate(relativePosition.X),
            formatCoordinate(relativePosition.Y),
            formatCoordinate(relativePosition.Z)
        )
    )

    if healthBar and healthPercent ~= lastHealthPercent then
        setMeterRotation(healthBar, healthPercent)
        if lastHealthPercent ~= nil then
            playLabelPulse(healthLabel)
        end
        lastHealthPercent = healthPercent
    end

    local clampedSpeedPercent = math.clamp(speedPercent, 0, 100)
    if speedBar and clampedSpeedPercent ~= lastSpeedPercent then
        setMeterRotation(speedBar, clampedSpeedPercent)
        if lastSpeedPercent ~= nil then
            playLabelPulse(speedLabel)
        end
        lastSpeedPercent = clampedSpeedPercent
    end

    if compassNeedle then
        local lookVector = primaryPart.CFrame.LookVector
        local heading = math.deg(math.atan2(-lookVector.X, -lookVector.Z))
        compassState.targetRotation = (heading + 360) % 360
        if compassState.currentRotation == nil then
            compassState.currentRotation = compassState.targetRotation
            compassNeedle.Rotation = compassState.targetRotation
        end
    end

    if controlFrame and not controlFrame.Visible then
        controlFrame.Visible = true
    end
end

local function startUpdating()
    if updateConnection then
        return
    end

    updateAccumulator = 0
    updateConnection = RunService.RenderStepped:Connect(function(deltaTime)
        stepAnimations(deltaTime)

        updateAccumulator += deltaTime
        if updateAccumulator >= UPDATE_INTERVAL then
            updateAccumulator -= UPDATE_INTERVAL
            updateTelemetry()
        end
    end)

    updateTelemetry()
end

local function startTracking(boat, seat, config)
    if currentBoat == boat then
        return
    end

    if not ensureGui() then
        return
    end

    currentBoat = boat
    currentSeat = seat
    currentConfig = config

    disconnectBoatConnection()
    boatConnection = boat.AncestryChanged:Connect(function(_, parent)
        if not parent then
            stopTracking()
        end
    end)

    if controlFrame then
        controlFrame.Visible = true
    end

    startUpdating()
end

local function onSeated(active, seat)
    if not active then
        if not seat or seat == currentSeat then
            stopTracking()
        end
        return
    end

    if not seat or not seat:IsA("VehicleSeat") then
        return
    end

    local ownerId = seat:GetAttribute("BoatOwner")
    if ownerId and tostring(ownerId) ~= tostring(player.UserId) then
        stopTracking()
        return
    end

    local boat = getBoatFromSeat(seat)
    if not boat then
        stopTracking()
        return
    end

    local config = getBoatConfig(boat)
    if not config or config.Type ~= "Submarine" then
        stopTracking()
        return
    end

    startTracking(boat, seat, config)
end

local function bindHumanoid(humanoid)
    if not humanoid then
        return
    end

    humanoid.Seated:Connect(onSeated)

    task.defer(function()
        if humanoid.SeatPart and humanoid.Sit then
            onSeated(true, humanoid.SeatPart)
        end
    end)
end

local function onCharacterAdded(character)
    stopTracking()

    local humanoid = character:WaitForChild("Humanoid", 5)
    if humanoid then
        bindHumanoid(humanoid)
    end
end

player.CharacterRemoving:Connect(function()
    stopTracking()
end)

if player.Character then
    onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

playerGui.ChildAdded:Connect(function(child)
    if child.Name == "SubmarineControlGUI" and child:IsA("ScreenGui") then
        ensureGui()
    end
end)

ensureGui()
