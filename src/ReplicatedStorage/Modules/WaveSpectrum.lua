--!strict
-- WaveSpectrum.lua
-- Utility helpers for generating varied wave sets for the dynamic ocean.
-- Produces Gerstner-compatible wave descriptors with randomized parameters so
-- the surface feels less repetitive while remaining deterministic via a seed.

local Workspace = game:GetService("Workspace")

local WaveSpectrum = {}

export type NumberRange = number | { number, number }
export type GroupSpec = {
    Count: number?,
    Wavelength: NumberRange?,
    Amplitude: NumberRange?,
    AmplitudeRatio: NumberRange?,
    Speed: NumberRange?,
    Steepness: NumberRange?,
    Phase: NumberRange?,
    PhaseOffset: NumberRange?,
    DirectionalBias: Vector2?,
    DirectionalSpread: number?,
}

export type SpectrumConfig = {
    Seed: number?,
    Groups: { GroupSpec }?,
    DirectionalBias: Vector2?,
    DirectionalSpread: number?,
    PhaseRange: NumberRange?,
}

local pi = math.pi
local tau = 2 * pi
local atan2 = math.atan2
local cos = math.cos
local sin = math.sin
local clamp = math.clamp
local abs = math.abs

local function resolveRange(range: NumberRange?, fallback: number): (number, number)
    local rangeType = typeof(range)
    if rangeType == "table" then
        local min = tonumber((range :: { any })[1]) or fallback
        local max = tonumber((range :: { any })[2]) or min
        if min > max then
            min, max = max, min
        end
        return min, max
    elseif rangeType == "number" then
        local value = range :: number
        return value, value
    end

    return fallback, fallback
end

local function sampleNumber(rng: Random, range: NumberRange?, fallback: number): number
    local min, max = resolveRange(range, fallback)
    if max <= min then
        return min
    end
    return rng:NextNumber(min, max)
end

local function samplePhase(rng: Random, range: NumberRange?): number
    local min, max = resolveRange(range, 0)
    if max <= min then
        return min
    end
    return rng:NextNumber(min, max)
end

local function sampleDirection(rng: Random, bias: Vector2?, spread: number?): Vector2
    local effectiveSpread = clamp(spread or 1, 0, 1)

    if effectiveSpread <= 1e-3 then
        if bias and bias.Magnitude > 1e-3 then
            return bias.Unit
        end
        return Vector2.new(1, 0)
    end

    local angle: number
    if effectiveSpread >= 0.999 then
        angle = rng:NextNumber(0, tau)
    else
        local baseAngle: number
        if bias and bias.Magnitude > 1e-3 then
            baseAngle = atan2(bias.Y, bias.X)
        else
            baseAngle = rng:NextNumber(0, tau)
        end

        local maxDeviation = pi * effectiveSpread
        angle = baseAngle + rng:NextNumber(-maxDeviation, maxDeviation)
    end

    return Vector2.new(cos(angle), sin(angle))
end

local function sampleAmplitude(rng: Random, group: GroupSpec, wavelength: number, fallback: number): number
    if group.Amplitude ~= nil then
        local amplitude = sampleNumber(rng, group.Amplitude, fallback)
        return math.max(0, amplitude)
    end

    local minRatio, maxRatio = resolveRange(group.AmplitudeRatio, 0)
    if maxRatio <= minRatio then
        return math.max(0, wavelength * minRatio)
    end

    local ratio = rng:NextNumber(minRatio, maxRatio)
    return math.max(0, wavelength * ratio)
end

local function defaultSpeedFor(wavelength: number): number
    local g = abs(Workspace.Gravity)
    if g <= 1e-3 then
        return 0
    end
    return math.sqrt(g * wavelength / tau)
end

function WaveSpectrum.generate(config: SpectrumConfig?): { [number]: { [string]: any } }
    local options = config or {}
    local groups = options.Groups or {}
    local seed = options.Seed or tick()
    local rng = Random.new(seed)

    local waves = {}
    local phaseRange = options.PhaseRange or { 0, tau }
    local defaultBias = options.DirectionalBias
    local defaultSpread = options.DirectionalSpread or 1

    for _, group in ipairs(groups) do
        local count = math.max(0, math.floor(group.Count or 0))
        if count <= 0 then
            continue
        end

        local groupBias = group.DirectionalBias or defaultBias
        local groupSpread = group.DirectionalSpread or defaultSpread
        local wavelengthRange = group.Wavelength or { 64, 96 }

        for _ = 1, count do
            local wavelength = math.max(1, sampleNumber(rng, wavelengthRange, 64))
            local amplitude = sampleAmplitude(rng, group, wavelength, wavelength * 0.02)
            local speed: number? = nil

            if group.Speed ~= nil then
                speed = sampleNumber(rng, group.Speed, defaultSpeedFor(wavelength))
            end

            local steepness: number? = nil
            if group.Steepness ~= nil then
                steepness = sampleNumber(rng, group.Steepness, 0.8)
            end

            local direction = sampleDirection(rng, groupBias, groupSpread)
            local phase = samplePhase(rng, group.Phase or group.PhaseOffset or phaseRange)

            waves[#waves + 1] = {
                Wavelength = wavelength,
                Amplitude = amplitude,
                Speed = speed,
                Steepness = steepness,
                Direction = direction,
                PhaseOffset = phase,
            }
        end
    end

    return waves
end

return WaveSpectrum
