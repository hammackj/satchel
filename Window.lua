--[[
	Window.lua
	A bag window: one grid of item buttons covering a list of bags, with a
	title, title-bar buttons, search box, free-slot count and (optionally)
	gold. The inventory and the bank are both windows made by ns.NewWindow.

	A window is either live (the current character's real bags) or offline
	(a stored snapshot: another character, or your bank away from a banker).

	Live item buttons use Blizzard's ContainerFrameItemButtonTemplate so
	clicking, dragging, splitting stacks and tooltips behave exactly like the
	default bags. That template finds its bag through its parent's ID, so each
	bag gets an invisible holder frame with SetID(bagID), and each button gets
	SetID(slot). Offline buttons are separate, display-only buttons: they must
	never act on the current character's bags.
--]]

local ADDON, ns = ...
local C = C_Container

local SIZE, GAP, PAD = 37, 4, 10
local TOP, BOTTOM = 56, 30 -- title + search above the grid, free/gold below

ns.ICON = 'Interface\\Icons\\INV_Misc_Bag_08'

-- Modern clients have a dedicated ItemButton frame type; fall back to Button.
local BUTTON_TYPE = pcall(CreateFrame, 'ItemButton') and 'ItemButton' or 'Button'
local created = 0 -- item buttons made so far, across all windows (for unique names)

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local GetDetailedItemLevelInfo = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo

local function part(b, key, suffix)
	return b[key] or _G[b:GetName() .. suffix]
end

--[[ Shared button decorations ]]--

-- Gear that has a meaningful item level: weapons and armor that go in a slot
-- (not shirts or tabards).
local NO_LEVEL = { [''] = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BODY = true, INVTYPE_TABARD = true }

local function updateLevel(b, link, quality)
	local fs = b.satchelLevel
	if not fs then
		fs = b:CreateFontString(nil, 'OVERLAY', 'NumberFontNormalSmall')
		fs:SetPoint('TOPLEFT', 2, -2)
		fs:SetDrawLayer('OVERLAY', 7)
		b.satchelLevel = fs
	end
	local level
	if link and SatchelDB.itemLevel and GetItemInfoInstant and GetDetailedItemLevelInfo then
		local _, _, _, equipLoc, _, classID = GetItemInfoInstant(link)
		if (classID == 2 or classID == 4) and not NO_LEVEL[equipLoc or ''] then
			level = GetDetailedItemLevelInfo(link)
		end
	end
	if level and level > 1 then
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
		fs:SetText(level)
		if color then
			fs:SetTextColor(color.r, color.g, color.b)
		end
		fs:Show()
	else
		fs:Hide()
	end
end

local function nameOf(link)
	return link and link:match('%[(.-)%]') or nil
end

--[[ Live item buttons ]]--

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

local function newLiveButton(holder, slot)
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

local function updateLiveButton(b, bag, slot)
	local info = C.GetContainerItemInfo(bag, slot)
	local texture = info and info.iconFileID
	local link = info and info.hyperlink
	local quality = info and info.quality
	SetItemButtonTexture(b, texture)
	SetItemButtonCount(b, info and info.stackCount or 0)
	SetItemButtonDesaturated(b, info and info.isLocked)
	if SetItemButtonQuality then
		SetItemButtonQuality(b, quality, link)
	end
	updateQuest(b, bag, slot, texture ~= nil)
	updateCooldown(b, bag, slot, texture ~= nil)
	updateLevel(b, link, quality)

	local new = texture ~= nil and C_NewItems ~= nil and C_NewItems.IsNewItem(bag, slot) or false
	local paid = new and C.IsBattlePayItem ~= nil and C.IsBattlePayItem(bag, slot) or false
	setGlow(b, new, paid, quality)

	if b.JunkIcon then
		b.JunkIcon:SetShown(SatchelDB.junkIcon and quality == 0 and not info.hasNoValue or false)
	end

	-- Plain field read only by our own search code.
	b.satchelName = nameOf(link)
end

--[[ Offline item buttons ]]--

local function offlineEnter(self)
	if self.link then
		GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
		GameTooltip:SetHyperlink(self.link)
		GameTooltip:Show()
	end
end

-- Shift-click links the item in chat, ctrl-click previews it, as in the default UI.
local function offlineClick(self)
	if self.link then
		HandleModifiedItemClick(self.link)
	end
end

local function newOfflineButton(parent)
	created = created + 1
	local name = 'SatchelItem' .. created
	local ok, b = pcall(CreateFrame, BUTTON_TYPE, name, parent, 'ItemButtonTemplate')
	if not ok then
		b = CreateFrame('Button', name, parent)
		b:SetSize(SIZE, SIZE)
		b.icon = b:CreateTexture(nil, 'BORDER')
		b.icon:SetAllPoints()
		b.Count = b:CreateFontString(nil, 'OVERLAY', 'NumberFontNormal')
		b.Count:SetPoint('BOTTOMRIGHT', -2, 2)
	end
	b:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
	b:SetScript('OnEnter', offlineEnter)
	b:SetScript('OnLeave', GameTooltip_Hide)
	b:SetScript('OnClick', offlineClick)
	return b
end

local function updateOfflineButton(b, item)
	local link = item and item.l
	b.link = link
	SetItemButtonTexture(b, item and C_Item.GetItemIconByID(item.id or link) or nil)
	SetItemButtonCount(b, item and item.c or 0)
	if SetItemButtonQuality and b.IconBorder then
		SetItemButtonQuality(b, item and item.q, link)
	end
	updateLevel(b, link, item and item.q)
	b.satchelName = nameOf(link)
end

--[[ Window ]]--

local Window = {}

local function titleButton(frame, anchor, icon, tip, onClick)
	local b = CreateFrame('Button', nil, frame)
	b:SetSize(18, 18)
	b:SetPoint('RIGHT', anchor, 'LEFT', -3, 0)
	b:SetNormalTexture(icon)
	b:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square', 'ADD')
	b:SetScript('OnClick', onClick)
	b:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_LEFT')
		GameTooltip:SetText(tip)
		GameTooltip:Show()
	end)
	b:SetScript('OnLeave', GameTooltip_Hide)
	return b
