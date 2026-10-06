--[[
	A record, stored in the place, of who last synced each instance and a
	fingerprint of the content they synced.

	This is what lets one person's plugin notice that the place holds a newer
	version of something than their files do, because a teammate synced it.

	Each user writes only to their own folder, so people syncing at the same
	time can never overwrite each other's records. Readers merge every user's
	records and keep the newest one for each path:

		Ledger
			<UserId> (Folder, attribute UserName)
				00 .. 31 (StringValue)  -- JSON: { [path] = { fingerprint | false, time } }

	A fingerprint of `false` means the user removed the instance.

	The ledger is always read straight from the place rather than cached, so
	undoing a Rojo patch (which also undoes its ledger writes) can never leave
	us with stale records.
]]

local HttpService = game:GetService("HttpService")

local Packages = script.Parent.Parent.Parent.Packages
local Log = require(Packages.Log)

local TeamCreate = require(script.Parent)

export type Record = {
	userId: number,
	fingerprint: string | false,
	time: number,
}

export type Entry = {
	path: string,
	fingerprint: string | false,
}

local Ledger = {}
Ledger.__index = Ledger

Ledger.FOLDER_NAME = "Ledger"
Ledger.BUCKET_COUNT = 32

-- Records are only useful while teammates might still have files older than
-- them, so they're dropped after a while to keep the place small.
Ledger.RECORD_LIFETIME = 30 * 24 * 60 * 60 * 1000

-- StringValues can't hold more than 200,000 characters.
Ledger.MAX_BUCKET_LENGTH = 190_000

function Ledger.bucketOf(path: string): number
	-- djb2. It only needs to spread paths evenly, and must agree between
	-- every teammate's plugin.
	local hash = 5381
	for index = 1, #path do
		hash = (hash * 33 + string.byte(path, index)) % 4294967296
	end

	return hash % Ledger.BUCKET_COUNT
end

local function bucketName(bucket: number): string
	return string.format("%02d", bucket)
end

local function decodeBucket(value: Instance): { [string]: { any } }
	local success, decoded = pcall(HttpService.JSONDecode, HttpService, (value :: StringValue).Value)

	if not success or type(decoded) ~= "table" then
		if (value :: StringValue).Value ~= "" then
			Log.warn("Ignoring unreadable Rojo Team Create ledger entry {}", value:GetFullName())
		end

		return {}
	end

	return decoded
end

local function isValidEntry(entry: any): boolean
	return type(entry) == "table" and (type(entry[1]) == "string" or entry[1] == false) and type(entry[2]) == "number"
end

--[[
	`root` overrides where the ledger lives, which tests use to stay out of the
	real place's ServerStorage.
]]
function Ledger.new(options: { userId: number, userName: string, root: Instance? })
	local self = {
		__userId = options.userId,
		__userName = options.userName,
		__root = options.root,
	}

	return setmetatable(self, Ledger)
end

function Ledger:__roots(): { Instance }
	if self.__root ~= nil then
		return { self.__root }
	end

	return TeamCreate.getRoots()
end

function Ledger:__userFolders(): { [number]: { Instance } }
	local folders = {}

	for _, root in self:__roots() do
		local ledgerFolder = root:FindFirstChild(Ledger.FOLDER_NAME)
		if ledgerFolder == nil then
			continue
		end

		for _, userFolder in ledgerFolder:GetChildren() do
			local userId = tonumber(userFolder.Name)
			if userId ~= nil then
				folders[userId] = folders[userId] or {}
				table.insert(folders[userId], userFolder)
			end
		end
	end

	return folders
end

function Ledger:__ownFolder(): Instance
	-- Keep writing to an existing folder, wherever it is, so our own older
	-- records keep being updated rather than duplicated.
	local existing = self:__userFolders()[self.__userId]
	if existing ~= nil then
		return existing[1]
	end

	local root = self.__root or TeamCreate.getRoot(true)
	local ledgerFolder = TeamCreate.getOrCreateChild(root, Ledger.FOLDER_NAME, "Folder")

	return TeamCreate.getOrCreateChild(ledgerFolder, tostring(self.__userId), "Folder")
end

--[[
	Creates the shared folders the ledger lives in, if they don't exist yet.

	This should happen outside of any ChangeHistory recording. Otherwise
	undoing that recording would remove the folders, along with everything
	teammates have stored in them since.
]]
function Ledger:ensureFolders()
	local root = self.__root or TeamCreate.getRoot(true)
	TeamCreate.getOrCreateChild(root, Ledger.FOLDER_NAME, "Folder")
