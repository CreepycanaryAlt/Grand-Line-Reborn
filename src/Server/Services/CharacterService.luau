local Players = game:GetService("Players")

local CharacterService = {}
CharacterService.__index = CharacterService
CharacterService.DebugMode = false

local _playerCharacterMap = {}
local _characterAddedCallbacks = {}
local _characterRemovingCallbacks = {}
local _playerConnections = {}
local _warnThrottle = {}
local WARN_THROTTLE_SECONDS = 8

local function shouldWarn(player, warnType)
	local userId = player and player.UserId or 0
	local now = os.clock()
	local byPlayer = _warnThrottle[userId]
	if byPlayer == nil then
		byPlayer = {}
		_warnThrottle[userId] = byPlayer
	end

	local last = byPlayer[warnType]
	if last ~= nil and (now - last) < WARN_THROTTLE_SECONDS then
		return false
	end

	byPlayer[warnType] = now
	return true
end

local function debugWarn(player, warnType, message)
	if not CharacterService.DebugMode then
		return
	end

	if not shouldWarn(player, warnType) then
		return
	end

	warn(("[CharacterService][Debug][%s] %s"):format(warnType, message))
end

local function isValidPlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

local function safeCall(callback, data, eventType, player)
	local ok, err = pcall(callback, data)
	if not ok then
		local trace = debug.traceback(tostring(err), 2)
		warn(
			("[CharacterService][server][%s] callback failed for %s\n%s"):format(
				eventType or "Unknown",
				player and player.Name or "UnknownPlayer",
				trace
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

	disconnectConnections(entry.Connections)
	_playerCharacterMap[player] = nil

	if shouldNotify then
		if _characterRemovingCallbacks[player] ~= nil and next(_characterRemovingCallbacks[player]) ~= nil then
			debugWarn(player, "RemovingWithActiveCallbacks", "Character removed while callbacks are still registered")
		end

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
	if humanoid == nil then
		humanoid = character:WaitForChild("Humanoid", 3)
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart == nil then
		rootPart = character:WaitForChild("HumanoidRootPart", 3)
	end

	if humanoid == nil or rootPart == nil then
		return nil
	end

	return {
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart,
		Connections = {},
	}
end

local function trackCharacter(player, character)
	clearCharacterEntry(player, true)

	local resolved = resolveCharacterData(character)
	if resolved == nil then
		debugWarn(player, "CharacterNotInitialized", "Character accessed before fully initialized")
		return
	end

	_playerCharacterMap[player] = resolved

	table.insert(resolved.Connections, character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			clearCharacterEntry(player, true)
		end
	end))

	table.insert(resolved.Connections, resolved.Humanoid.Died:Connect(function()
		clearCharacterEntry(player, true)
	end))

	dispatchCallbacks(_characterAddedCallbacks, player, {
		Character = resolved.Character,
		Humanoid = resolved.Humanoid,
		RootPart = resolved.RootPart,
	}, "Added")
end

local function onCharacterRemoving(player, character)
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

	local connections = _playerConnections[player]
	if connections ~= nil then
		disconnectConnections(connections)
		_playerConnections[player] = nil
	end

	_characterAddedCallbacks[player] = nil
	_characterRemovingCallbacks[player] = nil
	_warnThrottle[player.UserId] = nil
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
	local entry = self:Get(player)
	if entry == nil then
		if isValidPlayer(player) then
			debugWarn(player, "HumanoidNil", "GetHumanoid returned nil for a valid player")
		end
		return nil
	end

	if entry.Humanoid == nil then
		debugWarn(player, "HumanoidNil", "GetHumanoid returned nil for cached character data")
	end

	return entry and entry.Humanoid or nil
end

function CharacterService:GetRootPart(player)
	local entry = self:Get(player)
	if entry == nil then
		return nil
	end

	if entry.Character ~= nil and entry.RootPart == nil then
		debugWarn(player, "RootPartNil", "GetRootPart returned nil for a valid character")
	end

	return entry and entry.RootPart or nil
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
