-- Fixed "ideal comp" templates, one per WotLK raid instance x size/difficulty.
-- Each slot names a role (TANK/HEALER/DAMAGER, matching UnitGroupRolesAssigned's
-- return values) and, for a handful of slots, a specific required class chosen
-- for that raid's actual encounter mechanics (interrupts/CC/AoE/raid cooldowns,
-- not just generic buff coverage). class == nil means the slot accepts any
-- class in that role.
--
-- NOTE: UnitClass/UnitGroupRolesAssigned can't see talent spec, only class and
-- the manually-assigned role icon - so e.g. a "Balance Druid" slot really just
-- matches any Druid currently flagged DAMAGER, not specifically a Boomkin.
JohnnysRaidComp.RaidCompUI = JohnnysRaidComp.RaidCompUI or {}
local RaidCompUI = JohnnysRaidComp.RaidCompUI

RaidCompUI.SIZE_LABELS = {
	["10"] = "10-Man",
	["10H"] = "10-Man Heroic",
	["25"] = "25-Man",
	["25H"] = "25-Man Heroic",
	["CLASSRUN"] = "Class Run",
}

RaidCompUI.RAID_ORDER = { "ONY", "VOA", "EOE", "OS", "NAXX", "ULD", "TOC", "ICC", "RS" }

RaidCompUI.RAID_LABELS = {
	ONY = "Onyxia's Lair",
	VOA = "Vault of Archavon",
	EOE = "The Eye of Eternity",
	OS = "The Obsidian Sanctum",
	NAXX = "Naxxramas",
	ULD = "Ulduar",
	TOC = "Trial of the Crusader",
	ICC = "Icecrown Citadel",
	RS = "The Ruby Sanctum",
}

-- Only ToC/ICC/Ruby Sanctum shipped with a Heroic difficulty toggle - the
-- rest of WotLK's raids only ever had 10/25.
RaidCompUI.RAID_SIZE_ORDER = {
	ONY = { "10", "25" },
	VOA = { "10", "25" },
	EOE = { "10", "25" },
	OS = { "10", "25" },
	NAXX = { "10", "25" },
	ULD = { "10", "25" },
	TOC = { "10", "10H", "25", "25H" },
	ICC = { "10", "10H", "25", "25H" },
	RS = { "10", "10H", "25", "25H" },
}

