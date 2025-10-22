--!strict
-- WaveRenderer.client.lua
-- Lightweight client visualiser for the dynamic wave system. Renders a set of
-- editable-mesh tiles that slide under the shared server focus point so the
-- ocean appears infinite without burdening the server.

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaveConfig = require(ReplicatedStorage.Modules.WaveConfig)
local GerstnerWave = require(ReplicatedStorage.Modules.GerstnerWave)

local ContentLib: any = (getfenv() :: any).Content

local abs = math.abs
local cos = math.cos
local exp = math.exp
local max = math.max
local sin = math.sin
local sqrt = math.sqrt
local vector3_new = Vector3.new

if not AssetService.CreateEditableMesh then
    warn("EditableMesh API is unavailable; wave visuals disabled on this client")
    return
end

if not AssetService.CreateMeshPartAsync then
    warn("CreateMeshPartAsync is unavailable; wave visuals disabled on this client")
    return
end

if not (ContentLib and ContentLib.fromObject) then
    warn("Content.fromObject is unavailable; wave visuals disabled on this client")
    return
end

local COLOR_LERP_SPEED = 3

local containerName = WaveConfig.ContainerName or "DynamicWaveSurface"
local container = Workspace:FindFirstChild(containerName)
if not container then
    container = Instance.new("Folder")
    container.Name = containerName
    container.Parent = Workspace
end

local function attributeNumber(name: string, fallback: number): number
    local value = container:GetAttribute(name)
    if typeof(value) == "number" then
        return value
    end
    return fallback
end

local function attributeColor(name: string, fallback: Color3): Color3
    local value = container:GetAttribute(name)
    if typeof(value) == "Color3" then
        return value
    end
    return fallback
end

local function attributeMaterial(name: string, fallback: Enum.Material): Enum.Material
    local value = container:GetAttribute(name)
    if typeof(value) == "string" and value ~= "" then
        local enumName = value:match("%.([^.]+)$") or value
        local ok, enumMaterial = pcall(function()
            return Enum.Material[enumName]
        end)
        if ok and enumMaterial then
            return enumMaterial
        end
    end
    return fallback
end

local function attributeString(name: string, fallback: string): string
    local value = container:GetAttribute(name)
    if typeof(value) == "string" and value ~= "" then
        return value
    end
    return fallback
end

local gridWidth = math.max(2, math.floor(attributeNumber("GridWidth", WaveConfig.GridWidth or 100)))
local gridHeight = math.max(2, math.floor(attributeNumber("GridHeight", WaveConfig.GridHeight or 100)))
local spacing = attributeNumber("GridSpacing", WaveConfig.GridSpacing or 20)
local tileRadius = math.max(0, math.floor(attributeNumber("TileRadius", WaveConfig.TileRadius or 0)))
local choppiness = math.clamp(attributeNumber("Choppiness", WaveConfig.Choppiness or 0.35), 0, 1)
local reapplyInterval = math.max(1 / 60, attributeNumber("ReapplyInterval", WaveConfig.ReapplyInterval or (1 / 20)))
local seaLevel = attributeNumber("SeaLevel", WaveConfig.SeaLevel or 0)
local intensity = math.max(0, attributeNumber("WaveIntensity", WaveConfig.DefaultIntensity or 1))
local targetIntensity = intensity
local intensityResponsiveness = math.max(0, attributeNumber("IntensityResponsiveness", WaveConfig.IntensityResponsiveness or 2.5))
local material = attributeMaterial("MaterialName", WaveConfig.Material or Enum.Material.Water)
local color = attributeColor("Color", WaveConfig.Color or Color3.fromRGB(30, 120, 150))
local targetColor = color
local transparency = attributeNumber("Transparency", WaveConfig.Transparency or 0.2)
local reflectance = attributeNumber("Reflectance", WaveConfig.Reflectance or 0)
local landZoneName = attributeString("LandZoneName", WaveConfig.LandZoneName or "LandZone")
local landZoneAttenuation = math.clamp(attributeNumber("LandZoneAttenuation", WaveConfig.LandZoneAttenuation or 1), 0, 1)
local landZoneFadeDistance = math.max(0, attributeNumber("LandZoneFadeDistance", WaveConfig.LandZoneFadeDistance or 0))

