-- This file is the window itself. Two parts of it live in their own files,
-- loaded right after this one (see the .toc) and reached through RaidCompUI:
--   Inspect.lua       GearScore / PvP gear / talent-role lookups (inspect queue)
--   Achievements.lua  achievement + kill-count lookups for the tooltip
--
-- Raid Comp window, one screen: a rail of WotLK raids on the left, size
-- toggles across the top, and that raid+size's tailored "ideal comp" below,
-- grouped into Tanks / Healers / DPS sections that light up as real raid/party
-- members whose class+role match a slot join the group. Same plain
-- CreateFrame/Skin chrome as the rest of the hub (see Modules\BlackListUI\UI.lua
-- for the pattern this mirrors).
JohnnysRaidComp.RaidCompUI = JohnnysRaidComp.RaidCompUI or {}
local RaidCompUI = JohnnysRaidComp.RaidCompUI
local Skin = JohnnysRaidComp.Skin

-- FRAME_HEIGHT is only the starting/fallback size - RefreshComp sizes the
-- window to its content (see SetFrameHeight) so a 10-man doesn't leave a
-- screenful of dead space below it.
local FRAME_WIDTH, FRAME_HEIGHT = 1000, 560

local SIZE_BUTTON_WIDTH, SIZE_BUTTON_HEIGHT = 104, 22
local SIZE_GAP = 4

local COLUMNS = 6
-- Tall enough for a 3rd line (GearScore) below the name; GRID_TOP/row math
-- below all derive from this constant, so nothing else needs adjusting.
local CARD_WIDTH, CARD_HEIGHT = 131, 58
local CARD_GAP = 6
-- Where the first role section starts, below the size toggles (22px) and the
-- need bar (24px at NEED_BAR_TOP) - all relative to compPage's top.
local NEED_BAR_TOP = 30
local GRID_TOP = -62
-- Each role section: a heading row, its cards, then a gap before the next.
local SECTION_HEAD = 24
local SECTION_GAP = 6

-- Left rail of raids, and compPage's insets inside the window.
local RAIL_WIDTH = 160
local RAIL_TOP = 28
local RAIL_ROW_HEIGHT = 26
local PAGE_TOP_INSET = 10
local PAGE_BOTTOM_INSET = 12
local FOOTER_HEIGHT = 22

-- Bench (overflow) chips - roster members who didn't land in any slot,
-- rendered below the grid so nobody just silently vanishes off-screen.
local BENCH_COLUMNS = 7
-- Tall enough for a 2nd, small line (compact GearScore) below the name.
local BENCH_CHIP_WIDTH, BENCH_CHIP_HEIGHT = 110, 30
local BENCH_GAP = 6

-- Tall enough for the rail's raid list even when the grid is tiny.
local MIN_FRAME_HEIGHT = 320

local mainFrame, compPage
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
-- Height the raid rail needs for its open groups (see LayoutRail) - the
-- window never shrinks below it.
local railNeededHeight = 0

-- matches from the last RefreshComp, so a click can read "who's in slot X
-- right now" without recomputing; and the current selection awaiting a
-- second click to act on (nil when nothing is selected) - either a slot
-- ({kind="slot", value=index}) or a benched roster member
-- ({kind="bench", value=name}).
local currentMatches = {}
local selection = nil
-- [name] = that member's ScanRoster entry from the last RefreshComp, for the
-- "role is only a class guess" mark on cards/chips and the tooltip's Role line.
local rosterByName = {}

-- [name] = true when a GearScore rescan returned a *different* score for that
-- member and the leader hasn't acknowledged it yet (by hovering or clicking
-- their box). Drives the amber pulse in gsFlashPump (see the Flash pump section at the bottom of this
-- file). Session-only, not persisted - it's a transient
-- "look at this" cue, and a re-inspect on login naturally re-flags a real change.
local gsChanged = {}
-- Inspect.lua sets the flags (a rescan came back with a different score).
RaidCompUI.gsChanged = gsChanged

-- Role of each talent tree, in the talent frame's fixed left-to-right tab
-- order for 3.3.5a - the tree with the most points is taken as the spec.
-- `first` is the first tree's name, used to check that inspect talent data
-- really belongs to a player of that class (see DetectSpecRole).
local TALENT_TAB_ROLES = {
	WARRIOR = { "DAMAGER", "DAMAGER", "TANK", first = "Arms" },              -- Arms, Fury, Protection
	PALADIN = { "HEALER", "TANK", "DAMAGER", first = "Holy" },               -- Holy, Protection, Retribution
	HUNTER = { "DAMAGER", "DAMAGER", "DAMAGER", first = "Beast Mastery" },
	ROGUE = { "DAMAGER", "DAMAGER", "DAMAGER", first = "Assassination" },
	PRIEST = { "HEALER", "HEALER", "DAMAGER", first = "Discipline" },        -- Discipline, Holy, Shadow
	-- Any DK tree can tank or DPS on 3.3.5 - decided by TANK_TALENTS below.
	DEATHKNIGHT = { "DAMAGER", "DAMAGER", "DAMAGER", first = "Blood" },      -- Blood, Frost, Unholy
	SHAMAN = { "DAMAGER", "DAMAGER", "HEALER", first = "Elemental" },        -- Elemental, Enhancement, Restoration
	MAGE = { "DAMAGER", "DAMAGER", "DAMAGER", first = "Arcane" },
	WARLOCK = { "DAMAGER", "DAMAGER", "DAMAGER", first = "Affliction" },
	-- Feral is cat or bear - decided by TANK_TALENTS below.
	DRUID = { "DAMAGER", "DAMAGER", "HEALER", first = "Balance" },           -- Balance, Feral, Restoration
}

-- Classes whose tank spec isn't a tree of its own: enough points across these
-- survival talents means tank. `tab` limits the check to when that tree is
-- the main one. English talent names, like the rest of the addon.
local TANK_TALENTS = {
	-- A DK tank takes all three (15 points); DPS builds rarely more than one.
	DEATHKNIGHT = { points = 10, names = { ["Blade Barrier"] = true, ["Toughness"] = true, ["Anticipation"] = true } },
	-- Bears take all three (9 points); cats skip them.
	DRUID = { tab = 2, points = 5, names = { ["Thick Hide"] = true, ["Protector of the Pack"] = true, ["Natural Reaction"] = true } },
}

-- Role + main tree name from talents: your own (inspect = false), or those of
-- the player whose inspect data the client currently holds (inspect = true -
-- only valid right after INSPECT_TALENT_READY, see GSStoreRole). nil if no
-- points are spent, or if the inspect data is for a different class.
local function DetectSpecRole(class, inspect)
	local roles = TALENT_TAB_ROLES[class]
	if not roles then
		return nil
	end
	inspect = inspect and true or false
	local group = GetActiveTalentGroup(inspect, false)
	local bestTab, bestPoints, bestName = nil, 0, nil
	for tabIndex = 1, GetNumTalentTabs(inspect, false) do
		local tabName, _, pointsSpent = GetTalentTabInfo(tabIndex, inspect, false, group)
		if inspect and tabIndex == 1 and tabName ~= roles.first then
			return nil
		end
		if (pointsSpent or 0) > bestPoints then
			bestTab, bestPoints, bestName = tabIndex, pointsSpent, tabName
		end
	end
	if not bestTab then
		return nil
	end

	local role = roles[bestTab]
	local rule = TANK_TALENTS[class]
	if rule and (not rule.tab or rule.tab == bestTab) then
		local points = 0
		for tabIndex = 1, GetNumTalentTabs(inspect, false) do
			for talentIndex = 1, GetNumTalents(tabIndex, inspect, false) do
				local talentName, _, _, _, rank = GetTalentInfo(tabIndex, talentIndex, inspect, false, group)
				if talentName and rule.names[talentName] then
					points = points + (rank or 0)
				end
			end
		end
		if points >= rule.points then
			role = "TANK"
		end
	end
	return role, bestName
end
-- Inspect.lua reads an inspected player's talents with this.
RaidCompUI.DetectSpecRole = DetectSpecRole

