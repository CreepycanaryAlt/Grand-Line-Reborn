local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Bridge = require(Modules:WaitForChild("Bridge"))

-- Example authority registration: server owns handling logic.
Bridge:SetRateLimit("Movement", "Sprint", 10)
Bridge:SetRateLimit("State", "*", 20)

Bridge:On("Movement", "Sprint", function(player, data)
	print(("[Bridge] Sprint event from %s"):format(player.Name), data)

	-- Round-trip test: echo confirmation back to the same client.
	Bridge:Fire("State", "Snapshot", {
		source = "Server",
		received = "Movement/Sprint",
		serverTime = os.clock(),
	}, player)
end)

Bridge:On("State", "Update", function(player, data)
	print(("[Bridge] State update from %s"):format(player.Name), data)
end)
