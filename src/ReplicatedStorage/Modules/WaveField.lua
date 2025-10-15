--!strict
-- WaveField.lua
-- Creates and animates a tiled deformable ocean surface. The module exposes
-- helpers for sampling the surface height so that physics systems stay in sync
-- with the rendered geometry.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaveRegistry = require(ReplicatedStorage.Modules.WaveRegistry)

type WaveCell = {
        Part: BasePart,
        VertexIndices: { number },
}

export type WaveTile = {
        Container: Folder,
        Cells: { WaveCell },
        BaseVertices: { Vector3 },
        DeformedVertices: { Vector3 },
        Stride: number,
        GridIndex: Vector2,
        Center: Vector2,
}

local WaveField = {}
WaveField.__index = WaveField

local function unitVector2(direction: Vector2): Vector2
        if direction.Magnitude < 1e-4 then
                return Vector2.new(1, 0)
        end
        return direction.Unit
end

local function tileKey(x: number, z: number): string
        return string.format("%d:%d", x, z)
end

local function createTileGeometry(resolution: number, size: number, thickness: number, parent: Instance)
        local halfSize = size * 0.5
        local step = size / resolution
        local stride = resolution + 1

        local baseVertices = table.create(stride * stride)
        local deformedVertices = table.create(stride * stride)

        local index = 1
        for z = 0, resolution do
                local offsetZ = -halfSize + (z * step)
                for x = 0, resolution do
                        local offsetX = -halfSize + (x * step)
                        baseVertices[index] = Vector3.new(offsetX, 0, offsetZ)
                        deformedVertices[index] = baseVertices[index]
                        index += 1
                end
        end

        local container = Instance.new("Folder")
        container.Name = "WaveTile"

        local cells = table.create(resolution * resolution)
        local cellIndex = 1
        for z = 0, resolution - 1 do
                for x = 0, resolution - 1 do
                        local i0 = (z * stride) + x + 1
                        local i1 = i0 + 1
                        local i2 = i0 + stride
                        local i3 = i2 + 1

                        local part = Instance.new("Part")
                        part.Anchored = true
                        part.CanCollide = false
                        part.CanTouch = false
                        part.CanQuery = false
                        part.CastShadow = false
                        part.Material = Enum.Material.Water
                        part.Color = Color3.fromRGB(10, 55, 102)
                        part.Transparency = 0.2
                        part.Reflectance = 0.05
                        part.Size = Vector3.new(step, thickness, step)
                        part.Name = string.format("WaveCell_%d_%d", x, z)
                        part.Parent = container

                        cells[cellIndex] = {
                                Part = part,
                                VertexIndices = { i0, i1, i2, i3 },
                        }
                        cellIndex += 1
                end
        end

        container.Parent = parent

        return container, cells, baseVertices, deformedVertices, stride
end

local function resolveWorldPosition(instance: Instance): Vector3?
        if instance:IsA("BasePart") then
                return instance.Position
        elseif instance:IsA("Model") then
                local primary = instance.PrimaryPart
                if primary then
                        return primary.Position
                end

                for _, descendant in instance:GetDescendants() do
                        if descendant:IsA("BasePart") then
                                return descendant.Position
                        end
                end
        end
        return nil
end

function WaveField.new(config)
        local self = setmetatable({}, WaveField)

        self.config = config
        self.seaLevel = config.SeaLevel or 0
        self.tileSize = config.TileSize or 128
        self.resolution = math.max(2, math.floor(config.Resolution or 16))
        self.tileRadius = math.max(1, math.floor(config.TileRadius or 1))
        self.choppiness = math.clamp(config.Choppiness or 0, 0, 1)
        self.waves = config.Waves or {}
        self.focusTags = config.FocusTags or {}
        self.followCamera = config.FollowCamera ~= false
        self.recenterResponsiveness = config.RecenterResponsiveness or 4
        self.tileThickness = math.max(0.1, config.TileThickness or 0.5)
        self.minCellSize = math.max(0.01, config.MinCellSize or 0.05)

        self.folder = Instance.new("Folder")
        self.folder.Name = config.ContainerName or "DynamicWaveSurface"
        self.folder.Parent = Workspace

        self.tiles = {}
        self.tilePool = {}
        self.time = 0
        self.focusPosition = Vector3.new(0, self.seaLevel, 0)

        self:_populateInitialTiles()
        WaveRegistry.SetActiveField(self)

        return self
