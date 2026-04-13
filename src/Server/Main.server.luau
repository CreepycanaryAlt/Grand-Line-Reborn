local Players = game:GetService("Players")

local CharacterService = require(game.ServerScriptService.Services.CharacterService)

CharacterService.DebugMode = true

-- Test: player joins + character lifecycle
Players.PlayerAdded:Connect(function(player)

    print("[CharacterService TEST] Player joined:", player.Name)

    CharacterService:OnCharacterAdded(player, function(data)
        print("[CharacterService TEST] Character Added:", player.Name)

        print("Character:", data.Character)
        print("Humanoid:", CharacterService:GetHumanoid(player))
        print("RootPart:", CharacterService:GetRootPart(player))
    end)

    CharacterService:OnCharacterRemoving(player, function(data)
        print("[CharacterService TEST] Character Removing:", player.Name)
    end)
end)

-- Optional: test existing players in studio
for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(function()
        print("[CharacterService TEST] Existing player:", player.Name)

        local char = CharacterService:GetCharacter(player)
        local hum = CharacterService:GetHumanoid(player)
        local root = CharacterService:GetRootPart(player)

        print("Preloaded Character:", char)
        print("Preloaded Humanoid:", hum)
        print("Preloaded RootPart:", root)
    end)
end