-- Per-window scale & opacity for this addon's frames.
--
-- Self-contained per addon (the same way each of Johnny's addons carries its
-- own copy of Skin.lua): this addon keeps its own copy of this file and its
-- own saved values - nothing here is shared with the other addons. A window
-- registers itself from its BuildFrame with a unique key; the "Cfg" button on
-- any of this addon's windows opens one panel that shows a Scale + Opacity
-- +/- stepper pair for every registered window. Both values are floored at
-- 40% - below that a window gets hard to find and click.

local NS = JohnnysRaidComp
NS.WindowSettings = {}
local WS = NS.WindowSettings
local Skin = NS.Skin

local MIN_VALUE = 0.4
local STEP = 0.05

local PANEL_W = 224
local PAD = 14
local GROUP_H = 20 + 22 + 22 -- header + scale row + opacity row
local GROUP_GAP = 12

-- Declared up front so WS:Register (below) closes over the real locals.
local panel
local groups = {} -- key -> Frame (with .scaleReadout / .opacityReadout)
local windows = {} -- ordered: { {frame=, key=, label=}, ... }
local byKey = {}
-- Plain on/off feature toggles listed under the window groups - ordered:
-- { {key=, label=, get=, set=, row=}, ... }. See WS:RegisterOption.
local options = {}
local optionsHeader
local Relayout

-- Persistent per-window store, shape: { [key] = { scale=, opacity= }, __panel = {...} }
local function Store()
	local root = NS.db.profile
	root.windowSettings = root.windowSettings or {}
	return root.windowSettings
end

local function Cfg(key)
	local s = Store()
	s[key] = s[key] or {}
	return s[key]
end

local function Round2(v)
	return math.floor(v * 100 + 0.5) / 100
end

local function Clamp(v)
	v = Round2(v)
	if v < MIN_VALUE then
		return MIN_VALUE
	elseif v > 1 then
		return 1
	end
	return v
end

local function Pct(v)
	return string.format("%d%%", math.floor((v or 1) * 100 + 0.5))
end

----------------------------------------------------------------------------
-- Registration / apply
----------------------------------------------------------------------------
function WS:Apply(key)
	local w = byKey[key]
	if not w or not w.frame then
		return
	end
	local c = Cfg(key)
	w.frame:SetScale(c.scale or 1)
	w.frame:SetAlpha(c.opacity or 1)
end

-- Called by each window right after it builds its frame. Safe to call again
-- on a rebuild - it just re-points the stored frame and re-applies.
function WS:Register(frame, key, label)
	local w = byKey[key]
	if w then
		w.frame = frame
	else
		w = { frame = frame, key = key, label = label or key }
		byKey[key] = w
		table.insert(windows, w)
	end
	self:Apply(key)
	if panel and panel:IsShown() then
		Relayout()
	end
end

-- Adds a checkbox row to the panel's "Options" section. getFn returns the
-- current state (read each time the panel lays out, so it's fine to call
-- before SavedVariables load); setFn receives the new state on click. Owners
-- keep their own saved value - nothing is stored here.
function WS:RegisterOption(key, label, getFn, setFn)
	for _, o in ipairs(options) do
		if o.key == key then
			return
		end
	end
	table.insert(options, { key = key, label = label, get = getFn, set = setFn })
	if panel and panel:IsShown() then
		Relayout()
	end
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------
local function SavePanelPos()
	local point, _, rel, x, y = panel:GetPoint()
	Store().__panel = { point = point, rel = rel, x = x, y = y }
end

local function RefreshRow(key)
	local g = groups[key]
	if not g then
		return
	end
	local c = Cfg(key)
	g.scaleReadout:SetText(Pct(c.scale))
	g.opacityReadout:SetText(Pct(c.opacity))
end

local function Bump(key, field, delta)
	local c = Cfg(key)
	c[field] = Clamp((c[field] or 1) + delta)
	WS:Apply(key)
	RefreshRow(key)
end

