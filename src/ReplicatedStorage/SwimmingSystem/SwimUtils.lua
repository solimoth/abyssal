local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_CONSTANTS = table.freeze({
    DesiredVelocityAttribute = "WaterSwimDesiredVelocity",

    InteriorPartName = "ShipInterior",
    InteriorRegionPadding = Vector3.new(4, 6, 4),
    InteriorCacheDuration = 0.35,

    BuoyancyAttachmentName = "SwimmingBuoyancyAttachment",
    LinearVelocityName = "SwimmingLinearVelocity",

    SurfaceHoldOffset = 1,
    SurfaceHoldStiffness = 6,
    SurfaceHoldDamping = 3,

    BaseSwimSpeed = 16,
    MinSwimSpeed = 6,
    MaxHorizontalSpeed = 24,
    MaxVerticalSpeed = 18,
    DepthSlowFactor = 0.2,

    MaxOxygenTime = 20,
    OxygenRecoveryRate = 8,
    DrowningDamage = 10,
    DrowningDamageInterval = 1,

    DesiredVelocityUpdateThresholdSquared = 0.25,
})

local SwimConstants = {}
local WaterPhysics = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("WaterPhysics"))

local SwimUtils = {}
SwimUtils.DefaultConstants = DEFAULT_CONSTANTS

local function applyConstants(overrides)
    table.clear(SwimConstants)

    for key, value in pairs(DEFAULT_CONSTANTS) do
        SwimConstants[key] = value
    end

    if overrides then
        for key, value in pairs(overrides) do
            SwimConstants[key] = value
        end
    end
end

function SwimUtils.Configure(constants)
    applyConstants(constants)
end

function SwimUtils.GetConstants()
    return SwimConstants
end

local function getConstants()
    return SwimConstants
end

-- Ensure defaults are applied even if Configure is never invoked externally.
applyConstants()

local interiorCache = {}

local function computeInteriorStatus(character: Model, rootPart: BasePart)
    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = { character }

    local constants = getConstants()
    local regionSize = rootPart.Size + constants.InteriorRegionPadding
    local parts = Workspace:GetPartBoundsInBox(rootPart.CFrame, regionSize, overlapParams)

    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and part.Name == constants.InteriorPartName then
            return true
        end
    end

    return false
end

function SwimUtils.ClearCharacterCache(character: Model?)
    if character then
        interiorCache[character] = nil
    end
end

function SwimUtils.IsInsideShipInterior(character: Model?): boolean
    if not character then
        return false
    end

    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        return false
    end

    local cacheEntry = interiorCache[character]
    local now = os.clock()
    if cacheEntry and cacheEntry.rootPart == rootPart and cacheEntry.expiry > now then
        return cacheEntry.value
    end

    local inside = computeInteriorStatus(character, rootPart)
    interiorCache[character] = {
        value = inside,
        expiry = now + getConstants().InteriorCacheDuration,
        rootPart = rootPart,
    }

    return inside
end

function SwimUtils.GetCharacterComponents(character: Model?)
    if not character then
        return nil, nil, nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    local head = character:FindFirstChild("Head")

    return humanoid, rootPart, head
end

function SwimUtils.AnalyzeCharacter(character: Model?, reuseTable)
    local humanoid, rootPart, head = SwimUtils.GetCharacterComponents(character)
    if not humanoid or not rootPart then
        return nil
    end

    local analysis = reuseTable or {}
    analysis.character = character
    analysis.humanoid = humanoid
    analysis.rootPart = rootPart
    analysis.head = head

    local insideInterior = SwimUtils.IsInsideShipInterior(character)
    analysis.insideInterior = insideInterior

    local surfaceY = WaterPhysics.TryGetWaterSurface(rootPart.Position)
    analysis.surfaceY = surfaceY

    local rootUnderwater = surfaceY ~= nil and rootPart.Position.Y < surfaceY
    analysis.rootUnderwater = rootUnderwater

    if head then
        analysis.headUnderwater = WaterPhysics.IsUnderwater(head.Position)
    else
        analysis.headUnderwater = false
    end

    if surfaceY then
        analysis.depth = math.max(0, surfaceY - rootPart.Position.Y)
    else
        analysis.depth = 0
    end

    analysis.shouldSwim = rootUnderwater and not insideInterior

    return analysis
end

return SwimUtils
