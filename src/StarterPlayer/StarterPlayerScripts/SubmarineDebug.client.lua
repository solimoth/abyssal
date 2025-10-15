-- SubmarineDebug.lua
-- Place this as a LocalScript in StarterPlayer/StarterPlayerScripts/
-- This will help debug what's happening with submarine movement

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaterPhysics = require(ReplicatedStorage.Modules.WaterPhysics)

local player = Players.LocalPlayer

-- Debug submarine and control part positions
RunService.Heartbeat:Connect(function()
	-- Find any boats in workspace
	for _, obj in pairs(workspace:GetChildren()) do
		if obj:GetAttribute("OwnerId") == tostring(player.UserId) then
			-- Found player's boat
			local boatType = obj:GetAttribute("BoatType")
			if boatType == "TestSubmarine" then
				-- It's a submarine
				local primaryPart = obj.PrimaryPart
				local controlPart = workspace:FindFirstChild("BoatControlPart")

				if primaryPart and controlPart then
					-- Check if control part belongs to this player
					if controlPart:GetAttribute("OwnerUserId") == tostring(player.UserId) then
						-- Print positions every second
						if tick() % 1 < 0.016 then
							print("=== SUBMARINE DEBUG ===")
							print("Boat Y:", primaryPart.Position.Y)
							print("Control Part Y:", controlPart.Position.Y)
                                                        local surfaceY = WaterPhysics.GetWaterLevel(primaryPart.Position)
                                                        print("Depth from surface:", surfaceY - primaryPart.Position.Y)
							print("Control Anchored?", controlPart.Anchored)

							-- Check for BodyVelocity (shouldn't exist)
							local bodyVel = primaryPart:FindFirstChild("BodyVelocity")
							if bodyVel then
								print("WARNING: BodyVelocity found! MaxForce:", bodyVel.MaxForce)
							end

							-- Check AlignPosition
							local alignPos = primaryPart:FindFirstChild("BoatAlignPosition")
							if alignPos then
								print("AlignPos MaxForce:", alignPos.MaxForce)
								print("AlignPos Enabled:", alignPos.Enabled)
							end
						end
					end
				end
			end
		end
	end
end)
