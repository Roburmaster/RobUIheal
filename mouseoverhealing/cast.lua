-- cct/cast.lua
-- .toc: ## SavedVariables: HealDB
--
-- RobHeal (12.0 Safe & Optimized)
-- - Click-casting on unit frames (mouse buttons + modifiers)  [SHIFT OK on mouse]
-- - Keyboard hover-casting via SecureHandlerEnterLeaveTemplate (CTRL/ALT only recommended; SHIFT may be blocked for keys)
-- - Named secure overlays (fixes Invalid click target name in Restricted env)
-- - Wizard UI: Drag skill -> hold modifier -> press key / or click
--
-- IMPORTANT (12.0):
--   DO NOT hook CompactUnitFrame_* (taints Blizzard CUF -> secret values -> crashes)

local ADDON = "RobHeal"

HealDB = HealDB or {}

-- CONFIG
local KEY_MOUSEOVER_ONLY = true -- true = macro targets @mouseover only (safer for healing)

-- RUNTIME VARS
local registered   = setmetatable({}, { __mode = "k" }) -- [frame] = unitToken
local overlays     = setmetatable({}, { __mode = "k" }) -- [hostFrame] = overlayButton
local pendingWork  = false
local pendingSpell = nil

-- UI VARS
local mainFrame, listScroll, listContent, infoLabel, inputListener, spellPicker
local rowPool = {} -- Reusable UI rows

-- HELPERS
local function RH_Print(msg) print("|cff00ff00[RobHeal]|r " .. tostring(msg)) end
local function RH_Error(msg) print("|cffff0000[RobHeal]|r " .. tostring(msg)) end

-- =========================================================================
--  0. DB HANDLING
-- =========================================================================
local function EnsureDB()
    HealDB = HealDB or {}
    if type(HealDB.clicks) ~= "table" then HealDB.clicks = {} end
    if type(HealDB.keys)   ~= "table" then HealDB.keys   = {} end
end

local function ClickDB() EnsureDB(); return HealDB.clicks end
local function KeyDB()   EnsureDB(); return HealDB.keys end

