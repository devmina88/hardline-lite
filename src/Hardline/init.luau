-- Hardline v1.0
-- Server-side security for your Roblox game logic.
-- Validates every remote call before your code runs, tracks strikes per player,
-- audits unprotected remotes, watches your economy and sets honeypot traps.
--
-- Editions: Lite ships with Audit only. Pro adds Learn, Watch, Honeypots and Economy.
-- Same code for both: Pro features are enabled when their modules are present.

local Players = game:GetService("Players")

local PRO_URL = "https://builtbybit.com" -- TODO: replace with the Hardline Pro listing URL

local function optionalRequire(name: string): any
	local module = script:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		return require(module)
	end
	return nil
end

local Audit = require(script.Audit)
local Watch = optionalRequire("Watch")
local Honeypots = optionalRequire("Honeypots")
local Learn = optionalRequire("Learn")
local Economy = optionalRequire("Economy")

local Hardline = {}
Hardline.VERSION = "1.0.0"
Hardline.EDITION = if Watch and Honeypots and Learn and Economy then "Pro" else "Lite"

-- Features your game logic depends on (Watch, Economy) stop with an error in Lite,
-- so nothing silently stops working. Optional extras (Honeypots, Learn) only warn.
local function requirePro(feature: string)
	error(`[Hardline] {feature} is a Hardline Pro feature. Get it at {PRO_URL}`, 3)
end

local function warnPro(feature: string)
	warn(`[Hardline] {feature} is a Hardline Pro feature and was skipped. Get it at {PRO_URL}`)
end

export type Validator = (value: any) -> (boolean, string?)

-- Settings (change them with Hardline.configure) ------------------------

local settings = {
	strikeWindow = 60, -- seconds a strike is remembered
	kickAt = 0, -- strikes inside the window that trigger a kick (0 = log only, never kick)
	kickMessage = "Disconnected: unusual activity detected.",
	onStrike = nil :: ((player: Player, reason: string, strikes: number) -> ())?,
	autoAudit = true, -- print an audit report shortly after the server starts
	auditDelay = 5, -- seconds to wait before the first automatic audit
	followUpAuditDelay = 30, -- seconds after the first player joins before the second audit
	honeypotStrikes = 10, -- strikes for touching a honeypot (near-certain exploit)
}

function Hardline.configure(options: { [string]: any })
	for key, value in options do
		if settings[key] == nil and key ~= "onStrike" then
			warn(`[Hardline] Unknown setting: {key}`)
		else
			settings[key] = value
		end
	end
end

-- Strikes ------------------------------------------------------------

local strikeHistory: { [Player]: { number } } = {}

Players.PlayerRemoving:Connect(function(player)
	strikeHistory[player] = nil
end)

local function addStrikes(player: Player, reason: string, weight: number)
	local now = os.clock()
	local history: { number } = strikeHistory[player] or {}
	local recent = {}
	for _, t in ipairs(history) do
		if now - t < settings.strikeWindow then
			table.insert(recent, t)
		end
	end
	for _ = 1, weight do
		table.insert(recent, now)
	end
	strikeHistory[player] = recent

	local total = #recent
	warn(`[Hardline] {player.Name} ({player.UserId}): {reason} | strikes: {total}`)

	if settings.onStrike then
		task.spawn(settings.onStrike, player, reason, total)
	end

	if settings.kickAt > 0 and total >= settings.kickAt then
		player:Kick(settings.kickMessage)
	end
end

-- Report suspicious behavior detected by your own code
function Hardline.flag(player: Player, reason: string, weight: number?)
	addStrikes(player, reason, weight or 1)
end

-- Validators ---------------------------------------------------------

function Hardline.number(opts: { min: number?, max: number?, integer: boolean? }?): Validator
	local o = opts or {}
	return function(value)
		if typeof(value) ~= "number" then
			return false, "expected number, got " .. typeof(value)
		end
		if value ~= value or value == math.huge or value == -math.huge then
			return false, "number is NaN or infinite"
		end
		if o.integer and value % 1 ~= 0 then
			return false, "expected integer"
		end
		if o.min and value < o.min then
			return false, `below min {o.min}`
		end
		if o.max and value > o.max then
			return false, `above max {o.max}`
		end
		return true
	end
