local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local LOCAL_PLAYER = Players.LocalPlayer
local REGION_PADDING = Vector3.new(4, 6, 4)

local currentCharacter
local humanoid
local rootPart
local head

local characterConnections = {}

local function clearCharacterConnections()
        for _, connection in ipairs(characterConnections) do
                connection:Disconnect()
        end
        table.clear(characterConnections)
end

local function setCharacterReferences(character)
        clearCharacterConnections()

        currentCharacter = character
        humanoid = nil
        rootPart = nil
        head = nil

        if not character then
                return
        end

        humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
        rootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
        head = character:FindFirstChild("Head") or character:WaitForChild("Head", 5)

        table.insert(characterConnections, character.ChildAdded:Connect(function(child)
                if child:IsA("BasePart") then
                        if child.Name == "HumanoidRootPart" then
                                rootPart = child
                        elseif child.Name == "Head" then
                                head = child
                        end
                elseif child:IsA("Humanoid") then
                        humanoid = child
                end
        end))

        table.insert(characterConnections, character.ChildRemoved:Connect(function(child)
                if child == rootPart then
                        rootPart = nil
                elseif child == head then
                        head = nil
                elseif child == humanoid then
                        humanoid = nil
                end
        end))

        if humanoid then
                table.insert(characterConnections, humanoid.Died:Connect(function()
                        humanoid = nil
                        rootPart = nil
                        head = nil
                end))
        end
end

local function isInsideShipInterior()
        if not currentCharacter or not rootPart then
                return false
        end

        local overlapParams = OverlapParams.new()
        overlapParams.FilterType = Enum.RaycastFilterType.Exclude
        overlapParams.FilterDescendantsInstances = { currentCharacter }

        local regionSize = rootPart.Size + REGION_PADDING
        local parts = Workspace:GetPartBoundsInBox(rootPart.CFrame, regionSize, overlapParams)

        for _, part in ipairs(parts) do
                if part:IsA("BasePart") and part.Name == "ShipInterior" then
                        return true
                end
        end

        return false
end

local function forceSwimming()
        if not humanoid or not rootPart or humanoid.Health <= 0 then
                return
        end

        local insideShip = isInsideShipInterior()
        local rootUnderwater = WaterPhysics.IsUnderwater(rootPart.Position)

        if rootUnderwater and not insideShip then
                if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
                        humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
                end
        elseif humanoid:GetState() == Enum.HumanoidStateType.Swimming then
                local headUnderwater = head and WaterPhysics.IsUnderwater(head.Position)
                if insideShip or not headUnderwater then
                        humanoid:ChangeState(Enum.HumanoidStateType.Running)
                end
        end
end

LOCAL_PLAYER.CharacterAdded:Connect(setCharacterReferences)
LOCAL_PLAYER.CharacterRemoving:Connect(function()
        clearCharacterConnections()
        currentCharacter = nil
        humanoid = nil
        rootPart = nil
        head = nil
end)

if LOCAL_PLAYER.Character then
        setCharacterReferences(LOCAL_PLAYER.Character)
end

RunService.Heartbeat:Connect(forceSwimming)
