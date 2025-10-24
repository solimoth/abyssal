--!strict
-- WaveRegistry.lua
-- Lightweight global registry that allows the dynamic wave field to expose
-- sampling utilities to systems that require water height queries (boats,
-- characters, particle effects, etc.).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GerstnerWave = require(ReplicatedStorage.Modules.GerstnerWave)
local WaveConfig = require(ReplicatedStorage.Modules.WaveConfig)

local WaveRegistry = {}

local activeField: any? = nil

local function setActiveField(field)
    if activeField == field then
        return
    end

    if activeField and activeField._isClientField and typeof(activeField.Destroy) == "function" then
        activeField:Destroy()
    end

    activeField = field
end

function WaveRegistry.SetActiveField(field)
    setActiveField(field)
end

function WaveRegistry.GetActiveField()
    return activeField
end

function WaveRegistry.Sample(position: Vector3): number?
    if activeField then
        return activeField:GetHeight(position)
    end
    return nil
end

function WaveRegistry.SampleSurface(position: Vector3)
    if activeField and activeField.GetSurface then
        return activeField:GetSurface(position)
    end
    return nil
end

if RunService:IsClient() then
    local ensureClientField

    local ClientWaveField = {}
    ClientWaveField.__index = ClientWaveField

    local DEFAULT_CONTAINER_NAME = WaveConfig.ContainerName or "DynamicWaveSurface"
    local DEFAULT_SEA_LEVEL = WaveConfig.SeaLevel or 0
    local DEFAULT_INTENSITY = WaveConfig.DefaultIntensity or 1
    local DEFAULT_TIME_SCALE = WaveConfig.TimeScale or 1
    local DEFAULT_LAND_ZONE_NAME = WaveConfig.LandZoneName or "LandZone"
    local DEFAULT_LAND_ZONE_ATTENUATION = WaveConfig.LandZoneAttenuation or 1
    local DEFAULT_LAND_ZONE_FADE = WaveConfig.LandZoneFadeDistance or 0

    local function attributeNumber(container: Instance, name: string, fallback: number): number
        local value = container:GetAttribute(name)
        if typeof(value) == "number" then
            return value
        end
        return fallback
    end

    local function attributeString(container: Instance, name: string, fallback: string): string
        local value = container:GetAttribute(name)
        if typeof(value) == "string" and value ~= "" then
            return value
        end
        return fallback
    end

    function ClientWaveField.new(container: Instance, onContainerInvalidated: (() -> ())?)
        local self = setmetatable({}, ClientWaveField)

        self._isClientField = true
        self.container = container
        self.waves = GerstnerWave.BuildWaveInfos(WaveConfig.Waves)
        self.timeScale = math.max(0, attributeNumber(container, "TimeScale", DEFAULT_TIME_SCALE))
        self.lastClock = attributeNumber(container, "WaveClock", Workspace:GetServerTimeNow())
        self.clockSyncedAt = os.clock()
        self.landZoneName = attributeString(container, "LandZoneName", DEFAULT_LAND_ZONE_NAME)
        self.landZoneAttenuation = math.clamp(
            attributeNumber(container, "LandZoneAttenuation", DEFAULT_LAND_ZONE_ATTENUATION),
            0,
            1
        )
        self.landZoneFadeDistance = math.max(0, attributeNumber(container, "LandZoneFadeDistance", DEFAULT_LAND_ZONE_FADE))
        self.landZones = {}
        self.destroyed = false
        self.invalidated = false
        self.onContainerInvalidated = onContainerInvalidated

        local connections = {}
        self.connections = connections

        local function trackConnection(conn)
            table.insert(connections, conn)
            return conn
        end

        local function onClockChanged()
            local attr = container:GetAttribute("WaveClock")
            if typeof(attr) == "number" and attr ~= self.lastClock then
                self.lastClock = attr
                self.clockSyncedAt = os.clock()
            end
        end

        local function onTimeScaleChanged()
            self.timeScale = math.max(0, attributeNumber(container, "TimeScale", DEFAULT_TIME_SCALE))
        end

        local function onLandZoneNameChanged()
            self.landZoneName = attributeString(container, "LandZoneName", DEFAULT_LAND_ZONE_NAME)
            self:_refreshLandZones()
        end

        local function onLandZoneSettingsChanged()
            self.landZoneAttenuation = math.clamp(
                attributeNumber(container, "LandZoneAttenuation", DEFAULT_LAND_ZONE_ATTENUATION),
                0,
                1
            )
            self.landZoneFadeDistance = math.max(0, attributeNumber(container, "LandZoneFadeDistance", DEFAULT_LAND_ZONE_FADE))
        end

        trackConnection(container:GetAttributeChangedSignal("WaveClock"):Connect(onClockChanged))
        trackConnection(container:GetAttributeChangedSignal("TimeScale"):Connect(onTimeScaleChanged))
        trackConnection(container:GetAttributeChangedSignal("LandZoneName"):Connect(onLandZoneNameChanged))
        trackConnection(container:GetAttributeChangedSignal("LandZoneAttenuation"):Connect(onLandZoneSettingsChanged))
        trackConnection(container:GetAttributeChangedSignal("LandZoneFadeDistance"):Connect(onLandZoneSettingsChanged))

        self.descendantAddedConn = Workspace.DescendantAdded:Connect(function(instance)
            self:_tryRegisterLandZone(instance)
        end)

        self.descendantRemovingConn = Workspace.DescendantRemoving:Connect(function(instance)
            if self.landZones[instance] then
                self.landZones[instance] = nil
            end
        end)

        self.containerDestroyingConn = container.Destroying:Connect(function()
            self:_handleContainerInvalidated()
        end)

        self.containerAncestryConn = container.AncestryChanged:Connect(function(_, parent)
            if not parent or not parent:IsDescendantOf(Workspace) then
                self:_handleContainerInvalidated()
            end
        end)

        self:_refreshLandZones()

        return self
    end

    function ClientWaveField:_handleContainerInvalidated()
        if self.destroyed or self.invalidated then
            return
        end

        self.invalidated = true

        if self.onContainerInvalidated then
            self.onContainerInvalidated()
        end
    end

    function ClientWaveField:_refreshLandZones()
        table.clear(self.landZones)
        for _, descendant in ipairs(Workspace:GetDescendants()) do
            self:_tryRegisterLandZone(descendant)
        end
    end

    function ClientWaveField:_tryRegisterLandZone(instance: Instance)
        if instance:IsA("BasePart") and instance.Name == self.landZoneName then
            self.landZones[instance] = true
        end
    end

    function ClientWaveField:_getWaveClock(): number
        local elapsed = os.clock() - self.clockSyncedAt
        return self.lastClock + (elapsed * self.timeScale)
    end

    function ClientWaveField:_computeLandZoneAttenuation(position: Vector3): number
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

    function ClientWaveField:GetSurface(position: Vector3)
        local runTime = self:_getWaveClock()
        local baseTransform, tangent, binormal = GerstnerWave:GetHeightAndNormal(
            self.waves,
            Vector2.new(position.X, position.Z),
            runTime
        )

        local seaLevel = attributeNumber(self.container, "SeaLevel", DEFAULT_SEA_LEVEL)
        local intensity = math.max(0, attributeNumber(self.container, "WaveIntensity", DEFAULT_INTENSITY))
        local localIntensity = math.max(0, intensity * self:_computeLandZoneAttenuation(position))

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
            Height = seaLevel + scaledY,
            Normal = normal,
            Intensity = localIntensity,
            Displacement = Vector3.new(scaledX, scaledY, scaledZ),
        }
    end

    function ClientWaveField:GetHeight(position: Vector3): number
        local surface = self:GetSurface(position)
        return surface.Height
    end

    function ClientWaveField:GetSeaLevel(): number
        return attributeNumber(self.container, "SeaLevel", DEFAULT_SEA_LEVEL)
    end

    function ClientWaveField:Destroy()
        if self.destroyed then
            return
        end

        self.destroyed = true
        self.onContainerInvalidated = nil

        if self.connections then
            for _, connection in ipairs(self.connections) do
                connection:Disconnect()
            end
            table.clear(self.connections)
            self.connections = nil
        end

        if self.descendantAddedConn then
            self.descendantAddedConn:Disconnect()
            self.descendantAddedConn = nil
        end

        if self.descendantRemovingConn then
            self.descendantRemovingConn:Disconnect()
            self.descendantRemovingConn = nil
        end

        if self.containerDestroyingConn then
            self.containerDestroyingConn:Disconnect()
            self.containerDestroyingConn = nil
        end

        if self.containerAncestryConn then
            self.containerAncestryConn:Disconnect()
            self.containerAncestryConn = nil
        end

        self.container = nil
        table.clear(self.landZones)
    end

    function ensureClientField()
        local container = Workspace:FindFirstChild(DEFAULT_CONTAINER_NAME)
        if not container then
            container = Workspace:WaitForChild(DEFAULT_CONTAINER_NAME)
        end

        if container then
            local clientField
            clientField = ClientWaveField.new(container, function()
                if activeField == clientField then
                    setActiveField(nil)
                    task.defer(ensureClientField)
                end
            end)

            setActiveField(clientField)
        end
    end

    task.defer(ensureClientField)
end

return WaveRegistry
