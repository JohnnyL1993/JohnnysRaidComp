-- Raid Spammer: a chat-spam timer for the raid you're currently building in
-- Johnny's Raid Comp. Advertises that raid+size, a GearScore requirement you
-- set, and what's still missing from its ideal comp (reusing
-- RaidCompUI:ScanRoster/BuildMatches), on a repeating SendChatMessage timer
-- clamped to a 30-second floor so it doesn't hit WoW's chat throttle.
--
-- Two independent channels: the same message can go to two places (e.g. a
-- custom LFM channel and Guild) each on its own interval and its own Start/Stop.
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

local FRAME_WIDTH, FRAME_HEIGHT = 480, 630
local MIN_INTERVAL = 30
local FIELD_WIDTH = FRAME_WIDTH - 44
-- Narrower than FIELD_WIDTH so the "Reset" button fits to the right of it.
local TEMPLATE_BOX_WIDTH = FIELD_WIDTH - 70

local DEFAULT_RECRUIT_TEMPLATE = "[LFM] {raid} ({size}) - GS {gs}+ required - Need: {need} - {quest} - whisper me!"

local mainFrame

local recruitRaidText, recruitNeedText, recruitTemplateBox, recruitPreviewText, recruitGSBox
local recruitChannelBox, recruitIntervalBox, recruitStartBtn, recruitStatusText, recruitSpammer
local recruitChannel2Box, recruitInterval2Box, recruitStart2Btn, recruitStatus2Text, recruitSpammer2

local previewTicker

local questDropdown
local questLogEntries = {}

----------------------------------------------------------------------------
-- Shared helpers
----------------------------------------------------------------------------
local SPECIAL_CHAT_TYPES = { SAY = true, YELL = true, GUILD = true, OFFICER = true, RAID = true, PARTY = true }

-- Resolves free-typed channel text to a SendChatMessage chat type + channel
-- number. Re-resolved on every send (not cached) since a custom channel's
-- number can shift between joins/relogs.
local function ResolveChannelType(input)
	if not input or input == "" then
		return nil
	end
	local upper = input:upper()
	if SPECIAL_CHAT_TYPES[upper] then
		return upper, nil
	end

	-- A plain number is a channel index typed directly (e.g. "2" for Trade).
	local asNum = tonumber(input)
	if asNum and asNum > 0 and asNum == math.floor(asNum) then
		return "CHANNEL", asNum
	end

	-- Exact / prefix match on the channel name.
	local channelNum = GetChannelName(input)
	if channelNum and channelNum > 0 then
		return "CHANNEL", channelNum
	end

	-- Substring match against the channels you're joined to, so a "Trade"
	-- preset resolves even though the real channel name is "Trade - City".
	local list = { GetChannelList() }
	local want = input:lower()
	for i = 1, #list, 2 do
		local id, name = list[i], list[i + 1]
		if type(name) == "string" and name:lower():find(want, 1, true) then
			return "CHANNEL", id
		end
	end

	return nil
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
-- Generic start/stop/ticker controller - one instance per channel.
----------------------------------------------------------------------------
local function CreateSpammer(buildMessageFn, getChannelInputFn, getIntervalFn, statusText, startBtn)
	local active = false
	local elapsed = 0

	local ticker = CreateFrame("Frame")
	ticker:Hide()

	local function DoSend()
		local msg, err = buildMessageFn()
		if not msg then
			statusText:SetText("|cffff4040" .. (err or "Can't send - check settings.") .. "|r")
			return
		end

		local chatType, channelNum = ResolveChannelType(getChannelInputFn())
		if not chatType then
			statusText:SetText("|cffff4040Channel not found - are you joined to it?|r")
			return
		end

		SendChatMessage(msg, chatType, nil, channelNum)
		-- The exact outgoing text is already shown in the preview above, so the
		-- status line just needs a timestamped confirmation on one row.
		statusText:SetText("|cff40ff40Sent|r at " .. date("%H:%M:%S"))
	end

	ticker:SetScript("OnUpdate", function(self, e)
		if not active then
			return
		end
		elapsed = elapsed + e
		local interval = math.max(MIN_INTERVAL, tonumber(getIntervalFn()) or MIN_INTERVAL)
		if elapsed >= interval then
			elapsed = 0
			DoSend()
		end
	end)

	local controller = {}

	function controller:Start()
		active = true
		elapsed = 0
		ticker:Show()
		startBtn.text:SetText("Stop")
		DoSend()
	end

	function controller:Stop()
		active = false
		ticker:Hide()
		startBtn.text:SetText("Start")
		statusText:SetText("Stopped.")
	end

	function controller:Toggle()
		if active then
			controller:Stop()
		else
			controller:Start()
		end
	end

	function controller:IsActive()
		return active
	end

	return controller
end

----------------------------------------------------------------------------
-- Message composition - advertises the raid currently selected in Raid Comp.
----------------------------------------------------------------------------
-- Class Run's template is only built lazily inside RaidCompUI:ShowClassRunComp,
-- so if the saved selection points there but the Raid Comp window hasn't been
-- opened yet this session, build it here too.
local function EnsureTemplateBuilt(RaidCompUI, raidKey, sizeKey)
	local templateKey = raidKey .. "_" .. sizeKey
	if not RaidCompUI.TEMPLATES[templateKey] and sizeKey == "CLASSRUN" then
		RaidCompUI.TEMPLATES[templateKey] = RaidCompUI:BuildClassRunTemplate()
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

