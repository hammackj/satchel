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

local DEFAULTS = {
	columns = 10, bankColumns = 14, scale = 1,
	itemLevel = true, junkIcon = true, tooltipCounts = true,
	boe = true, upgrades = true, showKeyring = true,
}
local CHARACTER_BANK = Enum.BankType and Enum.BankType.Character or 0

local function say(msg)
	print('|cff33ff99Satchel|r: ' .. msg)
end

--[[ Bags ]]--

local NUM_BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local NUM_BANK_TABS = NUM_BANKBAGSLOTS
	or (Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumCharacterBankSlots)
	or 0

-- all: include the keyring even when it's hidden (for saving).
function ns.InventoryBags(all)
	local bags = {}
	for bag = BACKPACK_CONTAINER or 0, NUM_BAGS do
		bags[#bags + 1] = bag
	end
	if KEYRING_CONTAINER and HasKey and HasKey() and (all or SatchelDB.showKeyring) then
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

local inventory, bank

-- Title-bar button: show the bank (saved copy when away from a banker) of
-- whoever the bag window is showing.
local function toggleBank()
	if bank:IsShown() then
		bank:Hide()
	else
		bank.owner = inventory.owner
		bank:Open()
	end
end

local junkButton -- created below, shown at merchants

inventory = ns.NewWindow('Inventory', {
	title = function() return ns.CharacterLabel(ns.me) end,
	bags = ns.InventoryBags,
	store = 'inventory',
	live = function() return true end,
	columns = 'columns',
	money = true,
	sort = function()
		ns.SortBags(ns.InventoryBags(true), C.SortBags)
	end,
	buttons = {
		{ 'Interface\\Icons\\INV_Misc_Coin_02', 'Bank', toggleBank },
		{ 'Interface\\Icons\\INV_Misc_Key_03', 'Show/hide keyring', function()
			SatchelDB.showKeyring = not SatchelDB.showKeyring
			inventory:Refresh()
		end },
	},
	onRender = function(live)
		ns.UpdateJunkButton(live)
	end,
	default = { 'BOTTOMRIGHT', 'BOTTOMRIGHT', -60, 120 },
	-- Closed by the X button or Escape: tell Blizzard's bag state too, so the
	-- next bag keypress opens instead of closing.
	onHide = function()
		if ns.BlizzardBagsOpen() then
			CloseAllBags()
		end
	end,
})

bank = ns.NewWindow('Bank', {
	title = function() return ns.CharacterLabel(ns.me) .. ' - ' .. (BANK or 'Bank') end,
	bags = ns.BankBags,
	store = 'bank',
	live = function() return atBank end,
	columns = 'bankColumns',
	sort = function()
		ns.SortBags(ns.BankBags(), function()
			if C.SortBank then
				C.SortBank(CHARACTER_BANK)
			elseif C.SortBankBags then
				C.SortBankBags()
			end
		end, function() return atBank end)
	end,
	default = { 'TOPLEFT', 'TOPLEFT', 60, -120 },
	onHide = function()
		if atBank and closeBank then
			closeBank()
		end
	end,
})

ns.Inventory, ns.Bank = inventory, bank

function ns.RefreshAll()
	inventory:Refresh()
	bank:Refresh()
end

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
		bank.owner = nil
		if bank:IsShown() then
			bank:Render()
		else
			bank:Open()
		end
	else
		panel:SetScript('OnHide', blizzardBankOnHide or nil)
		panel:SetParent(UIParent)
	end
end

--[[ Junk ]]--

local atMerchant = false
-- Bumped by each Sell junk click, so a second click replaces the first queue.
local sellRun = 0
local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

function ns.AtMerchant()
	return atMerchant
end

-- Grey items that sell for something and aren't protected, with their total
-- value, and whether any grey item was skipped because it's protected.
local function junk()
	local slots, value, skipped = {}, 0, false
	for _, bag in ipairs(ns.InventoryBags(true)) do
		for slot = 1, C.GetContainerNumSlots(bag) or 0 do
			local info = C.GetContainerItemInfo(bag, slot)
			if info and info.quality == 0 and not info.hasNoValue then
				if ns.IsProtected(info.itemID) then
					skipped = true
				else
					slots[#slots + 1] = { bag, slot, info.hyperlink }
					local price = select(11, GetItemInfo(info.hyperlink))
					value = value + (price or 0) * (info.stackCount or 1)
				end
			end
		end
	end
	return slots, value, skipped
end

local function sellJunk()
	sellRun = sellRun + 1 -- cancels any queue still running
	local slots, _, skipped = junk()
	-- Blizzard's sell-all would also sell protected greys, so only use it when there are none.
	if not skipped and C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
		C_MerchantFrame.SellAllJunkItems()
		return
	end
	-- One at a time, spaced out so the vendor keeps up. Items can move while
	-- this runs (sorting, looting, dragging), so each sale checks the slot
	-- still holds the same sellable grey item; otherwise it's left alone.
	local run = sellRun
	for i, s in ipairs(slots) do
		C_Timer.After((i - 1) * 0.2, function()
			if run ~= sellRun or not atMerchant then
				return
			end
			local info = C.GetContainerItemInfo(s[1], s[2])
			if info and info.hyperlink == s[3] and info.quality == 0 and not info.hasNoValue
				and not info.isLocked and not ns.IsProtected(info.itemID) then
				C.UseContainerItem(s[1], s[2])
			end
		end)
	end
end

-- The vendor window's own "Sell All Junk" button runs Blizzard's sell-all,
-- which knows nothing about Satchel's locks and sells locked greys too. When
-- there are locked greys, send it through Satchel's queue instead; otherwise
-- leave Blizzard's button (and its confirmation) alone.
local vendorHooked = false
local function hookVendorButton()
	local button = MerchantSellAllJunkButton
	if vendorHooked or not button then
		return
	end
	vendorHooked = true
	local blizzard = button:GetScript('OnClick')
	button:SetScript('OnClick', function(self, ...)
		if select(3, junk()) then
			print('|cff33ff99Satchel|r: selling junk, keeping your locked items')
			sellJunk()
		elseif blizzard then
			blizzard(self, ...)
		end
	end)
end

junkButton = CreateFrame('Button', nil, inventory, 'UIPanelButtonTemplate')
junkButton:SetSize(80, 20)
junkButton:SetPoint('BOTTOM', 0, 8)
junkButton:SetText('Sell junk')
junkButton:Hide()
junkButton:SetScript('OnClick', sellJunk)
junkButton:SetScript('OnEnter', function(self)
	local slots, value = junk()
	GameTooltip:SetOwner(self, 'ANCHOR_TOP')
	GameTooltip:SetText('Sell junk')
	GameTooltip:AddLine(#slots .. ' grey item(s) worth ' .. ns.Coins(value), 1, 1, 1)
	if select(3, junk()) then
		GameTooltip:AddLine('Protected items are kept', 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end)
junkButton:SetScript('OnLeave', GameTooltip_Hide)

function ns.UpdateJunkButton(live)
	if live == nil then
		live = inventory:IsLive()
	end
	local show = atMerchant and live
	junkButton:SetShown(show)
	if show then
		junkButton:SetEnabled(#(junk()) > 0)
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
	SatchelDB.protected = SatchelDB.protected or {}
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
	ns.InitData()
	ns.SaveInventory()
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
		if atBank then
			ns.SaveBank()
			bank:Refresh()
		end
	end)
end

function handlers.BANKFRAME_CLOSED()
	if atBank then
		ns.SaveBank()
	end
	atBank = false
	bank:Close()
end

function handlers.BAG_UPDATE_DELAYED()
	ns.SaveInventory()
	if atBank then
		ns.SaveBank()
	end
	inventory:Refresh()
	bank:Refresh()
end
handlers.PLAYER_EQUIPMENT_CHANGED = handlers.BAG_UPDATE_DELAYED
handlers.BAG_CONTAINER_UPDATE = handlers.BAG_UPDATE_DELAYED
handlers.QUEST_ACCEPTED = handlers.BAG_UPDATE_DELAYED
handlers.QUEST_REMOVED = handlers.BAG_UPDATE_DELAYED

function handlers.PLAYERBANKSLOTS_CHANGED()
	if atBank then
		ns.SaveBank()
	end
	bank:Refresh()
end
handlers.BANK_TABS_CHANGED = handlers.PLAYERBANKSLOTS_CHANGED
handlers.BANK_TAB_SETTINGS_UPDATED = handlers.PLAYERBANKSLOTS_CHANGED

function handlers.PLAYER_MONEY()
	ns.SaveInventory()
	inventory:Refresh()
end

-- What this character can wear changes with level and skills.
function handlers.PLAYER_LEVEL_UP()
	ns.ClearUsableCache()
	ns.RefreshAll()
end
handlers.SKILL_LINES_CHANGED = handlers.PLAYER_LEVEL_UP

function handlers.MERCHANT_SHOW()
	atMerchant = true
	hookVendorButton()
	ns.UpdateJunkButton()
end

function handlers.MERCHANT_CLOSED()
	atMerchant = false
	sellRun = sellRun + 1
	ns.UpdateJunkButton()
end

-- Item levels and sell prices need item data the client may not have cached
-- yet; redraw once a burst of it has arrived.
local itemInfoPending = false
function handlers.GET_ITEM_INFO_RECEIVED()
	if itemInfoPending then
		return
	end
	itemInfoPending = true
	C_Timer.After(0.3, function()
		itemInfoPending = false
		inventory:Refresh()
		bank:Refresh()
	end)
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
	elseif cmd == 'ilvl' or cmd == 'junk' or cmd == 'counts' or cmd == 'boe' or cmd == 'upgrades' or cmd == 'keys' then
		local key = ({
			ilvl = 'itemLevel', junk = 'junkIcon', counts = 'tooltipCounts',
			boe = 'boe', upgrades = 'upgrades', keys = 'showKeyring',
		})[cmd]
		SatchelDB[key] = not SatchelDB[key]
		inventory:Refresh()
		bank:Refresh()
		say(cmd .. ' ' .. (SatchelDB[key] and 'on' or 'off'))
	elseif cmd == 'forget' then
		if arg == '' then
			say('usage: /satchel forget <character name>')
		else
			say('forgot ' .. ns.Forget(arg) .. ' character(s) named ' .. arg)
		end
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
		say('/satchel cols <n> | bankcols <n> | scale <x> | reset')
		say('/satchel ilvl | boe | upgrades | junk | counts | keys  - toggle item level, BoE, upgrade arrows, junk coin, tooltip counts, keyring')
		say('Alt-click an item to protect it from selling')
		say('/satchel forget <name>  - drop a deleted character\'s saved bags')
		say('/satchel errors [clear]')
	end
end
