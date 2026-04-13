local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local InputService = {}
InputService.__index = InputService

local actionBindings = {}
local actionListeners = {}
local actionStates = {}
local tokenToActions = {}
local contextEnabled = {
	Gameplay = true,
}
local activeContext = "Gameplay"
local inputLocked = false
local casBoundActions = {}

local DEBUG_MODE = true

local DEFAULT_CONTEXT = "Gameplay"
local PHASE_BEGAN = "Began"
local PHASE_CHANGED = "Changed"
local PHASE_ENDED = "Ended"
local ANALOG_CHANGE_EPSILON = 0.02

local GAMEPAD_DEADZONE = 0.2
local AXIS_TOKENS = {
	[tostring(Enum.KeyCode.Thumbstick1)] = true,
	[tostring(Enum.KeyCode.Thumbstick2)] = true,
	[tostring(Enum.KeyCode.ButtonR2)] = true,
	[tostring(Enum.KeyCode.ButtonL2)] = true,
}

local function normalizeActionName(actionName)
	assert(typeof(actionName) == "string" and #actionName > 0, "actionName must be a non-empty string")
	return actionName
end

local function normalizeContextName(contextName)
	if contextName == nil then
		return DEFAULT_CONTEXT
	end

	if typeof(contextName) ~= "string" or #contextName == 0 then
		return DEFAULT_CONTEXT
	end

	return contextName
end

local function enumToken(enumItem)
	if typeof(enumItem) ~= "EnumItem" then
		return nil
	end

	return tostring(enumItem)
end

local function extractBindConfig(contextOrOptions, options)
	local contextName = DEFAULT_CONTEXT
	local useContextAction = false

	if typeof(contextOrOptions) == "string" or contextOrOptions == nil then
		contextName = normalizeContextName(contextOrOptions)
	elseif typeof(contextOrOptions) == "table" then
		contextName = normalizeContextName(contextOrOptions.contextName)
		useContextAction = contextOrOptions.useContextAction == true or contextOrOptions.useCAS == true
	end

	if typeof(options) == "table" then
		useContextAction = useContextAction
			or options.useContextAction == true
			or options.useCAS == true
	end

	return contextName, useContextAction
end

local function ensureState(actionName)
	local state = actionStates[actionName]
	if state == nil then
		state = {
			active = false,
			pressedAt = 0,
			releasedAt = 0,
		}
		actionStates[actionName] = state
	end

	return state
end

local function removeActionFromTokenMap(actionName, tokens)
	for token in pairs(tokens) do
		local actions = tokenToActions[token]
		if actions then
			actions[actionName] = nil
			if next(actions) == nil then
				tokenToActions[token] = nil
			end
		end
	end
end

local function addActionToTokenMap(actionName, tokens)
	for token in pairs(tokens) do
		local actions = tokenToActions[token]
		if actions == nil then
			actions = {}
			tokenToActions[token] = actions
		end

		actions[actionName] = true
	end
end

local function getInputToken(inputObject)
	if inputObject == nil then
		return nil
	end

	if inputObject.KeyCode ~= Enum.KeyCode.Unknown then
		return tostring(inputObject.KeyCode)
	end

	return tostring(inputObject.UserInputType)
end

local function isContextActive(actionName)
	local binding = actionBindings[actionName]
	if binding == nil then
		return false
	end

	local actionContext = binding.context
	return actionContext == activeContext and contextEnabled[actionContext] == true
end

local function resolvePhase(isPressed, fromInputChanged)
	if isPressed then
		return PHASE_BEGAN
	end

	return PHASE_ENDED
end

local function ensureActiveContext()
	if contextEnabled[activeContext] == true then
		return activeContext
	end

	contextEnabled[DEFAULT_CONTEXT] = contextEnabled[DEFAULT_CONTEXT] ~= false
	activeContext = DEFAULT_CONTEXT
	return activeContext
end

local function normalizeInputValue(token, inputObject)
	if not AXIS_TOKENS[token] then
		return nil
	end

	local position = inputObject.Position
	local valueType = typeof(position)
	if valueType == "Vector2" then
		local magnitude = position.Magnitude
		if magnitude <= GAMEPAD_DEADZONE then
			return Vector2.zero, 0
		end

		local normalizedMagnitude = (magnitude - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE)
		return position.Unit * math.clamp(normalizedMagnitude, 0, 1), magnitude
	end

	if valueType == "Vector3" then
		local magnitude = position.Magnitude
		if magnitude <= GAMEPAD_DEADZONE then
			return Vector3.zero, 0
		end

		local normalizedMagnitude = (magnitude - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE)
		return position.Unit * math.clamp(normalizedMagnitude, 0, 1), magnitude
	end

	local scalar = math.abs(position)
	if scalar <= GAMEPAD_DEADZONE then
		return 0, scalar
	end

	local normalizedScalar = (scalar - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE)
	return math.sign(position) * math.clamp(normalizedScalar, 0, 1), scalar
end

local function updateRawState(actionName, isPressed, now)
	local state = ensureState(actionName)
	local changed = state.active ~= isPressed

	state.active = isPressed
	if changed then
		if not isPressed then
			state.releasedAt = now
		end
	end

	return state, changed
end

local function hasSignificantAnalogChange(previousValue, newValue)
	if previousValue == nil then
		return true
	end

	local valueType = typeof(newValue)
	if valueType == "number" then
		return math.abs(newValue - previousValue) > ANALOG_CHANGE_EPSILON
	end

	if valueType == "Vector2" or valueType == "Vector3" then
		return (newValue - previousValue).Magnitude > ANALOG_CHANGE_EPSILON
	end

	return true
end

local function emitAction(actionName, isPressed, inputObject, phase, normalizedValue, rawMagnitude)
	local listeners = actionListeners[actionName]
	if listeners == nil then
		return
	end

	local metadata = {
		phase = phase,
		normalizedValue = normalizedValue,
		rawMagnitude = rawMagnitude,
	}

	-- Consumption is local to this action dispatch chain only.
	for _, callback in ipairs(listeners) do
		local consumed = callback(isPressed, inputObject, actionName, metadata)
		if consumed == true then
			break
		end
	end
end

local function unbindContextAction(actionName)
	if casBoundActions[actionName] then
		ContextActionService:UnbindAction(actionName)
		casBoundActions[actionName] = nil
	end
end

local function bindContextAction(actionName, keybindEnums)
	ContextActionService:BindAction(
		actionName,
		function(_, inputState, inputObject)
			local now = os.clock()
			local isPressed = inputState == Enum.UserInputState.Begin
			local fromChanged = inputState == Enum.UserInputState.Change
			local token = getInputToken(inputObject)

			local normalizedValue, rawMagnitude = nil, nil
			if fromChanged and token ~= nil then
				normalizedValue, rawMagnitude = normalizeInputValue(token, inputObject)
				if normalizedValue ~= nil then
					isPressed = rawMagnitude > GAMEPAD_DEADZONE
				end
			end

			local state, changed = updateRawState(actionName, isPressed, now)
			if inputLocked then
				return Enum.ContextActionResult.Sink
			end

			local binding = actionBindings[actionName]
			if binding == nil or binding.context ~= ensureActiveContext() then
				return Enum.ContextActionResult.Sink
			end

			local phase = nil
			if fromChanged then
				if normalizedValue == nil or not hasSignificantAnalogChange(state.lastAnalogValue, normalizedValue) then
					return Enum.ContextActionResult.Sink
				end

				state.lastAnalogValue = normalizedValue
				phase = PHASE_CHANGED
			elseif changed then
				phase = resolvePhase(isPressed, false)
				if phase == PHASE_BEGAN then
					state.pressedAt = now
				end
			else
				return Enum.ContextActionResult.Sink
			end

			emitAction(actionName, isPressed, inputObject, phase, normalizedValue, rawMagnitude)
			return Enum.ContextActionResult.Sink
		end,
		false,
		table.unpack(keybindEnums)
	)

	casBoundActions[actionName] = true
end

local function processInput(inputObject, isPressed, gameProcessedEvent, fromInputChanged)
	-- Only suppress input while typing; allow gameplay keys even when core scripts mark processed.
	if gameProcessedEvent and UserInputService:GetFocusedTextBox() ~= nil then
		return
	end

	local token = getInputToken(inputObject)
	if token == nil then
		return
	end

	local actions = tokenToActions[token]
	if actions == nil then
		return
	end

	local normalizedValue, rawMagnitude = nil, nil
	if fromInputChanged then
		normalizedValue, rawMagnitude = normalizeInputValue(token, inputObject)
		if normalizedValue == nil then
			return
		end

		isPressed = rawMagnitude > GAMEPAD_DEADZONE
	end

	local now = os.clock()
	local validatedActiveContext = ensureActiveContext()
	for actionName in pairs(actions) do
		local state, changed = updateRawState(actionName, isPressed, now)

		-- Absolute gate: lock blocks dispatch/callbacks, raw state still updates.
		if inputLocked then
			continue
		end

		local binding = actionBindings[actionName]
		if binding == nil or binding.context ~= validatedActiveContext then
			continue
		end

		local phase = nil
		if fromInputChanged then
			if not hasSignificantAnalogChange(state.lastAnalogValue, normalizedValue) then
				continue
			end

			state.lastAnalogValue = normalizedValue
			phase = PHASE_CHANGED
		elseif changed then
			phase = resolvePhase(isPressed, false)
			if phase == PHASE_BEGAN then
				-- Buffer updates only on valid began dispatches.
				state.pressedAt = now
			end
		else
			continue
		end

		emitAction(actionName, isPressed, inputObject, phase, normalizedValue, rawMagnitude)
	end
end

UserInputService.InputBegan:Connect(function(inputObject, gameProcessedEvent)
	processInput(inputObject, true, gameProcessedEvent, false)
end)

UserInputService.InputEnded:Connect(function(inputObject, gameProcessedEvent)
	processInput(inputObject, false, gameProcessedEvent, false)
end)

UserInputService.InputChanged:Connect(function(inputObject, gameProcessedEvent)
	processInput(inputObject, false, gameProcessedEvent, true)
end)

function InputService:BindAction(actionName, keybinds, contextNameOrOptions, options)
	-- DEBUG_MODE must be defined at the top of the script, e.g. local DEBUG_MODE = true
	actionName = normalizeActionName(actionName)
	if typeof(keybinds) ~= "table" then
		if DEBUG_MODE then
			print("[InputService DEBUG] BindAction failed: keybinds is not a table for action", actionName)
		end
		return false
	end

	local contextName, useContextAction = extractBindConfig(contextNameOrOptions, options)

	local tokens = {}
	local enumBinds = {}
	local count = 0

	for _, bind in ipairs(keybinds) do
		local token = enumToken(bind)
		if token ~= nil and tokens[token] == nil then
			tokens[token] = true
			table.insert(enumBinds, bind)
			count += 1
			if DEBUG_MODE then
				print(string.format("[InputService DEBUG] BindAction: Binding token '%s' to action '%s' in context '%s'", token, actionName, contextName))
			end
		elseif DEBUG_MODE and token == nil then
			print(string.format("[InputService DEBUG] BindAction: Invalid bind type: %s for action '%s'", tostring(bind), actionName))
		end
	end

	if count == 0 then
		if DEBUG_MODE then
			print(string.format("[InputService DEBUG] BindAction: No valid tokens for action '%s' in context '%s'", actionName, contextName))
		end
		return false
	end

	local existing = actionBindings[actionName]
	if existing ~= nil then
		if DEBUG_MODE then
			print(string.format("[InputService DEBUG] BindAction: Overwriting existing binding for action '%s'", actionName))
		end
		if existing.useContextAction then
			unbindContextAction(actionName)
		else
			removeActionFromTokenMap(actionName, existing.tokens)
		end
	end

	contextEnabled[contextName] = contextEnabled[contextName] ~= false
	actionBindings[actionName] = {
		tokens = tokens,
		context = contextName,
		useContextAction = useContextAction,
	}
	local state = ensureState(actionName)
	state.active = false
	state.lastAnalogValue = nil
	if useContextAction then
		bindContextAction(actionName, enumBinds)
	else
		addActionToTokenMap(actionName, tokens)
	end

	if DEBUG_MODE then
		print(string.format("[InputService DEBUG] BindAction: Bound action '%s' to tokens: {%s} in context '%s'", actionName, table.concat((function()
			local arr = {}
			for k in pairs(tokens) do
				table.insert(arr, k)
			end
			return arr
		end)(), ", "), contextName))
	end
	return true
end

function InputService:OnAction(actionName, callback)
	actionName = normalizeActionName(actionName)
	if typeof(callback) ~= "function" then
		return function() end
	end

	local listeners = actionListeners[actionName]
	if listeners == nil then
		listeners = {}
		actionListeners[actionName] = listeners
	end

	table.insert(listeners, callback)

	return function()
		local index = table.find(listeners, callback)
		if index then
			table.remove(listeners, index)
		end
	end
end

function InputService:IsActive(actionName)
	actionName = normalizeActionName(actionName)
	local state = actionStates[actionName]
	return state ~= nil and state.active or false
end

function InputService:GetLastPressedTime(actionName)
	actionName = normalizeActionName(actionName)
	local state = actionStates[actionName]
	if state == nil then
		return 0
	end

	return state.pressedAt
end

function InputService:WasPressedWithin(actionName, timeWindow)
	actionName = normalizeActionName(actionName)
	assert(typeof(timeWindow) == "number" and timeWindow >= 0, "timeWindow must be a non-negative number")

	local state = actionStates[actionName]
	if state == nil or state.pressedAt <= 0 then
		return false
	end

	return (os.clock() - state.pressedAt) <= timeWindow
end

function InputService:SetContextEnabled(contextName, isEnabled)
	contextName = normalizeContextName(contextName)
	assert(typeof(isEnabled) == "boolean", "isEnabled must be a boolean")
	contextEnabled[contextName] = isEnabled
	ensureActiveContext()
end

function InputService:GetActiveContext()
	return activeContext
end

function InputService:SetActiveContext(contextName)
	contextName = normalizeContextName(contextName)
	activeContext = contextName
	ensureActiveContext()
end

function InputService:SetInputLocked(isLocked)
	assert(typeof(isLocked) == "boolean", "isLocked must be a boolean")
	inputLocked = isLocked
end

function InputService:IsInputLocked()
	return inputLocked
end

return setmetatable({}, InputService)
