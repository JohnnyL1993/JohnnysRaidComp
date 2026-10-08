-- Raid Spammer: a chat-spam timer for the raid you're currently building in
-- Johnny's Raid Comp. Advertises that raid+size, a GearScore requirement you
-- set, and what's still missing from its ideal comp (reusing
-- RaidCompUI:ScanRoster/BuildMatches), on a repeating SendChatMessage timer
-- clamped to a 30-second floor so it doesn't hit WoW's chat throttle.
--
-- Channels list: General, Trade, LookingForGroup and Yell, each with a tick
-- box and its own interval. One Start/Stop runs every ticked
-- channel, each on its own timer.
JohnnysRaidSpam.RaidSpamUI = JohnnysRaidSpam.RaidSpamUI or {}
local RaidSpamUI = JohnnysRaidSpam.RaidSpamUI
-- Shares Johnny's Raid Comp's Skin now that the Spammer ships inside that addon
-- rather than as its own folder (the two Skin.lua files were identical).
local Skin = JohnnysRaidComp.Skin

-- Both the roster/need scan and the raid/size name lookups come from Raid Comp;
-- guard so nothing errors if that side is somehow unavailable.
local function GetRaidCompUI()
	if IsAddOnLoaded("JohnnysRaidComp") and JohnnysRaidComp then
		return JohnnysRaidComp.RaidCompUI
	end
	return nil
end

-- Height without any channel rows; each row adds CHANNEL_ROW_H (see
-- RefreshChannelRows), so a long joined-channel list never clips.
local FRAME_WIDTH, BASE_HEIGHT = 480, 396
local MIN_INTERVAL = 30
local DEFAULT_INTERVAL = 90
-- Minimum gap between any two sends, so starting with several channels ticked
-- doesn't fire them all in the same frame.
local SEND_SPACING = 2
-- How soon to retry a channel that couldn't be sent to (not joined, no raid
-- picked, ...) instead of waiting out its full interval.
local RETRY_DELAY = 5
-- How long a row shows "Sent" after posting before going back to a countdown.
local SENT_FLASH = 3
local FIELD_WIDTH = FRAME_WIDTH - 44
-- Narrower than FIELD_WIDTH so the "Reset" button fits to the right of it.
local TEMPLATE_BOX_WIDTH = FIELD_WIDTH - 70

local DEFAULT_RECRUIT_TEMPLATE = "[LFM] {raid} ({size}) - GS {gs}+ required - Need: {need} - {quest} - whisper me!"

local mainFrame

local recruitRaidText, recruitNeedText, recruitTemplateBox, recruitPreviewText, recruitGSBox

local previewTicker

local questDropdown
local questLogEntries = {}

----------------------------------------------------------------------------
-- Shared helpers
----------------------------------------------------------------------------
-- The Channels list, in display order. Numbered channels are keyed by their
-- lowercased base name and always listed - "(not joined)" when you're not in
-- them - so they can be ticked ahead of time.
local CHANNEL_LIST = {
	{ key = "general", name = "General", channel = true },
	{ key = "trade", name = "Trade", channel = true },
	{ key = "lookingforgroup", name = "LookingForGroup", channel = true },
	{ key = "YELL", name = "Yell", chatType = "YELL" },
}
-- Chat types the old free-typed Channel 1/2 boxes accepted (see LegacyChannelKey).
local FIXED_KEYS = { SAY = true, YELL = true, GUILD = true, RAID = true }

-- "Trade - City" -> "Trade"; custom channels have no suffix.
local function BaseChannelName(name)
	return name:match("^(.-)%s+%-%s+") or name
end

-- Current number of a joined channel by its lowercased base name, or nil.
-- Looked up on every send (not cached) since a custom channel's number can
-- shift between joins/relogs.
local function FindChannelNum(key)
	local list = { GetChannelList() }
	for i = 1, #list, 2 do
		local id, name = list[i], list[i + 1]
		if type(name) == "string" and BaseChannelName(name):lower() == key then
			return id
		end
	end
	return nil
end

-- Rows for the Channels list, labelled with each channel's current number
-- ("General (1)") or "(not joined)".
local function GetChannelRows()
	local rows = {}
	for _, entry in ipairs(CHANNEL_LIST) do
		local label = entry.name
		if entry.channel then
			local num = FindChannelNum(entry.key)
			label = label .. (num and (" (" .. num .. ")") or " (not joined)")
		end
		table.insert(rows, { key = entry.key, label = label, channel = entry.channel, chatType = entry.chatType })
	end
	return rows
end

-- Why a row can't be posted to right now, or nil if it can.
local function RowUnavailableReason(row)
	if row.channel and not FindChannelNum(row.key) then
		return "Not joined"
	end
	return nil
end

local function GetRowConfig(key)
	return JohnnysRaidSpam.db.profile.raidSpamChannels[key]
end

