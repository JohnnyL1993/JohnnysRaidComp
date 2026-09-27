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

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:SetScript("OnEvent", function()
	if not RaidCompUI:IsShowingComp() then
		return
	end
	debounceElapsed = 0
	debounceTicker:Show()
end)