-- Resolves a unit's role, best source first: the manually-set raid-frame role
-- icon; your own active talents; the spec read from this player's talents the
-- last time they were inspected (db.realm.raidCompRoles, filled alongside the
-- GearScore inspect - see GSStoreRole); and only then a rough per-class guess
-- (see RaidCompUI.CLASS_DEFAULT_ROLE) so the member still shows up instead of
-- being silently dropped. Returns role, guessed, specName - guessed is true
-- for that last case, so the card can flag it; the next successful inspect
-- replaces it and the comp re-sorts them.
local function ResolveUnitRole(unit, class, name)
	local assigned = UnitGroupRolesAssigned(unit)
	if assigned and assigned ~= "NONE" then
		return assigned, false
	end

	-- UnitIsUnit, not a string == "player" check - in an actual raid the
	-- player's own unit token is "raidN" for whichever N they're slotted at,
	-- not literally "player".
	if UnitIsUnit(unit, "player") then
		local role, spec = DetectSpecRole(class, false)
		if role then
			return role, false, spec
		end
	end

	local known = JohnnysRaidComp.db and JohnnysRaidComp.db.realm.raidCompRoles
	local seen = known and name and known[name]
	if seen and seen.role and seen.class == class then
		return seen.role, false, seen.spec
	end

	return RaidCompUI.CLASS_DEFAULT_ROLE[class] or "DAMAGER", true
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
				local name = UnitName(unit)
				local role, guessed, spec = ResolveUnitRole(unit, class, name)
				table.insert(roster, { name = name, class = class, role = role, roleGuessed = guessed, spec = spec, unit = unit, subgroup = subgroup })
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
				local name = UnitName(unit)
				local role, guessed, spec = ResolveUnitRole(unit, class, name)
				table.insert(roster, { name = name, class = class, role = role, roleGuessed = guessed, spec = spec, unit = unit })
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
-- Manual placement - clicking a slot or a bench chip selects it (white
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
-- Defined with the class-slot editing further down.
local ShowSlotMenu

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
-- (see Inspect.lua). Gray "GS --" until a
-- lookup succeeds.
function FormatGearScoreText(name)
	local entry = JohnnysRaidComp.db.realm.raidCompGearScores[name]
	if not entry or not entry.score then
		return "GS --", 0.5, 0.5, 0.5
	end
	local r, g, b = JohnnysRaidComp.GearScore:GetQuality(entry.score)
	return "GS " .. entry.score, r, g, b
end

-- Same, but abbreviated (e.g. "5.8k") for the much narrower bench chips.
function FormatCompactGearScoreText(name)
	local entry = JohnnysRaidComp.db.realm.raidCompGearScores[name]
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
-- "2E 1G" for a GearScore cache entry with missing enchants / empty sockets,
-- or nil when there's nothing to flag (or the check hasn't run yet).
function RaidCompUI.GearIssueBadge(entry)
	if not entry then
		return nil
	end
	local enchants = entry.missingEnchants and #entry.missingEnchants or 0
	local gems = 0
	for _, text in ipairs(entry.emptySockets or {}) do
		gems = gems + (tonumber(text:match("%((%d+)%)")) or 1)
	end
	local parts = {}
	if enchants > 0 then
		table.insert(parts, enchants .. "E")
	end
	if gems > 0 then
		table.insert(parts, gems .. "G")
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

function ShowGearScoreTooltip(owner, name)
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	GameTooltip:SetText(name)

	local member = rosterByName[name]
	if member and member.role then
		local word = (member.role == "TANK" and "Tank") or (member.role == "HEALER" and "Healer") or "DPS"
		if member.roleGuessed then
			GameTooltip:AddLine("Role: " .. word .. "? Guessed from class - not inspected yet", 1, 0.85, 0.40)
		elseif member.spec then
			GameTooltip:AddLine("Role: " .. word .. " (" .. member.spec .. ")", 0.6, 0.6, 0.6)
		end
	end

	local blacklistEntry = JohnnysBlackList and JohnnysBlackList.BlackListUI and JohnnysBlackList.BlackListUI:GetEntryByName(name)
	if blacklistEntry then
		local reason = blacklistEntry.history and blacklistEntry.history[1] and blacklistEntry.history[1].reason
		GameTooltip:AddLine("BLACKLISTED" .. (reason and (": " .. reason) or ""), 1, 0.15, 0.15)
	end

	local entry = JohnnysRaidComp.db.realm.raidCompGearScores[name]
	if not entry or not entry.score then
		GameTooltip:AddLine("GearScore: not yet inspected", 0.6, 0.6, 0.6)
		RaidCompUI.AddAchievementLines(name)
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

	-- Enchants and gems (rings aren't checked for enchants - only enchanters
	-- can do those).
	if entry.missingEnchants then
		if #entry.missingEnchants > 0 then
			GameTooltip:AddLine("Missing enchants: " .. table.concat(entry.missingEnchants, ", "), 1, 0.85, 0.40, true)
		end
		if entry.emptySockets and #entry.emptySockets > 0 then
			GameTooltip:AddLine("Empty sockets: " .. table.concat(entry.emptySockets, ", "), 1, 0.85, 0.40, true)
		end
		if #entry.missingEnchants == 0 and not (entry.emptySockets and #entry.emptySockets > 0) then
			GameTooltip:AddLine("Fully enchanted and gemmed", 0.6, 0.6, 0.6)
		end
	end

	if entry.updatedAt then
		-- A stamp from before these were time()-based reads as years old - skip it.
		local age = time() - entry.updatedAt
		if age >= 0 and age < 86400 then
			local text = (age < 90) and (age .. "s") or (math.floor(age / 60) .. "m")
			GameTooltip:AddLine("Updated " .. text .. " ago", 0.5, 0.5, 0.5)
		else
			GameTooltip:AddLine("From an earlier session - re-scan pending", 0.5, 0.5, 0.5)
		end
	end

	RaidCompUI.AddAchievementLines(name)
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
		-- One role per class: ticking tank unticks that class's healer mark.
		local healers = JohnnysRaidComp.db.profile.raidCompClassRunHealers[templateKey]
		if healers then
			healers[slot.class] = nil
		end
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
		local tanks = JohnnysRaidComp.db.profile.raidCompClassRunTank
		if tanks[templateKey] == slot.class then
			tanks[templateKey] = nil
		end
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

-- Forgets every hand-made placement, for all raids and sizes. Called when the
-- group ends (see Init.lua): a swap pins the slot it emptied as "keep empty",
-- and left saved that hole stayed "open" in next week's raid while matching
-- players sat on the bench.
function RaidCompUI:ClearManualAssignments()
	local all = JohnnysRaidComp.db.profile.raidCompManualAssignments
	for templateKey in pairs(all) do
		all[templateKey] = nil
	end
	selection = nil
	if self:IsShowingComp() then
		self:RefreshComp()
	end
end

function CurrentTemplateKey()
	if not currentRaid or not currentSize then
		return nil
	end
	return currentRaid .. "_" .. currentSize
end

----------------------------------------------------------------------------
-- Ready check - the footer's "Ready check" button starts a normal ready
-- check; this tracks the answers (also for checks someone else starts) and
-- flags each member on their slot card: ready, not ready, or AFK (never
-- answered before it timed out). Results stay up until the next check, or
-- until the button is right-clicked. Session-only.
----------------------------------------------------------------------------
-- [name] = "ready" | "notready" | "waiting" | "afk" | "offline"
local readyState = {}
local readyActive = false
local readyStartedAt = 0
local readyHasResult = false
local readyBtn

local READY_ICONS = {
	ready = "Interface\\RaidFrame\\ReadyCheck-Ready",
	notready = "Interface\\RaidFrame\\ReadyCheck-NotReady",
	waiting = "Interface\\RaidFrame\\ReadyCheck-Waiting",
	afk = "Interface\\RaidFrame\\ReadyCheck-NotReady",
	offline = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}
local READY_WORDS = { notready = "NOT READY", afk = "AFK", offline = "OFFLINE" }

-- Reads everyone's current answer from the client while a check is running.
local function ReadyPoll()
	for _, member in ipairs(RaidCompUI:ScanRoster()) do
		local status = GetReadyCheckStatus(member.unit)
		if status == "ready" or status == "notready" or status == "waiting" then
			if readyState[member.name] ~= "offline" then
				readyState[member.name] = status
			end
		end
	end
end

local function ReadyRefresh()
	if RaidCompUI:IsShowingComp() then
		RaidCompUI:RefreshComp()
	end
end

local function ReadyFinish()
	if not readyActive then
		return
	end
	pcall(ReadyPoll)
	readyActive = false
	-- Anyone who never answered is the AFK list.
	for name, status in pairs(readyState) do
		if status == "waiting" then
			readyState[name] = "afk"
		end
	end
	ReadyRefresh()
end

local function ReadyStart(starter)
	for name in pairs(readyState) do
		readyState[name] = nil
	end
	for _, member in ipairs(RaidCompUI:ScanRoster()) do
		if UnitIsConnected(member.unit) then
			readyState[member.name] = "waiting"
		else
			readyState[member.name] = "offline"
		end
	end
	-- Whoever starts a check counts as ready.
	if starter and readyState[starter] then
		readyState[starter] = "ready"
	end
	readyActive = true
	readyHasResult = true
	readyStartedAt = GetTime()
	ReadyRefresh()
end

local function ReadyClear()
	if readyActive then
		return
	end
	for name in pairs(readyState) do
		readyState[name] = nil
	end
	readyHasResult = false
	ReadyRefresh()
end

