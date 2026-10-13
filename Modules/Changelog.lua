-- Changelog window, opened from the "Changelog" button at the bottom of the
-- Cfg panel (Modules\WindowSettings.lua). Lists what changed in each version,
-- newest first. Versions newer than the one you last opened this window on
-- are tagged NEW, so after an update the fresh entries stand out.
--
-- To add a release: put a new { version =, changes = { ... }, fixes = { ... } }
-- block at the TOP of ENTRIES and bump "## Version" in the .toc to match.
-- `changes` is what's new, `fixes` (optional) is bugs fixed - shown under
-- their own "Changes" / "Bug fixes" sub-headings.
local NS = JohnnysRaidComp
NS.Changelog = {}
local Changelog = NS.Changelog
local Skin = NS.Skin

local ENTRIES = {
	{
		version = "1.7.1",
		changes = {
			"Ready check is for the leader and assistants only: the button is hidden otherwise, and ready checks started by someone else aren't tracked.",
			"Gear check: each player's card shows missing enchants and empty gem sockets (e.g. \"2E 1G\"), and their tooltip names the slots - including a missing belt buckle. Rings aren't checked for enchants, since only enchanters can do those.",
			"Fixed GearScore for transmogged players: it was sometimes worked out from the transmog appearance instead of the gear they actually wear, giving a far too low score (and a false PvP tag). Scores are now only read once the inspect has fully arrived and the player's real gear has loaded.",
		},
	},
	{
		version = "1.7",
		changes = {
			"Roles now come from each player's talents, read when they're inspected, so a Shadow Priest or Prot Paladin moves to the right section once scanned. Until then they're placed by a class guess and marked with an amber \"?\".",
			"Raid Spammer: Run type tick boxes (Mount, EoF, Achievement, Fresh, Transmog, Rep Farm) that add e.g. \"Mount/EoF Run\" to the message through the new {type} token.",
			"Raid Spammer: Reserved section - a BoEs tick box, an Items picker and a free-text box - feeding the new {reserve} token (\"BoEs, Shards reserved\").",
			"The Items picker lists every boss of the raid picked in Raid Comp with its drops for that size and difficulty, plus a Common list of the usual reserves. Picks are remembered per raid.",
			"Raid Spammer stops by itself once the raid is full.",
			"The Raid Spammer preview shows the message length against the 255 character chat limit.",
			"GearScore scans finish sooner.",
			"Esc closes the Raid Comp window, and the Raid Spammer when it isn't running. Neither window can be dragged off-screen.",
			"This changelog, opened from the Cfg panel.",
		},
		fixes = {
			"The kick confirmation could open behind the Raid Comp window.",
			"Saved GearScore, role and achievement data no longer grows forever: players not seen for 30 days are dropped at login, and the data is now kept per realm.",
			"GearScores saved in an earlier session were never re-scanned after restarting your PC.",
			"A slot emptied by a swap could stay empty in later raids. Hand-made placements are now forgotten when the group ends.",
			"GearScore scans no longer swap the gear shown in your Inspect window - they pause while it's open.",
			"Raid Spammer no longer posts a message that's over the 255 character limit.",
			"Empty tokens no longer leave a stray \" -  - \" in the Raid Spammer message.",
			"The hidden update-check channel could take General's or Trade's channel number at login. It now waits for them before joining.",
		},
	},
	{
		version = "1.6",
		changes = {
			"TBC raids (Karazhan through Sunwell) alongside the WotLK ones. The raid list is now two collapsible groups.",
			"Each slot's corner arrow pins the slot to a class, or moves a class slot to another role it can play - e.g. the Shaman slot to Healers. Saved per raid and size.",
			"Tank and healer class slots are named by spec (\"Resto Shaman\", \"Prot Pala\"), on the cards and in the Raid Spammer's Need text, which now groups needs by role with counts.",
			"Class Run: tank and healer ticks work on empty slots too and rename the slot the same way.",
			"Ready check button: flags each player ready, not ready or AFK on their slot and summarises the result. Right-click clears the flags.",
			"Quick kick: Alt+click a slot or bench chip to remove that player, or \"Kick AFK\" after a ready check. Both ask first.",
		},
	},
	{
		version = "1.5",
		changes = {
			"New blue-black \"workshop\" look with a lime accent.",
			"Raid Comp is now one screen: raid list on the left, size buttons on top, and Tanks / Healers / DPS sections with a Still Need bar.",
			"Update checks from all of Johnny's addons share one slow queue, so logging in with several no longer trips the chat mute.",
		},
	},
	{
		version = "1.4",
		changes = {
			"Raid Spammer: a Channels list (General, Trade, LookingForGroup, Yell), each with its own tick box and interval, run by one Start/Stop.",
			"\"Class slots: On/Off\" turns the class-pinned slots into plain Any DPS / Any Healer slots.",
			"PvP gear and own-spec detection are built in, so Johnny's Gear Advisor is no longer needed for them.",
		},
	},
	{
		version = "1.3",
		changes = {
			"Built-in GearScore, so GearScoreLite no longer has to be installed.",
		},
	},
}

