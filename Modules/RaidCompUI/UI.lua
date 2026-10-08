-- Raid Comp window: pick a WotLK raid instance, then its size/difficulty,
-- then see that raid's tailored "ideal comp" grid light up as real raid/party
-- members whose class+role match a slot join the group. Same plain
-- CreateFrame/Skin chrome as the rest of the hub (see Modules\BlackListUI\UI.lua
-- for the pattern this mirrors).
JohnnysRaidComp.RaidCompUI = JohnnysRaidComp.RaidCompUI or {}
local RaidCompUI = JohnnysRaidComp.RaidCompUI
local Skin = JohnnysRaidComp.Skin

-- FRAME_HEIGHT is only the starting/fallback size - every page sizes the
-- window to its own content (see SetFrameHeight and its callers in
-- ShowRaidList / ShowSizeList / RefreshComp) so a 2-row 10-man or the raid
-- picker doesn't leave a screenful of dead space below it.
local FRAME_WIDTH, FRAME_HEIGHT = 820, 560

local RAID_COLS = 3
local RAID_BUTTON_WIDTH, RAID_BUTTON_HEIGHT = 230, 34
local RAID_GAP = 10

local SIZE_BUTTON_WIDTH, SIZE_BUTTON_HEIGHT = 160, 28
local SIZE_GAP = 12

local COLUMNS = 5
-- Tall enough for a 3rd line (GearScore) below the name; GRID_TOP/row math
-- below all derive from this constant, so nothing else needs adjusting.
local CARD_WIDTH, CARD_HEIGHT = 148, 58
local CARD_GAP = 6
local GRID_TOP = -104

-- Bench (overflow) chips - roster members who didn't land in any slot,
-- rendered below the grid so nobody just silently vanishes off-screen.
local BENCH_COLUMNS = 6
-- Tall enough for a 2nd, small line (compact GearScore) below the name.
local BENCH_CHIP_WIDTH, BENCH_CHIP_HEIGHT = 110, 30
local BENCH_GAP = 6

-- Turns "how many pixels of grid/bench sit below GRID_TOP" into a window
-- height. Above the grid: compPage's 44px top inset + the header/hint block
-- down to GRID_TOP. Below: a small gap + the Report-to-VH button strip + the
-- bottom margin. See SetFrameHeight / its call at the end of RefreshComp.
local COMP_CHROME_TOP = 44 - GRID_TOP
local COMP_CHROME_BOTTOM = 52
local MIN_FRAME_HEIGHT = 240

local mainFrame, raidListPage, sizeListPage, compPage
local sizeListButtons = {}
local classRunEntryButton
local headerText = {}
-- The Tank/Healer +/- buttons and the Reset button - shown/hidden together
-- with headerText's tank/healer/dps trio (Class Run has no adjustable
-- counts). DPS has no buttons of its own - it's always "whatever's left"
-- after Tanks/Healers are set, so it never needs a direct control.
local countControls = {}
local slotCards = {}
local benchChips = {}
local benchLabel
-- Status line next to the "Report uninspected to VH" button (see
-- BuildCompPage / RaidCompUI:AnnounceUninspected).
local reportVHStatus
local currentRaid, currentSize
-- What "< Back" on the comp page should do - differs depending on whether we
-- arrived via the normal size list or Class Run.
local compBackAction

-- matches from the last RefreshComp, so a click can read "who's in slot X
-- right now" without recomputing; and the current selection awaiting a
-- second click to act on (nil when nothing is selected) - either a slot
-- ({kind="slot", value=index}) or a benched roster member
-- ({kind="bench", value=name}).
local currentMatches = {}
local selection = nil

-- [name] = true when a GearScore rescan returned a *different* score for that
-- member and the leader hasn't acknowledged it yet (by hovering or clicking
-- their box). Drives the amber pulse in gsFlashPump (see the GearScore section
-- at the bottom of this file). Session-only, not persisted - it's a transient
-- "look at this" cue, and a re-inspect on login naturally re-flags a real change.
local gsChanged = {}

-- Role of each talent tree, in the talent frame's fixed left-to-right tab
-- order for 3.3.5a - the tree with the most points is taken as your spec.
local TALENT_TAB_ROLES = {
	WARRIOR = { "DAMAGER", "DAMAGER", "TANK" },          -- Arms, Fury, Protection
	PALADIN = { "HEALER", "TANK", "DAMAGER" },           -- Holy, Protection, Retribution
	HUNTER = { "DAMAGER", "DAMAGER", "DAMAGER" },
	ROGUE = { "DAMAGER", "DAMAGER", "DAMAGER" },
	PRIEST = { "HEALER", "HEALER", "DAMAGER" },          -- Discipline, Holy, Shadow
	DEATHKNIGHT = { "TANK", "DAMAGER", "DAMAGER" },      -- Blood, Frost, Unholy
	SHAMAN = { "DAMAGER", "DAMAGER", "HEALER" },         -- Elemental, Enhancement, Restoration
	MAGE = { "DAMAGER", "DAMAGER", "DAMAGER" },
	WARLOCK = { "DAMAGER", "DAMAGER", "DAMAGER" },
	DRUID = { "DAMAGER", "DAMAGER", "HEALER" },          -- Balance, Feral, Restoration
}

-- Your own role from your active talents - no inspect needed, since your own
-- talents can be read directly. nil if no points are spent yet.
local function GetPlayerSpecRole(class)
	local roles = TALENT_TAB_ROLES[class]
	if not roles then
		return nil
	end
	local bestTab, bestPoints = nil, 0
	for tabIndex = 1, GetNumTalentTabs() do
		local _, _, pointsSpent = GetTalentTabInfo(tabIndex)
		if (pointsSpent or 0) > bestPoints then
			bestTab, bestPoints = tabIndex, pointsSpent
		end
	end
	return bestTab and roles[bestTab]
end

-- Resolves a unit's role: the manually-set raid-frame role icon if present,
-- else (for the player only) the real active talent spec via GetPlayerSpecRole
-- - no inspect needed since that reads your own talents directly - else a rough
-- per-class guess (see RaidCompUI.CLASS_DEFAULT_ROLE) so the member still
-- shows up instead of being silently dropped.
local function ResolveUnitRole(unit, class)
	local assigned = UnitGroupRolesAssigned(unit)
	if assigned and assigned ~= "NONE" then
		return assigned
	end

	-- UnitIsUnit, not a string == "player" check - in an actual raid the
	-- player's own unit token is "raidN" for whichever N they're slotted at,
	-- not literally "player".
	if UnitIsUnit(unit, "player") then
		local role = GetPlayerSpecRole(class)
		if role then
			return role
		end
	end

	return RaidCompUI.CLASS_DEFAULT_ROLE[class] or "DAMAGER"
end

----------------------------------------------------------------------------
-- Roster scan - iterate the real raid (falling back to party/solo), reading
-- each unit's class and role via ResolveUnitRole above. Every existing member
-- gets included now (accurately or via best-effort guess) rather than only
-- those who happen to have a manually-set role icon.
----------------------------------------------------------------------------
function RaidCompUI:ScanRoster()
	local roster = {}

	local numRaid = GetNumRaidMembers()
	if numRaid > 0 then
		for i = 1, numRaid do
			local unit = "raid" .. i
			if UnitExists(unit) then
				local _, class = UnitClass(unit)
				-- 3rd return of GetRaidRosterInfo is subgroup (1-8) - same
				-- index i as "raidN" above, so no name-matching needed.
				local _, _, subgroup = GetRaidRosterInfo(i)
				table.insert(roster, { name = UnitName(unit), class = class, role = ResolveUnitRole(unit, class), unit = unit, subgroup = subgroup })
			end
		end
	else
		local units = { "player" }
		local numParty = GetNumPartyMembers()
		for i = 1, numParty do
			table.insert(units, "party" .. i)
		end
		for _, unit in ipairs(units) do
			if UnitExists(unit) then
				local _, class = UnitClass(unit)
				table.insert(roster, { name = UnitName(unit), class = class, role = ResolveUnitRole(unit, class), unit = unit })
			end
		end
	end

	return roster
end

----------------------------------------------------------------------------
-- Matching - class-specific slots are matched before generic ones (in each
-- group, original template order), so a pinned slot like a class-specific
-- DPS slot reserves that raid member before an earlier generic "Any DPS"
-- slot can grab them. A slot with no role set (Class Run - see Data.lua's
-- BuildClassRunTemplate) matches on class alone, any role. Rendering
-- afterward always walks the template in its original authored order, so
-- slot positions stay stable regardless of who filled what.
----------------------------------------------------------------------------
function RaidCompUI:BuildMatches(templateKey, roster)
	local template = RaidCompUI.TEMPLATES[templateKey]
	local matches = {}
	local claimed = {}
	-- Slots a manual swap has already pinned this refresh - excluded from
	-- both the specific and generic auto-fill passes below so a swap sticks
	-- instead of being instantly recomputed away.
	local handled = {}

	local overrides = JohnnysRaidComp.db.profile.raidCompManualAssignments[templateKey]
	if overrides then
		for i, slot in ipairs(template.slots) do
			local override = overrides[i]
			if override == false then
				handled[slot] = true
			elseif override then
				for _, member in ipairs(roster) do
					if not claimed[member] and member.name == override then
						claimed[member] = true
						matches[slot] = override
						handled[slot] = true
						break
					end
				end
				-- else: the pinned player has left the raid - leave the slot
				-- unhandled so it falls through to auto-fill this refresh;
				-- the override itself stays saved in case they rejoin.
			end
		end
	end

	local specific, generic = {}, {}
	for _, slot in ipairs(template.slots) do
		if not handled[slot] then
			if slot.class then
				table.insert(specific, slot)
			else
				table.insert(generic, slot)
			end
		end
	end

	local function TryFill(slot)
		for _, member in ipairs(roster) do
			if not claimed[member] and (not slot.role or member.role == slot.role) and (not slot.class or member.class == slot.class) then
				claimed[member] = true
				matches[slot] = member.name
				return
			end
		end
	end

	for _, slot in ipairs(specific) do
		TryFill(slot)
	end
	for _, slot in ipairs(generic) do
		TryFill(slot)
	end

	-- Counted by the role of the slot each player actually landed in, not
	-- their raw detected role - so a manual swap that puts a DPS in a Tank
	-- slot credits Tanks, not DPS. Anyone left unclaimed (roster deeper than
	-- the template needs) still counts under their own raw role, so bringing
	-- an extra healer beyond what's needed still shows as surplus healers
	-- rather than silently vanishing from the header. Those same unclaimed
	-- members are also returned as `overflow` - the bench list (see UI.lua's
	-- RefreshComp/EnsureBenchChip) - so nobody who didn't fit the template
	-- just disappears; they're shown and can still be clicked into a slot.
	local have = { TANK = 0, HEALER = 0, DAMAGER = 0 }
	local overflow = {}
	for _, slot in ipairs(template.slots) do
		if matches[slot] and slot.role then
			have[slot.role] = have[slot.role] + 1
		end
	end
	for _, member in ipairs(roster) do
		if not claimed[member] then
			have[member.role] = have[member.role] + 1
			table.insert(overflow, member)
		end
	end

	return matches, have, overflow
end

