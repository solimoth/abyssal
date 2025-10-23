local Workspace = game:GetService("Workspace")

local SwimInteriorUtils = {}

local CONFIG = {
    InteriorPartName = "ShipInterior",
    InteriorRegionPadding = Vector3.new(4, 6, 4),
    InteriorCacheDuration = 0.35,
}

local interiorCache = {}

local function computeInteriorStatus(character: Model, rootPart: BasePart)
    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = { character }

    local regionSize = rootPart.Size + CONFIG.InteriorRegionPadding
    local parts = Workspace:GetPartBoundsInBox(rootPart.CFrame, regionSize, overlapParams)

    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and part.Name == CONFIG.InteriorPartName then
            return true
        end
    end

    return false
end

function SwimInteriorUtils.Configure(overrides)
    if typeof(overrides) ~= "table" then
        return
    end

    for key, value in pairs(overrides) do
        if CONFIG[key] ~= nil then
            CONFIG[key] = value
        end
    end
end

function SwimInteriorUtils.ClearCharacterCache(character: Model?)
    if character then
        interiorCache[character] = nil
    end
end

function SwimInteriorUtils.IsInsideShipInterior(character: Model?)
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
        expiry = now + CONFIG.InteriorCacheDuration,
        rootPart = rootPart,
    }

    return inside
end

return SwimInteriorUtils