-- Only creates the saved entry on first write, so rows you never touch don't
-- pile up in SavedVariables.
local function EnsureRowConfig(key)
	local all = JohnnysRaidSpam.db.profile.raidSpamChannels
	all[key] = all[key] or { enabled = false, interval = DEFAULT_INTERVAL }
	return all[key]
end

local function IsRowEnabled(key)
	local cfg = GetRowConfig(key)
	return cfg and cfg.enabled
end

local function GetRowInterval(key)
	local cfg = GetRowConfig(key)
	return math.max(MIN_INTERVAL, (cfg and tonumber(cfg.interval)) or DEFAULT_INTERVAL)
end

-- Maps an old free-typed Channel 1/2 entry ("Trade", "yell", "5", ...) to a
-- Channels-list row key.
local function LegacyChannelKey(input)
	if not input or input == "" then
		return nil
	end
	local upper = input:upper()
	if FIXED_KEYS[upper] then
		return upper
	end
	local num = tonumber(input)
	if num then
		local _, name = GetChannelName(num)
		return name and BaseChannelName(name):lower() or nil
	end
	return BaseChannelName(input):lower()
end

-- One-time carry-over of the old two-channel settings into raidSpamChannels:
-- whatever was in Channel 1/2 comes back ticked with its old interval.
local function MigrateLegacyChannels()
	local profile = JohnnysRaidSpam.db.profile
	if profile.raidSpamChannelsMigrated then
		return
	end
	profile.raidSpamChannelsMigrated = true
	local legacy = {
		{ "raidSpamRecruitChannel", "raidSpamRecruitInterval" },
		{ "raidSpamRecruitChannel2", "raidSpamRecruitInterval2" },
	}
	for _, pair in ipairs(legacy) do
		local key = LegacyChannelKey(profile[pair[1]])
		if key then
			local cfg = EnsureRowConfig(key)
			cfg.enabled = true
			cfg.interval = tonumber(profile[pair[2]]) or DEFAULT_INTERVAL
		end
		profile[pair[1]], profile[pair[2]] = nil, nil
	end
end

-- The message box is multi-line now (so a long template is fully visible), but
-- a chat message is still one line - fold any newlines back into spaces before
-- sending or previewing.
local function OneLine(s)
	return (tostring(s or "")):gsub("%s*[\r\n]+%s*", " ")
end

-- Substitutes {token} placeholders in the user-editable message template. The
-- replacement side is escaped since gsub treats "%" specially there.
local function ApplyTemplate(template, tokens)
	local msg = template
	for key, value in pairs(tokens) do
		local safeValue = tostring(value):gsub("%%", "%%%%")
		msg = msg:gsub("{" .. key .. "}", safeValue)
	end
	return msg
end

-- Resolves the picked "weekly quest" (persisted by name, since quest log
-- indices shift) to a clickable quest link. Falls back to the plain saved name
-- if that quest is no longer in the log, and to "" if nothing's picked.
local function GetWeeklyQuestLink()
	local wantName = JohnnysRaidSpam.db.profile.raidSpamWeeklyQuestName
	if not wantName or wantName == "" then
		return ""
	end

	local numEntries = GetNumQuestLogEntries()
	for i = 1, numEntries do
		local title, _, _, _, isHeader = GetQuestLogTitle(i)
		if title == wantName and not isHeader then
			return GetQuestLink(i) or wantName
		end
	end
	return wantName
end

-- Tallies which slots in the current Raid Comp template are still unfilled -
-- generic role shortfalls ("2 Healer") first, then any unfilled pinned/class
-- slot labels ("Enh. Shaman (Bloodlust)") by name.
local function ComputeNeedText(templateKey)
	local RaidCompUI = GetRaidCompUI()
	if not RaidCompUI then
		return nil
	end
	local template = templateKey and RaidCompUI.TEMPLATES[templateKey]
	if not template then
		return nil
	end

	local roster = RaidCompUI:ScanRoster()
	local matches = RaidCompUI:BuildMatches(templateKey, roster)

	local genericShort = { TANK = 0, HEALER = 0, DAMAGER = 0 }
	local specificNeeds = {}
	for _, slot in ipairs(template.slots) do
		if not matches[slot] then
			if slot.class then
				table.insert(specificNeeds, slot.label)
			else
				genericShort[slot.role] = genericShort[slot.role] + 1
			end
		end
	end

	local parts = {}
	if genericShort.TANK > 0 then table.insert(parts, genericShort.TANK .. " Tank") end
	if genericShort.HEALER > 0 then table.insert(parts, genericShort.HEALER .. " Healer") end
	if genericShort.DAMAGER > 0 then table.insert(parts, genericShort.DAMAGER .. " DPS") end
	for _, label in ipairs(specificNeeds) do
		table.insert(parts, label)
	end

	if #parts == 0 then
		return "Full!"
	end
	return table.concat(parts, ", ")
end

