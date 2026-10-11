-- GearScore, PvP-gear and talent-role lookups for the Raid Comp window: the
-- throttled NotifyInspect queue and everything that reads its answers.
-- Split out of UI.lua, which loads first (see the .toc) and owns the window.
--
-- Public (called from UI.lua): RaidCompUI:RequestGearScore,
-- :ForceRescanGearScore, :RescanAllGearScores, :StoreGearScore.
local RaidCompUI = JohnnysRaidComp.RaidCompUI

-- From UI.lua: the "score changed, not yet acknowledged" flags that drive
-- the amber pulse on a card, and the talents -> role reader.
local gsChanged = RaidCompUI.gsChanged
local DetectSpecRole = RaidCompUI.DetectSpecRole

----------------------------------------------------------------------------
-- GearScore/PVP-gear lookup. The score math is our own GearScoreLite-
-- compatible formula (Modules\GearScore.lua), so GearScoreLite doesn't need
-- to be installed. It only reads whatever gear the client can currently see,
-- and a first read right after NotifyInspect is very often empty because the
-- server's inspect data hasn't arrived on the client yet (or an item isn't
-- in the item cache). What follows owns the request/response flow: a
-- throttled NotifyInspect queue, a couple of short retries when a read comes
-- back empty, resilience detection (our own hidden scan tooltip - see
-- ItemHasResilience), and a highest-score-ever-seen cache in db.realm so a lucky
-- earlier read survives an unlucky later one (and survives a /reload, since
-- it's not tied to whichever of your own characters did the inspecting).
--
-- (This was folded into UI.lua for a while, after a first Inspect.lua
-- "silently never loaded". The cause was the client, not the file: 3.3.5a
-- only notices a NEW file after the game is fully closed and reopened - a
-- /reload or relog isn't enough. Worth remembering when adding files.)
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
	return JohnnysRaidComp.db.realm.raidCompGearScores
end

local function GSIsFresh(name)
	local entry = GSGetCache()[name]
	-- time(), not GetTime(): the cache is saved between sessions and GetTime()
	-- restarts with the PC, which made old entries look fresh forever. A stamp
	-- in the future (clock change) counts as stale too.
	if not (entry and entry.updatedAt) then
		return false
	end
	local age = time() - entry.updatedAt
	return age >= 0 and age < GS_STALE_SECONDS
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
	entry.updatedAt = time()

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

-- The request behind the most recent NotifyInspect ({name=, unit=, at=}) - the
-- only player INSPECT_TALENT_READY can be about, since that event carries no
-- name or GUID on 3.3.5a.
local gsLastInspect

-- INSPECT_TALENT_READY: the inspected player's talents are readable now, so
-- work out their real role (see DetectSpecRole) and remember it. If that
-- differs from what they were placed by - usually the class guess - the comp
-- is repainted and BuildMatches moves them to a slot of their real role.
-- Ignored when it can't be tied to our own request: too long after it, the
-- unit has changed, or the talent data is for another class (another addon's
-- inspect answered instead).
local function GSStoreRole()
	local request = gsLastInspect
	if not request or GetTime() - request.at > 3 then
		return
	end
	if not (UnitExists(request.unit) and UnitName(request.unit) == request.name) then
		return
	end
	local _, class = UnitClass(request.unit)
	local ok, role, spec = pcall(DetectSpecRole, class, true)
	if not ok or not role then
		return
	end

	local known = JohnnysRaidComp.db.realm.raidCompRoles
	local old = known[request.name]
	-- time(), not GetTime(), since this is saved between sessions.
	known[request.name] = { role = role, spec = spec, class = class, at = time() }
	if (not old or old.role ~= role or old.spec ~= spec) and RaidCompUI:IsShowingComp() then
		RaidCompUI:RefreshComp()
	end
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
	RaidCompUI.AchClearPending(name)

	GSClearPending(name)

	for _, member in ipairs(self:ScanRoster()) do
		if member.name == name then
			self:RequestGearScore(name, member.unit)
			break
		end
	end

	RaidCompUI:SetStatus("Re-scanning " .. name .. "...")
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
		RaidCompUI.AchClearPending(member.name)
	end

	for _, member in ipairs(roster) do
		GSClearPending(member.name)
		self:RequestGearScore(member.name, member.unit)
	end

	RaidCompUI:SetStatus(string.format("Re-scanning all %d member(s)...", #roster))
	if RaidCompUI:IsShowingComp() then
		RaidCompUI:RefreshComp()
	end
end

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

	-- Stand aside while the player has someone's Inspect window open - our
	-- NotifyInspect on another member would swap the gear it's showing.
	local inspectOpen = InspectFrame and InspectFrame:IsShown()

	if not inspectOpen and gsSinceLastRequest >= GS_REQUEST_INTERVAL and #gsRequestQueue > 0 then
		local request = table.remove(gsRequestQueue, 1)
		if UnitExists(request.unit) and UnitName(request.unit) == request.name and CanInspect(request.unit) then
			gsSinceLastRequest = 0
			gsPendingGuid[UnitGUID(request.unit)] = request
			gsLastInspect = { name = request.name, unit = request.unit, at = GetTime() }
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
-- Talents of the player we just inspected - their real role (see GSStoreRole).
gsInspectFrame:RegisterEvent("INSPECT_TALENT_READY")
-- Own gear swap (e.g. PvE -> PvP set before a raid) - re-check immediately
-- rather than waiting out GS_STALE_SECONDS, since this is the one case where
-- we know for certain the cached reading is now out of date.
gsInspectFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
gsInspectFrame:SetScript("OnEvent", function(self, event, guid)
	if event == "INSPECT_TALENT_READY" then
		-- This is the inspect answer on 3.3.5a (INSPECT_READY with a GUID only
		-- exists on later clients, so that path below never runs here). With
		-- the player's own Inspect window open it's the answer to their
		-- inspect, not ours.
		if InspectFrame and InspectFrame:IsShown() then
			return
		end
		GSStoreRole()
		-- Read the score now instead of waiting for the fallback timer, and
		-- drop that timer so the same request isn't resolved twice.
		local request = gsLastInspect
		if request and GetTime() - request.at <= 3 and gsInFlight[request.name] then
			for i = #gsRetryQueue, 1, -1 do
				if gsRetryQueue[i].name == request.name then
					table.remove(gsRetryQueue, i)
				end
			end
			GSResolveScore(request.name, request.unit)
		end
		return
	end
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
