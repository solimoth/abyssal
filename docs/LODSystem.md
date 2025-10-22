# Dynamic Level of Detail System

The Abyssal project now ships with a dynamic level of detail (LOD) stack that
lets you stream lightweight placeholders from the server while the client swaps
in richer presentation when it is actually needed. The system is split into two
pieces:

- [`ReplicatedStorage/Modules/LODService`](../src/ReplicatedStorage/Modules/LODService.lua)
  performs the distance checks, activates the correct level and keeps the active
  asset aligned with its anchor.
- [`StarterPlayer/StarterPlayerScripts/LODManager.client`](../src/StarterPlayer/StarterPlayerScripts/LODManager.client.lua)
  is a plug-and-play controller that automatically registers any model tagged as
  an `LODGroup` and feeds the service with cloned geometry.

Because the heavy detail is cloned locally on the client the server only needs
to replicate a very small anchor model for each world object. This keeps CPU,
GPU, memory, and network costs down in the open world.

## Authoring a LOD group

1. **Create the anchor model**
   - Build a lightweight `Model` that marks the object's position. It can be as
     simple as a single invisible part or attachment; keep the footprint tiny so
     replication stays cheap.
   - Tag the model with `CollectionService` using the tag name `LODGroup`.
   - (Optional) Set the `LODAnchor` attribute to the name of a descendant
     `BasePart`, `Attachment`, or `Model` if you need to control the pivot used
     for distance checks and placement. When absent the manager uses
     `Model:GetPivot()`.

2. **Add a `LODLevels` folder**
   - Parent a `Folder` named `LODLevels` inside the tagged model.
   - Place one child `Model` or `BasePart` per level of detail inside this
     folder. These act as templates; they will be cloned on the client so make
     sure `Archivable` is enabled.
   - Give each template a `Number` attribute called `LODMaxDistance` (or
     `MaxDistance`). The number is the maximum camera distance (in studs) where
     that level remains active. The last level can omit this attribute to make
     it the fallback for any distance beyond the previous tiers.
   - (Optional) Add `LODMinDistance` (or `MinDistance`) to delay activation
     until the camera has moved far enough away, which is useful for making sure
     impostors do not appear while the player is still on top of the object.

3. **Optional group attributes**
   - `LODHysteresis` *(Number)* – distance buffer (default `25`) added around the
     switch thresholds to prevent the system from constantly swapping levels
     when the camera hovers around a boundary.
   - `LODUnloadDistance` *(Number)* – when the camera is farther than this value
     all levels are culled entirely.
   - `LODActiveParent` *(String)* – name of a descendant of the group or a
     top-level instance in `Workspace` that should hold the active clones. If
     omitted, a local folder is created in `Workspace`.
   - `LODContainerName` *(String)* – overrides the generated folder name that
     stores the active level.
   - `LODDestroyInstances` *(Boolean)* – set to `false` if you want to reuse the
     cloned instances after unregistering instead of destroying them.

Once those pieces are in place the client will automatically pick up the model
as soon as the tag is present. The manager clones each template once, keeps the
clones out of the world until the service says they should be visible, and then
applies the correct pivot offset so the clone lines up with the anchor model.

## How it works

1. `LODManager.client` watches `CollectionService` for the `LODGroup` tag.
2. When a tagged model is found it:
   - Resolves the pivot function (either the anchor specified by `LODAnchor` or
     the model's pivot).
   - Clones every child inside `LODLevels`, recording the relative offset from
     the anchor so the clone can be placed correctly later.
   - Registers the group with the shared `LODService` instance.
3. `LODService` runs on `Heartbeat`, slices work across frames, and for each
   group:
   - Measures the camera distance to the resolved pivot.
   - Picks the most appropriate LOD level while applying hysteresis and optional
     culling distances.
   - Activates the level (by parenting the clone into the runtime container) and
     calls `PivotTo`/`CFrame` so the clone matches the anchor.
   - Keeps the clone aligned in subsequent updates so moving objects (such as
     ships) drag their visuals along.

When the model leaves the workspace or the tag is removed the manager cleans up
all connections and destroys the clones that were created for that group.

## Manual control

You can integrate the service directly if you need specialised behaviour. The
service exposes `Register`, `Unregister`, and configuration setters for the
update cadence. A minimal manual registration looks like this:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LODService = require(ReplicatedStorage.Modules.LODService)

local service = LODService.GetDefault()
service:SetUpdateInterval(0.1)
service:Start()

local basePivot = anchorModel:GetPivot()
local high = highTemplate:Clone()
high.Parent = nil
local medium = mediumTemplate:Clone()
medium.Parent = nil

local handle = service:Register(anchorModel, {
    Levels = {
        {
            Instance = high,
            MaxDistance = 150,
            PivotOffset = basePivot:ToObjectSpace(highTemplate:GetPivot()),
        },
        {
            Instance = medium,
            MaxDistance = 400,
            PivotOffset = basePivot:ToObjectSpace(mediumTemplate:GetPivot()),
        },
    },
})
```

Call `handle:Destroy()` (or `service:Unregister(anchorModel)`) when the anchor no
longer needs to participate in LOD switching.

## Tips

- Use extremely cheap anchors—one invisible part or attachment is enough—to
  keep replication and physics costs to a minimum. All of the detailed visuals
  should live inside `LODLevels`.
- The last level can be a billboard, mesh impostor, or even an empty model. When
  combined with `LODUnloadDistance` you can completely cull distant objects.
- Adjust `LODService:SetMaxUpdatesPerStep` if you have thousands of groups.
  Lower values smooth CPU usage, higher values make switches more responsive.
- Because clones live on the client you can place any local-only effects (particle
  emitters, surface GUIs, etc.) inside your high-detail templates without
  involving the server.