-- =========================================================================
--  1. SPELL RESOLVE
-- =========================================================================
local function SpellNameFromID(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local si = C_Spell.GetSpellInfo(spellID)
        return si and si.name
    end
    return nil
end

local function SpellNameFromCursor()
    local infoType, info1, _, info3 = GetCursorInfo()
    if not infoType then return nil end

    if infoType == "spell" then
        if C_SpellBook and C_SpellBook.GetSpellBookItemInfo then
            local info = C_SpellBook.GetSpellBookItemInfo(info1, Enum.SpellBookSpellBank.Player)
            if info and info.spellID then
                return SpellNameFromID(info.spellID)
            end
        end
        return SpellNameFromID(info1) or SpellNameFromID(info3)

    elseif infoType == "action" then
        local at, aid = GetActionInfo(info1)
        if at == "spell" then
            return SpellNameFromID(aid)
        end
    end

    return nil
end

-- =========================================================================
--  2. KEY / BUTTON HELPERS
-- =========================================================================
local function GetReadableKey(k) return tostring(k or ""):upper() end

-- MOUSE click attribute key builder (SHIFT OK here)
local function GetClickAttrKey(button)
    local prefix = ""
    if IsAltKeyDown()     then prefix = prefix .. "alt-"   end
    if IsControlKeyDown() then prefix = prefix .. "ctrl-"  end
    if IsShiftKeyDown()   then prefix = prefix .. "shift-" end

    local btnID = "type1"
    if button == "RightButton" then
        btnID = "type2"
    elseif button == "MiddleButton" then
        btnID = "type3"
    else
        local n = button:match("Button(%d+)")
        if n then btnID = "type" .. n end
    end

    return prefix .. btnID
end

local function GetReadableClick(attrKey)
    local s = tostring(attrKey or "")
        :gsub("type1","Left")
        :gsub("type2","Right")
        :gsub("type3","Middle")
        :gsub("type(%d+)","Btn%1")
    return s:upper():gsub("-", " + ")
end

local function IsPureModifier(k)
    k = tostring(k or ""):upper()
    return (k == "SHIFT" or k == "CTRL" or k == "ALT")
end

-- For KEY binds: user holds modifiers while pressing key.
local function BuildHeldKeyString(key)
    local prefix = ""
    if IsAltKeyDown()     then prefix = prefix .. "ALT-"  end
    if IsControlKeyDown() then prefix = prefix .. "CTRL-" end
    if IsShiftKeyDown()   then prefix = prefix .. "SHIFT-" end
    return prefix .. tostring(key or ""):upper()
end

local function BuildMacro(spellName)
    local s = tostring(spellName or "")
    if KEY_MOUSEOVER_ONLY then
        return "/cast [@mouseover,help,nodead] " .. s
    end
    return "/cast [@mouseover,help,nodead] " .. s .. "; [help,nodead] " .. s .. "; [@player] " .. s
end

-- =========================================================================
--  3. SECURE OVERLAY SYSTEM (12.0 RESTRICTED SAFE)
-- =========================================================================
-- SetBindingClick in restricted env requires a NAMED click target.
-- Therefore overlays MUST have a unique global name.

local RH_OVERLAY_ID = 0

local function EnsureOverlay(hostFrame)
    if not hostFrame then return nil end
    local existing = overlays[hostFrame]
    if existing then return existing end
    if InCombatLockdown() then pendingWork = true return nil end

    RH_OVERLAY_ID = RH_OVERLAY_ID + 1
    local overlayName = "RobHealOverlay" .. RH_OVERLAY_ID

    local overlay = CreateFrame(
        "Button",
        overlayName,
        hostFrame,
        "SecureActionButtonTemplate,SecureHandlerEnterLeaveTemplate"
    )

    overlay:SetAllPoints(hostFrame)
    overlay:SetFrameLevel((hostFrame:GetFrameLevel() or 0) + 10)
    overlay:EnableMouse(true)
    overlay:RegisterForClicks("AnyUp", "AnyDown")

    -- Secure enter: bind keys ONLY while hovering this overlay
    overlay:SetAttribute("_onenter", [[
        self:ClearBindings()
        local target = self:GetName()
        if not target or target == "" then return end

        local n = self:GetAttribute("rh_num") or 0
        for i = 1, n do
            local k = self:GetAttribute("rh_key"..i)
            local b = self:GetAttribute("rh_btn"..i)
            if k and b then
                self:SetBindingClick(true, k, target, b)
            end
        end
    ]])

    overlay:SetAttribute("_onleave", [[
        self:ClearBindings()
    ]])

    overlays[hostFrame] = overlay

    -- Let host frames hook overlay clicks/visuals (hostFrame won't receive clicks).
    -- This is NOT secure code; it's a normal callback, safe in 12.0.
    if hostFrame and type(hostFrame.RobHeal_OnOverlayCreated) == "function" then
        pcall(hostFrame.RobHeal_OnOverlayCreated, hostFrame, overlay)
    end

    return overlay
end

-- =========================================================================
--  4. APPLY BINDINGS
-- =========================================================================
local function ApplyToOverlay(overlay, unit)
    if not overlay then return end
    if InCombatLockdown() then pendingWork = true return end

    if unit and unit ~= "" then
        overlay:SetAttribute("unit", unit)
    end

-- Default left click targets (so Blizzard target frame updates)
-- SHIFT is left alone so it can be used for healing binds (shift-type1 spell)
overlay:SetAttribute("type1", "target")
overlay:SetAttribute("spell1", nil)
overlay:SetAttribute("macrotext1", nil)



    -- 1) CLICK CASTS (mouse) - supports shift/ctrl/alt through attribute keys
    local clicks = ClickDB()
    for attrKey, spellName in pairs(clicks) do
        if spellName and spellName ~= "" then
            local spellAttr = attrKey:gsub("type", "spell") -- shift-type1 -> shift-spell1
            overlay:SetAttribute(attrKey, "spell")
            overlay:SetAttribute(spellAttr, spellName)
        end
    end

    -- 2) KEY CASTS (hover keys)
    local keys = KeyDB()

    local i = 0
    for keyStr, spellName in pairs(keys) do
        if spellName and spellName ~= "" then
            i = i + 1

            local cleanKey   = tostring(keyStr):gsub("[^A-Za-z0-9]", "")
            local virtualBtn = "RH_" .. cleanKey .. "_" .. i

            overlay:SetAttribute("type-" .. virtualBtn, "macro")
            overlay:SetAttribute("macrotext-" .. virtualBtn, BuildMacro(spellName))

            overlay:SetAttribute("rh_key"..i, keyStr)
            overlay:SetAttribute("rh_btn"..i, virtualBtn)
        end
    end

    overlay:SetAttribute("rh_num", i)