end

--[[
	Returns the newest record for every path across every user, and separately
	the newest record for every path from the current user.
]]
function Ledger:readAll(): ({ [string]: Record }, { [string]: Record })
	local latest = {}
	local own = {}

	local function consider(records, path, userId, entry)
		local existing = records[path]
		if existing == nil or entry[2] > existing.time then
			records[path] = {
				userId = userId,
				fingerprint = entry[1],
				time = entry[2],
			}
		end
	end

	for userId, folders in self:__userFolders() do
		for _, folder in folders do
			for _, value in folder:GetChildren() do
				if not value:IsA("StringValue") then
					continue
				end

				for path, entry in decodeBucket(value) do
					if not isValidEntry(entry) then
						continue
					end

					consider(latest, path, userId, entry)
					if userId == self.__userId then
						consider(own, path, userId, entry)
					end
				end
			end
		end
	end

	return latest, own
end

--[[
	Returns each user's newest record for a single path.
]]
function Ledger:readRecordsFor(path: string): { Record }
	local name = bucketName(Ledger.bucketOf(path))
	local results = {}

	for userId, folders in self:__userFolders() do
		local newest = nil

		for _, folder in folders do
			local value = folder:FindFirstChild(name)
			if value == nil or not value:IsA("StringValue") then
				continue
			end

			local entry = decodeBucket(value)[path]
			if isValidEntry(entry) and (newest == nil or entry[2] > newest.time) then
				newest = {
					userId = userId,
					fingerprint = entry[1],
					time = entry[2],
				}
			end
		end

		if newest ~= nil then
			table.insert(results, newest)
		end
	end

	return results
end

--[[
	Returns the name a user had when they last wrote to the ledger, so conflicts
	can name teammates even after they've left the session.
]]
function Ledger:getUserName(userId: number): string
	local folders = self:__userFolders()[userId]

	if folders ~= nil then
		for _, folder in folders do
			local name = folder:GetAttribute("UserName")
			if type(name) == "string" then
				return name
			end
		end
	end

	return TeamCreate.getUserName(userId)
end

--[[
	Records that the current user just synced each entry's path with the given
	fingerprint, or removed it if the fingerprint is `false`.
]]
function Ledger:record(entries: { Entry }, time: number?)
	local now = time or TeamCreate.now()

	local byBucket = {}
	for _, entry in entries do
		-- The root is the DataModel itself, which nobody can conflict over.
		if entry.path == nil or entry.path == "" then
			continue
		end

		local bucket = Ledger.bucketOf(entry.path)
		byBucket[bucket] = byBucket[bucket] or {}
		byBucket[bucket][entry.path] = entry.fingerprint
	end

	if next(byBucket) == nil then
		return
	end

	local folder = self:__ownFolder()
	if folder:GetAttribute("UserName") ~= self.__userName then
		folder:SetAttribute("UserName", self.__userName)
	end

	local expiry = now - Ledger.RECORD_LIFETIME

	for bucket, updates in byBucket do
		local value = TeamCreate.getOrCreateChild(folder, bucketName(bucket), "StringValue")

		local records = {}
		for path, entry in decodeBucket(value) do
			if isValidEntry(entry) and entry[2] >= expiry then
				records[path] = entry
			end
		end

		for path, fingerprint in updates do
			records[path] = { fingerprint, now }
		end

		local encoded = HttpService:JSONEncode(records)

		if #encoded > Ledger.MAX_BUCKET_LENGTH then
			-- Drop the oldest records until everything fits. Losing an old
			-- record only means we can't detect a conflict on that path.
			local paths = {}
			for path in records do
				table.insert(paths, path)
			end
			table.sort(paths, function(a, b)
				return records[a][2] < records[b][2]
			end)

			local index = 1
			while #encoded > Ledger.MAX_BUCKET_LENGTH and index <= #paths do
				-- Remove roughly a tenth at a time so we don't re-encode for
				-- every single record.
				local stop = math.min(#paths, index + math.max(1, math.floor(#paths / 10)) - 1)
				for removeIndex = index, stop do
					records[paths[removeIndex]] = nil
				end
				index = stop + 1

				encoded = HttpService:JSONEncode(records)
			end

			Log.debug("Trimmed Rojo Team Create ledger bucket {} to fit", bucketName(bucket))
		end

		value.Value = encoded
	end
end

return Ledger
