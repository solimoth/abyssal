local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local MAX_OXYGEN_TIME = 20 -- Seconds of air while submerged
local OXYGEN_RECOVERY_RATE = 8 -- Seconds of air recovered per second while breathing
local DROWNING_DAMAGE = 10 -- Damage dealt each damage interval once drowning
local DROWNING_DAMAGE_INTERVAL = 1 -- Seconds between drowning damage ticks
local BASE_SWIM_SPEED = 16 -- Default humanoid walk speed is reused for swimming
local MIN_SWIM_SPEED = 6 -- Minimum speed at extreme depth
local DEPTH_SLOW_FACTOR = 0.2 -- Speed lost per stud of depth

local WATER_LEVEL = WaterPhysics.GetWaterLevel()

local playerStates = {}

local BUOYANCY_FORCE_NAME = "WaterBuoyancyForce"
local BUOYANCY_ATTACHMENT_NAME = "WaterBuoyancyAttachment"
local WATER_DRAG_COEFFICIENT = 4 -- How quickly velocity bleeds off while submerged
local SWIM_FORCE_COEFFICIENT = 10 -- How aggressively characters accelerate toward their desired velocity
local SWIM_DESIRED_VELOCITY_ATTRIBUTE = "WaterSwimDesiredVelocity"

local function ensureState(player)
        local state = playerStates[player]
        if not state then
                state = {
                        oxygen = MAX_OXYGEN_TIME,
                        lastDamage = 0,
                        defaultSpeed = nil,
                        isDrowning = false,
                        nextOxygenPrint = 0,
                }
                playerStates[player] = state
        end
        return state
end

local function resetStateForCharacter(player)
        local state = ensureState(player)
        state.oxygen = MAX_OXYGEN_TIME
        state.lastDamage = 0
        state.defaultSpeed = nil
        state.isDrowning = false
        state.nextOxygenPrint = 0
end

local function isInsideShipInterior(character)
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")
        if not rootPart then
                return false
        end

        local regionSize = rootPart.Size + Vector3.new(4, 6, 4)
        local overlapParams = OverlapParams.new()
        overlapParams.FilterType = Enum.RaycastFilterType.Exclude
        overlapParams.FilterDescendantsInstances = { character }

        local parts = Workspace:GetPartBoundsInBox(rootPart.CFrame, regionSize, overlapParams)

        for _, part in ipairs(parts) do
                if part:IsA("BasePart") and part.Name == "ShipInterior" then
                        return true
                end
        end

        return false
end

local function updateBuoyancy(character, state, enabled, desiredVelocity)
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")
        if not rootPart then
                return
        end

        local attachment = rootPart:FindFirstChild(BUOYANCY_ATTACHMENT_NAME)
        local force = rootPart:FindFirstChild(BUOYANCY_FORCE_NAME)

        if not enabled then
                if force then
                        force.Force = Vector3.zero
                        force.Enabled = false
                end
                return
        end

        if not attachment then
                attachment = Instance.new("Attachment")
                attachment.Name = BUOYANCY_ATTACHMENT_NAME
                attachment.Parent = rootPart
        end

        if not force then
                force = Instance.new("VectorForce")
                force.Name = BUOYANCY_FORCE_NAME
                force.ApplyAtCenterOfMass = true
                force.RelativeTo = Enum.ActuatorRelativeTo.World
                force.Attachment0 = attachment
                force.Parent = rootPart
        end

        local mass = rootPart.AssemblyMass
        local velocity = rootPart.AssemblyLinearVelocity
        local dragForce = -velocity * WATER_DRAG_COEFFICIENT * mass

        local desired = Vector3.zero
        if desiredVelocity and typeof(desiredVelocity) == "Vector3" then
                desired = desiredVelocity
        end

        local movementForce = (desired - velocity) * SWIM_FORCE_COEFFICIENT * mass

        local gravityForce = Vector3.new(0, Workspace.Gravity * mass, 0)
        force.Force = gravityForce + dragForce + movementForce
        force.Enabled = true
end

local function updateSwimmingSpeed(humanoid, depth, state)
        if not state.defaultSpeed then
                state.defaultSpeed = humanoid.WalkSpeed
        end

        local targetSpeed = math.clamp(BASE_SWIM_SPEED - (depth * DEPTH_SLOW_FACTOR), MIN_SWIM_SPEED, BASE_SWIM_SPEED)

        if math.abs(humanoid.WalkSpeed - targetSpeed) > 0.1 then
                humanoid.WalkSpeed = targetSpeed
        end
