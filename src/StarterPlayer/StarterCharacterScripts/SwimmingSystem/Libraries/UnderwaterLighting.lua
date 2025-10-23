local Lighting = game:GetService("Lighting")

local COLOR_CORRECTION_NAME = "SwimmingUnderwaterColorCorrection"
local DEPTH_OF_FIELD_NAME = "SwimmingUnderwaterDepth"

local UnderwaterLighting = {}
UnderwaterLighting.__index = UnderwaterLighting

local function findOrCreateColorCorrection()
    local existing = Lighting:FindFirstChild(COLOR_CORRECTION_NAME)
    if existing and existing:IsA("ColorCorrectionEffect") then
        return existing
    end

    local effect = Instance.new("ColorCorrectionEffect")
    effect.Name = COLOR_CORRECTION_NAME
    effect.TintColor = Color3.fromRGB(70, 160, 205)
    effect.Brightness = -0.15
    effect.Contrast = -0.05
    effect.Saturation = -0.2
    effect.Enabled = false
    effect.Parent = Lighting
    return effect
end

local function findOrCreateDepthOfField()
    local existing = Lighting:FindFirstChild(DEPTH_OF_FIELD_NAME)
    if existing and existing:IsA("DepthOfFieldEffect") then
        return existing
    end

    local effect = Instance.new("DepthOfFieldEffect")
    effect.Name = DEPTH_OF_FIELD_NAME
    effect.FarIntensity = 0.35
    effect.NearIntensity = 0.55
    effect.FocusDistance = 25
    effect.InFocusRadius = 18
    effect.Enabled = false
    effect.Parent = Lighting
    return effect
end

function UnderwaterLighting:_ensureEffects()
    if not self._colorCorrection then
        self._colorCorrection = findOrCreateColorCorrection()
    end
    if not self._depthOfField then
        self._depthOfField = findOrCreateDepthOfField()
    end
end

function UnderwaterLighting:Add()
    if self._enabled then
        return
    end

    self:_ensureEffects()

    if self._colorCorrection then
        self._colorCorrection.Enabled = true
    end
    if self._depthOfField then
        self._depthOfField.Enabled = true
    end

    self._enabled = true
end

function UnderwaterLighting:Remove()
    if not self._enabled then
        return
    end

    if self._colorCorrection then
        self._colorCorrection.Enabled = false
    end
    if self._depthOfField then
        self._depthOfField.Enabled = false
    end

    self._enabled = false
end

function UnderwaterLighting:Destroy()
    if self._colorCorrection then
        self._colorCorrection:Destroy()
        self._colorCorrection = nil
    end
    if self._depthOfField then
        self._depthOfField:Destroy()
        self._depthOfField = nil
    end
    self._enabled = false
end

return setmetatable({
    _enabled = false,
    _colorCorrection = nil,
    _depthOfField = nil,
}, UnderwaterLighting)