end

function Hardline.string(opts: { maxLength: number?, oneOf: { string }? }?): Validator
	local o = opts or {}
	return function(value)
		if typeof(value) ~= "string" then
			return false, "expected string, got " .. typeof(value)
		end
		if o.maxLength and #value > o.maxLength then
			return false, "string too long"
		end
		if o.oneOf and not table.find(o.oneOf, value) then
			return false, "value not allowed"
		end
		return true
	end
end

function Hardline.boolean(): Validator
	return function(value)
		if typeof(value) ~= "boolean" then
			return false, "expected boolean, got " .. typeof(value)
		end
		return true
	end
end

-- An Instance, optionally of a given class (uses IsA, so "BasePart" accepts any part)
function Hardline.instance(className: string?): Validator
	return function(value)
		if typeof(value) ~= "Instance" then
			return false, "expected Instance, got " .. typeof(value)
		end
		if className and not value:IsA(className) then
			return false, `expected {className}, got {value.ClassName}`
		end
		return true
	end
end

local function hasBadNumbers(...: number): boolean
	for i = 1, select("#", ...) do
		local n = select(i, ...)
		if n ~= n or n == math.huge or n == -math.huge then
			return true
		end
	end
	return false
end

-- A Vector3 without NaN/infinite values, optionally limited in length
function Hardline.vector3(opts: { maxMagnitude: number? }?): Validator
	local o = opts or {}
	return function(value)
		if typeof(value) ~= "Vector3" then
			return false, "expected Vector3, got " .. typeof(value)
		end
		if hasBadNumbers(value.X, value.Y, value.Z) then
			return false, "Vector3 has NaN or infinite values"
		end
		if o.maxMagnitude and value.Magnitude > o.maxMagnitude then
			return false, `Vector3 longer than {o.maxMagnitude}`
		end
		return true
	end
end

-- A CFrame without NaN/infinite values (a classic way to break physics or crash servers)
function Hardline.cframe(): Validator
	return function(value)
		if typeof(value) ~= "CFrame" then
			return false, "expected CFrame, got " .. typeof(value)
		end
		if hasBadNumbers(value:GetComponents()) then
			return false, "CFrame has NaN or infinite values"
		end
		return true
	end
end

-- A table where every key and value pass their validators
function Hardline.map(keyValidator: Validator, valueValidator: Validator, opts: { maxSize: number? }?): Validator
	local o = opts or {}
	return function(value)
		if typeof(value) ~= "table" then
			return false, "expected table, got " .. typeof(value)
		end
		local count = 0
		for k, v in value do
			count += 1
			if o.maxSize and count > o.maxSize then
				return false, `table has more than {o.maxSize} entries`
			end
			local ok, reason = keyValidator(k)
			if not ok then
				return false, "key: " .. tostring(reason)
			end
			ok, reason = valueValidator(v)
			if not ok then
				return false, "value: " .. tostring(reason)
			end
		end
		return true
	end
end

