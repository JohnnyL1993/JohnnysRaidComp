JohnnysRaidSpam = LibStub("AceAddon-3.0"):NewAddon("JohnnysRaidSpam")

local defaults = {
	profile = {
		raidSpamRecruitGS = 0,
		raidSpamRecruitTemplate = "[LFM] {raid} ({size}) - GS {gs}+ required - Need: {need} - {quest} - whisper me!",
		-- Channel 1 and Channel 2 broadcast the same composed message to two
		-- destinations, each on its own repeat timer / Start-Stop.
		raidSpamRecruitChannel = "",
		raidSpamRecruitInterval = 90,
		raidSpamRecruitChannel2 = "",
		raidSpamRecruitInterval2 = 120,
		raidSpamWeeklyQuestName = "",
		raidSpamPanelPosition = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
		-- Docked = snapped to the Raid Comp window's right edge and moving with
		-- it (see RaidSpamUI's ApplyDock); raidSpamPanelPosition is only used
		-- while detached.
		raidSpamDocked = true,
	},
}

function JohnnysRaidSpam:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("JohnnysRaidSpamDB", defaults)
end
