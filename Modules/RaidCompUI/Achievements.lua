-- Achievement and boss-kill lookups for the Raid Comp tooltip. Split out of
-- UI.lua, which loads first (see the .toc) and owns the window.
--
-- Public: RaidCompUI:RequestAchievements, :SetAchievementTooltipEnabled,
-- :IsAchievementTooltipEnabled, :PrintAchievementCheck, :PrintStatSearch,
-- and RaidCompUI.AddAchievementLines / RaidCompUI.AchClearPending (plain
-- functions, called from UI.lua's tooltip and Inspect.lua's rescans).
local RaidCompUI = JohnnysRaidComp.RaidCompUI

----------------------------------------------------------------------------
-- Achievement/kill-count lookup, shown in the same tooltip as GearScore (see
-- AddAchievementLines / ShowGearScoreTooltip). 3.3.5a's only way to read
-- another player's achievements is the comparison API the Blizzard
-- Achievements "Compare" tab uses: SetAchievementComparisonUnit(unit) asks the
-- server, INSPECT_ACHIEVEMENT_READY fires (with no guid to say whose data it
-- is), then GetAchievementComparisonInfo / GetComparisonStatistic read it and
-- ClearAchievementComparisonUnit releases it. There's only ONE comparison slot
-- client-wide, so this runs strictly one request at a time, separate from the
-- NotifyInspect queue (Inspect.lua), and stands aside entirely while the Blizzard
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
	return JohnnysRaidComp.db.realm.raidCompAchievements
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
function RaidCompUI.AddAchievementLines(name)
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
function RaidCompUI.AchClearPending(name)
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
		pcall(RaidCompUI.ShowGearScoreTooltip, owner, request.name)
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
