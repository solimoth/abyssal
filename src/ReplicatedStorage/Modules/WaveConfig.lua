--!strict
-- WaveConfig.lua
-- Central configuration for the dynamic wave surface.
-- Adjust the values below to tune the behaviour and performance profile
-- of the simulated ocean surface.

local WaveConfig = {
        -- Base height of the simulated ocean surface in world space.
        SeaLevel = 908.935,

        -- Dimensions (studs) of a single tile in the tiled ocean surface grid.
        TileSize = 256,

        -- Number of quads along one axis of a tile. The resulting vertex count is
        -- (Resolution + 1)^2. Lower values are cheaper to update, higher values
        -- give smoother waves.
        Resolution = 16,

        -- Radius, in tiles, to maintain around the primary simulation focus point.
        -- The surface will feel effectively infinite while only keeping a handful
        -- of tiles active.
        TileRadius = 2,

        -- Wave profile parameters. Multiple layered waves provide a convincing
        -- ocean surface while staying light-weight.
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

        -- Optional extra perturbation to create sharper crests without needing a
        -- denser mesh.
        Choppiness = 0.35,

        -- Minimum time (seconds) between full geometry uploads for each tile. We
        -- update vertex heights every frame but only push the triangles to the
        -- physics engine at this rate to stay performant.
        UploadInterval = 0.1,

        -- How quickly the tiled surface recenters around the highest-priority
        -- focus object (ships, submarines, the camera, etc.).
        RecenterResponsiveness = 6,

        -- Optional list of CollectionService tags whose instances should be used
        -- as focus targets for the floating origin system.
        FocusTags = {
                "WaterFloat",
                "ShipHull",
        },

        -- If true the service will also follow the local player camera when no
        -- tagged focusable objects are nearby.
        FollowCamera = true,

        -- Name of the folder created inside Workspace to contain the generated
        -- wave tiles.
        ContainerName = "DynamicWaveSurface",

        -- Physical properties for the MeshParts. Ships interact with the visible
        -- geometry, so we keep the density low and enable custom physical
        -- material tuning.
        PhysicalMaterial = PhysicalProperties.new(0.4, 0.3, 0.5),
}

return WaveConfig
