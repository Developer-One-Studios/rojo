--[[
	Coordinates one person's sync session with everyone else syncing into the
	same Team Create place.

	A ServeSession runs every patch through `prepare`, which may wait on the
	server, then `finalize` immediately before applying it, and `commit`
	afterwards. Along the way, the Coordinator:

	- brings back instances a teammate removed if we're still changing them,
	- takes over instances a teammate already created instead of duplicating
	  them,
	- holds back changes that would overwrite a teammate's newer work, and
	- records what we synced in the ledger, so teammates can do the same for us.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Log = require(Packages.Log)

local PatchSet = require(script.Parent.Parent.PatchSet)
local Settings = require(script.Parent.Parent.Settings)
local HeldChanges = require(script.Parent.HeldChanges)
local Ledger = require(script.Parent.Ledger)
local PathResolver = require(script.Parent.PathResolver)
local adoptExisting = require(script.Parent.adoptExisting)
local classifyChanges = require(script.Parent.classifyChanges)

-- How many IDs to ask the server to fingerprint per request.
local FINGERPRINT_BATCH_SIZE = 2000

-- How long to wait after adding instances before checking whether a teammate
-- added the same ones at the same moment. Their copy and their ledger record
-- both have to reach us first, so we check a few times.
local DUPLICATE_CHECK_DELAYS = { 3, 10, 30 }

-- How many times `prepare` checks for instances a teammate removed while it
-- was waiting on the server.
local MAX_PREPARE_PASSES = 3

local Coordinator = {}
Coordinator.__index = Coordinator

function Coordinator.new(
	options: {
		apiContext: any,
		instanceMap: any,
		reconciler: any,
		userId: number,
		userName: string,
		root: Instance?,
		conflictBehavior: string?,
		-- Applies a patch through the owning session.
		applyPatch: (patch: any, options: any?) -> (),
		-- Applies a patch after any patches currently being applied.
		queuePatch: (patch: any, options: any?) -> (),
		-- Runs a function after any patches currently being applied.
		queueJob: (job: () -> ()) -> (),
		-- Tells the owning session about held back changes.
		onConflicts: (conflicts: { any }, details: { [string]: any }) -> (),
	}
)
	local self = {
		userId = options.userId,
		userName = options.userName,
		ledger = Ledger.new({
			userId = options.userId,
			userName = options.userName,
			root = options.root,
		}),

		__apiContext = options.apiContext,
		__instanceMap = options.instanceMap,
		__reconciler = options.reconciler,
		__conflictBehavior = options.conflictBehavior,
		__applyPatch = options.applyPatch,
		__queuePatch = options.queuePatch,
		__queueJob = options.queueJob,
		__onConflicts = options.onConflicts,
		__held = HeldChanges.new(),
		__active = true,
	}

	return setmetatable(self, Coordinator)
end

function Coordinator:stop()
	self.__active = false
	self.__held:clear()
end

function Coordinator:getConflictBehavior(): string
	return self.__conflictBehavior or Settings:get("teamCreateConflictBehavior")
end

--[[
	Returns whether the server can fingerprint instances. Servers without it
	are regular Rojo builds, which can't sync safely alongside teammates.
]]
function Coordinator:isServerSupported(rootId: string): boolean
	return (self.__apiContext:fingerprints({ rootId }):await())
end

--[[
	Gets the place ready for this session. Must run before the first patch is
	applied, outside of its ChangeHistory recording.
]]
function Coordinator:start()
	self.ledger:ensureFolders()
end

function Coordinator:getHeldConflicts()
	return self.__held:getConflicts()
end

--[[
	Returns every held change as a patch and stops holding them.
]]
function Coordinator:takeHeldChanges()
	return self.__held:take()
end

function Coordinator:discardHeldChanges()
	self.__held:clear()
end

function Coordinator:__fetchFingerprints(ids: { string }): { [string]: string }
	local fingerprints = {}

	for start = 1, #ids, FINGERPRINT_BATCH_SIZE do
		local batch = table.move(ids, start, math.min(start + FINGERPRINT_BATCH_SIZE - 1, #ids), 1, {})
		local success, result = self.__apiContext:fingerprints(batch):await()

		if success then
			for id, fingerprint in result do
				fingerprints[id] = fingerprint
			end
		else
			-- Without a fingerprint, an update to something a teammate
			-- synced is treated as a conflict, which is the safe side.
			Log.warn("Could not fetch fingerprints from the Rojo server: {}", result)
		end
	end

	return fingerprints
end

function Coordinator:__fetchPatchFingerprints(patch): { [string]: string }
	local ids = {}
	for id in patch.added do
		table.insert(ids, id)
	end
	for _, update in patch.updated do
		table.insert(ids, update.id)
	end

	return self:__fetchFingerprints(ids)
end

--[[
	When a teammate removes an instance, it disappears from our place too, but
	our InstanceMap still points at the removed copy. Changes to it would go
	nowhere, so instead we bring it back from the server as an addition. That
	addition then goes through the usual conflict checks, so if a teammate
	removed it on purpose, the user gets asked before it comes back.
]]
function Coordinator:__reviveRemovedInstances(patch)
	local instanceMap = self.__instanceMap
	local detachedRoots = self:__findDetachedRoots(patch)

	if next(detachedRoots) == nil then
		return
	end

	local ids = {}
	for id in detachedRoots do
		table.insert(ids, id)
	end

	local success, response = self.__apiContext:read(ids):await()
	if not success then
		Log.warn("Could not restore instances that were removed from the place: {}", response)
		return
	end

	for _, root in detachedRoots do
		for _, descendant in root:GetDescendants() do
			instanceMap:removeInstance(descendant)
		end
		instanceMap:removeInstance(root)
	end

	for id, virtualInstance in response.instances do
		patch.added[id] = virtualInstance
	end

	-- Updates to anything we're re-adding are already part of the addition.
	local remainingUpdates = {}
	for _, update in patch.updated do
		if response.instances[update.id] == nil then
			table.insert(remainingUpdates, update)
		end
	end
	patch.updated = remainingUpdates
end

local function isDetached(instance: Instance?): boolean
	return instance ~= nil and instance ~= game and not instance:IsDescendantOf(game)
end

--[[
	Finds instances the patch changes, or adds children to, that are no longer
	in the place. Returns the topmost removed instance for each, by ID.
]]
function Coordinator:__findDetachedRoots(patch): { [string]: Instance }
	local instanceMap = self.__instanceMap
	local detachedRoots = {}

	local function consider(instance)
		if not isDetached(instance) then
			return
		end

		local root = instance
		while root.Parent ~= nil do
			root = root.Parent
		end

		local rootId = instanceMap.fromInstances[root]
		if rootId ~= nil then
			detachedRoots[rootId] = root
		end
	end

	for _, update in patch.updated do
		consider(instanceMap.fromIds[update.id])
	end
	for _, virtualInstance in patch.added do
		if patch.added[virtualInstance.Parent] == nil then
			consider(instanceMap.fromIds[virtualInstance.Parent])
		end
	end

	return detachedRoots
end

--[[
	Moves changes to instances that are no longer in the place into a separate
	patch. Bringing those instances back means waiting on the server, which
	can't happen while finalizing, so they're applied by themselves afterwards.
]]
function Coordinator:__takeDetachedChanges(patch)
	if next(self:__findDetachedRoots(patch)) == nil then
		return nil
	end

	local instanceMap = self.__instanceMap
	local deferred = PatchSet.newEmpty()

	local remainingUpdates = {}
	for _, update in patch.updated do
		if isDetached(instanceMap.fromIds[update.id]) then
			table.insert(deferred.updated, update)
		else
			table.insert(remainingUpdates, update)
		end
	end
	patch.updated = remainingUpdates

	local detachedRootIds = {}
	for id, virtualInstance in patch.added do
		if patch.added[virtualInstance.Parent] == nil and isDetached(instanceMap.fromIds[virtualInstance.Parent]) then
			table.insert(detachedRootIds, id)
		end
	end

	local function move(id)
		local virtualInstance = patch.added[id]
		deferred.added[id] = virtualInstance
		patch.added[id] = nil
		for _, childId in virtualInstance.Children do
			if patch.added[childId] ~= nil then
				move(childId)
			end
		end
	end
	for _, id in detachedRootIds do
		move(id)
	end

	return deferred
end

--[[
	Works out what the ledger should say once `patch` is applied. This must run
	before applying, while removed instances still have paths.
]]
function Coordinator:__ledgerEntriesFor(patch, resolver, fingerprints)
	local entries = {}

	for _, target in patch.removed do
		local path = if typeof(target) == "Instance" then resolver:ofInstance(target) else resolver:ofId(target)
		if path ~= nil then
			table.insert(entries, { path = path, fingerprint = false, target = target })
		end
	end

	for id in patch.added do
		local path = resolver:ofId(id)
		if path ~= nil and fingerprints[id] ~= nil then
			table.insert(entries, { path = path, fingerprint = fingerprints[id], target = id })
		end
	end

	for _, update in patch.updated do
		local path = resolver:ofId(update.id)
		local fingerprint = fingerprints[update.id]

		if update.changedName ~= nil then
			-- A rename removes the old path and creates a new one.
			if path ~= nil then
				table.insert(entries, { path = path, fingerprint = false, target = update.id })
			end

			local instance = self.__instanceMap.fromIds[update.id]
			local parentPath = if instance ~= nil and instance.Parent ~= nil
				then resolver:ofInstance(instance.Parent)
				else nil
			if parentPath ~= nil and fingerprint ~= nil then
				table.insert(entries, {
					path = PathResolver.join(parentPath, update.changedName),
					fingerprint = fingerprint,
					target = update.id,
				})
			end
		elseif path ~= nil and fingerprint ~= nil then
			table.insert(entries, { path = path, fingerprint = fingerprint, target = update.id })
		end
	end

	return entries
end

--[[
	Finds teammates' ledger records that our files already agree with, so that
	we can record that we've seen them.

	Without this, connecting with files that already match a teammate's sync,
	and then editing one of them, would look like we're overwriting their work
	with an older version.
]]
function Coordinator:__findAcknowledgements(virtualInstances, rootId: string, records, ownRecords, catchUpPatch)
	-- Anything the catch-up patch changes doesn't match the place yet.
	local changed = {}
	for id in catchUpPatch.added do
		changed[id] = true
	end
	for _, update in catchUpPatch.updated do
		changed[update.id] = true
	end

	-- Name lookups for each instance in our tree. Names shared by siblings map
	-- to false, since their paths are ambiguous.
	local childIndexes = {}
	local function findChild(parentId: string, name: string): (string?, boolean)
		local index = childIndexes[parentId]
		if index == nil then
			index = {}
			for _, childId in virtualInstances[parentId].Children do
				local childName = virtualInstances[childId].Name
				index[childName] = if index[childName] == nil then childId else false
			end
			childIndexes[parentId] = index
		end

		local found = index[name]
		return found or nil, found == false
	end

	-- Returns the ID at a path in our tree, and whether the path's parent is
	-- part of our tree at all.
	local function resolve(path: string): (string?, boolean)
		local names = PathResolver.split(path)
		local id = rootId

		for index, name in names do
			local childId, ambiguous = findChild(id, name)
			if childId == nil then
				return nil, index == #names and not ambiguous
			end
			id = childId
		end

		return id, true
	end

	local acknowledgements = {}
	local pending = {}
	local pendingIds = {}

	for path, record in records do
		if record.userId == self.userId or path == "" then
			continue
		end

		-- We've already recorded seeing this exact content.
		local own = ownRecords[path]
		if own ~= nil and own.fingerprint == record.fingerprint then
			continue
		end

		local id, parentInTree = resolve(path)

		if record.fingerprint == false then
			-- They removed it, and our project doesn't have it either.
			if id == nil and parentInTree then
				table.insert(acknowledgements, { path = path, fingerprint = false })
			end
		elseif id ~= nil and not changed[id] and self.__instanceMap.fromIds[id] ~= nil then
			pending[id] = { path = path, fingerprint = record.fingerprint }
			table.insert(pendingIds, id)
		end
	end

	if #pendingIds > 0 then
		local fingerprints = self:__fetchFingerprints(pendingIds)

		for id, expected in pending do
			if fingerprints[id] == expected.fingerprint then
				table.insert(acknowledgements, expected)
			end
		end
	end

	return acknowledgements
end

--[[
	Checks the patch that catches a newly connected session up with the place.

	Returns the part that's safe to apply, the changes that would overwrite
	teammates' newer work, and acknowledgements to record once the user has
	accepted.
]]
function Coordinator:checkInitialSync(catchUpPatch, virtualInstances, rootId: string)
	local records, ownRecords = self.ledger:readAll()

	local safe = catchUpPatch
	local held = PatchSet.newEmpty()
	local conflicts = {}

	if self:getConflictBehavior() ~= "Overwrite" then
		local result = classifyChanges({
			patch = catchUpPatch,
			resolver = PathResolver.new(self.__instanceMap, catchUpPatch.added, nil, catchUpPatch.removed),
			fingerprints = self:__fetchPatchFingerprints(catchUpPatch),
			records = records,
			ownRecords = ownRecords,
			userId = self.userId,
		})

		if #result.conflicts > 0 then
			safe = result.safe
			held = result.held
			conflicts = result.conflicts

			for _, conflict in conflicts do
				conflict.userName = self.ledger:getUserName(conflict.userId)
			end
		end
	end

	return {
		safe = safe,
		held = held,
		conflicts = conflicts,
		acknowledgements = self:__findAcknowledgements(virtualInstances, rootId, records, ownRecords, catchUpPatch),
	}
end

--[[
	Does everything that has to wait on the server before a patch is applied:
	bringing back instances that teammates removed, and fetching fingerprints.
	Returns what `finalize` needs.
]]
function Coordinator:prepare(patch)
	local fingerprints = {}

	-- A teammate can remove something while we wait on the server, so check
	-- again afterwards.
	for _ = 1, MAX_PREPARE_PASSES do
		self:__reviveRemovedInstances(patch)

		local missing = {}
		for id in patch.added do
			if fingerprints[id] == nil then
				table.insert(missing, id)
			end
		end
		for _, update in patch.updated do
			if fingerprints[update.id] == nil then
				table.insert(missing, update.id)
			end
		end

		for id, fingerprint in self:__fetchFingerprints(missing) do
			fingerprints[id] = fingerprint
		end

		if next(self:__findDetachedRoots(patch)) == nil then
			break
		end
	end

	return {
		fingerprints = fingerprints,
	}
end

--[[
	Finishes preparing a patch immediately before it's applied: takes over
	instances that teammates already created, then separates out any changes
	that would overwrite a teammate's newer work.

	`force` skips holding back conflicting changes, for when the user has
	chosen to overwrite them. `acknowledgements` are extra ledger entries to
	record along with the patch.
]]
function Coordinator:finalize(patch, preparation, force: boolean?, acknowledgements: { any }?)
	-- Nothing from here until the patch is applied may yield. Otherwise a
	-- teammate's changes could arrive after we checked for them: we could
	-- duplicate something they just added, or overwrite something they just
	-- changed without noticing.
	local deferred = self:__takeDetachedChanges(patch)
	if deferred ~= nil then
		self.__queuePatch(deferred, { force = force })
	end

	local fingerprints = preparation.fingerprints
	local adoptedIds = adoptExisting(self.__reconciler, self.__instanceMap, patch)

	-- Adopted instances that already match our files need no changes, but we
	-- still record that we've seen them, just like when connecting.
	local updatedIds = {}
	for _, update in patch.updated do
		updatedIds[update.id] = true
	end
	local matchingAdoptedIds = {}
	for _, id in adoptedIds do
		if not updatedIds[id] then
			table.insert(matchingAdoptedIds, id)
		end
	end

	local resolver = PathResolver.new(self.__instanceMap, patch.added, nil, patch.removed)
	local safe, held, conflicts = patch, PatchSet.newEmpty(), {}

	if not force and self:getConflictBehavior() ~= "Overwrite" then
		local records, ownRecords = self.ledger:readAll()
		local result = classifyChanges({
			patch = patch,
			resolver = resolver,
			fingerprints = fingerprints,
			records = records,
			ownRecords = ownRecords,
			userId = self.userId,
		})

		safe, held, conflicts = result.safe, result.held, result.conflicts
	end

	local ledgerEntries = self:__ledgerEntriesFor(safe, resolver, fingerprints)
	for _, id in matchingAdoptedIds do
		local path = resolver:ofId(id)
		if path ~= nil and fingerprints[id] ~= nil then
			table.insert(ledgerEntries, { path = path, fingerprint = fingerprints[id], target = id })
		end
	end
	for _, entry in acknowledgements or {} do
		table.insert(ledgerEntries, entry)
	end

	-- Remember what we're adding, to check for duplicates once teammates'
	-- changes have had time to arrive.
	local addedRootIds = {}
	for id, virtualInstance in safe.added do
		if safe.added[virtualInstance.Parent] == nil then
			table.insert(addedRootIds, id)
		end
	end

	return {
		safe = safe,
		held = held,
		conflicts = conflicts,
		ledgerEntries = ledgerEntries,
		addedRootIds = addedRootIds,
	}
end

--[[
	Finishes up after the safe part of a prepared patch was applied. Held back
	changes are added to `unappliedPatch`, so they show up as changes that
	couldn't be applied.

	This should run inside the same ChangeHistory recording as the patch, so
	that undoing the patch also undoes what it told teammates.
]]
function Coordinator:commit(plan, unappliedPatch)
	local failed = {}
	for _, target in unappliedPatch.removed do
		failed[target] = true
	end
	for id in unappliedPatch.added do
		failed[id] = true
	end
	for _, update in unappliedPatch.updated do
		failed[update.id] = true
	end

	local entries = {}
	for _, entry in plan.ledgerEntries do
		if entry.target == nil or not failed[entry.target] then
			table.insert(entries, entry)
		end
	end

	local success, err = pcall(self.ledger.record, self.ledger, entries)
	if not success then
		Log.warn("Could not record synced changes for Team Create: {}", err)
	end

	self.__held:release(plan.safe)

	if not PatchSet.isEmpty(plan.held) then
		local canOverwrite = self:getConflictBehavior() == "Ask"
		if canOverwrite then
			self.__held:hold(plan.held, plan.conflicts)
		end

		PatchSet.assign(unappliedPatch, plan.held)

		local conflicts = plan.conflicts
		task.spawn(function()
			-- Looking up names can yield, so it waits until the patch has
			-- been applied.
			for _, conflict in conflicts do
				conflict.userName = self.ledger:getUserName(conflict.userId)
			end

			self.__onConflicts(conflicts, {
				canOverwrite = canOverwrite,
			})
		end)
	end

	if #plan.addedRootIds > 0 then
		local rootIds = plan.addedRootIds
		for _, delay in DUPLICATE_CHECK_DELAYS do
			task.delay(delay, function()
				if self.__active then
					self.__queueJob(function()
						self:__resolveDuplicates(rootIds)
					end)
				end
			end)
		end
	end
end

--[[
	When two people add the same instance at nearly the same moment, each of
	their plugins creates it before the other's copy has arrived, and the place
	ends up with both. Duplicate scripts would both run, so once both copies are
	visible, whoever has the higher user ID removes their copy and takes over
	their teammate's instead. Both plugins apply the same rule, so exactly one
	copy survives.
]]
function Coordinator:__resolveDuplicates(rootIds: { string })
	if not self.__active then
		return
	end

	local instanceMap = self.__instanceMap
	local resolver = PathResolver.new(instanceMap)

	for _, id in rootIds do
		local mine = instanceMap.fromIds[id]
		if mine == nil or not mine:IsDescendantOf(game) then
			continue
		end

		local parent = mine.Parent
		local theirs = nil
		for _, sibling in parent:GetChildren() do
			if
				sibling ~= mine
				and instanceMap.fromInstances[sibling] == nil
				and sibling.Name == mine.Name
				and sibling.ClassName == mine.ClassName
			then
				theirs = sibling
				break
			end
		end

		if theirs == nil then
			continue
		end

		-- Paths of duplicates are ambiguous, so build this one by hand.
		local parentPath = resolver:ofInstance(parent)
		if parentPath == nil then
			continue
		end
		local path = PathResolver.join(parentPath, mine.Name)

		-- Only give way to a teammate who actually synced this path. Anything
		-- else is a coincidence we shouldn't touch.
		local yieldTo = nil
		for _, record in self.ledger:readRecordsFor(path) do
			if record.userId < self.userId and record.fingerprint ~= false then
				yieldTo = record.userId
			end
		end

		if yieldTo == nil then
			continue
		end

		Log.info(
			"{} added {} at the same time as you, so Rojo is keeping their copy",
			self.ledger:getUserName(yieldTo),
			mine:GetFullName()
		)

		local success, response = self.__apiContext:read({ id }):await()
		if not success or response.instances[id] == nil then
			continue
		end

		-- Forget our copy before matching theirs, so nothing still points at
		-- it while we compare.
		for _, descendant in mine:GetDescendants() do
			instanceMap:removeInstance(descendant)
		end
		instanceMap:removeInstance(mine)

		self.__reconciler:hydrate(response.instances, id, theirs)
		local diffSuccess, catchUpPatch = self.__reconciler:diff(response.instances, id)

		-- Remove our copy first, so that afterwards the path is unambiguous
		-- again and any differences from theirs get the usual conflict checks.
		self.__applyPatch({ removed = { mine }, added = {}, updated = {} }, { force = true })

		if diffSuccess then
			self.__applyPatch(catchUpPatch)
		else
			Log.warn("Could not compare {} with its server version: {}", theirs:GetFullName(), catchUpPatch)
		end
	end
end

return Coordinator
