--!strict
-- WaveConfig.lua
-- Central configuration for the dynamic wave surface. Physics run on the server
-- while visuals are rendered locally by StarterPlayerScripts/WaveRenderer.
-- Adjust these values to tune fidelity and performance.

local generatedWaves = {
    {
        Amplitude = 4.3,
        Wavelength = 210,
        Speed = 8.8,
        Direction = Vector2.new(0.94, 0.35),
        PhaseOffset = math.pi * 0.1,
    },
    {
        Amplitude = 2.5,
        Wavelength = 135,
        Speed = 12.6,
        Direction = Vector2.new(-0.52, 0.85),
        PhaseOffset = math.pi * 0.6,
    },
    {
        Amplitude = 1.2,
        Wavelength = 78,
        Speed = 17.8,
        Direction = Vector2.new(0.18, -0.98),
        PhaseOffset = math.pi * 1.2,
    },
    {
        Amplitude = 0.7,
        Wavelength = 44,
        Speed = 23,
        Direction = Vector2.new(-0.88, -0.47),
        PhaseOffset = math.pi * 1.75,
    },
}

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

    -- Controls how quickly vertex positions ease towards their latest target
    -- sample. Higher values reduce visual jitter when frame times fluctuate.
    VertexSmoothingSpeed = 14,

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