-- A list (keys 1..n with no gaps) where every item passes the validator
function Hardline.array(itemValidator: Validator, opts: { maxSize: number? }?): Validator
	local o = opts or {}
	return function(value)
		if typeof(value) ~= "table" then
			return false, "expected table, got " .. typeof(value)
		end
		local length = #value
		if o.maxSize and length > o.maxSize then
			return false, `list has more than {o.maxSize} items`
		end
		local count = 0
		for k in value do
			count += 1
			if typeof(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > length then
				return false, "not a list"
			end
		end
		if count ~= length then
			return false, "not a list"
		end
		for i = 1, length do
			local ok, reason = itemValidator(value[i])
			if not ok then
				return false, `item {i}: {reason}`
			end
		end
		return true
	end
end

-- Allows nil, otherwise the value must pass the validator
function Hardline.optional(validator: Validator): Validator
	return function(value)
		if value == nil then
			return true
		end
		return validator(value)
	end
end

-- Accepts anything. Use it for arguments your own code already validates.
function Hardline.any(): Validator
	return function()
		return true
	end
end

-- Remote protection ---------------------------------------------------

type Options = {
	args: { Validator }?,
	-- Whole-call check that receives (player, ...args) and returns (ok, reason?).
	-- Works with validators you already have, such as t.tuple(...) from the "t" library.
	validate: ((...any) -> (boolean, string?))?,
	rateLimit: { max: number, window: number }?,
}

local protectedRemotes: { [Instance]: boolean } = {}
local ignoredRemotes: { [Instance]: boolean } = {}
local honeypotRemotes: { [Instance]: boolean } = {}

-- Builds the check every call must pass. Returns true if the call is allowed.
local function makeGate(remote: Instance, options: Options)
	-- With only "validate", the argument count is left to your validator.
	-- With neither "args" nor "validate", the remote must receive no arguments.
	local validators = options.args
	if validators == nil and options.validate == nil then
		validators = {}
	end
	local callHistory: { [Player]: { number } } = {}

	Players.PlayerRemoving:Connect(function(player)
		callHistory[player] = nil
	end)

	return function(player: Player, ...): boolean
		if validators then
			-- 1. Too many arguments: the real client never does this -> strong signal.
			--    Missing trailing arguments arrive as nil, so only Hardline.optional(...) accepts them.
			local count = select("#", ...)
			if count > #validators then
				addStrikes(player, `{remote.Name}: expected at most {#validators} args, got {count}`, 3)
				return false
			end

			-- 2. Invalid argument: also a strong signal
			local args = table.pack(...)
			for i, validate in ipairs(validators) do
				local ok, reason = validate(args[i])
				if not ok then
					addStrikes(player, `{remote.Name}: arg {i}: {reason}`, 3)
					return false
				end
			end
		end

		-- 3. Your own whole-call validation
		if options.validate then
			local success, ok, reason = pcall(options.validate, player, ...)
			if not success then
				-- A bug in the validator is not the player's fault: reject without strikes
				warn(`[Hardline] {remote.Name}: your validate function errored: {ok}`)
				return false
			end
			if not ok then
				addStrikes(player, `{remote.Name}: {reason or "validation failed"}`, 3)
				return false
			end
		end

		-- 4. Rate limit: extra valid calls are dropped silently, never punished
		if options.rateLimit then
			local now = os.clock()
			local history: { number } = callHistory[player] or {}
			local recent = {}
			for _, t in ipairs(history) do
				if now - t < options.rateLimit.window then
					table.insert(recent, t)
				end
			end
			if #recent >= options.rateLimit.max then
				callHistory[player] = recent
				return false
			end
			table.insert(recent, now)
			callHistory[player] = recent
		end

		return true
	end
end

-- Warn once when a remote is both ignored and handled by the server:
-- "ignore" is meant for server-to-client remotes only.
local warnedIgnoredAndProtected: { [Instance]: boolean } = {}
local function checkIgnoredAndProtected(remote: Instance)
	if ignoredRemotes[remote] and protectedRemotes[remote] and not warnedIgnoredAndProtected[remote] then
		warnedIgnoredAndProtected[remote] = true
		warn(
			`[Hardline] {remote:GetFullName()} is marked with Hardline.ignore, but your server listens to it. `
				.. "It is protected, but remove the ignore: it's only for server-to-client remotes."
		)
	end
end

-- Protect a RemoteEvent (or UnreliableRemoteEvent)
function Hardline.connect(remote: Instance, options: Options, handler: (Player, ...any) -> ())
	local gate = makeGate(remote, options)
	protectedRemotes[remote] = true
	checkIgnoredAndProtected(remote)

	return (remote :: any).OnServerEvent:Connect(function(player: Player, ...)
		if gate(player, ...) then
			handler(player, ...)
		end
	end)
end

-- Protect a RemoteFunction. Rejected calls return nil to the client.
function Hardline.connectFunction(remote: RemoteFunction, options: Options, handler: (Player, ...any) -> ...any)
	local gate = makeGate(remote, options)
	protectedRemotes[remote] = true
	checkIgnoredAndProtected(remote)

	remote.OnServerInvoke = function(player: Player, ...)
		if gate(player, ...) then
			return handler(player, ...)
		end
		return nil
	end
end

-- Mark a remote that only sends data server -> client, so the Audit skips it
function Hardline.ignore(remote: Instance)
	ignoredRemotes[remote] = true
	checkIgnoredAndProtected(remote)
end

-- Audit ---------------------------------------------------------------

local function classify(remote: Instance): Audit.Status
	if honeypotRemotes[remote] then
		return "honeypot"
	elseif protectedRemotes[remote] then
		return "protected"
	elseif ignoredRemotes[remote] then
		return "ignored"
	end
	return "unprotected"
end

local lastAuditSummary: string? = nil

local function summarize(report: Audit.Report): string
	local names = {}
	for _, remote in ipairs(report.unprotected) do
		table.insert(names, remote:GetFullName())
	end
	table.sort(names)
	return `{report.total}|{#report.protected}|{#report.ignored}|` .. table.concat(names, ",")
end

local LITE_TIP = `  Tip: Hardline Pro's learning mode writes this protection for you. {PRO_URL}`

local function printReport(report: Audit.Report)
	local tip = if Hardline.EDITION == "Lite" and #report.unprotected > 0 then LITE_TIP else nil
	Audit.print(report, tip)
end

-- Runs the audit, prints the report and returns it
function Hardline.audit(): Audit.Report
	local report = Audit.run(classify)
	printReport(report)
	lastAuditSummary = summarize(report)
	return report
end

-- Automatic audits only print when something changed since the last report
local function autoAudit()
	if not settings.autoAudit then
		return
	end
	local report = Audit.run(classify)
	local summary = summarize(report)
	if summary ~= lastAuditSummary then
		printReport(report)
		lastAuditSummary = summary
	end
end

-- 1st automatic audit: shortly after the server starts
task.defer(function()
	task.wait(settings.auditDelay)
	autoAudit()
end)

-- 2nd automatic audit: after the first player has been in the game for a while.
-- Many games only connect some remotes once a player's data or map has loaded.
local followUpScheduled = false
local function scheduleFollowUpAudit()
	if followUpScheduled then
		return
	end
	followUpScheduled = true
	task.delay(settings.followUpAuditDelay, autoAudit)
end

Players.PlayerAdded:Connect(scheduleFollowUpAudit)
if #Players:GetPlayers() > 0 then
	scheduleFollowUpAudit()
end

-- Learn (Pro) -----------------------------------------------------------

local learning = nil

-- Watch unprotected remotes while you play and print suggested protection.
-- Use it while testing, not in a live game. Returns an object with report().
function Hardline.learn(config: { [string]: any }?)
	if not Learn then
		warnPro("Learning mode (Hardline.learn)")
		return { report = function() end }
	end
	if learning then
		return learning
	end
	learning = Learn.start(config or {}, classify, function()
		return Audit.run(classify).unprotected
	end)
	return learning
end

-- Economy watch (Pro) ---------------------------------------------------

function Hardline.watch(config: { [string]: any })
	if not Watch then
		requirePro("Watch (Hardline.watch)")
	end
	return Watch.new(config, addStrikes)
end

-- Honeypots (Pro) -------------------------------------------------------

function Hardline.honeypots(config: { [string]: any }?): { Instance }
	if not Honeypots then
		warnPro("Honeypots (Hardline.honeypots)")
		return {}
	end
	local created = Honeypots.create(config or {}, function(player, name)
		addStrikes(player, `honeypot triggered: {name}`, settings.honeypotStrikes)
	end)
	for _, remote in ipairs(created) do
		honeypotRemotes[remote] = true
	end
	return created
end

-- Economy (Pro) ---------------------------------------------------------

Hardline.Economy = Economy
	or {
		new = function()
			requirePro("Economy (Hardline.Economy)")
		end,
	}

-- Startup line, so you always know which version and edition is running
print(`[Hardline] v{Hardline.VERSION} {Hardline.EDITION} loaded`)

return Hardline
