--!strict
-- WaveField.lua
-- Creates and animates a tiled EditableMesh ocean surface. The module exposes
-- helpers for sampling the surface height so that physics systems stay in sync
-- with the rendered geometry.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaveRegistry = require(ReplicatedStorage.Modules.WaveRegistry)

export type WaveTile = {
        Part: MeshPart,
        Mesh: EditableMesh,
        VertexIds: { number },
        BaseVertices: { Vector3 },
        GridIndex: Vector2,
        Center: Vector2,
        NextUpload: number,
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

local function createEditablePlane(part: MeshPart, resolution: number, size: number)
        local halfSize = size * 0.5
        local step = size / resolution

        local baseVertices = table.create((resolution + 1) * (resolution + 1))
        if not part.CreateEditableMesh then
                error("EditableMesh is not supported on this MeshPart; ensure the Editable Mesh feature is enabled")
        end

        local mesh = part:CreateEditableMesh()
        mesh.Name = "WaveEditableMesh"

        local vertexIds = {}
        local index = 1
        for z = 0, resolution do
                local offsetZ = -halfSize + (z * step)
                for x = 0, resolution do
                        local offsetX = -halfSize + (x * step)
                        baseVertices[index] = Vector3.new(offsetX, 0, offsetZ)
                        vertexIds[index] = mesh:AddVertex(baseVertices[index])
                        index += 1
                end
        end

        local stride = resolution + 1
        for z = 0, resolution - 1 do
                for x = 0, resolution - 1 do
                        local i0 = (z * stride) + x + 1
                        local i1 = i0 + 1
                        local i2 = i0 + stride
                        local i3 = i2 + 1

                        mesh:AddTriangle(vertexIds[i0], vertexIds[i2], vertexIds[i1])
                        mesh:AddTriangle(vertexIds[i1], vertexIds[i2], vertexIds[i3])
                end
        end

        mesh.Parent = part

        return mesh, vertexIds, baseVertices
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
        self.uploadInterval = math.max(0.03, config.UploadInterval or 0.1)
        self.choppiness = math.clamp(config.Choppiness or 0, 0, 1)
        self.waves = config.Waves or {}
        self.focusTags = config.FocusTags or {}
        self.followCamera = config.FollowCamera ~= false
        self.recenterResponsiveness = config.RecenterResponsiveness or 4

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
        local part = Instance.new("MeshPart")
        part.Name = "WaveTile"
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        part.CastShadow = false
        part.Material = Enum.Material.Water
        part.Color = Color3.fromRGB(10, 55, 102)
        part.Transparency = 0.2
        part.Reflectance = 0.05
        part.Size = Vector3.new(self.tileSize, 1, self.tileSize)
        if self.config.PhysicalMaterial then
                part.CustomPhysicalProperties = self.config.PhysicalMaterial
        end
        -- MeshPart:CreateEditableMesh requires the part to be parented, so temporarily
        -- attach it to the folder before creating the editable mesh surface.
        part.Parent = self.folder

        local mesh, vertexIds, baseVertices = createEditablePlane(part, self.resolution, self.tileSize)
        mesh:ApplyToBasePart(part)

        return {
                Part = part,
                Mesh = mesh,
                VertexIds = vertexIds,
                BaseVertices = baseVertices,
                GridIndex = Vector2.zero,
                Center = Vector2.zero,
                NextUpload = 0,
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

        tile.Part.Parent = self.folder
        tile.GridIndex = Vector2.new(cellX, cellZ)
        tile.Center = Vector2.new(centerX, centerZ)
        tile.Part.CFrame = CFrame.new(centerX, self.seaLevel, centerZ)
        tile.Part.Name = string.format("WaveTile_%d_%d", cellX, cellZ)
        tile.NextUpload = 0

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
                        tile.Part.Parent = nil
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

function WaveField:_updateTileGeometry(tile: WaveTile, now: number)
        local vertexIds = tile.VertexIds
        local baseVertices = tile.BaseVertices
        local mesh = tile.Mesh
        local center = tile.Center

        for index = 1, #vertexIds do
                        local base = baseVertices[index]
                        local worldX = center.X + base.X
                        local worldZ = center.Y + base.Z
                        local height, offsetX, offsetZ = self:_evaluateWaves(worldX, worldZ, self.time)
                        local localY = height - self.seaLevel
                        local localX = base.X + offsetX
                        local localZ = base.Z + offsetZ

                        mesh:SetVertexPosition(vertexIds[index], Vector3.new(localX, localY, localZ))
        end

        if now >= tile.NextUpload then
                mesh:ApplyToBasePart(tile.Part)
                tile.NextUpload = now + self.uploadInterval
        end
end

function WaveField:Step(dt: number)
        self.time += dt

        local targetFocus = self:_computeFocusPosition()
        local alpha = math.clamp(self.recenterResponsiveness * dt, 0, 1)
        self.focusPosition = self.focusPosition:Lerp(targetFocus, alpha)

        self:_updateTilePositions(self.focusPosition)

        local now = os.clock()
        for _, tile in pairs(self.tiles) do
                self:_updateTileGeometry(tile, now)
        end
end

function WaveField:Destroy()
        if WaveRegistry.GetActiveField() == self then
                WaveRegistry.SetActiveField(nil)
        end

        for key, tile in pairs(self.tiles) do
                tile.Part:Destroy()
                self.tiles[key] = nil
        end

        for index = #self.tilePool, 1, -1 do
                local tile = self.tilePool[index]
                self.tilePool[index] = nil
                tile.Part:Destroy()
        end

        if self.folder then
                self.folder:Destroy()
                self.folder = nil
        end
end

return WaveField
