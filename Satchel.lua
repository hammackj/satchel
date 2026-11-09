--[[
	Satchel.lua
	Wiring: saved settings, which bags exist, replacing Blizzard's bag
	windows, events and the /satchel command.

	Blizzard's own bag frames keep working invisibly (reparented to a hidden
	frame), and every bag open/close function is hooked to mirror their open
	state onto our window. Hooking instead of replacing those functions keeps
	Blizzard's code untainted, and mirroring instead of toggling keeps the two
	in step however the bags were opened (bag key, backpack button, vendor).
--]]

local ADDON, ns = ...
local C = C_Container
local frame = ns.Frame

local DEFAULTS = { columns = 10, scale = 1 }

local function say(msg)
	print('|cff33ff99Satchel|r: ' .. msg)
end

--[[ Bags ]]--

function ns.InventoryBags()
	local bags = {}
	local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
	for bag = BACKPACK_CONTAINER or 0, last do
		bags[#bags + 1] = bag
	end
	if KEYRING_CONTAINER and HasKey and HasKey() then
		bags[#bags + 1] = KEYRING_CONTAINER
	end
	return bags
end

--[[ Blizzard bag frames ]]--

local hidden = CreateFrame('Frame')
hidden:Hide()

local function eachBlizzardBag(fn)
	if ContainerFrameCombinedBags then
		fn(ContainerFrameCombinedBags)
	end
	local i = 1
	while _G['ContainerFrame' .. i] do
		fn(_G['ContainerFrame' .. i])
		i = i + 1
	end
end

function ns.BlizzardBagsOpen()
	local open = false
	eachBlizzardBag(function(f)
		open = open or f:IsShown()
	end)
	return open
end

local function hideBlizzardBags()
	eachBlizzardBag(function(f)
		f:SetParent(hidden)
	end)
end

local function sync()
	if ns.BlizzardBagsOpen() then
		frame:Open()
	else
		frame:Close()
	end
end

for _, name in ipairs({
	'ToggleAllBags', 'OpenAllBags', 'CloseAllBags',
	'ToggleBackpack', 'OpenBackpack', 'CloseBackpack',
	'ToggleBag', 'OpenBag', 'CloseBag',
}) do
	if _G[name] then
		hooksecurefunc(name, sync)
	end
end

--[[ Position ]]--

function ns.SavePosition()
	local point, _, relPoint, x, y = frame:GetPoint(1)
	SatchelDB.point = { point, relPoint, x, y }
end

local function restorePosition()
	frame:ClearAllPoints()
	local p = SatchelDB.point
	if p then
		frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		frame:SetPoint('BOTTOMRIGHT', UIParent, 'BOTTOMRIGHT', -60, 120)
	end
end

--[[ Events ]]--

local events = CreateFrame('Frame')
local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	SatchelDB = SatchelDB or {}
	for k, v in pairs(DEFAULTS) do
		if SatchelDB[k] == nil then
			SatchelDB[k] = v
		end
	end
	ns.FlushLog()
	frame:SetScale(SatchelDB.scale)
	restorePosition()
	events:UnregisterEvent('ADDON_LOADED')
end

function handlers.PLAYER_LOGIN()
	hideBlizzardBags()
	local ok, err = pcall(ns.Probe)
	if not ok then
		ns.Log('probe', err)
	end
end

function handlers.BAG_UPDATE_DELAYED()
	frame:Refresh()
end
handlers.BAG_CONTAINER_UPDATE = handlers.BAG_UPDATE_DELAYED
handlers.QUEST_ACCEPTED = handlers.BAG_UPDATE_DELAYED
handlers.QUEST_REMOVED = handlers.BAG_UPDATE_DELAYED

function handlers.ITEM_LOCK_CHANGED(bag, slot)
	if bag and slot and frame:IsShown() then
		frame:UpdateLock(bag, slot)
	end
end

function handlers.BAG_UPDATE_COOLDOWN()
	if frame:IsShown() then
		frame:UpdateCooldowns()
	end
end

events:SetScript('OnEvent', function(_, event, ...)
	handlers[event](...)
end)
for event in pairs(handlers) do
	-- Not every event exists on every client.
	pcall(events.RegisterEvent, events, event)
end

--[[ /satchel ]]--

SLASH_SATCHEL1 = '/satchel'
SlashCmdList.SATCHEL = function(msg)
	local cmd, arg = (msg or ''):match('^(%S*)%s*(.-)$')
	cmd = cmd:lower()

	if cmd == 'cols' or cmd == 'columns' then
		local n = tonumber(arg)
		if n and n >= 4 and n <= 36 then
			SatchelDB.columns = math.floor(n)
			frame:Refresh()
			say('columns set to ' .. SatchelDB.columns)
		else
			say('usage: /satchel cols <4-36>')
		end
	elseif cmd == 'scale' then
		local s = tonumber(arg)
		if s and s >= 0.5 and s <= 2 then
			SatchelDB.scale = s
			frame:SetScale(s)
			say('scale set to ' .. s)
		else
			say('usage: /satchel scale <0.5-2>')
		end
	elseif cmd == 'reset' then
		SatchelDB.point = nil
		restorePosition()
		say('position reset')
	elseif cmd == 'errors' then
		local log = SatchelDB.debug and SatchelDB.debug.errors or {}
		if arg == 'clear' then
			wipe(log)
			say('error log cleared')
		else
			say(#log .. ' logged error(s); /reload saves them to disk. /satchel errors clear to empty')
		end
	elseif cmd == '' then
		ToggleAllBags()
	else
		say('/satchel  - toggle bags')
		say('/satchel cols <n> | scale <x> | reset | errors [clear]')
	end
end
