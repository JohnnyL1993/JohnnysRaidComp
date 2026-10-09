-- Shared flat black/white "modern" skin, used by every module's UI so the whole
-- addon looks like one consistent panel instead of a patchwork of Blizzard's
-- stock red/gold button art and parchment dialog borders.
JohnnysRaidComp.Skin = {}
local Skin = JohnnysRaidComp.Skin

-- Flat white 1x1 texture, tinted per-use - the standard trick for solid-color
-- panels/borders without needing any custom art.
Skin.WHITE = "Interface\\Buttons\\WHITE8X8"

function Skin:StylePanel(frame, alpha)
	frame:SetBackdrop({ bgFile = self.WHITE, edgeFile = self.WHITE, edgeSize = 1 })
	frame:SetBackdropColor(0.03, 0.03, 0.03, alpha or 0.92)
	frame:SetBackdropBorderColor(0.180, 0.224, 0.243, 1)
end

function Skin:StyleButton(btn)
	btn:SetBackdrop({ bgFile = self.WHITE, edgeFile = self.WHITE, edgeSize = 1 })
	btn:SetBackdropColor(0.090, 0.114, 0.125, 0.95)
	btn:SetBackdropBorderColor(0.243, 0.298, 0.322, 1)

	local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture(self.WHITE)
	highlight:SetVertexColor(0.725, 0.886, 0.290, 0.14)
	btn:SetHighlightTexture(highlight)

	btn:SetScript("OnMouseDown", function(self)
		if self:IsEnabled() then
			self:SetBackdropColor(0.160, 0.200, 0.220, 0.95)
		end
	end)
	btn:SetScript("OnMouseUp", function(self)
		self:SetBackdropColor(0.090, 0.114, 0.125, 0.95)
	end)
end

-- Creates a flat-skinned button with a centered white label. Returns the
-- button; its font string is at btn.text if the caller needs to recolor it
-- (e.g. greying out an unavailable spec tab). `template` is optional - pass
-- "SecureActionButtonTemplate" for buttons that need to trigger protected
-- actions (macros, other secure frames) that a plain OnClick can't reach.
function Skin:CreateButton(parent, width, height, text, template)
	local btn = CreateFrame("Button", nil, parent, template)
	btn:SetSize(width, height)
	self:StyleButton(btn)

	local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER")
	fs:SetTextColor(1, 1, 1)
	if text then
		fs:SetText(text)
	end
	btn.text = fs

	return btn
end

-- A flat toggle button standing in for a checkbox - callers own the actual
-- boolean state (often mirroring some other addon's native checkbox widget),
-- this just renders it and reports clicks back via onToggle. SetChecked/
-- GetChecked let a caller keep this in sync with state that can change out
-- from under it.
function Skin:CreateCheckbox(parent, size, initialState, onToggle)
	local box = CreateFrame("Button", nil, parent)
	box:SetSize(size, size)
	self:StyleButton(box)

	local mark = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	mark:SetPoint("CENTER")
	mark:SetTextColor(0.725, 0.886, 0.290)
	box.mark = mark
	box.checked = initialState and true or false
	mark:SetText(box.checked and "X" or "")

	box:SetScript("OnClick", function(self)
		self.checked = not self.checked
		self.mark:SetText(self.checked and "X" or "")
		if onToggle then
			onToggle(self.checked)
		end
	end)

	function box:SetChecked(state)
		self.checked = state and true or false
		self.mark:SetText(self.checked and "X" or "")
	end

	function box:GetChecked()
		return self.checked
	end

	return box
end

-- A flat-skinned text entry: a StylePanel'd holder frame containing a plain
-- EditBox with no Blizzard InputBoxTemplate border art. Returns the holder;
-- the actual EditBox is at holder.editBox for callers that need GetText/
-- SetText/focus scripts.
function Skin:CreateEditBox(parent, width, height)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(width, height)
	self:StylePanel(holder, 0.95)

	local edit = CreateFrame("EditBox", nil, holder)
	edit:SetPoint("LEFT", 4, 0)
	edit:SetPoint("RIGHT", -4, 0)
	edit:SetHeight(height)
	edit:SetAutoFocus(false)
	edit:SetFontObject(GameFontHighlightSmall)
	edit:SetTextColor(1, 1, 1)
	edit:SetScript("OnEscapePressed", edit.ClearFocus)
	edit:SetScript("OnEnterPressed", edit.ClearFocus)
	holder.editBox = edit

	return holder
end

----------------------------------------------------------------------------
-- "Workshop rack" look shared with the Addon Hub drawer: blue-black panels,
-- 1px rules, one lime accent, condensed uppercase headings. The Style*
-- functions above already use these values; the helpers below are for
-- window title strips, section headings and numbered rows.
----------------------------------------------------------------------------
Skin.C = {
	ground = { 0.063, 0.078, 0.086 },
	panel = { 0.090, 0.114, 0.125 },
	rule = { 0.180, 0.224, 0.243 },
	rule2 = { 0.243, 0.298, 0.322 },
	text = { 0.902, 0.925, 0.918 },
	muted = { 0.604, 0.659, 0.651 },
	dim = { 0.560, 0.620, 0.610 },
	accent = { 0.725, 0.886, 0.290 },
	short = { 1.000, 0.450, 0.400 },
}
Skin.FONT_HEAD = "Fonts\\ARIALN.TTF"
Skin.FONT_TEXT = "Fonts\\FRIZQT__.TTF"
Skin.HEADER_HEIGHT = 28

-- Heading text (titles, counts, row numbers). Arial Narrow gets thin and hard
-- to read below about 14px, so only the larger sizes use it - small headings
-- fall back to the game's regular face.
function Skin:Heading(parent, size, color)
	color = color or self.C.text
	local fs = parent:CreateFontString(nil, "OVERLAY")
	if size < 14 then
		fs:SetFont(self.FONT_TEXT, math.max(10, size - 1))
	else
		fs:SetFont(self.FONT_HEAD, size)
	end
	fs:SetTextColor(color[1], color[2], color[3])
	return fs
end

function Skin:Solid(parent, layer, color)
	local tex = parent:CreateTexture(nil, layer)
	tex:SetTexture(self.WHITE)
	tex:SetVertexColor(color[1], color[2], color[3], 1)
	return tex
end

-- Title strip across the top of a StylePanel'd window: a lighter band with a
-- rule under it and the title top-left in uppercase. Returns the title's
-- font string so callers can anchor a breadcrumb or count after it.
function Skin:AddHeader(frame, text, size)
	local bg = self:Solid(frame, "BORDER", self.C.panel)
	bg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
	bg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
	bg:SetHeight(self.HEADER_HEIGHT - 1)

	local rule = self:Solid(frame, "ARTWORK", self.C.rule)
	rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -self.HEADER_HEIGHT)
	rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -self.HEADER_HEIGHT)
	rule:SetHeight(1)

	size = size or 16
	local title = self:Heading(frame, size, self.C.text)
	title:SetPoint("LEFT", frame, "TOPLEFT", 12, -self.HEADER_HEIGHT / 2)
	title:SetText(string.upper(text))
	return title
end