----------------------------------------------------------------------------
-- Message composition - advertises the raid currently selected in Raid Comp.
----------------------------------------------------------------------------
-- Raid Comp only builds/refreshes templates when its comp screen is shown
-- (Class Run lazily, regular ones with saved counts + the Class slots
-- setting), so if that window hasn't been opened yet this session, do it here.
local function EnsureTemplateBuilt(RaidCompUI, raidKey, sizeKey)
	local templateKey = raidKey .. "_" .. sizeKey
	local template = RaidCompUI.TEMPLATES[templateKey]
	if sizeKey == "CLASSRUN" then
		if not template then
			RaidCompUI.TEMPLATES[templateKey] = RaidCompUI:BuildClassRunTemplate()
		end
	elseif not template or not template.fromSaved
		or template.classPins ~= (JohnnysRaidComp.db.profile.raidCompClassPins ~= false) then
		-- Still the file-load default, or built before Class slots was toggled -
		-- rebuild so {need} matches the comp screen.
		RaidCompUI:RebuildTemplate(raidKey, sizeKey)
	end
	return templateKey
end

-- Builds the actual message from the (editable) template plus live data - this
-- is what both the preview text and every SendChatMessage call use, so what you
-- see is exactly what goes out, and {need} always reflects the current roster.
local function ComposeRecruitMessage()
	local RaidCompUI = GetRaidCompUI()
	if not RaidCompUI then
		return nil, "Raid Comp not available - can't advertise a selection."
	end
	local raidKey, sizeKey = RaidCompUI:GetSelectedRaid()
	if not raidKey or not sizeKey then
		return nil, "Pick a raid + size in Raid Comp first."
	end

	local templateKey = EnsureTemplateBuilt(RaidCompUI, raidKey, sizeKey)
	if not RaidCompUI.TEMPLATES[templateKey] then
		return nil, "Raid Comp selection not found."
	end

	local gs = tonumber(recruitGSBox.editBox:GetText()) or 0
	local needText = ComputeNeedText(templateKey) or "?"
	local template = OneLine(recruitTemplateBox.editBox:GetText())
	if template == "" then
		template = DEFAULT_RECRUIT_TEMPLATE
	end

	return ApplyTemplate(template, {
		raid = RaidCompUI.RAID_LABELS[raidKey],
		size = RaidCompUI.SIZE_LABELS[sizeKey],
		gs = gs,
		need = needText,
		quest = GetWeeklyQuestLink(),
	})
end

local function RefreshRecruitPreview()
	local RaidCompUI = GetRaidCompUI()

	if not RaidCompUI then
		recruitRaidText:SetText("|cffff4040Raid Comp not available.|r")
		recruitNeedText:SetText("")
	else
		local raidKey, sizeKey = RaidCompUI:GetSelectedRaid()
		if not raidKey or not sizeKey then
			recruitRaidText:SetText("|cffff4040No raid selected - pick one in Raid Comp first.|r")
			recruitNeedText:SetText("")
		else
			local templateKey = EnsureTemplateBuilt(RaidCompUI, raidKey, sizeKey)
			recruitRaidText:SetText(RaidCompUI.RAID_LABELS[raidKey] .. " - " .. RaidCompUI.SIZE_LABELS[sizeKey])
			recruitNeedText:SetText("Need: " .. (ComputeNeedText(templateKey) or "?"))
		end
	end

	local msg, err = ComposeRecruitMessage()
	if msg then
		recruitPreviewText:SetText("Preview: " .. msg)
	else
		recruitPreviewText:SetText("Preview: |cffff4040" .. (err or "?") .. "|r")
	end
end

----------------------------------------------------------------------------
-- Weekly Quest picker - a dropdown of the player's current *raid* quests
-- (plus a "(none)" option), feeding the {quest} token. The ad is for a raid,
-- so filler quests in the log would just be noise here.
----------------------------------------------------------------------------
local QUEST_NONE = "(none)"

-- 3.3.5a tags raid quests with a "Raid" questTag (localised text, but Warmane
-- is enUS); the suggestedGroup >= 10 check catches any weekly that only
-- carries a group-size hint instead.
local function IsRaidQuest(questTag, suggestedGroup)
	return questTag == "Raid" or (suggestedGroup and suggestedGroup >= 10)
end

local function ApplyQuestSelection(name)
	name = name or ""
	JohnnysRaidSpam.db.profile.raidSpamWeeklyQuestName = name
	if questDropdown then
		questDropdown:SetText(name ~= "" and name or QUEST_NONE)
	end
	RefreshRecruitPreview()
end

