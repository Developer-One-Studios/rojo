--[[
	Changes from our files that are being held back because they would
	overwrite a teammate's newer work, until the user decides what to do.

	Changes are kept per instance: a newer held change to an instance merges
	into the older one, and a held change is dropped as soon as a later change
	to the same instance is applied normally (for example, once the user pulls
	their teammate's version, and their files match the place again).
]]

local HeldChanges = {}
HeldChanges.__index = HeldChanges

function HeldChanges.new()
	local self = {
		__entries = {},
	}

	return setmetatable(self, HeldChanges)
end

local function mergeUpdates(older, newer)
	local merged = {
		id = older.id,
		changedName = if newer.changedName ~= nil then newer.changedName else older.changedName,
		changedClassName = if newer.changedClassName ~= nil then newer.changedClassName else older.changedClassName,
		changedMetadata = if newer.changedMetadata ~= nil then newer.changedMetadata else older.changedMetadata,
		changedProperties = table.clone(older.changedProperties or {}),
	}

	for name, value in newer.changedProperties or {} do
		merged.changedProperties[name] = value
	end

	return merged
end

function HeldChanges:hold(heldPatch, conflicts)
	local conflictsByTarget = {}
	for _, conflict in conflicts do
		conflictsByTarget[conflict.target] = conflict
	end

	for _, target in heldPatch.removed do
		self.__entries[target] = {
			kind = "remove",
			target = target,
			conflict = conflictsByTarget[target],
		}
	end

	for id, virtualInstance in heldPatch.added do
		if heldPatch.added[virtualInstance.Parent] ~= nil then
			continue
		end

		local subtree = {}
		local function collect(subtreeId)
			subtree[subtreeId] = heldPatch.added[subtreeId]
			for _, childId in heldPatch.added[subtreeId].Children do
				collect(childId)
			end
		end
		collect(id)

		self.__entries[id] = {
			kind = "add",
			subtree = subtree,
			conflict = conflictsByTarget[id],
		}
	end

	for _, update in heldPatch.updated do
		local existing = self.__entries[update.id]

		if existing ~= nil and existing.kind == "update" then
			existing.update = mergeUpdates(existing.update, update)
			existing.conflict = conflictsByTarget[update.id] or existing.conflict
		else
			self.__entries[update.id] = {
				kind = "update",
				update = mergeUpdates(update, update),
				conflict = conflictsByTarget[update.id],
			}
		end
	end
end

--[[
	Forgets held changes that were superseded by the given applied patch.
]]
function HeldChanges:release(appliedPatch)
	for _, target in appliedPatch.removed do
		self.__entries[target] = nil
	end

	for id in appliedPatch.added do
		self.__entries[id] = nil
	end

	for _, update in appliedPatch.updated do
		self.__entries[update.id] = nil
	end
end

function HeldChanges:isEmpty(): boolean
	return next(self.__entries) == nil
end

function HeldChanges:getConflicts()
	local conflicts = {}

	for _, entry in self.__entries do
		if entry.conflict ~= nil then
			table.insert(conflicts, entry.conflict)
		end
	end

	table.sort(conflicts, function(a, b)
		return a.path < b.path
	end)

	return conflicts
end

--[[
	Returns every held change as a single patch, and stops holding them.
]]
function HeldChanges:take()
	local patch = {
		removed = {},
		added = {},
		updated = {},
	}

	for _, entry in self.__entries do
		if entry.kind == "remove" then
			table.insert(patch.removed, entry.target)
		elseif entry.kind == "add" then
			for id, virtualInstance in entry.subtree do
				patch.added[id] = virtualInstance
			end
		elseif entry.kind == "update" then
			table.insert(patch.updated, entry.update)
		end
	end

	self:clear()

	return patch
end

function HeldChanges:clear()
	table.clear(self.__entries)
end

return HeldChanges
