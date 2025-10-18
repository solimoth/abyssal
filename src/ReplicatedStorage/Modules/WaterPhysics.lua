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
local BOAT_LEAN_RESPONSIVENESS_MIN_SCALE = 0.35
local BOAT_LEAN_RESPONSIVENESS_MAX_SCALE = 1
local BOAT_MAX_ROLL = math.rad(22)
local BOAT_MAX_PITCH = math.rad(15)
local BOAT_ROLL_GAIN = 1
local BOAT_PITCH_GAIN = 0.9
local BOAT_LEAN_SLOPE_FOR_FULL_STRENGTH = math.rad(18)
local BOAT_MIN_LEAN_THRESHOLD = 0.05
local BOAT_INTENSITY_POWER = 2
local BOAT_SLOPE_DEADZONE = math.rad(1.5)
local BOAT_LEAN_CALM_INTENSITY_THRESHOLD = 0.9
local BOAT_LEAN_CALM_INTENSITY_EXPONENT = 2.5
local BOAT_LEAN_CALM_RESIDUAL_SCALE = 0.035
local BOAT_LEAN_CALM_BASELINE_SCALE = 0.1

local waterRaycastParams = RaycastParams.new()
waterRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
waterRaycastParams.FilterDescendantsInstances = {}
waterRaycastParams.IgnoreWater = false

local cachedWaterParts: { BasePart } = {}
local cachedWaterUpdateTime = 0

local function applyAngularDeadzone(angle: number): number
    local absAngle = math.abs(angle)
    if absAngle <= BOAT_SLOPE_DEADZONE then
        return 0
    end

    local sign = angle >= 0 and 1 or -1
    return (absAngle - BOAT_SLOPE_DEADZONE) * sign
end

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

