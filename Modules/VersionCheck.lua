-- In-game "update available" banner for Johnny's Raid Comp.
--
-- WoW can't reach the internet, so there's no way to ask GitHub what the
-- latest release is. Instead every copy of the addon announces its own TOC
-- version to other players running it, and any client that hears a higher
-- version than its own shows a small banner pointing at the GitHub Releases
-- page.
--
-- Transport: Warmane blocks SendAddonMessage on public channels, so the
-- server-wide leg is a hidden temporary chat channel carrying plain
-- SendChatMessage lines tagged "JRCV:<version>", with a chat filter hiding
-- those lines (and the channel's join/leave notices) from every chat frame.
-- SendAddonMessage still works for GUILD / RAID / PARTY, so those use it.
--
-- Sends are kept rare so the channel never looks like spam: once on the
-- channel after joining, once to guild at login, to the group on roster
-- changes (throttled), and a single delayed reply when we hear someone on an
-- older version. The highest version heard is saved in
-- db.global.latestSeenVersion so the banner still shows on later logins even
-- when nobody else is online.
--
-- Anyone can fake a "JRCV:99" line; the worst it does is show a pointless
-- banner, so there's no protection against it.

local Skin = JohnnysRaidComp.Skin

local ADDON_NAME = "JohnnysRaidComp"
local TAG = "JRCV"
local CHANNEL = "JohnnysAddons"
local RELEASES_URL = "https://github.com/linnelljohn1-spec/JohnnysRaidComp/releases"

local JOIN_DELAY = 5            -- after first PLAYER_ENTERING_WORLD
local CHANNEL_ANNOUNCE_DELAY = 10 -- after joining
local GROUP_THROTTLE = 60
local REPLY_THROTTLE = 600
local REPLY_DELAY_MIN, REPLY_DELAY_MAX = 5, 30

local PREFIX = "|cff66ccffJohnny's Raid Comp|r: "

local myVersion = GetAddOnMetadata(ADDON_NAME, "Version") or "0"
local playerName = UnitName("player")

local started = false
local bannerShownThisSession = false
local lastGroupSend = -GROUP_THROTTLE
local lastReply = -REPLY_THROTTLE
local replyPending = false

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

----------------------------------------------------------------------------
-- Version comparison - numeric per dotted part, so 1.10 > 1.9 and 1.2 == 1.2.0.
----------------------------------------------------------------------------
local function ParseVersion(v)
	local parts = {}
	for num in tostring(v):gmatch("%d+") do
		table.insert(parts, tonumber(num))
	end
	return parts
end

-- Returns 1 if a > b, -1 if a < b, 0 if equal.
local function CompareVersions(a, b)
	local pa, pb = ParseVersion(a), ParseVersion(b)
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x > y then return 1 end
		if x < y then return -1 end
	end
	return 0
end

----------------------------------------------------------------------------
-- Tiny delay helper - 3.3.5 has no C_Timer, so one shared OnUpdate frame runs
-- pending callbacks when their time comes up.
----------------------------------------------------------------------------
local timerFrame = CreateFrame("Frame")
local timers = {}

timerFrame:SetScript("OnUpdate", function()
	local now = GetTime()
	for i = #timers, 1, -1 do
		local t = timers[i]
		if now >= t.at then
			table.remove(timers, i)
			t.fn()
		end
	end
	if #timers == 0 then
		timerFrame:Hide()
	end
end)
timerFrame:Hide()

local function After(seconds, fn)
	table.insert(timers, { at = GetTime() + seconds, fn = fn })
	timerFrame:Show()
end

----------------------------------------------------------------------------
-- Banner
----------------------------------------------------------------------------
local banner

local function BuildBanner()
	banner = CreateFrame("Frame", "JohnnysRaidCompUpdateBanner", UIParent)
	banner:SetSize(360, 70)
	banner:SetPoint("TOP", UIParent, "TOP", 0, -120)
	banner:SetFrameStrata("DIALOG")
	Skin:StylePanel(banner)
	banner:SetMovable(true)
	banner:EnableMouse(true)
	banner:RegisterForDrag("LeftButton")
	banner:SetScript("OnDragStart", banner.StartMoving)
	banner:SetScript("OnDragStop", banner.StopMovingOrSizing)
	banner:SetClampedToScreen(true)

	local text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT", 10, -10)
	text:SetPoint("TOPRIGHT", -30, -10)
	text:SetJustifyH("LEFT")
	banner.text = text

	local close = Skin:CreateButton(banner, 18, 18, "x")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() banner:Hide() end)

	-- Read-only URL box: re-selects everything on focus/click and undoes any
	-- typing, so it's just a place to Ctrl+C the link from.
	local urlHolder = Skin:CreateEditBox(banner, 340, 20)
	urlHolder:SetPoint("BOTTOM", 0, 10)
	local edit = urlHolder.editBox
	edit:SetText(RELEASES_URL)
	edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(RELEASES_URL)
			self:HighlightText()
		end
	end)
	edit:SetCursorPosition(0)

	banner:Hide()
end

local function ShowBanner(newVersion)
	if not banner then
		BuildBanner()
	end
	banner.text:SetText(("Version |cff66ff66%s|r is available (you have %s).\nCopy the link below with Ctrl+C:"):format(newVersion, myVersion))
	banner:Show()
	bannerShownThisSession = true