-- Headcount per role is fixed by the raid's size lockout by default, not by
-- which raid it is - a 25-man is always 25 players regardless of instance.
-- Heroic 25s just trade one DPS slot for an extra healer to cover the harder
-- damage. The user can override these per raid+size from the comp screen's
-- +/- controls (see RaidCompUI:GetDefaultCounts / RaidCompUI:BuildTemplate
-- below and UI.lua's AdjustCount) - DPS always absorbs the difference so the
-- total stays locked to the size's real player cap.
local SIZE_ROLE_COUNTS = {
	["10"] = { TANK = 2, HEALER = 3, DAMAGER = 5 },
	["10H"] = { TANK = 2, HEALER = 3, DAMAGER = 5 },
	["25"] = { TANK = 2, HEALER = 5, DAMAGER = 18 },
	["25H"] = { TANK = 2, HEALER = 6, DAMAGER = 17 },
}

-- Raids that support a "Class Run" mode - one slot per WotLK class (see
-- BuildClassRunTemplate below), for tracking "bring one of each class"
-- 10-man runs.
RaidCompUI.CLASS_RUN_RAIDS = { VOA = true }

-- Outside a Dungeon/Raid-Finder-formed group, WotLK 3.3.5a doesn't
-- auto-assign the raid frame's tank/healer/dps role icons - UnitGroupRolesAssigned
-- returns "NONE" for anyone who hasn't had that icon clicked by hand, which is
-- most manually-invited raids. Rather than dropping those members from the
-- scan entirely (which meant nobody showed up, not even the roster-scanner's
-- own player), unassigned members fall back to this rough per-class guess.
RaidCompUI.CLASS_DEFAULT_ROLE = {
	WARRIOR = "DAMAGER",
	PALADIN = "DAMAGER",
	HUNTER = "DAMAGER",
	ROGUE = "DAMAGER",
	PRIEST = "HEALER",
	DEATHKNIGHT = "DAMAGER",
	SHAMAN = "DAMAGER",
	MAGE = "DAMAGER",
	WARLOCK = "DAMAGER",
	DRUID = "DAMAGER",
}

RaidCompUI.CLASS_ORDER = {
	"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
	"DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}
RaidCompUI.CLASS_LABELS = {
	WARRIOR = "Warrior",
	PALADIN = "Paladin",
	HUNTER = "Hunter",
	ROGUE = "Rogue",
	PRIEST = "Priest",
	DEATHKNIGHT = "Death Knight",
	SHAMAN = "Shaman",
	MAGE = "Mage",
	WARLOCK = "Warlock",
	DRUID = "Druid",
}

-- Classes that can plausibly off-tank for a Class Run's manual "mark as tank"
-- toggle (see UI.lua's OnToggleTank) - only hybrids that actually have a
-- tank spec in WotLK. A class run has no role data at all otherwise (slots
-- match on class alone - see BuildClassRunTemplate), so this is purely an
-- informational marker the raid leader sets by hand, not something matched
-- against UnitGroupRolesAssigned.
RaidCompUI.CLASS_RUN_TANK_CAPABLE = {
	WARRIOR = true,
	PALADIN = true,
	DRUID = true,
	DEATHKNIGHT = true,
}

-- Same idea as CLASS_RUN_TANK_CAPABLE but for the "mark as healer" toggle -
-- unlike the tank marker, more than one class can be checked at once (a Class
-- Run typically wants 2+ healers, not 1), so this is tracked as a set in
-- raidCompClassRunHealers rather than a single value (see UI.lua's
-- OnToggleHealer).
RaidCompUI.CLASS_RUN_HEALER_CAPABLE = {
	PRIEST = true,
	PALADIN = true,
	SHAMAN = true,
	DRUID = true,
}

-- Per-raid priority lists: the classes most worth having for that specific
-- raid's mechanics, pinned onto DPS (and sometimes one healer) slot ahead of
-- generic "Any DPS"/"Any Healer" filler. Slots only ever display the class
-- name (see BuildTemplate) - no spec/reason text. 10-man templates only pin
-- the first two priorities (a 5-DPS raid can't afford to lock down more than
-- that); 25-man templates pin the whole list.
local RAID_PROFILES = {
	ONY = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "MAGE" },
			{ class = "DRUID" },
			{ class = "WARLOCK" },
		},
	},
	VOA = {
		-- Archavon is a pure tank-and-spank; only the later bosses added to
		-- this raid (Emalon/Koralon/Toravon) have a stacking-debuff tank-swap
		-- mechanic, so 1 dedicated tank covers how most guilds actually run it.
		tanks = 1,
		-- None of VOA's bosses have heavy sustained raid damage (no Loatheb-
		-- style healing debuff, no prolonged AoE phases), so it runs light on
		-- healers compared to progression content - 1 fewer than the default
		-- at each size, freed into an extra generic DPS slot.
		healers = { ["10"] = 2, ["25"] = 4 },
		dps = {
			{ class = "SHAMAN" },
			{ class = "MAGE" },
			{ class = "WARLOCK" },
			{ class = "DRUID" },
		},
	},
	EOE = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "MAGE" },
			{ class = "WARLOCK" },
			{ class = "HUNTER" },
		},
	},
	OS = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "DRUID" },
			{ class = "WARLOCK" },
			{ class = "MAGE" },
		},
	},
	NAXX = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "DRUID" },
			{ class = "WARLOCK" },
			{ class = "PALADIN" },
		},
		healer = { class = "PRIEST" },
	},
	ULD = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "WARLOCK" },
			{ class = "DRUID" },
			{ class = "ROGUE" },
		},
		healer = { class = "PRIEST" },
	},
	TOC = {
		dps = {
			{ class = "MAGE" },
			{ class = "WARLOCK" },
			{ class = "DRUID" },
			{ class = "SHAMAN" },
		},
	},
	ICC = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "DRUID" },
			{ class = "WARLOCK" },
			{ class = "PALADIN" },
		},
		healer = { class = "PRIEST" },
	},
	RS = {
		dps = {
			{ class = "SHAMAN" },
			{ class = "WARLOCK" },
			{ class = "DRUID" },
			{ class = "MAGE" },
		},
	},
}

