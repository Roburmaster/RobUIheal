local ADDON, ns = ...
ns = _G[ADDON] or ns
_G[ADDON] = ns

-- DB is set after ADDON_LOADED, once SavedVariables are populated by the game engine.
local DB

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------
local function SetButtonFromAngle(btn, angle)
    -- Keep on minimap edge
    local rad = math.rad(angle or 0)
    local x = math.cos(rad)
    local y = math.sin(rad)

    -- Typical radius for minimap buttons: ~80
    local radius = 100
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", (x * radius), (y * radius))
end

local function FindSlashHandlerKeyForSlashText(slashText)
    -- Example:
    --   SLASH_RHSETTINGS1 = "/rhsettings"
    --   SlashCmdList["RHSETTINGS"] = function(msg) ... end
    --
    -- We scan globals SLASH_*N and match the text, then extract "RHSETTINGS".
    if type(slashText) ~= "string" or slashText == "" then return nil end

    for k, v in pairs(_G) do
        if type(k) == "string" and k:match("^SLASH_") and type(v) == "string" then
            if v:lower() == slashText:lower() then
                -- k looks like "SLASH_RHSETTINGS1" => extract "RHSETTINGS"
                local name = k:match("^SLASH_(.+)%d+$")
                if name and _G.SlashCmdList and type(_G.SlashCmdList[name]) == "function" then
                    return name
                end
            end
        end
    end

    return nil
end

local function OpenRHSettings()
    -- 1) Try direct known mapping if it exists
    if _G.SlashCmdList and type(_G.SlashCmdList["RHSETTINGS"]) == "function" then
        _G.SlashCmdList["RHSETTINGS"]("")
        return true
    end

    -- 2) Find the actual SlashCmdList key that owns "/rhsettings"
    local key = FindSlashHandlerKeyForSlashText("/rhsettings")
    if key then
        _G.SlashCmdList[key]("")
        return true
    end

    -- 3) If you have a settings module with an opener, try that
    if ns and ns.Settings and type(ns.Settings.Open) == "function" then
        ns.Settings:Open()
        return true
    end

    print("RobUIHeal: Could not open /rhsettings. The slash handler key was not found in SlashCmdList.")
    return false
end

-- ------------------------------------------------------------
-- Create minimap button
-- ------------------------------------------------------------
local minimapButton = CreateFrame("Button", "RobUIHealMinimapButton", Minimap)
minimapButton:SetSize(31, 31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)

-- Make it behave like a normal minimap button
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetClampedToScreen(true)

-- Icon
local icon = minimapButton:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\AddOns\\RobUIHeal\\media\\ruh.png")
icon:SetPoint("CENTER", 0, 1)
icon:SetSize(18, 18)

-- Crop a bit so it sits nicer in the ring (common minimap style)
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

-- Correct minimap button border (NOT tracking border)
local border = minimapButton:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\UI-Minimap-IconBorder")
border:SetPoint("CENTER", 0, 0)
border:SetSize(54, 54)

-- Highlight
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

-- ------------------------------------------------------------
-- Drag logic (angle around minimap)
-- ------------------------------------------------------------
minimapButton:SetScript("OnDragStart", function(self)
    if InCombatLockdown() then return end
    self:LockHighlight()
    self:SetScript("OnUpdate", function(btn)
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = UIParent:GetScale()

        cx = cx / scale
        cy = cy / scale

        local dx = cx - mx
        local dy = cy - my

        local angle = math.deg(math.atan2(dy, dx))
        if angle < 0 then angle = angle + 360 end

        DB.minimapButtonAngle = angle
        SetButtonFromAngle(btn, angle)
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
end)

-- ------------------------------------------------------------
-- Click
-- ------------------------------------------------------------
minimapButton:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        OpenRHSettings()
    elseif button == "RightButton" then
        -- Optional: you can open something else here later
        OpenRHSettings()
    end
end)

-- ------------------------------------------------------------
-- Tooltip
-- ------------------------------------------------------------
minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("RobUIHeal")
    GameTooltip:AddLine("Left-click: Open settings (/rhsettings)", 1, 1, 1)
    GameTooltip:AddLine("Drag: Move button", 1, 1, 1)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
end)

-- ------------------------------------------------------------
-- Initial position (deferred until SavedVariables are loaded)
-- ------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    _G.RobUIHealDB = _G.RobUIHealDB or {}
    DB = _G.RobUIHealDB
    DB.minimapButtonAngle = DB.minimapButtonAngle or 0

    SetButtonFromAngle(minimapButton, DB.minimapButtonAngle)
end)