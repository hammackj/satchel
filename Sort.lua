--[[
	Sort.lua
	Satchel's own sort, used when the bags being sorted hold protected
	(Alt-clicked) items: Blizzard's sort runs on the server and can't skip
	single items, so this one moves items itself and leaves protected items in
	their slots.

	It runs as a series of single moves (pick up, put down), waiting after each
	for the server to unlock the items involved:
	  1. stack: merge partial stacks of the same item;
	  2. sort: swap items until every free slot holds the item it should.
	Bags that only take certain items (reagent bag, keyring, profession bags)
	are sorted as separate groups so nothing is moved where it can't go.
--]]

local ADDON, ns = ...
local C = C_Container

local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetDetailedItemLevelInfo = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo

local STEP = 0.05 -- seconds between checks while waiting for the server
local TIMEOUT = 30 -- give up after this long

-- Item class order (Enum.ItemClass): gear first, then things you use, then the rest.
local CLASS_ORDER = {
	[2] = 1, [4] = 2, -- weapon, armor
	[0] = 3, -- consumable
	[12] = 4, -- quest
	[1] = 5, -- container
	[7] = 6, [5] = 7, -- trade goods, reagent
	[9] = 8, [3] = 9, [16] = 10, -- recipe, gem, glyph
	[15] = 11, -- miscellaneous
}

-- Items present in the given positions, with what's needed to order them.
local function itemAt(bag, slot)
	local info = C.GetContainerItemInfo(bag, slot)
	if not info or not info.hyperlink then
		return nil
	end
	local name, _, quality, _, _, _, _, maxStack, equipLoc, _, _, classID, subclassID = GetItemInfo(info.hyperlink)
	return {
		link = info.hyperlink,
		id = info.itemID,
		count = info.stackCount or 1,
		locked = info.isLocked,
		name = name or '',
		quality = quality or info.quality or 1,
		maxStack = maxStack or 1,
		equipLoc = equipLoc or '',
		class = CLASS_ORDER[classID or -1] or 50,
		subclass = subclassID or 0,
		level = GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(info.hyperlink) or 0,
	}
end

local function before(a, b)
	-- Junk goes last.
	if (a.quality == 0) ~= (b.quality == 0) then
		return b.quality == 0
	end
	if a.class ~= b.class then
		return a.class < b.class
	end
	if a.subclass ~= b.subclass then
		return a.subclass < b.subclass
	end
	if a.equipLoc ~= b.equipLoc then
		return a.equipLoc < b.equipLoc
	end
	if a.quality ~= b.quality then
		return a.quality > b.quality
	end
	if a.level ~= b.level then
		return a.level > b.level
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	if a.id ~= b.id then
		return a.id < b.id
	end
	if a.link ~= b.link then
		return a.link < b.link
	end
	return a.count > b.count
end

local function same(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.link == b.link and a.count == b.count
end

-- Splits bags into groups that can be sorted together.
local REAGENT_BAG = Enum.BagIndex and Enum.BagIndex.ReagentBag
local function groups(bags)
	local out, byKey = {}, {}
	for _, bag in ipairs(bags) do
		local slots = C.GetContainerNumSlots(bag) or 0
		if slots > 0 then
			local key
			if bag == KEYRING_CONTAINER then
				key = 'keyring'
			elseif bag == REAGENT_BAG then
				key = 'reagent'
			else
				local _, family = C.GetContainerNumFreeSlots(bag)
				key = 'family' .. (family or 0)
			end
			if not byKey[key] then
				byKey[key] = {}
				out[#out + 1] = byKey[key]
			end
			for slot = 1, slots do
				tinsert(byKey[key], { bag, slot })
			end
		end
	end
	return out
end

-- Positions in a group that aren't holding a protected item.
local function freePositions(group)
	local out = {}
	for _, pos in ipairs(group) do
		local id = C.GetContainerItemID(pos[1], pos[2])
		if not ns.IsProtected(id) then
			out[#out + 1] = pos
		end
	end
	return out
end

local function move(from, to)
	ClearCursor()
	C.PickupContainerItem(from[1], from[2])
	C.PickupContainerItem(to[1], to[2])
	ClearCursor()
end

-- One move toward merged stacks; false when there's nothing left to merge.
local function stackStep(positions)
	local partial = {} -- link -> first position holding a partial stack
	for _, pos in ipairs(positions) do
		local item = itemAt(pos[1], pos[2])
		if item and item.count < item.maxStack then
			local first = partial[item.link]
			if first then
				move(pos, first)
				return true
			end
			partial[item.link] = pos
		end
	end
	return false
end

-- One move toward the target order; false when everything is in place,
-- nil when the bags no longer match the plan (something else moved items).
local function sortStep(positions, target)
	for i, pos in ipairs(positions) do
		local want = target[i]
		if not same(itemAt(pos[1], pos[2]), want) then
			for j = i + 1, #positions do
				local other = positions[j]
				if same(itemAt(other[1], other[2]), want) then
					move(other, pos)
					return true
				end
			end
			return nil
		end
	end
	return false
end

local function plan(positions)
	local items = {}
	for _, pos in ipairs(positions) do
		local item = itemAt(pos[1], pos[2])
		if item then
			items[#items + 1] = item
		end
	end
	table.sort(items, before)
	return items -- target[i] for positions[i]; positions past #items stay empty
end

local function busy(positions)
	if GetCursorInfo() then
		return true
	end
	for _, pos in ipairs(positions) do
		local info = C.GetContainerItemInfo(pos[1], pos[2])
		if info and info.isLocked then
			return true
		end
	end
	return false
end

local running = false

local function hasProtected(bags)
	for _, bag in ipairs(bags) do
		for slot = 1, C.GetContainerNumSlots(bag) or 0 do
			if ns.IsProtected(C.GetContainerItemID(bag, slot)) then
				return true
			end
		end
	end
	return false
end

-- Sorts bags, keeping protected items in place. blizzardSort is used when
-- there are none (it's instant). stillValid returns false to stop early
-- (e.g. the bank was closed).
function ns.SortBags(bags, blizzardSort, stillValid)
	if running then
		return
	end
	if InCombatLockdown() then
		print('|cff33ff99Satchel|r: can\'t sort in combat')
		return
	end
	if not hasProtected(bags) then
		blizzardSort()
		return
	end

	running = true
	local work = groups(bags)
	local g, phase, target, positions = 1, 'stack', nil, nil
	local started = GetTime()

	local function finish(msg)
		running = false
		if msg then
			print('|cff33ff99Satchel|r: ' .. msg)
		end
		ns.RefreshAll()
	end

	local function tick()
		if InCombatLockdown() then
			return finish('sort stopped: entered combat')
		end
		if (stillValid and not stillValid()) or GetTime() - started > TIMEOUT then
			return finish('sort stopped')
		end
		local group = work[g]
		if not group then
			return finish()
		end
		positions = positions or freePositions(group)
		if busy(positions) then
			return C_Timer.After(STEP, tick)
		end

		if phase == 'stack' then
			if not stackStep(positions) then
				phase, target = 'sort', plan(positions)
			end
		else
			local moved = sortStep(positions, target)
			if moved == nil then
				return finish('sort stopped: bags changed while sorting')
			elseif moved == false then
				g, phase, target, positions = g + 1, 'stack', nil, nil
			end
		end
		C_Timer.After(STEP, tick)
	end

	tick()
end
