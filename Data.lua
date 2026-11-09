--[[
	Data.lua
	Remembers every character's bags, bank, equipped items and gold in
	SatchelDB.characters (saved per account, so all characters share it).
	That record drives the "view another character" windows and the item
	counts added to tooltips.

	Each stored bag is { size = n, [slot] = { l = link, c = count, q = quality, id = itemID } }.
--]]

local ADDON, ns = ...
local C = C_Container

local index = {} -- character key -> { [itemID] = { bags, bank, equipped } }, rebuilt on demand

function ns.InitData()
	SatchelDB.characters = SatchelDB.characters or {}
	local name, realm = UnitName('player'), GetRealmName()
	ns.me = name .. ' - ' .. realm
	local c = SatchelDB.characters[ns.me] or {}
	SatchelDB.characters[ns.me] = c
	c.name, c.realm = name, realm
	c.class = select(2, UnitClass('player'))
end

function ns.Character(key)
	return SatchelDB and SatchelDB.characters and SatchelDB.characters[key or ns.me]
end

local function snapshot(bags)
	local out = {}
	for _, bag in ipairs(bags) do
		local size = C.GetContainerNumSlots(bag) or 0
		if size > 0 then
			local t = { size = size }
			for slot = 1, size do
				local info = C.GetContainerItemInfo(bag, slot)
				if info and info.hyperlink then
					t[slot] = { l = info.hyperlink, c = info.stackCount, q = info.quality, id = info.itemID, b = info.isBound or nil }
				end
			end
			out[bag] = t
		end
	end
	return out
end

function ns.SaveInventory()
	local c = ns.Character()
	if not c then
		return
	end
	c.inventory = snapshot(ns.InventoryBags(true))
	c.money = GetMoney()
	local equipped = {}
	for slot = 1, 19 do
		local id = GetInventoryItemID('player', slot)
		if id then
			equipped[id] = (equipped[id] or 0) + 1
		end
	end
	c.equipped = equipped
	c.updated = time()
	index[ns.me] = nil
end

function ns.SaveBank()
	local c = ns.Character()
	if not c then
		return
	end
	c.bank = snapshot(ns.BankBags())
	index[ns.me] = nil
end

--[[ Gold ]]--

local coinString = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString or GetCoinTextureString

function ns.Coins(copper)
	copper = copper or 0
	if coinString then
		return coinString(copper)
	end
	return ('%dg %ds %dc'):format(floor(copper / 10000), floor(copper / 100) % 100, copper % 100)
end

-- Every character's gold, richest first, with a total.
function ns.ShowGoldTooltip(owner)
	GameTooltip:SetOwner(owner, 'ANCHOR_TOPRIGHT')
	GameTooltip:SetText('Gold')
	local keys, total = ns.CharacterKeys(), 0
	table.sort(keys, function(a, b)
		return (ns.Character(a).money or 0) > (ns.Character(b).money or 0)
	end)
	for _, key in ipairs(keys) do
		local money = ns.Character(key).money or 0
		total = total + money
		GameTooltip:AddDoubleLine(ns.CharacterLabel(key), ns.Coins(money), 1, 1, 1, 1, 1, 1)
	end
	if #keys > 1 then
		GameTooltip:AddDoubleLine('Total', ns.Coins(total), 1, 0.82, 0, 1, 1, 1)
	end
	GameTooltip:Show()
end

--[[ Protected items ]]--
-- Alt-click marks an item (by item ID, account-wide): Sell junk and
-- right-click selling at a vendor leave it alone, and sorting leaves it in its slot.

function ns.IsProtected(itemID)
	return itemID ~= nil and SatchelDB.protected[itemID] == true
end

function ns.ToggleProtected(itemID, link)
	SatchelDB.protected[itemID] = not SatchelDB.protected[itemID] or nil
	print('|cff33ff99Satchel|r: ' .. (link or itemID) .. (SatchelDB.protected[itemID] and ' is protected from selling' or ' is no longer protected'))
	ns.RefreshAll()
end

--[[ Characters ]]--

-- Current character first, then the rest by name.
function ns.CharacterKeys(field)
	local keys = {}
	for key, c in pairs(SatchelDB.characters or {}) do
		if not field or c[field] then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b)
		if a == ns.me or b == ns.me then
			return a == ns.me
		end
		return a < b
	end)
	return keys
end

function ns.CharacterLabel(key)
	local c = ns.Character(key)
	if not c then
		return key
	end
	local label = c.name
	if c.realm ~= GetRealmName() then
		label = label .. ' - ' .. c.realm
	end
	local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class or '']
	if color and color.colorStr then
		label = '|c' .. color.colorStr .. label .. '|r'
	end
	return label
end

function ns.Forget(name)
	local removed = 0
	for key, c in pairs(SatchelDB.characters or {}) do
		if key ~= ns.me and (c.name or ''):lower() == name:lower() then
			SatchelDB.characters[key] = nil
			index[key] = nil
			removed = removed + 1
		end
	end
	return removed
end

--[[ Tooltip counts ]]--

local function countsFor(key)
	local idx = index[key]
	if idx then
		return idx
	end
	idx = {}
	local c = SatchelDB.characters[key]
	local function add(id, field, n)
		local e = idx[id]
		if not e then
			e = { 0, 0, 0 }
			idx[id] = e
		end
		e[field] = e[field] + n
	end
	for field, set in pairs({ [1] = c.inventory, [2] = c.bank }) do
		for _, t in pairs(set) do
			for slot = 1, t.size do
				local item = t[slot]
				if item and item.id then
					add(item.id, field, item.c or 1)
				end
			end
		end
	end
	for id, n in pairs(c.equipped or {}) do
		add(id, 3, n)
	end
	index[key] = idx
	return idx
end

local PLACES = { 'Bags', 'Bank', 'Equipped' }

local function addCounts(tooltip, itemID)
	if not itemID or not SatchelDB or not SatchelDB.tooltipCounts or not SatchelDB.characters then
		return
	end
	local total, lines = 0, 0
	for _, key in ipairs(ns.CharacterKeys()) do
		local e = countsFor(key)[itemID]
		local n = e and (e[1] + e[2] + e[3]) or 0
		if n > 0 then
			local parts = {}
			for i, place in ipairs(PLACES) do
				if e[i] > 0 then
					parts[#parts + 1] = place .. ' ' .. e[i]
				end
			end
			if lines == 0 then
				tooltip:AddLine(' ')
			end
			tooltip:AddDoubleLine(ns.CharacterLabel(key), n .. ' |cffaaaaaa(' .. table.concat(parts, ', ') .. ')|r', 1, 1, 1, 1, 1, 1)
			total, lines = total + n, lines + 1
		end
	end
	if lines > 1 then
		tooltip:AddDoubleLine('Total', total, 1, 0.82, 0, 1, 0.82, 0)
	end
	if lines > 0 then
		tooltip:Show()
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		if tooltip == GameTooltip or tooltip == ItemRefTooltip then
			addCounts(tooltip, data and data.id)
		end
	end)
else
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		tooltip:HookScript('OnTooltipSetItem', function(self)
			local _, link = self:GetItem()
			addCounts(self, link and tonumber(link:match('item:(%d+)')))
		end)
	end
end
