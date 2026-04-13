local Players = game:GetService("Players")

local CharacterService = {}
CharacterService.__index = CharacterService
CharacterService.DebugMode = false

local _playerCharacterMap = {}
local _characterAddedCallbacks = {}
local _characterRemovingCallbacks = {}
local _playerConnections = {}
local _pendingCharacterConnections = {}

local function safeCall(callback, data, eventType, player)
	local ok, err = pcall(callback, data)
	if not ok and CharacterService.DebugMode then
		warn("[CharacterService] callback error:", err)
		warn(
			("[CharacterService][client][%s] callback failed for %s"):format(
				eventType or "Unknown",
				player and player.Name or "UnknownPlayer"
			)
		)
	end
end

local function getCallbacks(registry, player)
	local callbacks = registry[player]
	if callbacks == nil then
		callbacks = {}
		registry[player] = callbacks
	end

	return callbacks
end

local function dispatchCallbacks(registry, player, data, eventType)
	local callbacks = registry[player]
	if callbacks == nil then
		return
	end

	for _, callback in ipairs(callbacks) do
		safeCall(callback, data, eventType, player)
	end
end

local function disconnectConnections(connections)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function clearCharacterEntry(player, shouldNotify)
	local entry = _playerCharacterMap[player]
	if entry == nil then
		return
	end

	_playerCharacterMap[player] = nil

	if shouldNotify then
		dispatchCallbacks(_characterRemovingCallbacks, player, {
			Character = entry.Character,
			Humanoid = entry.Humanoid,
			RootPart = entry.RootPart,
		}, "Removing")
	end
end

local function resolveCharacterData(character)
	if character == nil or not character:IsA("Model") then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or rootPart == nil then
		return nil
	end

	return {
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart,
	}
end

local function disconnectPendingValidation(player)
	local connections = _pendingCharacterConnections[player]
	if connections == nil then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	_pendingCharacterConnections[player] = nil
end

local function trackCharacter(player, character)
	clearCharacterEntry(player, true)
	disconnectPendingValidation(player)

	local resolved = resolveCharacterData(character)
	if resolved == nil then
		if character == nil then
			return
		end

		local pending = {}
		_pendingCharacterConnections[player] = pending
		local function tryResolve()
			if _pendingCharacterConnections[player] ~= pending then
				return
			end

			local retried = resolveCharacterData(character)
			if retried == nil then
				return
			end

			disconnectPendingValidation(player)
			_playerCharacterMap[player] = retried
			dispatchCallbacks(_characterAddedCallbacks, player, {
				Character = retried.Character,
				Humanoid = retried.Humanoid,
				RootPart = retried.RootPart,
			}, "Added")
		end

		table.insert(pending, character.ChildAdded:Connect(tryResolve))
		table.insert(pending, character.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				disconnectPendingValidation(player)
			end
		end))
		return
	end

	_playerCharacterMap[player] = resolved
	dispatchCallbacks(_characterAddedCallbacks, player, {
		Character = resolved.Character,
		Humanoid = resolved.Humanoid,
		RootPart = resolved.RootPart,
	}, "Added")
end

local function onCharacterRemoving(player, character)
	disconnectPendingValidation(player)

	local entry = _playerCharacterMap[player]
	if entry == nil then
		return
	end

	if character ~= nil and entry.Character ~= character then
		return
	end

	clearCharacterEntry(player, true)
end

local function bindPlayer(player)
	if _playerConnections[player] ~= nil then
		return
	end

	_characterAddedCallbacks[player] = _characterAddedCallbacks[player] or {}
	_characterRemovingCallbacks[player] = _characterRemovingCallbacks[player] or {}

	local connections = {}
	_playerConnections[player] = connections

	table.insert(connections, player.CharacterAdded:Connect(function(character)
		trackCharacter(player, character)
	end))

	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		onCharacterRemoving(player, character)
	end))

	if player.Character ~= nil then
		task.spawn(trackCharacter, player, player.Character)
	end
end

local function unbindPlayer(player)
	clearCharacterEntry(player, true)
	disconnectPendingValidation(player)

	local connections = _playerConnections[player]
	if connections ~= nil then
		disconnectConnections(connections)
		_playerConnections[player] = nil
	end

	_characterAddedCallbacks[player] = nil
	_characterRemovingCallbacks[player] = nil
end

Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(unbindPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	bindPlayer(player)
end

function CharacterService:Get(player)
	local entry = _playerCharacterMap[player]
	if entry == nil then
		return nil
	end

	return {
		Character = entry.Character,
		Humanoid = entry.Humanoid,
		RootPart = entry.RootPart,
	}
end

function CharacterService:GetCharacter(player)
	local entry = self:Get(player)
	return entry and entry.Character or nil
end

function CharacterService:GetHumanoid(player)
	local entry = _playerCharacterMap[player]
	if entry == nil then
		return nil
	end

	if entry.Humanoid ~= nil and entry.Humanoid.Parent ~= nil then
		return entry.Humanoid
	end

	local refreshed = resolveCharacterData(entry.Character)
	if refreshed ~= nil then
		_playerCharacterMap[player] = refreshed
		return refreshed.Humanoid
	end

	return nil
end

function CharacterService:GetRootPart(player)
	local entry = _playerCharacterMap[player]
	if entry == nil then
		return nil
	end

	if entry.RootPart ~= nil and entry.RootPart.Parent ~= nil then
		return entry.RootPart
	end

	local refreshed = resolveCharacterData(entry.Character)
	if refreshed ~= nil then
		_playerCharacterMap[player] = refreshed
		return refreshed.RootPart
	end

	return nil
end

function CharacterService:OnCharacterAdded(player, callback)
	assert(typeof(callback) == "function", "callback must be a function")
	local callbacks = getCallbacks(_characterAddedCallbacks, player)
	table.insert(callbacks, callback)

	local existing = self:Get(player)
	if existing ~= nil then
		safeCall(callback, existing, "Added", player)
	end

	return function()
		local idx = table.find(callbacks, callback)
		if idx ~= nil then
			table.remove(callbacks, idx)
		end
	end
end

function CharacterService:OnCharacterRemoving(player, callback)
	assert(typeof(callback) == "function", "callback must be a function")
	local callbacks = getCallbacks(_characterRemovingCallbacks, player)
	table.insert(callbacks, callback)

	return function()
		local idx = table.find(callbacks, callback)
		if idx ~= nil then
			table.remove(callbacks, idx)
		end
	end
end

return setmetatable({}, CharacterService)
