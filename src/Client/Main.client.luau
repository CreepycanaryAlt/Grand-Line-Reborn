local Players = game:GetService("Players")

local CharacterService = require(game.StarterPlayer.StarterPlayerScripts.Services.CharacterService)

CharacterService.DebugMode = true

local player = Players.LocalPlayer

print("[Client CharacterService TEST] Started for:", player.Name)

-- Test initial state
task.wait(1)

local char = CharacterService:GetCharacter(player)
local hum = CharacterService:GetHumanoid(player)
local root = CharacterService:GetRootPart(player)

print("[Client TEST] Initial Character:", char)
print("[Client TEST] Initial Humanoid:", hum)
print("[Client TEST] Initial RootPart:", root)

-- Test lifecycle events
CharacterService:OnCharacterAdded(player, function(data)
    print("[Client TEST] Character Added:", player.Name)
    print("Character:", data.Character)
end)

CharacterService:OnCharacterRemoving(player, function(data)
    print("[Client TEST] Character Removing:", player.Name)
end)

-- Revalidation test (stress safe access)
task.spawn(function()
    while true do
        task.wait(5)

        local h = CharacterService:GetHumanoid(player)
        local r = CharacterService:GetRootPart(player)

        print("[Client TEST LOOP] Humanoid:", h, "RootPart:", r)
    end
end)