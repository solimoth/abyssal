local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PassengerMovement = {}

local ZERO_VECTOR = Vector3.new()
local MAX_RELATIVE_SPEED = 80
local VELOCITY_BLEND_ALPHA_GROUNDED = 0.35
local VELOCITY_BLEND_ALPHA_AIRBORNE = 0.95
local STANDING_TRACK_DISTANCE = 45
local STANDING_RAYCAST_DISTANCE = 8
local STANDING_RELEASE_GRACE = 0.6

local standingRaycastParams = RaycastParams.new()
standingRaycastParams.FilterType = Enum.RaycastFilterType.Include
standingRaycastParams.IgnoreWater = false

local boatStates = {}
local passengerAssignments = {}

local function clearTable(tbl)
        if not tbl then
                return
        end

        for key in pairs(tbl) do
                tbl[key] = nil
        end
end

local function releasePassenger(boat, character)
        local boatState = boatStates[boat]
        if boatState and boatState.passengers then
                boatState.passengers[character] = nil
                if not next(boatState.passengers) then
                        boatStates[boat] = nil
                end
        end

        passengerAssignments[character] = nil
end

local function getBoatState(boat)
        local state = boatStates[boat]
        if state then
                return state
        end

        state = {
                passengers = {},
                lastCFrame = nil,
                previousVelocity = ZERO_VECTOR,
                lastVelocity = ZERO_VECTOR,
                lastUpdate = os.clock(),
        }
        boatStates[boat] = state
        return state
end

local function clampRelativeVelocity(relativeVelocity)
        local magnitude = relativeVelocity.Magnitude
        if magnitude > MAX_RELATIVE_SPEED then
                return relativeVelocity.Unit * MAX_RELATIVE_SPEED
        end

        return relativeVelocity
end

local function applyPassengerVelocity(humanoidRootPart, boatVelocity, previousBoatVelocity, state, blendAlpha)
        if not humanoidRootPart then
                return
        end

        local currentVelocity = humanoidRootPart.AssemblyLinearVelocity
        local targetVelocity = currentVelocity
        local alpha = blendAlpha or VELOCITY_BLEND_ALPHA_GROUNDED

        if state and not state.initialVelocityApplied then
                targetVelocity += clampRelativeVelocity(boatVelocity)
                state.initialVelocityApplied = true
                alpha = 1
        end

        local velocityDelta = boatVelocity - previousBoatVelocity
        if velocityDelta.Magnitude > 0 then
                targetVelocity += clampRelativeVelocity(velocityDelta)
        end

        if (currentVelocity - targetVelocity).Magnitude < 0.01 then
                return
        end

        humanoidRootPart.AssemblyLinearVelocity = currentVelocity:Lerp(targetVelocity, alpha)
end

local function applyBoatDeltaToPassenger(humanoidRootPart, boatDeltaCFrame)
        if not humanoidRootPart or not boatDeltaCFrame then
                return
        end

        humanoidRootPart.CFrame = boatDeltaCFrame * humanoidRootPart.CFrame
end

local function updateBoatVelocity(boatState, referenceCFrame, deltaTime)
        if not boatState then
                return ZERO_VECTOR
        end

        local now = os.clock()
        local dt = deltaTime
        if not dt or dt <= 0 then
                dt = math.max(now - (boatState.lastUpdate or now), 1 / 120)
        end

        local lastCFrame = boatState.lastCFrame
        local previousVelocity = boatState.lastVelocity or ZERO_VECTOR
        local newVelocity = ZERO_VECTOR

        if lastCFrame then
                local displacement = referenceCFrame.Position - lastCFrame.Position
                newVelocity = displacement / math.max(dt, 1 / 240)
        end

        boatState.previousVelocity = previousVelocity
        boatState.lastVelocity = newVelocity
        boatState.lastCFrame = referenceCFrame
        boatState.lastUpdate = now

        return newVelocity
end

