--!strict
-- WaveConfig.lua
-- Central configuration for the dynamic wave surface. Physics run on the server
-- while visuals are rendered locally by StarterPlayerScripts/WaveRenderer.
-- Adjust these values to tune fidelity and performance.

local WaveConfig = {
    -- Base height (world Y) of the simulated water surface.
    SeaLevel = 908.935,

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
    Waves = {
        {
            Amplitude = 6,
            Wavelength = 140,
            Speed = 14,
            Direction = Vector2.new(1, 0),
        },
        {
            Amplitude = 2.5,
            Wavelength = 40,
            Speed = 28,
            Direction = Vector2.new(0.4, 0.8),
        },
        {
            Amplitude = 1.25,
            Wavelength = 16,
            Speed = 50,
            Direction = Vector2.new(-0.6, 0.2),
        },
    },
}

return WaveConfig
