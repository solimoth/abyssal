--!strict
-- WaveConfig.lua
-- Central configuration for the dynamic wave surface. Physics run on the server
-- while visuals are rendered locally by StarterPlayerScripts/WaveRenderer.
-- Adjust these values to tune fidelity and performance.

local random = Random.new(21051990)
local tau = 2 * math.pi
local atan = math.atan

local function nextPhase()
    return random:NextNumber(0, tau)
end

local function randomDirection()
    local angle = random:NextNumber(0, tau)
    return Vector2.new(math.cos(angle), math.sin(angle))
end

local function jitterValue(baseValue: number, variance: number?): number
    variance = math.max(variance or 0, 0)
    if variance <= 0 then
        return baseValue
    end

    local lower = baseValue * (1 - variance)
    local upper = baseValue * (1 + variance)

    local minValue = math.max(1e-3, math.min(lower, upper))
    local maxValue = math.max(minValue, math.max(lower, upper))

    return random:NextNumber(minValue, maxValue)
end

local function jitterDirection(baseDirection: Vector2, maxAngle: number?): Vector2
    local limit = math.max(maxAngle or 0, 0)
    if limit <= 0 then
        return baseDirection.Unit
    end

    local baseAngle = atan(baseDirection.Y, baseDirection.X)
    local offset = random:NextNumber(-limit, limit)
    local angle = baseAngle + offset

    return Vector2.new(math.cos(angle), math.sin(angle))
end

local function randomWave(amplitudeMin: number, amplitudeMax: number, wavelengthMin: number, wavelengthMax: number, speedMin: number, speedMax: number)
    return {
        Amplitude = random:NextNumber(amplitudeMin, amplitudeMax),
        Wavelength = random:NextNumber(wavelengthMin, wavelengthMax),
        Speed = random:NextNumber(speedMin, speedMax),
        Direction = randomDirection(),
        PhaseOffset = nextPhase(),
    }
end

local function primaryWave(spec: {
    Amplitude: number,
    AmplitudeVariance: number?,
    Wavelength: number,
    WavelengthVariance: number?,
    Speed: number,
    SpeedVariance: number?,
    Direction: Vector2,
    DirectionJitter: number?,
})
    return {
        Amplitude = jitterValue(spec.Amplitude, spec.AmplitudeVariance),
        Wavelength = jitterValue(spec.Wavelength, spec.WavelengthVariance),
        Speed = jitterValue(spec.Speed, spec.SpeedVariance),
        Direction = jitterDirection(spec.Direction, spec.DirectionJitter),
        PhaseOffset = nextPhase(),
    }
end

local primaryWaveSpecs = {
    {
        Amplitude = 5.1,
        AmplitudeVariance = 0.18,
        Wavelength = 185,
        WavelengthVariance = 0.16,
        Speed = 9,
        SpeedVariance = 0.12,
        Direction = Vector2.new(1, 0.2),
        DirectionJitter = math.rad(20),
        Count = 2,
    },
    {
        Amplitude = 2.6,
        AmplitudeVariance = 0.22,
        Wavelength = 110,
        WavelengthVariance = 0.2,
        Speed = 13,
        SpeedVariance = 0.16,
        Direction = Vector2.new(0.35, 0.8),
        DirectionJitter = math.rad(26),
        Count = 1,
    },
    {
        Amplitude = 1.3,
        AmplitudeVariance = 0.28,
        Wavelength = 58,
        WavelengthVariance = 0.26,
        Speed = 20,
        SpeedVariance = 0.2,
        Direction = Vector2.new(-0.5, 0.15),
        DirectionJitter = math.rad(30),
        Count = 1,
    },
}

local generatedWaves = {}

for _, spec in ipairs(primaryWaveSpecs) do
    local count = math.max(spec.Count or 1, 1)
    for _ = 1, count do
        generatedWaves[#generatedWaves + 1] = primaryWave(spec)
    end
end

for _ = 1, 2 do
    generatedWaves[#generatedWaves + 1] = randomWave(1.5, 2.8, 95, 145, 11, 17)
end

for _ = 1, 2 do
    generatedWaves[#generatedWaves + 1] = randomWave(0.4, 1.1, 30, 55, 18, 28)
end

local WaveConfig = {
    -- Base height (world Y) of the simulated water surface.
    SeaLevel = 908.935,

    -- Global multiplier that scales every wave layer. Keep this at 1 for calm seas
    -- and drive it via WaveField:SetTargetIntensity for weather events.
    DefaultIntensity = 0.85,

    -- How quickly the intensity reacts to changes triggered by gameplay systems.
    -- Higher values snap immediately, lower values give smooth transitions.
    IntensityResponsiveness = 2.5,

    -- Overall simulation speed multiplier. Lower values make waves roll slowly.
    TimeScale = 0.4,

    -- Number of vertices along each axis of the editable mesh tile. Higher values
    -- give smoother waves but cost more to update every frame.
    GridWidth = 100,
    GridHeight = 100,

    -- Distance between vertices in studs. Controls the physical size of each
    -- tile produced by the system.
    GridSpacing = 20,

    -- Number of extra tiles to spawn in every direction around the focus point.
    -- Leave at 0 for a single sliding tile (best performance). Increase to 1 for
    -- a 3x3 grid if you need a wider playable area around multiple ships.
    TileRadius = 0,

    -- How frequently (in seconds) to bake the editable mesh back onto the
    -- replicated MeshPart. Lower values keep visuals perfectly in sync with the
    -- editable state but increase workload. 1/20 (~50 ms) is a good balance.
    ReapplyInterval = 1 / 20,

    -- Optional horizontal displacement multiplier. Use values between 0 and 1 to
    -- introduce a bit of crest "choppiness" without destabilising the mesh.
    Choppiness = 0.35,

    -- Rate at which the tiled surface recentres towards the active focus point.
    RecenterResponsiveness = 6,

    -- Optional land-zone attenuation. Place invisible parts named "LandZone"
    -- (or adjust the name below) around islands to calm the surrounding water.
    -- Waves inside the zone fade towards LandZoneAttenuation and blend back to
    -- full strength over LandZoneFadeDistance studs.
    LandZoneName = "LandZone",
    LandZoneAttenuation = 0.35,
    LandZoneFadeDistance = 80,

    -- CollectionService tags used to identify high-priority focus objects such
    -- as ships, submarines, or floating debris.
    FocusTags = {
        "WaterFloat",
        "ShipHull",
    },

    -- If true the server will also follow live player characters when no tagged
    -- focus objects are nearby. This keeps the ocean centred around active crews.
    FollowPlayers = true,

    -- Folder name created in Workspace to contain the generated MeshParts.
    ContainerName = "DynamicWaveSurface",

    -- Appearance applied to the generated MeshParts. Feel free to tweak colours
    -- and material to match the rest of the world.
    Material = Enum.Material.Water,
    Color = Color3.fromRGB(30, 120, 150),
    Transparency = 0.2,
    Reflectance = 0.05,

    -- Wave profile definitions. Amplitude/Wavelength/Speed are converted to
    -- Gerstner parameters internally.
    Waves = generatedWaves,
}

return WaveConfig
