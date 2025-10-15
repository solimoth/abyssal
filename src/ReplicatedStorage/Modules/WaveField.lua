--!strict
-- WaveField.lua
-- Manages the authoritative wave simulation state used for gameplay physics.
-- Visual rendering is handled on the client (see WaveRenderer.client.lua), but
-- the server owns the wave clock and focus tracking so ships and water queries
-- remain consistent for everyone.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GerstnerWave = require(ReplicatedStorage.Modules.GerstnerWave)
local WaveRegistry = require(ReplicatedStorage.Modules.WaveRegistry)

export type WaveField = {
    config: any,
    seaLevel: number,
    focusPosition: Vector3,
    focusTags: { string },
    followPlayers: boolean,
    recenterResponsiveness: number,
    waveInfos: { GerstnerWave.WaveInfo },
    time: number,
    timeScale: number,
    intensity: number,
    targetIntensity: number,
    intensityResponsiveness: number,
    folder: Folder?,
    lastFocusX: number,
    lastFocusZ: number,
    lastIntensity: number,
    lastClock: number,
    tileSizeX: number,
    tileSizeZ: number,
    spacing: number,
    gridWidth: number,
    gridHeight: number,
    tileRadius: number,
    landZoneName: string,
    landZoneAttenuation: number,
    landZoneFadeDistance: number,
    landZones: { [BasePart]: boolean },
    landZoneAddedConn: RBXScriptConnection?,
    landZoneRemovingConn: RBXScriptConnection?,
}

local WaveField = {}
WaveField.__index = WaveField

local function resolveWorldPosition(instance: Instance): Vector3?
    if instance:IsA("BasePart") then
        return instance.Position
    elseif instance:IsA("Model") then
        local primary = instance.PrimaryPart
        if primary then
            return primary.Position
        end

        for _, descendant in ipairs(instance:GetDescendants()) do
            if descendant:IsA("BasePart") then
                return descendant.Position
            end
        end
    end

    return nil
end

function WaveField.new(config: any): WaveField
    local self = setmetatable({}, WaveField)

    self.config = config
    self.seaLevel = config.SeaLevel or 0
    self.focusTags = config.FocusTags or {}
    self.followPlayers = config.FollowPlayers ~= false
    self.recenterResponsiveness = math.max(0, config.RecenterResponsiveness or 6)
    self.waveInfos = GerstnerWave.BuildWaveInfos(config.Waves)
    self.time = Workspace:GetServerTimeNow()
    self.timeScale = math.max(0, config.TimeScale or 1)
    self.intensity = math.max(0, config.DefaultIntensity or 1)
    self.targetIntensity = self.intensity
    self.intensityResponsiveness = math.max(0, config.IntensityResponsiveness or 0)

    self.gridWidth = math.max(2, math.floor(config.GridWidth or 64))
    self.gridHeight = math.max(2, math.floor(config.GridHeight or 64))
    self.spacing = config.GridSpacing or 16
    self.tileRadius = math.max(0, math.floor(config.TileRadius or 0))
    self.tileSizeX = self.spacing * (self.gridWidth - 1)
    self.tileSizeZ = self.spacing * (self.gridHeight - 1)

    self.landZoneName = config.LandZoneName or "LandZone"
    self.landZoneAttenuation = math.clamp(config.LandZoneAttenuation or 1, 0, 1)
    self.landZoneFadeDistance = math.max(0, config.LandZoneFadeDistance or 0)
    self.landZones = {}

    self.focusPosition = Vector3.new(0, self.seaLevel, 0)
    self.lastFocusX = self.focusPosition.X
    self.lastFocusZ = self.focusPosition.Z
    self.lastIntensity = self.intensity
    self.lastClock = self.time

    local folder = Instance.new("Folder")
    folder.Name = config.ContainerName or "DynamicWaveSurface"
    folder:SetAttribute("SeaLevel", self.seaLevel)
    folder:SetAttribute("FocusX", self.focusPosition.X)
    folder:SetAttribute("FocusZ", self.focusPosition.Z)
    folder:SetAttribute("WaveClock", self.time)
    folder:SetAttribute("WaveIntensity", self.intensity)
    folder:SetAttribute("IntensityResponsiveness", self.intensityResponsiveness)
    folder:SetAttribute("TimeScale", self.timeScale)
    folder:SetAttribute("GridWidth", self.gridWidth)
    folder:SetAttribute("GridHeight", self.gridHeight)
    folder:SetAttribute("GridSpacing", self.spacing)
    folder:SetAttribute("TileRadius", self.tileRadius)
    folder:SetAttribute("Choppiness", math.clamp(config.Choppiness or 0, 0, 1))
    folder:SetAttribute("ReapplyInterval", math.max(1 / 60, config.ReapplyInterval or (1 / 20)))
    folder:SetAttribute("MaterialName", (config.Material and tostring(config.Material)) or "")
    folder:SetAttribute("Color", config.Color or Color3.fromRGB(30, 120, 150))
    folder:SetAttribute("Transparency", config.Transparency or 0.2)
    folder:SetAttribute("Reflectance", config.Reflectance or 0)
    folder:SetAttribute("LandZoneName", self.landZoneName)
    folder:SetAttribute("LandZoneAttenuation", self.landZoneAttenuation)
    folder:SetAttribute("LandZoneFadeDistance", self.landZoneFadeDistance)
    folder.Parent = Workspace
    self.folder = folder

    local function registerLandZone(instance: Instance)
        if instance:IsA("BasePart") and instance.Name == self.landZoneName then
            self.landZones[instance] = true
        end
    end

    for _, descendant in ipairs(Workspace:GetDescendants()) do
        registerLandZone(descendant)
    end

    self.landZoneAddedConn = Workspace.DescendantAdded:Connect(registerLandZone)
    self.landZoneRemovingConn = Workspace.DescendantRemoving:Connect(function(instance)
        if self.landZones[instance] then
            self.landZones[instance] = nil
        end
    end)

    WaveRegistry.SetActiveField(self)

    return self
