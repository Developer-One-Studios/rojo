--[[
	Computes stable, human-readable paths for instances, such as
	"ReplicatedStorage/Shared/Util".

	Instance IDs are only meaningful to one person's Rojo server, so anything
	shared between teammates is keyed by path instead. A path is only useful if
	it identifies exactly one instance, so instances whose name is shared with
	a sibling get no path at all, and are left out of conflict tracking.

	A resolver caches what it learns, so create a new one for each patch.
]]

local PathResolver = {}
PathResolver.__index = PathResolver

local function escape(name: string): string
	return (string.gsub(name, "[%%/]", {
		["%"] = "%25",
		["/"] = "%2F",
	}))
end

function PathResolver.unescape(segment: string): string
	return (string.gsub(segment, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

--[[
	Splits a path into the names of each instance along it.
]]
function PathResolver.split(path: string): { string }
	local names = {}

	for segment in string.gmatch(path, "[^/]+") do
		table.insert(names, PathResolver.unescape(segment))
	end

	return names
end

function PathResolver.join(parentPath: string, name: string): string
	if parentPath == "" then
		return escape(name)
	end

	return parentPath .. "/" .. escape(name)
end

--[[
	Returns whether `path` is `ancestorPath` or is underneath it.
]]
function PathResolver.isWithin(path: string, ancestorPath: string): boolean
	if ancestorPath == "" or path == ancestorPath then
		return true
	end

	return string.sub(path, 1, #ancestorPath + 1) == ancestorPath .. "/"
end

--[[
	Returns the path of every ancestor of `path`, nearest first, not including
	the root.
]]
function PathResolver.ancestors(path: string): { string }
	local ancestors = {}

	local current = path
	while true do
		local parentPath = string.match(current, "^(.*)/[^/]*$")
		if parentPath == nil then
			break
		end

		table.insert(ancestors, parentPath)
		current = parentPath
	end

	return ancestors
end

--[[
	`added` is the `added` table of the patch being resolved, so that paths can
	also be found for instances that don't exist in the DataModel yet.

	`removed` is the `removed` list of the same patch. An instance being added
	in place of one that's being removed still gets a path.

	Paths are relative to `root`, which is the DataModel unless a test says
	otherwise.
]]
function PathResolver.new(instanceMap, added: { [string]: any }?, root: Instance?, removed: { any }?)
	local removedInstances = {}
	for _, target in removed or {} do
		local instance = if typeof(target) == "Instance" then target else instanceMap.fromIds[target]
		if instance ~= nil then
			removedInstances[instance] = true
		end
	end

	local self = {
		__instanceMap = instanceMap,
		__added = added or {},
		__removedInstances = removedInstances,
		__root = root or game,
		__instancePaths = {},
		__idPaths = {},
		__nameCounts = {},
		__addedNameCounts = nil,
	}

	return setmetatable(self, PathResolver)
end

function PathResolver:__countChildrenNamed(parent: Instance, name: string): number
	local counts = self.__nameCounts[parent]

	if counts == nil then
		counts = {}

		for _, child in parent:GetChildren() do
			-- Some children of the DataModel can't be read by plugins at all.
			local success, childName = pcall(function()
				return child.Name
			end)

			if success then
				counts[childName] = (counts[childName] or 0) + 1
			end
		end

		self.__nameCounts[parent] = counts
	end

	return counts[name] or 0
end

function PathResolver:__countAddedSiblingsNamed(parentId: string, name: string): number
	if self.__addedNameCounts == nil then
		local counts = {}

		for _, virtualInstance in self.__added do
			local parent = virtualInstance.Parent
			if parent ~= nil then
				counts[parent] = counts[parent] or {}
				counts[parent][virtualInstance.Name] = (counts[parent][virtualInstance.Name] or 0) + 1
			end
		end

		self.__addedNameCounts = counts
	end

	local siblingCounts = self.__addedNameCounts[parentId]
	return if siblingCounts then siblingCounts[name] or 0 else 0
end

-- Counts children with a name, leaving out any that the patch removes.
function PathResolver:__countRemainingChildrenNamed(parent: Instance, name: string): number
	local count = self:__countChildrenNamed(parent, name)

	if count > 0 and next(self.__removedInstances) ~= nil then
		for _, child in parent:GetChildren() do
			if self.__removedInstances[child] and child.Name == name then
				count -= 1
			end
		end
	end

	return count
end

--[[
	Returns the path of an instance in the DataModel, or nil if it isn't in the
	DataModel or doesn't have a unique path.
]]
function PathResolver:ofInstance(instance: Instance): string?
	if instance == self.__root then
		return ""
	end

	local cached = self.__instancePaths[instance]
	if cached ~= nil then
		return cached or nil
	end

	local path = nil

	local success, parent, name = pcall(function()
		return instance.Parent, instance.Name
	end)

	if success and parent ~= nil then
		local parentPath = self:ofInstance(parent)

		if parentPath ~= nil and self:__countChildrenNamed(parent, name) == 1 then
			path = PathResolver.join(parentPath, name)
		end
	end

	self.__instancePaths[instance] = path or false

	return path
end

--[[
	Returns the path of an instance by its Rojo ID, whether it already exists in
	the DataModel or is about to be added by the patch being resolved.
]]
function PathResolver:ofId(id: string): string?
	local cached = self.__idPaths[id]
	if cached ~= nil then
		return cached or nil
	end

	local path = nil
	local instance = self.__instanceMap.fromIds[id]

	if instance ~= nil then
		path = self:ofInstance(instance)
	else
		local virtualInstance = self.__added[id]

		if virtualInstance ~= nil and virtualInstance.Parent ~= nil then
			local parentPath = self:ofId(virtualInstance.Parent)
			local parentInstance = self.__instanceMap.fromIds[virtualInstance.Parent]

			local isUnique = self:__countAddedSiblingsNamed(virtualInstance.Parent, virtualInstance.Name) == 1
				and (
					parentInstance == nil
					or self:__countRemainingChildrenNamed(parentInstance, virtualInstance.Name) == 0
				)

			if parentPath ~= nil and isUnique then
				path = PathResolver.join(parentPath, virtualInstance.Name)
			end
		end
	end

	self.__idPaths[id] = path or false

	return path
end

--[[
	For an instance about to be added, finds an instance that's already in its
	place: the only child of its parent with the same name that this session
	isn't tracking. Returns that instance and its path.

	This is usually a teammate's version of the same file with a different
	class, like after renaming `foo.lua` to `foo.server.lua`.
]]
function PathResolver:findOccupant(id: string): (Instance?, string?)
	local virtualInstance = self.__added[id]
	if virtualInstance == nil then
		return nil, nil
	end

	local parent = self.__instanceMap.fromIds[virtualInstance.Parent]
	if parent == nil then
		return nil, nil
	end

	local occupant = nil
	for _, child in parent:GetChildren() do
		local success, name = pcall(function()
			return child.Name
		end)

		if
			success
			and name == virtualInstance.Name
			and self.__instanceMap.fromInstances[child] == nil
			and not self.__removedInstances[child]
		then
			if occupant ~= nil then
				-- More than one, so there's no telling which it replaces.
				return nil, nil
			end
			occupant = child
		end
	end

	if occupant == nil then
		return nil, nil
	end

	return occupant, self:ofInstance(occupant)
end

return PathResolver