end

-- opts:
--   title     function returning the live title
--   bags      function returning the list of bag IDs to show
--   store     field of the character record holding this window's snapshot
--   live      function: can the current character's real bags be shown now?
--   columns   SatchelDB key holding the column count
--   money     true to show gold
--   sort      function that sorts these bags (adds a sort button)
--   buttons   extra title-bar buttons: { icon, tooltip, onClick }
--   onHide    function called after the window hides
--   default   default position: { point, relPoint, x, y }
function ns.NewWindow(key, opts)
	local name = 'Satchel' .. key .. 'Frame'
	local frame = CreateFrame('Frame', name, UIParent, 'BackdropTemplate')
	Mixin(frame, Window)
	frame.key, frame.opts = key, opts
	frame.holders, frame.buttons, frame.offline = {}, {}, {}

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
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	tinsert(UISpecialFrames, name) -- Escape closes it

	frame:SetScript('OnDragStart', frame.StartMoving)
	frame:SetScript('OnDragStop', function(self)
		self:StopMovingOrSizing()
		self:SavePosition()
	end)

	-- Icon + name: click to pick whose bags to show.
	local owner = CreateFrame('Button', nil, frame)
	owner:SetPoint('TOPLEFT', PAD, -8)
	owner:SetHeight(20)
	local icon = owner:CreateTexture(nil, 'ARTWORK')
	icon:SetTexture(ns.ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetSize(18, 18)
	icon:SetPoint('LEFT')
	frame.title = owner:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
	frame.title:SetPoint('LEFT', icon, 'RIGHT', 6, 0)
	owner:SetScript('OnClick', function(self)
		ns.ShowCharacterMenu(frame, self)
	end)
	owner:SetScript('OnEnter', function(self)
		GameTooltip:SetOwner(self, 'ANCHOR_TOPLEFT')
		GameTooltip:SetText('Click to view another character')
		GameTooltip:Show()
	end)
	owner:SetScript('OnLeave', GameTooltip_Hide)
	frame.ownerButton = owner

	local close = CreateFrame('Button', nil, frame, 'UIPanelCloseButton')
	close:SetPoint('TOPRIGHT', -2, -2)

	local anchor = close
	for _, def in ipairs(opts.buttons or {}) do
		anchor = titleButton(frame, anchor, def[1], def[2], def[3])
	end
	if opts.sort then
		frame.sortButton = titleButton(frame, anchor, 'Interface\\Icons\\INV_Pet_Broom', 'Sort', function()
			opts.sort()
			if SOUNDKIT and SOUNDKIT.UI_BAG_SORTING_01 then
				PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
			end
		end)
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
		self.owner = nil -- reopen on your own bags
		if opts.onHide then
			opts.onHide()
		end
	end)

	ns.Windows = ns.Windows or {}
	tinsert(ns.Windows, frame)
	return frame
end

function Window:IsLive()
	return self.owner == nil and self.opts.live()
end

-- Shows another character's bags; nil or your own key goes back to yours.
function Window:SetOwner(key)
	if key == ns.me then
		key = nil
	end
	self.owner = key
	if self:IsShown() then
		self:Render()
	end
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
		b = newLiveButton(self:Holder(bag), slot)
		list[slot] = b
	end
	return b
end

local function eachButton(self, fn)
	for _, list in pairs(self.buttons) do
		for _, b in ipairs(list) do
			fn(b)
		end
	end
	for _, b in ipairs(self.offline) do
		fn(b)
	end
end

function Window:ApplySearch()
	local text = (self.search:GetText() or ''):lower()
	eachButton(self, function(b)
		local match = text == '' or (b.satchelName and b.satchelName:lower():find(text, 1, true)) ~= nil
		if b.SetMatchesSearch then
			b:SetMatchesSearch(match)
		else
			b:SetAlpha(match and 1 or 0.25)
		end
	end)
end