----------------------------------------------------------------------------
-- Manual placement - clicking a slot or a bench chip selects it (gold
-- border); clicking a second one acts on the pair: slot+slot swaps their
-- occupants, slot+bench drops the benched player into that slot (whoever
-- was there, if anyone, simply becomes unclaimed and reappears on the bench
-- next refresh - see BuildMatches), bench+bench just moves the selection to
-- the newly-clicked name (there's nothing to place between two unslotted
-- players). Either half pins a manual override (BuildMatches's `overrides`)
-- so the placement survives the next roster-driven refresh. Right-click a
-- slot clears its own override and lets it fall back to auto-fill.
----------------------------------------------------------------------------
local EnsureSlotCard, SetCardState, SetHeaderCount
local EnsureBenchChip, SetBenchChipState
local GetOverrides, CurrentTemplateKey
local SwapSlots, AssignBenchToSlot, HandlePick, OnCardClick, OnBenchClick
local FormatNameWithClass, OnToggleTank, OnToggleHealer
local FormatGearScoreText, FormatCompactGearScoreText, ShowGearScoreTooltip
-- Defined in the achievement lookup section at the bottom of this file.
local AddAchievementLines, AchClearPending

-- Colors a matched member's whole name by class (e.g. "|cff...Bob|r") - used
-- by both SetCardState and SetBenchChipState so slot cards and bench chips
-- read the same way. class can be nil (ScanRoster always sets it, but stay
-- defensive), in which case the name is shown plain. The embedded color code
-- overrides whatever the FontString's own SetTextColor was set to for the
-- span it wraps, so this works regardless of the card/chip's base text color.
function FormatNameWithClass(name, class)
	local color = class and RAID_CLASS_COLORS[class]
	if not color then
		return name
	end
	return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
end

-- GearScore text + color for a slot card, from the GearScore lookup cache
-- (see the lookup section further down this file). Gray "GS --" until a
-- lookup succeeds.
function FormatGearScoreText(name)
	local entry = JohnnysRaidComp.db.global.raidCompGearScores[name]
	if not entry or not entry.score then
		return "GS --", 0.5, 0.5, 0.5
	end
	local r, g, b = JohnnysRaidComp.GearScore:GetQuality(entry.score)
	return "GS " .. entry.score, r, g, b
end

-- Same, but abbreviated (e.g. "5.8k") for the much narrower bench chips.
function FormatCompactGearScoreText(name)
	local entry = JohnnysRaidComp.db.global.raidCompGearScores[name]
	if not entry or not entry.score then
		return "--", 0.5, 0.5, 0.5
	end
	local r, g, b = JohnnysRaidComp.GearScore:GetQuality(entry.score)
	if entry.score >= 1000 then
		return string.format("%.1fk", entry.score / 1000), r, g, b
	end
	return tostring(entry.score), r, g, b
end

-- Shared GearScore/PVP-gear/blacklist/achievement tooltip for both slot cards
-- and bench chips. Every exit path runs AddAchievementLines before Show.
function ShowGearScoreTooltip(owner, name)
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	GameTooltip:SetText(name)

	local blacklistEntry = JohnnysBlackList and JohnnysBlackList.BlackListUI and JohnnysBlackList.BlackListUI:GetEntryByName(name)
	if blacklistEntry then
		local reason = blacklistEntry.history and blacklistEntry.history[1] and blacklistEntry.history[1].reason
		GameTooltip:AddLine("BLACKLISTED" .. (reason and (": " .. reason) or ""), 1, 0.15, 0.15)
	end

	local entry = JohnnysRaidComp.db.global.raidCompGearScores[name]
	if not entry or not entry.score then
		GameTooltip:AddLine("GearScore: not yet inspected", 0.6, 0.6, 0.6)
		AddAchievementLines(name)
		GameTooltip:Show()
		return
	end

	GameTooltip:AddLine(string.format("GearScore: %d (avg ilvl %d)", entry.score, entry.avgIlvl or 0), 1, 1, 1)

	if entry.hasPvpGear then
		local slotNames = {}
		for slotName in pairs(entry.pvpSlots or {}) do
			table.insert(slotNames, slotName)
		end
		table.sort(slotNames)
		GameTooltip:AddLine("PVP gear: " .. table.concat(slotNames, ", "), 0.85, 0.3, 0.85)
	else
		GameTooltip:AddLine("No PVP gear detected", 0.6, 0.6, 0.6)
	end

	if entry.updatedAt then
		GameTooltip:AddLine(string.format("Updated %ds ago", math.floor(GetTime() - entry.updatedAt)), 0.5, 0.5, 0.5)
	end

	AddAchievementLines(name)
	GameTooltip:Show()
end

-- Sets (or clears) the Class Run tank marker for the toggled card's class -
-- see EnsureSlotCard's card.tankToggle. Only one class can be marked per
-- raid's Class Run at a time, so checking one clears any previous pick.
function OnToggleTank(slot, checked)
	local templateKey = CurrentTemplateKey()
	if not templateKey or not slot or not slot.class then
		return
	end
	local all = JohnnysRaidComp.db.profile.raidCompClassRunTank
	if checked then
		all[templateKey] = slot.class
	elseif all[templateKey] == slot.class then
		all[templateKey] = nil
	end
	RaidCompUI:RefreshComp()
end

-- Same as OnToggleTank, but healers are a set rather than a single value -
-- more than one class can be checked at once (see CLASS_RUN_HEALER_CAPABLE).
function OnToggleHealer(slot, checked)
	local templateKey = CurrentTemplateKey()
	if not templateKey or not slot or not slot.class then
		return
	end
	local all = JohnnysRaidComp.db.profile.raidCompClassRunHealers
	local set = all[templateKey]
	if checked then
		if not set then
			set = {}
			all[templateKey] = set
		end
		set[slot.class] = true
	elseif set then
		set[slot.class] = nil
	end
	RaidCompUI:RefreshComp()
end

function GetOverrides(templateKey)
	local all = JohnnysRaidComp.db.profile.raidCompManualAssignments
	local overrides = all[templateKey]
	if not overrides then
		overrides = {}
		all[templateKey] = overrides
	end
	return overrides
end

function CurrentTemplateKey()
	if not currentRaid or not currentSize then
		return nil
	end
	return currentRaid .. "_" .. currentSize
end

local function ClearSelection()
	selection = nil
end

function SwapSlots(templateKey, indexA, indexB)
	local template = RaidCompUI.TEMPLATES[templateKey]
	local overrides = GetOverrides(templateKey)
	local nameA = currentMatches[template.slots[indexA]]
	local nameB = currentMatches[template.slots[indexB]]
	overrides[indexA] = nameB or false
	overrides[indexB] = nameA or false
end

function AssignBenchToSlot(templateKey, slotIndex, benchName)
	local overrides = GetOverrides(templateKey)
	overrides[slotIndex] = benchName
end

-- kind is "slot" (value = slot index) or "bench" (value = player name).
function HandlePick(kind, value)
	local templateKey = CurrentTemplateKey()
	if not templateKey then
		selection = nil
		return
	end

	if not selection then
		selection = { kind = kind, value = value }
		return
	end

	if selection.kind == kind and selection.value == value then
		selection = nil
		return
	end

	if selection.kind == "bench" and kind == "bench" then
		selection = { kind = kind, value = value }
		return
	end

	if selection.kind == "slot" and kind == "slot" then
		SwapSlots(templateKey, selection.value, value)
	else
		local slotIndex = (kind == "slot") and value or selection.value
		local benchName = (kind == "bench") and value or selection.value
		AssignBenchToSlot(templateKey, slotIndex, benchName)
	end

	selection = nil
end

function OnCardClick(index, mouseButton)
	local templateKey = CurrentTemplateKey()
	if not templateKey then
		return
	end

	-- Ctrl+click any box (either mouse button) force-re-scans that member's
	-- GearScore - see RaidCompUI:ForceRescanGearScore. Returns early so it
	-- never also triggers a swap or clears an override.
	local matchedName = slotCards[index] and slotCards[index].matchedName
	if IsControlKeyDown() then
		if matchedName then
			RaidCompUI:ForceRescanGearScore(matchedName)
		end
		return
	end
	-- Any normal click on a box acknowledges its pending GS-change pulse.
	if matchedName then
		gsChanged[matchedName] = nil
	end

	if mouseButton == "RightButton" then
		local overrides = JohnnysRaidComp.db.profile.raidCompManualAssignments[templateKey]
		if overrides then
			overrides[index] = nil
		end
		selection = nil
	else
		HandlePick("slot", index)
	end

	RaidCompUI:RefreshComp()
end

function OnBenchClick(name)
	-- Ctrl+click force-re-scans this member's GearScore instead of
	-- selecting/placing them (see OnCardClick / RaidCompUI:ForceRescanGearScore).
	if IsControlKeyDown() then
		RaidCompUI:ForceRescanGearScore(name)
		return
	end
	gsChanged[name] = nil
	HandlePick("bench", name)
	RaidCompUI:RefreshComp()
end

----------------------------------------------------------------------------
-- Slot card pool - lazily created, repositioned/hidden per refresh, same
-- pattern as the pooled rows in Modules\BlackListUI\UI.lua.
----------------------------------------------------------------------------
function EnsureSlotCard(index)
	local card = slotCards[index]
	if card then
		return card
	end

	card = CreateFrame("Frame", nil, compPage)
	card:SetSize(CARD_WIDTH, CARD_HEIGHT)
	card:SetBackdrop({ bgFile = Skin.WHITE, edgeFile = Skin.WHITE, edgeSize = 1 })

	-- Amber "GearScore just changed" pulse (see gsFlashPump in the GearScore
	-- section). ARTWORK sits above the backdrop background but below the OVERLAY
	-- font strings, so the name/GS text stays readable and this stacks on top of
	-- whatever border state (matched/blacklist/selected) the card is showing.
	card.flashTex = card:CreateTexture(nil, "ARTWORK")
	card.flashTex:SetAllPoints()
	card.flashTex:SetTexture(Skin.WHITE)
	card.flashTex:SetVertexColor(1, 0.82, 0)
	card.flashTex:Hide()

	card.label = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.label:SetPoint("TOP", 0, -6)
	card.label:SetWidth(CARD_WIDTH - 8)
	card.label:SetJustifyH("CENTER")

	card.nameText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.nameText:SetPoint("TOP", card.label, "BOTTOM", 0, -2)
	card.nameText:SetWidth(CARD_WIDTH - 8)
	card.nameText:SetJustifyH("CENTER")

	-- GearScore (see the lookup section further down this file) - blank/"GS --" until a
	-- lookup succeeds.
	card.gsText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.gsText:SetPoint("BOTTOM", 0, 5)
	card.gsText:SetWidth(CARD_WIDTH - 8)
	card.gsText:SetJustifyH("CENTER")

	-- PVP-gear badge (resilience detected on at least one equipped item) -
	-- opposite corner from the tank/healer toggles below, shown only when the
	-- matched member actually has PVP gear on (see SetCardState).
	card.pvpBadge = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.pvpBadge:SetPoint("TOPLEFT", 4, -4)
	card.pvpBadge:SetText("PvP")
	card.pvpBadge:SetTextColor(0.85, 0.3, 0.85)
	card.pvpBadge:Hide()

	card:EnableMouse(true)
	card:SetScript("OnMouseUp", function(self, mouseButton)
		OnCardClick(index, mouseButton)
	end)
	card:SetScript("OnEnter", function(self)
		if card.matchedName then
			-- Hovering a box acknowledges its pending GS-change pulse.
			gsChanged[card.matchedName] = nil
			card.flashTex:Hide()
			pcall(ShowGearScoreTooltip, self, card.matchedName)
		end
	end)
	card:SetScript("OnLeave", GameTooltip_Hide)

	-- Class Run only (see SetCardState) - manual "this person is tanking" /
	-- "this person is healing" markers. Class Run has no role data at all
	-- otherwise (slots match on class alone), so these are purely
	-- informational flags the raid leader sets by hand (see Data.lua's
	-- CLASS_RUN_TANK_CAPABLE/CLASS_RUN_HEALER_CAPABLE). Tank is exclusive
	-- (OnToggleTank clears any previous pick); healer is a set, since a Class
	-- Run usually wants 2+ healers (OnToggleHealer). Distinct border tints so
	-- the two checkboxes stay tellable apart at a glance, not just on hover.
	card.tankToggle = Skin:CreateCheckbox(card, 16, false, function(checked)
		OnToggleTank(card.slot, checked)
	end)
	card.tankToggle:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -2)
	card.tankToggle:SetBackdropBorderColor(0.85, 0.65, 0.2, 1)
	card.tankToggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Mark as Tank")
		GameTooltip:Show()
	end)
	card.tankToggle:SetScript("OnLeave", GameTooltip_Hide)
	card.tankToggle:Hide()

	card.healerToggle = Skin:CreateCheckbox(card, 16, false, function(checked)
		OnToggleHealer(card.slot, checked)
	end)
	card.healerToggle:SetPoint("RIGHT", card.tankToggle, "LEFT", -2, 0)
	card.healerToggle:SetBackdropBorderColor(0.3, 0.6, 0.9, 1)
	card.healerToggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Mark as Healer")
		GameTooltip:Show()
	end)
	card.healerToggle:SetScript("OnLeave", GameTooltip_Hide)
	card.healerToggle:Hide()

	slotCards[index] = card
	return card
