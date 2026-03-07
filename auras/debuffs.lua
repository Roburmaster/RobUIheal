-- ============================================================================
-- debuffs.lua (RobHeal) - WoW 12.0 / Midnight
-- TWO-ROW SOLUTION (WORKING DESIGN):
--   - Row 1 (TOP):   BOSS/PRIVATE AURAS via C_UnitAuras.AddPrivateAuraAnchor (bigger icons)
--   - Row 2 (BOTTOM):NORMAL debuffs via C_UnitAuras.GetAuraDataByIndex (DurationObject for swipe+countdown)
--
-- Hard rules:
--   - NO IsAddOnLoaded / LoadAddOn (restricted env can nil those)
--   - NO secret value math/comparisons (no exp/dur math; use DurationObject)
--   - Private auras are NOT readable; Blizzard draws them into our "priv" frames.
-- ============================================================================

local _, ns = ...
ns.Debuffs = ns.Debuffs or {}
local Debuffs = ns.Debuffs

local UnitExists  = UnitExists
local UnitAura    = UnitAura
local GameTooltip = GameTooltip
local pcall       = pcall
local floor       = math.floor
local max         = math.max
local tonumber    = tonumber
local type        = type
local select      = select
local ipairs      = ipairs

local CUA = C_UnitAuras
local C_Spell = C_Spell
local GetAuraDataByIndex = CUA and CUA.GetAuraDataByIndex or nil
local GetAuraDuration    = CUA and CUA.GetAuraDuration or nil

local scrubsecretvalues  = _G.scrubsecretvalues

-- ============================================================
-- CONFIG
-- ============================================================
local MAX_PRIVATE = 6
local MAX_NORMAL  = 6

local PRIVATE_SIZE = 20
local NORMAL_SIZE  = 16
local GAP          = 2
local ROW_GAP      = 2

local PRIVATE_SCAN_TICK = 0.20
local PRIVATE_COVER_INSET = 2

Debuffs.DEFAULT_ANCHOR = "BOTTOM"

-- ============================================================
-- DEBUG
-- ============================================================
local RH_DEBUFF_DEBUG = false

local function dprint(...)
    if RH_DEBUFF_DEBUG then
        print("|cff00ff00[RobHeal Debuffs]|r", ...)
    end
end

SLASH_ROBHEALDEBUFFDBG1 = "/rhdebuffdbg"
SlashCmdList.ROBHEALDEBUFFDBG = function()
    RH_DEBUFF_DEBUG = not RH_DEBUFF_DEBUG
    print("|cff00ff00[RobHeal Debuffs]|r debug:", RH_DEBUFF_DEBUG and "ON" or "OFF")
end

SLASH_ROBHEALDEBUFFDUMP1 = "/rhdebuffdump"
SlashCmdList.ROBHEALDEBUFFDUMP = function()
    print("|cff00ff00[RobHeal Debuffs]|r",
        "UnitAura:", UnitAura and "YES" or "NO",
        "CUA:", CUA and "YES" or "NO",
        "GetAuraDataByIndex:", GetAuraDataByIndex and "YES" or "NO",
        "GetAuraDuration:", GetAuraDuration and "YES" or "NO",
        "AddPrivateAuraAnchor:", (CUA and CUA.AddPrivateAuraAnchor) and "YES" or "NO",
        "RemovePrivateAuraAnchor:", (CUA and CUA.RemovePrivateAuraAnchor) and "YES" or "NO",
        "SetCooldownFromDurationObject:", (CreateFrame("Cooldown"):GetObjectType() and true) and "MAYBE" or "?"
    )
end

-- ============================================================
-- HELPERS
-- ============================================================
local function SafeToNumber(v)
    if v == nil then return 0 end
    if scrubsecretvalues then
        local sv = select(1, scrubsecretvalues(v))
        if type(sv) == "number" then return sv end
        return 0
    end
    if type(v) == "number" then return v end
    return 0