-- Rebuilds questLogEntries from the quest log, drops a saved pick that's no
-- longer there, and refreshes the dropdown's item list only when the set of
-- quests actually changed (and not while the list is open under the cursor).
local lastQuestSig
local function RefreshQuestLogEntries()
	for i = #questLogEntries, 1, -1 do
		questLogEntries[i] = nil
	end

	local numEntries = GetNumQuestLogEntries()
	for i = 1, numEntries do
		local title, _, questTag, suggestedGroup, isHeader = GetQuestLogTitle(i)
		if title and not isHeader and IsRaidQuest(questTag, suggestedGroup) then
			table.insert(questLogEntries, title)
		end
	end

	local current = JohnnysRaidSpam.db.profile.raidSpamWeeklyQuestName or ""
	if current ~= "" then
		local stillValid = false
		for _, title in ipairs(questLogEntries) do
			if title == current then
				stillValid = true
				break
			end
		end
		if not stillValid then
			current = ""
			JohnnysRaidSpam.db.profile.raidSpamWeeklyQuestName = ""
		end
	end

	if not questDropdown then
		return
	end

	local sig = table.concat(questLogEntries, "\001")
	if sig ~= lastQuestSig and not questDropdown:IsOpen() then
		lastQuestSig = sig
		local items = { QUEST_NONE }
		for _, title in ipairs(questLogEntries) do
			table.insert(items, title)
		end
		questDropdown:SetItems(items, function(choice)
			ApplyQuestSelection(choice == QUEST_NONE and "" or choice)
		end)
	end

	questDropdown:SetText(current ~= "" and current or QUEST_NONE)
end

----------------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------------
local function SavePosition()
	local point, _, relativePoint, x, y = mainFrame:GetPoint()
	local pos = JohnnysRaidSpam.db.profile.raidSpamPanelPosition
	pos.point, pos.relativePoint, pos.x, pos.y = point, relativePoint, x, y
end

----------------------------------------------------------------------------
-- Docking to the Raid Comp window. Docked, this window's top-left is
-- anchored to the comp window's top-right, so moving the comp window carries
-- it along, and dragging this window drags the comp window instead (moving
-- both). Detached, it's a free window at raidSpamPanelPosition as before.
-- The comp window is built lazily, so until it exists a docked spammer just
-- sits at its saved free position.
----------------------------------------------------------------------------
local DOCK_GAP = 2
local dockBtn

local function GetCompFrame()
	return _G["JohnnysAddonHubRaidCompFrame"]
end

local function IsDocked()
	return JohnnysRaidSpam.db.profile.raidSpamDocked and GetCompFrame() ~= nil
end

local function ApplyDock()
	if not mainFrame then
		return
	end
	mainFrame:ClearAllPoints()
	if IsDocked() then
		mainFrame:SetPoint("TOPLEFT", GetCompFrame(), "TOPRIGHT", DOCK_GAP, 0)
	else
		local pos = JohnnysRaidSpam.db.profile.raidSpamPanelPosition
		mainFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
	end
	if dockBtn then
		dockBtn.text:SetText(JohnnysRaidSpam.db.profile.raidSpamDocked and "Detach" or "Dock")
	end
end

local function SetDocked(docked)
	if not docked and IsDocked() then
		-- Detach in place: re-anchor to UIParent at the current on-screen spot
		-- (GetLeft/GetTop and SetPoint offsets are both in this frame's own
		-- scale, so this holds with any Cfg scale) and save it as the free spot.
		local left, top = mainFrame:GetLeft(), mainFrame:GetTop()
		mainFrame:ClearAllPoints()
		mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		SavePosition()
	end
	JohnnysRaidSpam.db.profile.raidSpamDocked = docked
	ApplyDock()
end

-- Skin:CreateEditBox is single-line; the recruit template is long enough that
-- you want it wrapped so the whole thing is visible at once. Same flat look,
-- just multi-line and top-aligned.
local function CreateTemplateBox(parent, width, height)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(width, height)
	Skin:StylePanel(holder, 0.95)

	local edit = CreateFrame("EditBox", nil, holder)
	edit:SetMultiLine(true)
	edit:SetPoint("TOPLEFT", 6, -6)
	edit:SetPoint("BOTTOMRIGHT", -6, 6)
	edit:SetAutoFocus(false)
	edit:SetFontObject(GameFontHighlightSmall)
	edit:SetTextColor(1, 1, 1)
	edit:SetJustifyV("TOP")
	edit:SetMaxLetters(255)
	edit:SetScript("OnEscapePressed", edit.ClearFocus)
	holder.editBox = edit

	return holder
end

local function AddDivider(parent, yOffset)
	local tex = parent:CreateTexture(nil, "ARTWORK")
	tex:SetTexture(Skin.WHITE)
	tex:SetVertexColor(0.3, 0.3, 0.3, 1)
	tex:SetPoint("TOPLEFT", 4, yOffset)
	tex:SetPoint("TOPRIGHT", -4, yOffset)
	tex:SetHeight(1)
end

