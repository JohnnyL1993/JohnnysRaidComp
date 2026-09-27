-- Standalone launcher for Johnny's Raid Comp.
--
-- This addon has no launcher of its own - RaidCompUI:Toggle() / RaidSpamUI:Toggle()
-- are normally driven by the separate "Johnny's Addon Hub" addon. With the hub
-- installed there's nothing to do here. Without it, this addon would be
-- unopenable, so on the first login where no hub is present we prompt the user
-- to pick a launcher style - a minimap button, or a small collapsible
-- hub-style panel - build it, and remember the choice in
-- db.profile.launcherMode for next time.
--
-- Same plain CreateFrame + JohnnysRaidComp.Skin chrome as the rest of the
-- addon. This addon bundles only LibStub/CallbackHandler/AceAddon/AceDB (no
-- AceEvent, no AceConsole), so the login hook is a bare event frame and the
-- slash command goes straight into SlashCmdList.

local Skin = JohnnysRaidComp.Skin

local function DB()
	return JohnnysRaidComp.db.profile
end

----------------------------------------------------------------------------
-- Launcher list - mirrors JohnnysAddonHub\Modules\Hub\Init.lua's LAUNCHERS.
-- Raid Comp / Raid Spammer are always shown (Raid Spammer ships inside this
-- addon); the rest appear only when their standalone addon is loaded. Load
-- state doesn't change mid-session, so this is safe to re-derive each rebuild.
----------------------------------------------------------------------------
local LAUNCHERS = {
	{ name = "Raid Comp", onClick = function()
		JohnnysRaidComp.RaidCompUI:Toggle()
	end },
	{ name = "Raid Spammer", onClick = function()
		if JohnnysRaidSpam and JohnnysRaidSpam.RaidSpamUI then
			JohnnysRaidSpam.RaidSpamUI:Toggle()
		end
	end },
	{ name = "Gear Advisor", addon = "JohnnysGearAdvisor", onClick = function()
		JohnnysGearAdvisor:Toggle()
	end },
	{ name = "Blacklist", addon = "JohnnysBlackList", onClick = function()
		JohnnysBlackList:Toggle()
	end },
	{ name = "Raid Browser", addon = "JohnnysRaidBrowser", onClick = function()
		JohnnysRaidBrowser.RaidBrowserUI:Toggle()
	end },
	{ name = "Raid Roll", addon = "JohnnysRaidRoll", onClick = function()
		JohnnysRaidRoll.RaidRollUI:Toggle()
	end },
	{ name = "Raid Loot", addon = "JohnnysRaidRoll", onClick = function()
		JohnnysRaidRoll.RaidLootUI:Toggle()
	end },
}

local function GetVisibleLaunchers()
	local visible = {}
	for _, launcher in ipairs(LAUNCHERS) do
		if not launcher.addon or IsAddOnLoaded(launcher.addon) then
			table.insert(visible, launcher)
		end
	end
	return visible
end

----------------------------------------------------------------------------
-- Hub-style panel (mode "hub") - a small always-on-screen column of launcher
-- buttons with a collapse toggle, a stripped-down port of the real hub bar.
----------------------------------------------------------------------------
local PANEL_WIDTH = 150
local ROW_HEIGHT = 22
local PADDING = 6

local panel, panelTitle, panelToggle
local panelButtons = {}

local function SavePanelPosition()
	local point, _, relativePoint, x, y = panel:GetPoint()
	local pos = DB().launcherPanelPosition
	pos.point, pos.relativePoint, pos.x, pos.y = point, relativePoint, x, y
end

local function LayoutPanel()
	local collapsed = DB().launcherPanelCollapsed
	local visible = #panelButtons

	if collapsed then
		panelTitle:Hide()
		for _, btn in ipairs(panelButtons) do
			btn:Hide()
		end
		panelToggle.text:SetText("+")
		panel:SetSize(PANEL_WIDTH, ROW_HEIGHT + PADDING * 2)
	else
		panelTitle:Show()
		for _, btn in ipairs(panelButtons) do
			btn:Show()
		end
		panelToggle.text:SetText("-")
		panel:SetSize(PANEL_WIDTH, ROW_HEIGHT + PADDING * 2 + visible * (ROW_HEIGHT + 4))
	end
end