end

function SetCardState(card, slot, matchedName, matchedClass, isClassRun)
	card.slot = slot
	card.matchedName = matchedName
	card.label:SetText(slot.label)

	if matchedName then
		card:SetBackdropColor(0.10, 0.10, 0.10, 0.95)
		card:SetBackdropBorderColor(0.3, 0.9, 0.3, 1)
		card.label:SetTextColor(1, 1, 1)
		card.nameText:SetTextColor(0.3, 1, 0.3)
		card.nameText:SetText(FormatNameWithClass(matchedName, matchedClass))

		-- pcall'd for the same reason as RefreshComp's RequestGearScore loop -
		-- this reads the GearScore cache and must never be able to
		-- break the card itself if something about that goes wrong.
		local ok = pcall(function()
			local gsText, r, g, b = FormatGearScoreText(matchedName)
			card.gsText:SetText(gsText)
			card.gsText:SetTextColor(r, g, b)
			card.gsText:Show()

			-- SetShown doesn't exist on this client - only Show()/Hide() do.
			local entry = JohnnysRaidComp.db.global.raidCompGearScores[matchedName]
			if entry and entry.hasPvpGear then
				card.pvpBadge:Show()
			else
				card.pvpBadge:Hide()
			end
		end)
		if not ok then
			card.gsText:Hide()
			card.pvpBadge:Hide()
		end

		card.blacklistEntry = JohnnysBlackList and JohnnysBlackList.BlackListUI and JohnnysBlackList.BlackListUI:GetEntryByName(matchedName)
		if card.blacklistEntry then
			card:SetBackdropBorderColor(0.9, 0.15, 0.15, 1)
		end
	else
		card:SetBackdropColor(0.08, 0.08, 0.08, 0.4)
		card:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.4)
		card.label:SetTextColor(0.5, 0.5, 0.5)
		card.nameText:SetTextColor(0.4, 0.4, 0.4)
		card.nameText:SetText("-- empty --")
		card.gsText:Hide()
		card.pvpBadge:Hide()
		card.blacklistEntry = nil
	end

	-- Tank toggle only makes sense on a filled Class Run slot for a class
	-- that actually has a tank spec (see CLASS_RUN_TANK_CAPABLE) - regular
	-- raid+size slots already track TANK/HEALER/DAMAGER via the real role
	-- icon, so the manual marker would be redundant there.
	if isClassRun and matchedName and RaidCompUI.CLASS_RUN_TANK_CAPABLE[slot.class] then
		local templateKey = CurrentTemplateKey()
		card.tankToggle:SetChecked(templateKey and JohnnysRaidComp.db.profile.raidCompClassRunTank[templateKey] == slot.class)
		card.tankToggle:Show()
	else
		card.tankToggle:Hide()
	end

	if isClassRun and matchedName and RaidCompUI.CLASS_RUN_HEALER_CAPABLE[slot.class] then
		local templateKey = CurrentTemplateKey()
		local healerSet = templateKey and JohnnysRaidComp.db.profile.raidCompClassRunHealers[templateKey]
		card.healerToggle:SetChecked(healerSet and healerSet[slot.class])
		card.healerToggle:Show()
	else
		card.healerToggle:Hide()
	end

	if selection and selection.kind == "slot" and slotCards[selection.value] == card then
		card:SetBackdropBorderColor(1, 0.82, 0, 1)
	end
end

----------------------------------------------------------------------------
-- Bench chip pool - one per unplaced roster member, same lazily-created/
-- pooled pattern as the slot cards above. Left-click selects/places (see
-- HandlePick); there's no right-click action since a bench entry has no
-- override of its own to clear.
----------------------------------------------------------------------------
function EnsureBenchChip(index)
	local chip = benchChips[index]
	if chip then
		return chip
	end

	chip = CreateFrame("Frame", nil, compPage)
	chip:SetSize(BENCH_CHIP_WIDTH, BENCH_CHIP_HEIGHT)
	chip:SetBackdrop({ bgFile = Skin.WHITE, edgeFile = Skin.WHITE, edgeSize = 1 })

	-- "GearScore just changed" pulse - same as the slot cards' flashTex above.
	chip.flashTex = chip:CreateTexture(nil, "ARTWORK")
	chip.flashTex:SetAllPoints()
	chip.flashTex:SetTexture(Skin.WHITE)
	chip.flashTex:SetVertexColor(1, 0.82, 0)
	chip.flashTex:Hide()

	chip.nameText = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	chip.nameText:SetPoint("TOP", 0, -3)
	chip.nameText:SetWidth(BENCH_CHIP_WIDTH - 6)
	chip.nameText:SetJustifyH("CENTER")

	-- Compact GearScore (see the lookup section further down this file) - "--" until a lookup
	-- succeeds.
	chip.gsText = chip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	chip.gsText:SetPoint("BOTTOM", 0, 3)
	chip.gsText:SetWidth(BENCH_CHIP_WIDTH - 6)
	chip.gsText:SetJustifyH("CENTER")

	chip:EnableMouse(true)
	chip:SetScript("OnMouseUp", function(self, mouseButton)
		if mouseButton == "LeftButton" and chip.name then
			OnBenchClick(chip.name)
		end
	end)
	chip:SetScript("OnEnter", function(self)
		if chip.name then
			gsChanged[chip.name] = nil
			chip.flashTex:Hide()
			pcall(ShowGearScoreTooltip, self, chip.name)
		end
	end)
	chip:SetScript("OnLeave", GameTooltip_Hide)

	benchChips[index] = chip
	return chip
end

function SetBenchChipState(chip, name, class)
	chip.name = name
	chip.nameText:SetText(FormatNameWithClass(name, class))
	chip:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
	chip:SetBackdropBorderColor(0.5, 0.5, 0.2, 0.8)
	chip.nameText:SetTextColor(1, 0.9, 0.6)

	-- pcall'd for the same reason as SetCardState's GS lookup - must never be
	-- able to break the chip itself if something about that goes wrong.
	local ok = pcall(function()
		local gsText, r, g, b = FormatCompactGearScoreText(name)
		local entry = JohnnysRaidComp.db.global.raidCompGearScores[name]
		if entry and entry.hasPvpGear then
			chip.gsText:SetText("PvP " .. gsText)
			chip.gsText:SetTextColor(0.85, 0.3, 0.85)
		else
			chip.gsText:SetText(gsText)
			chip.gsText:SetTextColor(r, g, b)
		end
	end)
	if not ok then
		chip.gsText:SetText("")
	end

	chip.blacklistEntry = JohnnysBlackList and JohnnysBlackList.BlackListUI and JohnnysBlackList.BlackListUI:GetEntryByName(name)
	if chip.blacklistEntry then
		chip:SetBackdropBorderColor(0.9, 0.15, 0.15, 1)
	end

	if selection and selection.kind == "bench" and selection.value == name then
		chip:SetBackdropBorderColor(1, 0.82, 0, 1)
	end
end

----------------------------------------------------------------------------
-- "Report uninspected to VH" - roster members with no cached GearScore yet
-- (typically people out of inspect range, since RequestGearScore needs
-- CanInspect + range) get pinged in chat to come to Violet Hold so their
-- gear can be inspected. Sent as a raid warning when we're leader/assist,
-- else plain raid/party chat.
----------------------------------------------------------------------------
local VH_PREFIX = "Not yet inspected - please come to Violet Hold (VH) for a gear check: "

function RaidCompUI:GetUninspectedNames()
	local cache = JohnnysRaidComp.db.global.raidCompGearScores
	local names = {}
	for _, member in ipairs(self:ScanRoster()) do
		local entry = cache[member.name]
		if (not entry or not entry.score) and not UnitIsUnit(member.unit, "player") then
			table.insert(names, member.name)
		end
	end
	return names
end