function Window:Place(b, index)
	local cols = SatchelDB[self.opts.columns]
	local col, row = index % cols, floor(index / cols)
	b:ClearAllPoints()
	b:SetPoint('TOPLEFT', self, 'TOPLEFT', PAD + col * (SIZE + GAP), -(TOP + row * (SIZE + GAP)))
	b:Show()
end

function Window:Resize(count)
	local cols = SatchelDB[self.opts.columns]
	local rows = math.max(1, math.ceil(count / cols))
	self:SetSize(PAD * 2 + cols * SIZE + (cols - 1) * GAP, TOP + rows * SIZE + (rows - 1) * GAP + BOTTOM)
end

--[[ Live view ]]--

-- Positions a button for every slot of every current bag and resizes the window.
function Window:Layout()
	local index = 0
	local active = {}
	for _, bag in ipairs(self.opts.bags()) do
		active[bag] = true
		self:Holder(bag):Show()
		local slots = C.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			self:Place(self:Button(bag, slot), index)
			index = index + 1
		end
		local list = self.buttons[bag]
		if list then
			for slot = slots + 1, #list do
				list[slot]:Hide()
			end
		end
	end
	for bag, h in pairs(self.holders) do
		h:SetShown(active[bag] == true)
	end
	for _, b in ipairs(self.offline) do
		b:Hide()
	end
	self:Resize(index)
end

function Window:UpdateItems()
	local total, empty = 0, 0
	for _, bag in ipairs(self.opts.bags()) do
		local slots = C.GetContainerNumSlots(bag) or 0
		total = total + slots
		empty = empty + (C.GetContainerNumFreeSlots(bag) or 0)
		for slot = 1, slots do
			updateLiveButton(self:Button(bag, slot), bag, slot)
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
	if b and b:IsVisible() then
		local info = C.GetContainerItemInfo(bag, slot)
		SetItemButtonDesaturated(b, info and info.isLocked)
	end
end

function Window:UpdateCooldowns()
	for bag, list in pairs(self.buttons) do
		for slot, b in ipairs(list) do
			if b:IsVisible() then
				updateCooldown(b, bag, slot, C.GetContainerItemID(bag, slot) ~= nil)
			end
		end
	end
end

--[[ Offline view ]]--

function Window:RenderOffline()
	for _, h in pairs(self.holders) do
		h:Hide()
	end
	local c = ns.Character(self.owner)
	local data = c and c[self.opts.store]
	local bags = {}
	for bag in pairs(data or {}) do
		bags[#bags + 1] = bag
	end
	table.sort(bags)

	local index, empty = 0, 0
	for _, bag in ipairs(bags) do
		local t = data[bag]
		for slot = 1, t.size do
			index = index + 1
			local b = self.offline[index]
			if not b then
				b = newOfflineButton(self)
				self.offline[index] = b
			end
			self:Place(b, index - 1)
			updateOfflineButton(b, t[slot])
			if not t[slot] then
				empty = empty + 1
			end
		end
	end
	for i = index + 1, #self.offline do
		self.offline[i]:Hide()
	end
	self:Resize(index)

	if data then
		self.free:SetFormattedText('%d/%d free', empty, index)
	else
		self.free:SetText('Not seen yet: visit a banker on this character')
	end
	if self.money then
		MoneyFrame_Update(self.money:GetName(), c and c.money or 0)
	end
	self:ApplySearch()
end

--[[ Showing ]]--

function Window:Render()
	local live = self:IsLive()
	if live then
		self.title:SetText(self.opts.title())
		self:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
		self:Layout()
		self:UpdateItems()
	else
		self.title:SetText(ns.CharacterLabel(self.owner or ns.me) .. (self.owner and '' or ' |cffaaaaaa(saved)|r'))
		-- A blue tint marks a view you can't take items from.
		self:SetBackdropColor(0.04, 0.06, 0.14, 0.92)
		self:RenderOffline()
	end
	self.ownerButton:SetWidth(self.title:GetStringWidth() + 26)
	if self.sortButton then
		self.sortButton:SetShown(live)
	end
	if self.opts.onRender then
		self.opts.onRender(live)
	end
end

function Window:Refresh()
	if self:IsShown() then
		self:Render()
	end
end

function Window:Open()
	if not self:IsShown() then
		self:Render()
		self:Show()
	end
end

function Window:Close()
	if self:IsShown() then
		self:Hide()
	end
end

--[[ Character menu ]]--

function ns.ShowCharacterMenu(window, anchor)
	local keys = ns.CharacterKeys(window.opts.store)
	if #keys == 0 then
		return
	end
	local current = window.owner or ns.me
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(anchor, function(_, root)
			root:CreateTitle(window.key == 'Bank' and 'Show bank of' or 'Show bags of')
			for _, key in ipairs(keys) do
				root:CreateRadio(ns.CharacterLabel(key),
					function() return key == current end,
					function() window:SetOwner(key) end)
			end
		end)
	else
		-- No menu API: step to the next character.
		local nextKey = keys[1]
		for i, key in ipairs(keys) do
			if key == current then
				nextKey = keys[i % #keys + 1]
			end
		end
		window:SetOwner(nextKey)
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
