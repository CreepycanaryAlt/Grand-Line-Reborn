local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local IS_SERVER = RunService:IsServer()
local BRIDGE_EVENT_NAME = "BridgeEvent"
local REMOTE_CONTAINER_NAME = "Remotes"

local CHANNEL_PATTERN = "^[%w_]+$"
local MAX_KEY_LENGTH = 48
local MAX_TABLE_DEPTH = 5
local MAX_TABLE_ENTRIES = 64
local MAX_STRING_LENGTH = 512
local MAX_PAYLOAD_UNITS = 4096
local STALE_BUCKET_WINDOW = 30
local MAX_BUCKETS_PER_PLAYER = 256
local DIRECTION_CLIENT_TO_SERVER = "ClientToServer"
local DIRECTION_SERVER_TO_CLIENT = "ServerToClient"
local INTERNAL_RESPONSE_ACTION = "__BridgeResponse"

local Bridge = {}
Bridge.__index = Bridge

local listeners = {}
local rateLimits = {}
local playerBuckets = {}
local incomingMiddlewarePipeline = {}
local outgoingMiddlewarePipeline = {}
local debugEnabled = false
local nextRequestId = 0
local pendingResponses = {}

local function debugLog(message, ...)
	if not debugEnabled then
		return
	end

	print("[Bridge] " .. message, ...)
end

local function getOrCreateRemoteContainer()
	local remotesFolder = ReplicatedStorage:FindFirstChild(REMOTE_CONTAINER_NAME)
	if remotesFolder == nil then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = REMOTE_CONTAINER_NAME
		remotesFolder.Parent = ReplicatedStorage
	end

	return remotesFolder
end

local function resolveRemoteEvent()
	local remotesFolder = getOrCreateRemoteContainer()
	local existing = remotesFolder:FindFirstChild(BRIDGE_EVENT_NAME)

	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	if existing and not existing:IsA("RemoteEvent") then
		error(("Bridge remote '%s' exists but is not a RemoteEvent"):format(BRIDGE_EVENT_NAME))
	end

	if IS_SERVER then
		local remote = Instance.new("RemoteEvent")
		remote.Name = BRIDGE_EVENT_NAME
		remote.Parent = remotesFolder
		return remote
	end

	return remotesFolder:WaitForChild(BRIDGE_EVENT_NAME)
end

local bridgeEvent = resolveRemoteEvent()

local function isValidKey(value)
	return typeof(value) == "string"
		and #value > 0
		and #value <= MAX_KEY_LENGTH
		and value:match(CHANNEL_PATTERN) ~= nil
end

