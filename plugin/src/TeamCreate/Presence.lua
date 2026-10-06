--[[
	Lets everyone in a Team Create place see who else is syncing with Rojo.

	While connected, each plugin keeps an entry with a regular heartbeat under
	the Sessions folder. Entries aren't Archivable, so they're never saved with
	the place, and entries whose heartbeat stops or whose owner has left the
	place are ignored.

	Unmodified Rojo plugins don't know how to sync alongside other people, and
	only stay out of a place while someone holds their session lock. So while
	anyone is syncing with this plugin, one of them holds that lock.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local Packages = script.Parent.Parent.Parent.Packages
local Log = require(Packages.Log)

local TeamCreate = require(script.Parent)

export type Session = {
	userId: number,
	userName: string,
	projectName: string?,
	startedAt: number?,
	-- True for someone holding the session lock of an unmodified Rojo
	-- plugin, which doesn't know how to avoid overwriting other people.
	legacy: boolean,
}

local Presence = {}
Presence.__index = Presence

Presence.FOLDER_NAME = "Sessions"
Presence.LEGACY_LOCK_NAME = "__Rojo_SessionLock"
Presence.HEARTBEAT_INTERVAL = 10
Presence.POLL_INTERVAL = 3
Presence.STALE_AFTER = 45 * 1000

function Presence.new(options: { userId: number, userName: string, root: Instance? })
	local self = {
		__userId = options.userId,
		__userName = options.userName,
		__root = options.root,
		__entry = nil,
		__threads = {},
		__listeners = {},
		__lastSignature = nil,
		__others = {},
	}

	return setmetatable(self, Presence)
end

function Presence:__roots(): { Instance }
	if self.__root ~= nil then
		return { self.__root }
	end

	return TeamCreate.getRoots()
end

function Presence:__sessionsFolder(): Instance
	return TeamCreate.getOrCreateChild(self.__root or TeamCreate.getRoot(true), Presence.FOLDER_NAME, "Folder", false)
end

function Presence:__createEntry(sessions: Instance)
	local entry = sessions:FindFirstChild(tostring(self.__userId))
	if entry == nil then
		entry = Instance.new("Configuration")
		entry.Name = tostring(self.__userId)
		entry.Archivable = false
	end

	entry:SetAttribute("UserId", self.__userId)
	entry:SetAttribute("UserName", self.__userName)
	entry:SetAttribute("ProjectName", self.__projectName)
	entry:SetAttribute("StartedAt", self.__startedAt)
	entry:SetAttribute("Heartbeat", TeamCreate.now())
	entry.Parent = sessions

	self.__entry = entry
end

--[[
	Makes sure our entry is in the place and up to date.

	It may have been taken out: a teammate may have tidied it up while our
	Studio was frozen for long enough to look stale, or undoing the patch that
	created the bookkeeping folder may have removed the folder around it.
]]
function Presence:__heartbeat()
	local sessions = self:__sessionsFolder()
	local entry = self.__entry

	local moved = entry ~= nil
		and pcall(function()
			if entry.Parent ~= sessions then
				entry.Parent = sessions
			end
		end)

	if moved then
		entry:SetAttribute("Heartbeat", TeamCreate.now())
	else
		-- A destroyed entry can't be put back, so make a new one.
		self:__createEntry(sessions)
	end

	self:__claimLegacyLock()
end

-- Only the real place has a lock to hold, not tests' stand-in folders.
function Presence:__usesLegacyLock(): boolean
	return self.__root == nil and Players.LocalPlayer ~= nil
end

function Presence:__claimLegacyLock()
	if not self:__usesLegacyLock() then
		return
	end

	local lock = ServerStorage:FindFirstChild(Presence.LEGACY_LOCK_NAME)
	if lock == nil then
		lock = Instance.new("ObjectValue")
		lock.Name = Presence.LEGACY_LOCK_NAME
		lock.Archivable = false
		lock.Value = Players.LocalPlayer
		lock.Parent = ServerStorage
		return
	end

	if not lock:IsA("ObjectValue") then
		return
	end

	-- Any teammate syncing with this plugin can hold the lock for everyone.
	-- Only take it over when nobody in the place has it.
	local owner = lock.Value
	if owner == nil or owner.Parent == nil then
		lock.Value = Players.LocalPlayer
	end
end

function Presence:__releaseLegacyLock()
	if not self:__usesLegacyLock() then
		return
	end

	local lock = ServerStorage:FindFirstChild(Presence.LEGACY_LOCK_NAME)
	if lock ~= nil and lock:IsA("ObjectValue") and lock.Value == Players.LocalPlayer then
		-- Teammates still syncing take it back on their next heartbeat.
		lock.Value = nil
	end
end

function Presence:start(info: { projectName: string })
	self:stop()

	self.__projectName = info.projectName
	self.__startedAt = TeamCreate.now()
	self:__createEntry(self:__sessionsFolder())
	self:__claimLegacyLock()

	table.insert(
		self.__threads,
		task.spawn(function()
			while true do
				task.wait(Presence.HEARTBEAT_INTERVAL)

				local success, err = pcall(self.__heartbeat, self)
				if not success then
					Log.debug("Could not update Rojo Team Create session entry: {}", err)
				end
			end
		end)
	)

	table.insert(
		self.__threads,
		task.spawn(function()
			while true do
				self:__refresh()
				task.wait(Presence.POLL_INTERVAL)
			end
		end)
	)
end

function Presence:stop()
	for _, thread in self.__threads do
		pcall(task.cancel, thread)
	end
	table.clear(self.__threads)

	if self.__entry ~= nil then
		pcall(function()
			self.__entry:Destroy()
		end)
		self.__entry = nil
		pcall(self.__releaseLegacyLock, self)
	end

	self.__lastSignature = nil
	self.__others = {}
end

local function isInPlace(userId: number): boolean
	-- Outside Team Create there are no players to check against.
	if #Players:GetPlayers() == 0 then
		return true
	end

	return Players:GetPlayerByUserId(userId) ~= nil
end

--[[
	Returns everyone else who is currently syncing into this place.
]]
function Presence:getOthers(): { Session }
	local others = {}
	local seen = {}
	local now = TeamCreate.now()

	for _, root in self:__roots() do
		local sessions = root:FindFirstChild(Presence.FOLDER_NAME)
		if sessions == nil then
			continue
		end

		for _, entry in sessions:GetChildren() do
			local userId = entry:GetAttribute("UserId")
			if type(userId) ~= "number" or userId == self.__userId or seen[userId] then
				continue
			end

			if not isInPlace(userId) then
				-- They left without disconnecting (for example, Studio
				-- crashed), so tidy up after them. This removes the entry
				-- rather than destroying it, so that if we're wrong, their
				-- plugin can put it back.
				pcall(function()
					entry.Parent = nil
				end)
				continue
			end

			local heartbeat = entry:GetAttribute("Heartbeat")
			if type(heartbeat) ~= "number" or now - heartbeat > Presence.STALE_AFTER then
				continue
			end

			seen[userId] = true
			table.insert(others, {
				userId = userId,
				userName = entry:GetAttribute("UserName") or TeamCreate.getUserName(userId),
				projectName = entry:GetAttribute("ProjectName"),
				startedAt = entry:GetAttribute("StartedAt"),
				legacy = false,
			})
		end
	end

	-- Unmodified Rojo plugins claim a lock instead. While we're syncing we
	-- hold it so they can't connect, but one may have connected before us.
	-- Someone holding it who has a session entry is one of us.
	local lock = ServerStorage:FindFirstChild(Presence.LEGACY_LOCK_NAME)
	if lock ~= nil and lock:IsA("ObjectValue") then
		local owner = lock.Value
		if owner ~= nil and owner:IsA("Player") and owner.Parent ~= nil then
			local userId = owner.UserId
			if userId ~= self.__userId and not seen[userId] then
				table.insert(others, {
					userId = userId,
					userName = owner.Name,
					projectName = nil,
					startedAt = nil,
					legacy = true,
				})
			end
		end
	end

	table.sort(others, function(a, b)
		return a.userName < b.userName
	end)

	return others
end

function Presence:onChanged(callback: (others: { Session }, previous: { Session }) -> ())
	self.__listeners[callback] = true

	return function()
		self.__listeners[callback] = nil
	end
end

function Presence:__refresh()
	local others = self:getOthers()

	local parts = {}
	for _, session in others do
		table.insert(
			parts,
			string.format("%d:%s:%s", session.userId, tostring(session.projectName), tostring(session.legacy))
		)
	end
	local signature = table.concat(parts, "|")

	if signature == self.__lastSignature then
		return
	end

	local previous = self.__others
	self.__lastSignature = signature
	self.__others = others

	for callback in self.__listeners do
		task.spawn(callback, others, previous)
	end
end

return Presence