end

function WaveField:_getFocusPosition(): Vector3
    local bestPosition: Vector3? = nil
    local closestDistance = math.huge

    local origin = self.focusPosition

    for _, tag in ipairs(self.focusTags) do
        for _, instance in ipairs(CollectionService:GetTagged(tag)) do
            if not instance:IsDescendantOf(Workspace) then
                continue
            end

            local worldPos = resolveWorldPosition(instance)
            if worldPos then
                local distance = (worldPos - origin).Magnitude
                if distance < closestDistance then
                    closestDistance = distance
                    bestPosition = worldPos
                end
            end
        end
    end

    if self.followPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            local character = player.Character
            if character then
                local hrp = character:FindFirstChild("HumanoidRootPart")
                local worldPos = hrp and hrp.Position or resolveWorldPosition(character)
                if worldPos then
                    local distance = (worldPos - origin).Magnitude
                    if distance < closestDistance then
                        closestDistance = distance
                        bestPosition = worldPos
                    end
                end
            end
        end
    end

    if not bestPosition then
        return Vector3.new(origin.X, self.seaLevel, origin.Z)
    end

    return Vector3.new(bestPosition.X, self.seaLevel, bestPosition.Z)
end

function WaveField:Step(dt: number)
    self.time += dt * self.timeScale

    local targetFocus = self:_getFocusPosition()
    if self.recenterResponsiveness > 0 then
        local alpha = math.clamp(dt * self.recenterResponsiveness, 0, 1)
        self.focusPosition = self.focusPosition:Lerp(targetFocus, alpha)
    else
        self.focusPosition = targetFocus
    end

    if self.intensity ~= self.targetIntensity then
        local alpha = self.intensityResponsiveness > 0 and math.clamp(dt * self.intensityResponsiveness, 0, 1) or 1
        self.intensity += (self.targetIntensity - self.intensity) * alpha
        if math.abs(self.intensity - self.targetIntensity) < 1e-3 then
            self.intensity = self.targetIntensity
        end
    end

    if self.folder then
        if math.abs(self.focusPosition.X - self.lastFocusX) > 1e-3 then
            self.lastFocusX = self.focusPosition.X
            self.folder:SetAttribute("FocusX", self.lastFocusX)
        end

        if math.abs(self.focusPosition.Z - self.lastFocusZ) > 1e-3 then
            self.lastFocusZ = self.focusPosition.Z
            self.folder:SetAttribute("FocusZ", self.lastFocusZ)
        end

        if math.abs(self.time - self.lastClock) > 1e-3 then
            self.lastClock = self.time
            self.folder:SetAttribute("WaveClock", self.lastClock)
        end

        if math.abs(self.intensity - self.lastIntensity) > 1e-3 then
            self.lastIntensity = self.intensity
            self.folder:SetAttribute("WaveIntensity", self.lastIntensity)
        end
    end