local function isValidPayload(value)
	local totalUnits = 0
	local stack = {
		{ value = value, depth = 1 },
	}

	while #stack > 0 do
		local current = stack[#stack]
		stack[#stack] = nil

		totalUnits += 1
		if totalUnits > MAX_PAYLOAD_UNITS then
			return false
		end

		local currentValue = current.value
		local valueType = typeof(currentValue)

		if valueType == "string" then
			if #currentValue > MAX_STRING_LENGTH then
				return false
			end
		elseif valueType == "table" then
			if current.depth > MAX_TABLE_DEPTH then
				return false
			end

			local count = 0
			for key, nested in pairs(currentValue) do
				count += 1
				if count > MAX_TABLE_ENTRIES then
					return false
				end

				local keyType = typeof(key)
				if keyType ~= "string" and keyType ~= "number" then
					return false
				end

				if keyType == "string" and #key > MAX_KEY_LENGTH then
					return false
				end

				if keyType == "number" and (key ~= key or key == math.huge or key == -math.huge) then
					return false
				end

				stack[#stack + 1] = {
					value = nested,
					depth = current.depth + 1,
				}
			end
		elseif valueType ~= "nil" and valueType ~= "boolean" and valueType ~= "number" then
			return false
		end
	end

	return true
end

local function getActionCallbacks(channel, action)
	local channelListeners = listeners[channel]
	if channelListeners == nil then
		return nil
	end

	return channelListeners[action]
end

local function dispatchToListeners(player, channel, action, data)
	local callbacks = getActionCallbacks(channel, action)
	if callbacks == nil then
		return
	end

	-- Dispatch is an O(1) channel/action lookup followed by callback iteration.
	for _, callback in ipairs(callbacks) do
		task.spawn(function()
			local ok, err
			if IS_SERVER then
				ok, err = pcall(callback, player, data)
			else
				ok, err = pcall(callback, data)
			end

			if not ok then
				warn("[Bridge] Listener error:", err)
			end
		end)
	end
end

local function getRateLimit(channel, action)
	local exactChannel = rateLimits[channel]
	if exactChannel ~= nil then
		if exactChannel[action] ~= nil then
			return exactChannel[action]
		end

		if exactChannel["*"] ~= nil then
			return exactChannel["*"]
		end
	end

	local globalChannel = rateLimits["*"]
	if globalChannel ~= nil then
		if globalChannel[action] ~= nil then
			return globalChannel[action]
		end

		return globalChannel["*"]
	end

	return nil
end

local function pruneStaleBuckets(byUser, now)
	local keptBucketCount = 0
	for channel, byChannel in pairs(byUser) do
		for action, bucket in pairs(byChannel) do
			if (now - bucket.lastTime) > STALE_BUCKET_WINDOW then
				byChannel[action] = nil
			else
				keptBucketCount += 1
			end
		end

		if next(byChannel) == nil then
			byUser[channel] = nil
		end
	end

	return keptBucketCount
end

local function runMiddlewarePipeline(pipeline, player, channel, action, data, direction)
	for _, middleware in ipairs(pipeline) do
		local keep, reason = middleware(player, channel, action, data, direction)
		if keep == false then
			debugLog(
				"Middleware rejected [%s] (%s:%s) from %s reason=%s",
				direction,
				channel,
				action,
				player and player.Name or "Server",
				reason or "Blocked"
			)
			return false, reason
		end
	end

	return true, nil
end

local function canSendOutgoing(player, channel, action, data)
	return runMiddlewarePipeline(
		outgoingMiddlewarePipeline,
		player,
		channel,
		action,
		data,
		DIRECTION_SERVER_TO_CLIENT
	)
end

local function sendToClient(player, channel, action, data)
	local canSend = canSendOutgoing(player, channel, action, data)
	if not canSend then
		return
	end

	debugLog("Dispatch [%s] (%s:%s) to %s", DIRECTION_SERVER_TO_CLIENT, channel, action, player.Name)
	bridgeEvent:FireClient(player, channel, action, data)
end

local function sendToAllClients(channel, action, data)
	for _, player in ipairs(Players:GetPlayers()) do
		sendToClient(player, channel, action, data)
	end
end

local function reserveRequestSlot(channel, action)
	nextRequestId += 1
	if nextRequestId >= 2 ^ 31 then
		nextRequestId = 1
	end

	local requestId = nextRequestId
	pendingResponses[requestId] = {
		channel = channel,
		action = action,
		createdAt = os.clock(),
	}

	return requestId
end

local function routeIncomingResponse(action, data, direction)
	if action ~= INTERNAL_RESPONSE_ACTION then
		return false
	end

	if typeof(data) ~= "table" then
		return true
	end

	local requestId = data.requestId
	if typeof(requestId) ~= "number" then
		return true
	end

	if pendingResponses[requestId] ~= nil then
		debugLog("Response routed [%s] requestId=%d", direction, requestId)
		-- Response completion mapping reserved for future Request implementation.
		pendingResponses[requestId] = nil
	end

	return true
end

local function consumeToken(player, channel, action)
	local limit = getRateLimit(channel, action)
	if limit == nil then
		return true
	end

	-- Token bucket: tokens refill continuously at `limit` per second.
	local userId = player.UserId
	local now = os.clock()
	local refillRate = limit
	local capacity = limit

	local byUser = playerBuckets[userId]
	if byUser == nil then
		byUser = {}
		playerBuckets[userId] = byUser
	else
		local activeCount = pruneStaleBuckets(byUser, now)
		if activeCount >= MAX_BUCKETS_PER_PLAYER then
			debugLog("Bucket cap rejection (%s:%s) for %s", channel, action, player.Name)
			return false
		end
	end

	local byChannel = byUser[channel]
	if byChannel == nil then
		byChannel = {}
		byUser[channel] = byChannel
	end

	local bucketKey = action
	local bucket = byChannel[bucketKey]
	if bucket == nil then
		byChannel[bucketKey] = {
			tokens = capacity - 1,
			lastTime = now,
		}
		return true
	end

	local elapsed = now - bucket.lastTime
	bucket.lastTime = now
	bucket.tokens = math.min(capacity, bucket.tokens + elapsed * refillRate)

	if bucket.tokens < 1 then
		debugLog("Rate limited (%s:%s) for %s", channel, action, player.Name)
		return false
	end

	bucket.tokens -= 1
	return true
end

local function cleanupPlayerBuckets(player)
	playerBuckets[player.UserId] = nil
end

if IS_SERVER then
	Players.PlayerRemoving:Connect(cleanupPlayerBuckets)
end

function Bridge:Fire(channel, action, data, targetPlayer)
	assert(isValidKey(channel), "Bridge:Fire channel must be an alphanumeric string")
	assert(isValidKey(action), "Bridge:Fire action must be an alphanumeric string")
	assert(isValidPayload(data), "Bridge:Fire payload contains unsupported data")

	if IS_SERVER then
		if targetPlayer ~= nil then
			sendToClient(targetPlayer, channel, action, data)
			return
		end

		sendToAllClients(channel, action, data)
		return
	end

	bridgeEvent:FireServer(channel, action, data)
end

function Bridge:FireClient(player, channel, action, data)
	assert(IS_SERVER, "Bridge:FireClient can only be called on the server")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bridge:FireClient player must be a Player")
	assert(isValidKey(channel), "Bridge:FireClient channel must be an alphanumeric string")
	assert(isValidKey(action), "Bridge:FireClient action must be an alphanumeric string")
	assert(isValidPayload(data), "Bridge:FireClient payload contains unsupported data")

	sendToClient(player, channel, action, data)
end

function Bridge:FireAll(channel, action, data)
	assert(IS_SERVER, "Bridge:FireAll can only be called on the server")
	assert(isValidKey(channel), "Bridge:FireAll channel must be an alphanumeric string")
	assert(isValidKey(action), "Bridge:FireAll action must be an alphanumeric string")
	assert(isValidPayload(data), "Bridge:FireAll payload contains unsupported data")

	sendToAllClients(channel, action, data)
end

function Bridge:On(channel, action, callback)
	assert(isValidKey(channel), "Bridge:On channel must be an alphanumeric string")
	assert(isValidKey(action), "Bridge:On action must be an alphanumeric string")
	assert(typeof(callback) == "function", "Bridge:On callback must be a function")

	local channelListeners = listeners[channel]
	if channelListeners == nil then
		channelListeners = {}
		listeners[channel] = channelListeners
	end

	local actionListeners = channelListeners[action]
	if actionListeners == nil then
		actionListeners = {}
		channelListeners[action] = actionListeners
	end

	table.insert(actionListeners, callback)

	return function()
		local index = table.find(actionListeners, callback)
		if index ~= nil then
			table.remove(actionListeners, index)
		end
	end
end

function Bridge:SetRateLimit(channel, action, limit)
	assert(IS_SERVER, "Bridge:SetRateLimit can only be called on the server")
	assert(channel == "*" or isValidKey(channel), "Bridge:SetRateLimit channel must be '*' or alphanumeric")
	assert(action == "*" or isValidKey(action), "Bridge:SetRateLimit action must be '*' or alphanumeric")
	assert(typeof(limit) == "number" and limit > 0, "Bridge:SetRateLimit limit must be a positive number")

	local channelLimits = rateLimits[channel]
	if channelLimits == nil then
		channelLimits = {}
		rateLimits[channel] = channelLimits
	end

	channelLimits[action] = limit
end

function Bridge:Use(middlewareFunction)
	self:UseIncoming(middlewareFunction)
end

function Bridge:UseIncoming(middlewareFunction)
	assert(IS_SERVER, "Bridge:Use can only be called on the server")
	assert(typeof(middlewareFunction) == "function", "Bridge:Use middleware must be a function")
	table.insert(incomingMiddlewarePipeline, middlewareFunction)
end

function Bridge:UseOutgoing(middlewareFunction)
	assert(IS_SERVER, "Bridge:UseOutgoing can only be called on the server")
	assert(typeof(middlewareFunction) == "function", "Bridge:UseOutgoing middleware must be a function")
	table.insert(outgoingMiddlewarePipeline, middlewareFunction)
end

function Bridge:SetDebug(enabled)
	assert(typeof(enabled) == "boolean", "Bridge:SetDebug enabled must be a boolean")
	debugEnabled = enabled
end

function Bridge:Request(channel, action, data)
	assert(isValidKey(channel), "Bridge:Request channel must be an alphanumeric string")
	assert(isValidKey(action), "Bridge:Request action must be an alphanumeric string")
	assert(isValidPayload(data), "Bridge:Request payload contains unsupported data")

	local requestId = reserveRequestSlot(channel, action)
	debugLog("Request reserved requestId=%d (%s:%s)", requestId, channel, action)
	error("Bridge:Request is reserved for future request/response support")
end

if IS_SERVER then
	bridgeEvent.OnServerEvent:Connect(function(player, channel, action, data)
		if not isValidKey(channel) or not isValidKey(action) then
			return
		end

		if not isValidPayload(data) then
			return
		end

		if routeIncomingResponse(action, data, DIRECTION_CLIENT_TO_SERVER) then
			return
		end

		if not consumeToken(player, channel, action) then
			return
		end

		local canPass = runMiddlewarePipeline(
			incomingMiddlewarePipeline,
			player,
			channel,
			action,
			data,
			DIRECTION_CLIENT_TO_SERVER
		)
		if not canPass then
			return
		end

		debugLog("Dispatch [%s] (%s:%s) from %s", DIRECTION_CLIENT_TO_SERVER, channel, action, player.Name)
		dispatchToListeners(player, channel, action, data)
	end)
else
	bridgeEvent.OnClientEvent:Connect(function(channel, action, data)
		if not isValidKey(channel) or not isValidKey(action) then
			return
		end

		if not isValidPayload(data) then
			return
		end

		if routeIncomingResponse(action, data, DIRECTION_SERVER_TO_CLIENT) then
			return
		end

		debugLog("Dispatch [%s] (%s:%s)", DIRECTION_SERVER_TO_CLIENT, channel, action)
		dispatchToListeners(nil, channel, action, data)
	end)
end

return setmetatable({}, Bridge)