function WaterPhysics.ApplyFloatingPhysics(
        currentCFrame: CFrame,
        boatType: string,
        deltaTime: number,
        targetOffsetOverride: any
)
        local position = currentCFrame.Position
        local surfaceSample = WaveRegistry.SampleSurface(position)
        local surfaceY
        local surfaceNormal = Vector3.yAxis
        local leanStrength = 0
        local intensity = 0
        local intensityScale = 0
        local leanIntensityScale = 0
        local targetPitch = 0
        local targetRoll = 0

        if surfaceSample then
                surfaceY = surfaceSample.Height
                surfaceNormal = surfaceSample.Normal
                intensity = math.clamp(surfaceSample.Intensity or 0, 0, 1)
                intensityScale = intensity ^ BOAT_INTENSITY_POWER

                if intensity > BOAT_LEAN_CALM_INTENSITY_THRESHOLD then
                        local normalized = (intensity - BOAT_LEAN_CALM_INTENSITY_THRESHOLD)
                                / math.max(1 - BOAT_LEAN_CALM_INTENSITY_THRESHOLD, 1e-3)
                        leanIntensityScale = math.clamp(normalized, 0, 1) ^ BOAT_LEAN_CALM_INTENSITY_EXPONENT
                elseif BOAT_LEAN_CALM_INTENSITY_THRESHOLD > 0 then
                        local calmNormalized = math.clamp(intensity / BOAT_LEAN_CALM_INTENSITY_THRESHOLD, 0, 1)
                        local residual = calmNormalized * BOAT_LEAN_CALM_RESIDUAL_SCALE
                        local baseline = calmNormalized * BOAT_LEAN_CALM_BASELINE_SCALE
                        leanIntensityScale = math.max(residual, baseline)
                end

                if surfaceNormal.Magnitude > 1e-3 and intensity > 0 then
                        surfaceNormal = surfaceNormal.Unit

                        local upDot = math.clamp(surfaceNormal:Dot(Vector3.yAxis), 0.01, 1)
                        local forward = currentCFrame.LookVector
                        local right = currentCFrame.RightVector

                        local forwardXZ = Vector3.new(forward.X, 0, forward.Z)
                        if forwardXZ.Magnitude < 1e-3 then
                                forwardXZ = Vector3.new(0, 0, -1)
                        else
                                forwardXZ = forwardXZ.Unit
                        end

                        local rightXZ = Vector3.new(right.X, 0, right.Z)
                        if rightXZ.Magnitude < 1e-3 then
                                rightXZ = Vector3.new(1, 0, 0)
                        else
                                rightXZ = rightXZ.Unit
                        end

                        local slopeForward = -(surfaceNormal.X * forwardXZ.X + surfaceNormal.Z * forwardXZ.Z) / upDot
                        local slopeRight = -(surfaceNormal.X * rightXZ.X + surfaceNormal.Z * rightXZ.Z) / upDot

					local basePitch = applyAngularDeadzone(math.atan(math.clamp(slopeForward, -4, 4)))
					local baseRoll = applyAngularDeadzone(math.atan(math.clamp(slopeRight, -4, 4)))

					local rawPitch = -basePitch * BOAT_PITCH_GAIN
					local rawRoll = -baseRoll * BOAT_ROLL_GAIN

                                        local slopeScale = 1
                                        if BOAT_LEAN_SLOPE_FOR_FULL_STRENGTH > 0 then
                                                local slopeMagnitude = math.max(math.abs(basePitch), math.abs(baseRoll))
                                                slopeScale = math.clamp(slopeMagnitude / BOAT_LEAN_SLOPE_FOR_FULL_STRENGTH, 0, 1)
                                        end

                                        local intensitySlopeScale = leanIntensityScale * slopeScale
                                        leanStrength = math.clamp(intensitySlopeScale, 0, 1)

                                        targetPitch = math.clamp(rawPitch * leanStrength, -BOAT_MAX_PITCH, BOAT_MAX_PITCH)
                                        targetRoll = math.clamp(rawRoll * leanStrength, -BOAT_MAX_ROLL, BOAT_MAX_ROLL)
                end
        else
                surfaceY = WaterPhysics.TryGetWaterSurface(position)
        end

        if not surfaceY then
                return currentCFrame, false
        end

        local offsetScalar
        local offsetLocal
        local overrideType = typeof(targetOffsetOverride)
        if overrideType == "table" then
                offsetScalar = targetOffsetOverride.vertical or targetOffsetOverride.target or targetOffsetOverride.offset
                offsetLocal = targetOffsetOverride.localOffset or targetOffsetOverride.local or targetOffsetOverride.vector
        elseif overrideType == "number" then
                offsetScalar = targetOffsetOverride
        end

        local _, currentYaw, _ = currentCFrame:ToOrientation()

        local rotation: CFrame
        if leanStrength <= BOAT_MIN_LEAN_THRESHOLD then
                rotation = CFrame.Angles(0, currentYaw, 0)
        else
                local targetOrientation = CFrame.new(position)
                        * CFrame.Angles(0, currentYaw, 0)
                        * CFrame.Angles(targetPitch, 0, 0)
                        * CFrame.Angles(0, 0, targetRoll)
                local responsivenessDriver = math.max(leanStrength, leanIntensityScale, intensityScale * 0.1, 0.05)
                local responsivenessScale = BOAT_LEAN_RESPONSIVENESS_MIN_SCALE
                        + (BOAT_LEAN_RESPONSIVENESS_MAX_SCALE - BOAT_LEAN_RESPONSIVENESS_MIN_SCALE) * responsivenessDriver
                local alpha = math.clamp(deltaTime * BOAT_LEAN_RESPONSIVENESS * responsivenessScale, 0, 1)
                local blendedOrientation = currentCFrame:Lerp(targetOrientation, alpha)
                rotation = blendedOrientation - blendedOrientation.Position
        end

        local targetOffset = offsetScalar
        if targetOffset == nil then
                if boatType == "Surface" then
                        targetOffset = 2
                elseif boatType == "Submarine" then
                        targetOffset = -1
                else
                        targetOffset = 0
                end
        end

        local targetHeight = surfaceY + targetOffset
        if offsetLocal then
                local rotatedOffset = rotation:VectorToWorldSpace(offsetLocal)
                targetHeight = surfaceY - rotatedOffset.Y
        end

        local yDifference = targetHeight - position.Y
        local stiffness = boatType == "Submarine" and 2 or 5
        local buoyancySpeed = math.clamp(yDifference * stiffness, -10, 10)
        local newY = position.Y + (buoyancySpeed * deltaTime)
        local basePosition = Vector3.new(position.X, newY, position.Z)

        local finalCFrame = CFrame.new(basePosition) * rotation
        return finalCFrame, true
end

return WaterPhysics
