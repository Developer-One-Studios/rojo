return function()
	local PathResolver = require(script.Parent.PathResolver)
	local InstanceMap = require(script.Parent.Parent.InstanceMap)

	local function makeFolder(name, parent)
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
		return folder
	end

	describe("ofInstance", function()
		it("should join names from the root down", function()
			local root = makeFolder("Root")
			local shared = makeFolder("Shared", makeFolder("ReplicatedStorage", root))

			local resolver = PathResolver.new(InstanceMap.new(), nil, root)

			expect(resolver:ofInstance(root)).to.equal("")
			expect(resolver:ofInstance(shared)).to.equal("ReplicatedStorage/Shared")
		end)

		it("should escape slashes and percent signs in names", function()
			local root = makeFolder("Root")
			local child = makeFolder("50% a/b", root)

			local resolver = PathResolver.new(InstanceMap.new(), nil, root)

			expect(resolver:ofInstance(child)).to.equal("50%25 a%2Fb")
		end)

		it("should not give a path to instances that share a name with a sibling", function()
			local root = makeFolder("Root")
			local first = makeFolder("Part", root)
			local second = makeFolder("Part", root)
			local inside = makeFolder("Inside", first)
			local unique = makeFolder("Unique", root)

			local resolver = PathResolver.new(InstanceMap.new(), nil, root)

			expect(resolver:ofInstance(first)).to.equal(nil)
			expect(resolver:ofInstance(second)).to.equal(nil)
			expect(resolver:ofInstance(inside)).to.equal(nil)
			expect(resolver:ofInstance(unique)).to.equal("Unique")
		end)

		it("should not give a path to instances outside of the root", function()
			local root = makeFolder("Root")
			local outside = makeFolder("Outside")

			local resolver = PathResolver.new(InstanceMap.new(), nil, root)

			expect(resolver:ofInstance(outside)).to.equal(nil)
		end)
	end)

	describe("ofId", function()
		it("should resolve instances in the InstanceMap", function()
			local root = makeFolder("Root")
			local child = makeFolder("Child", root)

			local instanceMap = InstanceMap.new()
			instanceMap:insert("ROOT", root)
			instanceMap:insert("CHILD", child)

			local resolver = PathResolver.new(instanceMap, nil, root)

			expect(resolver:ofId("ROOT")).to.equal("")
			expect(resolver:ofId("CHILD")).to.equal("Child")
			expect(resolver:ofId("UNKNOWN")).to.equal(nil)
		end)

		it("should resolve instances that are about to be added", function()
			local root = makeFolder("Root")
			local child = makeFolder("Child", root)

			local instanceMap = InstanceMap.new()
			instanceMap:insert("ROOT", root)
			instanceMap:insert("CHILD", child)

			local added = {
				NEW_FOLDER = {
					Name = "NewFolder",
					ClassName = "Folder",
					Parent = "CHILD",
					Properties = {},
					Children = { "NEW_SCRIPT" },
				},
				NEW_SCRIPT = {
					Name = "NewScript",
					ClassName = "ModuleScript",
					Parent = "NEW_FOLDER",
					Properties = {},
					Children = {},
				},
			}

			local resolver = PathResolver.new(instanceMap, added, root)

			expect(resolver:ofId("NEW_FOLDER")).to.equal("Child/NewFolder")
			expect(resolver:ofId("NEW_SCRIPT")).to.equal("Child/NewFolder/NewScript")
		end)

		it("should not give a path to additions whose name is already taken", function()
			local root = makeFolder("Root")
			makeFolder("Taken", root)

			local instanceMap = InstanceMap.new()
			instanceMap:insert("ROOT", root)

			local added = {
				NEW = {
					Name = "Taken",
					ClassName = "ModuleScript",
					Parent = "ROOT",
					Properties = {},
					Children = {},
				},
				TWIN_A = {
					Name = "Twin",
					ClassName = "Folder",
					Parent = "ROOT",
					Properties = {},
					Children = {},
				},
				TWIN_B = {
					Name = "Twin",
					ClassName = "Folder",
					Parent = "ROOT",
					Properties = {},
					Children = {},
				},
			}

			local resolver = PathResolver.new(instanceMap, added, root)

			expect(resolver:ofId("NEW")).to.equal(nil)
			expect(resolver:ofId("TWIN_A")).to.equal(nil)
			expect(resolver:ofId("TWIN_B")).to.equal(nil)
		end)
	end)

	describe("removals", function()
		it("should give a path to additions replacing an instance the patch removes", function()
			local root = makeFolder("Root")
			local old = makeFolder("Thing", root)

			local instanceMap = InstanceMap.new()
			instanceMap:insert("ROOT", root)

			local added = {
				NEW = {
					Name = "Thing",
					ClassName = "ModuleScript",
					Parent = "ROOT",
					Properties = {},
					Children = {},
				},
			}

			expect(PathResolver.new(instanceMap, added, root):ofId("NEW")).to.equal(nil)
			expect(PathResolver.new(instanceMap, added, root, { old }):ofId("NEW")).to.equal("Thing")
		end)
	end)

	describe("findOccupant", function()
		it("should find the untracked instance with the same name", function()
			local root = makeFolder("Root")
			local occupant = makeFolder("Thing", root)

			local instanceMap = InstanceMap.new()
			instanceMap:insert("ROOT", root)

			local added = {
				NEW = { Name = "Thing", ClassName = "ModuleScript", Parent = "ROOT", Properties = {}, Children = {} },
			}

			local found, path = PathResolver.new(instanceMap, added, root):findOccupant("NEW")
			expect(found).to.equal(occupant)
			expect(path).to.equal("Thing")
		end)

		it("should not find instances we track, or pick between several", function()
			local root = makeFolder("Root")
			local tracked = makeFolder("Tracked", root)
			makeFolder("Twin", root)
			makeFolder("Twin", root)

			local instanceMap = InstanceMap.new()
			instanceMap:insert("ROOT", root)
			instanceMap:insert("TRACKED", tracked)

			local added = {
				A = { Name = "Tracked", ClassName = "ModuleScript", Parent = "ROOT", Properties = {}, Children = {} },
				B = { Name = "Twin", ClassName = "ModuleScript", Parent = "ROOT", Properties = {}, Children = {} },
			}

			local resolver = PathResolver.new(instanceMap, added, root)
			expect(resolver:findOccupant("A")).to.equal(nil)
			expect(resolver:findOccupant("B")).to.equal(nil)
		end)
	end)

	describe("isWithin", function()
		it("should match the path itself and its descendants only", function()
			expect(PathResolver.isWithin("A/B", "A/B")).to.equal(true)
			expect(PathResolver.isWithin("A/B/C", "A/B")).to.equal(true)
			expect(PathResolver.isWithin("A/BC", "A/B")).to.equal(false)
			expect(PathResolver.isWithin("A", "A/B")).to.equal(false)
			expect(PathResolver.isWithin("Anything", "")).to.equal(true)
		end)
	end)

	describe("split", function()
		it("should undo escaping", function()
			local path = PathResolver.join(PathResolver.join("", "50% a/b"), "Child")
			local names = PathResolver.split(path)

			expect(#names).to.equal(2)
			expect(names[1]).to.equal("50% a/b")
			expect(names[2]).to.equal("Child")
			expect(#PathResolver.split("")).to.equal(0)
		end)
	end)

	describe("ancestors", function()
		it("should list ancestors nearest first", function()
			local ancestors = PathResolver.ancestors("A/B/C")

			expect(#ancestors).to.equal(2)
			expect(ancestors[1]).to.equal("A/B")
			expect(ancestors[2]).to.equal("A")
			expect(#PathResolver.ancestors("A")).to.equal(0)
		end)
	end)
end