end

local function SafeToID(v)
    local n = SafeToNumber(v)
    if n > 0 then return n end
    return nil
end

local function GetSpellTextureSafe(spellId)
    if not spellId or not (C_Spell and C_Spell.GetSpellTexture) then return nil end
    local ok, tex = pcall(C_Spell.GetSpellTexture, spellId)
    if ok then return tex end
    return nil
end

-- ============================================================
-- SAFE UI CALLS
-- ============================================================
local function SafeShown(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsShown() end)
    return ok and v or false
end

local function SafeAlpha(obj)
    if not obj then return 0 end
    local ok, v = pcall(function()
        if obj.GetAlpha then return obj:GetAlpha() end
        return 1
    end)
    if ok and type(v) == "number" then return v end
    return 0
end

local function SafeTexture(texObj)
    if not texObj then return nil end
    local ok, v = pcall(function()
        if texObj.GetTexture then return texObj:GetTexture() end
        return nil
    end)
    if ok then return v end
    return nil
end

-- ============================================================
-- HP BAR COLOR PICKER
-- ============================================================
local function GetHPBarColor(frame)
    if not frame then return nil end

    local candidates = {
        frame.health, frame.hp, frame.healthBar, frame.hpBar,
        frame.Health, frame.HP, frame.HealthBar, frame.HPBar,
        frame.statusBar, frame.status, frame.bar
    }

    for _, sb in ipairs(candidates) do
        if sb and sb.GetObjectType then
            local okType, t = pcall(function() return sb:GetObjectType() end)
            if okType and t == "StatusBar" then
                local ok, r, g, b = pcall(function() return sb:GetStatusBarColor() end)
                if ok and r and g and b then
                    local a = 1
                    if sb.GetAlpha then
                        local okA, aa = pcall(function() return sb:GetAlpha() end)
                        if okA and type(aa) == "number" then a = aa end
                    end
                    return r, g, b, a
                end
            end
        end
    end

    return nil
end

-- ============================================================
-- TOOLTIP (NORMAL row only)
-- ============================================================
local function ShowAuraTooltip(self)
    if not self or not SafeShown(self) then return end
    if not self._unit then return end
    if not self._auraIndex then return end

    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT", -2, -2)

    local ok = pcall(function()
        GameTooltip:SetUnitAura(self._unit, self._auraIndex, "HARMFUL")
    end)

    if ok and GameTooltip:NumLines() > 0 then
        GameTooltip:Show()
    else
        GameTooltip:Hide()
    end
end