-- One "Label [-] NN% [+]" line inside a group frame; returns the NN% readout.
local function StepperLine(group, y, labelText, key, field)
	local label = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", 0, y)
	label:SetText(labelText)

	local minus = Skin:CreateButton(group, 22, 18, "-")
	minus:SetPoint("TOPLEFT", 66, y + 2)
	minus:SetScript("OnClick", function() Bump(key, field, -STEP) end)

	local readout = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	readout:SetPoint("LEFT", minus, "RIGHT", 6, 0)
	readout:SetWidth(44)
	readout:SetJustifyH("CENTER")

	local plus = Skin:CreateButton(group, 22, 18, "+")
	plus:SetPoint("LEFT", readout, "RIGHT", 6, 0)
	plus:SetScript("OnClick", function() Bump(key, field, STEP) end)

	return readout
end

local function EnsureGroup(w)
	local g = groups[w.key]
	if g then
		return g
	end
	g = CreateFrame("Frame", nil, panel)
	g:SetSize(PANEL_W - PAD * 2, GROUP_H)

	g.header = g:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	g.header:SetPoint("TOPLEFT", 0, 0)
	g.header:SetTextColor(1, 1, 1)
	g.header:SetText(w.label)

	g.scaleReadout = StepperLine(g, -20, "Scale", w.key, "scale")
	g.opacityReadout = StepperLine(g, -42, "Opacity", w.key, "opacity")
	groups[w.key] = g
	return g
end

-- Assigned (not redeclared) so the forward-declared local above is filled in.
Relayout = function()
	if not panel then
		return
	end
	local y = -40
	for _, w in ipairs(windows) do
		local g = EnsureGroup(w)
		g:ClearAllPoints()
		g:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
		g:Show()
		RefreshRow(w.key)
		y = y - (GROUP_H + GROUP_GAP)
	end

	if #options > 0 then
		if not optionsHeader then
			optionsHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			optionsHeader:SetTextColor(1, 1, 1)
			optionsHeader:SetText("Options")
		end
		optionsHeader:ClearAllPoints()
		optionsHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
		y = y - 20
		for _, o in ipairs(options) do
			if not o.row then
				local opt = o
				o.row = Skin:CreateCheckbox(panel, 16, false, function(checked)
					opt.set(checked)
				end)
				local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				label:SetPoint("LEFT", o.row, "RIGHT", 6, 0)
				label:SetWidth(PANEL_W - PAD * 2 - 22)
				label:SetJustifyH("LEFT")
				label:SetText(o.label)
			end
			o.row:ClearAllPoints()
			o.row:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
			o.row:SetChecked(o.get())
			y = y - 22
		end
		y = y - GROUP_GAP
	end

	panel:SetHeight(-y + 12)
end

local function BuildPanel()
	panel = CreateFrame("Frame", nil, UIParent)
	panel:SetSize(PANEL_W, 120)

	local p = Store().__panel
	if p then
		panel:SetPoint(p.point or "CENTER", UIParent, p.rel or "CENTER", p.x or 0, p.y or 0)
	else
		panel:SetPoint("CENTER")
	end

	panel:SetFrameStrata("FULLSCREEN_DIALOG") -- above the windows it configures
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePanelPos()
	end)
	Skin:StylePanel(panel, 0.97)

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	title:SetPoint("TOP", 0, -12)
	title:SetText("Window Scale / Opacity")

	local close = Skin:CreateButton(panel, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() panel:Hide() end)
end

function WS:Toggle()
	if not panel then
		BuildPanel()
	end
	if panel:IsShown() then
		panel:Hide()
	else
		Relayout()
		panel:Show()
	end
end

-- Convenience: a "Cfg" button on `parent`, tucked left of the close X.
function WS:AttachButton(parent)
	local btn = Skin:CreateButton(parent, 40, 20, "Cfg")
	btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -28, -4)
	btn:SetScript("OnClick", function() WS:Toggle() end)
	return btn
end
