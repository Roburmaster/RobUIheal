-- ============================================================================
-- migration_msg.lua (RobHeal)
-- Displays a one-time message per character explaining the DB reset
-- and the new profile system.
-- ============================================================================

local ADDON, ns = ...

local TEX = "Interface\\Buttons\\WHITE8X8"

-- Create the main popup frame
local frame = CreateFrame("Frame", "RobHealMigrationFrame", UIParent, "BackdropTemplate")
frame:SetSize(420, 220)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
frame:SetFrameStrata("DIALOG")
frame:SetBackdrop({ bgFile = TEX, edgeFile = TEX, edgeSize = 1 })
frame:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
frame:SetBackdropBorderColor(0, 0, 0, 1)
frame:Hide()

-- Title
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", frame, "TOP", 0, -18)
title:SetText("RobHeal - Important Update")
title:SetTextColor(1, 0.82, 0, 1)

-- Body Text
local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
body:SetPoint("TOPLEFT", frame, "TOPLEFT", 25, -55)
body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -25, 60)
body:SetJustifyH("CENTER")
body:SetJustifyV("TOP")
body:SetText("We sincerely apologize, but your previous settings were lost during the recent update.\n\nThe good news is that we have completely rebuilt the backend! RobHeal now features a robust, account-wide Profile System. You can finally set up your layouts once and easily share them across all your characters.\n\nThank you for your patience and support!")
body:SetTextColor(0.85, 0.85, 0.85, 1)

-- Acknowledge Button
local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
btn:SetSize(140, 28)
btn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 18)
btn:SetBackdrop({ bgFile = TEX, edgeFile = TEX, edgeSize = 1 })
btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
btn:SetBackdropBorderColor(0, 0, 0, 1)

local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
btnText:SetPoint("CENTER", 0, 0)
btnText:SetText("I Understand")
btnText:SetTextColor(0.9, 0.9, 0.9, 1)

-- Hover effects for the button
btn:SetScript("OnEnter", function()
    btn:SetBackdropColor(0.28, 0.28, 0.28, 1)
    btnText:SetTextColor(1, 1, 1, 1)
end)
btn:SetScript("OnLeave", function()
    btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
    btnText:SetTextColor(0.9, 0.9, 0.9, 1)
end)

-- Click action: Save state to character DB and hide frame
btn:SetScript("OnClick", function()
    if _G.RobHealCharDB then
        _G.RobHealCharDB.seenMigrationMsg = true
    end
    frame:Hide()
end)

-- Event listener to show the frame upon login if not seen before
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self, event, isInitialLogin, isReloadingUi)
    -- Only check on actual logins or UI reloads
    if isInitialLogin or isReloadingUi then
        -- Delay slightly to ensure DB is fully initialized
        C_Timer.After(1.5, function()
            -- Show if DB exists and the flag is NOT true
            if _G.RobHealCharDB and not _G.RobHealCharDB.seenMigrationMsg then
                frame:Show()
            end
        end)
    end
end)
