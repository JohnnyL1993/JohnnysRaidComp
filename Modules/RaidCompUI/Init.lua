-- Roster-change listener for the Raid Comp window. Debounced the same way
-- Modules\GearUpgrade\UI.lua handles delayed item-info retries: roster events
-- fire in bursts on mass invites/leaves, so a short OnUpdate accumulator
-- coalesces a burst into a single rescan instead of one per event.
local RaidCompUI = JohnnysRaidComp.RaidCompUI

local DEBOUNCE_SECONDS = 0.3

local debounceTicker = CreateFrame("Frame")
debounceTicker:Hide()
local debounceElapsed = 0
debounceTicker:SetScript("OnUpdate", function(self, elapsed)
	debounceElapsed = debounceElapsed + elapsed
	if debounceElapsed >= DEBOUNCE_SECONDS then
		debounceElapsed = 0
		self:Hide()
		RaidCompUI:RefreshComp()
	end
end)

-- Hand-made slot placements belong to the group they were made in: they're
-- forgotten when the group ends, and at login if you're no longer in one
-- (see RaidCompUI:ClearManualAssignments). The login check waits a few
-- seconds, since group data isn't there yet when the world first loads.
local LOGIN_CHECK_DELAY = 10
local wasGrouped = false

local function IsGrouped()
	return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

local loginCheck = CreateFrame("Frame")
loginCheck:Hide()
local loginElapsed = 0
loginCheck:SetScript("OnUpdate", function(self, elapsed)
	loginElapsed = loginElapsed + elapsed
	if loginElapsed >= LOGIN_CHECK_DELAY then
		self:Hide()
		wasGrouped = IsGrouped()
		if not wasGrouped then
			RaidCompUI:ClearManualAssignments()
		end
	end
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_ENTERING_WORLD" then
		-- Fires on every loading screen; only the first one is the login.
		self:UnregisterEvent("PLAYER_ENTERING_WORLD")
		loginCheck:Show()
		return
	end

	local grouped = IsGrouped()
	if wasGrouped and not grouped then
		RaidCompUI:ClearManualAssignments()
	end
	wasGrouped = grouped

	if not RaidCompUI:IsShowingComp() then
		return
	end
	debounceElapsed = 0
	debounceTicker:Show()
end)