-- "Ready check: 8 ready, 1 not ready - AFK: Bob, Jim", or nil with no result.
local function ReadySummary(roster)
	if not readyHasResult then
		return nil
	end
	local ready, total = 0, 0
	local lists = { notready = {}, afk = {}, offline = {}, waiting = {} }
	for _, member in ipairs(roster) do
		local status = readyState[member.name]
		if status then
			total = total + 1
			if status == "ready" then
				ready = ready + 1
			elseif lists[status] then
				table.insert(lists[status], member.name)
			end
		end
	end
	if total == 0 then
		return nil
	end
	local text
	if readyActive then
		text = string.format("Ready check running: %d/%d ready", ready, total)
		if #lists.waiting > 0 then
			text = text .. " - waiting on " .. table.concat(lists.waiting, ", ")
		end
	else
		text = string.format("Ready check: %d/%d ready", ready, total)
		if #lists.afk > 0 then
			text = text .. " - AFK: " .. table.concat(lists.afk, ", ")
		end
	end
	if #lists.notready > 0 then
		text = text .. " - not ready: " .. table.concat(lists.notready, ", ")
	end
	if #lists.offline > 0 then
		text = text .. " - offline: " .. table.concat(lists.offline, ", ")
	end
	local allGood = (not readyActive) and ready == total
	return text, allGood
end

-- Footer button: left-click starts a check, right-click clears the flags.
local function OnReadyButton(mouseButton)
	if mouseButton == "RightButton" then
		ReadyClear()
		return
	end
	if readyActive then
		return
	end
	local inRaid = GetNumRaidMembers() > 0
	if not inRaid and GetNumPartyMembers() == 0 then
		DEFAULT_CHAT_FRAME:AddMessage("|cffb9e24aRaid Comp:|r you're not in a group, so there's nobody to ready check.")
		return
	end
	local allowed
	if inRaid then
		allowed = IsRaidLeader() or IsRaidOfficer()
	else
		allowed = IsPartyLeader()
	end
	if not allowed then
		DEFAULT_CHAT_FRAME:AddMessage("|cffb9e24aRaid Comp:|r only the leader or an assistant can start a ready check.")
		return
	end
	DoReadyCheck()
end

----------------------------------------------------------------------------
-- Quick kick - Alt+click a slot card or bench chip to remove that player, or
-- the footer's "Kick AFK (n)" button (shown after a ready check that left
-- people unanswered) to remove all of them. Always behind a confirm popup.
----------------------------------------------------------------------------
local kickBtn

local function CanKick()
	if GetNumRaidMembers() > 0 then
		return IsRaidLeader() or IsRaidOfficer()
	end
	return GetNumPartyMembers() > 0 and IsPartyLeader()
end

-- Roster members the last ready check left flagged AFK (never yourself).
local function ReadyAfkNames(roster)
	local names = {}
	if readyActive then
		return names
	end
	local me = UnitName("player")
	for _, member in ipairs(roster) do
		if readyState[member.name] == "afk" and member.name ~= me then
			table.insert(names, member.name)
		end
	end
	return names
end

StaticPopupDialogs["JOHNNYS_RAIDCOMP_KICK"] = {
	text = "Remove from the group?\n\n%s",
	button1 = "Remove",
	button2 = "Cancel",
	OnAccept = function(self, names)
		for _, name in ipairs(names or {}) do
			UninviteUnit(name)
			readyState[name] = nil
			gsChanged[name] = nil
		end
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

local function ConfirmKick(names)
	if not names or #names == 0 then
		return
	end
	if not CanKick() then
		DEFAULT_CHAT_FRAME:AddMessage("|cffb9e24aRaid Comp:|r only the leader or an assistant can remove players.")
		return
	end
	local me = UnitName("player")
	local list = {}
	for _, name in ipairs(names) do
		if name ~= me then
			table.insert(list, name)
		end
	end
	if #list == 0 then
		return
	end
	local dialog = StaticPopup_Show("JOHNNYS_RAIDCOMP_KICK", table.concat(list, ", "))
	if dialog then
		dialog.data = list
	end
end

local readyWatcher = CreateFrame("Frame")
readyWatcher:RegisterEvent("READY_CHECK")
readyWatcher:RegisterEvent("READY_CHECK_CONFIRM")
readyWatcher:RegisterEvent("READY_CHECK_FINISHED")
readyWatcher:SetScript("OnEvent", function(self, event, arg1)
	if event == "READY_CHECK" then
		-- Only the leader or an assistant can act on the result (kick the
		-- AFKs), so as a plain member a ready check is left alone entirely.
		if CanKick() then
			pcall(ReadyStart, arg1)
		end
	elseif event == "READY_CHECK_CONFIRM" then
		if readyActive then
			pcall(ReadyPoll)
			ReadyRefresh()
		end
	else
		ReadyFinish()
	end
end)
local readyElapsed = 0
readyWatcher:SetScript("OnUpdate", function(self, elapsed)
	if not readyActive then
		return
	end
	readyElapsed = readyElapsed + elapsed
	if readyElapsed < 0.5 then
		return
	end
	readyElapsed = 0
	pcall(ReadyPoll)
	-- A ready check lasts 30s; close it ourselves if the finish event is missed.
	if GetTime() - readyStartedAt > 40 then
		ReadyFinish()
	else
		ReadyRefresh()
	end
end)

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
	-- Alt+click: remove this player from the group (asks first).
	if IsAltKeyDown() then
		if matchedName then
			ConfirmKick({ matchedName })
		end
		return
	end
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
	-- Alt+click: remove this player from the group (asks first).
	if IsAltKeyDown() then
		ConfirmKick({ name })
		return
	end
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
	card.index = index
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

	card.label = Skin:Heading(card, 11, Skin.C.muted)
	card.label:SetPoint("TOP", 0, -6)
	card.label:SetWidth(CARD_WIDTH - 8)
	card.label:SetJustifyH("CENTER")

	card.nameText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.nameText:SetPoint("TOP", card.label, "BOTTOM", 0, -2)
	card.nameText:SetWidth(CARD_WIDTH - 8)
	card.nameText:SetJustifyH("CENTER")

	-- GearScore (see Inspect.lua) - blank/"GS --" until a
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

	-- Missing enchants / empty sockets, bottom-right: "2E 1G". The tooltip
	-- names the slots (see ShowGearScoreTooltip).
	card.gearBadge = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.gearBadge:SetPoint("BOTTOMRIGHT", -4, 5)
	card.gearBadge:SetTextColor(1, 0.85, 0.40)
	card.gearBadge:Hide()

	-- Ready-check flag (see the ready check section): icon bottom-left, plus
	-- a word beside it for anything that isn't a plain "ready".
	card.readyIcon = card:CreateTexture(nil, "OVERLAY")
	card.readyIcon:SetSize(14, 14)
	card.readyIcon:SetPoint("BOTTOMLEFT", 3, 3)
	card.readyIcon:Hide()
	card.readyWord = Skin:Heading(card, 10, Skin.C.short)
	card.readyWord:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 3, 19)
	card.readyWord:Hide()

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
		GameTooltip:SetText("Tank: advertise this class as its tank spec")
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
		GameTooltip:SetText("Healer: advertise this class as its healing spec")
		GameTooltip:Show()
	end)
	card.healerToggle:SetScript("OnLeave", GameTooltip_Hide)
	card.healerToggle:Hide()

	-- Corner arrow: opens the slot's menu to pin it to a class, or move a
	-- class slot to another role (see ShowSlotMenu). Not shown on a Class Run
	-- or with Class slots switched off (see SetCardState).
	card.menuBtn = CreateFrame("Button", nil, card)
	card.menuBtn:SetSize(16, 16)
	card.menuBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -2)
	card.menuBtn.arrow = card.menuBtn:CreateTexture(nil, "OVERLAY")
	card.menuBtn.arrow:SetSize(9, 8)
	card.menuBtn.arrow:SetPoint("CENTER")
	card.menuBtn.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
	card.menuBtn.arrow:SetVertexColor(Skin.C.muted[1], Skin.C.muted[2], Skin.C.muted[3])
	card.menuBtn:SetScript("OnClick", function() ShowSlotMenu(card) end)
	card.menuBtn:SetScript("OnEnter", function(self)
		self.arrow:SetVertexColor(Skin.C.accent[1], Skin.C.accent[2], Skin.C.accent[3])
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Choose this slot's class or role")
		GameTooltip:Show()
	end)
	card.menuBtn:SetScript("OnLeave", function(self)
		self.arrow:SetVertexColor(Skin.C.muted[1], Skin.C.muted[2], Skin.C.muted[3])
		GameTooltip:Hide()
	end)
	card.menuBtn:Hide()

	slotCards[index] = card
	return card
end