end

----------------------------------------------------------------------------
-- Sending
----------------------------------------------------------------------------
local function Message()
	return TAG .. ":" .. myVersion
end

local function SendOnChannel()
	local id = GetChannelName(CHANNEL)
	if id and id > 0 then
		SendChatMessage(Message(), "CHANNEL", nil, id)
	end
end

local function SendAddon(distribution)
	SendAddonMessage(TAG, myVersion, distribution)
end

local function SendToGroup()
	local now = GetTime()
	if now - lastGroupSend < GROUP_THROTTLE then
		return
	end
	if GetNumRaidMembers() > 0 then
		SendAddon("RAID")
	elseif GetNumPartyMembers() > 0 then
		SendAddon("PARTY")
	else
		return
	end
	lastGroupSend = now
end

-- Someone on an older version spoke - tell them once, after a random delay so
-- a crowd of up-to-date clients doesn't all answer at the same moment.
local function ScheduleReply(send)
	if replyPending or GetTime() - lastReply < REPLY_THROTTLE then
		return
	end
	replyPending = true
	After(math.random(REPLY_DELAY_MIN, REPLY_DELAY_MAX), function()
		replyPending = false
		lastReply = GetTime()
		send()
	end)
end

----------------------------------------------------------------------------
-- Receiving
----------------------------------------------------------------------------
local function OnVersionHeard(version, sender, reply)
	if not version or version == "" or sender == playerName then
		return
	end

	local cmp = CompareVersions(version, myVersion)
	if cmp > 0 then
		local db = JohnnysRaidComp.db.global
		if not db.latestSeenVersion or CompareVersions(version, db.latestSeenVersion) > 0 then
			db.latestSeenVersion = version
		end
		if not bannerShownThisSession then
			Print(("version %s is available (you have %s) - %s"):format(db.latestSeenVersion, myVersion, RELEASES_URL))
			ShowBanner(db.latestSeenVersion)
		end
	elseif cmp < 0 then
		ScheduleReply(reply)
	end
end

local function IsOurChannel(channelName)
	return channelName and channelName:lower() == CHANNEL:lower()
end

-- Chat filters: hide our tagged lines and the channel's join/leave notices.
-- Args after (self, event) are the event's arg1..argN; arg9 is the channel's
-- base name for all three CHAT_MSG_CHANNEL* events.
local function ChannelMessageFilter(self, event, msg, ...)
	if msg and msg:sub(1, #TAG + 1) == TAG .. ":" then
		return true
	end
end

local function ChannelNoticeFilter(self, event, ...)
	if IsOurChannel((select(9, ...))) then
		return true
	end
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", ChannelMessageFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", ChannelNoticeFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", ChannelNoticeFilter)

----------------------------------------------------------------------------
-- Channel join
----------------------------------------------------------------------------
local function JoinVersionChannel()
	if GetChannelName(CHANNEL) == 0 then
		JoinTemporaryChannel(CHANNEL)
	end
	-- Keep it out of every chat window even if some frame picked it up.
	for i = 1, NUM_CHAT_WINDOWS do
		local frame = _G["ChatFrame" .. i]
		if frame then
			ChatFrame_RemoveChannel(frame, CHANNEL)
		end
	end
	After(CHANNEL_ANNOUNCE_DELAY, SendOnChannel)
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_CHANNEL")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")

local function OnFirstEnterWorld()
	local db = JohnnysRaidComp.db.global
	if db.latestSeenVersion then
		if CompareVersions(db.latestSeenVersion, myVersion) > 0 then
			ShowBanner(db.latestSeenVersion)
		else
			db.latestSeenVersion = nil
		end
	end

	After(JOIN_DELAY, JoinVersionChannel)
	if IsInGuild() then
		After(JOIN_DELAY, function() SendAddon("GUILD") end)
	end
	SendToGroup()
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_ENTERING_WORLD" then
		if not started then
			started = true -- PLAYER_ENTERING_WORLD also fires on every zone change
			OnFirstEnterWorld()
		end
	elseif event == "CHAT_MSG_CHANNEL" then
		local msg, sender = ...
		local channelName = select(9, ...)
		if IsOurChannel(channelName) and msg then
			local version = msg:match("^" .. TAG .. ":(%S+)")
			OnVersionHeard(version, sender, SendOnChannel)
		end
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, msg, distribution, sender = ...
		if prefix == TAG then
			OnVersionHeard(msg, sender, function() SendAddon(distribution) end)
		end
	elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		SendToGroup()
	end
end)

----------------------------------------------------------------------------
-- Public - used by "/jrc version" in Modules\Launcher.lua.
----------------------------------------------------------------------------
JohnnysRaidComp.VersionCheck = {}

function JohnnysRaidComp.VersionCheck:PrintStatus()
	local latest = JohnnysRaidComp.db.global.latestSeenVersion
	if latest and CompareVersions(latest, myVersion) > 0 then
		Print(("installed %s, newer version %s seen - %s"):format(myVersion, latest, RELEASES_URL))
		ShowBanner(latest)
	else
		Print(("installed %s - no newer version seen."):format(myVersion))
	end
end
