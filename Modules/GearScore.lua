-- Built-in GearScore calculation, so players don't need GearScoreLite installed.
--
-- Reproduces GearScoreLite 1.84's formula exactly - raid leaders on Warmane
-- compare against GearScoreLite numbers, so matching them matters more than
-- the formula being "right". Covered quirks, all mirrored on purpose:
--   * per-slot weights (SLOT_MOD) and two ilvl curves (above / at-or-below 120)
--   * legendaries score as epics x1.3; grey/white items as greens x0.005;
--     heirlooms as blue ilvl 187.05 (an off-hand heirloom then counts as
--     ilvl 0 in the average; other slots use the real ilvl)
--   * an unenchanted enchantable slot loses 2 x SLOT_MOD percent
--   * hunters: melee weapons x0.3164, ranged x5.3224
--   * Titan's Grip: both weapon scores halved when a 2H is dual-wielded
--   * the score colour's green/blue channels are swapped vs. the table names
--     (a GearScoreLite bug everyone's used to seeing)
--
-- Public: JohnnysRaidComp.GearScore:GetScore(unit) and :GetQuality(score),
-- used by the GearScore lookup section of Modules\RaidCompUI\UI.lua.

JohnnysRaidComp.GearScore = {}
local GearScore = JohnnysRaidComp.GearScore

local SCALE = 1.8618

-- [equipLoc] = { slot weight, can be enchanted }
local ITEM_TYPES = {
	INVTYPE_RELIC          = { 0.3164, false },
	INVTYPE_TRINKET        = { 0.5625, false },
	INVTYPE_2HWEAPON       = { 2.0000, true },
	INVTYPE_WEAPONMAINHAND = { 1.0000, true },
	INVTYPE_WEAPONOFFHAND  = { 1.0000, true },
	INVTYPE_RANGED         = { 0.3164, true },
	INVTYPE_THROWN         = { 0.3164, false },
	INVTYPE_RANGEDRIGHT    = { 0.3164, false },
	INVTYPE_SHIELD         = { 1.0000, true },
	INVTYPE_WEAPON         = { 1.0000, true },
	INVTYPE_HOLDABLE       = { 1.0000, false },
	INVTYPE_HEAD           = { 1.0000, true },
	INVTYPE_NECK           = { 0.5625, false },
	INVTYPE_SHOULDER       = { 0.7500, true },
	INVTYPE_CHEST          = { 1.0000, true },
	INVTYPE_ROBE           = { 1.0000, true },
	INVTYPE_WAIST          = { 0.7500, false },
	INVTYPE_LEGS           = { 1.0000, true },
	INVTYPE_FEET           = { 0.7500, true },
	INVTYPE_WRIST          = { 0.5625, true },
	INVTYPE_HAND           = { 0.7500, true },
	INVTYPE_FINGER         = { 0.5625, false },
	INVTYPE_CLOAK          = { 0.5625, true },
	INVTYPE_BODY           = { 0, false },
}

-- [rarity] = { A, B }: score = (ilvl - A) / B, before slot/quality scaling.
local FORMULA_HIGH = { -- ilvl > 120
	[4] = { 91.45, 0.65 },
	[3] = { 81.375, 0.8125 },
	[2] = { 73.0, 1.0 },
}
local FORMULA_LOW = {
	[4] = { 26.0, 1.2 },
	[3] = { 0.75, 1.8 },
	[2] = { 8.0, 2.0 },
}

-- Colour bands, keyed by the band's upper bound. Each channel is
-- { A, B, C, D } -> A + (score - B) * C * D.
local QUALITY = {
	[6000] = { r = { 0.94, 5000, 0.00006, 1 },  g = { 0.47, 5000, 0.00047, -1 }, b = { 0, 0, 0, 0 } },
	[5000] = { r = { 0.69, 4000, 0.00025, 1 },  g = { 0.28, 4000, 0.00019, 1 },  b = { 0.97, 4000, 0.00096, -1 } },
	[4000] = { r = { 0.0, 3000, 0.00069, 1 },   g = { 0.5, 3000, 0.00022, -1 },  b = { 1, 3000, 0.00003, -1 } },
	[3000] = { r = { 0.12, 2000, 0.00012, -1 }, g = { 1, 2000, 0.00050, -1 },    b = { 0, 2000, 0.001, 1 } },
	[2000] = { r = { 1, 1000, 0.00088, -1 },    g = { 1, 0, 0, 0 },              b = { 1, 1000, 0.001, -1 } },
	[1000] = { r = { 0.55, 0, 0.00045, 1 },     g = { 0.55, 0, 0.00045, 1 },     b = { 0.55, 0, 0.00045, 1 } },
}

local HUNTER_MELEE_MOD = 0.3164
local HUNTER_RANGED_MOD = 5.3224

local function Channel(c, score)
	return c[1] + (score - c[2]) * c[3] * c[4]
end

-- r, g, b for a GearScore value, identical to GearScore_GetQuality.
function GearScore:GetQuality(score)
	if not score then
		return 0, 0, 0
	end
	if score > 5999 then
		score = 5999
	end
	for i = 0, 6 do
		if score > i * 1000 and score <= (i + 1) * 1000 then
			local q = QUALITY[(i + 1) * 1000]
			-- g/b deliberately swapped, as in GearScoreLite.
			return Channel(q.r, score), Channel(q.b, score), Channel(q.g, score)
		end
	end
	return 0.1, 0.1, 0.1
end

-- An enchantable slot with no enchant id in its link loses 2 x slot weight %.
local function EnchantMultiplier(link, itemType)
	if not itemType[2] then
		return 1
	end
	local enchantId = link:match("|Hitem:%d+:(%d+)")
	if enchantId == "0" then
		local percent = floor(-2 * itemType[1] * 100) / 100
		return 1 + percent / 100
	end
	return 1
end

-- Returns score, scoreIlvl, equipLoc, realIlvl for one item link, or nil if the client
-- hasn't cached the item yet (GetItemInfo returns nothing until it has).
local function ItemScore(link)
	local _, _, rarity, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
	if not rarity then
		return nil
	end
	local realIlvl = ilvl

	local qualityScale = 1
	if rarity == 5 then
		qualityScale, rarity = 1.3, 4
	elseif rarity == 1 or rarity == 0 then
		qualityScale, rarity = 0.005, 2
	end
	local heirloom = rarity == 7
	if heirloom then
		rarity, ilvl = 3, 187.05
	end

	local itemType = ITEM_TYPES[equipLoc]
	if not itemType or rarity < 2 or rarity > 4 then
		return -1, ilvl, equipLoc, realIlvl
	end

	local f = (ilvl > 120 and FORMULA_HIGH or FORMULA_LOW)[rarity]
	local score = floor((ilvl - f[1]) / f[2] * itemType[1] * SCALE * qualityScale)
	if score < 0 then
		score = 0
	end
	score = floor(score * EnchantMultiplier(link, itemType))

	return score, heirloom and 0 or ilvl, equipLoc, realIlvl
end

-- GearScore and average item level for a player unit whose gear is readable
-- (yourself, or someone freshly inspected). Third return is true if any
-- equipped item wasn't in the client's item cache yet - the caller should
-- retry shortly rather than trust a too-low score.
function GearScore:GetScore(unit)
	if not UnitIsPlayer(unit) then
		return 0, 0, false
	end

	local _, class = UnitClass(unit)
	local isHunter = class == "HUNTER"
	local total, count, levels = 0, 0, 0
	local incomplete = false

	local mainLink = GetInventoryItemLink(unit, 16)
	local offLink = GetInventoryItemLink(unit, 17)

	-- Titan's Grip: halve both weapons when an off-hand is present alongside
	-- a main hand and either one is two-handed.
	local titanGrip = 1
	if mainLink and offLink then
		local _, _, _, _, _, _, _, _, mainLoc = GetItemInfo(mainLink)
		if mainLoc == "INVTYPE_2HWEAPON" then
			titanGrip = 0.5
		end
	end
	if offLink then
		local score, ilvl, loc = ItemScore(offLink)
		if score then
			if loc == "INVTYPE_2HWEAPON" then
				titanGrip = 0.5
			end
			if isHunter then
				score = score * HUNTER_MELEE_MOD
			end
			total = total + score * titanGrip
			count, levels = count + 1, levels + ilvl
		else
			incomplete = true
		end
	end

	for slot = 1, 18 do
		if slot ~= 4 and slot ~= 17 then
			local link = GetInventoryItemLink(unit, slot)
			if link then
				local score, _, _, ilvl = ItemScore(link)
				if score then
					if slot == 16 then
						if isHunter then
							score = score * HUNTER_MELEE_MOD
						end
						score = score * titanGrip
					elseif slot == 18 and isHunter then
						score = score * HUNTER_RANGED_MOD
					end
					total = total + score
					count, levels = count + 1, levels + ilvl
				else
					incomplete = true
				end
			end
		end
	end

	if total < 0 then
		total = 0
	end
	return floor(total), count > 0 and floor(levels / count) or 0, incomplete
end
