--[[
	Window.lua
	A bag window: one grid of item buttons covering a list of bags, with a
	title, sort button, search box, free-slot count and (optionally) gold.
	The inventory and the bank are both windows made by ns.NewWindow.

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

ns.ICON = 'Interface\\Icons\\INV_Misc_Bag_08'

-- Modern clients have a dedicated ItemButton frame type; fall back to Button.
local BUTTON_TYPE = pcall(CreateFrame, 'ItemButton') and 'ItemButton' or 'Button'
local created = 0 -- item buttons made so far, across all windows (for unique names)

local function part(b, key, suffix)
	return b[key] or _G[b:GetName() .. suffix]
end

--[[ Item buttons ]]--

local function setGlow(b, new, paid, quality)
	if b.BattlepayItemTexture then
		b.BattlepayItemTexture:SetShown(new and paid)
	end
	local glow = b.NewItemTexture
	if not glow then
		return
	end
	glow:SetShown(new)
	if new then
		glow:SetAtlas(NEW_ITEM_ATLAS_BY_QUALITY and quality and NEW_ITEM_ATLAS_BY_QUALITY[quality] or 'bags-glow-white')
	end
	for _, anim in ipairs({ b.newitemglowAnim, b.flashAnim }) do
		if new then
			anim:Play()
		else
			anim:Stop()
		end
	end
end

-- Hovering a new item marks it seen, as in the default bags.
local function markSeen(b)
	if b.NewItemTexture and b.NewItemTexture:IsShown() then
		if C_NewItems then
			C_NewItems.RemoveNewItem(b:GetParent():GetID(), b:GetID())
		end
		setGlow(b, false)
	end
end

local function newButton(holder, slot)
	created = created + 1
	local b = CreateFrame(BUTTON_TYPE, 'SatchelItem' .. created, holder, 'ContainerFrameItemButtonTemplate')
	b:SetID(slot)
	-- The template's own event/show handlers assume Blizzard's bag frames;
	-- everything they would update is done by updateButton instead.
	b:SetScript('OnEvent', nil)
	b:SetScript('OnShow', nil)
	-- The template starts with its "new item" and blue "purchased item"
	-- glows visible.
	setGlow(b, false)
	b:HookScript('OnEnter', markSeen)
	return b
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

	local new = texture ~= nil and C_NewItems ~= nil and C_NewItems.IsNewItem(bag, slot) or false
	local paid = new and C.IsBattlePayItem ~= nil and C.IsBattlePayItem(bag, slot) or false
	setGlow(b, new, paid, info and info.quality)

	-- Plain field read only by our own search code.
	b.satchelName = info and info.hyperlink and info.hyperlink:match('%[(.-)%]') or nil
end

--[[ Window ]]--

local Window = {}

-- opts:
--   title     string shown in the title bar, or a function returning one
--   bags      function returning the list of bag IDs to show
--   columns   SatchelDB key holding the column count
--   money     true to show the player's gold
--   sort      function that sorts these bags (adds a sort button)
--   onHide    function called after the window hides
--   default   default position: { point, relPoint, x, y }
function ns.NewWindow(key, opts)
	local name = 'Satchel' .. key .. 'Frame'
	local frame = CreateFrame('Frame', name, UIParent, 'BackdropTemplate')
	Mixin(frame, Window)
	frame.key, frame.opts = key, opts
	frame.holders, frame.buttons = {}, {}

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
	tinsert(UISpecialFrames, name) -- Escape closes it

	frame:SetScript('OnDragStart', frame.StartMoving)
	frame:SetScript('OnDragStop', function(self)
		self:StopMovingOrSizing()
		self:SavePosition()
	end)

	local icon = frame:CreateTexture(nil, 'ARTWORK')
	icon:SetTexture(ns.ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetSize(18, 18)
	icon:SetPoint('TOPLEFT', PAD, -9)

	frame.title = frame:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
	frame.title:SetPoint('LEFT', icon, 'RIGHT', 6, 0)

	local close = CreateFrame('Button', nil, frame, 'UIPanelCloseButton')
	close:SetPoint('TOPRIGHT', -2, -2)

	if opts.sort then
		local sort = CreateFrame('Button', nil, frame)
		sort:SetSize(18, 18)
		sort:SetPoint('RIGHT', close, 'LEFT', -2, 0)
		sort:SetNormalTexture('Interface\\Icons\\INV_Pet_Broom')
		sort:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square', 'ADD')
		sort:SetScript('OnClick', function()
			opts.sort()
			if SOUNDKIT and SOUNDKIT.UI_BAG_SORTING_01 then
				PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
			end
		end)
		sort:SetScript('OnEnter', function(self)
			GameTooltip:SetOwner(self, 'ANCHOR_LEFT')
			GameTooltip:SetText('Sort')
			GameTooltip:Show()
		end)
		sort:SetScript('OnLeave', GameTooltip_Hide)
	end

	-- Search: prefer the standard search box (magnifier, clear button), else a plain input.
	local ok, search = pcall(CreateFrame, 'EditBox', 'Satchel' .. key .. 'Search', frame, 'SearchBoxTemplate')
	if not ok then
		search = CreateFrame('EditBox', 'Satchel' .. key .. 'Search', frame, 'InputBoxTemplate')
	end
	search:SetAutoFocus(false)
	search:SetHeight(20)
	search:SetPoint('TOPLEFT', PAD + 6, -30)
	search:SetPoint('TOPRIGHT', -PAD - 2, -30)
	search:HookScript('OnTextChanged', function() frame:ApplySearch() end)
	search:HookScript('OnEscapePressed', search.ClearFocus)
	search:HookScript('OnEnterPressed', search.ClearFocus)
	frame.search = search

	frame.free = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
	frame.free:SetPoint('BOTTOMLEFT', PAD + 2, 12)

	if opts.money then
		frame.money = CreateFrame('Frame', 'Satchel' .. key .. 'Money', frame, 'SmallMoneyFrameTemplate')
		frame.money:SetPoint('BOTTOMRIGHT', -PAD + 6, 10)
	end

	frame:SetScript('OnHide', function(self)
		self.search:ClearFocus()
		if opts.onHide then
			opts.onHide()
		end
	end)

	ns.Windows = ns.Windows or {}
	tinsert(ns.Windows, frame)
	return frame
end

function Window:Holder(bag)
	local h = self.holders[bag]
	if not h then
		h = CreateFrame('Frame', nil, self)
		h:SetID(bag)
		-- Some versions of the item button code ask their container this.
		h.IsCombinedBagContainer = h.IsCombinedBagContainer or function() return false end
		self.holders[bag] = h
	end
	return h
end

function Window:Button(bag, slot)
	local list = self.buttons[bag]
	if not list then
		list = {}
		self.buttons[bag] = list
	end
	local b = list[slot]
	if not b then
		b = newButton(self:Holder(bag), slot)
		list[slot] = b
	end
	return b
end

function Window:ApplySearch()
	local text = (self.search:GetText() or ''):lower()
	for _, list in pairs(self.buttons) do
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

-- Positions a button for every slot of every current bag and resizes the window.
function Window:Layout()
	local cols = SatchelDB[self.opts.columns]
	local index = 0
	local active = {}
	for _, bag in ipairs(self.opts.bags()) do
		active[bag] = true
		local slots = C.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local b = self:Button(bag, slot)
			local col, row = index % cols, floor(index / cols)
			b:ClearAllPoints()
			b:SetPoint('TOPLEFT', self, 'TOPLEFT', PAD + col * (SIZE + GAP), -(TOP + row * (SIZE + GAP)))
			b:Show()
			index = index + 1
		end
		local list = self.buttons[bag]
		if list then
			for slot = slots + 1, #list do
				list[slot]:Hide()
			end
		end
	end
	for bag, list in pairs(self.buttons) do
		if not active[bag] then
			for _, b in ipairs(list) do
				b:Hide()
			end
		end
	end

	local rows = math.max(1, math.ceil(index / cols))
	self:SetSize(PAD * 2 + cols * SIZE + (cols - 1) * GAP, TOP + rows * SIZE + (rows - 1) * GAP + BOTTOM)
end

function Window:UpdateItems()
	local total, empty = 0, 0
	for _, bag in ipairs(self.opts.bags()) do
		local slots = C.GetContainerNumSlots(bag) or 0
		total = total + slots
		empty = empty + (C.GetContainerNumFreeSlots(bag) or 0)
		for slot = 1, slots do
			updateButton(self:Button(bag, slot), bag, slot)
		end
	end
	self.free:SetFormattedText('%d/%d free', empty, total)
	if self.money then
		MoneyFrame_Update(self.money:GetName(), GetMoney())
	end
	self:ApplySearch()
end

-- Cheap update for ITEM_LOCK_CHANGED: only the lock state of one slot.
function Window:UpdateLock(bag, slot)
	local b = self.buttons[bag] and self.buttons[bag][slot]
	if b and b:IsShown() then
		local info = C.GetContainerItemInfo(bag, slot)
		SetItemButtonDesaturated(b, info and info.isLocked)
	end
end

function Window:UpdateCooldowns()
	for bag, list in pairs(self.buttons) do
		for slot, b in ipairs(list) do
			if b:IsShown() then
				updateCooldown(b, bag, slot, C.GetContainerItemID(bag, slot) ~= nil)
			end
		end
	end
end

function Window:Refresh()
	if self:IsShown() then
		self:Layout()
		self:UpdateItems()
	end
end

function Window:Open()
	if self:IsShown() then
		return
	end
	local title = self.opts.title
	self.title:SetText(type(title) == 'function' and title() or title)
	self:Layout()
	self:UpdateItems()
	self:Show()
end

function Window:Close()
	if self:IsShown() then
		self:Hide()
	end
end

--[[ Position ]]--

function Window:SavePosition()
	local point, _, relPoint, x, y = self:GetPoint(1)
	SatchelDB.positions[self.key] = { point, relPoint, x, y }
end

function Window:RestorePosition()
	self:ClearAllPoints()
	local p = SatchelDB.positions[self.key] or self.opts.default
	self:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end
