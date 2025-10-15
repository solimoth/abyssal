--!strict
-- WaveField.lua
-- Generates and animates an editable-mesh ocean surface. A limited number of
-- tiles slide underneath the active ships/players so the water feels infinite
-- while keeping performance requirements light enough for server simulation.

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GerstnerWave = require(ReplicatedStorage.Modules.GerstnerWave)
local WaveRegistry = require(ReplicatedStorage.Modules.WaveRegistry)

export type WaveTile = {
    Part: MeshPart,
    Editable: EditableMesh,
    Vertices: { { number } },
    OriginCF: CFrame,
    GridOffset: Vector2,
}

local WaveField = {}
WaveField.__index = WaveField

local function roundTo(value: number, snap: number): number
    if snap == 0 then
        return value
    end
    return math.floor(value / snap + 0.5) * snap
end

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

local ContentLib: any = (getfenv() :: any).Content

local function applyEditableToPart(editable: EditableMesh, part: MeshPart)
    if not AssetService.CreateMeshPartAsync then
        error("CreateMeshPartAsync is unavailable; editable mesh baking is not supported in this experience")
    end

    local content
    if ContentLib and ContentLib.fromObject then
        content = ContentLib.fromObject(editable)
    else
        error("Content.fromObject is unavailable; update your experience to the latest engine version")
    end

    local ok, meshPart = pcall(function()
        return AssetService:CreateMeshPartAsync(content)
    end)

    if ok and meshPart then
        part:ApplyMesh(meshPart)
        part.Size = meshPart.Size
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        meshPart:Destroy()
    else
        warn("Failed to bake editable mesh:", meshPart)
    end
end

local function buildEditableGrid(gridWidth: number, gridHeight: number, spacing: number)
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

local function createTile(folder: Folder, gridWidth: number, gridHeight: number, spacing: number, material: Enum.Material, color: Color3, transparency: number, reflectance: number, seaLevel: number, gridOffset: Vector2): WaveTile
    local editable, vertices = buildEditableGrid(gridWidth, gridHeight, spacing)

    local part = Instance.new("MeshPart")
    part.Name = string.format("WaveTile_%d_%d", gridOffset.X, gridOffset.Y)
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Material = material
    part.Color = color
    part.Transparency = transparency
    part.Reflectance = reflectance
    part.Parent = folder

    applyEditableToPart(editable, part)

    part.CFrame = CFrame.new(0, seaLevel, 0)

    return {
        Part = part,
        Editable = editable,
        Vertices = vertices,
        OriginCF = part.CFrame,
        GridOffset = gridOffset,
    }
end

local function convertWaveDefinition(entry: {[string]: any}): GerstnerWave.WaveInfo
    local direction = entry.Direction or Vector2.new(1, 0)
    if direction.Magnitude < 1e-3 then
        direction = Vector2.new(1, 0)
    else
        direction = direction.Unit
    end

    local wavelength = entry.Wavelength or entry.WaveLength or 64
    local amplitude = entry.Amplitude or entry.Height or 1
    local speed = entry.Speed or entry.PhaseSpeed
    local steepness = entry.Steepness
    local gravity = entry.Gravity

    local k = (2 * math.pi) / wavelength

    if not steepness then
        steepness = amplitude * k
    end

    steepness = math.clamp(steepness, 0, 1.2)

    if not gravity then
        if speed then
            gravity = speed * speed * k
        else
            gravity = Workspace.Gravity
        end
    end

    return GerstnerWave.WaveInfo.new(direction, wavelength, steepness, gravity)
end

