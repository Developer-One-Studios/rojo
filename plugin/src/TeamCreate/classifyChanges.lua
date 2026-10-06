--[[
	Splits a patch into changes that are safe to apply to a Team Create place,
	and changes that would throw away something a teammate synced more recently.

	A change conflicts when the newest ledger record for its path belongs to
	someone else, and it's for different content than the newest record of our
	own (if we've already synced or seen their version, we're up to date with
	it), and:

	- update: they synced different content than our files now have. Either
	  our files are behind theirs, or we both changed it.
	- add: they removed it, so our files are probably just behind theirs. Or
	  something they synced already has its name, like their version of the
	  same file with a different class; adding ours would leave both.
	- remove: they synced it, or something inside it. It's probably new and our
	  files just don't have it yet.

	Anything without a teammate's record is safe, which keeps the behavior of
	regular Rojo for everything nobody else has touched.
]]

local Types = require(script.Parent.Parent.Types)
local PatchSet = require(script.Parent.Parent.PatchSet)
local PathResolver = require(script.Parent.PathResolver)

export type Conflict = {
	kind: "update" | "add" | "remove",
	path: string,
	userId: number,
	time: number,
	-- The ID or instance the change applies to.
	target: any,
}

local function classifyChanges(
	options: {
		patch: any,
		resolver: any,
		fingerprints: { [string]: string },
		-- The newest record for each path, from anyone.
		records: { [string]: any },
		-- The newest record for each path that the current user wrote.
		ownRecords: { [string]: any }?,
		userId: number,
	}
)
	local patch = options.patch
	local resolver = options.resolver
	local records = options.records
	local ownRecords = options.ownRecords or {}
	local userId = options.userId

	-- Returns whether a teammate's record is for content that we've already
	-- synced or seen ourselves, in which case our changes build on theirs.
	local function alreadySeen(path: string, record): boolean
		local own = ownRecords[path]
		return own ~= nil and own.fingerprint == record.fingerprint
	end

	local safe = PatchSet.newEmpty()
	local held = PatchSet.newEmpty()
	local conflicts: { Conflict } = {}

	local function teammateRecord(path: string?)
		if path == nil or path == "" then
			return nil
		end

		local record = records[path]
		if record ~= nil and record.userId ~= userId and not alreadySeen(path, record) then
			return record
		end

		return nil
	end

	local function addConflict(kind, path, record, target)
		table.insert(conflicts, {
			kind = kind,
			path = path,
			userId = record.userId,
			time = record.time,
			target = target,
		})
	end

	-- For removals we need to know about teammates' work anywhere inside the
	-- removed instance, not just on the instance itself.
	local teammateWritesWithin = nil
	local function newestTeammateWriteWithin(path: string)
		if teammateWritesWithin == nil then
			teammateWritesWithin = {}

			for recordPath, record in records do
				if record.userId == userId or record.fingerprint == false or alreadySeen(recordPath, record) then
					continue
				end

				local affected = PathResolver.ancestors(recordPath)
				table.insert(affected, recordPath)

				for _, affectedPath in affected do
					local existing = teammateWritesWithin[affectedPath]
					if existing == nil or record.time > existing.time then
						teammateWritesWithin[affectedPath] = record
					end
				end
			end
		end

		return teammateWritesWithin[path]
	end

	for _, idOrInstance in patch.removed do
		local path = if Types.RbxId(idOrInstance)
			then resolver:ofId(idOrInstance)
			else resolver:ofInstance(idOrInstance)

		local record = if path ~= nil and path ~= "" then newestTeammateWriteWithin(path) else nil

		if record ~= nil then
			table.insert(held.removed, idOrInstance)
			addConflict("remove", path, record, idOrInstance)
		else
			table.insert(safe.removed, idOrInstance)
		end
	end

	-- Additions are decided per added subtree: descendants always go wherever
	-- the topmost added instance goes.
	local subtreeIsHeld = {}
	local function isHeld(id: string): boolean
		local rootId = id
		while patch.added[patch.added[rootId].Parent] ~= nil do
			rootId = patch.added[rootId].Parent
		end

		local decision = subtreeIsHeld[rootId]
		if decision == nil then
			local path = resolver:ofId(rootId)
			local record = teammateRecord(path)
			decision = false

			if record ~= nil and record.fingerprint == false then
				decision = true
				addConflict("add", path, record, rootId)
			elseif path == nil then
				-- The name is already taken, perhaps by a teammate's version of
				-- this instance with a different class.
				local occupant, occupantPath = resolver:findOccupant(rootId)
				local occupantRecord = teammateRecord(occupantPath)

				if
					occupant ~= nil
					and occupantRecord ~= nil
					and type(occupantRecord.fingerprint) == "string"
					and occupantRecord.fingerprint ~= options.fingerprints[rootId]
				then
					decision = true

					-- Overwriting their version means replacing it, not adding
					-- ours next to it.
					table.insert(held.removed, occupant)
					addConflict("update", occupantPath, occupantRecord, rootId)
				end
			end

			subtreeIsHeld[rootId] = decision
		end

		return decision
	end

	for id, virtualInstance in patch.added do
		if isHeld(id) then
			held.added[id] = virtualInstance
		else
			safe.added[id] = virtualInstance
		end
	end

	for _, update in patch.updated do
		local path = resolver:ofId(update.id)
		local record = teammateRecord(path)

		if
			record ~= nil
			and type(record.fingerprint) == "string"
			and record.fingerprint ~= options.fingerprints[update.id]
		then
			table.insert(held.updated, update)
			addConflict("update", path, record, update.id)
		else
			table.insert(safe.updated, update)
		end
	end

	table.sort(conflicts, function(a, b)
		return a.path < b.path
	end)

	return {
		safe = safe,
		held = held,
		conflicts = conflicts,
	}
end

return classifyChanges
