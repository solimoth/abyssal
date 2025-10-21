# Lighting System Overview

This lighting pipeline allows you to define lighting presets in **ReplicatedStorage/LightingConfigurations** and apply them dynamically per-player. Presets are activated automatically when players enter parts inside `Workspace/Zones`, and you can also control them manually from server-side systems through the `LightingService` module.

## Creating lighting configurations

1. In Studio, create a folder under `ReplicatedStorage > LightingConfigurations` named after the preset you want to use (for example, `Normal`, `OceanExplore`, `WaterLayer1`, ...).
2. Configure any Lighting service properties you would like this preset to control by adding attributes to the folder. Attribute names must match the Lighting property names (e.g. `Ambient`, `Brightness`, `FogColor`, `FogEnd`, `OutdoorAmbient`, ...). Properties left unset will keep the current value when the preset is applied.
3. Add any post-processing instances that should be active while the preset is enabled as children of the folder. Supported instances are:
   - `Atmosphere`
   - `Sky`
   - `BloomEffect`
   - `ColorCorrectionEffect`
   - `DepthOfFieldEffect`
   - `SunRaysEffect`

   Configure these instances exactly how you want them to look; the system will tween their numeric and colour properties when switching between presets.
4. (Optional) Set the `DefaultConfiguration` attribute on the `LightingConfigurations` folder to the name of the preset that should load when the client starts. By default the system looks for a preset called `Normal`.

> Tip: Because attributes support numeric, colour, and boolean values, you can tune fog, brightness, and ambient colours directly from Studio without editing scripts.

## Marking lighting zones

1. Create (or locate) a folder named `Zones` under `Workspace`. The server watches this folder automatically.
2. Add parts inside `Workspace/Zones` that represent the regions you want to influence. Each part's name should match a preset folder under `ReplicatedStorage/LightingConfigurations`. Resize them to cover the desired volume and set `CanCollide`/`Transparency` as needed.
3. (Optional) Override behaviour by setting attributes on the part:
   - `LightingConfiguration` (string): Use this if you want the part to activate a different preset name than the part's own name.
   - `LightingPriority` (number): Determines which zone wins when players overlap multiple zones. Higher values take priority. Defaults to `0`.
   - `LightingTransitionTime` (number): Overrides the tween duration in seconds when entering/exiting the zone.
   - `LightingEasingStyle` / `LightingEasingDirection` (string or EnumItem): Controls the easing style/direction for the tween. Accepts names from `Enum.EasingStyle`/`Enum.EasingDirection`.
   - `LightingSourceId` (string): Optional unique identifier for the zone. This is useful if you want to reference the same zone from other scripts; if omitted a unique ID is generated automatically.

When a player touches a zone part inside the `Zones` folder, the server instructs that player to switch to the target preset. If the configuration name can't be found, the system warns once for that zone and keeps the current lighting unchanged. Exiting the zone removes its influence, falling back to the next-highest-priority source or the default preset.

## Manually controlling lighting from scripts

Require the module from `ServerScriptService/Systems/LightingService.lua`:

```lua
local LightingService = require(ServerScriptService.Systems.LightingService)
```

Available APIs:

- `LightingService:SetSource(player, sourceId, configName, options)` – push a lighting preset for a single player. `options` is a table that accepts `transitionTime`, `easingStyle`, `easingDirection`, and `priority`.
- `LightingService:ClearSource(player, sourceId)` – remove a previously assigned source for the player.
- `LightingService:ClearAll(player)` – remove all overrides for a player and fall back to the default configuration.
- `LightingService:ApplyToAll(sourceId, configName, options)` – apply a preset to every connected player under a single source ID.
- `LightingService:ClearSourceFromAll(sourceId)` – clear a global source.
- `LightingService:SetDefaultConfiguration(configName, options)` – change the default fallback preset and optional tween settings.

These helpers allow other gameplay systems (depth tracking, scripted events, weather, etc.) to request lighting changes without interfering with each other. Priorities ensure that the most important source wins, while timestamps guarantee deterministic behaviour when priorities tie.

## Client behaviour

The client script (`StarterPlayerScripts/LightingController.client.lua`) listens for remote instructions and handles the actual tweening. It:

- Reads lighting property values from the active preset's folder attributes.
- Tweens Lighting service properties and supported effects using `TweenService` for smooth transitions.
- Clones any configured effects into `Lighting` when a preset is enabled and removes them gracefully when the preset ends.

Because all work happens locally, the system is lightweight: only small remote messages are sent when the active preset changes, and the client performs the tweening.

## Troubleshooting

- **Preset not switching:** Ensure the folder name matches the configuration requested and that it resides under `ReplicatedStorage/LightingConfigurations`.
- **No default lighting:** Verify that the `DefaultConfiguration` attribute points to an existing preset (or create a preset named `Normal`).
- **Harsh transitions:** Increase `LightingTransitionTime` or adjust easing attributes on the zone, or override them via the `options` table when calling the service manually.

With these pieces in place you can build rich, depth-aware lighting that responds smoothly to player movement.