function PassengerMovement.Update(boat, referenceCFrame, deltaTime, processedCharacters)
        if not boat or not referenceCFrame then
                return
        end

        processedCharacters = processedCharacters or {}

        local boatState = getBoatState(boat)
        local passengers = boatState.passengers
        standingRaycastParams.FilterDescendantsInstances = { boat }

        local previousBoatCFrame = boatState.lastCFrame
        local boatVelocity = updateBoatVelocity(boatState, referenceCFrame, deltaTime)
        local previousBoatVelocity = boatState.previousVelocity or ZERO_VECTOR
        local boatDeltaCFrame
        if previousBoatCFrame then
                boatDeltaCFrame = referenceCFrame * previousBoatCFrame:Inverse()
        end
        local boatPosition = referenceCFrame.Position
        local seenCharacters = {}
        local now = os.clock()

        for _, player in ipairs(Players:GetPlayers()) do
                local character = player.Character
                if not character or processedCharacters[character] then
                        continue
                end

                local humanoid = character:FindFirstChildOfClass("Humanoid")
                if not humanoid or humanoid.Health <= 0 then
                        continue
                end

                if humanoid.Sit or humanoid.PlatformStand then
                        continue
                end

                local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
                if not humanoidRootPart then
                        continue
                end

                local distance = (humanoidRootPart.Position - boatPosition).Magnitude
                if distance > STANDING_TRACK_DISTANCE then
                        continue
                end

                local rayResult = Workspace:Raycast(
                        humanoidRootPart.Position,
                        Vector3.new(0, -STANDING_RAYCAST_DISTANCE, 0),
                        standingRaycastParams
                )

                if rayResult and rayResult.Instance and rayResult.Instance:IsDescendantOf(boat) then
                        processedCharacters[character] = true
                        seenCharacters[character] = true

                        local previousBoat = passengerAssignments[character]
                        if previousBoat and previousBoat ~= boat then
                                releasePassenger(previousBoat, character)
                        end

                        passengerAssignments[character] = boat

                        local state = passengers[character]
                        if not state then
                                state = {}
                                passengers[character] = state
                        end

                        state.lastSeen = now

                        local humanoidState = humanoid:GetState()
                        local isAirborne = humanoid.FloorMaterial == Enum.Material.Air
                                or humanoidState == Enum.HumanoidStateType.Jumping
                                or humanoidState == Enum.HumanoidStateType.Freefall
                                or humanoidState == Enum.HumanoidStateType.FallingDown

                        if boatDeltaCFrame then
                                applyBoatDeltaToPassenger(humanoidRootPart, boatDeltaCFrame)
                        end
                        applyPassengerVelocity(
                                humanoidRootPart,
                                boatVelocity,
                                previousBoatVelocity,
                                state,
                                isAirborne and VELOCITY_BLEND_ALPHA_AIRBORNE or VELOCITY_BLEND_ALPHA_GROUNDED
                        )
                end
        end

        for character, state in pairs(passengers) do
                if not character or not character.Parent then
                        releasePassenger(boat, character)
                        continue
                end

                local humanoid = character:FindFirstChildOfClass("Humanoid")
                if not humanoid or humanoid.Health <= 0 or humanoid.Sit or humanoid.PlatformStand then
                        releasePassenger(boat, character)
                        continue
                end

                local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
                if not humanoidRootPart then
                        releasePassenger(boat, character)
                        continue
                end

                if seenCharacters[character] then
                        continue
                end

                local lastSeen = state.lastSeen or 0
                if now - lastSeen <= STANDING_RELEASE_GRACE then
                        processedCharacters[character] = true

                        local humanoidState = humanoid:GetState()
                        local isAirborne = humanoidState == Enum.HumanoidStateType.Jumping
                                or humanoidState == Enum.HumanoidStateType.Freefall
                                or humanoidState == Enum.HumanoidStateType.FallingDown

                        if boatDeltaCFrame then
                                applyBoatDeltaToPassenger(humanoidRootPart, boatDeltaCFrame)
                        end

                        applyPassengerVelocity(
                                humanoidRootPart,
                                boatVelocity,
                                previousBoatVelocity,
                                state,
                                isAirborne and VELOCITY_BLEND_ALPHA_AIRBORNE or VELOCITY_BLEND_ALPHA_GROUNDED
                        )
                else
                        releasePassenger(boat, character)
                end
        end
end

function PassengerMovement.ReleaseBoat(boat)
        if not boat then
                return
        end

        local state = boatStates[boat]
        if not state then
                return
        end

        for character in pairs(state.passengers) do
                passengerAssignments[character] = nil
        end

        boatStates[boat] = nil
end

function PassengerMovement.ReleaseCharacter(character)
        if not character then
                return
        end

        local boat = passengerAssignments[character]
        if boat then
                releasePassenger(boat, character)
        end
end

function PassengerMovement.Clear()
        for boat in pairs(boatStates) do
                boatStates[boat] = nil
        end
        clearTable(passengerAssignments)
end

return PassengerMovement

