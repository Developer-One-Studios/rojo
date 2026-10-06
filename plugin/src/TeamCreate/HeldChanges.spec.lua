return function()
	local HeldChanges = require(script.Parent.HeldChanges)
	local PatchSet = require(script.Parent.Parent.PatchSet)

	local function conflict(target, path)
		return {
			kind = "update",
			path = path,
			userId = 2,
			time = 1,
			target = target,
		}
	end

	it("should give back held changes once, as a patch", function()
		local held = HeldChanges.new()

		local patch = PatchSet.newEmpty()
		table.insert(patch.removed, "REMOVED")
		patch.added.ADDED = { Name = "Added", Parent = "ROOT", Children = { "ADDED_CHILD" } }
		patch.added.ADDED_CHILD = { Name = "Child", Parent = "ADDED", Children = {} }
		table.insert(patch.updated, { id = "UPDATED", changedProperties = { Source = { String = "x" } } })

		held:hold(patch, { conflict("UPDATED", "Updated") })

		expect(held:isEmpty()).to.equal(false)

		local taken = held:take()
		expect(taken.removed[1]).to.equal("REMOVED")
		expect(taken.added.ADDED).to.be.ok()
		expect(taken.added.ADDED_CHILD).to.be.ok()
		expect(taken.updated[1].id).to.equal("UPDATED")

		expect(held:isEmpty()).to.equal(true)
	end)

	it("should merge newer held updates into older ones", function()
		local held = HeldChanges.new()

		local first = PatchSet.newEmpty()
		table.insert(first.updated, {
			id = "UTIL",
			changedProperties = { Source = { String = "first" }, Disabled = { Bool = true } },
		})
		held:hold(first, { conflict("UTIL", "Util") })

		local second = PatchSet.newEmpty()
		table.insert(second.updated, {
			id = "UTIL",
			changedName = "Renamed",
			changedProperties = { Source = { String = "second" } },
		})
		held:hold(second, { conflict("UTIL", "Util") })

		local taken = held:take()
		expect(#taken.updated).to.equal(1)
		expect(taken.updated[1].changedName).to.equal("Renamed")
		expect(taken.updated[1].changedProperties.Source.String).to.equal("second")
		expect(taken.updated[1].changedProperties.Disabled.Bool).to.equal(true)
	end)

	it("should not modify the update it was given", function()
		local held = HeldChanges.new()

		local update = { id = "UTIL", changedProperties = { Source = { String = "first" } } }
		local first = PatchSet.newEmpty()
		table.insert(first.updated, update)
		held:hold(first, {})

		local second = PatchSet.newEmpty()
		table.insert(second.updated, { id = "UTIL", changedProperties = { Source = { String = "second" } } })
		held:hold(second, {})

		expect(update.changedProperties.Source.String).to.equal("first")
	end)

	it("should forget held changes superseded by an applied change", function()
		local held = HeldChanges.new()

		local patch = PatchSet.newEmpty()
		table.insert(patch.updated, { id = "UTIL", changedProperties = {} })
		table.insert(patch.updated, { id = "OTHER", changedProperties = {} })
		held:hold(patch, { conflict("UTIL", "Util"), conflict("OTHER", "Other") })

		local applied = PatchSet.newEmpty()
		table.insert(applied.updated, { id = "UTIL", changedProperties = {} })
		held:release(applied)

		local conflicts = held:getConflicts()
		expect(#conflicts).to.equal(1)
		expect(conflicts[1].target).to.equal("OTHER")
	end)

	it("should list conflicts sorted by path", function()
		local held = HeldChanges.new()

		local patch = PatchSet.newEmpty()
		table.insert(patch.updated, { id = "B", changedProperties = {} })
		table.insert(patch.updated, { id = "A", changedProperties = {} })
		held:hold(patch, { conflict("B", "Zeta"), conflict("A", "Alpha") })

		local conflicts = held:getConflicts()
		expect(conflicts[1].path).to.equal("Alpha")
		expect(conflicts[2].path).to.equal("Zeta")
	end)

	it("should drop everything when cleared", function()
		local held = HeldChanges.new()

		local patch = PatchSet.newEmpty()
		table.insert(patch.removed, "REMOVED")
		held:hold(patch, {})
		held:clear()

		expect(held:isEmpty()).to.equal(true)
		expect(PatchSet.isEmpty(held:take())).to.equal(true)
	end)
end
