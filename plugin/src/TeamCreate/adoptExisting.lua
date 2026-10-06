--[[
	Before adding instances, checks whether a teammate already created them.

	When two people sync the same new file, for example after both pulling the
	same commit, the second person's Rojo would otherwise create a duplicate
	next to the first person's copy. Duplicate scripts both run, so instead we
	take over the existing instance and only apply whatever differs.

	Mutates `patch` in place, and returns the IDs of every instance that was
	matched to an existing one.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Log = require(Packages.Log)

local TeamCreate = require(script.Parent)

local function findUnclaimedMatch(instanceMap, parent: Instance, virtualInstance): Instance?
	for _, child in parent:GetChildren() do
		local success, matches = pcall(function()
			return child.Name == virtualInstance.Name and child.ClassName == virtualInstance.ClassName
		end)

		if
			success
			and matches
			and instanceMap.fromInstances[child] == nil
			and not TeamCreate.isInternalInstance(child)
		then
			return child
		end
	end

	return nil
end

local function removeSubtree(added, id: string)
	local virtualInstance = added[id]
	if virtualInstance == nil then
		return
	end

	added[id] = nil
	for _, childId in virtualInstance.Children do
		removeSubtree(added, childId)
	end
end

local function adoptExisting(reconciler, instanceMap, patch): { string }
	-- Only the topmost instance of each added subtree needs a parent that
	-- already exists. Collect them first since we modify `patch.added`.
	local rootIds = {}
	for id, virtualInstance in patch.added do
		if patch.added[virtualInstance.Parent] == nil then
			table.insert(rootIds, id)
		end
	end

	local adoptedIds = {}

	for _, id in rootIds do
		local virtualInstance = patch.added[id]
		local parent = instanceMap.fromIds[virtualInstance.Parent]
		if parent == nil then
			continue
		end

		local existing = findUnclaimedMatch(instanceMap, parent, virtualInstance)
		if existing == nil then
			continue
		end

		Log.debug("Adopting existing instance {} instead of creating a duplicate", existing:GetFullName())

		-- Hydrate maps the existing instance and any matching descendants to
		-- the server's IDs, then diff works out what's still different. The
		-- virtual instances are read from the patch, so do that before
		-- removing them from it.
		local subtree = {}
		local function collect(subtreeId)
			subtree[subtreeId] = patch.added[subtreeId]
			for _, childId in patch.added[subtreeId].Children do
				collect(childId)
			end
		end
		collect(id)

		reconciler:hydrate(subtree, id, existing)
		local success, subPatch = reconciler:diff(subtree, id)

		for subtreeId in subtree do
			if instanceMap.fromIds[subtreeId] ~= nil then
				table.insert(adoptedIds, subtreeId)
			end
		end

		removeSubtree(patch.added, id)

		if not success then
			Log.warn("Could not compare {} with its server version: {}", existing:GetFullName(), subPatch)
			continue
		end

		for _, removed in subPatch.removed do
			table.insert(patch.removed, removed)
		end
		for addedId, addedInstance in subPatch.added do
			patch.added[addedId] = addedInstance
		end
		for _, update in subPatch.updated do
			table.insert(patch.updated, update)
		end
	end

	return adoptedIds
end

return adoptExisting
