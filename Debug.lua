--[[
	Debug.lua
	Development aids. Everything here lands in SatchelDB.debug, which WoW
	writes to WTF/Account/<account>/SavedVariables/Satchel.lua on /reload or
	logout, so errors can be read from disk instead of from screenshots.

	- errors: Lua errors (from any addon, tagged when Satchel is involved)
	  and blocked/forbidden protected actions (taint), newest last.
	- probe: what this client's API actually provides, recorded at login.
--]]

local ADDON, ns = ...

local MAX_ERRORS = 50
local pending = {} -- entries logged before SavedVariables are loaded

local function append(entry)
	SatchelDB.debug = SatchelDB.debug or {}
	local log = SatchelDB.debug.errors or {}
	SatchelDB.debug.errors = log

	local last = log[#log]
	if last and last.msg == entry.msg then
		last.count = (last.count or 1) + 1
		last.t = entry.t
		return
	end
	log[#log + 1] = entry
	while #log > MAX_ERRORS do
		table.remove(log, 1)
	end
end

function ns.Log(kind, msg)
	local entry = { t = date('%Y-%m-%d %H:%M:%S'), kind = kind, msg = tostring(msg) }
	if SatchelDB then
		append(entry)
	else
		pending[#pending + 1] = entry
	end
end

function ns.FlushLog()
	for _, entry in ipairs(pending) do
		append(entry)
	end
	wipe(pending)
end

-- Chain onto the current error handler so the default UI (or BugSack) still sees errors.
do
	local previous = geterrorhandler()
	seterrorhandler(function(msg, ...)
		pcall(function()
			local stack = debugstack and debugstack(3, 12, 0) or ''
			local text = tostring(msg) .. '\n' .. stack
			ns.Log(text:find(ADDON, 1, true) and 'error:satchel' or 'error', text)
		end)
		return previous(msg, ...)
	end)
end

-- Taint: a protected action was blocked because insecure code touched its path.
-- ADDON_LOADED is handled here too, so errors raised while Satchel's other
-- files load (before Satchel.lua can register anything) still get saved.
local watcher = CreateFrame('Frame')
watcher:RegisterEvent('ADDON_ACTION_BLOCKED')
watcher:RegisterEvent('ADDON_ACTION_FORBIDDEN')
watcher:RegisterEvent('ADDON_LOADED')
watcher:SetScript('OnEvent', function(self, event, addon, func)
	if event == 'ADDON_LOADED' then
		if addon == ADDON then
			SatchelDB = SatchelDB or {}
			ns.FlushLog()
			self:UnregisterEvent('ADDON_LOADED')
		end
		return
	end
	ns.Log(event, tostring(addon) .. ' -> ' .. tostring(func) .. (InCombatLockdown() and ' (in combat)' or ''))
end)

local PROBE_GLOBALS = {
	'C_Container', 'C_Item', 'C_Bank', 'C_NewItems', 'C_CurrencyInfo',
	'ContainerFrameCombinedBags', 'ContainerFrameContainer', 'ContainerFrameItemButtonMixin', 'ItemButtonMixin',
	'NUM_CONTAINER_FRAMES', 'NUM_BAG_SLOTS', 'NUM_TOTAL_EQUIPPED_BAG_SLOTS', 'NUM_BANKBAGSLOTS',
	'BACKPACK_CONTAINER', 'BANK_CONTAINER', 'KEYRING_CONTAINER', 'REAGENTBANK_CONTAINER', 'HasKey',
	'ToggleAllBags', 'OpenAllBags', 'CloseAllBags', 'ToggleBackpack', 'OpenBackpack', 'CloseBackpack',
	'ToggleBag', 'OpenBag', 'CloseBag', 'IsBagOpen',
	'SetItemButtonTexture', 'SetItemButtonCount', 'SetItemButtonDesaturated', 'SetItemButtonQuality',
	'CooldownFrame_Set', 'MoneyFrame_Update', 'GetCoinTextureString',
	'TEXTURE_ITEM_QUEST_BANG', 'TEXTURE_ITEM_QUEST_BORDER', 'BankFrame', 'SortBags',
	'NEW_ITEM_ATLAS_BY_QUALITY', 'CloseBankFrame', 'C_PlayerInteractionManager', 'SOUNDKIT',
	'MerchantSellAllJunkButton', 'C_MerchantFrame',
}

local PROBE_TEMPLATES = {
	{ 'ItemButton', 'ContainerFrameItemButtonTemplate' },
	{ 'Button', 'ContainerFrameItemButtonTemplate' },
	{ 'Frame', 'SmallMoneyFrameTemplate' },
	{ 'EditBox', 'SearchBoxTemplate' },
	{ 'EditBox', 'BagSearchBoxTemplate' },
	{ 'EditBox', 'InputBoxTemplate' },
	{ 'Button', 'UIPanelCloseButton' },
	{ 'Frame', 'BackdropTemplate' },
}

local function keys(t)
	local out = {}
	for k in pairs(t or {}) do
		out[#out + 1] = tostring(k)
	end
	table.sort(out)
	return out
end

function ns.Probe()
	local p = {}
	local version, build, _, toc = GetBuildInfo()
	p.client = { version = version, build = build, toc = toc, project = WOW_PROJECT_ID }

	p.globals = {}
	for _, name in ipairs(PROBE_GLOBALS) do
		p.globals[name] = type(_G[name])
	end
	p.container = keys(C_Container)
	p.itemButtonMixin = keys(ContainerFrameItemButtonMixin)
	p.cbank = keys(C_Bank)
	p.bankType = Enum.BankType and CopyTable(Enum.BankType)
	p.numCharacterBankSlots = Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumCharacterBankSlots
	if Enum and Enum.BagIndex then
		p.bagIndex = {}
		for k, v in pairs(Enum.BagIndex) do
			p.bagIndex[k] = v
		end
	end

	p.templates = {}
	local scratch = CreateFrame('Frame')
	scratch:Hide()
	for _, t in ipairs(PROBE_TEMPLATES) do
		local ok, err = pcall(CreateFrame, t[1], nil, scratch, t[2])
		p.templates[t[1] .. ':' .. t[2]] = ok and 'ok' or tostring(err)
	end

	p.bags = {}
	for bag = -5, 20 do
		local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
		if ok and slots and slots > 0 then
			p.bags[tostring(bag)] = slots
		end
	end

	local frames = 0
	while _G['ContainerFrame' .. (frames + 1)] do
		frames = frames + 1
	end
	p.blizzardContainerFrames = frames

	SatchelDB.debug = SatchelDB.debug or {}
	SatchelDB.debug.probe = p
end

-- What the bank looks like to this client, per character, recorded each time
-- the banker opens (Forever shows some characters a tabbed bank and others a
-- classic one: a main grid plus bank bag slots).
function ns.ProbeBank(takenOver)
	local b = { t = date('%Y-%m-%d %H:%M:%S'), takenOver = takenOver }
	local function try(fn, ...)
		if type(fn) ~= 'function' then
			return 'missing'
		end
		local r = { pcall(fn, ...) }
		if not r[1] then
			return 'error: ' .. tostring(r[2])
		end
		table.remove(r, 1)
		return #r <= 1 and r[1] or r
	end
	local bankType = Enum.BankType and Enum.BankType.Character or 0
	b.purchasedTabIDs = C_Bank and try(C_Bank.FetchPurchasedBankTabIDs, bankType)
	local data = C_Bank and try(C_Bank.FetchPurchasedBankTabData, bankType)
	b.purchasedTabData = type(data) == 'table' and #data or data
	b.canPurchaseTab = C_Bank and try(C_Bank.CanPurchaseBankTab, bankType)
	b.numBankSlots = try(GetNumBankSlots)
	b.globals = {}
	for _, name in ipairs({ 'BANK_CONTAINER', 'NUM_BANKBAGSLOTS', 'NUM_BANKGENERIC_SLOTS', 'REAGENTBANK_CONTAINER', 'NUM_BANK_TABS' }) do
		b.globals[name] = _G[name] == nil and 'nil' or _G[name]
	end
	b.bags = {}
	for bag = -5, 30 do
		local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
		if ok and slots and slots > 0 then
			local items = 0
			for slot = 1, slots do
				if C_Container.GetContainerItemInfo(bag, slot) then
					items = items + 1
				end
			end
			b.bags[tostring(bag)] = slots .. ' slots, ' .. items .. ' items'
		end
	end
	b.bankFrameChildren = {}
	if BankFrame then
		for _, child in ipairs({ BankFrame:GetChildren() }) do
			local name = child:GetName()
			if name then
				b.bankFrameChildren[#b.bankFrameChildren + 1] = name .. (child:IsShown() and '' or ' (hidden)')
			end
		end
		table.sort(b.bankFrameChildren)
	end
	SatchelDB.debug = SatchelDB.debug or {}
	SatchelDB.debug.bankProbe = SatchelDB.debug.bankProbe or {}
	SatchelDB.debug.bankProbe[UnitName('player') or '?'] = b
end