local function RebuildPanelButtons()
	for _, btn in ipairs(panelButtons) do
		btn:Hide()
		btn:SetParent(nil)
	end
	panelButtons = {}

	local y = -(PADDING + ROW_HEIGHT + 2)
	for _, launcher in ipairs(GetVisibleLaunchers()) do
		local btn = Skin:CreateButton(panel, PANEL_WIDTH - PADDING * 2, ROW_HEIGHT, launcher.name)
		btn:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, y)
		btn:SetScript("OnClick", launcher.onClick)
		table.insert(panelButtons, btn)
		y = y - (ROW_HEIGHT + 4)
	end

	LayoutPanel()
end

local function BuildHubPanel()
	if panel then
		panel:Show()
		return
	end

	panel = CreateFrame("Frame", "JohnnysRaidCompLauncher", UIParent)
	local pos = DB().launcherPanelPosition
	panel:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
	Skin:StylePanel(panel, 0.9)
	panel:SetFrameStrata("MEDIUM")
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePanelPosition()
	end)

	panelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panelTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -PADDING)
	panelTitle:SetText("Raid Comp")

	panelToggle = Skin:CreateButton(panel, ROW_HEIGHT - 4, ROW_HEIGHT - 4, "-")
	panelToggle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PADDING, -PADDING + 1)
	panelToggle:SetScript("OnClick", function()
		DB().launcherPanelCollapsed = not DB().launcherPanelCollapsed
		LayoutPanel()
	end)

	if JohnnysRaidComp.WindowSettings then
		JohnnysRaidComp.WindowSettings:Register(panel, "launcher", "Launcher panel")
	end

	RebuildPanelButtons()
end

----------------------------------------------------------------------------
-- Minimap button (mode "minimap") - hand-rolled (no LibDBIcon bundled),
-- dragged around the minimap ring with its angle persisted. Left-click opens
-- Raid Comp, right-click opens the Raid Spammer.
----------------------------------------------------------------------------
local MINIMAP_RADIUS = 80

local minimapButton

local function PositionMinimapButton()
	local a = math.rad(DB().minimapButtonAngle)
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER",
		MINIMAP_RADIUS * math.cos(a), MINIMAP_RADIUS * math.sin(a))
end

local function BuildMinimapButton()
	if minimapButton then
		minimapButton:Show()
		return
	end

	minimapButton = CreateFrame("Button", "JohnnysRaidCompMinimapButton", Minimap)
	minimapButton:SetSize(31, 31)
	minimapButton:SetFrameStrata("MEDIUM")
	minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 8)

	local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
	icon:SetSize(19, 19)
	icon:SetPoint("CENTER", 0, 1)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = minimapButton:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT", 0, 0)

	minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	minimapButton:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			if JohnnysRaidSpam and JohnnysRaidSpam.RaidSpamUI then
				JohnnysRaidSpam.RaidSpamUI:Toggle()
			end
		else
			JohnnysRaidComp.RaidCompUI:Toggle()
		end
	end)

	minimapButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Johnny's Raid Comp")
		GameTooltip:AddLine("Left-click: Raid Comp", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Right-click: Raid Spammer", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("/jrc launcher to change this button", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	minimapButton:SetScript("OnLeave", GameTooltip_Hide)

	-- Drag around the ring: while dragging, an OnUpdate recomputes the angle
	-- from the cursor position relative to the minimap centre.
	minimapButton:RegisterForDrag("LeftButton")
	minimapButton:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			cx, cy = cx / scale, cy / scale
			DB().minimapButtonAngle = math.deg(math.atan2(cy - my, cx - mx))
			PositionMinimapButton()
		end)
	end)
	minimapButton:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	PositionMinimapButton()
end

----------------------------------------------------------------------------
-- First-run chooser prompt - shown once on a hub-less login, and again on
-- demand via "/jrc launcher".
----------------------------------------------------------------------------
local chooser

local SetLauncherMode -- forward declaration (defined with the slash handler)