function SetCardState(card, slot, matchedName, matchedClass, isClassRun)
	card.slot = slot
	card.matchedName = matchedName
	card.label:SetText(string.upper(RaidCompUI:SlotLabel(CurrentTemplateKey(), slot)))

	if matchedName then
		card:SetBackdropColor(0.090, 0.114, 0.125, 0.95)
		card:SetBackdropBorderColor(Skin.C.accent[1], Skin.C.accent[2], Skin.C.accent[3], 1)
		card.label:SetTextColor(Skin.C.muted[1], Skin.C.muted[2], Skin.C.muted[3])
		card.nameText:SetTextColor(Skin.C.text[1], Skin.C.text[2], Skin.C.text[3])
		-- Amber "?" = placed by class guess only, not inspected yet (see ResolveUnitRole).
		local member = rosterByName[matchedName]
		local guessMark = (not isClassRun and member and member.roleGuessed) and " |cffffd966?|r" or ""
		card.nameText:SetText(FormatNameWithClass(matchedName, matchedClass) .. guessMark)

		-- pcall'd for the same reason as RefreshComp's RequestGearScore loop -
		-- this reads the GearScore cache and must never be able to
		-- break the card itself if something about that goes wrong.
		local ok = pcall(function()
			local gsText, r, g, b = FormatGearScoreText(matchedName)
			card.gsText:SetText(gsText)
			card.gsText:SetTextColor(r, g, b)
			card.gsText:Show()

			-- SetShown doesn't exist on this client - only Show()/Hide() do.
			local entry = JohnnysRaidComp.db.realm.raidCompGearScores[matchedName]
			if entry and entry.hasPvpGear then
				card.pvpBadge:Show()
			else
				card.pvpBadge:Hide()
			end

			local badge = RaidCompUI.GearIssueBadge(entry)
			if badge then
				card.gearBadge:SetText(badge)
				card.gearBadge:Show()
			else
				card.gearBadge:Hide()
			end
		end)
		if not ok then
			card.gsText:Hide()
			card.pvpBadge:Hide()
			card.gearBadge:Hide()
		end

		card.blacklistEntry = JohnnysBlackList and JohnnysBlackList.BlackListUI and JohnnysBlackList.BlackListUI:GetEntryByName(matchedName)
		if card.blacklistEntry then
			card:SetBackdropBorderColor(0.9, 0.15, 0.15, 1)
		end
	else
		card:SetBackdropColor(0.063, 0.078, 0.086, 0.8)
		card:SetBackdropBorderColor(0.180, 0.224, 0.243, 1)
		card.label:SetTextColor(Skin.C.dim[1], Skin.C.dim[2], Skin.C.dim[3])
		card.nameText:SetTextColor(Skin.C.dim[1], Skin.C.dim[2], Skin.C.dim[3])
		card.nameText:SetText("open")
		card.gsText:Hide()
		card.pvpBadge:Hide()
		card.gearBadge:Hide()
		card.blacklistEntry = nil
	end

	local readyStatus = matchedName and readyState[matchedName]
	if readyStatus and READY_ICONS[readyStatus] then
		card.readyIcon:SetTexture(READY_ICONS[readyStatus])
		card.readyIcon:Show()
		local word = READY_WORDS[readyStatus]
		if word then
			card.readyWord:SetText(word)
			if readyStatus == "afk" then
				card.readyWord:SetTextColor(1, 0.85, 0.40)
				card:SetBackdropBorderColor(1, 0.85, 0.40, 1)
			else
				card.readyWord:SetTextColor(Skin.C.short[1], Skin.C.short[2], Skin.C.short[3])
				card:SetBackdropBorderColor(Skin.C.short[1], Skin.C.short[2], Skin.C.short[3], 1)
			end
			card.readyWord:Show()
		else
			card.readyWord:Hide()
		end
	else
		card.readyIcon:Hide()
		card.readyWord:Hide()
	end

	-- A class slot's label wears its class colour (dimmer while empty) so the
	-- pinned slots stand out from the "Any" ones.
	local classColor = (not isClassRun) and slot.class and RAID_CLASS_COLORS[slot.class]
	if classColor then
		local k = matchedName and 1 or 0.8
		card.label:SetTextColor(classColor.r * k, classColor.g * k, classColor.b * k)
	end

	if not isClassRun and JohnnysRaidComp.db.profile.raidCompClassPins ~= false then
		card.menuBtn:Show()
	else
		card.menuBtn:Hide()
	end

	-- Tank toggle only makes sense on a filled Class Run slot for a class
	-- that actually has a tank spec (see CLASS_RUN_TANK_CAPABLE) - regular
	-- raid+size slots already track TANK/HEALER/DAMAGER via the real role
	-- icon, so the manual marker would be redundant there.
	if isClassRun and RaidCompUI.CLASS_RUN_TANK_CAPABLE[slot.class] then
		local templateKey = CurrentTemplateKey()
		card.tankToggle:SetChecked(templateKey and JohnnysRaidComp.db.profile.raidCompClassRunTank[templateKey] == slot.class)
		card.tankToggle:Show()
	else
		card.tankToggle:Hide()
	end

	if isClassRun and RaidCompUI.CLASS_RUN_HEALER_CAPABLE[slot.class] then
		local templateKey = CurrentTemplateKey()
		local healerSet = templateKey and JohnnysRaidComp.db.profile.raidCompClassRunHealers[templateKey]
		card.healerToggle:SetChecked(healerSet and healerSet[slot.class])
		card.healerToggle:Show()
	else
		card.healerToggle:Hide()
	end

	if selection and selection.kind == "slot" and slotCards[selection.value] == card then
		card:SetBackdropBorderColor(1, 1, 1, 1)
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

	-- Compact GearScore (see Inspect.lua) - "--" until a lookup
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
	local member = rosterByName[name]
	local guessMark = (currentSize ~= "CLASSRUN" and member and member.roleGuessed) and " |cffffd966?|r" or ""
	chip.nameText:SetText(FormatNameWithClass(name, class) .. guessMark)
	chip:SetBackdropColor(0.090, 0.114, 0.125, 0.6)
	chip:SetBackdropBorderColor(Skin.C.rule2[1], Skin.C.rule2[2], Skin.C.rule2[3], 1)
	chip.nameText:SetTextColor(1, 0.9, 0.6)

	-- pcall'd for the same reason as SetCardState's GS lookup - must never be
	-- able to break the chip itself if something about that goes wrong.
	local ok = pcall(function()
		local gsText, r, g, b = FormatCompactGearScoreText(name)
		local entry = JohnnysRaidComp.db.realm.raidCompGearScores[name]
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
		chip:SetBackdropBorderColor(1, 1, 1, 1)
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
	local cache = JohnnysRaidComp.db.realm.raidCompGearScores
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
	fs:SetText(string.format("%s  %d/%d", string.upper(label), have, needed))
	local color = (have >= needed) and Skin.C.accent or Skin.C.short
	fs:SetTextColor(color[1], color[2], color[3])
end

-- Resize to `height` (clamped) without moving the window - SetHeight keeps
-- the frame's anchor point, so a CENTER-anchored window just grows/shrinks
-- evenly about its middle. RefreshComp calls this so the window is only ever
-- as tall as the current raid's grid (and bench) needs.
local function SetFrameHeight(height)
	if not mainFrame then
		return
	end
	local railMin = Skin.HEADER_HEIGHT + railNeededHeight + 2
	mainFrame:SetHeight(math.max(MIN_FRAME_HEIGHT, railMin, math.floor(height + 0.5)))
end

-- Widgets of the single-screen layout that RefreshComp repaints (built in
-- BuildCompPage further down).
local needLabel, needText, gsSummaryText, hintText, reportVHBtn

-- The grid is drawn as one labelled section per role, in template order
-- (BuildTemplate emits tanks, then healers, then DPS), so slot indices - which
-- manual swaps are saved against - keep their meaning.
local SECTIONS = {
	{ role = "TANK", key = "tank", label = "Tanks" },
	{ role = "HEALER", key = "healer", label = "Healers" },
	{ role = "DAMAGER", key = "dps", label = "DPS" },
}

local IDLE_HINT = "Click two slots to swap. Right-click: undo. Alt+click: kick. Corner arrow: class or role."

-- Positions slot card `index` as the n-th card of a section whose first row
-- starts at `y` (relative to compPage's top), and paints its state.
local function PlaceCard(index, slot, n, y, matches, classByName, isClassRun)
	local card = EnsureSlotCard(index)
	local col = (n - 1) % COLUMNS
	local row = math.floor((n - 1) / COLUMNS)
	card:ClearAllPoints()
	card:SetPoint("TOPLEFT", compPage, "TOPLEFT", col * (CARD_WIDTH + CARD_GAP), y - row * (CARD_HEIGHT + CARD_GAP))
	local matchedName = matches[slot]
	SetCardState(card, slot, matchedName, matchedName and classByName[matchedName], isClassRun)
	card:Show()
end

-- "STILL NEED 1 healer, 3 DPS" from the slots nobody is in, plus the roster's
-- average / lowest cached GearScore on the right of the same bar.
local function RefreshNeedBar(template, matches, roster)
	local C = Skin.C
	local empty = { TANK = 0, HEALER = 0, DAMAGER = 0 }
	local parts = {}
	local emptyClasses = {}
	for _, slot in ipairs(template.slots) do
		if not matches[slot] then
			if slot.role then
				empty[slot.role] = empty[slot.role] + 1
			else
				table.insert(emptyClasses, RaidCompUI:SlotLabel(CurrentTemplateKey(), slot))
			end
		end
	end
	if empty.TANK > 0 then
		table.insert(parts, empty.TANK .. (empty.TANK == 1 and " tank" or " tanks"))
	end
	if empty.HEALER > 0 then
		table.insert(parts, empty.HEALER .. (empty.HEALER == 1 and " healer" or " healers"))
	end
	if empty.DAMAGER > 0 then
		table.insert(parts, empty.DAMAGER .. " DPS")
	end
	for _, label in ipairs(emptyClasses) do
		table.insert(parts, label)
	end

	if #parts > 0 then
		needLabel:SetText("STILL NEED")
		needLabel:SetTextColor(C.short[1], C.short[2], C.short[3])
		needText:SetText(table.concat(parts, ", "))
	else
		needLabel:SetText("RAID FULL")
		needLabel:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
		needText:SetText("Every slot is filled.")
	end

	local cache = JohnnysRaidComp.db.realm.raidCompGearScores
	local total, count, lowScore, lowName = 0, 0, nil, nil
	for _, member in ipairs(roster) do
		local entry = cache and cache[member.name]
		local score = entry and tonumber(entry.score)
		if score then
			total = total + score
			count = count + 1
			if not lowScore or score < lowScore then
				lowScore, lowName = score, member.name
			end
		end
	end
	if count > 0 then
		gsSummaryText:SetText(string.format("AVG GS %d    LOWEST %d %s", math.floor(total / count + 0.5), lowScore, lowName))
	else
		gsSummaryText:SetText("")
	end
end

-- Footer hint: what the next click will do while something is selected,
-- otherwise the short how-to.
local function RefreshHint(template, roster)
	local C = Skin.C
	if not selection then
		local okSummary, summary, allGood = pcall(ReadySummary, roster or {})
		if okSummary and summary then
			hintText:SetText(summary)
			if allGood then
				hintText:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
			else
				hintText:SetTextColor(1, 0.85, 0.40)
			end
			return
		end
		hintText:SetText(IDLE_HINT)
		hintText:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
		return
	end
	hintText:SetTextColor(C.text[1], C.text[2], C.text[3])
	if selection.kind == "bench" then
		hintText:SetText("Click a slot to place " .. selection.value .. " there, or click them again to cancel.")
	else
		local slot = template.slots[selection.value]
		local name = slot and currentMatches[slot]
		if name then
			hintText:SetText("Click another slot to swap with " .. name .. ", or the same slot to cancel.")
		else
			hintText:SetText("Click a filled slot or a benched player to put them here.")
		end
	end
end

----------------------------------------------------------------------------
-- Refresh - rescans the roster, recomputes matches, and repaints the role
-- sections, bench, need bar and footer for the currently selected raid+size.
----------------------------------------------------------------------------
function RaidCompUI:RefreshComp()
	if not currentRaid or not currentSize then
		return
	end

	local templateKey = currentRaid .. "_" .. currentSize
	local template = RaidCompUI.TEMPLATES[templateKey]
	local roster = self:ScanRoster()
	rosterByName = {}
	for _, member in ipairs(roster) do
		rosterByName[member.name] = member
	end
	local matches, have, overflow = self:BuildMatches(templateKey, roster)
	currentMatches = matches

	-- Kick off/refresh a GearScore+PVP-gear lookup for everyone currently
	-- shown (slotted or benched) - see Inspect.lua. No-ops
	-- for anyone already fresh or already queued. pcall'd as a hard boundary -
	-- inspect/item-cache reads can fail in odd ways, and they must never be
	-- able to take the actual comp grid down with it.
	local ok, err = pcall(function()
		for _, member in ipairs(roster) do
			self:RequestGearScore(member.name, member.unit)
			-- Separate queue (see Achievements.lua) - no-ops if
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

	-- y walks down compPage as each section is laid out.
	local y = GRID_TOP

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
		headerText.classRun:SetText(string.format("CLASSES REPRESENTED  %d/%d", filled, #template.slots))
		local color = (filled >= #template.slots) and Skin.C.accent or Skin.C.short
		headerText.classRun:SetTextColor(color[1], color[2], color[3])
		headerText.classRun:ClearAllPoints()
		headerText.classRun:SetPoint("TOPLEFT", compPage, "TOPLEFT", 0, y - 4)
		headerText.classRun:Show()
		y = y - SECTION_HEAD

		for i, slot in ipairs(template.slots) do
			PlaceCard(i, slot, i, y, matches, classByName, true)
		end
		y = y - math.ceil(#template.slots / COLUMNS) * (CARD_HEIGHT + CARD_GAP)
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

		for _, section in ipairs(SECTIONS) do
			local header = headerText[section.key]
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", compPage, "TOPLEFT", 0, y - 4)
			y = y - SECTION_HEAD

			local n = 0
			for i, slot in ipairs(template.slots) do
				if slot.role == section.role then
					n = n + 1
					PlaceCard(i, slot, n, y, matches, classByName, false)
				end
			end
			if n > 0 then
				y = y - math.ceil(n / COLUMNS) * (CARD_HEIGHT + CARD_GAP)
			end
			y = y - SECTION_GAP
		end
	end

	for i = #template.slots + 1, #slotCards do
		slotCards[i]:Hide()
	end

	-- Bench - anyone BuildMatches couldn't place, rendered below the last
	-- section so nobody who didn't fit the template just disappears.
	if #overflow > 0 then
		local benchTop = y - 4
		benchLabel:ClearAllPoints()
		benchLabel:SetPoint("TOPLEFT", compPage, "TOPLEFT", 0, benchTop)
		benchLabel:SetText(string.format("BENCH  %d", #overflow))
		benchLabel:Show()

		for i, member in ipairs(overflow) do
			local chip = EnsureBenchChip(i)
			local col = (i - 1) % BENCH_COLUMNS
			local row = math.floor((i - 1) / BENCH_COLUMNS)
			chip:ClearAllPoints()
			chip:SetPoint("TOPLEFT", compPage, "TOPLEFT", col * (BENCH_CHIP_WIDTH + BENCH_GAP), benchTop - 20 - row * (BENCH_CHIP_HEIGHT + BENCH_GAP))
			SetBenchChipState(chip, member.name, member.class)
			chip:Show()
		end

		local benchRows = math.ceil(#overflow / BENCH_COLUMNS)
		y = benchTop - 20 - benchRows * (BENCH_CHIP_HEIGHT + BENCH_GAP)
	else
		benchLabel:Hide()
	end

	for i = #overflow + 1, #benchChips do
		benchChips[i]:Hide()
	end

	-- pcall'd like the GearScore reads above - these only decorate the
	-- window and must never be able to break the grid.
	pcall(RefreshNeedBar, template, matches, roster)
	RefreshHint(template, roster)
	if kickBtn then
		local afk = ReadyAfkNames(roster)
		if #afk > 0 then
			kickBtn.text:SetText(string.format("Kick AFK (%d)", #afk))
			kickBtn:Show()
		else
			kickBtn:Hide()
		end
	end
	if readyBtn then
		readyBtn.text:SetText(readyActive and "Checking..." or "Ready check")
		-- Only the leader or an assistant can start one.
		if CanKick() then
			readyBtn:Show()
		else
			readyBtn:Hide()
		end
	end

	local okNames, names = pcall(self.GetUninspectedNames, self)
	local uninspected = (okNames and names) and #names or 0
	if uninspected > 0 then
		reportVHBtn.text:SetText(string.format("Ping %d uninspected to VH", uninspected))
		reportVHBtn.text:SetTextColor(Skin.C.text[1], Skin.C.text[2], Skin.C.text[3])
		reportVHBtn:Enable()
	else
		reportVHBtn.text:SetText("Everyone inspected")
		reportVHBtn.text:SetTextColor(Skin.C.dim[1], Skin.C.dim[2], Skin.C.dim[3])
		reportVHBtn:Disable()
	end

	-- Window = title strip + top inset + everything laid out above + the
	-- footer button strip + bottom margin.
	SetFrameHeight(Skin.HEADER_HEIGHT + PAGE_TOP_INSET + (-y) + 18 + FOOTER_HEIGHT + PAGE_BOTTOM_INSET)
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

----------------------------------------------------------------------------
-- Class-slot editing - each slot card's corner arrow opens a menu to pin the
-- slot to a class (or back to "Any"), or to move a class slot to another role
-- it can play: moving the Shaman slot to Healers turns one "Any Healer" into
-- "Shaman" and leaves an "Any DPS" behind, so the headcounts never change.
-- Saved per raid+size in profile.raidCompClassSlots.
----------------------------------------------------------------------------
local slotMenuFrame

-- This raid+size's editable class-slot lists, seeded from the built-in picks
-- the first time anything is changed.
local function EditableClassSlots(templateKey)
	local all = JohnnysRaidComp.db.profile.raidCompClassSlots
	local pins = all[templateKey]
	if not pins then
		pins = RaidCompUI:GetDefaultClassSlots(currentRaid, currentSize)
		all[templateKey] = pins
	end
	pins.TANK = pins.TANK or {}
	pins.HEALER = pins.HEALER or {}
	pins.DAMAGER = pins.DAMAGER or {}
	return pins
end

-- Rebuilds the open template after a class-slot edit. Slot positions shift
-- when a class slot is added/moved, so manual placements are carried over by
-- player instead of by position: each goes back into a slot of the same role,
-- preferring one pinned to their class.
local function RebuildKeepingPlacements(templateKey)
	local old = RaidCompUI.TEMPLATES[templateKey]
	local allOverrides = JohnnysRaidComp.db.profile.raidCompManualAssignments
	local overrides = allOverrides[templateKey]
	local kept = {}
	if old and overrides then
		for i, slot in ipairs(old.slots) do
			if type(overrides[i]) == "string" then
				table.insert(kept, { name = overrides[i], role = slot.role })
			end
		end
	end

	RaidCompUI:RebuildTemplate(currentRaid, currentSize)

	local fresh
	if #kept > 0 then
		local template = RaidCompUI.TEMPLATES[templateKey]
		local classByName = {}
		for _, member in ipairs(RaidCompUI:ScanRoster()) do
			classByName[member.name] = member.class
		end
		fresh = {}
		for pass = 1, 2 do
			for _, entry in ipairs(kept) do
				if not entry.done then
					for i, slot in ipairs(template.slots) do
						local fits
						if pass == 1 then
							fits = slot.class and slot.class == classByName[entry.name]
						else
							fits = not slot.class
						end
						if fresh[i] == nil and slot.role == entry.role and fits then
							fresh[i] = entry.name
							entry.done = true
							break
						end
					end
				end
			end
		end
	end
	allOverrides[templateKey] = fresh

	ClearSelection()
	RaidCompUI:RefreshComp()
end

-- Pins the slot to `class`, or back to "Any" with class == nil.
local function SetSlotClass(slot, class)
	local templateKey = CurrentTemplateKey()
	if not templateKey or not slot or not slot.role or slot.class == class then
		return
	end
	local list = EditableClassSlots(templateKey)[slot.role]
	if slot.pinIndex then
		if class then
			list[slot.pinIndex] = class
		else
			table.remove(list, slot.pinIndex)
		end
	elseif class then
		table.insert(list, class)
	end
	RebuildKeepingPlacements(templateKey)
end

-- True when `role` still has an "Any" slot a class slot could take over.
local function RoleHasRoom(templateKey, role)
	local template = RaidCompUI.TEMPLATES[templateKey]
	if not template then
		return false
	end
	for _, slot in ipairs(template.slots) do
		if slot.role == role and not slot.class then
			return true
		end
	end
	return false
end

-- Moves a class slot to another role: it replaces one of that role's "Any"
-- slots and its old slot becomes an "Any" of the role it left.
local function MoveSlotRole(slot, newRole)
	local templateKey = CurrentTemplateKey()
	if not templateKey or not slot or not slot.class or not slot.pinIndex or slot.role == newRole then
		return
	end
	if not RoleHasRoom(templateKey, newRole) then
		return
	end
	local pins = EditableClassSlots(templateKey)
	table.remove(pins[slot.role], slot.pinIndex)
	table.insert(pins[newRole], slot.class)
	RebuildKeepingPlacements(templateKey)
end

-- Back to the raid's built-in class slots.
local function ResetClassSlots()
	local templateKey = CurrentTemplateKey()
	if not templateKey or currentSize == "CLASSRUN" then
		return
	end
	JohnnysRaidComp.db.profile.raidCompClassSlots[templateKey] = nil
	RebuildKeepingPlacements(templateKey)
end

local ROLE_MENU_NAMES = { TANK = "Tanks", HEALER = "Healers", DAMAGER = "DPS" }
local ROLE_MENU_ORDER = { "TANK", "HEALER", "DAMAGER" }

function ShowSlotMenu(card)
	local slot = card and card.slot
	local templateKey = CurrentTemplateKey()
	if not slot or not slot.role or not templateKey or currentSize == "CLASSRUN" then
		return
	end
	if not slotMenuFrame then
		slotMenuFrame = CreateFrame("Frame", "JohnnysRaidCompSlotMenu", UIParent, "UIDropDownMenuTemplate")
	end

	local menu = {}
	if slot.class then
		table.insert(menu, { text = "Move this " .. slot.label .. " slot to", isTitle = true, notCheckable = true })
		for _, role in ipairs(ROLE_MENU_ORDER) do
			if RaidCompUI.ROLE_CLASSES[role][slot.class] then
				local target = role
				local isCurrent = (role == slot.role)
				local hasRoom = isCurrent or RoleHasRoom(templateKey, role)
				table.insert(menu, {
					text = ROLE_MENU_NAMES[role] .. ((not hasRoom) and "  (no free slot)" or ""),
					checked = isCurrent,
					disabled = not hasRoom,
					func = function() MoveSlotRole(slot, target) end,
				})
			end
		end
	end

	table.insert(menu, { text = "Class for this slot", isTitle = true, notCheckable = true })
	table.insert(menu, {
		text = "Any class",
		checked = not slot.class,
		func = function() SetSlotClass(slot, nil) end,
	})
	for _, class in ipairs(RaidCompUI.CLASS_ORDER) do
		if RaidCompUI.ROLE_CLASSES[slot.role][class] then
			local pick = class
			local color = RAID_CLASS_COLORS[class]
			local label = RaidCompUI.CLASS_LABELS[class]
			if color then
				label = string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, label)
			end
			table.insert(menu, {
				text = label,
				checked = (slot.class == class),
				func = function() SetSlotClass(slot, pick) end,
			})
		end
	end

	table.insert(menu, { text = " ", isTitle = true, notCheckable = true })
	table.insert(menu, {
		text = "Reset this raid's class slots",
		notCheckable = true,
		func = ResetClassSlots,
	})

	EasyMenu(menu, slotMenuFrame, "cursor", 0, 0, "MENU")
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
-- Raid / size selection - one screen: the raid rail on the left and the size
-- toggles across the top are always visible, so changing either is a single
-- click (there are no separate picker pages or Back buttons any more).
----------------------------------------------------------------------------
local raidButtons = {}

-- Lime border + lighter fill for the active size toggle.
local function SetToggleSelected(btn, selected)
	local C = Skin.C
	if selected then
		btn:SetBackdropColor(0.122, 0.153, 0.169, 0.95)
		btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
		btn.text:SetTextColor(C.text[1], C.text[2], C.text[3])
	else
		btn:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 0.95)
		btn:SetBackdropBorderColor(C.rule2[1], C.rule2[2], C.rule2[3], 1)
		btn.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
	end
end

-- Repaints the rail highlight and rebuilds the size toggles for currentRaid.
local function RefreshSelectors()
	local C = Skin.C
	for raidKey, btn in pairs(raidButtons) do
		if raidKey == currentRaid then
			btn.bg:Show()
			btn.bar:Show()
			btn.num:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
			btn.text:SetTextColor(C.text[1], C.text[2], C.text[3])
		else
			btn.bg:Hide()
			btn.bar:Hide()
			btn.num:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
			btn.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
		end
	end

	for _, btn in ipairs(sizeListButtons) do
		btn:Hide()
	end
	local raidKey = currentRaid
	local sizes = RaidCompUI.RAID_SIZE_ORDER[raidKey] or {}
	local x = 0
	for i, sizeKey in ipairs(sizes) do
		local btn = sizeListButtons[i]
		if not btn then
			btn = Skin:CreateButton(compPage, SIZE_BUTTON_WIDTH, SIZE_BUTTON_HEIGHT, "")
			sizeListButtons[i] = btn
		end
		btn.text:SetText(RaidCompUI.SIZE_LABELS[sizeKey])
		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", compPage, "TOPLEFT", x, 0)
		btn:SetScript("OnClick", function() RaidCompUI:ShowComp(raidKey, sizeKey) end)
		-- StyleButton's own OnMouseUp repaints the idle fill, so re-apply the
		-- selected look after it.
		btn:SetScript("OnMouseUp", function(self) SetToggleSelected(self, sizeKey == currentSize) end)
		SetToggleSelected(btn, sizeKey == currentSize)
		btn:Show()
		x = x + SIZE_BUTTON_WIDTH + SIZE_GAP
	end

	if RaidCompUI.CLASS_RUN_RAIDS[raidKey] then
		classRunEntryButton:ClearAllPoints()
		classRunEntryButton:SetPoint("TOPLEFT", compPage, "TOPLEFT", x, 0)
		classRunEntryButton:SetScript("OnClick", function() RaidCompUI:ShowClassRunComp(raidKey) end)
		classRunEntryButton:SetScript("OnMouseUp", function(self) SetToggleSelected(self, currentSize == "CLASSRUN") end)
		SetToggleSelected(classRunEntryButton, currentSize == "CLASSRUN")
		classRunEntryButton:Show()
	else
		classRunEntryButton:Hide()
	end
end

function RaidCompUI:ShowComp(raidKey, sizeKey)
	currentRaid, currentSize = raidKey, sizeKey
	JohnnysRaidComp.db.profile.raidCompSelectedRaid = raidKey
	JohnnysRaidComp.db.profile.raidCompSelectedSize = sizeKey
	ClearSelection()
	self:RebuildTemplate(raidKey, sizeKey)

	mainFrame.title:SetText(string.upper(RaidCompUI.RAID_LABELS[raidKey] .. "  /  " .. RaidCompUI.SIZE_LABELS[sizeKey]))
	RefreshSelectors()
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
	ClearSelection()

	mainFrame.title:SetText(string.upper(RaidCompUI.RAID_LABELS[raidKey]) .. "  /  CLASS RUN (ONE OF EACH CLASS)")
	RefreshSelectors()
	self:RefreshComp()
end

-- Rail click: switch raid but keep the size you were on where the new raid
-- has it (25-Man Heroic falls back to 25-Man on raids with no heroic mode).
local function SelectRaid(raidKey)
	local size = currentSize
	if size == "CLASSRUN" and RaidCompUI.CLASS_RUN_RAIDS[raidKey] then
		RaidCompUI:ShowClassRunComp(raidKey)
		return
	end

	local sizes = RaidCompUI.RAID_SIZE_ORDER[raidKey]
	local function Has(key)
		for _, sizeKey in ipairs(sizes) do
			if sizeKey == key then
				return true
			end
		end
		return false
	end
	if not size or not Has(size) then
		local plain = size and (string.gsub(size, "H$", ""))
		size = (plain and Has(plain)) and plain or sizes[1]
	end
	RaidCompUI:ShowComp(raidKey, size)
end

----------------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------------
local function SavePosition()
	local point, _, relativePoint, x, y = mainFrame:GetPoint()
	local pos = JohnnysRaidComp.db.profile.raidCompPanelPosition
	pos.point, pos.relativePoint, pos.x, pos.y = point, relativePoint, x, y
end

-- Turns a Skin button into the one filled lime "main action" of a view.
local function MakePrimary(btn)
	local C = Skin.C
	local function Idle()
		btn:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 1)
	end
	btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
	btn.text:SetTextColor(C.ground[1], C.ground[2], C.ground[3])
	btn:SetScript("OnMouseDown", function()
		btn:SetBackdropColor(0.580, 0.710, 0.230, 1)
	end)
	btn:SetScript("OnMouseUp", Idle)
	Idle()
end

-- Left rail: one collapsible group per expansion (Data.lua's RAID_GROUPS),
-- each a clickable heading over numbered raid rows, with a lime bar + number
-- on the active raid. Folded groups are remembered (raidCompRailCollapsed).
local railGroups = {}
local RAIL_GROUP_HEIGHT = 24

-- Stacks the group headings and the rows of whichever groups are open, and
-- records how tall the rail now needs to be (see SetFrameHeight).
local function LayoutRail()
	local collapsed = JohnnysRaidComp.db.profile.raidCompRailCollapsed
	local y = 4
	for _, entry in ipairs(railGroups) do
		local isCollapsed = collapsed[entry.group.key] and true or false
		entry.header:ClearAllPoints()
		entry.header:SetPoint("TOPLEFT", 0, -y)
		entry.header.sign:SetText(isCollapsed and "+" or "-")
		y = y + RAIL_GROUP_HEIGHT
		for _, btn in ipairs(entry.rows) do
			if isCollapsed then
				btn:Hide()
			else
				btn:ClearAllPoints()
				btn:SetPoint("TOPLEFT", 0, -y)
				btn:Show()
				y = y + RAIL_ROW_HEIGHT
			end
		end
		y = y + 4
	end
	railNeededHeight = y + 6
end

local function BuildRail()
	local C = Skin.C
	local rail = CreateFrame("Frame", nil, mainFrame)
	rail:SetPoint("TOPLEFT", 1, -(Skin.HEADER_HEIGHT + 1))
	rail:SetPoint("BOTTOMLEFT", 1, 1)
	rail:SetWidth(RAIL_WIDTH)

	local bg = Skin:Solid(rail, "BACKGROUND", C.panel)
	bg:SetAllPoints()

	local divider = Skin:Solid(rail, "BORDER", C.rule)
	divider:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, 0)
	divider:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", 0, 0)
	divider:SetWidth(1)

	for _, group in ipairs(RaidCompUI.RAID_GROUPS) do
		local entry = { group = group, rows = {} }

		local header = CreateFrame("Button", nil, rail)
		header:SetSize(RAIL_WIDTH - 1, RAIL_GROUP_HEIGHT)
		local headerHl = header:CreateTexture(nil, "HIGHLIGHT")
		headerHl:SetAllPoints()
		headerHl:SetTexture(Skin.WHITE)
		headerHl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.08)
		header.label = Skin:Heading(header, 11, C.muted)
		header.label:SetPoint("LEFT", header, "LEFT", 12, 0)
		header.label:SetText(string.upper(group.label))
		header.sign = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		header.sign:SetPoint("RIGHT", header, "RIGHT", -10, 0)
		header.sign:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
		header:SetScript("OnClick", function()
			local collapsed = JohnnysRaidComp.db.profile.raidCompRailCollapsed
			collapsed[group.key] = not collapsed[group.key]
			LayoutRail()
			-- Re-fits the window height to the rail's new length.
			RaidCompUI:RefreshComp()
		end)
		entry.header = header

		for i, raidKey in ipairs(group.raids) do
			local btn = CreateFrame("Button", nil, rail)
			btn:SetSize(RAIL_WIDTH - 1, RAIL_ROW_HEIGHT)

			btn.bg = btn:CreateTexture(nil, "BORDER")
			btn.bg:SetAllPoints()
			btn.bg:SetTexture(Skin.WHITE)
			btn.bg:SetVertexColor(0.122, 0.153, 0.169, 1)
			btn.bg:Hide()

			local hl = btn:CreateTexture(nil, "HIGHLIGHT")
			hl:SetAllPoints()
			hl:SetTexture(Skin.WHITE)
			hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.10)

			btn.bar = Skin:Solid(btn, "ARTWORK", C.accent)
			btn.bar:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
			btn.bar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
			btn.bar:SetWidth(2)
			btn.bar:Hide()

			btn.num = Skin:Heading(btn, 14, C.dim)
			btn.num:SetPoint("LEFT", btn, "LEFT", 12, 0)
			btn.num:SetText(string.format("%02d", i))

			btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			btn.text:SetPoint("LEFT", btn, "LEFT", 36, 0)
			btn.text:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
			btn.text:SetJustifyH("LEFT")
			btn.text:SetText(RaidCompUI.RAID_LABELS[raidKey])

			btn:SetScript("OnClick", function() SelectRaid(raidKey) end)
			raidButtons[raidKey] = btn
			table.insert(entry.rows, btn)
		end

		table.insert(railGroups, entry)
	end

	LayoutRail()
end

local function BuildCompPage()
	local C = Skin.C
	compPage = CreateFrame("Frame", nil, mainFrame)
	compPage:SetPoint("TOPLEFT", RAIL_WIDTH + 12, -(Skin.HEADER_HEIGHT + PAGE_TOP_INSET))
	compPage:SetPoint("BOTTOMRIGHT", -12, PAGE_BOTTOM_INSET)

	-- Top row: size toggles on the left (pooled, see RefreshSelectors) and the
	-- template options on the right.
	classRunEntryButton = Skin:CreateButton(compPage, 90, SIZE_BUTTON_HEIGHT, "Class Run")
	classRunEntryButton:Hide()

	countControls.reset = Skin:CreateButton(compPage, 60, SIZE_BUTTON_HEIGHT, "Reset")
	countControls.reset:SetPoint("TOPRIGHT", compPage, "TOPRIGHT", 0, 0)
	countControls.reset:SetScript("OnClick", function() ResetCounts() end)

	-- Lives in countControls so Class Run hides it along with the +/- (see
	-- RefreshComp) - a Class Run is nothing but class slots.
	countControls.classPins = Skin:CreateButton(compPage, 110, SIZE_BUTTON_HEIGHT,
		JohnnysRaidComp.db.profile.raidCompClassPins and "Class slots: On" or "Class slots: Off")
	countControls.classPins:SetPoint("RIGHT", countControls.reset, "LEFT", -6, 0)
	countControls.classPins:SetScript("OnClick", ToggleClassPins)

	-- Need bar: what's still missing, the roster's GearScore summary, and a
	-- shortcut to the Raid Spammer (whose {need} token reads this same comp).
	local needBar = CreateFrame("Frame", nil, compPage)
	needBar:SetPoint("TOPLEFT", compPage, "TOPLEFT", 0, -NEED_BAR_TOP)
	needBar:SetPoint("TOPRIGHT", compPage, "TOPRIGHT", 0, -NEED_BAR_TOP)
	needBar:SetHeight(24)
	Skin:StylePanel(needBar, 1)
	needBar:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 1)

	needLabel = Skin:Heading(needBar, 12, C.short)
	needLabel:SetPoint("LEFT", needBar, "LEFT", 8, 0)

	needText = needBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	needText:SetPoint("LEFT", needLabel, "RIGHT", 8, 0)
	needText:SetTextColor(C.text[1], C.text[2], C.text[3])

	local lfmBtn = Skin:CreateButton(needBar, 84, 18, "Open LFM")
	lfmBtn:SetPoint("RIGHT", needBar, "RIGHT", -3, 0)
	lfmBtn:SetScript("OnClick", function()
		local spamFrame = _G["JohnnysAddonHubRaidSpamFrame"]
		if spamFrame and spamFrame:IsShown() then
			return
		end
		if JohnnysRaidSpam and JohnnysRaidSpam.RaidSpamUI then
			JohnnysRaidSpam.RaidSpamUI:Toggle()
		end
	end)
	MakePrimary(lfmBtn)

	gsSummaryText = Skin:Heading(needBar, 11, C.muted)
	gsSummaryText:SetPoint("RIGHT", lfmBtn, "LEFT", -10, 0)

	-- Section headings. Positioned each refresh (see RefreshComp); the +/-
	-- pairs hang off their heading's right edge so they follow it.
	headerText.tank = Skin:Heading(compPage, 13)
	countControls.tankMinus = Skin:CreateButton(compPage, 18, 18, "-")
	countControls.tankMinus:SetPoint("LEFT", headerText.tank, "RIGHT", 10, 0)
	countControls.tankMinus:SetScript("OnClick", function() AdjustCount("TANK", -1) end)
	countControls.tankPlus = Skin:CreateButton(compPage, 18, 18, "+")
	countControls.tankPlus:SetPoint("LEFT", countControls.tankMinus, "RIGHT", 2, 0)
	countControls.tankPlus:SetScript("OnClick", function() AdjustCount("TANK", 1) end)

	headerText.healer = Skin:Heading(compPage, 13)
	countControls.healerMinus = Skin:CreateButton(compPage, 18, 18, "-")
	countControls.healerMinus:SetPoint("LEFT", headerText.healer, "RIGHT", 10, 0)
	countControls.healerMinus:SetScript("OnClick", function() AdjustCount("HEALER", -1) end)
	countControls.healerPlus = Skin:CreateButton(compPage, 18, 18, "+")
	countControls.healerPlus:SetPoint("LEFT", countControls.healerMinus, "RIGHT", 2, 0)
	countControls.healerPlus:SetScript("OnClick", function() AdjustCount("HEALER", 1) end)

	-- DPS has no +/- of its own - it's always the remainder after
	-- Tanks/Healers are set (see AdjustCount), so there's nothing to click.
	headerText.dps = Skin:Heading(compPage, 13)

	-- Class Run's single "CLASSES REPRESENTED X/10" heading, shown instead of
	-- the three role headings (see RefreshComp).
	headerText.classRun = Skin:Heading(compPage, 13)
	headerText.classRun:Hide()

	-- Positioned dynamically each refresh (see RefreshComp) since it sits
	-- right below the last section.
	benchLabel = Skin:Heading(compPage, 13, C.muted)
	benchLabel:Hide()

	-- Fixed bottom strip - pings roster members not yet GearScore-inspected
	-- (normally those out of inspect range) to report to Violet Hold. See
	-- RaidCompUI:AnnounceUninspected. Label/enabled state set in RefreshComp.
	reportVHBtn = Skin:CreateButton(compPage, 172, FOOTER_HEIGHT, "Ping uninspected to VH")
	reportVHBtn:SetPoint("BOTTOMLEFT", compPage, "BOTTOMLEFT", 0, 0)
	reportVHBtn:SetScript("OnClick", function() RaidCompUI:AnnounceUninspected() end)

	-- Force a fresh GearScore sweep of the whole roster in place - see
	-- RaidCompUI:RescanAllGearScores.
	local rescanAllBtn = Skin:CreateButton(compPage, 102, FOOTER_HEIGHT, "Re-scan all GS")
	rescanAllBtn:SetPoint("LEFT", reportVHBtn, "RIGHT", 6, 0)
	rescanAllBtn:SetScript("OnClick", function() RaidCompUI:RescanAllGearScores() end)

	reportVHStatus = compPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	-- Starts a ready check and flags the answers on the cards (see the ready
	-- check section). Right-click clears the flags.
	readyBtn = Skin:CreateButton(compPage, 88, FOOTER_HEIGHT, "Ready check")
	readyBtn:SetPoint("LEFT", rescanAllBtn, "RIGHT", 6, 0)
	readyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	readyBtn:SetScript("OnClick", function(self, mouseButton) OnReadyButton(mouseButton) end)
	readyBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Ready check")
		GameTooltip:AddLine("Anyone who doesn't answer is flagged AFK on their slot.", 1, 1, 1, true)
		GameTooltip:AddLine("Right-click: clear the flags.", 0.6, 0.66, 0.65)
		GameTooltip:Show()
	end)
	readyBtn:SetScript("OnLeave", GameTooltip_Hide)

	-- Only shown after a ready check that left someone flagged AFK (see
	-- RefreshComp) - removes all of them, after a confirm popup.
	kickBtn = Skin:CreateButton(compPage, 92, FOOTER_HEIGHT, "Kick AFK")
	kickBtn:SetPoint("LEFT", readyBtn, "RIGHT", 6, 0)
	kickBtn:SetBackdropBorderColor(C.short[1], C.short[2], C.short[3], 1)
	kickBtn.text:SetTextColor(C.short[1], C.short[2], C.short[3])
	kickBtn:SetScript("OnClick", function()
		ConfirmKick(ReadyAfkNames(RaidCompUI:ScanRoster()))
	end)
	kickBtn:Hide()

	reportVHStatus:SetPoint("BOTTOMLEFT", reportVHBtn, "TOPLEFT", 0, 3)

	hintText = compPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hintText:SetPoint("BOTTOMRIGHT", compPage, "BOTTOMRIGHT", 0, 5)
	hintText:SetWidth(330)
	hintText:SetJustifyH("RIGHT")
	hintText:SetText(IDLE_HINT)
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "JohnnysAddonHubRaidCompFrame", UIParent)
	mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)

	local pos = JohnnysRaidComp.db.profile.raidCompPanelPosition
	mainFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)

	-- HIGH, not DIALOG: the kick confirmation (a StaticPopup, DIALOG strata)
	-- must always open above this window, never behind it.
	mainFrame:SetFrameStrata("HIGH")
	mainFrame:SetClampedToScreen(true) -- can't be dragged off-screen and lost
	table.insert(UISpecialFrames, "JohnnysAddonHubRaidCompFrame") -- Esc closes it
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

	-- Title strip: "RAID COMP" then a muted breadcrumb for the current
	-- selection ("ICECROWN CITADEL  /  25-MAN HEROIC"), set by ShowComp /
	-- ShowClassRunComp through mainFrame.title:SetText.
	local titleText = Skin:AddHeader(mainFrame, "Raid Comp")
	mainFrame.title = Skin:Heading(mainFrame, 12, Skin.C.muted)
	mainFrame.title:SetPoint("BOTTOMLEFT", titleText, "BOTTOMRIGHT", 10, 1)

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

	-- "Update available" notice, hidden unless a newer version has been seen
	-- (see Modules\VersionCheck.lua). It anchors itself to its host's top-left
	-- corner, which the title occupies, so give it a host left of Cfg instead.
	local noticeHost = CreateFrame("Frame", nil, mainFrame)
	noticeHost:SetSize(210, Skin.HEADER_HEIGHT)
	noticeHost:SetPoint("TOPRIGHT", cfg, "TOPLEFT", -4, 6)
	JohnnysRaidComp.VersionCheck:AttachNotice(noticeHost)

	BuildRail()
	BuildCompPage()

	mainFrame:SetScript("OnShow", function()
		local lastRaid = JohnnysRaidComp.db.profile.raidCompSelectedRaid
		local lastSize = JohnnysRaidComp.db.profile.raidCompSelectedSize
		-- Class Run's template is only ever built lazily inside
		-- ShowClassRunComp itself, so it won't exist yet on a fresh session -
		-- route there directly instead of the TEMPLATES-lookup check below.
		if lastRaid and lastSize == "CLASSRUN" and RaidCompUI.CLASS_RUN_RAIDS[lastRaid] then
			RaidCompUI:ShowClassRunComp(lastRaid)
		elseif lastRaid and lastSize and RaidCompUI.TEMPLATES[lastRaid .. "_" .. lastSize] then
			RaidCompUI:ShowComp(lastRaid, lastSize)
		else
			-- Nothing picked yet: open on the first raid at its first size.
			local firstRaid = RaidCompUI.RAID_ORDER[1]
			RaidCompUI:ShowComp(firstRaid, RaidCompUI.RAID_SIZE_ORDER[firstRaid][1])
		end
		-- First open after an update: show what changed, docked to the left.
		if JohnnysRaidComp.Changelog then
			pcall(JohnnysRaidComp.Changelog.ShowIfUnseen, JohnnysRaidComp.Changelog)
		end
	end)
	mainFrame:SetScript("OnHide", function()
		if JohnnysRaidComp.Changelog then
			JohnnysRaidComp.Changelog:Hide()
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
-- Hooks for Inspect.lua and Achievements.lua, which load after this file.
----------------------------------------------------------------------------
-- The tooltip a finished achievement scan redraws if it's still open.
RaidCompUI.ShowGearScoreTooltip = ShowGearScoreTooltip

-- The small status line above the footer buttons ("Re-scanning Bob...").
-- Does nothing until the window has been built.
function RaidCompUI:SetStatus(text)
	if reportVHStatus then
		reportVHStatus:SetText(text)
	end
end
