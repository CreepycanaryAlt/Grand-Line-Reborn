local Players = game:GetService("Players")

local CharacterService = require(script.Parent:WaitForChild("CharacterService"))

local StateSystem = {}
StateSystem.__index = StateSystem

local StateRegistry = {}
local PlayerStates = {}
local PlayerConnections = {}

local function listToSet(values)
	local map = {}
	if typeof(values) ~= "table" then
		return map
	end

	for _, value in ipairs(values) do
		if typeof(value) == "string" and #value > 0 then
			map[value] = true
		end
	end

	return map
end

local function getPlayerBucket(player)
	local bucket = PlayerStates[player]
	if bucket == nil then
		bucket = {
			ActiveStates = {},
		}
		PlayerStates[player] = bucket
	end

	return bucket
end

local function removePlayerStateBucket(player)
	PlayerStates[player] = nil
end

local function scheduleExpiration(player, stateName, entry)
	if entry.Duration == nil then
		return
	end

	local token = entry.ExpireToken
	task.delay(entry.Duration, function()
		local bucket = PlayerStates[player]
		if bucket == nil then
			return
		end

		local current = bucket.ActiveStates[stateName]
		if current == nil or current.ExpireToken ~= token then
			return
		end

		StateSystem:RemoveState(player, stateName)
	end)
end

local function runStateHook(hook, characterData, context)
	if typeof(hook) ~= "function" then
		return
	end

	local ok, err = pcall(hook, characterData.Character, context)
	if not ok then
		warn("[StateSystem] state hook failed:", err)
	end
end

local function canOverwrite(incomingDefinition, existingName)
	return incomingDefinition.Overwrites[existingName] == true
end

local function canBeOverwrittenByIncoming(incomingDefinition, existingDefinition, incomingName)
	return incomingDefinition.Priority > existingDefinition.Priority
		and existingDefinition.OverwritableBy[incomingName] == true
end

function StateSystem:RegisterState(definition)
	assert(typeof(definition) == "table", "State definition must be a table")
	assert(typeof(definition.Name) == "string" and #definition.Name > 0, "State definition must include Name")

	local stateName = definition.Name
	StateRegistry[stateName] = {
		Name = stateName,
		Priority = if typeof(definition.Priority) == "number" then definition.Priority else 0,
		Blocks = listToSet(definition.Blocks),
		Overwrites = listToSet(definition.Overwrites),
		OverwritableBy = listToSet(definition.OverwritableBy),
		Duration = if typeof(definition.Duration) == "number" and definition.Duration > 0 then definition.Duration else nil,
		Stackable = definition.Stackable == true,
		OnApply = definition.OnApply,
		OnRemove = definition.OnRemove,
	}
end

function StateSystem:ApplyState(player, stateName, context)
	local characterData = CharacterService:Get(player)
	if characterData == nil then
		return false
	end

	local definition = StateRegistry[stateName]
	if definition == nil then
		return false
	end

	local bucket = getPlayerBucket(player)
	local activeStates = bucket.ActiveStates
	local existing = activeStates[stateName]
	local now = os.clock()

	if existing ~= nil and definition.Stackable then
		existing.StackCount += 1
		existing.StartTime = now
		existing.Context = context
		existing.Duration = definition.Duration
		existing.SourcePriority = definition.Priority
		existing.ExpireToken += 1
		scheduleExpiration(player, stateName, existing)
		runStateHook(definition.OnApply, characterData, context)
		return true
	end

	if existing ~= nil and not definition.Stackable then
		existing.StartTime = now
		existing.Context = context
		existing.Duration = definition.Duration
		existing.SourcePriority = definition.Priority
		existing.ExpireToken += 1
		scheduleExpiration(player, stateName, existing)
		runStateHook(definition.OnApply, characterData, context)
		return true
	end

	for existingName, existingEntry in pairs(activeStates) do
		local existingDefinition = StateRegistry[existingName]
		if existingDefinition ~= nil then
			if canOverwrite(definition, existingName)
				or canBeOverwrittenByIncoming(definition, existingDefinition, stateName)
			then
				self:RemoveState(player, existingName)
			elseif existingDefinition.Overwrites[stateName] == true and existingDefinition.Priority >= definition.Priority then
				return false
			end
		end
	end

	activeStates[stateName] = {
		StartTime = now,
		Duration = definition.Duration,
		Context = context,
		SourcePriority = definition.Priority,
		StackCount = 1,
		ExpireToken = 1,
	}

	scheduleExpiration(player, stateName, activeStates[stateName])
	runStateHook(definition.OnApply, characterData, context)
	return true
end

function StateSystem:RemoveState(player, stateName)
	local bucket = PlayerStates[player]
	if bucket == nil then
		return false
	end

	local entry = bucket.ActiveStates[stateName]
	if entry == nil then
		return false
	end

	local definition = StateRegistry[stateName]
	local characterData = CharacterService:Get(player)

	entry.ExpireToken += 1
	bucket.ActiveStates[stateName] = nil

	if definition ~= nil and characterData ~= nil then
		runStateHook(definition.OnRemove, characterData, entry.Context)
	end

	if next(bucket.ActiveStates) == nil then
		removePlayerStateBucket(player)
	end

	return true
end

function StateSystem:HasState(player, stateName)
	local bucket = PlayerStates[player]
	return bucket ~= nil and bucket.ActiveStates[stateName] ~= nil or false
end

function StateSystem:GetActiveStates(player)
	local bucket = PlayerStates[player]
	if bucket == nil then
		return {}
	end

	local output = {}
	for stateName, entry in pairs(bucket.ActiveStates) do
		output[stateName] = {
			StartTime = entry.StartTime,
			Duration = entry.Duration,
			Context = entry.Context,
			SourcePriority = entry.SourcePriority,
			StackCount = entry.StackCount,
		}
	end

	return output
end

function StateSystem:CanPerformAction(player, actionType)
	local bucket = PlayerStates[player]
	if bucket == nil then
		return true
	end

	for stateName in pairs(bucket.ActiveStates) do
		local definition = StateRegistry[stateName]
		if definition ~= nil and definition.Blocks[actionType] == true then
			return false
		end
	end

	return true
end

local function clearAllStatesForPlayer(player)
	local bucket = PlayerStates[player]
	if bucket == nil then
		return
	end

	for stateName in pairs(bucket.ActiveStates) do
		StateSystem:RemoveState(player, stateName)
	end

	removePlayerStateBucket(player)
end

local function bindPlayer(player)
	if PlayerConnections[player] ~= nil then
		return
	end

	local connections = {}
	PlayerConnections[player] = connections

	table.insert(connections, CharacterService:OnCharacterAdded(player, function()
		clearAllStatesForPlayer(player)
	end))

	table.insert(connections, CharacterService:OnCharacterRemoving(player, function()
		clearAllStatesForPlayer(player)
	end))
end

local function unbindPlayer(player)
	clearAllStatesForPlayer(player)

	local connections = PlayerConnections[player]
	if connections ~= nil then
		for _, disconnect in ipairs(connections) do
			disconnect()
		end
		PlayerConnections[player] = nil
	end
end

Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(unbindPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	bindPlayer(player)
end

return setmetatable({}, StateSystem)