-- Flat-skinned dropdown - the Skin has no dropdown of its own and the addon
-- avoids Blizzard's gold UIDropDownMenu art, so this is a button that drops a
-- StylePanel'd list of Skin buttons. A full-screen transparent "closer" behind
-- the open list dismisses it on any outside click.
--   dd:SetItems(items, onSelect)  - (re)populate; onSelect(itemText) on pick
--   dd:SetText(text)              - set the shown label
--   dd:IsOpen()                   - is the list currently dropped
--   dd:Close()                    - force the list shut
local function CreateDropdown(parent, width)
	local dd = CreateFrame("Frame", nil, parent)
	dd:SetSize(width, 22)

	local btn = Skin:CreateButton(dd, width, 22, "")
	btn:SetAllPoints(dd)
	btn.text:ClearAllPoints()
	btn.text:SetPoint("LEFT", 6, 0)
	btn.text:SetPoint("RIGHT", -18, 0)
	btn.text:SetJustifyH("LEFT")

	local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	arrow:SetPoint("RIGHT", -6, 0)
	arrow:SetTextColor(0.7, 0.7, 0.7)
	arrow:SetText("v")

	-- Created before the list so the list sits on a higher frame level and its
	-- rows take clicks in preference to the closer.
	local closer = CreateFrame("Button", nil, UIParent)
	closer:SetAllPoints(UIParent)
	closer:SetFrameStrata("FULLSCREEN_DIALOG")
	closer:SetFrameLevel(1)
	closer:Hide()

	local list = CreateFrame("Frame", nil, dd)
	list:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
	list:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -2)
	list:SetFrameStrata("FULLSCREEN_DIALOG")
	list:SetFrameLevel(20)
	list:SetClampedToScreen(true)
	Skin:StylePanel(list, 0.98)
	list:Hide()

	closer:SetScript("OnClick", function() list:Hide() end)
	list:SetScript("OnShow", function() closer:Show() end)
	list:SetScript("OnHide", function() closer:Hide() end)

	local rows = {}
	local ROW_H = 20

	function dd:SetItems(items, onSelect)
		for _, r in ipairs(rows) do
			r:Hide()
		end
		for i, item in ipairs(items) do
			local r = rows[i]
			if not r then
				r = Skin:CreateButton(list, 10, ROW_H, "")
				r.text:ClearAllPoints()
				r.text:SetPoint("LEFT", 6, 0)
				r.text:SetPoint("RIGHT", -6, 0)
				r.text:SetJustifyH("LEFT")
				rows[i] = r
			end
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (i - 1) * ROW_H)
			r:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, -4 - (i - 1) * ROW_H)
			r.text:SetText(item)
			r:SetScript("OnClick", function()
				list:Hide()
				if onSelect then
					onSelect(item)
				end
			end)
			r:Show()
		end
		list:SetHeight(math.max(#items, 1) * ROW_H + 8)
	end

	function dd:SetText(text)
		btn.text:SetText(text or "")
	end

	function dd:IsOpen()
		return list:IsShown()
	end

	function dd:Close()
		list:Hide()
	end

	btn:SetScript("OnClick", function()
		if list:IsShown() then
			list:Hide()
		else
			list:Show()
		end
	end)

	return dd
end

----------------------------------------------------------------------------
-- Channels list - one row per channel ([x] Name  Seconds: [90]  Ready),
-- all run by one Start/Stop. Each ticked row posts the same
-- ComposeRecruitMessage() text on its own interval.
----------------------------------------------------------------------------
local CHANNEL_ROW_H = 24
local CHANNEL_ROWS_TOP = -272

local channelsParent
local channelRows = {}   -- current row descriptors, in display order
local rowWidgets = {}    -- pooled row frames; rowWidgets[i] shows channelRows[i]
local lastRowSig
local spamStartBtn, spamStatusText, spamTicker
local spamActive = false
local remaining = {}     -- row key -> seconds until its next send (while running)
local lastSentAt = {}    -- row key -> GetTime() of its last send
local lastSendTime = 0

local function UpdateRowStatus(w)
	local row = w.row
	local enabled = IsRowEnabled(row.key)
	local reason = enabled and RowUnavailableReason(row)
	if reason then
		w.status:SetText("|cffff4040" .. reason .. "|r")
	elseif spamActive and enabled then
		local sentAt = lastSentAt[row.key]
		if sentAt and GetTime() - sentAt < SENT_FLASH then
			w.status:SetText("|cff40ff40Sent|r")
		else
			w.status:SetText("Next: " .. math.ceil(remaining[row.key] or 0) .. "s")
		end
	else
		w.status:SetText("Ready")
	end
end

local function UpdateAllRowStatus()
	for i = 1, #channelRows do
		UpdateRowStatus(rowWidgets[i])
	end
end

local function CreateRowWidget(parent)
	local w = CreateFrame("Frame", nil, parent)
	w:SetHeight(CHANNEL_ROW_H)

	w.check = Skin:CreateCheckbox(w, 14, false, function(checked)
		local key = w.row.key
		EnsureRowConfig(key).enabled = checked
		if spamActive then
			-- Ticked mid-run: post on the next tick rather than a full interval later.
			remaining[key] = checked and 0 or nil
		end
		UpdateRowStatus(w)
	end)
	w.check:SetPoint("LEFT", 0, 0)

	w.label = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	w.label:SetPoint("LEFT", 22, 0)
	w.label:SetWidth(170)
	w.label:SetJustifyH("LEFT")

	local intervalLabel = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	intervalLabel:SetPoint("LEFT", 196, 0)
	intervalLabel:SetTextColor(0.7, 0.7, 0.7)
	intervalLabel:SetText("Seconds:")

	w.interval = Skin:CreateEditBox(w, 50, 20)
	w.interval:SetPoint("LEFT", 266, 0)
	w.interval.editBox:SetNumeric(true)
	w.interval.editBox:SetScript("OnTextChanged", function(self)
		-- Programmatic SetText in RefreshChannelRows shouldn't create a saved entry.
		if w.suppress then
			return
		end
		EnsureRowConfig(w.row.key).interval = tonumber(self:GetText()) or DEFAULT_INTERVAL
	end)
	-- Snap anything under the floor up to MIN_INTERVAL once you're done typing,
	-- so the box always shows the interval that will actually be used.
	local function ClampInterval(self)
		local value = math.max(MIN_INTERVAL, tonumber(self:GetText()) or DEFAULT_INTERVAL)
		if tostring(value) ~= self:GetText() then
			self:SetText(tostring(value))
		end
	end
	w.interval.editBox:SetScript("OnEditFocusLost", ClampInterval)
	w.interval.editBox:SetScript("OnEnterPressed", function(self)
		ClampInterval(self)
		self:ClearFocus()
	end)

	w.status = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	w.status:SetPoint("LEFT", 326, 0)
	w.status:SetPoint("RIGHT", 0, 0)
	w.status:SetJustifyH("LEFT")
	w.status:SetTextColor(0.7, 0.7, 0.7)

	return w
end

-- Rebuilds the rows only when the joined-channel set changed (so a box you're
-- typing in isn't re-laid out every poll), then refreshes every row's status.
local function RefreshChannelRows()
	if not channelsParent then
		return
	end

	local rows = GetChannelRows()
	local sigParts = {}
	for i, row in ipairs(rows) do
		sigParts[i] = row.key .. "=" .. row.label
	end
	local sig = table.concat(sigParts, "\001")

	if sig ~= lastRowSig then
		lastRowSig = sig
		channelRows = rows
		for i, row in ipairs(rows) do
			local w = rowWidgets[i]
			if not w then
				w = CreateRowWidget(channelsParent)
				rowWidgets[i] = w
			end
			local y = CHANNEL_ROWS_TOP - (i - 1) * CHANNEL_ROW_H
			w:ClearAllPoints()
			w:SetPoint("TOPLEFT", channelsParent, "TOPLEFT", 4, y)
			w:SetPoint("TOPRIGHT", channelsParent, "TOPRIGHT", -4, y)
			w.row = row
			w.label:SetText(row.label)
			-- Dim a channel you're not in (only Trade is ever listed that way).
			local shade = (row.channel and not FindChannelNum(row.key)) and 0.6 or 1
			w.label:SetTextColor(shade, shade, shade)
			local cfg = GetRowConfig(row.key)
			w.check:SetChecked(cfg and cfg.enabled)
			w.suppress = true
			w.interval.editBox:SetText(tostring(GetRowInterval(row.key)))
			w.suppress = false
			w:Show()
		end
		for i = #rows + 1, #rowWidgets do
			rowWidgets[i]:Hide()
		end

		spamStartBtn:ClearAllPoints()
		spamStartBtn:SetPoint("TOPLEFT", channelsParent, "TOPLEFT", 4, CHANNEL_ROWS_TOP - #rows * CHANNEL_ROW_H - 8)
		mainFrame:SetHeight(BASE_HEIGHT + #rows * CHANNEL_ROW_H)
	end

	UpdateAllRowStatus()
end

local function SendToRow(row, msg)
	if row.channel then
		local num = FindChannelNum(row.key)
		if not num then
			return false
		end
		SendChatMessage(msg, "CHANNEL", nil, num)
	else
		if RowUnavailableReason(row) then
			return false
		end
		SendChatMessage(msg, row.chatType)
	end
	return true
end

-- Counts every ticked row down and posts the ones that are due, at most one
-- send per SEND_SPACING so a batch of due rows goes out staggered.
local function SpamTick(dt)
	local now = GetTime()
	for _, row in ipairs(channelRows) do
		local key = row.key
		if IsRowEnabled(key) then
			local rem = (remaining[key] or 0) - dt
			if rem <= 0 and now - lastSendTime >= SEND_SPACING then
				local msg, err = ComposeRecruitMessage()
				if not msg then
					spamStatusText:SetText("|cffff4040" .. (err or "Can't send - check settings.") .. "|r")
					rem = RETRY_DELAY
				elseif SendToRow(row, msg) then
					lastSendTime = now
					lastSentAt[key] = now
					rem = GetRowInterval(key)
					spamStatusText:SetText("|cff40ff40Sent|r to " .. row.label .. " at " .. date("%H:%M:%S"))
				else
					rem = RETRY_DELAY
				end
			end
			remaining[key] = math.max(rem, 0)
		else
			remaining[key] = nil
		end
	end
	UpdateAllRowStatus()
end

local function StopSpam()
	spamActive = false
	spamTicker:Hide()
	wipe(remaining)
	spamStartBtn.text:SetText("Start")
	spamStatusText:SetText("Stopped.")
	UpdateAllRowStatus()
end

local function StartSpam()
	local any = false
	for _, row in ipairs(channelRows) do
		if IsRowEnabled(row.key) then
			any = true
			break
		end
	end
	if not any then
		spamStatusText:SetText("|cffff4040Tick at least one channel first.|r")
		return
	end

	wipe(remaining)
	spamActive = true
	spamTicker:Show()
	spamStartBtn.text:SetText("Stop")
	spamStatusText:SetText("Running...")
	SpamTick(0)
end

local function BuildChannelsSection(parent)
	channelsParent = parent

	local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("TOP", 0, -246)
	header:SetText("Channels")

	spamStartBtn = Skin:CreateButton(parent, 120, 24, "Start")
	spamStartBtn:SetScript("OnClick", function()
		if spamActive then
			StopSpam()
		else
			StartSpam()
		end
	end)

	spamStatusText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	spamStatusText:SetPoint("LEFT", spamStartBtn, "RIGHT", 10, 0)
	spamStatusText:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
	spamStatusText:SetJustifyH("LEFT")
	spamStatusText:SetTextColor(0.7, 0.7, 0.7)
	spamStatusText:SetText("Stopped.")

	-- Stepped at 0.25s rather than every frame - plenty for second countdowns.
	spamTicker = CreateFrame("Frame")
	spamTicker:Hide()
	local acc = 0
	spamTicker:SetScript("OnUpdate", function(self, e)
		acc = acc + e
		if acc >= 0.25 then
			local dt = acc
			acc = 0
			SpamTick(dt)
		end
	end)

	MigrateLegacyChannels()
	RefreshChannelRows()
end

local function BuildRecruitPanel(parent)
	recruitRaidText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	recruitRaidText:SetPoint("TOPLEFT", 4, -6)
	recruitRaidText:SetTextColor(1, 1, 1)

	recruitNeedText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	recruitNeedText:SetPoint("TOPLEFT", 4, -26)
	recruitNeedText:SetTextColor(0.85, 0.85, 0.85)

	local templateLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	templateLabel:SetPoint("TOPLEFT", 4, -52)
	templateLabel:SetTextColor(0.7, 0.7, 0.7)
	templateLabel:SetText("Message (tokens: {raid} {size} {gs} {need} {quest}):")

	recruitTemplateBox = CreateTemplateBox(parent, TEMPLATE_BOX_WIDTH, 74)
	recruitTemplateBox:SetPoint("TOPLEFT", 4, -68)
	recruitTemplateBox.editBox:SetText(JohnnysRaidSpam.db.profile.raidSpamRecruitTemplate or DEFAULT_RECRUIT_TEMPLATE)
	recruitTemplateBox.editBox:SetScript("OnTextChanged", function(self)
		JohnnysRaidSpam.db.profile.raidSpamRecruitTemplate = self:GetText()
		RefreshRecruitPreview()
	end)

	local resetBtn = Skin:CreateButton(parent, 60, 22, "Reset")
	resetBtn:SetPoint("TOPLEFT", recruitTemplateBox, "TOPRIGHT", 8, 0)
	resetBtn:SetScript("OnClick", function()
		-- SetText fires OnTextChanged, which already saves + refreshes the preview.
		recruitTemplateBox.editBox:SetText(DEFAULT_RECRUIT_TEMPLATE)
	end)

	recruitPreviewText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	recruitPreviewText:SetPoint("TOPLEFT", 4, -150)
	recruitPreviewText:SetWidth(FIELD_WIDTH)
	recruitPreviewText:SetJustifyH("LEFT")
	recruitPreviewText:SetTextColor(0.6, 0.9, 1)

	local gsLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	gsLabel:SetPoint("TOPLEFT", 4, -210)
	gsLabel:SetTextColor(0.7, 0.7, 0.7)
	gsLabel:SetText("Min GS required:")

	recruitGSBox = Skin:CreateEditBox(parent, 100, 22)
	recruitGSBox:SetPoint("TOPLEFT", 140, -206)
	recruitGSBox.editBox:SetNumeric(true)
	recruitGSBox.editBox:SetText(tostring(JohnnysRaidSpam.db.profile.raidSpamRecruitGS or 0))
	recruitGSBox.editBox:SetScript("OnTextChanged", function(self)
		JohnnysRaidSpam.db.profile.raidSpamRecruitGS = tonumber(self:GetText()) or 0
		RefreshRecruitPreview()
	end)

	AddDivider(parent, -236)

	BuildChannelsSection(parent)
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "JohnnysAddonHubRaidSpamFrame", UIParent)
	mainFrame:SetSize(FRAME_WIDTH, BASE_HEIGHT)

	local pos = JohnnysRaidSpam.db.profile.raidSpamPanelPosition
	mainFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)

	mainFrame:SetFrameStrata("DIALOG")
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:RegisterForDrag("LeftButton")
	-- Docked, a drag moves the comp window (via its own drag handlers, so it
	-- saves its position as usual) and this window follows the anchor.
	local draggingComp
	mainFrame:SetScript("OnDragStart", function(self)
		local comp = IsDocked() and GetCompFrame()
		if comp and comp:GetScript("OnDragStart") then
			draggingComp = comp
			comp:GetScript("OnDragStart")(comp)
		else
			self:StartMoving()
		end
	end)
	mainFrame:SetScript("OnDragStop", function(self)
		if draggingComp then
			local comp = draggingComp
			draggingComp = nil
			comp:GetScript("OnDragStop")(comp)
			return
		end
		self:StopMovingOrSizing()
		SavePosition()
	end)
	Skin:StylePanel(mainFrame, 0.95)
	mainFrame:Hide()

	-- Per-window scale/opacity (see JohnnysRaidComp's Modules\WindowSettings.lua).
	if JohnnysRaidComp and JohnnysRaidComp.WindowSettings then
		JohnnysRaidComp.WindowSettings:Register(mainFrame, "raidspam", "Raid Spammer")
	end

	local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Raid Spammer")

	local close = Skin:CreateButton(mainFrame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() RaidSpamUI:Toggle() end)

	local cfgBtn
	if JohnnysRaidComp and JohnnysRaidComp.WindowSettings then
		cfgBtn = JohnnysRaidComp.WindowSettings:AttachButton(mainFrame)
	end

	-- Dock/Detach toggle - see ApplyDock.
	dockBtn = Skin:CreateButton(mainFrame, 56, 20, "Detach")
	if cfgBtn then
		dockBtn:SetPoint("TOPRIGHT", cfgBtn, "TOPLEFT", -4, 0)
	else
		dockBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", -4, 0)
	end
	dockBtn:SetScript("OnClick", function()
		SetDocked(not JohnnysRaidSpam.db.profile.raidSpamDocked)
	end)

	-- Weekly raid-quest picker - feeds the {quest} token.
	local questLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	questLabel:SetPoint("TOPLEFT", 16, -40)
	questLabel:SetTextColor(0.7, 0.7, 0.7)
	questLabel:SetText("Weekly Raid Quest:")

	questDropdown = CreateDropdown(mainFrame, 300)
	questDropdown:SetPoint("LEFT", questLabel, "RIGHT", 10, 1)
	questDropdown:SetText(QUEST_NONE)

	local content = CreateFrame("Frame", nil, mainFrame)
	content:SetPoint("TOPLEFT", 16, -68)
	content:SetPoint("BOTTOMRIGHT", -16, 16)
	BuildRecruitPanel(content)

	-- Live preview (raid/need text) refreshes on a short poll while shown -
	-- roster/selection data changes independently of this window.
	previewTicker = CreateFrame("Frame")
	previewTicker:Hide()
	local previewElapsed = 0
	previewTicker:SetScript("OnUpdate", function(self, e)
		previewElapsed = previewElapsed + e
		if previewElapsed >= 3 then
			previewElapsed = 0
			RefreshQuestLogEntries()
			RefreshRecruitPreview()
			RefreshChannelRows()
		end
	end)

	mainFrame:SetScript("OnShow", function()
		-- Re-dock on every show - the comp window may have been built since.
		ApplyDock()
		RefreshQuestLogEntries()
		RefreshRecruitPreview()
		RefreshChannelRows()
		previewTicker:Show()
	end)
	mainFrame:SetScript("OnHide", function()
		previewTicker:Hide()
		questDropdown:Close()
		-- Don't leave chat spam running unattended once the window's closed.
		if spamActive then
			StopSpam()
		end
	end)

	-- Pick up /join and /leave right away instead of on the next 3s poll.
	mainFrame:RegisterEvent("CHANNEL_UI_UPDATE")
	mainFrame:SetScript("OnEvent", function()
		if mainFrame:IsShown() then
			RefreshChannelRows()
		end
	end)
end

function RaidSpamUI:Toggle()
	if not mainFrame then
		BuildFrame()
	end
	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		mainFrame:Show()
	end
end
