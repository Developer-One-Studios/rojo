return function()
	local adoptExisting = require(script.Parent.adoptExisting)
	local InstanceMap = require(script.Parent.Parent.InstanceMap)
	local PatchSet = require(script.Parent.Parent.PatchSet)
	local Reconciler = require(script.Parent.Parent.Reconciler)

	local function setup()
		local root = Instance.new("Folder")
		root.Name = "Root"

		local instanceMap = InstanceMap.new()
		instanceMap:insert("ROOT", root)

		return root, instanceMap, Reconciler.new(instanceMap)
	end

	local function addedScript(id, name, source, parent)
		return {
			Id = id,
			Name = name,
			ClassName = "ModuleScript",
			Parent = parent or "ROOT",
			Properties = {
				Source = { String = source },
			},
			Children = {},
		}
	end

	it("should adopt an instance a teammate already created instead of duplicating it", function()
		local root, instanceMap, reconciler = setup()

		local existing = Instance.new("ModuleScript")
		existing.Name = "Util"
		existing.Source = "return 'same'"
		existing.Parent = root

		local patch = PatchSet.newEmpty()
		patch.added.UTIL = addedScript("UTIL", "Util", "return 'same'")

		expect(#adoptExisting(reconciler, instanceMap, patch)).to.equal(1)

		expect(instanceMap.fromIds.UTIL).to.equal(existing)
		expect(next(patch.added)).to.equal(nil)
		expect(#patch.updated).to.equal(0)
	end)

	it("should only update what differs", function()
		local root, instanceMap, reconciler = setup()

		local existing = Instance.new("ModuleScript")
		existing.Name = "Util"
		existing.Source = "return 'theirs'"
		existing.Parent = root

		local patch = PatchSet.newEmpty()
		patch.added.UTIL = addedScript("UTIL", "Util", "return 'mine'")

		adoptExisting(reconciler, instanceMap, patch)

		expect(#patch.updated).to.equal(1)
		expect(patch.updated[1].id).to.equal("UTIL")
		expect(patch.updated[1].changedProperties.Source.String).to.equal("return 'mine'")
	end)

	it("should still add descendants the existing instance doesn't have", function()
		local root, instanceMap, reconciler = setup()

		local existing = Instance.new("Folder")
		existing.Name = "Shared"
		existing.Parent = root

		local patch = PatchSet.newEmpty()
		patch.added.SHARED = {
			Id = "SHARED",
			Name = "Shared",
			ClassName = "Folder",
			Parent = "ROOT",
			Properties = {},
			Children = { "UTIL" },
		}
		patch.added.UTIL = addedScript("UTIL", "Util", "return {}", "SHARED")

		local adoptedIds = adoptExisting(reconciler, instanceMap, patch)

		expect(#adoptedIds).to.equal(1)
		expect(adoptedIds[1]).to.equal("SHARED")
		expect(instanceMap.fromIds.SHARED).to.equal(existing)
		expect(patch.added.SHARED).to.equal(nil)
		expect(patch.added.UTIL).to.be.ok()
	end)

	it("should not adopt instances that are already tracked", function()
		local root, instanceMap, reconciler = setup()

		local tracked = Instance.new("ModuleScript")
		tracked.Name = "Util"
		tracked.Parent = root
		instanceMap:insert("OTHER", tracked)

		local patch = PatchSet.newEmpty()
		patch.added.UTIL = addedScript("UTIL", "Util", "return {}")

		expect(#adoptExisting(reconciler, instanceMap, patch)).to.equal(0)
		expect(patch.added.UTIL).to.be.ok()
	end)

	it("should not adopt instances of a different class", function()
		local root, instanceMap, reconciler = setup()

		local existing = Instance.new("Script")
		existing.Name = "Util"
		existing.Parent = root

		local patch = PatchSet.newEmpty()
		patch.added.UTIL = addedScript("UTIL", "Util", "return {}")

		expect(#adoptExisting(reconciler, instanceMap, patch)).to.equal(0)
		expect(patch.added.UTIL).to.be.ok()
	end)
end