local tiles = {}
local colorChangedConn: RBXScriptConnection?

local tileSizeX = spacing * (gridWidth - 1)
local tileSizeZ = spacing * (gridHeight - 1)

local waves = GerstnerWave.BuildWaveInfos(WaveConfig.Waves)

local waveStates = table.create(#waves)
for i = 1, #waves do
    local info = waves[i]
    local state = {}
    local k, c, A, dir, _steepness, phaseOffset = GerstnerWave.System:CalculateWave(info)
    local dirX = dir.X
    local dirY = dir.Y

    state.dirAX = dirX * A
    state.dirAY = dirY * A
    state.A = A
    state.kDirX = k * dirX
    state.kDirY = k * dirY
    state.kc = k * c
    state.phaseOffset = phaseOffset
    state.timePhase = 0

    waveStates[i] = state
end

local waveCount = #waveStates

local lastClockAttribute = attributeNumber("WaveClock", Workspace:GetServerTimeNow())
local clockSyncedAt = os.clock()
local vertexSmoothingSpeed = math.max(0, attributeNumber("VertexSmoothingSpeed", WaveConfig.VertexSmoothingSpeed or 0))

local function getWaveClock()
    local attr = container:GetAttribute("WaveClock")
    if typeof(attr) == "number" and attr ~= lastClockAttribute then
        lastClockAttribute = attr
        clockSyncedAt = os.clock()
    end
    local elapsed = os.clock() - clockSyncedAt
    return lastClockAttribute + elapsed
end

local function roundTo(value: number, snap: number): number
    if snap == 0 then
        return value
    end
    return math.floor(value / snap + 0.5) * snap
end

local function applyEditableToPart(editable: EditableMesh, targetPart: MeshPart)
    local content = ContentLib.fromObject(editable)
    local ok, meshPart = pcall(function()
        return AssetService:CreateMeshPartAsync(content)
    end)

    if not ok or not meshPart then
        warn("Failed to bake editable mesh", meshPart)
        return
    end

    targetPart:ApplyMesh(meshPart)
    targetPart.Size = meshPart.Size
    targetPart.Anchored = true
    targetPart.CanCollide = false
    targetPart.CanQuery = false
    targetPart.CanTouch = false
    targetPart.CastShadow = false
    meshPart:Destroy()

    targetPart.Material = material
    targetPart.Color = color
    targetPart.Transparency = transparency
    targetPart.Reflectance = reflectance
end

local function refreshTileAppearance()
    for _, tile in ipairs(tiles) do
        local part = tile.Part
        if part then
            part.Material = material
            part.Color = color
            part.Transparency = transparency
            part.Reflectance = reflectance
        end
    end
end

local function colorsClose(a: Color3, b: Color3): boolean
    local dr = a.R - b.R
    local dg = a.G - b.G
    local db = a.B - b.B
    return (dr * dr) + (dg * dg) + (db * db) <= 1e-5
end

local function buildEditableGrid()
    local editable = AssetService:CreateEditableMesh()
    local vertices = table.create(gridHeight)

    local halfX = spacing * (gridWidth - 1) * 0.5
    local halfZ = spacing * (gridHeight - 1) * 0.5

    for y = 1, gridHeight do
        local row = table.create(gridWidth)
        local localZ = (spacing * (y - 1)) - halfZ
        for x = 1, gridWidth do
            local localX = (spacing * (x - 1)) - halfX
            local vertexId = editable:AddVertex(Vector3.new(localX, 0, localZ))
            row[x] = {
                Id = vertexId,
                OffsetX = localX,
                OffsetZ = localZ,
                LastX = localX,
                LastY = 0,
                LastZ = localZ,
            }
        end
        vertices[y] = row
    end

    for y = 1, gridHeight - 1 do
        local row = vertices[y]
        local nextRow = vertices[y + 1]
        for x = 1, gridWidth - 1 do
            local current = row[x]
            local below = nextRow[x]
            local right = row[x + 1]
            local belowRight = nextRow[x + 1]

            editable:AddTriangle(current.Id, below.Id, right.Id)
            editable:AddTriangle(below.Id, belowRight.Id, right.Id)
        end
    end

    return editable, vertices
end

local function createTile(gridOffset: Vector2)
    local part = Instance.new("MeshPart")
    part.Name = string.format("WaveTile_%d_%d", gridOffset.X, gridOffset.Y)
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Material = material
    part.Color = color
    part.Transparency = transparency
    part.Reflectance = reflectance
    part.Parent = container

    local editable, vertices = buildEditableGrid()
    applyEditableToPart(editable, part)
    part.CFrame = CFrame.new(0, seaLevel, 0)

    return {
        Part = part,
        Editable = editable,
        Vertices = vertices,
        GridOffset = gridOffset,
        OriginCF = part.CFrame,
    }
end

for z = -tileRadius, tileRadius do
    for x = -tileRadius, tileRadius do
        tiles[#tiles + 1] = createTile(Vector2.new(x, z))
    end
end

if #tiles == 0 then
    tiles[1] = createTile(Vector2.zero)
end

local function updateColorFromAttribute()
    local newColor = attributeColor("Color", targetColor)
    if newColor ~= targetColor then
        targetColor = newColor
    end
end

colorChangedConn = container:GetAttributeChangedSignal("Color"):Connect(updateColorFromAttribute)
updateColorFromAttribute()

local reapplyClock = 0

local landZones: { [BasePart]: boolean } = {}

local function registerLandZone(instance: Instance)
    if instance:IsA("BasePart") and instance.Name == landZoneName then
        landZones[instance] = true
    end
end

local function unregisterLandZone(instance: Instance)
    if landZones[instance] then
        landZones[instance] = nil
    end
end

local function rescanLandZones()
    table.clear(landZones)
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        registerLandZone(descendant)
    end
end

rescanLandZones()

local descendantAddedConn = Workspace.DescendantAdded:Connect(registerLandZone)
local descendantRemovingConn = Workspace.DescendantRemoving:Connect(unregisterLandZone)

local function landZoneMultiplier(worldPosition: Vector3): number
    if landZoneAttenuation >= 0.999 or not next(landZones) then
        return 1
    end

    local best = 1
    for part in pairs(landZones) do
        if part.Parent then
            local halfSize = part.Size * 0.5
            local localPos = part.CFrame:PointToObjectSpace(worldPosition)
            local dx = max(abs(localPos.X) - halfSize.X, 0)
            local dz = max(abs(localPos.Z) - halfSize.Z, 0)
            local distanceOutside = sqrt((dx * dx) + (dz * dz))

            if distanceOutside <= landZoneFadeDistance then
                local t = landZoneFadeDistance > 0 and math.clamp(distanceOutside / landZoneFadeDistance, 0, 1) or 0
                local multiplier = landZoneAttenuation + (1 - landZoneAttenuation) * t
                if multiplier < best then
                    best = multiplier
                    if best <= landZoneAttenuation then
                        break
                    end
                end
            end
        else
            landZones[part] = nil
        end
    end

    return best
end

local function getSharedFocus(): Vector2?
    local fx = container:GetAttribute("FocusX")
    local fz = container:GetAttribute("FocusZ")
    if typeof(fx) == "number" and typeof(fz) == "number" then
        return Vector2.new(fx, fz)
    end
    return nil
end

local function getFallbackFocus(): Vector2
    local localPlayer = Players.LocalPlayer
    local character = localPlayer and localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if hrp then
        return Vector2.new(hrp.Position.X, hrp.Position.Z)
    end

    local camera = Workspace.CurrentCamera
    if camera then
        local pos = camera.CFrame.Position
        return Vector2.new(pos.X, pos.Z)
    end

    return Vector2.zero
end

local function updateTile(tile, scaledChoppiness, globalIntensity, checkLandZones, smoothingAlpha)
    local editable = tile.Editable
    local vertices = tile.Vertices
    local originCF = tile.OriginCF

    if not editable or not vertices then
        return
    end

    local originPos = originCF.Position
    local tileOriginX = originPos.X
    local tileOriginZ = originPos.Z
    local tileSeaLevel = originPos.Y
    local shouldSample = waveCount > 0 and (scaledChoppiness ~= 0 or globalIntensity ~= 0)
    local doSmoothing = smoothingAlpha and smoothingAlpha > 0 and smoothingAlpha < 0.999

    -- Cache per-tile wave phase offsets so we avoid recomputing origin terms for
    -- every vertex. This keeps the runtime cost proportional to the number of
    -- vertices while still supporting arbitrarily many wave layers.
    local phaseOrigins = tile.PhaseOrigins
    if not phaseOrigins then
        phaseOrigins = table.create(waveCount)
        tile.PhaseOrigins = phaseOrigins
    end

    if shouldSample then
        for i = 1, waveCount do
            local state = waveStates[i]
            phaseOrigins[i] = (state.kDirX * tileOriginX) + (state.kDirY * tileOriginZ) + state.timePhase
        end
    end

    local rowPhaseBuffer = tile.RowPhaseBuffer
    if not rowPhaseBuffer then
        rowPhaseBuffer = table.create(waveCount)
        tile.RowPhaseBuffer = rowPhaseBuffer
    end

    for y = 1, gridHeight do
        local row = vertices[y]
        local firstVertex = row[1]
        local baseZ = firstVertex and firstVertex.OffsetZ or 0
        local worldZ = tileOriginZ + baseZ

        if shouldSample then
            for i = 1, waveCount do
                local state = waveStates[i]
                rowPhaseBuffer[i] = phaseOrigins[i] + (state.kDirY * baseZ)
            end
        end

        for x = 1, gridWidth do
            local vertex = row[x]
            local baseX = vertex.OffsetX

            local worldX = tileOriginX + baseX

            local targetX = baseX
            local targetY = 0
            local targetZ = baseZ

            if shouldSample then
                local sumX = 0
                local sumY = 0
                local sumZ = 0

                for i = 1, waveCount do
                    local state = waveStates[i]
                    local phase = rowPhaseBuffer[i] + (state.kDirX * baseX)
                    local cosPhase = cos(phase)
                    local sinPhase = sin(phase)

                    sumX += state.dirAX * cosPhase
                    sumY += state.A * sinPhase
                    sumZ += state.dirAY * cosPhase
                end

                local zoneMultiplier = 1
                if checkLandZones then
                    zoneMultiplier = landZoneMultiplier(vector3_new(worldX, tileSeaLevel, worldZ))
                end

                local localIntensity = globalIntensity * zoneMultiplier
                local localChoppiness = scaledChoppiness * zoneMultiplier

                if localChoppiness ~= 0 then
                    targetX += sumX * localChoppiness
                    targetZ += sumZ * localChoppiness
                end

                if localIntensity ~= 0 then
                    targetY = max(0, sumY * localIntensity)
                end
            end

            local offsetX = targetX
            local offsetY = targetY
            local offsetZ = targetZ

            if doSmoothing then
                offsetX = vertex.LastX + (targetX - vertex.LastX) * smoothingAlpha
                offsetY = vertex.LastY + (targetY - vertex.LastY) * smoothingAlpha
                offsetZ = vertex.LastZ + (targetZ - vertex.LastZ) * smoothingAlpha
            end

            vertex.LastX = offsetX
            vertex.LastY = offsetY
            vertex.LastZ = offsetZ

            editable:SetPosition(vertex.Id, vector3_new(offsetX, offsetY, offsetZ))
        end
    end
end

local renderStepName = "WaveRendererUpdate"
local renderStepBound = false
local heartbeatConn

local function step(dt)
    seaLevel = attributeNumber("SeaLevel", seaLevel)
    targetIntensity = math.max(0, attributeNumber("WaveIntensity", targetIntensity))
    intensityResponsiveness = math.max(0, attributeNumber("IntensityResponsiveness", intensityResponsiveness))
    landZoneAttenuation = math.clamp(attributeNumber("LandZoneAttenuation", landZoneAttenuation), 0, 1)
    landZoneFadeDistance = math.max(0, attributeNumber("LandZoneFadeDistance", landZoneFadeDistance))
    vertexSmoothingSpeed = math.max(0, attributeNumber("VertexSmoothingSpeed", vertexSmoothingSpeed))

    local updatedLandZoneName = attributeString("LandZoneName", landZoneName)
    if updatedLandZoneName ~= landZoneName then
        landZoneName = updatedLandZoneName
        rescanLandZones()
    end

    if intensity ~= targetIntensity then
        local alpha = intensityResponsiveness > 0 and math.clamp(dt * intensityResponsiveness, 0, 1) or 1
        intensity += (targetIntensity - intensity) * alpha
        if math.abs(intensity - targetIntensity) < 1e-3 then
            intensity = targetIntensity
        end
    end

    if not colorsClose(color, targetColor) then
        local alpha = COLOR_LERP_SPEED > 0 and (1 - math.exp(-COLOR_LERP_SPEED * dt)) or 1
        local newColor = color:Lerp(targetColor, alpha)
        if colorsClose(newColor, targetColor) then
            newColor = targetColor
        end

        if newColor ~= color then
            color = newColor
            refreshTileAppearance()
        end
    end

    local focus = getSharedFocus() or getFallbackFocus()
    local originX = roundTo(focus.X, tileSizeX)
    local originZ = roundTo(focus.Y, tileSizeZ)

    local runTime = getWaveClock()
    if waveCount > 0 then
        for i = 1, waveCount do
            local state = waveStates[i]
            state.timePhase = -(state.kc * runTime) + state.phaseOffset
        end
    end
    local scaledChoppiness = choppiness * intensity
    local checkLandZones = landZoneAttenuation < 0.999 and next(landZones) ~= nil
    local smoothingAlpha = 1
    if vertexSmoothingSpeed > 0 then
        smoothingAlpha = 1 - exp(-vertexSmoothingSpeed * dt)
        if smoothingAlpha > 1 then
            smoothingAlpha = 1
        end
    end

    for _, tile in ipairs(tiles) do
        local offset = tile.GridOffset
        local tileOriginX = originX + (offset.X * tileSizeX)
        local tileOriginZ = originZ + (offset.Y * tileSizeZ)
        local originCF = CFrame.new(tileOriginX, seaLevel, tileOriginZ)

        tile.OriginCF = originCF
        local part = tile.Part
        if part then
            part.CFrame = originCF
        end

        updateTile(tile, scaledChoppiness, intensity, checkLandZones, smoothingAlpha)
    end

    reapplyClock += dt
    if reapplyClock >= reapplyInterval then
        reapplyClock = 0
        for _, tile in ipairs(tiles) do
            local editable = tile.Editable
            local part = tile.Part
            if editable and part then
                applyEditableToPart(editable, part)
                part.CFrame = tile.OriginCF
            end
        end
    end
end

if RunService:IsClient() and RunService.BindToRenderStep then
    RunService:BindToRenderStep(renderStepName, Enum.RenderPriority.Last.Value, step)
    renderStepBound = true
else
    heartbeatConn = RunService.Heartbeat:Connect(step)
end

local function cleanup()
    if renderStepBound and RunService.UnbindFromRenderStep then
        RunService:UnbindFromRenderStep(renderStepName)
        renderStepBound = false
    end

    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end

    if colorChangedConn then
        colorChangedConn:Disconnect()
        colorChangedConn = nil
    end

    if descendantAddedConn then
        descendantAddedConn:Disconnect()
        descendantAddedConn = nil
    end

    if descendantRemovingConn then
        descendantRemovingConn:Disconnect()
        descendantRemovingConn = nil
    end

    for _, tile in ipairs(tiles) do
        if tile.Editable then
            tile.Editable:Destroy()
            tile.Editable = nil
        end

        if tile.Part then
            tile.Part:Destroy()
            tile.Part = nil
        end

        tile.PhaseOrigins = nil
        tile.RowPhaseBuffer = nil
    end

    table.clear(tiles)
    table.clear(landZones)
end

script.Destroying:Connect(cleanup)
