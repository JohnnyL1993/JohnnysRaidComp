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
	frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
end

function Skin:StyleButton(btn)
	btn:SetBackdrop({ bgFile = self.WHITE, edgeFile = self.WHITE, edgeSize = 1 })
	btn:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
	btn:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

	local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture(self.WHITE)
	highlight:SetVertexColor(1, 1, 1, 0.12)
	btn:SetHighlightTexture(highlight)

	btn:SetScript("OnMouseDown", function(self)
		if self:IsEnabled() then
			self:SetBackdropColor(0.18, 0.18, 0.18, 0.95)
		end
	end)
	btn:SetScript("OnMouseUp", function(self)
		self:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
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
	mark:SetTextColor(1, 1, 1)
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
