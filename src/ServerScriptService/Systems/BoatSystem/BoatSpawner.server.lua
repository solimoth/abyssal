-- BoatSpawner.lua (FIXED - Performance optimizations)
-- Place in: ServerScriptService/Systems/BoatSystem/BoatSpawner.lua

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local BoatConfig = require(ReplicatedStorage.Modules.BoatConfig)
local BoatManager = require(script.Parent.BoatManager)

-- Constants
local WATER_LEVEL = 908.935
local SPAWN_ZONE_COLOR = Color3.fromRGB(0, 162, 255)
local SPAWN_ZONE_TRANSPARENCY = 0.8

-- Cache for dock spawn zones
local DockSpawnZones = {}
local DockPrompts = {}

-- Function to visualize spawn zone (optional, for debugging)
local function VisualizeSpawnZone(zone, enabled)
	if enabled then
		zone.Transparency = SPAWN_ZONE_TRANSPARENCY
		zone.Material = Enum.Material.ForceField
		zone.BrickColor = BrickColor.new("Cyan")
	else
		zone.Transparency = 1
	end
end

-- Function to get a random position within the spawn zone
local function GetRandomSpawnPosition(spawnZone)
	local zoneSize = spawnZone.Size
	local zoneCFrame = spawnZone.CFrame

	-- Generate random offsets within the zone (avoiding edges)
	local edgeBuffer = 2
	local randomX = math.random() * (zoneSize.X - edgeBuffer * 2) - (zoneSize.X / 2 - edgeBuffer)
	local randomZ = math.random() * (zoneSize.Z - edgeBuffer * 2) - (zoneSize.Z / 2 - edgeBuffer)

	local localOffset = Vector3.new(randomX, 0, randomZ)
	local worldPosition = zoneCFrame:PointToWorldSpace(localOffset)

	return Vector3.new(worldPosition.X, WATER_LEVEL + 2, worldPosition.Z)
end

-- Optimized position checking using OverlapParams
local function IsPositionClear(position, checkRadius)
	checkRadius = checkRadius or 15

	-- Use OverlapParams for better performance
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Blacklist
	overlapParams.FilterDescendantsInstances = {}

	local parts = workspace:GetPartBoundsInBox(
		CFrame.new(position),
		Vector3.new(checkRadius * 2, 10, checkRadius * 2),
		overlapParams
	)

	for _, part in pairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model:GetAttribute("OwnerId") then
			-- This is a boat, position is not clear
			return false
		end
	end

	return true
end

-- Function to find a clear spawn position within the zone
local function FindClearSpawnPosition(spawnZone, maxAttempts)
	maxAttempts = maxAttempts or 10

	for i = 1, maxAttempts do
		local position = GetRandomSpawnPosition(spawnZone)
		if IsPositionClear(position) then
			return position
		end
	end

	return GetRandomSpawnPosition(spawnZone)
end

