local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Bridge = require(Modules:WaitForChild("Bridge"))

-- Example outbound client message.
Bridge:Fire("Movement", "Sprint", {
	isSprinting = true,
	timestamp = os.clock(),
})

-- Optional example listener for generic server->client bridge traffic.
Bridge:On("State", "Snapshot", function(data)
	print("[Bridge] Received state snapshot", data)
end)
