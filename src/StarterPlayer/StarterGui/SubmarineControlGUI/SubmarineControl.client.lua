local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)
local SubmarinePhysics = require(ReplicatedStorage.Modules.SubmarinePhysics)

local player = Players.LocalPlayer
local gui = script.Parent
local controlFrame = gui:WaitForChild("SubmarineControlFrame")

local compassNeedle = controlFrame:WaitForChild("CompassNeedle")
local healthBar = controlFrame:WaitForChild("HealthAmountLine")
local speedBar = controlFrame:WaitForChild("SpeedAmountLine")
local healthLabel = controlFrame:WaitForChild("HealthPercentLabel")
local speedLabel = controlFrame:WaitForChild("SpeedPercentLabel")
local pressureLabel = controlFrame:WaitForChild("HullPressurePercentLabel")
local coordinatesLabel = controlFrame:WaitForChild("CoordinatesLabel")
local depthLabel = controlFrame:WaitForChild("DepthAmountLabel")

local healthBarFullSize = healthBar.Size
local speedBarFullSize = speedBar.Size

local updateConnection
local boatConnection
local currentBoat
local currentConfig
local currentSeat
local updateAccumulator = 0
local UPDATE_INTERVAL = 0.05

local function disconnectBoatConnection()
    if boatConnection then
        boatConnection:Disconnect()
        boatConnection = nil
    end
end

local function resetUi()
    healthLabel.Text = "100% HEALTH"
    speedLabel.Text = "0% SPEED"
    pressureLabel.Text = "0% PRESSURE"
    depthLabel.Text = "0m"
    coordinatesLabel.Text = "0, 0, 0"
    compassNeedle.Rotation = 0
    healthBar.Size = healthBarFullSize
    speedBar.Size = UDim2.new(0, 0, speedBarFullSize.Y.Scale, speedBarFullSize.Y.Offset)
end

local function setBarSize(bar, ratio, baseSize)
    ratio = math.clamp(ratio, 0, 1)
    bar.Size = UDim2.new(
        baseSize.X.Scale * ratio,
        baseSize.X.Offset * ratio,
        baseSize.Y.Scale,
        baseSize.Y.Offset
    )
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
    controlFrame.Visible = false
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
    return math.floor(value + 0.5)
end

local function updateTelemetry()
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
        if not config or config.Type ~= "Submarine" then
            stopTracking()
            return
        end
        currentConfig = config
    end

    local info = SubmarinePhysics.GetSubmarineInfo(boat, config)

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

    healthLabel.Text = string.format("%d%% HEALTH", healthPercent)
    speedLabel.Text = string.format("%d%% SPEED", speedPercent)
    pressureLabel.Text = string.format("%d%% PRESSURE", pressurePercent)
    depthLabel.Text = string.format("%dm", depthMeters)
    coordinatesLabel.Text = string.format(
        "%d, %d, %d",
        formatCoordinate(position.X),
        formatCoordinate(position.Y),
        formatCoordinate(position.Z)
    )

    setBarSize(healthBar, healthPercent / 100, healthBarFullSize)
    setBarSize(speedBar, math.clamp(speedPercent / 100, 0, 1), speedBarFullSize)

    local lookVector = primaryPart.CFrame.LookVector
    local heading = math.deg(math.atan2(-lookVector.X, -lookVector.Z))
    compassNeedle.Rotation = heading

    if not controlFrame.Visible then
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

local function startTracking(boat, seat)
    if currentBoat == boat then
        return
    end

    currentBoat = boat
    currentSeat = seat
    currentConfig = nil

    disconnectBoatConnection()
    boatConnection = boat.AncestryChanged:Connect(function(_, parent)
        if not parent then
            stopTracking()
        end
    end)

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
    if ownerId and ownerId ~= tostring(player.UserId) then
        stopTracking()
        return
    end

    local boat = getBoatFromSeat(seat)
    if not boat then
        stopTracking()
        return
    end

    local boatType = boat:GetAttribute("BoatType")
    if boatType ~= "Submarine" then
        stopTracking()
        return
    end

    startTracking(boat, seat)
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

resetUi()