-- Function to handle any dock with a spawn button
local function SetupDockSpawnButton(dock)
	-- Avoid re-initializing
	if DockPrompts[dock] then return end

	local spawnButton = dock:FindFirstChild("SpawnButton")
	if not spawnButton then return end

	local spawnZone = dock:FindFirstChild("BoatSpawnZone")

	-- Cache the spawn zone
	if spawnZone and spawnZone:IsA("BasePart") then
		DockSpawnZones[dock] = spawnZone
		spawnZone.CanCollide = false
		spawnZone.Anchored = true
		VisualizeSpawnZone(spawnZone, false)
	else
		warn("Dock '" .. dock.Name .. "' is missing BoatSpawnZone part!")
	end

	local prompt = spawnButton:FindFirstChild("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Spawn Boat"
		prompt.ObjectText = "Boat Dock"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = spawnButton
	end

	-- Cache the prompt
	DockPrompts[dock] = prompt

	-- Connect the prompt
	local triggerConnection
	triggerConnection = prompt.Triggered:Connect(function(player)
		OnDockPromptTriggered(player, dock, spawnButton)
	end)

	-- Update prompt text when shown
	local shownConnection
	shownConnection = prompt.PromptShown:Connect(function(playerShowing)
		local hasBoat = BoatManager.GetPlayerBoat(playerShowing) ~= nil

		if hasBoat then
			prompt.ActionText = "Boat Active"
			prompt.ObjectText = "Your boat is spawned"
		else
			local boatTypeToShow = "Boat"

			-- Check for dock-specific type first
			local dockBoatType = dock:GetAttribute("BoatType")
			if dockBoatType and dockBoatType ~= "" then
				local config = BoatConfig.GetBoatData(dockBoatType)
				boatTypeToShow = config and config.DisplayName or dockBoatType
			else
				-- Get player's selected type
				local getBoatTypeRemote = ReplicatedStorage.Remotes.BoatRemotes:FindFirstChild("GetSelectedBoatType")
				if getBoatTypeRemote then
					local success, selectedType = pcall(function()
						return getBoatTypeRemote:InvokeClient(playerShowing)
					end)

					if success and selectedType then
						local config = BoatConfig.GetBoatData(selectedType)
						boatTypeToShow = config and config.DisplayName or selectedType
					end
				end
			end

			prompt.ActionText = "Spawn " .. boatTypeToShow
			prompt.ObjectText = "Boat Dock"
		end
	end)

	-- Store connections for cleanup
	dock:SetAttribute("HasSpawnSystem", true)

	-- Cleanup when dock is destroyed
	dock.AncestryChanged:Connect(function()
		if not dock.Parent then
			DockPrompts[dock] = nil
			DockSpawnZones[dock] = nil
			if triggerConnection then
				triggerConnection:Disconnect()
			end
			if shownConnection then
				shownConnection:Disconnect()
			end
		end
	end)
end

-- Handle dock interaction
function OnDockPromptTriggered(player, dock, spawnButton)
	local prompt = DockPrompts[dock] or spawnButton:FindFirstChild("ProximityPrompt")
	if not prompt then return end

	-- Check if player already has a boat
	local existingBoat = BoatManager.GetPlayerBoat(player)

	if existingBoat then
		prompt.ActionText = "Boat Already Active"
		prompt.ObjectText = "Return to your boat"

		-- Change it back after a moment
		task.wait(2)
		if prompt and prompt.Parent then
			prompt.ActionText = "Boat Active"
			prompt.ObjectText = "Your boat is spawned"
		end
	else
		local spawnPosition
		local spawnZone = DockSpawnZones[dock] or dock:FindFirstChild("BoatSpawnZone")

		if spawnZone and spawnZone:IsA("BasePart") then
			spawnPosition = FindClearSpawnPosition(spawnZone)

			-- Face the boat away from the dock
			local directionFromButton = (spawnPosition - spawnButton.Position).Unit
			directionFromButton = Vector3.new(directionFromButton.X, 0, directionFromButton.Z).Unit

			local spawnCFrame = CFrame.lookAt(spawnPosition, spawnPosition + directionFromButton)
		else
			-- Fallback: Use the old offset system if no spawn zone exists
			local spawnOffset = dock:GetAttribute("SpawnOffset") or Vector3.new(0, 0, -30)
			spawnPosition = spawnButton.Position + spawnOffset
			spawnPosition = Vector3.new(spawnPosition.X, WATER_LEVEL + 2, spawnPosition.Z)
		end

		-- Get the selected boat type from the client
		local boatType = "StarterRaft"

		-- Try to get player's selected boat type
		local getBoatTypeRemote = ReplicatedStorage.Remotes.BoatRemotes:FindFirstChild("GetSelectedBoatType")
		if getBoatTypeRemote then
			local success, selectedType = pcall(function()
				return getBoatTypeRemote:InvokeClient(player)
			end)

			if success and selectedType then
				local config = BoatConfig.GetBoatData(selectedType)
				if config then
					boatType = selectedType
				end
			end
		end

		-- Override with dock-specific boat type if set
		local dockBoatType = dock:GetAttribute("BoatType")
		if dockBoatType and dockBoatType ~= "" then
			local config = BoatConfig.GetBoatData(dockBoatType)
			if config then
				boatType = dockBoatType
			end
		end

		-- Spawn the boat
		BoatManager.SpawnBoat(player, boatType, spawnPosition)

		-- Update prompt text
		prompt.ActionText = "Boat Active"
		prompt.ObjectText = "Your boat is spawned"
	end
end

-- Find all existing docks in workspace (optimized)
local function InitializeExistingDocks()
	-- Use CollectionService for better performance
	for _, obj in pairs(workspace:GetDescendants()) do
		if obj:IsA("Model") and not obj:GetAttribute("HasSpawnSystem") then
			-- Check if it has a spawn button in a performant way
			local spawnButton = obj:FindFirstChild("SpawnButton", false)
			if spawnButton then
				SetupDockSpawnButton(obj)
			end
		end
	end
end

-- Listen for new docks being added (optimized)
local dockCheckQueue = {}
local checkingQueue = false

local function ProcessDockQueue()
	if checkingQueue then return end
	checkingQueue = true

	task.spawn(function()
		task.wait(0.1) -- Small delay for batch processing

		for dock, _ in pairs(dockCheckQueue) do
			if dock.Parent and not dock:GetAttribute("HasSpawnSystem") then
				SetupDockSpawnButton(dock)
			end
		end

		dockCheckQueue = {}
		checkingQueue = false
	end)
end

workspace.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("Model") and descendant:FindFirstChild("SpawnButton", false) then
		dockCheckQueue[descendant] = true
		ProcessDockQueue()
	end
end)

-- Initialize on start
InitializeExistingDocks()

-- Export the water level for other scripts to use
_G.WATER_LEVEL = WATER_LEVEL

print("Boat Spawner system initialized (optimized)")
print("Docks should have: SpawnButton part and BoatSpawnZone part")