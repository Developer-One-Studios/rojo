--[[
	Shared helpers for letting several people sync into the same Team Create
	place at once.

	Everyone syncing runs their own `rojo serve` against their own copy of the
	project, and each of their plugins writes into the one shared DataModel.
	To keep people from silently overwriting each other, every plugin leaves a
	small amount of bookkeeping in the place under ServerStorage:

		__RojoTeamCreate (Folder)
			Sessions (Folder, not saved)  -- who is syncing right now
			Ledger (Folder)               -- who last synced each instance, and what
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Settings = require(script.Parent.Settings)

local TeamCreate = {}

TeamCreate.ROOT_NAME = "__RojoTeamCreate"

--[[
	Players only contains collaborators in edit mode when the place is open in
	Team Create, which makes it a cheap and reliable signal.
]]
function TeamCreate.isTeamCreateSession(): boolean
	return RunService:IsEdit() and #Players:GetPlayers() > 0
end

function TeamCreate.isEnabled(): boolean
	local mode = Settings:get("teamCreateMode")

	if mode == "Never" then
		return false
	elseif mode == "Always" then
		return RunService:IsEdit()
	end

	return TeamCreate.isTeamCreateSession()
end

local cachedUserNames = {}

function TeamCreate.getUserName(userId: number): string
	local cached = cachedUserNames[userId]
	if cached then
		return cached
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		cachedUserNames[userId] = player.Name
		return player.Name
	end

	local success, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if success and type(name) == "string" then
		cachedUserNames[userId] = name
		return name
	end

	return "User " .. tostring(userId)
end

function TeamCreate.getLocalUser(): { userId: number, userName: string }
	-- StudioService is only available to plugins, so it's fetched here rather
	-- than when this module loads, which keeps it usable from tests.
	local userId = game:GetService("StudioService"):GetUserId()

	return {
		userId = userId,
		userName = TeamCreate.getUserName(userId),
	}
end

--[[
	Milliseconds since the Unix epoch, according to the Team Create server.

	Collaborators' computer clocks can easily disagree by a minute or more, so
	comparing their local timestamps would make "who synced last" unreliable.
]]
function TeamCreate.now(): number
	local success, serverTime = pcall(workspace.GetServerTimeNow, workspace)
	if success and type(serverTime) == "number" and serverTime > 0 then
		return math.floor(serverTime * 1000)
	end

	return DateTime.now().UnixTimestampMillis
end

--[[
	Returns every bookkeeping folder in the place. There is normally only one,
	but two people connecting at the same moment can each create one before
	seeing the other's, so readers merge all of them.
]]
function TeamCreate.getRoots(): { Instance }
	local roots = {}

	for _, child in ServerStorage:GetChildren() do
		if TeamCreate.isInternalInstance(child) then
			table.insert(roots, child)
		end
	end

	return roots
end

function TeamCreate.getRoot(create: boolean?): Instance?
	local existing = ServerStorage:FindFirstChild(TeamCreate.ROOT_NAME)
	if existing ~= nil or not create then
		return existing
	end

	local root = Instance.new("Folder")
	root.Name = TeamCreate.ROOT_NAME
	root.Parent = ServerStorage

	return root
end

--[[
	Rojo must never treat its own bookkeeping as an unknown instance to delete,
	even when a project syncs ServerStorage from the filesystem.
]]
function TeamCreate.isInternalInstance(instance: Instance): boolean
	local success, isInternal = pcall(function()
		return instance.Name == TeamCreate.ROOT_NAME and instance.ClassName == "Folder"
	end)

	return success and isInternal
end

function TeamCreate.getOrCreateChild(parent: Instance, name: string, className: string, archivable: boolean?)
	local child = parent:FindFirstChild(name)
	if child ~= nil and child.ClassName == className then
		return child
	end

	child = Instance.new(className)
	child.Name = name
	if archivable == false then
		child.Archivable = false
	end
	child.Parent = parent

	return child
end

return TeamCreate