-- One channel block: a channel field + Say/Yell/Guild/Raid quick-fills + its
-- own interval + its own Start/Stop + a status line. Both blocks post the same
-- ComposeRecruitMessage() text - only the destination and the timer differ.
-- Returns the widgets the caller needs to wire a spammer onto.
local function BuildChannelBlock(parent, yTop, labelText, channelKey, intervalKey, defaultInterval)
	local channelLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	channelLabel:SetPoint("TOPLEFT", 4, yTop)
	channelLabel:SetTextColor(0.7, 0.7, 0.7)
	channelLabel:SetText(labelText)

	local channelBox = Skin:CreateEditBox(parent, 200, 22)
	channelBox:SetPoint("TOPLEFT", 90, yTop + 4)
	channelBox.editBox:SetText(JohnnysRaidSpam.db.profile[channelKey] or "")
	channelBox.editBox:SetScript("OnTextChanged", function(self)
		JohnnysRaidSpam.db.profile[channelKey] = self:GetText()
	end)

	-- "Say"/"Yell"/"Guild"/"Raid" are chat types ResolveChannelType matches
	-- case-insensitively; "Trade" is a numbered channel it resolves by name.
	local presetX = 4
	for _, preset in ipairs({ "Say", "Yell", "Trade", "Guild", "Raid" }) do
		local btn = Skin:CreateButton(parent, 56, 20, preset)
		btn:SetPoint("TOPLEFT", presetX, yTop - 24)
		btn:SetScript("OnClick", function()
			channelBox.editBox:SetText(preset)
			JohnnysRaidSpam.db.profile[channelKey] = preset
		end)
		presetX = presetX + 60
	end

	local intervalLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	intervalLabel:SetPoint("TOPLEFT", 4, yTop - 52)
	intervalLabel:SetTextColor(0.7, 0.7, 0.7)
	intervalLabel:SetText("Repeat every (sec, min " .. MIN_INTERVAL .. "):")

	local intervalBox = Skin:CreateEditBox(parent, 70, 22)
	intervalBox:SetPoint("TOPLEFT", 230, yTop - 48)
	intervalBox.editBox:SetNumeric(true)
	intervalBox.editBox:SetText(tostring(JohnnysRaidSpam.db.profile[intervalKey] or defaultInterval))
	intervalBox.editBox:SetScript("OnTextChanged", function(self)
		JohnnysRaidSpam.db.profile[intervalKey] = tonumber(self:GetText()) or MIN_INTERVAL
	end)

	local startBtn = Skin:CreateButton(parent, 120, 24, "Start")
	startBtn:SetPoint("TOPLEFT", 4, yTop - 80)

	local statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statusText:SetPoint("TOPLEFT", 4, yTop - 108)
	statusText:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
	statusText:SetJustifyH("LEFT")
	statusText:SetJustifyV("TOP")
	statusText:SetTextColor(0.7, 0.7, 0.7)
	statusText:SetText("Stopped.")

	return channelBox, intervalBox, startBtn, statusText
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

	recruitChannelBox, recruitIntervalBox, recruitStartBtn, recruitStatusText =
		BuildChannelBlock(parent, -250, "Channel 1:", "raidSpamRecruitChannel", "raidSpamRecruitInterval", 90)

	AddDivider(parent, -376)

	recruitChannel2Box, recruitInterval2Box, recruitStart2Btn, recruitStatus2Text =
		BuildChannelBlock(parent, -390, "Channel 2:", "raidSpamRecruitChannel2", "raidSpamRecruitInterval2", 120)

	recruitSpammer = CreateSpammer(
		ComposeRecruitMessage,
		function() return recruitChannelBox.editBox:GetText() end,
		function() return recruitIntervalBox.editBox:GetText() end,
		recruitStatusText,
		recruitStartBtn
	)
	recruitStartBtn:SetScript("OnClick", function() recruitSpammer:Toggle() end)

	recruitSpammer2 = CreateSpammer(
		ComposeRecruitMessage,
		function() return recruitChannel2Box.editBox:GetText() end,
		function() return recruitInterval2Box.editBox:GetText() end,
		recruitStatus2Text,
		recruitStart2Btn
	)
	recruitStart2Btn:SetScript("OnClick", function() recruitSpammer2:Toggle() end)
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "JohnnysAddonHubRaidSpamFrame", UIParent)
	mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)

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
		end
	end)

	mainFrame:SetScript("OnShow", function()
		-- Re-dock on every show - the comp window may have been built since.
		ApplyDock()
		RefreshQuestLogEntries()
		RefreshRecruitPreview()
		previewTicker:Show()
	end)
	mainFrame:SetScript("OnHide", function()
		previewTicker:Hide()
		questDropdown:Close()
		-- Don't leave chat spam running unattended once the window's closed.
		if recruitSpammer and recruitSpammer:IsActive() then
			recruitSpammer:Stop()
		end
		if recruitSpammer2 and recruitSpammer2:IsActive() then
			recruitSpammer2:Stop()
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