end

local function ensureSwimming(humanoid)
        local currentState = humanoid:GetState()
        if currentState ~= Enum.HumanoidStateType.Swimming and currentState ~= Enum.HumanoidStateType.Dead then
                humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
        end
end

local function ensureNotSwimming(humanoid)
        if humanoid:GetState() == Enum.HumanoidStateType.Swimming then
                humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end
end

local function restoreSpeedIfNeeded(humanoid, state)
        if state.defaultSpeed and math.abs(humanoid.WalkSpeed - state.defaultSpeed) > 0.1 then
                humanoid.WalkSpeed = state.defaultSpeed
        end
end

local function updateOxygen(player, humanoid, headUnderwater, insideShip, deltaTime)
        local state = ensureState(player)

        if insideShip then
                if state.isDrowning then
                        print(string.format("[Drowning] %s reached safety inside a ship.", player.Name))
                end
                state.oxygen = MAX_OXYGEN_TIME
                state.isDrowning = false
                state.lastDamage = 0
                return
        end

        if headUnderwater then
                state.oxygen = math.max(0, state.oxygen - deltaTime)

                local now = tick()
                if state.oxygen <= 0 then
                        if not state.isDrowning then
                                print(string.format("[Drowning] %s is out of air!", player.Name))
                        end
                        state.isDrowning = true

                        if now - state.lastDamage >= DROWNING_DAMAGE_INTERVAL then
                                humanoid:TakeDamage(DROWNING_DAMAGE)
                                state.lastDamage = now
                                print(string.format("[Drowning] %s took %.0f damage from drowning.", player.Name, DROWNING_DAMAGE))
                        end
                else
                        if now >= state.nextOxygenPrint then
                                print(string.format("[Drowning] %s oxygen remaining: %.1fs", player.Name, state.oxygen))
                                state.nextOxygenPrint = now + 2
                        end
                end
        else
                local wasDrowning = state.isDrowning
                state.isDrowning = false
                state.lastDamage = 0
                state.oxygen = math.min(MAX_OXYGEN_TIME, state.oxygen + (OXYGEN_RECOVERY_RATE * deltaTime))

                if wasDrowning then
                        print(string.format("[Drowning] %s is breathing again.", player.Name))
                end
        end
end

local function processCharacter(player, deltaTime)
        local character = player.Character
        if not character then
                return
        end

        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local rootPart = character:FindFirstChild("HumanoidRootPart")
        local head = character:FindFirstChild("Head")

        if not humanoid or not rootPart or not head then
                return
        end

        local state = ensureState(player)
        if not state.defaultSpeed then
                state.defaultSpeed = humanoid.WalkSpeed
        end

        local insideShip = isInsideShipInterior(character)
        local rootUnderwater = WaterPhysics.IsUnderwater(rootPart.Position)
        local headUnderwater = WaterPhysics.IsUnderwater(head.Position)

        local shouldSwim = rootUnderwater and not insideShip

        if shouldSwim then
                ensureSwimming(humanoid)
        else
                ensureNotSwimming(humanoid)
        end

        local desiredVelocity = rootPart:GetAttribute(SWIM_DESIRED_VELOCITY_ATTRIBUTE)
        if not shouldSwim then
                desiredVelocity = Vector3.zero
        end

        updateBuoyancy(character, state, shouldSwim, desiredVelocity)

        if humanoid:GetState() == Enum.HumanoidStateType.Swimming and rootUnderwater then
                local depth = math.max(0, WATER_LEVEL - rootPart.Position.Y)
                updateSwimmingSpeed(humanoid, depth, state)
        else
                restoreSpeedIfNeeded(humanoid, state)
        end

        updateOxygen(player, humanoid, headUnderwater and not insideShip, insideShip, deltaTime)
end

Players.PlayerAdded:Connect(function(player)
        ensureState(player)

        player.CharacterAdded:Connect(function()
                resetStateForCharacter(player)
        end)

        player.CharacterRemoving:Connect(function()
                resetStateForCharacter(player)
        end)
end)

Players.PlayerRemoving:Connect(function(player)
        playerStates[player] = nil
end)

local lastUpdate = tick()

RunService.Heartbeat:Connect(function()
        local now = tick()
        local deltaTime = now - lastUpdate
        lastUpdate = now

        for _, player in ipairs(Players:GetPlayers()) do
                processCharacter(player, deltaTime)
        end
end)

