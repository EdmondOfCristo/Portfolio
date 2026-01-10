--[[
	⚠️ Not intended for public use. ⚠️
	DataStoreSystem.luau
--]]

----------------------------------------------------------------
-- Services
----------------------------------------------------------------

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

----------------------------------------------------------------
-- DataStore
----------------------------------------------------------------

local Store = DataStoreService:GetDataStore("PortfolioDataStore_V1")
local DataStore = {}

----------------------------------------------------------------
-- Settings
----------------------------------------------------------------

local DATA_VERSION = 1
local AUTO_SAVE_INTERVAL = 120
local MAX_SAVE_RETRIES = 3
local MAX_BACKUPS = 3
local DEBUG = false

----------------------------------------------------------------
-- Runtime Tracking
----------------------------------------------------------------

-- Tracks active session IDs to prevent duplicate sessions
local ActiveSessions = {}

-- Cached copy of last successful save (useful for debugging / diffing later)
local LastSavedCache = {}

-- Health metrics for monitoring save performance
local SaveFailures = 0
local SaveSuccesses = 0

----------------------------------------------------------------
-- Rejoin Rate Limiting (ANTI-REJOIN ABUSE)
----------------------------------------------------------------

-- Tracks recent join timestamps per UserId
local RejoinTracker = {}

-- Max number of rejoins allowed in the window
local MAX_REJOINS = 3

-- Time window (seconds) for rejoin tracking
local REJOIN_WINDOW = 60

----------------------------------------------------------------
-- Utility
----------------------------------------------------------------

local function DebugPrint(...)
	if DEBUG then
		print("[DataStore]:", ...)
	end
end

----------------------------------------------------------------
-- Schema (VALIDATION + RECONCILIATION)
----------------------------------------------------------------
-- Ensures loaded data always matches expected structure and types

local Schema = {
	leaderstats = {
		Cash = "number",
		Kills = "number",
		Rebirths = "number",
	},
}

local function Reconcile(schema, data)
	for key, expected in pairs(schema) do
		if typeof(expected) == "table" then
			data[key] = data[key] or {}
			Reconcile(expected, data[key])
		else
			if typeof(data[key]) ~= expected then
				-- Reset invalid or missing values safely
				if expected == "number" then
					data[key] = 0
				elseif expected == "string" then
					data[key] = ""
				elseif expected == "boolean" then
					data[key] = false
				end
			end
		end
	end
end

----------------------------------------------------------------
-- Migrations
----------------------------------------------------------------
-- Allows safe evolution of saved data formats

local Migrations = {
	[0] = function(data)
		data.Version = 1
		return data
	end,
}

local function ApplyMigrations(data)
	local version = data.Version or 0

	while version < DATA_VERSION do
		local migrate = Migrations[version]
		if migrate then
			data = migrate(data)
		end
		version += 1
	end

	data.Version = DATA_VERSION
	return data
end

----------------------------------------------------------------
-- Recursive Folder Save / Load
----------------------------------------------------------------
-- Serializes folders of ValueObjects into tables and back

local function SaveFolder(folder)
	local tbl = {}

	for _, obj in ipairs(folder:GetChildren()) do
		if CollectionService:HasTag(obj, "DontSave") then
			continue
		end

		if obj:IsA("ValueBase") then
			tbl[obj.Name] = obj.Value
		elseif obj:IsA("Folder") then
			tbl[obj.Name] = SaveFolder(obj)
		end
	end

	return tbl
end

local function LoadFolder(folder, data)
	if not data then return end

	for _, obj in ipairs(folder:GetChildren()) do
		if CollectionService:HasTag(obj, "DontSave") then
			continue
		end

		local value = data[obj.Name]
		if value == nil then continue end

		if obj:IsA("ValueBase") and typeof(value) == typeof(obj.Value) then
			obj.Value = value
		elseif obj:IsA("Folder") then
			LoadFolder(obj, value)
		end
	end