end

function WaveField:_createTile(): WaveTile
        local container, cells, baseVertices, deformedVertices, stride = createTileGeometry(
                self.resolution,
                self.tileSize,
                self.tileThickness,
                self.folder
        )

        if self.config.PhysicalMaterial then
                for _, cell in ipairs(cells) do
                        cell.Part.CustomPhysicalProperties = self.config.PhysicalMaterial
                end
        end

        return {
                Container = container,
                Cells = cells,
                BaseVertices = baseVertices,
                DeformedVertices = deformedVertices,
                Stride = stride,
                GridIndex = Vector2.zero,
                Center = Vector2.zero,
        }
end

function WaveField:_obtainTile(): WaveTile
        local tile = table.remove(self.tilePool)
        if tile then
                return tile
        end
        return self:_createTile()
end

function WaveField:_assignTile(tile: WaveTile, cellX: number, cellZ: number, key: string)
        local centerX = (cellX + 0.5) * self.tileSize
        local centerZ = (cellZ + 0.5) * self.tileSize

        tile.Container.Parent = self.folder
        tile.GridIndex = Vector2.new(cellX, cellZ)
        tile.Center = Vector2.new(centerX, centerZ)
        tile.Container.Name = string.format("WaveTile_%d_%d", cellX, cellZ)

        self:_resetTile(tile)

        self.tiles[key] = tile
end

function WaveField:_populateInitialTiles()
        local baseCellX = 0
        local baseCellZ = 0
        for dz = -self.tileRadius, self.tileRadius do
                for dx = -self.tileRadius, self.tileRadius do
                        local cellX = baseCellX + dx
                        local cellZ = baseCellZ + dz
                        local tile = self:_obtainTile()
                        self:_assignTile(tile, cellX, cellZ, tileKey(cellX, cellZ))
                end
        end
end

function WaveField:_computeFocusPosition(): Vector3
        local accumulator = Vector3.zero
        local count = 0

        for _, tag in ipairs(self.focusTags) do
                for _, instance in ipairs(CollectionService:GetTagged(tag)) do
                        local position = resolveWorldPosition(instance)
                        if position then
                                accumulator += position
                                count += 1
                        end
                end
        end

        if count == 0 and self.followCamera then
                local camera = Workspace.CurrentCamera
                if camera then
                        accumulator = camera.CFrame.Position
                        count = 1
                end
        end

        if count == 0 then
                return self.focusPosition
        end

        local average = accumulator / count
        return Vector3.new(average.X, self.seaLevel, average.Z)
end

