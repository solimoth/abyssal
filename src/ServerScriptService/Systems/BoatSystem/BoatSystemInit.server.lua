-- BoatSystemInit.lua (REGULAR SCRIPT)
-- Place in: ServerScriptService/Systems/BoatSystem/BoatSystemInit.lua
-- This is a regular Script that initializes the boat system

local BoatManager = require(script.Parent.BoatManager)

-- Initialize the boat manager
BoatManager.Initialize()

print("Boat System initialized successfully!")