function WaveField.new(config)
    local self = setmetatable({}, WaveField)

    self.config = config
    self.seaLevel = config.SeaLevel or 0
    self.gridWidth = math.max(2, math.floor(config.GridWidth or 64))
    self.gridHeight = math.max(2, math.floor(config.GridHeight or 64))
    self.spacing = config.GridSpacing or 16
    self.tileRadius = math.max(0, math.floor(config.TileRadius or 0))
    self.reapplyInterval = math.max(1 / 60, config.ReapplyInterval or (1 / 20))
    self.choppiness = math.clamp(config.Choppiness or 0, 0, 1)
    self.recenterResponsiveness = math.max(0, config.RecenterResponsiveness or 6)
    self.focusTags = config.FocusTags or {}
    self.followPlayers = config.FollowPlayers ~= false

    self.tileSizeX = self.spacing * (self.gridWidth - 1)
    self.tileSizeZ = self.spacing * (self.gridHeight - 1)

    self.folder = Instance.new("Folder")
    self.folder.Name = config.ContainerName or "DynamicWaveSurface"
    self.folder.Parent = Workspace

    self.waveInfos = table.create(#(config.Waves or {}))
    for _, entry in ipairs(config.Waves or {}) do
        self.waveInfos[#self.waveInfos + 1] = convertWaveDefinition(entry)
    end

    self.tiles = {}
    self.focusPosition = Vector3.new(0, self.seaLevel, 0)
    self.time = 0
    self.reapplyClock = self.reapplyInterval

    local material = config.Material or Enum.Material.Water
    local color = config.Color or Color3.fromRGB(30, 120, 150)
    local transparency = config.Transparency or 0.2
    local reflectance = config.Reflectance or 0

    for z = -self.tileRadius, self.tileRadius do
        for x = -self.tileRadius, self.tileRadius do
            local gridOffset = Vector2.new(x, z)
            local tile = createTile(self.folder, self.gridWidth, self.gridHeight, self.spacing, material, color, transparency, reflectance, self.seaLevel, gridOffset)
            table.insert(self.tiles, tile)
        end
    end

    if #self.tiles == 0 then
        local tile = createTile(self.folder, self.gridWidth, self.gridHeight, self.spacing, material, color, transparency, reflectance, self.seaLevel, Vector2.zero)
        table.insert(self.tiles, tile)
    end

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

function WaveField:_updateTileDeformation(tile: WaveTile)
    local editable = tile.Editable
    local vertices = tile.Vertices
    local originCF = tile.OriginCF

    for y = 1, self.gridHeight do
        local row = vertices[y]
        local vz = (self.spacing * (y - 1)) - (self.tileSizeZ * 0.5)
        for x = 1, self.gridWidth do
            local vx = (self.spacing * (x - 1)) - (self.tileSizeX * 0.5)
            local worldPosition = (originCF * CFrame.new(vx, 0, vz)).Position
            local transform = GerstnerWave:GetTransform(self.waveInfos, Vector2.new(worldPosition.X, worldPosition.Z), self.time)

            local offsetX = vx + (transform.X * self.choppiness)
            local offsetY = transform.Y
            local offsetZ = vz + (transform.Z * self.choppiness)

            editable:SetPosition(row[x], Vector3.new(offsetX, offsetY, offsetZ))
        end
    end
end

function WaveField:_applyEditableMeshes()
    for _, tile in ipairs(self.tiles) do
        applyEditableToPart(tile.Editable, tile.Part)
        tile.Part.CFrame = tile.OriginCF
    end
end

function WaveField:Step(dt: number)
    self.time += dt

    local targetFocus = self:_getFocusPosition()
    if self.recenterResponsiveness > 0 then
        local alpha = math.clamp(dt * self.recenterResponsiveness, 0, 1)
        self.focusPosition = self.focusPosition:Lerp(targetFocus, alpha)
    else
        self.focusPosition = targetFocus
    end

    local originX = roundTo(self.focusPosition.X, self.tileSizeX)
    local originZ = roundTo(self.focusPosition.Z, self.tileSizeZ)

    for _, tile in ipairs(self.tiles) do
        local offset = tile.GridOffset
        local tileOriginX = originX + (offset.X * self.tileSizeX)
        local tileOriginZ = originZ + (offset.Y * self.tileSizeZ)
        local originCF = CFrame.new(tileOriginX, self.seaLevel, tileOriginZ)

        tile.OriginCF = originCF
        tile.Part.CFrame = originCF
        self:_updateTileDeformation(tile)
    end

    self.reapplyClock -= dt
    if self.reapplyClock <= 0 then
        self.reapplyClock = self.reapplyInterval
        self:_applyEditableMeshes()
    end
end

function WaveField:GetHeight(position: Vector3): number
    local transform = GerstnerWave:GetTransform(self.waveInfos, Vector2.new(position.X, position.Z), self.time)
    return self.seaLevel + transform.Y
end

function WaveField:Destroy()
    if WaveRegistry.GetActiveField() == self then
        WaveRegistry.SetActiveField(nil)
    end

    for _, tile in ipairs(self.tiles) do
        tile.Part:Destroy()
        tile.Editable:Destroy()
    end

    table.clear(self.tiles)

    if self.folder.Parent then
        self.folder:Destroy()
    end
end

return WaveField