-- The size lockout's default tank/healer/dps split for a given raid, before
-- any user override (see UI.lua's AdjustCount/ResetCounts). A raid profile
-- can shift the default tank/healer counts (e.g. VOA's Archavon is a pure
-- tank-and-spank needing only 1 tank, and none of VOA's bosses have heavy
-- sustained raid damage so it also runs 1 healer light) - any slot freed up
-- this way becomes an extra generic DPS slot so the total still matches the
-- size's real player cap.
function RaidCompUI:GetDefaultCounts(raidKey, sizeKey)
	local profile = RAID_PROFILES[raidKey] or {}
	local counts = SIZE_ROLE_COUNTS[sizeKey]
	local tankCount = profile.tanks or counts.TANK
	local healerCount = (profile.healers and profile.healers[sizeKey]) or counts.HEALER
	local extraDps = (counts.TANK - tankCount) + (counts.HEALER - healerCount)
	return { TANK = tankCount, HEALER = healerCount, DAMAGER = counts.DAMAGER + extraDps }
end

-- Builds a raid+size's slot list from an explicit tank/healer/dps count
-- (either RaidCompUI:GetDefaultCounts's result, or a user-adjusted one from
-- UI.lua's AdjustCount) - the raid's own class-priority profile still decides
-- which of those slots get pinned to a specific class, same as before.
function RaidCompUI:BuildTemplate(raidKey, sizeKey, counts)
	local profile = RAID_PROFILES[raidKey] or {}
	-- Class slots switched off (raidCompClassPins) - build from an empty
	-- profile so every slot is generic. SavedVariables aren't loaded yet when
	-- this runs at file load, so those default templates always have pins;
	-- RaidCompUI:RebuildTemplate applies the setting before anything's shown.
	local db = JohnnysRaidComp.db
	local classPins = not (db and db.profile.raidCompClassPins == false)
	if not classPins then
		profile = {}
	end
	local isLarge = (sizeKey == "25" or sizeKey == "25H")
	local slots = {}

	local tankCount = counts.TANK
	for i = 1, tankCount do
		table.insert(slots, { role = "TANK", label = "Any Tank" })
	end

	-- A pinned healer is only worth locking down on 25s - a light 10-man
	-- healer count can't spare the flexibility.
	local healerSlotsLeft = counts.HEALER
	if profile.healer and isLarge and healerSlotsLeft > 0 then
		table.insert(slots, { role = "HEALER", class = profile.healer.class, label = RaidCompUI.CLASS_LABELS[profile.healer.class] })
		healerSlotsLeft = healerSlotsLeft - 1
	end
	for i = 1, healerSlotsLeft do
		table.insert(slots, { role = "HEALER", label = "Any Healer" })
	end

	local dpsProfile = profile.dps or {}
	local pinCount = isLarge and #dpsProfile or math.min(2, #dpsProfile)
	pinCount = math.min(pinCount, counts.DAMAGER)
	local dpsSlotsLeft = counts.DAMAGER
	for i = 1, pinCount do
		local class = dpsProfile[i].class
		table.insert(slots, { role = "DAMAGER", class = class, label = RaidCompUI.CLASS_LABELS[class] })
		dpsSlotsLeft = dpsSlotsLeft - 1
	end
	for i = 1, dpsSlotsLeft do
		table.insert(slots, { role = "DAMAGER", label = "Any DPS" })
	end

	-- classPins records which setting this was built under, so a stale
	-- template can be spotted (see RaidSpamUI's EnsureTemplateBuilt).
	return { slots = slots, needed = { TANK = counts.TANK, HEALER = counts.HEALER, DAMAGER = counts.DAMAGER }, classPins = classPins }
end

-- "Class Run" - one slot per WotLK class (10 total), matched on class alone
-- (role = nil, so any role that class happens to be counts). Only makes
-- sense at 10-man size, since there are exactly 10 classes. Built once and
-- cached by the caller (see UI.lua) rather than per-template-key like the
-- regular BuildTemplate output, since there's nothing to key it by beyond
-- the raid itself.
function RaidCompUI:BuildClassRunTemplate()
	local slots = {}
	for _, classToken in ipairs(RaidCompUI.CLASS_ORDER) do
		table.insert(slots, { class = classToken, label = RaidCompUI.CLASS_LABELS[classToken] })
	end
	return { slots = slots, isClassRun = true }
end

-- RaidCompUI.TEMPLATES is keyed "<RAIDKEY>_<SIZEKEY>", e.g. "ICC_25H". Built
-- here with each raid+size's default counts; UI.lua's AdjustCount/ResetCounts
-- rebuild an individual entry in place once the player has a saved custom
-- count for it (SavedVariables aren't loaded yet at this point in the addon's
-- startup, so a saved override can't be applied until the comp screen for
-- that raid+size is actually shown - see UI.lua's ShowComp).
RaidCompUI.TEMPLATES = {}
for _, raidKey in ipairs(RaidCompUI.RAID_ORDER) do
	for _, sizeKey in ipairs(RaidCompUI.RAID_SIZE_ORDER[raidKey]) do
		local counts = RaidCompUI:GetDefaultCounts(raidKey, sizeKey)
		RaidCompUI.TEMPLATES[raidKey .. "_" .. sizeKey] = RaidCompUI:BuildTemplate(raidKey, sizeKey, counts)
	end
end

-- Achievements + boss kill counts shown in the slot-card/bench-chip tooltip
-- (see UI.lua's achievement lookup section), per raid x size. `ach` holds
-- achievement IDs - display names are read at runtime from
-- GetAchievementInfo(id) and any ID it doesn't recognise is skipped, so one
-- wrong ID can't break the tooltip (`/jrc achcheck` lists them all in chat).
-- `bosses` are matched against the client's own Statistics names at runtime
-- (e.g. "Lich King kills (Heroic Icecrown 25 player)") by boss name + size +
-- heroic-ness, rather than hardcoding statistic IDs - see ResolveKillStat.
-- CLASSRUN falls back to the raid's "10" entry.
--
-- `runs` drives the tooltip's per-size "Runs/clears" line, from the same
-- kill statistics: runs = the highest kill count among `first` (a raid's
-- opening boss(es) - every lockout that got anywhere) and `last`; clears =
-- `last` kills. A raid with only `last` (single boss) shows one number; one
-- with only `first` (VoA - no boss order) shows runs without clears. A
-- `first` boss the client has no statistic for just drops out of the max.
--
-- Keep each raid's "10"/"25" (and "10H"/"25H") lists PARALLEL - same
-- achievement at the same position - since a 10-man tooltip counts the 25-man
-- version at the matching index as done too.
RaidCompUI.RAID_ACHIEVEMENTS = {
	ONY = {
		bosses = { "Onyxia" },
		runs = { last = "Onyxia" },
		["10"] = { 4396 }, -- Onyxia's Lair (10 player)
		["25"] = { 4397 },
	},
	VOA = {
		bosses = { "Archavon", "Emalon", "Koralon", "Toravon" },
		runs = { first = { "Archavon", "Emalon", "Koralon", "Toravon" } }, -- no boss order, so no "clears"
		["10"] = { 1722, 3136, 3836, 4585 }, -- Archavon/Emalon/Koralon/Toravon (10 player)
		["25"] = { 1721, 3137, 3837, 4586 },
	},
	EOE = {
		bosses = { "Malygos" },
		runs = { last = "Malygos" },
		["10"] = { 622 }, -- The Spellweaver's Downfall (10 player)
		["25"] = { 1874 },
	},
	OS = {
		bosses = { "Sartharion" },
		runs = { last = "Sartharion" },
		["10"] = { 1876, 2051 }, -- Besting the Black Dragonflight, The Twilight Zone (10 player)
		["25"] = { 625, 2054 },
	},
	NAXX = {
		bosses = { "Kel'Thuzad" },
		runs = { first = { "Anub'Rekhan", "Noth the Plaguebringer", "Instructor Razuvious", "Patchwerk" }, last = "Kel'Thuzad" }, -- any wing can go first
		["10"] = { 576, 2137 }, -- The Fall of Naxxramas, Glory of the Raider (10 player)
		["25"] = { 577, 2138 },
	},
	ULD = {
		bosses = { "Yogg-Saron" },
		runs = { first = { "Flame Leviathan" }, last = "Yogg-Saron" },
		["10"] = { 2894, 3036, 3159, 2957 }, -- Secrets of Ulduar, Observed, Alone in the Darkness, Glory of the Ulduar Raider (10 player)
		["25"] = { 2895, 3037, 3164, 2958 },
	},
	TOC = {
		bosses = { "Anub'arak" },
		runs = { first = { "Beasts of Northrend" }, last = "Anub'arak" },
		["10"] = { 3917 }, -- Call of the Crusade (10 player)
		["10H"] = { 3918, 3808, 3809, 3810 }, -- Call of the Grand Crusade, A Tribute to Skill/Mad Skill/Insanity (10 player)
		["25"] = { 3916 },
		["25H"] = { 3812, 3817, 3818, 3819 },
	},
	ICC = {
		bosses = { "Lich King" },
		runs = { first = { "Lord Marrowgar" }, last = "Lich King" },
		["10"] = { 4530, 4532, 4602 }, -- The Frozen Throne, Fall of the Lich King, Glory of the Icecrown Raider (10 player)
		["10H"] = { 4583, 4636, 4602 }, -- Bane of the Fallen King, Heroic: Fall of the Lich King, Glory of the Icecrown Raider (10 player)
		["25"] = { 4597, 4608, 4603 },
		["25H"] = { 4584, 4637, 4603 }, -- The Light of Dawn, Heroic: Fall of the Lich King (25 player), Glory (25 player)
	},
	RS = {
		bosses = { "Halion" },
		runs = { first = { "Baltharus the Warborn" }, last = "Halion" },
		["10"] = { 4817 }, -- The Twilight Destroyer (10 player)
		["10H"] = { 4818 },
		["25"] = { 4815 },
		["25H"] = { 4816 },
	},
}

-- Alternate names a boss's kill statistic may go by instead of "<boss>
-- kills (...)" - matched the same way (before the parentheses; size and
-- heroic-ness checked as usual). Use `/jrc statsearch <text>` in-game to see
-- what this server actually calls a statistic, and add it here.
RaidCompUI.KILL_STAT_ALIASES = {
	["Anub'arak"] = { "Times completed the Trial of the" }, -- "...Crusader (10 player)" / "...Grand Crusader (25 player)"
}