function WaveField:_updateTilePositions(targetFocus: Vector3)
        local tileSize = self.tileSize
        local baseCellX = math.floor(targetFocus.X / tileSize + 0.5)
        local baseCellZ = math.floor(targetFocus.Z / tileSize + 0.5)

        local requiredOrder = {}
        local requiredCells: {[string]: {cellX: number, cellZ: number, tile: WaveTile?}} = {}

        for dz = -self.tileRadius, self.tileRadius do
                for dx = -self.tileRadius, self.tileRadius do
                        local cellX = baseCellX + dx
                        local cellZ = baseCellZ + dz
                        local key = tileKey(cellX, cellZ)
                        requiredOrder[#requiredOrder + 1] = key
                        requiredCells[key] = { cellX = cellX, cellZ = cellZ }
                end
        end

        for key, tile in pairs(self.tiles) do
                local cell = requiredCells[key]
                if cell then
                        cell.tile = tile
                else
                        tile.Container.Parent = nil
                        self.tilePool[#self.tilePool + 1] = tile
                end
                self.tiles[key] = nil
        end

        for _, key in ipairs(requiredOrder) do
                local cell = requiredCells[key]
                local tile = cell.tile or self:_obtainTile()
                self:_assignTile(tile, cell.cellX, cell.cellZ, key)
        end
end

function WaveField:_evaluateWaves(x: number, z: number, time: number)
        local height = self.seaLevel
        local offsetX = 0
        local offsetZ = 0

        for _, wave in ipairs(self.waves) do
                local direction = unitVector2(wave.Direction or Vector2.new(1, 0))
                local amplitude = wave.Amplitude or 0
                local wavelength = wave.Wavelength or 1
                local speed = wave.Speed or 0

                local frequency = (2 * math.pi) / wavelength
                local phase = (direction.X * x + direction.Y * z) * frequency + (time * speed * frequency)

                local sinValue = math.sin(phase)
                local cosValue = math.cos(phase)

                height += sinValue * amplitude

                if self.choppiness > 0 then
                        local chop = amplitude * self.choppiness
                        offsetX += direction.X * cosValue * chop
                        offsetZ += direction.Y * cosValue * chop
                end
        end

        return height, offsetX, offsetZ
end

function WaveField:GetHeight(position: Vector3): number
        local height = self:_evaluateWaves(position.X, position.Z, self.time)
        return height
end

function WaveField:_updateTileGeometry(tile: WaveTile)
        local baseVertices = tile.BaseVertices
        local deformedVertices = tile.DeformedVertices
        local center = tile.Center

        for index = 1, #baseVertices do
                local base = baseVertices[index]
                local worldX = center.X + base.X
                local worldZ = center.Y + base.Z
                local height, offsetX, offsetZ = self:_evaluateWaves(worldX, worldZ, self.time)
                local localY = height - self.seaLevel
                local localX = base.X + offsetX
                local localZ = base.Z + offsetZ

                deformedVertices[index] = Vector3.new(localX, localY, localZ)
        end

        self:_applyDeformation(tile)
end

function WaveField:Step(dt: number)
        self.time += dt

        local targetFocus = self:_computeFocusPosition()
        local alpha = math.clamp(self.recenterResponsiveness * dt, 0, 1)
        self.focusPosition = self.focusPosition:Lerp(targetFocus, alpha)

        self:_updateTilePositions(self.focusPosition)

        for _, tile in pairs(self.tiles) do
                self:_updateTileGeometry(tile)
        end
end

function WaveField:Destroy()
        if WaveRegistry.GetActiveField() == self then
                WaveRegistry.SetActiveField(nil)
        end

        for key, tile in pairs(self.tiles) do
                tile.Container:Destroy()
                self.tiles[key] = nil
        end

        for index = #self.tilePool, 1, -1 do
                local tile = self.tilePool[index]
                self.tilePool[index] = nil
                tile.Container:Destroy()
        end

        if self.folder then
                self.folder:Destroy()
                self.folder = nil
        end
end

function WaveField:_resetTile(tile: WaveTile)
        local baseVertices = tile.BaseVertices
        local deformedVertices = tile.DeformedVertices
        for index = 1, #baseVertices do
                local base = baseVertices[index]
                deformedVertices[index] = Vector3.new(base.X, 0, base.Z)
        end
        self:_applyDeformation(tile)
end

function WaveField:_applyDeformation(tile: WaveTile)
        local deformedVertices = tile.DeformedVertices
        local offset = Vector3.new(tile.Center.X, self.seaLevel, tile.Center.Y)

        for _, cell in ipairs(tile.Cells) do
                local indices = cell.VertexIndices
                local v0 = deformedVertices[indices[1]]
                local v1 = deformedVertices[indices[2]]
                local v2 = deformedVertices[indices[3]]
                local v3 = deformedVertices[indices[4]]

                local p0 = offset + v0
                local p1 = offset + v1
                local p2 = offset + v2
                local p3 = offset + v3

                local xVector = p1 - p0
                local zVector = p2 - p0
                local xMagnitude = math.max(xVector.Magnitude, self.minCellSize)
                local zMagnitude = math.max(zVector.Magnitude, self.minCellSize)

                local xDir = xVector.Magnitude > 1e-5 and xVector.Unit or Vector3.new(1, 0, 0)
                local zDir = zVector.Magnitude > 1e-5 and zVector.Unit or Vector3.new(0, 0, 1)
                local yDir = xDir:Cross(zDir)
                if yDir.Magnitude < 1e-5 then
                        yDir = Vector3.new(0, 1, 0)
                        zDir = yDir:Cross(xDir)
                        if zDir.Magnitude < 1e-5 then
                                zDir = Vector3.new(0, 0, 1)
                        else
                                zDir = zDir.Unit
                        end
                else
                        yDir = yDir.Unit
                        zDir = yDir:Cross(xDir).Unit
                end

                local origin = (p0 + p1 + p2 + p3) * 0.25
                local cframe = CFrame.fromMatrix(origin, xDir, yDir, zDir)
                local part = cell.Part
                part.CFrame = cframe
                part.Size = Vector3.new(xMagnitude, self.tileThickness, zMagnitude)
        end
end

return WaveField
