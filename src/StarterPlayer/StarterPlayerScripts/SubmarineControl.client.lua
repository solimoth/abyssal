local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

local healthBarFullSize
local speedBarFullSize

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

local function setBarSize(bar, ratio, baseSize)
    if not bar or not baseSize then
        return
    end

    ratio = math.clamp(ratio, 0, 1)
    bar.Size = UDim2.new(
        baseSize.X.Scale * ratio,
        baseSize.X.Offset * ratio,
        baseSize.Y.Scale,
        baseSize.Y.Offset
    )
end

local function resetUi()
    if not controlFrame or not controlFrame.Parent then
        return
    end

    if healthLabel then
        healthLabel.Text = "100% HEALTH"
    end
    if speedLabel then
        speedLabel.Text = "0% SPEED"
    end
    if pressureLabel then
        pressureLabel.Text = "0% PRESSURE"
    end
    if depthLabel then
        depthLabel.Text = "0m"
    end
    if coordinatesLabel then
        coordinatesLabel.Text = zeroCoordinateText
    end
    if compassNeedle then
        compassNeedle.Rotation = 0
    end

    if healthBar and healthBarFullSize then
        healthBar.Size = healthBarFullSize
    end
    if speedBar and speedBarFullSize then
        speedBar.Size = UDim2.new(0, 0, speedBarFullSize.Y.Scale, speedBarFullSize.Y.Offset)
    end

    controlFrame.Visible = false
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
    healthBarFullSize = nil
    speedBarFullSize = nil
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

    healthBarFullSize = healthBar.Size
    speedBarFullSize = speedBar.Size

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

    if healthLabel then
        healthLabel.Text = string.format("%d%% HEALTH", healthPercent)
    end
    if speedLabel then
        speedLabel.Text = string.format("%d%% SPEED", speedPercent)
    end
    if pressureLabel then
        pressureLabel.Text = string.format("%d%% PRESSURE", pressurePercent)
    end
    if depthLabel then
        depthLabel.Text = string.format("%dm", depthMeters)
    end
    if coordinatesLabel then
        coordinatesLabel.Text = string.format(
            "%s, %s, %s",
            formatCoordinate(relativePosition.X),
            formatCoordinate(relativePosition.Y),
            formatCoordinate(relativePosition.Z)
        )
    end

    setBarSize(healthBar, healthPercent / 100, healthBarFullSize)
    setBarSize(speedBar, math.clamp(speedPercent / 100, 0, 1), speedBarFullSize)

    if compassNeedle then
        local lookVector = primaryPart.CFrame.LookVector
        local heading = math.deg(math.atan2(-lookVector.X, -lookVector.Z))
        compassNeedle.Rotation = heading
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
