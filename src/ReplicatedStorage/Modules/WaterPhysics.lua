local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = {}

local WaveRegistry = require(ReplicatedStorage.Modules.WaveRegistry)
local WaveConfig = require(ReplicatedStorage.Modules.WaveConfig)

-- The legacy system expected a fixed water level for the map. We keep a default so
-- downstream systems that rely on a reference plane continue to function even when
-- a water surface cannot be located with raycasts (for example while inside sealed
-- interiors). The value can be configured through TerrainWaterSystem if required.
local DEFAULT_WATER_LEVEL = WaveConfig.SeaLevel or 908.935

-- When sampling for the water surface we cast a ray both above and below the target
-- position to ensure we find the closest body of water without having to know the
-- exact top height ahead of time.
local WATER_SURFACE_SEARCH_DISTANCE = 512
local WATER_VOLUME_CACHE_DURATION = 1
local WATER_HORIZONTAL_TOLERANCE = 0.5
local WATER_VOLUME_TAGS = { "WaterVolume", "WaterRegion" }
local BOAT_LEAN_RESPONSIVENESS = 4

local waterRaycastParams = RaycastParams.new()
waterRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
waterRaycastParams.FilterDescendantsInstances = {}
waterRaycastParams.IgnoreWater = false

local cachedWaterParts: { BasePart } = {}
local cachedWaterUpdateTime = 0