local function BuildChooser()
	chooser = CreateFrame("Frame", nil, UIParent)
	chooser:SetSize(340, 150)
	chooser:SetPoint("CENTER")
	Skin:StylePanel(chooser, 0.97)
	chooser:SetFrameStrata("DIALOG")
	chooser:EnableMouse(true)

	local title = chooser:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Johnny's Raid Comp")

	local body = chooser:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	body:SetPoint("TOP", title, "BOTTOM", 0, -10)
	body:SetWidth(300)
	body:SetText("How do you want to open it? You can change this later with /jrc launcher.")

	local minimapBtn = Skin:CreateButton(chooser, 140, 26, "Minimap Button")
	minimapBtn:SetPoint("BOTTOMLEFT", 20, 18)
	minimapBtn:SetScript("OnClick", function()
		SetLauncherMode("minimap")
		chooser:Hide()
	end)

	local panelBtn = Skin:CreateButton(chooser, 140, 26, "Hub Panel")
	panelBtn:SetPoint("BOTTOMRIGHT", -20, 18)
	panelBtn:SetScript("OnClick", function()
		SetLauncherMode("hub")
		chooser:Hide()
	end)

	-- Closing without choosing falls back to the minimap button so the addon
	-- is still openable.
	local close = Skin:CreateButton(chooser, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function()
		SetLauncherMode("minimap")
		chooser:Hide()
	end)
end

local function ShowChooserPrompt()
	if not chooser then
		BuildChooser()
	end
	chooser:Show()
end

----------------------------------------------------------------------------
-- Mode application
----------------------------------------------------------------------------
-- Sets and persists the launcher style, building the chosen widget and hiding
-- the other. Safe to call repeatedly / to switch at runtime. Assigned (not
-- redeclared) so the forward-declared local above is what gets filled in.
SetLauncherMode = function(mode)
	DB().launcherMode = mode

	if mode == "minimap" then
		if panel then panel:Hide() end
		BuildMinimapButton()
	elseif mode == "hub" then
		if minimapButton then minimapButton:Hide() end
		BuildHubPanel()
	else -- "none"
		if panel then panel:Hide() end
		if minimapButton then minimapButton:Hide() end
	end
end

local function ApplyLauncher()
	-- The Addon Hub is the launcher whenever it's installed - don't build our
	-- own alongside it. The saved launcherMode is left untouched, so removing
	-- the hub again brings the chosen minimap button / panel straight back.
	-- (Load state can't change mid-session, so this one check on login is
	-- enough; "/jrc minimap|hub" still forces ours if you really want both.)
	if IsAddOnLoaded("JohnnysAddonHub") then
		return
	end

	local mode = DB().launcherMode
	if mode == "minimap" or mode == "hub" or mode == "none" then
		SetLauncherMode(mode)
	elseif not mode then
		ShowChooserPrompt()
	end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
	ApplyLauncher()
end)

----------------------------------------------------------------------------
-- Slash command - always available regardless of launcher mode / the hub.
----------------------------------------------------------------------------
SLASH_JOHNNYSRAIDCOMP1 = "/jrc"
SLASH_JOHNNYSRAIDCOMP2 = "/raidcomp"
SlashCmdList["JOHNNYSRAIDCOMP"] = function(msg)
	local arg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

	if arg == "" or arg == "comp" then
		JohnnysRaidComp.RaidCompUI:Toggle()
	elseif arg == "lfm" or arg == "spam" then
		if JohnnysRaidSpam and JohnnysRaidSpam.RaidSpamUI then
			JohnnysRaidSpam.RaidSpamUI:Toggle()
		end
	elseif arg == "launcher" or arg == "chooser" then
		ShowChooserPrompt()
	elseif arg == "settings" or arg == "config" or arg == "cfg" then
		if JohnnysRaidComp.WindowSettings then
			JohnnysRaidComp.WindowSettings:Toggle()
		end
	elseif arg == "ach" then
		local RaidCompUI = JohnnysRaidComp.RaidCompUI
		local on = not RaidCompUI:IsAchievementTooltipEnabled()
		RaidCompUI:SetAchievementTooltipEnabled(on)
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffJohnny's Raid Comp|r: achievements in tooltips " .. (on and "ON" or "OFF"))
	elseif arg == "achcheck" then
		JohnnysRaidComp.RaidCompUI:PrintAchievementCheck()
	elseif arg:match("^statsearch") then
		JohnnysRaidComp.RaidCompUI:PrintStatSearch(arg:match("^statsearch%s+(.+)$"))
	elseif arg == "minimap" then
		SetLauncherMode("minimap")
	elseif arg == "hub" or arg == "panel" then
		SetLauncherMode("hub")
	elseif arg == "none" or arg == "off" then
		SetLauncherMode("none")
	elseif arg == "version" or arg == "ver" then
		JohnnysRaidComp.VersionCheck:PrintStatus()
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffJohnny's Raid Comp|r: /jrc [comp | lfm | settings | ach | achcheck | statsearch <text> | launcher | minimap | hub | none | version]")
	end
end