end

local function RefreshAll()
    if InCombatLockdown() then
        pendingWork = true
        return
    end

    for hostFrame, unit in pairs(registered) do
        local overlay = EnsureOverlay(hostFrame)
        if overlay then
            ApplyToOverlay(overlay, unit)
        end
    end
end

-- =========================================================================
--  5. UI SYSTEM (Optimized)
-- =========================================================================
local function UpdateList()
    if not listContent then return end

    for _, row in pairs(rowPool) do row:Hide() end

    local data = {}
    for k, v in pairs(ClickDB()) do table.insert(data, { type="CLICK", key=k, spell=v }) end
    for k, v in pairs(KeyDB())   do table.insert(data, { type="KEY",   key=k, spell=v }) end
    table.sort(data, function(a,b) return (a.type..a.key) < (b.type..b.key) end)

    local y = 0
    for idx, item in ipairs(data) do
        local row = rowPool[idx]
        if not row then
            row = CreateFrame("Frame", nil, listContent, "BackdropTemplate")
            row:SetSize(395, 30)
            row:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8x8" })
            row:SetBackdropColor(0.1, 0.1, 0.1, 0.5)

            row.tSpell = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.tSpell:SetPoint("LEFT", 5, 0)

            row.tKey = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.tKey:SetPoint("RIGHT", -30, 0)

            row.btnDel = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.btnDel:SetSize(24, 24)
            row.btnDel:SetPoint("RIGHT", 0, 0)

            rowPool[idx] = row
        end

        row:SetPoint("TOPLEFT", 5, y)
        row:Show()

        row.tSpell:SetText(item.spell or "")
        row.tKey:SetText(item.type == "CLICK" and GetReadableClick(item.key) or GetReadableKey(item.key))

        row.btnDel:SetScript("OnClick", function()
            if InCombatLockdown() then RH_Error("Combat error") return end

            if item.type == "CLICK" then
                ClickDB()[item.key] = nil
            else
                KeyDB()[item.key] = nil
            end

            UpdateList()
            RefreshAll()
            RH_Print("Bindings refreshed.")
        end)

        y = y - 32
    end
end