local FRAME_W, FRAME_H = 460, 440
local PAD = 14

local frame

-- "1.10" > "1.9": compares dot-separated numbers, not text.
local function VersionNewer(a, b)
	local pa, pb = {}, {}
	for n in string.gmatch(tostring(a or ""), "%d+") do
		table.insert(pa, tonumber(n))
	end
	for n in string.gmatch(tostring(b or ""), "%d+") do
		table.insert(pb, tonumber(n))
	end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

local function InstalledVersion()
	return GetAddOnMetadata("JohnnysRaidComp", "Version") or "0"
end

-- True while there are entries the player hasn't opened the changelog on yet
-- (drives the "new" marker on the Cfg panel's button).
function Changelog:HasUnseen()
	local seen = NS.db.global.changelogSeenVersion
	return VersionNewer(InstalledVersion(), seen or "0")
end

local function Build()
	local C = Skin.C
	frame = CreateFrame("Frame", "JohnnysRaidCompChangelog", UIParent)
	frame:SetSize(FRAME_W, FRAME_H)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	Skin:StylePanel(frame, 0.97)
	frame:Hide()
	table.insert(UISpecialFrames, "JohnnysRaidCompChangelog") -- Esc closes it

	local title = Skin:AddHeader(frame, "Changelog")
	local sub = Skin:Heading(frame, 12, C.muted)
	sub:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 10, 1)
	sub:SetText("JOHNNY'S RAID COMP  /  INSTALLED " .. InstalledVersion())

	local close = Skin:CreateButton(frame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() frame:Hide() end)

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", PAD, 8)
	hint:SetText("Mouse wheel to scroll - newest first.")

	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", PAD, -(Skin.HEADER_HEIGHT + 10))
	scroll:SetPoint("BOTTOMRIGHT", -PAD, 30)
	scroll:EnableMouseWheel(true)

	local content = CreateFrame("Frame", nil, scroll)
	local contentW = FRAME_W - PAD * 2
	content:SetWidth(contentW)
	content:SetHeight(10)
	scroll:SetScrollChild(content)

	-- Never shown: no width set, so GetStringWidth gives an entry's full
	-- unwrapped width (see the height calculation below).
	local measure = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	measure:Hide()
	local LINE_H = 13

	local installed = InstalledVersion()
	local seen = NS.db.global.changelogSeenVersion or "0"
	local y = 0
	for _, entry in ipairs(ENTRIES) do
		local head = Skin:Heading(content, 15, C.accent)
		head:SetPoint("TOPLEFT", 0, -y)
		head:SetText("VERSION " .. entry.version)

		local tag
		if VersionNewer(entry.version, installed) then
			tag = "NOT RELEASED YET"
		elseif entry.version == installed then
			tag = VersionNewer(entry.version, seen) and "NEW  -  THIS VERSION" or "THIS VERSION"
		elseif VersionNewer(entry.version, seen) then
			tag = "NEW"
		end
		if tag then
			local tagText = Skin:Heading(content, 11, C.muted)
			tagText:SetPoint("BOTTOMLEFT", head, "BOTTOMRIGHT", 10, 1)
			tagText:SetText(tag)
			if string.find(tag, "NEW", 1, true) == 1 then
				tagText:SetTextColor(1, 0.85, 0.40)
			end
		end
		y = y + 22

		-- Changes first, then bug fixes. The two sub-headings only appear on a
		-- version that has fixes; one with changes alone is a plain list.
		local hasFixes = entry.fixes and #entry.fixes > 0
		local sections = {
			{ label = "CHANGES", items = entry.changes or {} },
			{ label = "BUG FIXES", items = entry.fixes or {} },
		}
		for _, section in ipairs(sections) do
			if #section.items > 0 then
				if hasFixes then
					local subHead = Skin:Heading(content, 11, C.muted)
					subHead:SetPoint("TOPLEFT", 2, -y)
					subHead:SetText(section.label)
					y = y + 16
				end

				for _, change in ipairs(section.items) do
					local dot = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					dot:SetPoint("TOPLEFT", 2, -y)
					dot:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
					dot:SetText("-")

					local line = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					line:SetPoint("TOPLEFT", 14, -y)
					line:SetWidth(contentW - 18)
					line:SetJustifyH("LEFT")
					line:SetJustifyV("TOP")
					line:SetTextColor(C.text[1], C.text[2], C.text[3])
					line:SetText(change)
					-- GetHeight can report one line for text that only just
					-- wraps onto a second, which made the next entry overlap
					-- it. Cross-check against the text's unwrapped width (with
					-- some slack, since word wrap breaks early) and take the
					-- taller of the two.
					measure:SetText(change)
					local wrapLines = math.ceil(measure:GetStringWidth() / ((contentW - 18) * 0.93))
					y = y + math.max(12, line:GetHeight(), wrapLines * LINE_H) + 6
				end

				if hasFixes then
					y = y + 4
				end
			end
		end

		local rule = Skin:Solid(content, "ARTWORK", C.rule)
		rule:SetPoint("TOPLEFT", 0, -(y + 4))
		rule:SetPoint("TOPRIGHT", 0, -(y + 4))
		rule:SetHeight(1)
		y = y + 16
	end
	content:SetHeight(y)

	scroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = math.max(0, content:GetHeight() - self:GetHeight())
		local target = self:GetVerticalScroll() - delta * 40
		self:SetVerticalScroll(math.max(0, math.min(maxScroll, target)))
	end)
