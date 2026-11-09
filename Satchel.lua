--[[
	Satchel.lua
	Wiring: saved settings, which bags exist, replacing Blizzard's bag and
	bank windows, events and the /satchel command.

	Blizzard's own bag frames keep working invisibly (reparented to a hidden
	frame), and every bag open/close function is hooked to mirror their open
	state onto our window. Hooking instead of replacing those functions keeps
	Blizzard's code untainted, and mirroring instead of toggling keeps the two
	in step however the bags were opened (bag key, backpack button, vendor).

	The bank works the same way: Blizzard's BankFrame still opens, but is
	parked on a tiny invisible parent while our bank window shows the tabs.
	Its OnHide is removed while parked, because that OnHide ends the banker
	interaction. Our window ends it instead when it closes.
--]]

local ADDON, ns = ...
local C = C_Container

local DEFAULTS = { columns = 10, bankColumns = 14, scale = 1 }
local CHARACTER_BANK = Enum.BankType and Enum.BankType.Character or 0

local function say(msg)
	print('|cff33ff99Satchel|r: ' .. msg)
end

--[[ Bags ]]--

local NUM_BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local NUM_BANK_TABS = NUM_BANKBAGSLOTS
	or (Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumCharacterBankSlots)
	or 0

function ns.InventoryBags()
	local bags = {}
	for bag = BACKPACK_CONTAINER or 0, NUM_BAGS do
		bags[#bags + 1] = bag
	end
	if KEYRING_CONTAINER and HasKey and HasKey() then
		bags[#bags + 1] = KEYRING_CONTAINER
	end
	return bags
end

-- Bank tabs are bags NUM_BAGS+1 onward. Unbought tabs have no slots and are skipped by Layout.
function ns.BankBags()
	local bags = {}
	if BANK_CONTAINER then
		bags[#bags + 1] = BANK_CONTAINER
	end
	for bag = NUM_BAGS + 1, NUM_BAGS + NUM_BANK_TABS do
		bags[#bags + 1] = bag
	end
	return bags
end

--[[ Windows ]]--

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

local atBank = false
local closeBank = C_Bank and C_Bank.CloseBankFrame or CloseBankFrame

local inventory = ns.NewWindow('Inventory', {
	title = function() return UnitName('player') end,
	bags = ns.InventoryBags,
	columns = 'columns',
	money = true,
	sort = C.SortBags,
	default = { 'BOTTOMRIGHT', 'BOTTOMRIGHT', -60, 120 },
	-- Closed by the X button or Escape: tell Blizzard's bag state too, so the
	-- next bag keypress opens instead of closing.
	onHide = function()
		if ns.BlizzardBagsOpen() then
			CloseAllBags()
		end
	end,
})

local bank = ns.NewWindow('Bank', {
	title = function() return BANK or 'Bank' end,
	bags = ns.BankBags,
	columns = 'bankColumns',
	sort = function()
		if C.SortBank then
			C.SortBank(CHARACTER_BANK)
		elseif C.SortBankBags then
			C.SortBankBags()
		end
	end,
	default = { 'TOPLEFT', 'TOPLEFT', 60, -120 },
	onHide = function()
		if atBank and closeBank then
			closeBank()
		end
	end,
})

ns.Inventory, ns.Bank = inventory, bank

local function sync()
	if ns.BlizzardBagsOpen() then
		inventory:Open()
	else
		inventory:Close()
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

--[[ Bank ]]--

-- With no tabs bought there is nothing to show, and buying the first tab
-- happens in Blizzard's window, so it is left alone in that case.
local function bankHasTabs()
	if C_Bank and C_Bank.FetchPurchasedBankTabIDs then
		local ok, ids = pcall(C_Bank.FetchPurchasedBankTabIDs, CHARACTER_BANK)
		if ok and type(ids) == 'table' then
			return #ids > 0
		end
	end
	for _, bag in ipairs(ns.BankBags()) do
		if (C.GetContainerNumSlots(bag) or 0) > 0 then
			return true
		end
	end
	return false
end

local parked = CreateFrame('Frame', nil, UIParent)
parked:SetScale(0.001)
parked:SetAlpha(0)

local blizzardBankOnHide -- BankFrame's own OnHide, saved the first time we see it

local function onBlizzardBankShown(panel)
	if blizzardBankOnHide == nil then
		blizzardBankOnHide = panel:GetScript('OnHide') or false
	end
	local take = bankHasTabs()
	SatchelDB.debug = SatchelDB.debug or {}
	SatchelDB.debug.bank = { t = date('%Y-%m-%d %H:%M:%S'), tabs = take, numTabs = NUM_BANK_TABS }
	if take then
		panel:SetScript('OnHide', nil)
		panel:SetParent(parked)
		atBank = true
		bank:Open()
	else
		panel:SetScript('OnHide', blizzardBankOnHide or nil)
		panel:SetParent(UIParent)
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
	SatchelDB.positions = SatchelDB.positions or {}
	if SatchelDB.point then -- 0.1 kept a single position
		SatchelDB.positions.Inventory, SatchelDB.point = SatchelDB.point, nil
	end
	ns.FlushLog()
	for _, w in ipairs(ns.Windows) do
		w:SetScale(SatchelDB.scale)
		w:RestorePosition()
	end
	events:UnregisterEvent('ADDON_LOADED')
end

function handlers.PLAYER_LOGIN()
	eachBlizzardBag(function(f)
		f:SetParent(hidden)
	end)
	if BankFrame then
		BankFrame:HookScript('OnShow', onBlizzardBankShown)
	end
	local ok, err = pcall(ns.Probe)
	if not ok then
		ns.Log('probe', err)
	end
end

function handlers.BANKFRAME_OPENED()
	-- Tab contents can arrive a moment after the banker opens on the first visit.
	C_Timer.After(0.3, function()
		bank:Refresh()
	end)
end

function handlers.BANKFRAME_CLOSED()
	atBank = false
	bank:Close()
end

function handlers.BAG_UPDATE_DELAYED()
	inventory:Refresh()
	bank:Refresh()
end
handlers.BAG_CONTAINER_UPDATE = handlers.BAG_UPDATE_DELAYED
handlers.QUEST_ACCEPTED = handlers.BAG_UPDATE_DELAYED
handlers.QUEST_REMOVED = handlers.BAG_UPDATE_DELAYED

function handlers.PLAYERBANKSLOTS_CHANGED()
	bank:Refresh()
end
handlers.BANK_TABS_CHANGED = handlers.PLAYERBANKSLOTS_CHANGED
handlers.BANK_TAB_SETTINGS_UPDATED = handlers.PLAYERBANKSLOTS_CHANGED

function handlers.PLAYER_MONEY()
	inventory:Refresh()
end

function handlers.ITEM_LOCK_CHANGED(bag, slot)
	if bag and slot then
		inventory:UpdateLock(bag, slot)
		bank:UpdateLock(bag, slot)
	end
end

function handlers.BAG_UPDATE_COOLDOWN()
	for _, w in ipairs(ns.Windows) do
		if w:IsShown() then
			w:UpdateCooldowns()
		end
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

local function setColumns(key, arg, label)
	local n = tonumber(arg)
	if n and n >= 4 and n <= 36 then
		SatchelDB[key] = math.floor(n)
		inventory:Refresh()
		bank:Refresh()
		say(label .. ' columns set to ' .. SatchelDB[key])
	else
		say('usage: /satchel ' .. (key == 'columns' and 'cols' or 'bankcols') .. ' <4-36>')
	end
end

SLASH_SATCHEL1 = '/satchel'
SlashCmdList.SATCHEL = function(msg)
	local cmd, arg = (msg or ''):match('^(%S*)%s*(.-)$')
	cmd = cmd:lower()

	if cmd == 'cols' or cmd == 'columns' then
		setColumns('columns', arg, 'bag')
	elseif cmd == 'bankcols' then
		setColumns('bankColumns', arg, 'bank')
	elseif cmd == 'scale' then
		local s = tonumber(arg)
		if s and s >= 0.5 and s <= 2 then
			SatchelDB.scale = s
			for _, w in ipairs(ns.Windows) do
				w:SetScale(s)
			end
			say('scale set to ' .. s)
		else
			say('usage: /satchel scale <0.5-2>')
		end
	elseif cmd == 'reset' then
		wipe(SatchelDB.positions)
		for _, w in ipairs(ns.Windows) do
			w:RestorePosition()
		end
		say('positions reset')
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
		say('/satchel cols <n> | bankcols <n> | scale <x> | reset | errors [clear]')
	end
end