local function EnsureUI()
    if mainFrame then return mainFrame end

    mainFrame = CreateFrame("Frame", "RobHealFrame", UIParent, "BasicFrameTemplateWithInset")
    mainFrame:SetSize(460, 520)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    mainFrame.TitleText:SetText("RobHeal Config")
    mainFrame:Hide()

    listScroll = CreateFrame("ScrollFrame", nil, mainFrame, "UIPanelScrollFrameTemplate")
    listScroll:SetSize(420, 320)
    listScroll:SetPoint("TOP", 0, -40)

    listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(420, 1000)
    listScroll:SetScrollChild(listContent)

    infoLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    infoLabel:SetPoint("BOTTOM", 0, 140)
    infoLabel:SetJustifyH("CENTER")
    infoLabel:SetText("")

    local warn = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    warn:SetPoint("BOTTOM", 0, 118)
    warn:SetJustifyH("CENTER")
    warn:SetText("|cffffaa00Warning: Using SHIFT + keyboard may not work for mouseover healing.|r")

    local help = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("BOTTOM", 0, 98)
    help:SetJustifyH("CENTER")
    help:SetText("Drag skill to button. Hold modifier then press desired key. Mouse can be used with no modifier.")

    -- INPUT LISTENER
    inputListener = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    inputListener:SetSize(420, 420)
    inputListener:SetPoint("CENTER")
    inputListener:SetFrameStrata("DIALOG")
    inputListener:SetBackdrop({ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark" })
    inputListener:Hide()
    inputListener:EnableMouse(true)

    local lText = inputListener:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    lText:SetPoint("CENTER", 0, 20)
    lText:SetText("HOLD MODIFIER + PRESS KEY OR CLICK")

    local keyBox = CreateFrame("EditBox", nil, inputListener)
    keyBox:SetSize(1,1)
    keyBox:SetAutoFocus(false)
    keyBox:EnableKeyboard(true)

    local function SaveBind(bindType, key)
        if InCombatLockdown() then RH_Error("Combat error") return end
        if not pendingSpell or pendingSpell == "" then return end

        if bindType == "CLICK" then
            ClickDB()[key] = pendingSpell
        else
            KeyDB()[key] = pendingSpell
        end

        pendingSpell = nil
        inputListener:Hide()
        keyBox:ClearFocus()
        UpdateList()
        RefreshAll()
        RH_Print("Bindings refreshed.")
    end

    inputListener:SetScript("OnMouseDown", function(_, btn)
        if not pendingSpell then return end
        local k = GetClickAttrKey(btn)
        SaveBind("CLICK", k)
    end)

    keyBox:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then
            pendingSpell = nil
            inputListener:Hide()
            return
        end
        if not pendingSpell or IsPureModifier(key) then return end

        local k = BuildHeldKeyString(key)
        SaveBind("KEY", k)
    end)

    inputListener:SetScript("OnShow", function() keyBox:SetFocus() end)
    inputListener:SetScript("OnHide", function() keyBox:ClearFocus() end)

    -- SPELL PICKER
    spellPicker = CreateFrame("Frame")
    spellPicker:Hide()
    spellPicker:SetScript("OnUpdate", function(self)
        local name = SpellNameFromCursor()
        if name then
            pendingSpell = name
            ClearCursor()
            self:Hide()
            infoLabel:SetText("Selected: "..name..". Now hold modifier and press key, or click.")
            inputListener:Show()
        end
    end)

    -- BUTTONS
    local btnAdd = CreateFrame("Button", nil, mainFrame, "GameMenuButtonTemplate")
    btnAdd:SetSize(220, 40)
    btnAdd:SetPoint("BOTTOMLEFT", 12, 50)
    btnAdd:SetText("Drag skill here!")
    btnAdd:SetScript("OnClick", function()
        if InCombatLockdown() then RH_Error("Can't edit in combat.") return end
        infoLabel:SetText("DRAG A SPELL FROM SPELLBOOK NOW")
        spellPicker:Show()
    end)

    local btnClear = CreateFrame("Button", nil, mainFrame, "GameMenuButtonTemplate")
    btnClear:SetSize(160, 40)
    btnClear:SetPoint("BOTTOMRIGHT", -12, 50)
    btnClear:SetText("Clear All")
    btnClear:SetScript("OnClick", function()
        if InCombatLockdown() then RH_Error("Can't edit in combat.") return end
        wipe(ClickDB()); wipe(KeyDB())
        UpdateList()
        RefreshAll()
        RH_Print("Bindings refreshed.")
    end)

    UpdateList()
    return mainFrame
end

-- =========================================================================
--  6. PUBLIC API
-- =========================================================================
_G.RobHeal_RegisterFrame = function(frame, unit)
    if not frame or not unit then return end
    registered[frame] = unit
    RefreshAll()
end

_G.RobHeal_RefreshBindings = function()
    RefreshAll()
    RH_Print("Bindings refreshed.")
end

-- =========================================================================
--  7. INIT
-- =========================================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        EnsureDB()

        -- DO NOT hook CompactUnitFrame_* in 12.0.
        -- Party/Raid modules must call RobHeal_RegisterFrame() for their own frames.

        RefreshAll()
        RH_Print("Loaded.")

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingWork then
            pendingWork = false
            RefreshAll()
            RH_Print("Bindings refreshed.")
        end
    end
end)

SLASH_ROBHEAL1 = "/robheal"
SlashCmdList.ROBHEAL = function()
    local f = EnsureUI()
    if f:IsShown() then f:Hide() else f:Show() end
end
