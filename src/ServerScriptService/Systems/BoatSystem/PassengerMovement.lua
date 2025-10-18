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
local STANDING_ORIENTATION_LERP_ALPHA = 0.35

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

local function applyPassengerVelocity(humanoidRootPart, boatVelocity, state, blendAlpha)
        if not humanoidRootPart then
                return
        end

        local relativeVelocity = state.relativeVelocity or ZERO_VECTOR
        local targetVelocity = boatVelocity + relativeVelocity
        local currentVelocity = humanoidRootPart.AssemblyLinearVelocity

        if (currentVelocity - targetVelocity).Magnitude < 0.01 then
                return
        end

        humanoidRootPart.AssemblyLinearVelocity = currentVelocity:Lerp(
                targetVelocity,
                blendAlpha or VELOCITY_BLEND_ALPHA_GROUNDED
        )
        state.relativeVelocity = clampRelativeVelocity(humanoidRootPart.AssemblyLinearVelocity - boatVelocity)
end

local function updateGroundedPassengerTransform(humanoidRootPart, previousBoatCFrame, referenceCFrame, state)
        if not humanoidRootPart or not referenceCFrame then
                return
        end

        if not previousBoatCFrame then
                state.lastRelativePosition = referenceCFrame:PointToObjectSpace(humanoidRootPart.Position)
                return
        end

        local relativePosition = previousBoatCFrame:PointToObjectSpace(humanoidRootPart.Position)
        state.lastRelativePosition = relativePosition

        local targetPosition = referenceCFrame:PointToWorldSpace(relativePosition)
        local delta = targetPosition - humanoidRootPart.Position

        if delta.Magnitude > 1e-4 then
                humanoidRootPart.CFrame = humanoidRootPart.CFrame + delta
        end
end

local function moveAirbornePassengerWithBoat(humanoidRootPart, previousBoatCFrame, referenceCFrame, state)
        if not humanoidRootPart or not referenceCFrame then
                return
        end

        local relativePosition = state.lastRelativePosition
        if not relativePosition then
                return
        end

        if not previousBoatCFrame then
                return
        end

        local previousPosition = previousBoatCFrame:PointToWorldSpace(relativePosition)
        local targetPosition = referenceCFrame:PointToWorldSpace(relativePosition)
        local delta = targetPosition - previousPosition

        if delta.Magnitude > 1e-4 then
                humanoidRootPart.CFrame = humanoidRootPart.CFrame + delta
        end
end

local function alignCharacterOrientationWithBoat(character, referenceCFrame, state)
        if not character or not referenceCFrame then
                return
        end

        local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
        if not humanoidRootPart then
                return
        end

        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then
                return
        end

        if humanoid.FloorMaterial == Enum.Material.Air then
                return
        end

        local humanoidState = humanoid:GetState()
        if humanoidState == Enum.HumanoidStateType.Jumping
                or humanoidState == Enum.HumanoidStateType.Freefall
                or humanoidState == Enum.HumanoidStateType.FallingDown then
                return
        end

        local boatUp = referenceCFrame.UpVector
        if state then
                state.lastUpVector = boatUp
        end

        local currentCFrame = humanoidRootPart.CFrame
        local currentPosition = currentCFrame.Position
        local currentLook = currentCFrame.LookVector
        local projectedLook = currentLook - boatUp * currentLook:Dot(boatUp)

        if projectedLook.Magnitude < 1e-3 then
                if state and state.lastProjectedLook and state.lastProjectedLook.Magnitude > 1e-3 then
                        projectedLook = state.lastProjectedLook
                else
                        local fallback = referenceCFrame.LookVector - boatUp * referenceCFrame.LookVector:Dot(boatUp)
                        if fallback.Magnitude > 1e-3 then
                                projectedLook = fallback
                        else
                                projectedLook = Vector3.new(0, 0, -1)
                        end
                end
        end

        projectedLook = projectedLook.Unit

        local targetCFrame = CFrame.lookAt(currentPosition, currentPosition + projectedLook, boatUp)
        if state then
                state.lastProjectedLook = projectedLook
        end

        local currentUp = currentCFrame.UpVector
        if currentLook:Dot(targetCFrame.LookVector) > 0.999 and currentUp:Dot(targetCFrame.UpVector) > 0.999 then
                return
        end

        local blendAlpha = STANDING_ORIENTATION_LERP_ALPHA
        if state and state.customBlend then
                blendAlpha = state.customBlend
        end

        humanoidRootPart.CFrame = currentCFrame:Lerp(targetCFrame, blendAlpha)
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
        if lastCFrame then
                local displacement = referenceCFrame.Position - lastCFrame.Position
                boatState.lastVelocity = displacement / math.max(dt, 1 / 240)
        else
                boatState.lastVelocity = ZERO_VECTOR
        end

        boatState.lastCFrame = referenceCFrame
        boatState.lastUpdate = now

        return boatState.lastVelocity
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

                        if not state.relativeVelocity then
                                state.relativeVelocity = ZERO_VECTOR
                        else
                                state.relativeVelocity = clampRelativeVelocity(
                                        humanoidRootPart.AssemblyLinearVelocity - boatVelocity
                                )
                        end

                        if not isAirborne then
                                updateGroundedPassengerTransform(
                                        humanoidRootPart,
                                        previousBoatCFrame,
                                        referenceCFrame,
                                        state
                                )
                        end

                        alignCharacterOrientationWithBoat(character, referenceCFrame, state)
                        applyPassengerVelocity(
                                humanoidRootPart,
                                boatVelocity,
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

                        if not isAirborne then
                                alignCharacterOrientationWithBoat(character, referenceCFrame, state)
                                updateGroundedPassengerTransform(
                                        humanoidRootPart,
                                        previousBoatCFrame,
                                        referenceCFrame,
                                        state
                                )
                        else
                                moveAirbornePassengerWithBoat(
                                        humanoidRootPart,
                                        previousBoatCFrame,
                                        referenceCFrame,
                                        state
                                )
                        end

                        state.relativeVelocity = clampRelativeVelocity(
                                humanoidRootPart.AssemblyLinearVelocity - boatVelocity
                        )
                        applyPassengerVelocity(
                                humanoidRootPart,
                                boatVelocity,
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

