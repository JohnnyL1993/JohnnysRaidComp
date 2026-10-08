JohnnysRaidSpam = LibStub("AceAddon-3.0"):NewAddon("JohnnysRaidSpam")

local defaults = {
	profile = {
		raidSpamRecruitGS = 0,
		raidSpamRecruitTemplate = "[LFM] {raid} ({size}) - GS {gs}+ required - Need: {need} - {quest} - whisper me!",
		-- Per-channel tick + repeat interval for the Channels list, keyed by the
		-- channel's lowercased base name ("trade", "global") or chat type
		-- ("YELL"): { enabled = bool, interval = sec }.
		-- The old Channel 1/Channel 2 settings (raidSpamRecruitChannel/Interval
		-- and ...2) are migrated into this once; see MigrateLegacyChannels.
		raidSpamChannels = {},
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