local function refreshWaterParts()
    local now = os.clock()
    if now - cachedWaterUpdateTime <= WATER_VOLUME_CACHE_DURATION then
        return
    end

    table.clear(cachedWaterParts)
    local seenParts: {[BasePart]: boolean} = {}

    local function addWaterPartsFromFolder(folder: Instance?)
        if not folder then
            return
        end

        if folder:IsA("BasePart") and not seenParts[folder] then
            seenParts[folder] = true
            cachedWaterParts[#cachedWaterParts + 1] = folder
        end

        for _, descendant in ipairs(folder:GetDescendants()) do
            if descendant:IsA("BasePart") and not seenParts[descendant] then
                seenParts[descendant] = true
                cachedWaterParts[#cachedWaterParts + 1] = descendant
            end
        end
    end

    local seenFolders: {[Instance]: boolean} = {}

    local function tryAddFolder(parent: Instance?, name: string)
        if not parent then
            return
        end

        local folder = parent:FindFirstChild(name)
        if folder and not seenFolders[folder] then
            seenFolders[folder] = true
            addWaterPartsFromFolder(folder)
        end
    end

    tryAddFolder(Workspace, "Water")
    tryAddFolder(Workspace, "WaterParts")
    tryAddFolder(Workspace, "WaterVolumes")

    local mechanics = Workspace:FindFirstChild("Mechanics")
    tryAddFolder(mechanics, "Water")
    tryAddFolder(mechanics, "WaterParts")
    tryAddFolder(mechanics, "WaterVolumes")

    local gameplay = Workspace:FindFirstChild("Gameplay")
    if gameplay then
        tryAddFolder(gameplay, "Water")
        tryAddFolder(gameplay, "WaterParts")
        tryAddFolder(gameplay, "WaterVolumes")

        local gameplayMechanics = gameplay:FindFirstChild("Mechanics")
        tryAddFolder(gameplayMechanics, "Water")
        tryAddFolder(gameplayMechanics, "WaterParts")
        tryAddFolder(gameplayMechanics, "WaterVolumes")
    end

    local misc = Workspace:FindFirstChild("Misc")
    tryAddFolder(misc, "Water")
    tryAddFolder(misc, "WaterParts")
    tryAddFolder(misc, "WaterVolumes")

    for _, tag in ipairs(WATER_VOLUME_TAGS) do
        for _, instance in ipairs(CollectionService:GetTagged(tag)) do
            addWaterPartsFromFolder(instance)
        end
    end

    cachedWaterUpdateTime = now
end

local function findWaterSurfaceFromParts(position: Vector3): number?
    refreshWaterParts()

    local closestSurface: number? = nil
    local closestDistance = math.huge

    for _, part in ipairs(cachedWaterParts) do
        if not part:IsDescendantOf(Workspace) then
            continue
        end

        local halfSize = part.Size * 0.5
        local localPosition = part.CFrame:PointToObjectSpace(position)
        if math.abs(localPosition.X) > (halfSize.X + WATER_HORIZONTAL_TOLERANCE) then
            continue
        end
        if math.abs(localPosition.Z) > (halfSize.Z + WATER_HORIZONTAL_TOLERANCE) then
            continue
        end

        local topWorld = (part.CFrame * CFrame.new(0, halfSize.Y, 0)).Position
        local bottomWorld = (part.CFrame * CFrame.new(0, -halfSize.Y, 0)).Position
        local topY = math.max(topWorld.Y, bottomWorld.Y)

        local distance = math.abs(position.Y - topY)
        if distance < closestDistance then
            closestSurface = topY
            closestDistance = distance
        end
    end

    return closestSurface
end

local function sampleDynamicSurface(position: Vector3): number?
    local height = WaveRegistry.Sample(position)
    if height then
        return height
    end
    return nil
end

local function findWaterSurface(position: Vector3): number?
    local dynamicHeight = sampleDynamicSurface(position)
    if dynamicHeight then
        return dynamicHeight
    end

    local origin = position + Vector3.new(0, WATER_SURFACE_SEARCH_DISTANCE, 0)
    local direction = Vector3.new(0, -WATER_SURFACE_SEARCH_DISTANCE * 2, 0)
    local result = Workspace:Raycast(origin, direction, waterRaycastParams)

    if result and result.Material == Enum.Material.Water then
        return result.Position.Y
    end

    return findWaterSurfaceFromParts(position)
end

function WaterPhysics.GetWaterLevel(position: Vector3?)
        if position then
                local surfaceY = WaterPhysics.TryGetWaterSurface(position)
                if surfaceY then
                        return surfaceY
                end
        end

        return DEFAULT_WATER_LEVEL
end

function WaterPhysics.TryGetWaterSurface(position: Vector3)
    return findWaterSurface(position)
end

function WaterPhysics.IsUnderwater(position: Vector3)
        local surfaceY = WaterPhysics.TryGetWaterSurface(position)
        return surfaceY ~= nil and position.Y < surfaceY
end

function WaterPhysics.GetDepth(position: Vector3)
        local surfaceY = WaterPhysics.TryGetWaterSurface(position)
        if not surfaceY then
                return 0
        end

        return math.max(0, surfaceY - position.Y)
end

function WaterPhysics.GetPressure(position: Vector3)
        return WaterPhysics.GetDepth(position) / 100
end

function WaterPhysics.GetWaterDrag(velocity: Vector3, isSubmerged: boolean)
        if not isSubmerged then
                return velocity
        end

        local dragCoefficient = 0.95
        return velocity * dragCoefficient
end

function WaterPhysics.GetVisibilityAtDepth(position: Vector3)
        local depth = WaterPhysics.GetDepth(position)

        if depth <= 0 then
                return 1
        elseif depth < 50 then
                return 1 - (depth / 100)
        elseif depth < 200 then
                return 0.5 - ((depth - 50) / 300)
        else
                return 0.1
        end
end

local function calculateDisplacementRatio(part: BasePart, surfaceY: number)
        local halfHeight = part.Size.Y * 0.5
        local bottomY = part.Position.Y - halfHeight
        local displacedHeight = surfaceY - bottomY
        local range = part.Size.Y + 0.5

        return math.clamp(displacedHeight / range, 0, 1)
end

function WaterPhysics.ComputeBuoyancyForce(part: BasePart, surfaceY: number)
        local displacementRatio = calculateDisplacementRatio(part, surfaceY)
        if displacementRatio <= 0 then
                return Vector3.zero, displacementRatio
        end

        local mass = part:GetMass()
        local gravity = Workspace.Gravity
        local upwardForce = mass * gravity * displacementRatio

        return Vector3.new(0, upwardForce, 0), displacementRatio
end

function WaterPhysics.ApplyFloatingPhysics(currentCFrame: CFrame, boatType: string, deltaTime: number)
        local position = currentCFrame.Position
        local surfaceSample = WaveRegistry.SampleSurface(position)
        local surfaceY
        local surfaceNormal = Vector3.yAxis
        local leanStrength = 0

        if surfaceSample then
                surfaceY = surfaceSample.Height
                surfaceNormal = surfaceSample.Normal
                leanStrength = math.clamp(surfaceSample.Intensity or 0, 0, 1)
        else
                surfaceY = WaterPhysics.TryGetWaterSurface(position)
        end

        if not surfaceY then
                return currentCFrame, false
        end

        local targetOffset = 0
        if boatType == "Surface" then
                targetOffset = 2
        elseif boatType == "Submarine" then
                targetOffset = -1
        end

        local targetY = surfaceY + targetOffset
        local yDifference = targetY - position.Y
        local stiffness = boatType == "Submarine" and 2 or 5
        local buoyancySpeed = math.clamp(yDifference * stiffness, -10, 10)
        local newY = position.Y + (buoyancySpeed * deltaTime)

        local _, currentYaw, _ = currentCFrame:ToOrientation()
        local basePosition = Vector3.new(position.X, newY, position.Z)

        if leanStrength <= 0 then
                local newCFrame = CFrame.new(basePosition) * CFrame.Angles(0, currentYaw, 0)
                return newCFrame, true
        end

        surfaceNormal = surfaceNormal.Magnitude > 1e-3 and surfaceNormal.Unit or Vector3.yAxis
        if leanStrength < 1 then
                local blendedNormal = surfaceNormal:Lerp(Vector3.yAxis, 1 - leanStrength)
                if blendedNormal.Magnitude > 1e-3 then
                        surfaceNormal = blendedNormal.Unit
                else
                        surfaceNormal = Vector3.yAxis
                end
        end

        local forward = currentCFrame.LookVector
        forward = forward - surfaceNormal * forward:Dot(surfaceNormal)
        if forward.Magnitude < 1e-3 then
                local right = currentCFrame.RightVector
                forward = right - surfaceNormal * right:Dot(surfaceNormal)
        end
        if forward.Magnitude < 1e-3 then
                forward = Vector3.zAxis
        end
        forward = forward.Unit

        local targetOrientation = CFrame.lookAt(basePosition, basePosition + forward, surfaceNormal)
        local alpha = math.clamp(deltaTime * BOAT_LEAN_RESPONSIVENESS, 0, 1)
        local blendedOrientation = currentCFrame:Lerp(targetOrientation, alpha)
        local rotation = blendedOrientation - blendedOrientation.Position

        local finalCFrame = CFrame.new(basePosition) * rotation
        return finalCFrame, true
end

return WaterPhysics
