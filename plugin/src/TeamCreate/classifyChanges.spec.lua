return function()
	local classifyChanges = require(script.Parent.classifyChanges)
	local PathResolver = require(script.Parent.PathResolver)
	local InstanceMap = require(script.Parent.Parent.InstanceMap)
	local PatchSet = require(script.Parent.Parent.PatchSet)

	local ME = 1
	local TEAMMATE = 2

	-- Builds a small place:
	--   Root (stands in for the DataModel)
	--     Shared (Folder)
	--       Util (ModuleScript)
	local function setup()
		local root = Instance.new("Folder")
		root.Name = "Root"

		local shared = Instance.new("Folder")
		shared.Name = "Shared"
		shared.Parent = root

		local util = Instance.new("ModuleScript")
		util.Name = "Util"
		util.Parent = shared

		local instanceMap = InstanceMap.new()
		instanceMap:insert("ROOT", root)
		instanceMap:insert("SHARED", shared)
		instanceMap:insert("UTIL", util)

		return root, instanceMap, shared, util
	end

	local function classify(patch, records, fingerprints, ownRecords)
		local root, instanceMap = setup()

		return classifyChanges({
			patch = patch,
			resolver = PathResolver.new(instanceMap, patch.added, root),
			fingerprints = fingerprints or {},
			records = records,
			ownRecords = ownRecords,
			userId = ME,
		})
	end

	local function utilUpdate()
		local patch = PatchSet.newEmpty()
		table.insert(patch.updated, {
			id = "UTIL",
			changedProperties = {
				Source = { String = "return 'mine'" },
			},
		})
		return patch
	end

	describe("updates", function()
		it("should apply updates nobody else has synced", function()
			local result = classify(utilUpdate(), {}, { UTIL = "mine" })

			expect(#result.safe.updated).to.equal(1)
			expect(#result.conflicts).to.equal(0)
		end)

		it("should apply updates when we synced last", function()
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = ME, fingerprint = "older", time = 1 },
			}, { UTIL = "mine" })

			expect(#result.safe.updated).to.equal(1)
			expect(#result.conflicts).to.equal(0)
		end)

		it("should hold updates that would replace a teammate's different content", function()
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			}, { UTIL = "mine" })

			expect(#result.safe.updated).to.equal(0)
			expect(#result.held.updated).to.equal(1)
			expect(#result.conflicts).to.equal(1)

			local conflict = result.conflicts[1]
			expect(conflict.kind).to.equal("update")
			expect(conflict.path).to.equal("Shared/Util")
			expect(conflict.userId).to.equal(TEAMMATE)
			expect(conflict.time).to.equal(5)
			expect(conflict.target).to.equal("UTIL")
		end)

		it("should apply updates once our files match what the teammate synced", function()
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "same", time = 5 },
			}, { UTIL = "same" })

			expect(#result.safe.updated).to.equal(1)
			expect(#result.conflicts).to.equal(0)
		end)

		it("should apply updates on top of a teammate's version we've already seen", function()
			-- For example, we connected with files matching what they synced,
			-- or they last synced something we had already synced ourselves.
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			}, { UTIL = "mine" }, {
				["Shared/Util"] = { userId = ME, fingerprint = "theirs", time = 3 },
			})

			expect(#result.safe.updated).to.equal(1)
			expect(#result.conflicts).to.equal(0)
		end)

		it("should hold updates when the version we last saw is older than the teammate's", function()
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			}, { UTIL = "mine" }, {
				["Shared/Util"] = { userId = ME, fingerprint = "older", time = 3 },
			})

			expect(#result.held.updated).to.equal(1)
		end)

		it("should hold updates it can't fingerprint when a teammate synced last", function()
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			}, {})

			expect(#result.held.updated).to.equal(1)
		end)

		it("should apply updates to something a teammate removed but is back", function()
			local result = classify(utilUpdate(), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = false, time = 5 },
			}, { UTIL = "mine" })

			expect(#result.safe.updated).to.equal(1)
		end)

		it("should never hold updates to the root", function()
			local patch = PatchSet.newEmpty()
			table.insert(patch.updated, { id = "ROOT", changedName = "Place", changedProperties = {} })

			local result = classify(patch, {
				[""] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			})

			expect(#result.safe.updated).to.equal(1)
		end)
	end)

	describe("additions", function()
		local function newFolderPatch()
			local patch = PatchSet.newEmpty()
			patch.added.NEW = {
				Id = "NEW",
				Name = "New",
				ClassName = "Folder",
				Parent = "SHARED",
				Properties = {},
				Children = { "NEW_CHILD" },
			}
			patch.added.NEW_CHILD = {
				Id = "NEW_CHILD",
				Name = "Child",
				ClassName = "ModuleScript",
				Parent = "NEW",
				Properties = {},
				Children = {},
			}
			return patch
		end

		it("should add instances nobody else has synced", function()
			local result = classify(newFolderPatch(), {})

			expect(result.safe.added.NEW).to.be.ok()
			expect(result.safe.added.NEW_CHILD).to.be.ok()
			expect(#result.conflicts).to.equal(0)
		end)

		it("should hold additions of something a teammate removed, with everything inside", function()
			local result = classify(newFolderPatch(), {
				["Shared/New"] = { userId = TEAMMATE, fingerprint = false, time = 5 },
			})

			expect(result.safe.added.NEW).to.equal(nil)
			expect(result.safe.added.NEW_CHILD).to.equal(nil)
			expect(result.held.added.NEW).to.be.ok()
			expect(result.held.added.NEW_CHILD).to.be.ok()

			expect(#result.conflicts).to.equal(1)
			expect(result.conflicts[1].kind).to.equal("add")
			expect(result.conflicts[1].path).to.equal("Shared/New")
		end)

		it("should add instances a teammate synced but that are missing now", function()
			local result = classify(newFolderPatch(), {
				["Shared/New"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			})

			expect(result.safe.added.NEW).to.be.ok()
		end)

		it("should hold additions next to a teammate's same-named instance of another class", function()
			-- A teammate renamed Util.lua to Util.server.lua, so the place has
			-- their Script where our ModuleScript used to be.
			local root, instanceMap, shared = setup()
			local ourOldCopy = shared.Util
			instanceMap:removeInstance(ourOldCopy)
			ourOldCopy.Parent = nil

			local theirs = Instance.new("Script")
			theirs.Name = "Util"
			theirs.Parent = shared

			local patch = PatchSet.newEmpty()
			patch.added.UTIL = {
				Id = "UTIL",
				Name = "Util",
				ClassName = "ModuleScript",
				Parent = "SHARED",
				Properties = {},
				Children = {},
			}

			local result = classifyChanges({
				patch = patch,
				resolver = PathResolver.new(instanceMap, patch.added, root),
				fingerprints = { UTIL = "ours" },
				records = {
					["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
				},
				userId = ME,
			})

			expect(result.safe.added.UTIL).to.equal(nil)
			expect(result.held.added.UTIL).to.be.ok()
			-- Overwriting replaces their instance instead of adding a twin.
			expect(result.held.removed[1]).to.equal(theirs)
			expect(result.conflicts[1].path).to.equal("Shared/Util")
			expect(result.conflicts[1].target).to.equal("UTIL")
		end)

		it("should add next to same-named instances nobody synced", function()
			local root, instanceMap, shared = setup()

			local unrelated = Instance.new("Folder")
			unrelated.Name = "Assets"
			unrelated.Parent = shared

			local patch = PatchSet.newEmpty()
			patch.added.ASSETS = {
				Id = "ASSETS",
				Name = "Assets",
				ClassName = "ModuleScript",
				Parent = "SHARED",
				Properties = {},
				Children = {},
			}

			local result = classifyChanges({
				patch = patch,
				resolver = PathResolver.new(instanceMap, patch.added, root),
				fingerprints = { ASSETS = "ours" },
				records = {},
				userId = ME,
			})

			expect(result.safe.added.ASSETS).to.be.ok()
			expect(#result.held.removed).to.equal(0)
		end)

		it("should add instances we removed ourselves", function()
			local result = classify(newFolderPatch(), {
				["Shared/New"] = { userId = ME, fingerprint = false, time = 5 },
			})

			expect(result.safe.added.NEW).to.be.ok()
		end)
	end)

	describe("removals", function()
		local function removalPatch(target)
			local patch = PatchSet.newEmpty()
			table.insert(patch.removed, target)
			return patch
		end

		it("should remove instances nobody else has synced", function()
			local result = classify(removalPatch("UTIL"), {})

			expect(#result.safe.removed).to.equal(1)
		end)

		it("should hold removals of something a teammate synced", function()
			local result = classify(removalPatch("UTIL"), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			})

			expect(#result.safe.removed).to.equal(0)
			expect(#result.held.removed).to.equal(1)
			expect(result.conflicts[1].kind).to.equal("remove")
		end)

		it("should hold removals of something containing a teammate's work", function()
			local result = classify(removalPatch("SHARED"), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			})

			expect(#result.held.removed).to.equal(1)
			expect(result.conflicts[1].path).to.equal("Shared")
		end)

		it("should remove things a teammate also removed", function()
			local result = classify(removalPatch("UTIL"), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = false, time = 5 },
			})

			expect(#result.safe.removed).to.equal(1)
		end)

		it("should remove things we synced last", function()
			local result = classify(removalPatch("UTIL"), {
				["Shared/Util"] = { userId = ME, fingerprint = "mine", time = 5 },
			})

			expect(#result.safe.removed).to.equal(1)
		end)

		it("should remove things whose teammate version we've already seen", function()
			local result = classify(removalPatch("SHARED"), {
				["Shared/Util"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			}, {}, {
				["Shared/Util"] = { userId = ME, fingerprint = "theirs", time = 3 },
			})

			expect(#result.safe.removed).to.equal(1)
		end)

		it("should not be confused by teammates' work next to the removed instance", function()
			local result = classify(removalPatch("UTIL"), {
				["Shared/Utility"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
			})

			expect(#result.safe.removed).to.equal(1)
		end)

		it("should handle removals given as instances", function()
			local root, instanceMap, shared = setup()

			-- The diff lists instances that aren't in the project directly
			-- rather than by ID.
			local unknown = Instance.new("Script")
			unknown.Name = "TeammatesNewScript"
			unknown.Parent = shared

			local patch = removalPatch(unknown)

			local result = classifyChanges({
				patch = patch,
				resolver = PathResolver.new(instanceMap, patch.added, root),
				fingerprints = {},
				records = {
					["Shared/TeammatesNewScript"] = { userId = TEAMMATE, fingerprint = "theirs", time = 5 },
				},
				userId = ME,
			})

			expect(result.held.removed[1]).to.equal(unknown)
			expect(result.conflicts[1].target).to.equal(unknown)
		end)
	end)
end