end

-- Docks the window beside the Raid Comp window, tops level, so the two never
-- overlap: on its left if there's room, otherwise on its right (past the Raid
-- Spammer when that is docked there). Only if neither side has room - or Raid
-- Comp is closed - does it fall back to the middle of the screen.
local function Place()
	local comp = _G["JohnnysAddonHubRaidCompFrame"]
	frame:ClearAllPoints()
	if comp and comp:IsShown() and comp:GetLeft() then
		-- Everything in real screen pixels, since the windows can be scaled.
		local need = (FRAME_W + 6) * frame:GetEffectiveScale()
		local compScale = comp:GetEffectiveScale()
		if comp:GetLeft() * compScale >= need then
			frame:SetPoint("TOPRIGHT", comp, "TOPLEFT", -6, 0)
			return
		end

		local edge, edgeScale = comp, compScale
		local spam = _G["JohnnysAddonHubRaidSpamFrame"]
		if spam and spam:IsShown() and spam:GetRight()
			and spam:GetRight() * spam:GetEffectiveScale() > comp:GetRight() * compScale then
			edge, edgeScale = spam, spam:GetEffectiveScale()
		end
		local screenRight = UIParent:GetRight() * UIParent:GetEffectiveScale()
		if screenRight - edge:GetRight() * edgeScale >= need then
			frame:SetPoint("TOPLEFT", edge, "TOPRIGHT", 6, 0)
			return
		end
	end
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

local function Open()
	if not frame then
		Build()
	end
	Place()
	frame:Show()
	-- Everything up to the installed version now counts as seen. The NEW
	-- tags were painted when the window was built, so they stay up for the
	-- rest of this session.
	NS.db.global.changelogSeenVersion = InstalledVersion()
end

function Changelog:Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		Open()
	end
end

-- Called when the Raid Comp window opens: pops the changelog up beside it
-- once per update, until it has been looked at.
function Changelog:ShowIfUnseen()
	if self:HasUnseen() then
		Open()
	end
end

-- Called when the Raid Comp window closes, so the changelog doesn't stay
-- behind on its own.
function Changelog:Hide()
	if frame then
		frame:Hide()
	end
end