end

function WaveField:GetHeight(position: Vector3): number
    local surface = self:GetSurface(position)
    return surface.Height
end

function WaveField:SetTargetIntensity(intensity: number)
    self.targetIntensity = math.max(0, intensity)
end

function WaveField:GetIntensity(): number
    return self.intensity
end

function WaveField:_computeLandZoneAttenuation(position: Vector3): number
    if self.landZoneAttenuation >= 0.999 or not next(self.landZones) then
        return 1
    end

    local best = 1
    for part in pairs(self.landZones) do
        if typeof(part) ~= "Instance" then
            continue
        end

        if part.Parent then
            local halfSize = part.Size * 0.5
            local localPos = part.CFrame:PointToObjectSpace(position)
            local dx = math.max(math.abs(localPos.X) - halfSize.X, 0)
            local dz = math.max(math.abs(localPos.Z) - halfSize.Z, 0)
            local distanceOutside = math.sqrt((dx * dx) + (dz * dz))

            if distanceOutside <= self.landZoneFadeDistance then
                local t = self.landZoneFadeDistance > 0 and math.clamp(distanceOutside / self.landZoneFadeDistance, 0, 1) or 0
                local multiplier = self.landZoneAttenuation + (1 - self.landZoneAttenuation) * t
                if multiplier < best then
                    best = multiplier
                    if best <= self.landZoneAttenuation then
                        break
                    end
                end
            end
        else
            self.landZones[part] = nil
        end
    end

    return best
end

function WaveField:_getLocalIntensity(position: Vector3): number
    local attenuation = self:_computeLandZoneAttenuation(position)
    return math.max(0, self.intensity * attenuation)
end

function WaveField:GetSurface(position: Vector3)
    local baseTransform, tangent, binormal = GerstnerWave:GetHeightAndNormal(self.waveInfos, Vector2.new(position.X, position.Z), self.time)
    local localIntensity = self:_getLocalIntensity(position)

    local scaledX = baseTransform.X * localIntensity
    local scaledY = math.max(0, baseTransform.Y * localIntensity)
    local scaledZ = baseTransform.Z * localIntensity

    local tangentScaled = tangent * localIntensity
    local binormalScaled = binormal * localIntensity

    local normal = tangentScaled:Cross(binormalScaled)
    if normal.Magnitude < 1e-3 then
        normal = Vector3.yAxis
    else
        normal = normal.Unit
    end

    return {
        Height = self.seaLevel + scaledY,
        Normal = normal,
        Intensity = localIntensity,
        Displacement = Vector3.new(scaledX, scaledY, scaledZ),
    }
end

function WaveField:SetTimeScale(timeScale: number)
    self.timeScale = math.max(0, timeScale)
    if self.folder then
        self.folder:SetAttribute("TimeScale", self.timeScale)
    end
end

function WaveField:GetSeaLevel(): number
    return self.seaLevel
end

function WaveField:Destroy()
    if WaveRegistry.GetActiveField() == self then
        WaveRegistry.SetActiveField(nil)
    end

    if self.landZoneAddedConn then
        self.landZoneAddedConn:Disconnect()
        self.landZoneAddedConn = nil
    end

    if self.landZoneRemovingConn then
        self.landZoneRemovingConn:Disconnect()
        self.landZoneRemovingConn = nil
    end

    if self.folder then
        self.folder:Destroy()
        self.folder = nil
    end
end

return WaveField