-- ============================================================
-- COUNTDOWN STYLING
-- ============================================================
local function SafeSetFont(fs, path, size, flags)
    if not (fs and fs.SetFont) then return end
    size  = tonumber(size) or 12
    flags = flags or ""
    local ok = pcall(fs.SetFont, fs, path, size, flags)
    if not ok then
        pcall(fs.SetFont, fs, (_G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"), size, flags)
    end
end

local function StyleCooldownCountdown(cd, iconSize)
    if not (cd and cd.GetCountdownFontString) then return end
    local fs = cd:GetCountdownFontString()
    if not fs then return end

    local font = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    local fsz  = max(9, floor((tonumber(iconSize) or 16) * 0.62))

    SafeSetFont(fs, font, fsz, "OUTLINE")
    fs:SetShadowOffset(0, 0)
    fs:SetDrawLayer("OVERLAY", 7)
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", cd, "CENTER", 0, 0)
    fs:Show()
end

-- ============================================================
-- PRIVATE AURA ANCHORS
-- ============================================================
local function RemovePrivateAnchors(ui)
    if not ui or not ui.private or not ui.private.icons then return end
    if not (CUA and CUA.RemovePrivateAuraAnchor) then return end

    for _, b in ipairs(ui.private.icons) do
        if b._paID then
            pcall(CUA.RemovePrivateAuraAnchor, b._paID)
            b._paID = nil
        end
        if b._cover then b._cover:Hide() end
        b._hasDraw = false
    end
    ui._paUnit = nil
end

local function EnsurePrivateAnchors(ui, unit)
    if not ui or not unit then return end
    if not (CUA and CUA.AddPrivateAuraAnchor) then return end
    if ui._paUnit == unit then return end

    RemovePrivateAnchors(ui)
    ui._paUnit = unit

    for idx = 1, MAX_PRIVATE do
        local b = ui.private.icons[idx]
        if b and b.priv then
            local ok, id = pcall(CUA.AddPrivateAuraAnchor, {
                unitToken = unit,
                auraIndex = idx,
                parent = b.priv,

                showCountdownFrame = true,
                showCountdownNumbers = true,

                iconInfo = {
                    iconWidth = PRIVATE_SIZE,
                    iconHeight = PRIVATE_SIZE,
                    iconAnchor = {
                        point = "CENTER",
                        relativeTo = b.priv,
                        relativePoint = "CENTER",
                        offsetX = 0,
                        offsetY = 0,
                    },
                },
            })

            b._paID = (ok and id) or nil

            if b._cover then b._cover:Hide() end
            b._hasDraw = false
        end
    end

    dprint("Private anchors set for", unit)
end

-- ============================================================
-- PRIVATE DRAW DETECTION
-- ============================================================
local function PrivateSlotHasDraw_A(priv)
    if not priv then return false end

    local okChildren, children = pcall(function() return { priv:GetChildren() } end)
    if not okChildren or not children then return false end

    for i = 1, #children do
        local child = children[i]
        if child then
            local a = SafeAlpha(child)
            if a > 0.01 then
                local icon = rawget(child, "Icon")
                local tex = SafeTexture(icon)
                if tex then return true end

                local cd = rawget(child, "Cooldown")
                if cd and SafeShown(cd) then return true end

                local border = rawget(child, "DebuffBorder") or rawget(child, "TempEnchantBorder")
                if border and SafeShown(border) then return true end
            end
        end
    end

    return false
end

-- ============================================================
-- UI CREATION
-- ============================================================
local function CreatePrivateSlot(parent, index)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(PRIVATE_SIZE, PRIVATE_SIZE)
    f:SetPoint("LEFT", (index - 1) * (PRIVATE_SIZE + GAP), 0)
    f:Show()

    local priv = CreateFrame("Frame", nil, f)
    priv:SetAllPoints()
    priv:SetFrameLevel(f:GetFrameLevel() + 20)

    local cover = priv:CreateTexture(nil, "OVERLAY")
    cover:SetTexture("Interface\\Buttons\\WHITE8X8")
    cover:SetPoint("TOPLEFT", PRIVATE_COVER_INSET, -PRIVATE_COVER_INSET)
    cover:SetPoint("BOTTOMRIGHT", -PRIVATE_COVER_INSET, PRIVATE_COVER_INSET)
    cover:SetDrawLayer("OVERLAY", 7)
    cover:Hide()

    f.priv = priv
    f._cover = cover
    f._paID = nil
    f._hasDraw = false

    return f
end

local function CreateNormalSlot(parent, index)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(NORMAL_SIZE, NORMAL_SIZE)
    f:SetPoint("LEFT", (index - 1) * (NORMAL_SIZE + GAP), 0)
    f:Hide()

    f:EnableMouse(true)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints(tex)
    cd:SetDrawEdge(false)
    cd:SetDrawSwipe(true)
    cd:SetHideCountdownNumbers(false)
    cd:Hide()

    StyleCooldownCountdown(cd, NORMAL_SIZE)

    local count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    count:SetPoint("BOTTOMRIGHT", 2, 0)
    count:SetText("")
    count:Hide()

    f.icon  = tex
    f.cd    = cd
    f.count = count

    f._unit = nil
    f._auraIndex = nil
    f._spellId = nil
    f._auraInstanceID = nil

    f:SetScript("OnEnter", ShowAuraTooltip)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return f
end

local function Ensure(frame)
    if frame._rhDebuffs then return frame._rhDebuffs end

    local holder = CreateFrame("Frame", nil, frame)

    local w_private = MAX_PRIVATE * PRIVATE_SIZE + (MAX_PRIVATE - 1) * GAP
    local w_normal  = MAX_NORMAL  * NORMAL_SIZE  + (MAX_NORMAL  - 1) * GAP
    local w = max(w_private, w_normal)
    local h = PRIVATE_SIZE + ROW_GAP + NORMAL_SIZE

    holder:SetSize(w, h)

    if Debuffs.DEFAULT_ANCHOR == "BOTTOM" then
        holder:SetPoint("BOTTOM", frame, "BOTTOM", 0, 4)
    else
        holder:SetPoint("TOP", frame, "TOP", 0, -4)
    end

    holder:SetFrameLevel((frame:GetFrameLevel() or 0) + 50)
    holder:SetFrameStrata(frame:GetFrameStrata() or "MEDIUM")
    holder:SetIgnoreParentAlpha(true)
    holder:SetAlpha(1)
    holder:Hide()

    local privRow = CreateFrame("Frame", nil, holder)
    privRow:SetSize(w_private, PRIVATE_SIZE)
    privRow:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    privRow:Show()

    local privIcons = {}
    for i = 1, MAX_PRIVATE do
        privIcons[i] = CreatePrivateSlot(privRow, i)
        privIcons[i]:SetFrameLevel(privRow:GetFrameLevel() + 1)
    end

    local normRow = CreateFrame("Frame", nil, holder)
    normRow:SetSize(w_normal, NORMAL_SIZE)
    normRow:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
    normRow:Show()

    local normIcons = {}
    for i = 1, MAX_NORMAL do
        normIcons[i] = CreateNormalSlot(normRow, i)
        normIcons[i]:SetFrameLevel(normRow:GetFrameLevel() + 1)
    end

    holder._privAccum = 0
    holder:SetScript("OnUpdate", function(self, elapsed)
        elapsed = elapsed or 0
        self._privAccum = self._privAccum + elapsed
        if self._privAccum < PRIVATE_SCAN_TICK then return end
        self._privAccum = 0

        local ui = frame._rhDebuffs
        if ui and ui.private and ui.private.icons then
            for _, p in ipairs(ui.private.icons) do
                if p and p.priv and p._cover then
                    local has = false
                    local ok = pcall(function()
                        has = PrivateSlotHasDraw_A(p.priv)
                    end)
                    if not ok then has = false end

                    if has ~= p._hasDraw then
                        p._hasDraw = has
                        if has then p._cover:Show() else p._cover:Hide() end
                    end
                end
            end
        end
    end)

    frame._rhDebuffs = {
        holder = holder,
        private = { row = privRow, icons = privIcons },
        normal  = { row = normRow, icons = normIcons },
        _paUnit = nil,
        _coverKey = nil,
    }

    return frame._rhDebuffs
end

-- ============================================================
-- NORMAL DEBUFF COLLECTION (12.0 SAFE)
--   - Prefer AuraInstanceID (DurationObject possible)
--   - Midnight fix: do NOT break on missing icon
-- ============================================================
local function CollectNormal(unit)
    if not unit or not UnitExists(unit) then return nil end
    local list = {}

    if GetAuraDataByIndex then
        for i = 1, 40 do
            local aura
            local ok = pcall(function()
                aura = GetAuraDataByIndex(unit, i, "HARMFUL")
            end)
            if (not ok) or (not aura) then break end

            -- MIDNIGHT FIX:
            -- Was: if not aura.icon then break end
            -- Now: keep scanning; some auras may not have icon
            if aura.icon then
                list[#list + 1] = {
                    auraIndex      = i,
                    auraInstanceID = aura.auraInstanceID,
                    icon           = aura.icon,
                    count          = aura.applications,
                    spellId        = SafeToID(aura.spellId),
                }
                if #list >= MAX_NORMAL then break end
            end
        end

        if #list > 0 then return list end
    end

    if UnitAura then
        for i = 1, 40 do
            local name, texture, count, _, _, _, _, _, _, spellId = UnitAura(unit, i, "HARMFUL")
            if not name then break end

            list[#list + 1] = {
                auraIndex      = i,
                auraInstanceID = nil,
                icon           = texture,
                count          = count,
                spellId        = SafeToID(spellId),
            }

            if #list >= MAX_NORMAL then break end
        end
    end

    if #list == 0 then return nil end
    return list
end

-- ============================================================
-- PUBLIC API
-- ============================================================
function Debuffs:Attach(frame)
    local ui = Ensure(frame)

    dprint("Attach:",
        "UnitAura:", UnitAura and "YES" or "NO",
        "CUA:", CUA and "YES" or "NO",
        "GetAuraDataByIndex:", GetAuraDataByIndex and "YES" or "NO",
        "GetAuraDuration:", GetAuraDuration and "YES" or "NO",
        "AddPrivateAuraAnchor:", (CUA and CUA.AddPrivateAuraAnchor) and "YES" or "NO"
    )

    return ui
end

function Debuffs:Update(frame, unit)
    local ui = Ensure(frame)
    local holder = ui.holder

    if not unit or not UnitExists(unit) then
        holder:Hide()
        RemovePrivateAnchors(ui)
        return
    end

    holder:Show()

    EnsurePrivateAnchors(ui, unit)

    do
        local r, g, b, a = GetHPBarColor(frame)
        if not r then r, g, b, a = 0, 0, 0, 0.85 end

        local key = string.format("%.3f:%.3f:%.3f:%.3f", r, g, b, a)
        if ui._coverKey ~= key then
            ui._coverKey = key
            for _, icon in ipairs(ui.private.icons) do
                if icon._cover then
                    icon._cover:SetVertexColor(r, g, b, a)
                end
            end
        end
    end

    local list = CollectNormal(unit)

    local icons = ui.normal.icons
    for slot = 1, MAX_NORMAL do
        local b = icons[slot]
        local a = list and list[slot] or nil

        if a then
            b._unit = unit
            b._auraIndex = a.auraIndex
            b._spellId = a.spellId
            b._auraInstanceID = a.auraInstanceID

            local okSet = pcall(function() b.icon:SetTexture(a.icon) end)
            if (not okSet) or (not b.icon:GetTexture()) then
                local tex = GetSpellTextureSafe(a.spellId)
                if tex then pcall(function() b.icon:SetTexture(tex) end) end
            end

            local c = SafeToNumber(a.count)
            if c > 1 then
                b.count:SetText(c)
                b.count:Show()
            else
                b.count:SetText("")
                b.count:Hide()
            end

            if GetAuraDuration and b._auraInstanceID and b.cd.SetCooldownFromDurationObject then
                local durObj
                local okDur = pcall(function()
                    durObj = GetAuraDuration(unit, b._auraInstanceID)
                end)

                if okDur and durObj then
                    pcall(b.cd.SetCooldownFromDurationObject, b.cd, durObj, true)
                    b.cd:Show()
                    StyleCooldownCountdown(b.cd, NORMAL_SIZE)
                else
                    b.cd:Hide()
                end
            else
                b.cd:Hide()
            end

            b:Show()
        else
            b._unit = nil
            b._auraIndex = nil
            b._spellId = nil
            b._auraInstanceID = nil

            b.icon:SetTexture(nil)
            b.count:SetText("")
            b.count:Hide()
            b.cd:Hide()
            b:Hide()
        end
    end
end