function RaidCompUI:AnnounceUninspected()
	local names = self:GetUninspectedNames()
	if #names == 0 then
		if reportVHStatus then
			reportVHStatus:SetText("Everyone's been inspected.")
		end
		return
	end

	local inRaid = GetNumRaidMembers() > 0
	local channel = inRaid and "RAID" or "PARTY"
	if inRaid and (IsRaidLeader() or IsRaidOfficer()) then
		channel = "RAID_WARNING"
	end

	-- Chat lines cap at 255 chars - chunk the name list across messages.
	local line = VH_PREFIX
	for _, name in ipairs(names) do
		local sep = (line == VH_PREFIX) and "" or ", "
		if #line + #sep + #name > 250 then
			SendChatMessage(line, channel)
			line = VH_PREFIX .. name
		else
			line = line .. sep .. name
		end
	end
	if line ~= VH_PREFIX then
		SendChatMessage(line, channel)
	end

	if reportVHStatus then
		reportVHStatus:SetText(string.format("Pinged %d via %s.", #names, channel))
	end
end

function SetHeaderCount(fs, label, have, needed)
	fs:SetText(string.format("%s: %d/%d", label, have, needed))
	if have >= needed then
		fs:SetTextColor(0.3, 1, 0.3)
	else
		fs:SetTextColor(1, 0.4, 0.4)
	end
end

-- Resize to `height` (clamped) without moving the window - SetHeight keeps
-- the frame's anchor point, so a CENTER-anchored window just grows/shrinks
-- evenly about its middle. Every page calls this so none of them leaves a
-- screenful of empty panel below its content.
local function SetFrameHeight(height)
	if not mainFrame then
		return
	end
	mainFrame:SetHeight(math.max(MIN_FRAME_HEIGHT, math.floor(height + 0.5)))
end

----------------------------------------------------------------------------
-- Refresh - rescans the roster, recomputes matches, and repaints the header
-- counts + every slot card for the currently selected raid+size.
----------------------------------------------------------------------------
function RaidCompUI:RefreshComp()
	if not currentRaid or not currentSize then
		return
	end

	local templateKey = currentRaid .. "_" .. currentSize
	local template = RaidCompUI.TEMPLATES[templateKey]
	local roster = self:ScanRoster()
	local matches, have, overflow = self:BuildMatches(templateKey, roster)
	currentMatches = matches

	-- Kick off/refresh a GearScore+PVP-gear lookup for everyone currently
	-- shown (slotted or benched) - see the lookup section further down this
	-- file. No-ops
	-- for anyone already fresh or already queued. pcall'd as a hard boundary -
	-- inspect/item-cache reads can fail in odd ways, and they must never be
	-- able to take the actual comp grid down with it.
	local ok, err = pcall(function()
		for _, member in ipairs(roster) do
			self:RequestGearScore(member.name, member.unit)
			-- Separate queue (see the achievement lookup section) - no-ops if
			-- the tooltip option is off.
			self:RequestAchievements(member.name, member.unit)
		end
	end)
	if not ok then
		geterrorhandler()(err)
	end

	-- matches only records the matched player's name (see BuildMatches) - this
	-- looks their class back up for the "name (Class)" display in SetCardState.
	local classByName = {}
	for _, member in ipairs(roster) do
		classByName[member.name] = member.class
	end

	if template.isClassRun then
		headerText.tank:Hide()
		headerText.healer:Hide()
		headerText.dps:Hide()
		for _, control in pairs(countControls) do
			control:Hide()
		end

		local filled = 0
		for _, slot in ipairs(template.slots) do
			if matches[slot] then
				filled = filled + 1
			end
		end
		headerText.classRun:SetText(string.format("Classes represented: %d/%d", filled, #template.slots))
		if filled >= #template.slots then
			headerText.classRun:SetTextColor(0.3, 1, 0.3)
		else
			headerText.classRun:SetTextColor(1, 0.4, 0.4)
		end
		headerText.classRun:Show()
	else
		headerText.classRun:Hide()
		headerText.tank:Show()
		headerText.healer:Show()
		headerText.dps:Show()
		for _, control in pairs(countControls) do
			control:Show()
		end

		SetHeaderCount(headerText.tank, "Tanks", have.TANK, template.needed.TANK)
		SetHeaderCount(headerText.healer, "Healers", have.HEALER, template.needed.HEALER)
		SetHeaderCount(headerText.dps, "DPS", have.DAMAGER, template.needed.DAMAGER)
	end

	for i, slot in ipairs(template.slots) do
		local card = EnsureSlotCard(i)
		local col = (i - 1) % COLUMNS
		local row = math.floor((i - 1) / COLUMNS)
		card:ClearAllPoints()
		card:SetPoint("TOPLEFT", compPage, "TOPLEFT", col * (CARD_WIDTH + CARD_GAP), GRID_TOP - row * (CARD_HEIGHT + CARD_GAP))
		local matchedName = matches[slot]
		SetCardState(card, slot, matchedName, matchedName and classByName[matchedName], template.isClassRun)
		card:Show()
	end

	for i = #template.slots + 1, #slotCards do
		slotCards[i]:Hide()
	end

	-- Bench - anyone BuildMatches couldn't place, rendered below the grid
	-- (positioned from the grid's actual row count so it never overlaps,
	-- regardless of a 10-man's 2 rows vs a 25-man's 5).
	local rows = math.ceil(#template.slots / COLUMNS)
	local benchTop = GRID_TOP - rows * (CARD_HEIGHT + CARD_GAP) - 20

	if #overflow > 0 then
		benchLabel:ClearAllPoints()
		benchLabel:SetPoint("TOPLEFT", compPage, "TOPLEFT", 0, benchTop)
		benchLabel:SetText(string.format("Bench (%d unassigned - click a name, then click a slot to place them):", #overflow))
		benchLabel:Show()
	else
		benchLabel:Hide()
	end

	for i, member in ipairs(overflow) do
		local chip = EnsureBenchChip(i)
		local col = (i - 1) % BENCH_COLUMNS
		local row = math.floor((i - 1) / BENCH_COLUMNS)
		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", compPage, "TOPLEFT", col * (BENCH_CHIP_WIDTH + BENCH_GAP), benchTop - 18 - row * (BENCH_CHIP_HEIGHT + BENCH_GAP))
		SetBenchChipState(chip, member.name, member.class)
		chip:Show()
	end

	for i = #overflow + 1, #benchChips do
		benchChips[i]:Hide()
	end

	-- Shrink the window to just what the grid (and bench, if any) needs, so a
	-- 2-row 10-man doesn't sit in a 5-row-tall panel. `rows`/#overflow are the
	-- same values the bench layout above just used.
	local contentBelowGridTop = rows * (CARD_HEIGHT + CARD_GAP)
	if #overflow > 0 then
		local benchRows = math.ceil(#overflow / BENCH_COLUMNS)
		contentBelowGridTop = contentBelowGridTop + 20 + 18
			+ benchRows * BENCH_CHIP_HEIGHT + (benchRows - 1) * BENCH_GAP
	end
	SetFrameHeight(COMP_CHROME_TOP + contentBelowGridTop + COMP_CHROME_BOTTOM)
end

----------------------------------------------------------------------------
-- Role-count editing - Tanks/Healers each get a +/- pair; DPS is always
-- "whatever's left" so it has no button of its own. Adjusting either one
-- keeps the total locked to the raid+size's real player cap by taking the
-- difference out of (or giving it back to) DPS. Saved per raid+size so it
-- survives /reload; changing the shape of the grid invalidates any pending
-- manual swaps for that template (see UI.lua's SwapSlots), since a slot index
-- may now mean something different.
----------------------------------------------------------------------------
local function RebuildCurrentTemplate(templateKey, counts)
	-- `counts` is already saved (or cleared back to default) by the caller,
	-- which is exactly what RebuildTemplate reads.
	RaidCompUI:RebuildTemplate(currentRaid, currentSize)
	JohnnysRaidComp.db.profile.raidCompManualAssignments[templateKey] = nil
	ClearSelection()
	RaidCompUI:RefreshComp()
end

local function AdjustCount(role, delta)
	if not currentRaid or not currentSize or currentSize == "CLASSRUN" then
		return
	end

	local templateKey = currentRaid .. "_" .. currentSize
	local all = JohnnysRaidComp.db.profile.raidCompRoleCounts
	local counts = all[templateKey]
	if not counts then
		local default = RaidCompUI:GetDefaultCounts(currentRaid, currentSize)
		counts = { TANK = default.TANK, HEALER = default.HEALER, DAMAGER = default.DAMAGER }
		all[templateKey] = counts
	end

	local newRoleCount = counts[role] + delta
	local newDps = counts.DAMAGER - delta
	if newRoleCount < 0 or newDps < 0 then
		return
	end

	counts[role] = newRoleCount
	counts.DAMAGER = newDps
	RebuildCurrentTemplate(templateKey, counts)
end

local function ResetCounts()
	if not currentRaid or not currentSize or currentSize == "CLASSRUN" then
		return
	end

	local templateKey = currentRaid .. "_" .. currentSize
	JohnnysRaidComp.db.profile.raidCompRoleCounts[templateKey] = nil
	RebuildCurrentTemplate(templateKey, RaidCompUI:GetDefaultCounts(currentRaid, currentSize))
end

-- Rebuilds a raid+size's template from its saved custom count (if any) and
-- the Class slots setting - SavedVariables aren't loaded yet when Data.lua
-- builds the default RaidCompUI.TEMPLATES at file-load time, so this is where
-- both actually take effect. Public so the Raid Spammer's {need} sees the same
-- slots without the comp window having been opened.
function RaidCompUI:RebuildTemplate(raidKey, sizeKey)
	if sizeKey == "CLASSRUN" then
		return
	end
	local templateKey = raidKey .. "_" .. sizeKey
	local counts = JohnnysRaidComp.db.profile.raidCompRoleCounts[templateKey]
		or RaidCompUI:GetDefaultCounts(raidKey, sizeKey)
	local template = RaidCompUI:BuildTemplate(raidKey, sizeKey, counts)
	template.fromSaved = true
	RaidCompUI.TEMPLATES[templateKey] = template
end

-- Class slots on/off (raidCompClassPins) - global, so every raid+size picks
-- it up on its next RebuildTemplate. Only the open template is rebuilt now.
-- Pinned slots sit before the "Any" slots of their role, so slot indices keep
-- their meaning and manual swaps are left alone.
local function ToggleClassPins()
	local profile = JohnnysRaidComp.db.profile
	profile.raidCompClassPins = not profile.raidCompClassPins
	countControls.classPins.text:SetText(profile.raidCompClassPins and "Class slots: On" or "Class slots: Off")
	if currentRaid and currentSize and currentSize ~= "CLASSRUN" then
		RaidCompUI:RebuildTemplate(currentRaid, currentSize)
		ClearSelection()
		RaidCompUI:RefreshComp()
	end
end

----------------------------------------------------------------------------
-- Page switching
----------------------------------------------------------------------------
local function HideAllPages()
	raidListPage:Hide()
	sizeListPage:Hide()
	compPage:Hide()
end

local function ShowRaidList()
	currentRaid, currentSize = nil, nil
	HideAllPages()
	raidListPage:Show()
	-- Raid-button grid under the page's -76 top inset, then a bottom margin.
	local raidRows = math.ceil(#RaidCompUI.RAID_ORDER / RAID_COLS)
	SetFrameHeight(76 + 20 + raidRows * (RAID_BUTTON_HEIGHT + RAID_GAP) + 16)
	mainFrame.title:SetText("Raid Comp - Select a Raid")
end

local function ShowSizeList(raidKey)
	currentRaid = raidKey
	currentSize = nil

	for _, btn in ipairs(sizeListButtons) do
		btn:Hide()
	end
	local sizes = RaidCompUI.RAID_SIZE_ORDER[raidKey]
	local totalWidth = #sizes * SIZE_BUTTON_WIDTH + (#sizes - 1) * SIZE_GAP
	local startX = (FRAME_WIDTH - 32 - totalWidth) / 2
	for i, sizeKey in ipairs(sizes) do
		local btn = sizeListButtons[i]
		if not btn then
			btn = Skin:CreateButton(sizeListPage, SIZE_BUTTON_WIDTH, SIZE_BUTTON_HEIGHT, "")
			sizeListButtons[i] = btn
		end
		btn.text:SetText(RaidCompUI.SIZE_LABELS[sizeKey])
		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", sizeListPage, "TOPLEFT", startX + (i - 1) * (SIZE_BUTTON_WIDTH + SIZE_GAP), -60)
		btn:SetScript("OnClick", function() RaidCompUI:ShowComp(raidKey, sizeKey) end)
		btn:Show()
	end

	if RaidCompUI.CLASS_RUN_RAIDS[raidKey] then
		classRunEntryButton:ClearAllPoints()
		classRunEntryButton:SetPoint("TOP", sizeListPage, "TOP", 0, -110)
		classRunEntryButton:Show()
		classRunEntryButton:SetScript("OnClick", function() RaidCompUI:ShowClassRunComp(raidKey) end)
	else
		classRunEntryButton:Hide()
	end

	HideAllPages()
	sizeListPage:Show()
	-- Size buttons at -60, plus the Class Run button at -110 when this raid
	-- has one; page top inset is -44.
	local sizeContent = RaidCompUI.CLASS_RUN_RAIDS[raidKey] and 136 or 88
	SetFrameHeight(44 + sizeContent + 16)
	mainFrame.title:SetText(RaidCompUI.RAID_LABELS[raidKey] .. " - Select Size")
end

function RaidCompUI:ShowComp(raidKey, sizeKey)
	currentRaid, currentSize = raidKey, sizeKey
	JohnnysRaidComp.db.profile.raidCompSelectedRaid = raidKey
	JohnnysRaidComp.db.profile.raidCompSelectedSize = sizeKey
	compBackAction = function() ShowSizeList(raidKey) end
	ClearSelection()
	self:RebuildTemplate(raidKey, sizeKey)

	HideAllPages()
	compPage:Show()
	mainFrame.title:SetText(RaidCompUI.RAID_LABELS[raidKey] .. " - " .. RaidCompUI.SIZE_LABELS[sizeKey])
	self:RefreshComp()
end

-- Class Run - one slot per WotLK class (10 total, see Data.lua's
-- BuildClassRunTemplate), only ever 10-man since there are exactly 10
-- classes. Built once and cached under a fixed "<RAID>_CLASSRUN" key so
-- RefreshComp's normal "currentRaid .. '_' .. currentSize" lookup needs no
-- special-casing - it's just another template key.
function RaidCompUI:ShowClassRunComp(raidKey)
	local templateKey = raidKey .. "_CLASSRUN"
	if not RaidCompUI.TEMPLATES[templateKey] then
		RaidCompUI.TEMPLATES[templateKey] = RaidCompUI:BuildClassRunTemplate()
	end

	currentRaid, currentSize = raidKey, "CLASSRUN"
	-- Persisted the same way ShowComp does, so anything reading "what's
	-- currently selected in Raid Comp" (e.g. Modules\RaidSpamUI\Init.lua's
	-- Recruit tab {need} token) sees Class Run too, not just a regular
	-- raid+size pick.
	JohnnysRaidComp.db.profile.raidCompSelectedRaid = raidKey
	JohnnysRaidComp.db.profile.raidCompSelectedSize = "CLASSRUN"
	compBackAction = function() ShowSizeList(raidKey) end
	ClearSelection()

	HideAllPages()
	compPage:Show()
	mainFrame.title:SetText(RaidCompUI.RAID_LABELS[raidKey] .. " - Class Run (one of each class)")
	self:RefreshComp()
end

----------------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------------
local function SavePosition()
	local point, _, relativePoint, x, y = mainFrame:GetPoint()
	local pos = JohnnysRaidComp.db.profile.raidCompPanelPosition
	pos.point, pos.relativePoint, pos.x, pos.y = point, relativePoint, x, y
end

local function BuildRaidListPage()
	raidListPage = CreateFrame("Frame", nil, mainFrame)
	raidListPage:SetPoint("TOPLEFT", 16, -76)
	raidListPage:SetPoint("BOTTOMRIGHT", -16, 16)

	for i, raidKey in ipairs(RaidCompUI.RAID_ORDER) do
		local col = (i - 1) % RAID_COLS
		local row = math.floor((i - 1) / RAID_COLS)
		local btn = Skin:CreateButton(raidListPage, RAID_BUTTON_WIDTH, RAID_BUTTON_HEIGHT, RaidCompUI.RAID_LABELS[raidKey])
		btn:SetPoint("TOPLEFT", col * (RAID_BUTTON_WIDTH + RAID_GAP), -20 - row * (RAID_BUTTON_HEIGHT + RAID_GAP))
		btn:SetScript("OnClick", function() ShowSizeList(raidKey) end)
	end
end

local function BuildSizeListPage()
	sizeListPage = CreateFrame("Frame", nil, mainFrame)
	sizeListPage:SetPoint("TOPLEFT", 16, -44)
	sizeListPage:SetPoint("BOTTOMRIGHT", -16, 16)
	sizeListPage:Hide()

	local back = Skin:CreateButton(sizeListPage, 60, 22, "< Back")
	back:SetPoint("TOPLEFT", 0, 0)
	back:SetScript("OnClick", ShowRaidList)

	classRunEntryButton = Skin:CreateButton(sizeListPage, 200, 26, "Class Run >")
	classRunEntryButton:Hide()
end

local function BuildCompPage()
	compPage = CreateFrame("Frame", nil, mainFrame)
	compPage:SetPoint("TOPLEFT", 16, -44)
	compPage:SetPoint("BOTTOMRIGHT", -16, 16)
	compPage:Hide()

	local back = Skin:CreateButton(compPage, 60, 22, "< Back")
	back:SetPoint("TOPLEFT", 0, 0)
	back:SetScript("OnClick", function()
		if compBackAction then
			compBackAction()
		end
	end)

	headerText.tank = compPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	headerText.tank:SetPoint("TOPLEFT", 90, -4)

	-- Each anchored off the previous element's right edge (rather than fixed
	-- x coordinates) so the Tank/Healer +/- pairs have room without the
	-- columns overlapping regardless of how wide "Tanks: 10/10" ends up.
	countControls.tankMinus = Skin:CreateButton(compPage, 18, 18, "-")
	countControls.tankMinus:SetPoint("LEFT", headerText.tank, "RIGHT", 8, 0)
	countControls.tankMinus:SetScript("OnClick", function() AdjustCount("TANK", -1) end)

	countControls.tankPlus = Skin:CreateButton(compPage, 18, 18, "+")
	countControls.tankPlus:SetPoint("LEFT", countControls.tankMinus, "RIGHT", 2, 0)
	countControls.tankPlus:SetScript("OnClick", function() AdjustCount("TANK", 1) end)

	headerText.healer = compPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	headerText.healer:SetPoint("LEFT", countControls.tankPlus, "RIGHT", 24, 0)

	countControls.healerMinus = Skin:CreateButton(compPage, 18, 18, "-")
	countControls.healerMinus:SetPoint("LEFT", headerText.healer, "RIGHT", 8, 0)
	countControls.healerMinus:SetScript("OnClick", function() AdjustCount("HEALER", -1) end)

	countControls.healerPlus = Skin:CreateButton(compPage, 18, 18, "+")
	countControls.healerPlus:SetPoint("LEFT", countControls.healerMinus, "RIGHT", 2, 0)
	countControls.healerPlus:SetScript("OnClick", function() AdjustCount("HEALER", 1) end)

	-- DPS has no +/- of its own - it's always the remainder after
	-- Tanks/Healers are set (see AdjustCount), so there's nothing to click.
	headerText.dps = compPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	headerText.dps:SetPoint("LEFT", countControls.healerPlus, "RIGHT", 24, 0)

	countControls.reset = Skin:CreateButton(compPage, 60, 20, "Reset")
	countControls.reset:SetPoint("TOPRIGHT", compPage, "TOPRIGHT", 0, -2)
	countControls.reset:SetScript("OnClick", function() ResetCounts() end)

	-- Lives in countControls so Class Run hides it along with the +/- (see
	-- RefreshComp) - a Class Run is nothing but class slots.
	countControls.classPins = Skin:CreateButton(compPage, 110, 20,
		JohnnysRaidComp.db.profile.raidCompClassPins and "Class slots: On" or "Class slots: Off")
	countControls.classPins:SetPoint("RIGHT", countControls.reset, "LEFT", -6, 0)
	countControls.classPins:SetScript("OnClick", ToggleClassPins)

	-- Class Run's single "Classes represented: X/10" line, shown instead of
	-- the tank/healer/dps trio above (see RefreshComp).
	headerText.classRun = compPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	headerText.classRun:SetPoint("TOPLEFT", 90, -4)
	headerText.classRun:Hide()

	local hint = compPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", 90, -22)
	hint:SetText("Click a slot, then click another to swap. Right-click a slot to undo its swap. Ctrl+click a box to re-scan its GearScore.")

	-- Positioned dynamically each refresh (see RefreshComp) since it sits
	-- right below the grid, whose height depends on the template's size.
	benchLabel = compPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	benchLabel:Hide()

	-- Fixed bottom strip - pings roster members not yet GearScore-inspected
	-- (normally those out of inspect range) to report to Violet Hold. See
	-- RaidCompUI:AnnounceUninspected.
	local reportVHBtn = Skin:CreateButton(compPage, 240, 22, "Report uninspected to VH")
	reportVHBtn:SetPoint("BOTTOMLEFT", compPage, "BOTTOMLEFT", 0, 8)
	reportVHBtn:SetScript("OnClick", function() RaidCompUI:AnnounceUninspected() end)

	-- Force a fresh GearScore sweep of the whole roster in place - see
	-- RaidCompUI:RescanAllGearScores. Saves closing/reopening the window, which
	-- only picks up uncached/stale members anyway.
	local rescanAllBtn = Skin:CreateButton(compPage, 130, 22, "Re-scan all GS")
	rescanAllBtn:SetPoint("LEFT", reportVHBtn, "RIGHT", 8, 0)
	rescanAllBtn:SetScript("OnClick", function() RaidCompUI:RescanAllGearScores() end)

	reportVHStatus = compPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	reportVHStatus:SetPoint("LEFT", rescanAllBtn, "RIGHT", 8, 0)
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "JohnnysAddonHubRaidCompFrame", UIParent)
	mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)

	local pos = JohnnysRaidComp.db.profile.raidCompPanelPosition
	mainFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)

	mainFrame:SetFrameStrata("DIALOG")
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
	mainFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)
	Skin:StylePanel(mainFrame, 0.95)
	mainFrame:Hide()

	mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	mainFrame.title:SetPoint("TOP", 0, -16)
	mainFrame.title:SetText("Raid Comp")

	local close = Skin:CreateButton(mainFrame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() RaidCompUI:Toggle() end)

	-- Opens the built-in Raid Spammer panel (Modules\RaidSpamUI\Init.lua), which
	-- reads this window's current raid/size selection for its Recruit ad.
	local lfm = Skin:CreateButton(mainFrame, 44, 20, "LFM")
	lfm:SetPoint("TOPRIGHT", close, "TOPLEFT", -4, 0)
	lfm:SetScript("OnClick", function()
		if JohnnysRaidSpam and JohnnysRaidSpam.RaidSpamUI then
			JohnnysRaidSpam.RaidSpamUI:Toggle()
		end
	end)

	-- Per-window scale/opacity (see Modules\WindowSettings.lua).
	local cfg = Skin:CreateButton(mainFrame, 44, 20, "Cfg")
	cfg:SetPoint("TOPRIGHT", lfm, "TOPLEFT", -4, 0)
	cfg:SetScript("OnClick", function()
		if JohnnysRaidComp.WindowSettings then
			JohnnysRaidComp.WindowSettings:Toggle()
		end
	end)

	if JohnnysRaidComp.WindowSettings then
		JohnnysRaidComp.WindowSettings:Register(mainFrame, "raidcomp", "Raid Comp")
	end

	-- "Update available" line in the top-left corner, hidden unless a newer
	-- version has been seen (see Modules\VersionCheck.lua).
	JohnnysRaidComp.VersionCheck:AttachNotice(mainFrame)

	BuildRaidListPage()
	BuildSizeListPage()
	BuildCompPage()

	mainFrame:SetScript("OnShow", function()
		local lastRaid = JohnnysRaidComp.db.profile.raidCompSelectedRaid
		local lastSize = JohnnysRaidComp.db.profile.raidCompSelectedSize
		-- Class Run's template is only ever built lazily inside
		-- ShowClassRunComp itself, so it won't exist yet on a fresh session -
		-- route there directly instead of the TEMPLATES-lookup check below
		-- (which would otherwise fail and fall back to the raid list).
		if lastRaid and lastSize == "CLASSRUN" and RaidCompUI.CLASS_RUN_RAIDS[lastRaid] then
			RaidCompUI:ShowClassRunComp(lastRaid)
		elseif lastRaid and lastSize and RaidCompUI.TEMPLATES[lastRaid .. "_" .. lastSize] then
			RaidCompUI:ShowComp(lastRaid, lastSize)
		else
			ShowRaidList()
		end
	end)
end

function RaidCompUI:Toggle()
	if not mainFrame then
		BuildFrame()
	end
	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		mainFrame:Show()
	end
end

-- Called by Init.lua's roster-change listener; only does anything while the
-- comp grid (not a selector page) is actually on screen.
function RaidCompUI:IsShowingComp()
	return mainFrame and mainFrame:IsShown() and compPage and compPage:IsShown()
end

-- Small getter so other standalone addons (e.g. JohnnysRaidSpam) can read the
-- currently selected raid/size through the guarded RaidCompUI table reference
-- instead of reaching into this addon's own SavedVariables directly.
function RaidCompUI:GetSelectedRaid()
	return JohnnysRaidComp.db.profile.raidCompSelectedRaid, JohnnysRaidComp.db.profile.raidCompSelectedSize
end

-- Called once a queued GearScore/PVP-gear lookup resolves (see below).
-- A full RefreshComp is cheap here (at most ~25 cards) and keeps this simple
-- rather than hunting down which single card/chip currently shows `name`.
RaidCompUI.OnGearScoreUpdated = function(name)
	if RaidCompUI:IsShowingComp() then
		RaidCompUI:RefreshComp()
	end
end

----------------------------------------------------------------------------
-- GearScore/PVP-gear lookup. The score math is our own GearScoreLite-
-- compatible formula (Modules\GearScore.lua), so GearScoreLite doesn't need
-- to be installed. It only reads whatever gear the client can currently see,
-- and a first read right after NotifyInspect is very often empty because the
-- server's inspect data hasn't arrived on the client yet (or an item isn't
-- in the item cache). What follows owns the request/response flow: a
-- throttled NotifyInspect queue, a couple of short retries when a read comes
-- back empty, resilience detection (our own hidden scan tooltip - see
-- ItemHasResilience), and a highest-score-ever-seen cache in db.global so a lucky
-- earlier read survives an unlucky later one (and survives a /reload, since
-- it's not tied to whichever of your own characters did the inspecting).
--
-- (This lived in its own Modules\RaidCompUI\Inspect.lua file originally, but
-- that file was silently never loading - the .toc listed it correctly and
-- its contents were valid, but nothing in it, not even a bare print(), ever
-- ran, even after a full character-select relog. Folded in here instead,
-- since UI.lua is proven to load reliably.)
----------------------------------------------------------------------------

local GS_REQUEST_INTERVAL = 1 -- min seconds between outgoing NotifyInspect calls
local GS_STALE_SECONDS = 300 -- re-request a cached entry after this long
local GS_RETRY_DELAY = 0.75
local GS_MAX_RETRIES = 3

-- Equippable slots the GearScore formula reads (1-18, skipping 4 = shirt), and
-- the slot's display name for the PVP-piece list shown in the tooltip.
local GS_SLOT_NAMES = {
	[1] = "Head", [2] = "Neck", [3] = "Shoulder", [5] = "Chest", [6] = "Waist",
	[7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Ring",
	[12] = "Ring", [13] = "Trinket", [14] = "Trinket", [15] = "Back",
	[16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged",
}

local gsRequestQueue = {} -- ordered list of {name=, unit=}
-- [name] = true for the *entire* lifetime of a lookup - from RequestGearScore
-- accepting it, through however many retries, until ResolveScore finally
-- either stores a result or gives up. Prevents RefreshComp (which calls
-- RequestGearScore for the whole roster on every repaint, including the
-- repaint a finished lookup itself triggers) from piling up duplicate
-- requests for someone whose lookup is already in flight.
local gsInFlight = {}
local gsPendingGuid = {} -- [guid] = {name=, unit=}, so INSPECT_READY can find its request
local gsRetries = {} -- [name] = zero-score attempts so far for the current inspect
local gsRetryQueue = {} -- ordered list of {name=, unit=, fireAt=}

local function GSGetCache()
	return JohnnysRaidComp.db.global.raidCompGearScores
end

local function GSIsFresh(name)
	local entry = GSGetCache()[name]
	return entry and entry.updatedAt and (GetTime() - entry.updatedAt) < GS_STALE_SECONDS
end

-- Only ever called with a genuine, complete reading (GSResolveScoreBody
-- already retries a 0/empty read up to GS_MAX_RETRIES before giving up
-- without ever calling this) - so the new value always replaces the old one,
-- reflecting whatever the player currently has equipped. Earlier this kept
-- the highest score ever seen instead, on the theory that a low/zero read
-- meant a bad inspect - but that also meant a real re-gear (say, PvE gear
-- swapped for a lower-scoring PvP set) could never show, since the old
-- higher score would stick forever. The retry-until-valid logic above is
-- what actually solves "first inspect often reads 0"; this just trusts
-- whatever it hands back.
function RaidCompUI:StoreGearScore(name, score, avgIlvl, hasPvpGear, pvpSlots)
	local cache = GSGetCache()
	local entry = cache[name]
	if not entry then
		entry = {}
		cache[name] = entry
	end

	local oldScore = entry.score

	if score and score > 0 then
		entry.score = score
		entry.avgIlvl = avgIlvl
	end
	entry.hasPvpGear = hasPvpGear
	entry.pvpSlots = pvpSlots
	entry.updatedAt = GetTime()

	-- Flag a genuine change so gsFlashPump pulses this member's box until the
	-- leader acknowledges it. A first-ever reading (oldScore == nil) is not a
	-- "change" and doesn't flash - see the plan/user decision.
	if score and score > 0 and oldScore and oldScore ~= score then
		gsChanged[name] = true
	end

	if RaidCompUI.OnGearScoreUpdated then
		RaidCompUI.OnGearScoreUpdated(name)
	end
end

-- 3.3.5a has no GetItemStats, so resilience is read the way Pawn does it:
-- render the item into a hidden tooltip and pattern-match its lines.
-- English-client text, like the rest of the addon.
local pvpScanTooltip = CreateFrame("GameTooltip", "JohnnysRaidCompScanTooltip", nil, "GameTooltipTemplate")
local RESILIENCE_PATTERNS = {
	"Improves your resilience rating by %d+",
	"Increases your resilience rating by %d+",
}

-- True if an item's own stats include resilience. "Use:"/proc lines are
-- skipped so a temporary effect doesn't flag a PvE item.
local function ItemHasResilience(link)
	pvpScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
	pvpScanTooltip:ClearLines()
	pvpScanTooltip:SetHyperlink(link)
	for i = 2, pvpScanTooltip:NumLines() do
		local fontString = _G["JohnnysRaidCompScanTooltipTextLeft" .. i]
		local text = fontString and fontString:GetText()
		if text and not (text:find("^Use:") or text:find("Chance on") or text:find(" for %d+ sec")) then
			for _, pattern in ipairs(RESILIENCE_PATTERNS) do
				if text:find(pattern) then
					return true
				end
			end
		end
	end
	return false
end

-- Scans the (now-inspected) unit's equipped gear for a resilience line (see
-- ItemHasResilience). Also reports whether any equipped-item data was
-- actually readable yet, so callers can tell "no PVP gear" apart from
-- "inspect data hasn't arrived".
local function GSScanPvpGear(unit)
	local hasPvp, slots, sawAnyItem = false, {}, false
	for slotId, slotName in pairs(GS_SLOT_NAMES) do
		local link = GetInventoryItemLink(unit, slotId)
		if link then
			sawAnyItem = true
			if ItemHasResilience(link) then
				hasPvp = true
				slots[slotName] = true
			end
		end
	end
	return hasPvp, slots, sawAnyItem
end

local function GSQueueRetry(name, unit)
	table.insert(gsRetryQueue, { name = name, unit = unit, fireAt = GetTime() + GS_RETRY_DELAY })
end

-- The actual body, pcall'd by GSResolveScore below - the score read and
-- ItemHasResilience both depend on inspect/item-cache data and item
-- tooltip rendering, and a failure there must never get to spam
-- errors from the OnUpdate pump or leave `gsInFlight[name]` stuck true
-- forever (which would silently stop that player from ever being looked up
-- again this session).
local function GSResolveScoreBody(name, unit)
	if not (UnitExists(unit) and UnitName(unit) == name) then
		gsInFlight[name] = nil
		gsRetries[name] = nil
		return
	end

	local score, avgIlvl, incomplete = JohnnysRaidComp.GearScore:GetScore(unit)
	local hasPvp, pvpSlots, sawAnyItem = GSScanPvpGear(unit)

	-- Retry an empty read, or one where some item wasn't in the item cache yet
	-- (its score would be too low). Giving up stores nothing, so the next
	-- RefreshComp simply requests a fresh inspect.
	if incomplete or (not sawAnyItem and (not score or score == 0)) then
		if (gsRetries[name] or 0) < GS_MAX_RETRIES then
			gsRetries[name] = (gsRetries[name] or 0) + 1
			GSQueueRetry(name, unit)
		else
			gsInFlight[name] = nil
			gsRetries[name] = nil
		end
		return
	end

	gsInFlight[name] = nil
	gsRetries[name] = nil
	RaidCompUI:StoreGearScore(name, score, avgIlvl, hasPvp, pvpSlots)
end

-- Reads back the GearScore + the PVP scan for a unit that should now
-- have inspect data available. Called from two places for the same pending
-- request - the INSPECT_READY handler, and a fallback retry timer queued
-- right after every NotifyInspect (in case INSPECT_READY never fires, e.g.
-- the target leaves inspect range mid-request) - so the gsInFlight check up
-- front makes whichever one loses the race a harmless no-op.
local function GSResolveScore(name, unit)
	if not gsInFlight[name] then
		return
	end

	local ok, err = pcall(GSResolveScoreBody, name, unit)
	if not ok then
		gsInFlight[name] = nil
		gsRetries[name] = nil
		geterrorhandler()(err)
	end
end

-- Queues a unit for an inspect-driven GearScore/PVP-gear lookup. Safe to call
-- repeatedly (e.g. every RefreshComp, including the repaint a finished lookup
-- itself triggers) - skips anyone already in flight or still fresh.
function RaidCompUI:RequestGearScore(name, unit)
	if not (name and unit and UnitExists(unit)) then
		return
	end
	if gsInFlight[name] or GSIsFresh(name) then
		return
	end

	gsInFlight[name] = true
	table.insert(gsRequestQueue, { name = name, unit = unit })
end

-- Wipes the cached entry and every in-flight guard/queue slot for `name` so a
-- following RequestGearScore isn't skipped (gsInFlight/GSIsFresh) or beaten by a
-- stale pending inspect. Shared by the single-member Ctrl+click path and the
-- whole-roster "Re-scan all GS" button below.
local function GSClearPending(name)
	GSGetCache()[name] = nil
	gsInFlight[name] = nil
	gsRetries[name] = nil
	gsChanged[name] = nil
	for i = #gsRequestQueue, 1, -1 do
		if gsRequestQueue[i].name == name then
			table.remove(gsRequestQueue, i)
		end
	end
	for i = #gsRetryQueue, 1, -1 do
		if gsRetryQueue[i].name == name then
			table.remove(gsRetryQueue, i)
		end
	end
	for guid, req in pairs(gsPendingGuid) do
		if req.name == name then
			gsPendingGuid[guid] = nil
		end
	end
end

-- Manual "this reading looks wrong, do it again" - bound to Ctrl+click on any
-- slot card / bench chip (see OnCardClick / OnBenchClick). Clears the member's
-- cached score + guards, then re-queues a fresh lookup against their current
-- unit token. Generalises the same reset the INSPECT_READY frame already does
-- for PLAYER_EQUIPMENT_CHANGED on your own name.
function RaidCompUI:ForceRescanGearScore(name)
	if not name then
		return
	end
	-- Achievements re-scan too - the RefreshComp below re-requests them.
	AchClearPending(name)

	GSClearPending(name)

	for _, member in ipairs(self:ScanRoster()) do
		if member.name == name then
			self:RequestGearScore(name, member.unit)
			break
		end
	end

	if reportVHStatus then
		reportVHStatus:SetText("Re-scanning " .. name .. "...")
	end
	-- Repaint so the box drops back to "GS --" immediately; the result lands via
	-- the normal INSPECT_READY -> StoreGearScore -> OnGearScoreUpdated path.
	if RaidCompUI:IsShowingComp() then
		RaidCompUI:RefreshComp()
	end
end

-- Whole-roster version, bound to the comp page's "Re-scan all GS" button - so
-- the leader can force a fresh sweep without closing and reopening the window
-- (which only re-requests uncached/stale members, not a true refresh). Clears
-- every current roster member's cached score + guards and re-queues them; the
-- gsPump throttle then spaces the NotifyInspect calls out at GS_REQUEST_INTERVAL
-- as usual, so a full 25-man repopulates over ~25s.
function RaidCompUI:RescanAllGearScores()
	local roster = self:ScanRoster()
	-- Achievements re-scan too (see ForceRescanGearScore above).
	for _, member in ipairs(roster) do
		AchClearPending(member.name)
	end

	for _, member in ipairs(roster) do
		GSClearPending(member.name)
		self:RequestGearScore(member.name, member.unit)
	end

	if reportVHStatus then
		reportVHStatus:SetText(string.format("Re-scanning all %d member(s)...", #roster))
	end
	if RaidCompUI:IsShowingComp() then
		RaidCompUI:RefreshComp()
	end
end

----------------------------------------------------------------------------
-- Flash pump - drives the amber "GearScore changed" pulse on any currently-
-- shown box whose member is still in gsChanged (unacknowledged). Cheap
-- early-out when nothing is pending; otherwise it's at most ~25 cards + ~12
-- chips touched per frame. The pulse stops when the leader hovers or clicks the
-- box (see the OnEnter / OnCardClick / OnBenchClick handlers) or force-re-scans
-- it. Same polled manual-accumulator style as the request pump below.
----------------------------------------------------------------------------
local gsFlashPump = CreateFrame("Frame")
gsFlashPump:SetScript("OnUpdate", function()
	if not next(gsChanged) then
		return
	end
	local a = 0.12 + 0.22 * (0.5 + 0.5 * math.sin(GetTime() * 4))
	local function paint(boxes, key)
		for _, box in ipairs(boxes) do
			if box:IsShown() and box[key] and gsChanged[box[key]] then
				box.flashTex:SetAlpha(a)
				box.flashTex:Show()
			else
				box.flashTex:Hide()
			end
		end
	end
	paint(slotCards, "matchedName")
	paint(benchChips, "name")
end)

----------------------------------------------------------------------------
-- Pump - a single OnUpdate ticker drives both the outgoing request queue
-- (throttled to GS_REQUEST_INTERVAL so we don't hammer the client's own
-- inspect cooldown) and any scheduled retries. Same manual-accumulator style
-- as Init.lua's roster debounce and GearUpgrade\UI.lua's item-info retry
-- ticker - 3.3.5a has no embedded AceTimer, so everything here is polled.
----------------------------------------------------------------------------
local gsPump = CreateFrame("Frame")
local gsSinceLastRequest = GS_REQUEST_INTERVAL
gsPump:SetScript("OnUpdate", function(self, elapsed)
	gsSinceLastRequest = gsSinceLastRequest + elapsed

	if gsSinceLastRequest >= GS_REQUEST_INTERVAL and #gsRequestQueue > 0 then
		local request = table.remove(gsRequestQueue, 1)
		if UnitExists(request.unit) and UnitName(request.unit) == request.name and CanInspect(request.unit) then
			gsSinceLastRequest = 0
			gsPendingGuid[UnitGUID(request.unit)] = request
			NotifyInspect(request.unit)
			GSQueueRetry(request.name, request.unit) -- safety net if INSPECT_READY never fires
		else
			-- Out of inspect range/can't be inspected right now - drop it;
			-- the next RefreshComp will naturally re-request them since
			-- nothing was ever stored for this attempt.
			gsInFlight[request.name] = nil
		end
	end

	if #gsRetryQueue > 0 then
		local now = GetTime()
		local i = 1
		while i <= #gsRetryQueue do
			local retry = gsRetryQueue[i]
			if now >= retry.fireAt then
				table.remove(gsRetryQueue, i)
				GSResolveScore(retry.name, retry.unit)
			else
				i = i + 1
			end
		end
	end
end)

local gsInspectFrame = CreateFrame("Frame")
gsInspectFrame:RegisterEvent("INSPECT_READY")
-- Own gear swap (e.g. PvE -> PvP set before a raid) - re-check immediately
-- rather than waiting out GS_STALE_SECONDS, since this is the one case where
-- we know for certain the cached reading is now out of date.
gsInspectFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
gsInspectFrame:SetScript("OnEvent", function(self, event, guid)
	if event == "PLAYER_EQUIPMENT_CHANGED" then
		local cache = GSGetCache()
		cache[UnitName("player")] = nil
		if RaidCompUI:IsShowingComp() then
			RaidCompUI:RefreshComp()
		end
		return
	end

	local request = gsPendingGuid[guid]
	if not request then
		return
	end
	gsPendingGuid[guid] = nil
	GSResolveScore(request.name, request.unit)
end)

----------------------------------------------------------------------------
-- Achievement/kill-count lookup, shown in the same tooltip as GearScore (see
-- AddAchievementLines / ShowGearScoreTooltip). 3.3.5a's only way to read
-- another player's achievements is the comparison API the Blizzard
-- Achievements "Compare" tab uses: SetAchievementComparisonUnit(unit) asks the
-- server, INSPECT_ACHIEVEMENT_READY fires (with no guid to say whose data it
-- is), then GetAchievementComparisonInfo / GetComparisonStatistic read it and
-- ClearAchievementComparisonUnit releases it. There's only ONE comparison slot
-- client-wide, so this runs strictly one request at a time, separate from the
-- NotifyInspect queue above, and stands aside entirely while the Blizzard
-- compare frame is open so it never clobbers a compare the user started.
--
-- Each scan reads every ID for every raid in RAID_ACHIEVEMENTS (not just the
-- selected one), so switching raids in the picker needs no re-scan. Gated on
-- db.profile.showAchievementTooltip - off means no scans and no tooltip lines.
----------------------------------------------------------------------------

-- Pacing is measured from the previous request FINISHING (answered or timed
-- out), not from it being sent: the gap starts at ACH_MIN_GAP, doubles (up to
-- ACH_MAX_GAP) whenever a request times out - in case the server throttles
-- rapid comparison requests - and eases back down on each answer.
local ACH_MIN_GAP = 0.3
local ACH_MAX_GAP = 2
local ACH_TIMEOUT = 2.5 -- give up on a request whose READY never came
local ACH_STALE_SECONDS = 3600 -- re-request a cached entry after this long (time() based)
-- Bump whenever what a scan reads changes, so saved entries from an older
-- scan are treated as missing and re-scanned. 2 = kill-stat matching fix,
-- 3 = first-boss stats for the runs/clears line, 4 = KILL_STAT_ALIASES.
local ACH_DATA_VERSION = 4

local ACH_ICON_DONE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t "
local ACH_ICON_MISSING = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t "

-- Size whose achievements also satisfy this size's (see AddAchievementLines).
local ACH_25_COUNTERPART = { ["10"] = "25", ["10H"] = "25H" }

local achQueue = {} -- ordered list of {name=, unit=}
local achInFlight = {} -- [name] = true from RequestAchievements until stored/dropped
local achPending = nil -- the one outstanding {name=, unit=, sentAt=}

local function AchGetCache()
	return JohnnysRaidComp.db.global.raidCompAchievements
end

-- A member's cached entry, or nil if missing or from an older scan version.
local function AchGetEntry(name)
	local entry = AchGetCache()[name]
	if entry and entry.v == ACH_DATA_VERSION then
		return entry
	end
	return nil
end

function RaidCompUI:IsAchievementTooltipEnabled()
	return JohnnysRaidComp.db and JohnnysRaidComp.db.profile.showAchievementTooltip and true or false
end

local function BlizzCompareOpen()
	return AchievementFrameComparison and AchievementFrameComparison:IsShown()
end

-- CLASSRUN has no size-specific achievements of its own - use the 10s.
local function AchSpecFor(raidKey, sizeKey)
	local spec = raidKey and RaidCompUI.RAID_ACHIEVEMENTS[raidKey]
	if not spec then
		return nil
	end
	if sizeKey == "CLASSRUN" then
		sizeKey = "10"
	end
	return spec, sizeKey
end

-- Every statistic the client knows about, as { {id=, name=}, ... }, built on
-- first use. Not cached while empty, in case it's asked before the client has
-- its achievement data loaded.
local achStatIndex
local function AchStatIndex()
	if achStatIndex then
		return achStatIndex
	end
	local list = {}
	if GetStatisticsCategoryList then
		for _, cat in ipairs(GetStatisticsCategoryList() or {}) do
			for i = 1, (GetCategoryNumAchievements(cat) or 0) do
				local id, name = GetAchievementInfo(cat, i)
				if id and name then
					table.insert(list, { id = id, name = name })
				end
			end
		end
	end
	if #list > 0 then
		achStatIndex = list
	end
	return list
end

-- Finds the "<boss> kills (<instance> NN player)" statistic for a size key
-- ("10"/"10H"/"25"/"25H") by name - heroic variants say "Heroic ..." (ICC/RS)
-- or "Grand Crusader" (ToC). The boss name must be BEFORE the parentheses and
-- the size/difficulty INSIDE them: the expansion-wide stats like "Lich King
-- 25-player raids completed (final boss killed)" also contain "Lich King",
-- "25-player" and "kill", and matching them showed all WotLK 25-man clears as
-- Lich King kills. Heroic-ness is checked across the whole name, since some
-- say it outside the parentheses ("Times completed the Trial of the Grand
-- Crusader (10 player)"). A boss with KILL_STAT_ALIASES (see Data.lua) also
-- matches those alternate names. Prefers names containing "kill", falling
-- back to any other boss+size match (e.g. "Victories over ..."). Cached,
-- misses too.
local achStatCache = {}
local function ResolveKillStat(boss, sizeKey)
	local cacheKey = boss .. "|" .. sizeKey
	if achStatCache[cacheKey] ~= nil then
		return achStatCache[cacheKey] or nil
	end
	local index = AchStatIndex()
	if #index == 0 then
		return nil
	end

	local needles = { boss }
	for _, alias in ipairs(RaidCompUI.KILL_STAT_ALIASES[boss] or {}) do
		table.insert(needles, alias)
	end

	local sizePattern = sizeKey:sub(1, 2) .. "[%s%-]player"
	local wantHeroic = sizeKey:find("H", 1, true) ~= nil
	local fallback
	for _, stat in ipairs(index) do
		local name = stat.name
		local before, inParens = name:match("^(.-)%s*%((.-)%)%s*$")
		if before and inParens:find(sizePattern) then
			local bossMatch = false
			for _, needle in ipairs(needles) do
				if before:find(needle, 1, true) then
					bossMatch = true
					break
				end
			end
			local isHeroic = name:find("Heroic", 1, true) ~= nil or name:find("Grand Crusader", 1, true) ~= nil
			if bossMatch and isHeroic == wantHeroic then
				if before:lower():find("kill", 1, true) then
					achStatCache[cacheKey] = stat.id
					return stat.id
				end
				fallback = fallback or stat.id
			end
		end
	end
	achStatCache[cacheKey] = fallback or false
	return fallback
end

-- Every boss whose kill statistic a scan should read for `spec`: the
-- tooltip's kill-count bosses plus its `runs` first/last bosses, deduped.
local function AchAllBosses(spec)
	local list, seen = {}, {}
	local function add(boss)
		if boss and not seen[boss] then
			seen[boss] = true
			table.insert(list, boss)
		end
	end
	for _, boss in ipairs(spec.bosses or {}) do
		add(boss)
	end
	if spec.runs then
		for _, boss in ipairs(spec.runs.first or {}) do
			add(boss)
		end
		add(spec.runs.last)
	end
	return list
end

-- A scanned member's kill count for boss+size as a number (the API gives
-- "--" for none), or nil if this client has no such statistic at all.
local function AchKills(entry, boss, sizeKey)
	local statId = ResolveKillStat(boss, sizeKey)
	if not statId then
		return nil
	end
	return tonumber(entry.stats[statId]) or 0
end

-- One labelled row per size of the raid (see RAID_ACHIEVEMENTS' `runs` for
-- what counts as a run vs a clear), the selected size marked and in white:
--   Runs                      (selected size marked with >)
--   > 25-Man            12 runs, 3 cleared
--     25-Man Heroic                  none
-- Sizes where no statistic resolved at all are left out; a clears statistic
-- that didn't resolve shows as "?" rather than hiding the run count.
local function AchAddRunLines(entry, spec, raidKey, selectedSize)
	local runs = spec.runs
	if not runs then
		return
	end
	local rows = {}
	for _, sizeKey in ipairs(RaidCompUI.RAID_SIZE_ORDER[raidKey] or {}) do
		local runCount
		for _, boss in ipairs(runs.first or {}) do
			local kills = AchKills(entry, boss, sizeKey)
			if kills then
				runCount = math.max(runCount or 0, kills)
			end
		end
		local clears = runs.last and AchKills(entry, runs.last, sizeKey)
		if clears then
			runCount = math.max(runCount or 0, clears)
		end

		if runCount then
			local value
			if runCount == 0 then
				value = "none"
			elseif not runs.first then
				value = string.format("%d kill%s", runCount, runCount == 1 and "" or "s") -- single-boss raid
			elseif not runs.last then
				value = string.format("%d run%s", runCount, runCount == 1 and "" or "s") -- VoA: no boss order
			else
				value = string.format("%d run%s, %s cleared", runCount, runCount == 1 and "" or "s", clears and tostring(clears) or "?")
			end
			table.insert(rows, { sizeKey = sizeKey, value = value, zero = runCount == 0 })
		end
	end
	if #rows == 0 then
		return
	end

	-- Every size reporting the exact same non-zero count means the server
	-- isn't splitting that raid's statistics by size/difficulty (seen with
	-- ToC: 137/116 on all four, heroics never run) - one combined row, instead
	-- of four rows claiming runs that never happened.
	local allSame = #rows > 1 and not rows[1].zero
	for i = 2, #rows do
		if rows[i].value ~= rows[1].value then
			allSame = false
			break
		end
	end
	if allSame then
		GameTooltip:AddLine("Runs", 1, 0.82, 0)
		GameTooltip:AddDoubleLine("   All sizes combined", rows[1].value, 1, 1, 1, 1, 1, 1)
		GameTooltip:AddLine("   (server doesn't split this raid's stats by size)", 0.6, 0.6, 0.6)
		return
	end

	GameTooltip:AddLine("Runs", 1, 0.82, 0)
	for _, row in ipairs(rows) do
		local label = RaidCompUI.SIZE_LABELS[row.sizeKey] or row.sizeKey
		if row.sizeKey == selectedSize then
			GameTooltip:AddDoubleLine("> " .. label, row.value, 1, 1, 1, row.zero and 0.6 or 1, row.zero and 0.6 or 1, row.zero and 0.6 or 1)
		else
			GameTooltip:AddDoubleLine("   " .. label, row.value, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
		end
	end
end

-- Tooltip section for the currently selected raid/size - called from every
-- exit path of ShowGearScoreTooltip.
function AddAchievementLines(name)
	if not RaidCompUI:IsAchievementTooltipEnabled() then
		return
	end
	local raidKey, rawSize = RaidCompUI:GetSelectedRaid()
	local spec, sizeKey = AchSpecFor(raidKey, rawSize)
	if not spec then
		return
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(string.format("Achievements (%s %s):", RaidCompUI.RAID_LABELS[raidKey] or raidKey,
		RaidCompUI.SIZE_LABELS[sizeKey] or sizeKey), 1, 0.82, 0)

	local entry = AchGetEntry(name)
	if not entry then
		if achInFlight[name] then
			-- Being hovered = wanted now: jump the queue (if not already sent).
			for i = 2, #achQueue do
				if achQueue[i].name == name then
					table.insert(achQueue, 1, table.remove(achQueue, i))
					break
				end
			end
			GameTooltip:AddLine("scanning...", 0.6, 0.6, 0.6)
		else
			GameTooltip:AddLine("not yet scanned (out of range?)", 0.6, 0.6, 0.6)
		end
		return
	end

	-- On a 10-man, the 25-man version of the same achievement counts too -
	-- matched by position, since each raid's 10/25 lists in RAID_ACHIEVEMENTS
	-- are kept parallel.
	local upSize = ACH_25_COUNTERPART[sizeKey]
	local upIds = upSize and spec[upSize]

	for i, id in ipairs(spec[sizeKey] or {}) do
		local _, achName = GetAchievementInfo(id)
		if achName then
			local upId = upIds and upIds[i]
			if entry.ach[id] then
				GameTooltip:AddLine(ACH_ICON_DONE .. achName, 0.3, 1, 0.3)
			elseif upId and entry.ach[upId] then
				GameTooltip:AddLine(ACH_ICON_DONE .. achName .. " (via 25-man)", 0.3, 1, 0.3)
			else
				GameTooltip:AddLine(ACH_ICON_MISSING .. achName, 0.6, 0.6, 0.6)
			end
		end
	end

	-- Per-boss kill lines only where the Runs rows don't already say it -
	-- i.e. VoA, whose bosses have no order (so no "cleared" count).
	if not (spec.runs and spec.runs.last) then
		for _, boss in ipairs(spec.bosses or {}) do
			local kills = AchKills(entry, boss, sizeKey)
			if kills then
				if kills > 0 then
					GameTooltip:AddLine(string.format("%s kills: %d", boss, kills), 1, 1, 1)
				else
					GameTooltip:AddLine(string.format("%s kills: 0", boss), 0.6, 0.6, 0.6)
				end
			end
		end
	end

	AchAddRunLines(entry, spec, raidKey, sizeKey)
end

-- `/jrc statsearch <text>` - every statistic this client has whose name
-- contains <text> (case-insensitive), with its ID. For finding what a
-- server actually calls a boss's kill statistic when /jrc achcheck says
-- NOT FOUND or a count looks wrong.
function RaidCompUI:PrintStatSearch(text)
	local out = DEFAULT_CHAT_FRAME
	text = (text or ""):lower()
	if text == "" then
		out:AddMessage("|cff66ccffJohnny's Raid Comp|r: /jrc statsearch <part of a name>, e.g. /jrc statsearch crusade")
		return
	end
	local found = 0
	for _, stat in ipairs(AchStatIndex()) do
		if stat.name:lower():find(text, 1, true) then
			found = found + 1
			out:AddMessage(string.format("  %d  %s", stat.id, stat.name))
		end
	end
	out:AddMessage(string.format("|cff66ccffJohnny's Raid Comp|r: %d statistic(s) matching \"%s\"", found, text))
end

-- Queues a member for an achievement comparison. Safe to call on every
-- RefreshComp - skips anyone already in flight or still fresh, and does
-- nothing while the option is off.
function RaidCompUI:RequestAchievements(name, unit)
	if not (self:IsAchievementTooltipEnabled() and SetAchievementComparisonUnit and name and unit and UnitExists(unit)) then
		return
	end
	if achInFlight[name] then
		return
	end
	local entry = AchGetEntry(name)
	if entry and entry.updatedAt and (time() - entry.updatedAt) < ACH_STALE_SECONDS then
		return
	end
	achInFlight[name] = true
	table.insert(achQueue, { name = name, unit = unit })
end

-- Same role as GSClearPending, for the Ctrl+click / "Re-scan all GS" paths.
-- If this member's comparison is the one outstanding right now, it's left
-- in flight - fresh data is already on its way.
function AchClearPending(name)
	AchGetCache()[name] = nil
	for i = #achQueue, 1, -1 do
		if achQueue[i].name == name then
			table.remove(achQueue, i)
		end
	end
	if not (achPending and achPending.name == name) then
		achInFlight[name] = nil
	end
end

local function AchDropPending()
	if achPending then
		if not BlizzCompareOpen() then
			ClearAchievementComparisonUnit()
		end
		achInFlight[achPending.name] = nil
		achPending = nil
	end
end

function RaidCompUI:SetAchievementTooltipEnabled(on)
	JohnnysRaidComp.db.profile.showAchievementTooltip = on and true or false
	if not on then
		for i = #achQueue, 1, -1 do
			achInFlight[achQueue[i].name] = nil
			achQueue[i] = nil
		end
		AchDropPending()
	end
	if self:IsShowingComp() then
		self:RefreshComp()
	end
end

-- Reads every tracked achievement + kill statistic for all raids out of the
-- active comparison. pcall'd by the event handler below.
local function AchReadBody(name)
	local entry = { ach = {}, stats = {}, updatedAt = time(), v = ACH_DATA_VERSION }
	for raidKey, spec in pairs(RaidCompUI.RAID_ACHIEVEMENTS) do
		for key, ids in pairs(spec) do
			if key ~= "bosses" and key ~= "runs" then
				for _, id in ipairs(ids) do
					if GetAchievementInfo(id) then
						entry.ach[id] = GetAchievementComparisonInfo(id) and true or false
					end
				end
			end
		end
		for _, sizeKey in ipairs(RaidCompUI.RAID_SIZE_ORDER[raidKey] or {}) do
			for _, boss in ipairs(AchAllBosses(spec)) do
				local statId = ResolveKillStat(boss, sizeKey)
				if statId then
					entry.stats[statId] = GetComparisonStatistic(statId)
				end
			end
		end
	end
	AchGetCache()[name] = entry
end

local achPump = CreateFrame("Frame")
local achGap = ACH_MIN_GAP
local achSinceDone = ACH_MAX_GAP -- seconds since the last request finished
achPump:SetScript("OnUpdate", function(self, elapsed)
	achSinceDone = achSinceDone + elapsed

	if achPending then
		if GetTime() - achPending.sentAt > ACH_TIMEOUT then
			-- Never answered (left range, logged off, or the server throttling
			-- us) - drop it and slow down; the next RefreshComp re-requests
			-- them since nothing was stored.
			AchDropPending()
			achGap = math.min(achGap * 2, ACH_MAX_GAP)
			achSinceDone = 0
		end
		return
	end

	if #achQueue == 0 or achSinceDone < achGap or BlizzCompareOpen() then
		return
	end

	local request = table.remove(achQueue, 1)
	if UnitExists(request.unit) and UnitName(request.unit) == request.name and UnitIsVisible(request.unit) then
		request.sentAt = GetTime()
		achPending = request
		SetAchievementComparisonUnit(request.unit)
	else
		achInFlight[request.name] = nil
	end
end)

local achEventFrame = CreateFrame("Frame")
achEventFrame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
achEventFrame:SetScript("OnEvent", function()
	local request = achPending
	if not request then
		return
	end
	achPending = nil
	achInFlight[request.name] = nil
	achSinceDone = 0
	achGap = math.max(ACH_MIN_GAP, achGap * 0.75)

	-- The Blizzard compare opened while ours was pending - this READY may be
	-- its data, not ours, so leave the comparison alone and retry later.
	if BlizzCompareOpen() then
		return
	end

	local ok, err = pcall(AchReadBody, request.name)
	ClearAchievementComparisonUnit()
	if not ok then
		geterrorhandler()(err)
		return
	end
	if RaidCompUI.OnGearScoreUpdated then
		RaidCompUI.OnGearScoreUpdated(request.name)
	end

	-- If that member's tooltip is open right now, redraw it so the results
	-- appear without having to mouse off and back on. Slot cards keep the
	-- member in .matchedName, bench chips in .name.
	local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
	if owner and (owner.matchedName or owner.name) == request.name then
		pcall(ShowGearScoreTooltip, owner, request.name)
	end
end)

-- `/jrc achcheck` - lists every configured achievement ID and resolved kill
-- statistic with the name this client reports, so bad IDs are easy to spot.
function RaidCompUI:PrintAchievementCheck()
	local out = DEFAULT_CHAT_FRAME
	out:AddMessage("|cff66ccffJohnny's Raid Comp|r achievement check:")
	for _, raidKey in ipairs(self.RAID_ORDER) do
		local spec = self.RAID_ACHIEVEMENTS[raidKey]
		if spec then
			for _, sizeKey in ipairs(self.RAID_SIZE_ORDER[raidKey] or {}) do
				local parts = {}
				for _, id in ipairs(spec[sizeKey] or {}) do
					local _, achName = GetAchievementInfo(id)
					table.insert(parts, achName and (id .. " " .. achName) or ("|cffff4040" .. id .. " BAD|r"))
				end
				for _, boss in ipairs(AchAllBosses(spec)) do
					local statId = ResolveKillStat(boss, sizeKey)
					local statName = statId and select(2, GetAchievementInfo(statId))
					table.insert(parts, statName and ("stat " .. statId .. " " .. statName) or ("|cffff4040" .. boss .. " kills: NOT FOUND|r"))
				end
				out:AddMessage(string.format("%s %s: %s", raidKey, sizeKey, table.concat(parts, "; ")))
			end
		end
	end
end

-- Registered at load (not in BuildFrame) so the Cfg panel shows it even if
-- it's opened before the comp window has ever been built.
if JohnnysRaidComp.WindowSettings then
	JohnnysRaidComp.WindowSettings:RegisterOption("achTooltip", "Show achievements in tooltips",
		function() return RaidCompUI:IsAchievementTooltipEnabled() end,
		function(checked) RaidCompUI:SetAchievementTooltipEnabled(checked) end)
end
