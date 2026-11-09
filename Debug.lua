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
local taint = CreateFrame('Frame')
taint:RegisterEvent('ADDON_ACTION_BLOCKED')
taint:RegisterEvent('ADDON_ACTION_FORBIDDEN')
taint:SetScript('OnEvent', function(_, event, addon, func)
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
