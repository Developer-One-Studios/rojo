return function()
	local HttpService = game:GetService("HttpService")

	local Ledger = require(script.Parent.Ledger)

	local function newLedger(root, userId, userName)
		return Ledger.new({
			userId = userId,
			userName = userName or ("User" .. userId),
			root = root,
		})
	end

	it("should read back what was recorded", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)

		ledger:record({
			{ path = "ReplicatedStorage/Util", fingerprint = "aaaa" },
			{ path = "ReplicatedStorage/Old", fingerprint = false },
		}, 1000)

		local records = ledger:readAll()

		expect(records["ReplicatedStorage/Util"].userId).to.equal(1)
		expect(records["ReplicatedStorage/Util"].fingerprint).to.equal("aaaa")
		expect(records["ReplicatedStorage/Util"].time).to.equal(1000)
		expect(records["ReplicatedStorage/Old"].fingerprint).to.equal(false)
	end)

	it("should create its shared folders ahead of time", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)

		ledger:ensureFolders()
		ledger:ensureFolders()

		expect(#root:GetChildren()).to.equal(1)
		expect(root:FindFirstChild("Ledger")).to.be.ok()
		expect(#root.Ledger:GetChildren()).to.equal(0)
	end)

	it("should never record the root", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)

		ledger:record({ { path = "", fingerprint = "aaaa" } }, 1000)

		local records = ledger:readAll()
		expect(next(records)).to.equal(nil)
		expect(root:FindFirstChild("Ledger")).to.equal(nil)
	end)

	it("should keep the newest record across users", function()
		local root = Instance.new("Folder")
		local alice = newLedger(root, 1, "Alice")
		local bob = newLedger(root, 2, "Bob")

		alice:record({ { path = "A", fingerprint = "alice-1" } }, 1000)
		bob:record({ { path = "A", fingerprint = "bob-1" } }, 2000)
		alice:record({ { path = "B", fingerprint = "alice-2" } }, 3000)
		bob:record({ { path = "B", fingerprint = "bob-2" } }, 2500)

		-- Both users see the same merged view.
		for _, ledger in { alice, bob } do
			local records = ledger:readAll()
			expect(records.A.userId).to.equal(2)
			expect(records.A.fingerprint).to.equal("bob-1")
			expect(records.B.userId).to.equal(1)
			expect(records.B.fingerprint).to.equal("alice-2")
		end

		-- Each user can also see their own newest records.
		local _, aliceOwn = alice:readAll()
		expect(aliceOwn.A.fingerprint).to.equal("alice-1")
		expect(aliceOwn.B.fingerprint).to.equal("alice-2")

		local _, bobOwn = bob:readAll()
		expect(bobOwn.A.fingerprint).to.equal("bob-1")
		expect(bobOwn.B.fingerprint).to.equal("bob-2")
	end)

	it("should only write to the user's own folder", function()
		local root = Instance.new("Folder")
		local alice = newLedger(root, 1, "Alice")
		local bob = newLedger(root, 2, "Bob")

		alice:record({ { path = "A", fingerprint = "a" } }, 1000)
		bob:record({ { path = "A", fingerprint = "b" } }, 2000)

		local folders = root.Ledger:GetChildren()
		expect(#folders).to.equal(2)

		local aliceFolder = root.Ledger:FindFirstChild("1")
		expect(aliceFolder:GetAttribute("UserName")).to.equal("Alice")

		for _, value in aliceFolder:GetChildren() do
			for _, entry in HttpService:JSONDecode(value.Value) do
				expect(entry[1]).to.equal("a")
			end
		end
	end)

	it("should read every user's newest record for one path", function()
		local root = Instance.new("Folder")
		local alice = newLedger(root, 1)
		local bob = newLedger(root, 2)

		alice:record({ { path = "A", fingerprint = "a1" } }, 1000)
		alice:record({ { path = "A", fingerprint = "a2" } }, 3000)
		bob:record({ { path = "A", fingerprint = "b1" } }, 2000)
		bob:record({ { path = "Other", fingerprint = "x" } }, 2000)

		local records = alice:readRecordsFor("A")
		table.sort(records, function(a, b)
			return a.userId < b.userId
		end)

		expect(#records).to.equal(2)
		expect(records[1].fingerprint).to.equal("a2")
		expect(records[2].fingerprint).to.equal("b1")
		expect(#alice:readRecordsFor("Missing")).to.equal(0)
	end)

	it("should remember teammates' names", function()
		local root = Instance.new("Folder")
		newLedger(root, 7, "Teammate"):record({ { path = "A", fingerprint = "a" } }, 1000)

		expect(newLedger(root, 1):getUserName(7)).to.equal("Teammate")
	end)

	it("should update a path in place rather than duplicating it", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)

		ledger:record({ { path = "A", fingerprint = "first" } }, 1000)
		ledger:record({ { path = "A", fingerprint = "second" } }, 2000)

		local count = 0
		for _, value in root.Ledger["1"]:GetChildren() do
			for path in HttpService:JSONDecode(value.Value) do
				if path == "A" then
					count += 1
				end
			end
		end

		expect(count).to.equal(1)
		expect(ledger:readAll().A.fingerprint).to.equal("second")
	end)

	it("should drop expired records when writing", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)

		-- Put both paths in the same bucket so the second write rewrites the
		-- first one's bucket.
		local oldPath = "Old"
		local newPath
		for index = 1, 1000 do
			local candidate = "New" .. index
			if Ledger.bucketOf(candidate) == Ledger.bucketOf(oldPath) then
				newPath = candidate
				break
			end
		end

		ledger:record({ { path = oldPath, fingerprint = "a" } }, 1000)
		ledger:record({ { path = newPath, fingerprint = "b" } }, 1000 + Ledger.RECORD_LIFETIME + 1)

		local records = ledger:readAll()
		expect(records[oldPath]).to.equal(nil)
		expect(records[newPath]).to.be.ok()
	end)

	it("should trim the oldest records when a bucket gets too large", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)

		local originalMax = Ledger.MAX_BUCKET_LENGTH
		local originalCount = Ledger.BUCKET_COUNT
		Ledger.MAX_BUCKET_LENGTH = 400
		Ledger.BUCKET_COUNT = 1

		local success, err = pcall(function()
			for index = 1, 40 do
				ledger:record({ { path = "Path" .. index, fingerprint = "0123456789abcdef" } }, index)
			end
		end)

		Ledger.MAX_BUCKET_LENGTH = originalMax
		Ledger.BUCKET_COUNT = originalCount

		assert(success, err)

		for _, value in root.Ledger["1"]:GetChildren() do
			expect(#value.Value <= 400).to.equal(true)
		end

		local records = ledger:readAll()
		expect(records.Path40).to.be.ok()
		expect(records.Path1).to.equal(nil)
	end)

	it("should ignore values it can't read", function()
		local root = Instance.new("Folder")
		local ledger = newLedger(root, 1)
		ledger:record({ { path = "A", fingerprint = "a" } }, 1000)

		local broken = Instance.new("StringValue")
		broken.Name = "99"
		broken.Value = "{ not json"
		broken.Parent = root.Ledger["1"]

		local wrongShape = Instance.new("StringValue")
		wrongShape.Name = "98"
		wrongShape.Value = HttpService:JSONEncode({ B = { 12, "nope" } })
		wrongShape.Parent = root.Ledger["1"]

		local records = ledger:readAll()
		expect(records.A.fingerprint).to.equal("a")
		expect(records.B).to.equal(nil)
	end)
end
