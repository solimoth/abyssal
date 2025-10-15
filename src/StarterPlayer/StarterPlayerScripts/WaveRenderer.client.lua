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

local gridWidth = math.max(2, math.floor(attributeNumber("GridWidth", WaveConfig.GridWidth or 100)))
local gridHeight = math.max(2, math.floor(attributeNumber("GridHeight", WaveConfig.GridHeight or 100)))
local spacing = attributeNumber("GridSpacing", WaveConfig.GridSpacing or 20)
local tileRadius = math.max(0, math.floor(attributeNumber("TileRadius", WaveConfig.TileRadius or 0)))
local choppiness = math.clamp(attributeNumber("Choppiness", WaveConfig.Choppiness or 0.35), 0, 1)
local reapplyInterval = math.max(1 / 60, attributeNumber("ReapplyInterval", WaveConfig.ReapplyInterval or (1 / 20)))
local seaLevel = attributeNumber("SeaLevel", WaveConfig.SeaLevel or 0)
local material = attributeMaterial("MaterialName", WaveConfig.Material or Enum.Material.Water)
local color = attributeColor("Color", WaveConfig.Color or Color3.fromRGB(30, 120, 150))
local transparency = attributeNumber("Transparency", WaveConfig.Transparency or 0.2)
local reflectance = attributeNumber("Reflectance", WaveConfig.Reflectance or 0)

local tileSizeX = spacing * (gridWidth - 1)
local tileSizeZ = spacing * (gridHeight - 1)

local waves = GerstnerWave.BuildWaveInfos(WaveConfig.Waves)

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

local function buildEditableGrid()
    local editable = AssetService:CreateEditableMesh()
    local vertices = table.create(gridHeight)

    local halfX = spacing * (gridWidth - 1) * 0.5
    local halfZ = spacing * (gridHeight - 1) * 0.5

    for y = 1, gridHeight do
        local row = table.create(gridWidth)
        local vz = (spacing * (y - 1)) - halfZ
        for x = 1, gridWidth do
            local vx = (spacing * (x - 1)) - halfX
            row[x] = editable:AddVertex(Vector3.new(vx, 0, vz))
        end
        vertices[y] = row
    end

    for y = 1, gridHeight - 1 do
        for x = 1, gridWidth - 1 do
            local v1 = vertices[y][x]
            local v2 = vertices[y + 1][x]
            local v3 = vertices[y][x + 1]
            local v4 = vertices[y + 1][x + 1]

            editable:AddTriangle(v1, v2, v3)
            editable:AddTriangle(v2, v4, v3)
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
        SeaY = seaLevel,
    }
end

local tiles = {}
for z = -tileRadius, tileRadius do
    for x = -tileRadius, tileRadius do
        tiles[#tiles + 1] = createTile(Vector2.new(x, z))
    end
end

if #tiles == 0 then
    tiles[1] = createTile(Vector2.zero)
end

local reapplyClock = 0

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

local function updateTile(tile)
    local editable = tile.Editable
    local vertices = tile.Vertices
    local originCF = tile.OriginCF

    local runTime = Workspace:GetServerTimeNow()

    for y = 1, gridHeight do
        local row = vertices[y]
        local vz = (spacing * (y - 1)) - (tileSizeZ * 0.5)
        for x = 1, gridWidth do
            local vx = (spacing * (x - 1)) - (tileSizeX * 0.5)

            local worldPosition = (originCF * CFrame.new(vx, 0, vz)).Position
            local transform = GerstnerWave:GetTransform(waves, Vector2.new(worldPosition.X, worldPosition.Z), runTime)

            local offsetX = vx + (transform.X * choppiness)
            local offsetY = transform.Y
            local offsetZ = vz + (transform.Z * choppiness)

            editable:SetPosition(row[x], Vector3.new(offsetX, offsetY, offsetZ))
        end
    end
end

RunService.Heartbeat:Connect(function(dt)
    seaLevel = attributeNumber("SeaLevel", seaLevel)

    local focus = getSharedFocus() or getFallbackFocus()
    local originX = roundTo(focus.X, tileSizeX)
    local originZ = roundTo(focus.Y, tileSizeZ)

    for _, tile in ipairs(tiles) do
        local offset = tile.GridOffset
        local tileOriginX = originX + (offset.X * tileSizeX)
        local tileOriginZ = originZ + (offset.Y * tileSizeZ)
        local originCF = CFrame.new(tileOriginX, seaLevel, tileOriginZ)

        tile.OriginCF = originCF
        tile.Part.CFrame = originCF
        updateTile(tile)
    end

    reapplyClock += dt
    if reapplyClock >= reapplyInterval then
        reapplyClock = 0
        for _, tile in ipairs(tiles) do
            applyEditableToPart(tile.Editable, tile.Part)
            tile.Part.CFrame = tile.OriginCF
        end
    end
end)