end

----------------------------------------------------------------
-- Encode / Decode
----------------------------------------------------------------
-- Converts player state to/from savable table format

local function Encode(player)
	return {
		Version = DATA_VERSION,
		SessionId = ActiveSessions[player],
		Timestamp = os.time(),

		leaderstats = SaveFolder(player.leaderstats),
	}
end

local function Decode(player, data)
	LoadFolder(player.leaderstats, data.leaderstats)
end

----------------------------------------------------------------
-- Saving
----------------------------------------------------------------

function DataStore:Save(player)
	if not ActiveSessions[player] then return end

	local attempts = 0
	local success, err

	repeat
		attempts += 1
		success, err = pcall(function()
			local encoded = Encode(player)

			Store:UpdateAsync(player.UserId, function(old)
				old = old or {}

				-- Maintain rolling backups for rollback safety
				old.Backups = old.Backups or {}
				table.insert(old.Backups, 1, old.Data)

				if #old.Backups > MAX_BACKUPS then
					table.remove(old.Backups)
				end

				old.Data = encoded
				return old
			end)
		end)

		if not success then
			task.wait(2)
		end
	until success or attempts >= MAX_SAVE_RETRIES

	if success then
		SaveSuccesses += 1
		LastSavedCache[player] = Encode(player)
	else
		SaveFailures += 1
		warn("Failed to save data for", player.Name, err)
	end
end

----------------------------------------------------------------
-- Loading
----------------------------------------------------------------

function DataStore:Load(player)
	----------------------------------------------------------------
	-- Rejoin Rate Limiting
	----------------------------------------------------------------
	-- Prevents players from repeatedly leaving and rejoining
	-- to abuse reloads or spam datastore requests

	local now = os.time()
	local history = RejoinTracker[player.UserId] or {}

	-- Remove expired join timestamps
	for i = #history, 1, -1 do
		if now - history[i] > REJOIN_WINDOW then
			table.remove(history, i)
		end
	end

	-- Enforce rejoin limit
	if #history >= MAX_REJOINS then
		player:Kick("You are rejoining too frequently. Please wait a moment.")
		return
	end

	-- Record this join
	table.insert(history, now)
	RejoinTracker[player.UserId] = history

	----------------------------------------------------------------
	-- Session Setup & Data Load
	----------------------------------------------------------------

	local sessionId = HttpService:GenerateGUID(false)
	ActiveSessions[player] = sessionId

	local success, stored = pcall(function()
		return Store:GetAsync(player.UserId)
	end)

	if not success then
		player:Kick("Data failed to load. Please rejoin.")
		return
	end

	if stored and stored.Data then
		local data = ApplyMigrations(stored.Data)
		Reconcile(Schema, data)
		Decode(player, data)
	end
end

----------------------------------------------------------------
-- Rollback
----------------------------------------------------------------
-- Restores a previous backup by index (admin/debug use)

function DataStore:Rollback(player, index)
	local success, stored = pcall(function()
		return Store:GetAsync(player.UserId)
	end)

	if success and stored and stored.Backups and stored.Backups[index] then
		Decode(player, stored.Backups[index])
	end
end

----------------------------------------------------------------
-- Health Reporting
----------------------------------------------------------------

function DataStore:GetHealth()
	return {
		SavesSucceeded = SaveSuccesses,
		SavesFailed = SaveFailures,
		ActiveSessions = #Players:GetPlayers(),
	}
end

----------------------------------------------------------------
-- Autosave Loop
----------------------------------------------------------------
-- Periodically saves all active players

task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			DataStore:Save(player)
		end
	end
end)

----------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------
-- Final save + memory cleanup on leave / shutdown

Players.PlayerRemoving:Connect(function(player)
	DataStore:Save(player)
	ActiveSessions[player] = nil
	LastSavedCache[player] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		DataStore:Save(player)
	end
end)

return DataStore
