--[[
	Frame.lua
	The bag window: one grid of item buttons covering every equipped bag,
	plus a search box, free-slot count and gold.

	Item buttons use Blizzard's ContainerFrameItemButtonTemplate so clicking,
	dragging, splitting stacks and tooltips behave exactly like the default
	bags. That template finds its bag through its parent's ID, so each bag
	gets an invisible holder frame with SetID(bagID), and each button gets
	SetID(slot).
--]]

local ADDON, ns = ...
local C = C_Container

local SIZE, GAP, PAD = 37, 4, 10
local TOP, BOTTOM = 56, 30 -- title + search above the grid, free/gold below

-- Modern clients have a dedicated ItemButton frame type; fall back to Button.
local BUTTON_TYPE = pcall(CreateFrame, 'ItemButton') and 'ItemButton' or 'Button'

local frame = CreateFrame('Frame', 'SatchelFrame', UIParent, 'BackdropTemplate')
frame:Hide()
frame:SetFrameStrata('HIGH')
frame:SetToplevel(true)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag('LeftButton')
frame:SetBackdrop({
	bgFile = 'Interface\\Tooltips\\UI-Tooltip-Background',
	edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
tinsert(UISpecialFrames, 'SatchelFrame') -- Escape closes it
ns.Frame = frame

frame:SetScript('OnDragStart', frame.StartMoving)
frame:SetScript('OnDragStop', function(self)
	self:StopMovingOrSizing()
	ns.SavePosition()
end)

local title = frame:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
title:SetPoint('TOPLEFT', PAD + 2, -12)

local close = CreateFrame('Button', nil, frame, 'UIPanelCloseButton')
close:SetPoint('TOPRIGHT', -2, -2)

-- Search: prefer the standard search box (magnifier, clear button), else a plain input.
local search
do
	local ok, box = pcall(CreateFrame, 'EditBox', 'SatchelSearchBox', frame, 'SearchBoxTemplate')
	if not ok then
		box = CreateFrame('EditBox', 'SatchelSearchBox', frame, 'InputBoxTemplate')
	end
	search = box
	search:SetAutoFocus(false)
	search:SetHeight(20)
	search:SetPoint('TOPLEFT', PAD + 6, -30)
	search:SetPoint('TOPRIGHT', -PAD - 2, -30)
end

local free = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
free:SetPoint('BOTTOMLEFT', PAD + 2, 12)

local money = CreateFrame('Frame', 'SatchelMoneyFrame', frame, 'SmallMoneyFrameTemplate')
money:SetPoint('BOTTOMRIGHT', -PAD + 6, 10)

local holders = {} -- bagID -> holder frame
local buttons = {} -- bagID -> { [slot] = button }
local created = 0

local function holder(bag)
	local h = holders[bag]
	if not h then
		h = CreateFrame('Frame', nil, frame)
		h:SetID(bag)
		-- Some versions of the item button code ask their container this.
		if not h.IsCombinedBagContainer then
			h.IsCombinedBagContainer = function() return false end
		end
		holders[bag] = h
	end
	return h
end

local function button(bag, slot)
	local list = buttons[bag]
	if not list then
		list = {}
		buttons[bag] = list
	end
	local b = list[slot]
	if not b then
		created = created + 1
		b = CreateFrame(BUTTON_TYPE, 'SatchelItem' .. created, holder(bag), 'ContainerFrameItemButtonTemplate')
		b:SetID(slot)
		list[slot] = b
	end
	return b
end

local function part(b, key, suffix)
	return b[key] or _G[b:GetName() .. suffix]
end

local function updateQuest(b, bag, slot, hasItem)
	local tex = part(b, 'IconQuestTexture', 'IconQuestTexture')
	if not tex then
		return
	end
	local quest = hasItem and C.GetContainerItemQuestInfo and C.GetContainerItemQuestInfo(bag, slot)
	if quest and quest.questID and not quest.isActive and TEXTURE_ITEM_QUEST_BANG then
		tex:SetTexture(TEXTURE_ITEM_QUEST_BANG)
		tex:Show()
	elseif quest and (quest.questID or quest.isQuestItem) and TEXTURE_ITEM_QUEST_BORDER then
		tex:SetTexture(TEXTURE_ITEM_QUEST_BORDER)
		tex:Show()
	else
		tex:Hide()
	end
end

local function updateCooldown(b, bag, slot, hasItem)
	local cd = part(b, 'Cooldown', 'Cooldown')
	if not cd then
		return
	end
	if hasItem then
		local start, duration, enable = C.GetContainerItemCooldown(bag, slot)
		CooldownFrame_Set(cd, start, duration, enable)
	else
		cd:Hide()
	end
end

local function updateButton(b, bag, slot)
	local info = C.GetContainerItemInfo(bag, slot)
	local texture = info and info.iconFileID
	SetItemButtonTexture(b, texture)
	SetItemButtonCount(b, info and info.stackCount or 0)
	SetItemButtonDesaturated(b, info and info.isLocked)
	if SetItemButtonQuality then
		SetItemButtonQuality(b, info and info.quality, info and info.hyperlink)
	end
	updateQuest(b, bag, slot, texture ~= nil)
	updateCooldown(b, bag, slot, texture ~= nil)
	-- Plain field read only by our own search code.
	b.satchelName = info and info.hyperlink and info.hyperlink:match('%[(.-)%]') or nil
end

local function applySearch()
	local text = (search:GetText() or ''):lower()
	for _, list in pairs(buttons) do
		for _, b in ipairs(list) do
			local match = text == '' or (b.satchelName and b.satchelName:lower():find(text, 1, true)) ~= nil
			if b.SetMatchesSearch then
				b:SetMatchesSearch(match)
			else
				b:SetAlpha(match and 1 or 0.25)
			end
		end
	end
end
search:HookScript('OnTextChanged', applySearch)
search:HookScript('OnEscapePressed', function(self) self:ClearFocus() end)
search:HookScript('OnEnterPressed', function(self) self:ClearFocus() end)

-- Positions a button for every slot of every current bag and resizes the window.
function frame:Layout()
	local cols = SatchelDB.columns
	local index = 0
	local active = {}
	for _, bag in ipairs(ns.InventoryBags()) do
		active[bag] = true
		local slots = C.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local b = button(bag, slot)
			local col, row = index % cols, floor(index / cols)
			b:ClearAllPoints()
			b:SetPoint('TOPLEFT', frame, 'TOPLEFT', PAD + col * (SIZE + GAP), -(TOP + row * (SIZE + GAP)))
			b:Show()
			index = index + 1
		end
		local list = buttons[bag]
		if list then
			for slot = slots + 1, #list do
				list[slot]:Hide()
			end
		end
	end
	for bag, list in pairs(buttons) do
		if not active[bag] then
			for _, b in ipairs(list) do
				b:Hide()
			end
		end
	end

	local rows = math.max(1, math.ceil(index / cols))
	self:SetSize(PAD * 2 + cols * SIZE + (cols - 1) * GAP, TOP + rows * SIZE + (rows - 1) * GAP + BOTTOM)
end

function frame:UpdateItems()
	local total, empty = 0, 0
	for _, bag in ipairs(ns.InventoryBags()) do
		local slots = C.GetContainerNumSlots(bag) or 0
		total = total + slots
		empty = empty + (C.GetContainerNumFreeSlots(bag) or 0)
		for slot = 1, slots do
			updateButton(button(bag, slot), bag, slot)
		end
	end
	free:SetFormattedText('%d/%d free', empty, total)
	applySearch()
end

-- Cheap update for ITEM_LOCK_CHANGED: only the lock state of one slot.
function frame:UpdateLock(bag, slot)
	local b = buttons[bag] and buttons[bag][slot]
	if b and b:IsShown() then
		local info = C.GetContainerItemInfo(bag, slot)
		SetItemButtonDesaturated(b, info and info.isLocked)
	end
end

function frame:UpdateCooldowns()
	for bag, list in pairs(buttons) do
		for slot, b in ipairs(list) do
			if b:IsShown() then
				updateCooldown(b, bag, slot, C.GetContainerItemID(bag, slot) ~= nil)
			end
		end
	end
end

function frame:Refresh()
	if self:IsShown() then
		self:Layout()
		self:UpdateItems()
	end
end

function frame:Open()
	if self:IsShown() then
		return
	end
	title:SetText(UnitName('player'))
	self:Layout()
	self:UpdateItems()
	MoneyFrame_Update('SatchelMoneyFrame', GetMoney())
	self:Show()
end

function frame:Close()
	if self:IsShown() then
		self:Hide()
	end
end

-- Closed by the X button or Escape: tell Blizzard's bag state too, so the
-- next bag keypress opens instead of closing.
frame:SetScript('OnHide', function()
	search:ClearFocus()
	if ns.BlizzardBagsOpen() then
		CloseAllBags()
	end
end)
