local Workspace = game:GetService("Workspace")

local WaterPhysics = {}

-- The legacy system expected a fixed water level for the map. We keep a default so
-- downstream systems that rely on a reference plane continue to function even when
-- a water surface cannot be located with raycasts (for example while inside sealed
-- interiors). The value can be configured through TerrainWaterSystem if required.
local DEFAULT_WATER_LEVEL = 908.935

-- When sampling for the water surface we cast a ray both above and below the target
-- position to ensure we find the closest body of water without having to know the
-- exact top height ahead of time.
local WATER_SURFACE_SEARCH_DISTANCE = 512

local waterRaycastParams = RaycastParams.new()
waterRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
waterRaycastParams.FilterDescendantsInstances = {}
waterRaycastParams.IgnoreWater = false

local function findWaterSurface(position: Vector3)
        local origin = position + Vector3.new(0, WATER_SURFACE_SEARCH_DISTANCE, 0)
        local direction = Vector3.new(0, -WATER_SURFACE_SEARCH_DISTANCE * 2, 0)
        local result = Workspace:Raycast(origin, direction, waterRaycastParams)

        if result and result.Material == Enum.Material.Water then
                return result.Position.Y, result
        end

        return nil, nil
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
        local surfaceY = WaterPhysics.TryGetWaterSurface(position)

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
        local newCFrame = CFrame.new(position.X, newY, position.Z) * CFrame.Angles(0, currentYaw, 0)

        return newCFrame, true
end

return WaterPhysics
