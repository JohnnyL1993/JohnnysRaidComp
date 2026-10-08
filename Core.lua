JohnnysRaidComp = LibStub("AceAddon-3.0"):NewAddon("JohnnysRaidComp")

local defaults = {
	profile = {
		raidCompSelectedRaid = nil,
		raidCompSelectedSize = nil,
		raidCompPanelPosition = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
		raidCompManualAssignments = {},
		raidCompRoleCounts = {},
		-- Off = no class-pinned slots (Shaman, Mage, ...); every DPS/healer
		-- slot is a plain "Any DPS"/"Any Healer". Toggled from the comp
		-- screen's "Class slots" button, applies to every raid+size.
		raidCompClassPins = true,
		raidCompClassRunTank = {},
		raidCompClassRunHealers = {},
		-- Standalone launcher (see Modules\Launcher.lua) - only used when
		-- Johnny's Addon Hub isn't installed to open this addon's windows.
		-- nil launcherMode = the user hasn't picked a style yet, so first
		-- login without the hub shows the chooser prompt.
		launcherMode = nil, -- "minimap" | "hub" | "none"
		launcherPanelPosition = { point = "CENTER", relativePoint = "CENTER", x = -250, y = 200 },
		launcherPanelCollapsed = false,
		minimapButtonAngle = 200,
		-- Per-window scale/opacity (see Modules\WindowSettings.lua). Keyed by
		-- window ("raidcomp" / "raidspam" / "launcher"), each holding its own
		-- { scale=, opacity= }; floored at 0.4 by the panel's +/- controls.
		windowSettings = {},
		-- Achievement/kill-count lines in the slot-card/bench-chip tooltip
		-- (see Modules\RaidCompUI\UI.lua's achievement lookup section). Off
		-- also stops the scans themselves, not just the tooltip lines.
		showAchievementTooltip = true,
	},
	-- Shared account-wide, not per-character - a raid member's GearScore isn't
	-- tied to which of your own alts happened to inspect them (see
	-- Modules\RaidCompUI\UI.lua's GearScore lookup section).
	global = {
		raidCompGearScores = {},
		-- [name] = { ach = {[id]=bool}, stats = {[id]="7"}, updatedAt = time() }.
		-- time(), not GetTime(), so the stale check survives a client restart.
		raidCompAchievements = {},
		-- Highest addon version heard from other players (see
		-- Modules\VersionCheck.lua); nil when we're up to date.
		latestSeenVersion = nil,
	},
}

function JohnnysRaidComp:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("JohnnysRaidCompDB", defaults)
end
