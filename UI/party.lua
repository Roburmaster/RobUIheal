-- ============================================================================
-- party.lua (RobHeal)
-- Party frames (no SecureHeader). Uses db.lua: ns:GetPartyDB() (role-profile aware).
-- Midnight-safe / secret-safe hardened for hostile/charm/takeover states.
-- ============================================================================

local ADDON, ns = ...
ns = _G[ADDON] or ns

ns.Party = ns.Party or {}
local Party = ns.Party

local Range   = ns.Range
local Dispel  = ns.Dispel
local Debuffs = ns.Debuffs

local TEX     = "Interface\\Buttons\\WHITE8X8"
local POWER_H = 3

Party.frames       = Party.frames or {}
Party.eventFrame   = Party.eventFrame or nil
Party.mover        = Party.mover or nil
Party.selectedUnit = Party.selectedUnit or nil

local pcall        = pcall
local type         = type
local ipairs       = ipairs
local pairs        = pairs
local tostring     = tostring
local math_floor   = math.floor
local table_sort   = table.sort

local function GetDB()
    return ns:GetPartyDB()
end

local function IsSecretValue(v)
    local f = _G.issecretvalue
    if type(f) == "function" then
        local ok, ret = pcall(f, v)
        if ok and ret then
            return true
        end
    end
    return false
end

local function SafeSetText(fs, text)
    if not fs then return end
    if text == nil then text = "" end
    pcall(fs.SetText, fs, text)
end

local function SafeSetFormattedText(fs, fmt, ...)
    if not fs then return false end
    local ok = pcall(fs.SetFormattedText, fs, fmt, ...)
    return ok and true or false
end

local function SafeSetMinMax(bar, mn, mx)
    if not bar then return end
    pcall(bar.SetMinMaxValues, bar, mn, mx)
end

local function SafeSetValue(bar, v)
    if not bar then return end
    pcall(bar.SetValue, bar, v)
end

local function IsSafeUnitForHP(unit)
    if ns and ns.util and ns.util.IsSafeUnit then
        return ns.util.IsSafeUnit(unit) and true or false
    end
    return true
end

local function RoleRank(role)
    if role == "TANK" then return 1 end
    if role == "HEALER" then return 2 end
    return 3
end

local function RoleLetter(role)
    if role == "TANK" then return "T" end
    if role == "HEALER" then return "H" end
    if role == "DAMAGER" then return "D" end
    return ""
end

local function SoftHide(frame)
    frame:SetAlpha(0)
    frame:EnableMouse(false)
    if frame._hpPctOverlay then frame._hpPctOverlay:Hide() end
    if frame._rhTargetedSquare then frame._rhTargetedSquare:Hide() end
    if frame._rhSelected then frame._rhSelected:Hide() end
    if frame._rhSelectedBorder then frame._rhSelectedBorder:Hide() end
end

local function SoftShow(frame)
    frame:SetAlpha(1)
    frame:EnableMouse(true)
    if frame._hpPctOverlay then frame._hpPctOverlay:Show() end
end

local function UpdatePowerLayout(btn, showPower)
    btn.hp:ClearAllPoints()
    btn.hp:SetPoint("TOPLEFT", 1, -1)

    if showPower then
        btn.power:SetHeight(POWER_H)
        btn.power:Show()
        btn.hp:SetPoint("BOTTOMRIGHT", -1, 1 + POWER_H)
    else
        btn.power:Hide()
        btn.hp:SetPoint("BOTTOMRIGHT", -1, 1)
    end
end

local function PlaceDebuffs(frame)
    if not frame or not frame.hp or not frame._rhDebuffs or not frame._rhDebuffs.holder then return end
    local holder = frame._rhDebuffs.holder
    holder:ClearAllPoints()
    holder:SetPoint("BOTTOM", frame.hp, "BOTTOM", 0, 2)
    holder:SetIgnoreParentAlpha(true)
    holder:SetAlpha(1)
end

local function EnsureTargetedSquare(btn)
    if btn._rhTargetedSquare then return end

    local sq = CreateFrame("Frame", nil, btn)
    sq:SetSize(10, 10)
    sq:SetPoint("BOTTOM", btn, "TOP", 0, 2)
    sq:SetFrameLevel(btn:GetFrameLevel() + 80)
    sq:SetIgnoreParentAlpha(true)
    sq:SetAlpha(0)
    sq:Hide()

    local t = sq:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetColorTexture(1, 0, 0, 1)
    sq.tex = t

    btn._rhTargetedSquare = sq
end

local function EnsureSelectedHighlight(btn)
    if btn._rhSelected then return end

    local sel = btn:CreateTexture(nil, "OVERLAY")
    sel:SetAllPoints(btn)
    sel:SetColorTexture(1, 1, 0, 0.14)
    sel:SetIgnoreParentAlpha(true)
    sel:Hide()
    btn._rhSelected = sel

    local b = btn:CreateTexture(nil, "OVERLAY")
    b:SetPoint("TOPLEFT", -1, 1)
    b:SetPoint("BOTTOMRIGHT", 1, -1)
    b:SetTexture("Interface\\Buttons\\WHITE8x8")
    b:SetVertexColor(1, 1, 0, 0.55)
    b:SetIgnoreParentAlpha(true)
    b:Hide()
    btn._rhSelectedBorder = b
end

local function GetDisplayName(unit, frame)
    local name = UnitName(unit)

    if name == nil then
        if frame and frame._rhRC_Name then
            return frame._rhRC_Name
        end
        return ""
    end

    if IsSecretValue(name) then
        if frame and frame._rhRC_Name and frame._rhRC_Name ~= "" then
            return frame._rhRC_Name
        end
        return name
    end

    if type(name) ~= "string" then
        name = tostring(name or "")
    end

    local short = name
    if #short > 18 then
        short = short:sub(1, 18)
    end

    if frame then
        frame._rhRC_Name = short
    end

    return short
end

local function GetSortName(unit)
    local name = UnitName(unit)
    if not name or IsSecretValue(name) or type(name) ~= "string" then
        return unit or ""
    end
    return name
end

local function GetHealthValues(unit)
    local cur = UnitHealth(unit)
    local mx  = UnitHealthMax(unit)

    if cur == nil then cur = 0 end
    if mx  == nil then mx  = 1 end

    return cur, mx
end

local function GetPowerValues(unit)
    local cur = UnitPower(unit)
    local mx  = UnitPowerMax(unit)

    if cur == nil then cur = 0 end
    if mx  == nil then mx  = 1 end

    return cur, mx
end

function Party:SetSelectedUnit(unit)
    self.selectedUnit = unit
    self:UpdateSelectionHighlights()
end

function Party:UpdateSelectionHighlights()
    local sel = self.selectedUnit
    for _, f in ipairs(self.frames) do
        if f and f.unit and f._rhSelected then
            local isSel = (sel ~= nil and f.unit == sel)
            f._rhSelected:SetShown(isSel)
            f._rhSelectedBorder:SetShown(isSel)
        end
    end
end

function Party:HookOverlayClicks(host, overlay)
    if not overlay or overlay._rhPartyHooked then return end
    overlay._rhPartyHooked = true

    overlay:HookScript("OnClick", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        if not IsShiftKeyDown() then return end

        local unit = self:GetAttribute("unit") or (host and host.unit)
        if unit and unit ~= "" then
            Party:SetSelectedUnit(unit)
        end
    end)
end

local function CreateMover()
    local m = CreateFrame("Frame", "RobHealPartyMover", UIParent)
    m:SetSize(180, 18)
    m:SetFrameStrata("DIALOG")
    m:Hide()

    m.bg = m:CreateTexture(nil, "BACKGROUND")
    m.bg:SetAllPoints()
    m.bg:SetColorTexture(0, 0, 0, 0.35)

    m.text = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.text:SetPoint("CENTER")
    m.text:SetText("Party (drag)")

    m:EnableMouse(true)
    m:SetMovable(true)
    m:RegisterForDrag("LeftButton")

    m:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        self:StartMoving()
    end)

    m:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        local db = GetDB()
        local p, _, rp, x, y = self:GetPoint()

        db.point    = p or db.point
        db.relPoint = rp or db.relPoint
        db.x        = math_floor((x or 0) + 0.5)
        db.y        = math_floor((y or 0) + 0.5)

        if ns.RequestPartyRebuild then ns:RequestPartyRebuild() else Party:Build() end
    end)

    return m
end

local function ApplyMoverPosition(m)
    local db = GetDB()
    m:ClearAllPoints()
    m:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

local function CreateUnitButton()
    local btn = CreateFrame("Button", nil, UIParent)
    btn:SetClampedToScreen(true)
    btn:RegisterForClicks("AnyUp", "AnyDown")

    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(0.06, 0.06, 0.06, 0.85)

    btn.btop = btn:CreateTexture(nil, "BORDER"); btn.btop:SetColorTexture(0,0,0,0.85)
    btn.bbot = btn:CreateTexture(nil, "BORDER"); btn.bbot:SetColorTexture(0,0,0,0.85)
    btn.blef = btn:CreateTexture(nil, "BORDER"); btn.blef:SetColorTexture(0,0,0,0.85)
    btn.brig = btn:CreateTexture(nil, "BORDER"); btn.brig:SetColorTexture(0,0,0,0.85)
    btn.btop:SetPoint("TOPLEFT");     btn.btop:SetPoint("TOPRIGHT");     btn.btop:SetHeight(1)
    btn.bbot:SetPoint("BOTTOMLEFT");  btn.bbot:SetPoint("BOTTOMRIGHT");  btn.bbot:SetHeight(1)
    btn.blef:SetPoint("TOPLEFT");     btn.blef:SetPoint("BOTTOMLEFT");   btn.blef:SetWidth(1)
    btn.brig:SetPoint("TOPRIGHT");    btn.brig:SetPoint("BOTTOMRIGHT");  btn.brig:SetWidth(1)

    btn.power = CreateFrame("StatusBar", nil, btn)
    btn.power:SetPoint("BOTTOMLEFT", 1, 1)
    btn.power:SetPoint("BOTTOMRIGHT", -1, 1)
    btn.power:SetHeight(POWER_H)
    btn.power:SetStatusBarTexture(TEX)
    btn.power:SetStatusBarColor(0.12, 0.42, 1.0)
    SafeSetMinMax(btn.power, 0, 1)
    SafeSetValue(btn.power, 1)
    btn.power:Hide()

    btn.hp = CreateFrame("StatusBar", nil, btn)
    btn.hp:SetStatusBarTexture(TEX)
    SafeSetMinMax(btn.hp, 0, 1)
    SafeSetValue(btn.hp, 1)

    btn.hpbg = btn.hp:CreateTexture(nil, "BACKGROUND")
    btn.hpbg:SetAllPoints()
    btn.hpbg:SetColorTexture(0.02, 0.02, 0.02, 0.90)

    btn.nameText = btn.hp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.nameText:SetTextColor(1, 1, 1, 1)
    btn.nameText:SetPoint("TOPLEFT", btn.hp, "TOPLEFT", 4, -2)
    btn.nameText:SetJustifyH("LEFT")
    btn.nameText:SetText("")

    btn.roleText = btn.hp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.roleText:ClearAllPoints()
    btn.roleText:SetPoint("TOPRIGHT", btn.hp, "TOPRIGHT", -4, -2)
    btn.roleText:SetJustifyH("RIGHT")
    btn.roleText:SetText("")

    EnsureSelectedHighlight(btn)

    btn.RobHeal_OnOverlayCreated = function(host, overlay)
        Party:HookOverlayClicks(host, overlay)
    end

    if not btn._hpPctOverlay then
        local o = CreateFrame("Frame", nil, UIParent)
        o:SetFrameStrata("MEDIUM")
        o:SetFrameLevel(btn:GetFrameLevel() + 2)
        o:SetClampedToScreen(true)
        o:Show()

        o:ClearAllPoints()
        o:SetPoint("CENTER", btn, "CENTER", 0, 0)
        o:SetSize(80, 18)

        local fs = o:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER", o, "CENTER", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetTextColor(1, 1, 1, 1)
        fs:SetText("")
        fs:Show()

        btn._hpPctOverlay = o
        btn._hpPctText = fs
    end

    UpdatePowerLayout(btn, GetDB().showPower)

    if Dispel and Dispel.Attach then Dispel:Attach(btn) end
    if Debuffs and Debuffs.Attach then
        Debuffs:Attach(btn)
        PlaceDebuffs(btn)
    end

    if ns.IncomingHeals and ns.IncomingHeals.Attach then ns.IncomingHeals:Attach(btn) end
    if ns.HealAbsorb   and ns.HealAbsorb.Attach   then ns.HealAbsorb:Attach(btn) end
    if ns.ShieldAbsorb and ns.ShieldAbsorb.Attach then ns.ShieldAbsorb:Attach(btn) end

    local FriendlyBuffs = ns.FriendlyBuffs
    if FriendlyBuffs and FriendlyBuffs.Attach then
        btn._rhKind = "PARTY"
        FriendlyBuffs:Attach(btn)
    end

    EnsureTargetedSquare(btn)
    local TargetedSpells = ns.TargetedSpells
    if TargetedSpells and TargetedSpells.Attach then
        TargetedSpells:Attach(btn)
    end

    return btn
end

function Party:GetUnits()
    local list = {}

    if UnitExists("player") then list[#list + 1] = "player" end

    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then list[#list + 1] = u end
    end

    local db = GetDB()
    if db.sort == "ROLE" then
        table_sort(list, function(a, b)
            local ra = UnitGroupRolesAssigned(a)
            local rb = UnitGroupRolesAssigned(b)
            local da = RoleRank(ra)
            local dbb = RoleRank(rb)
            if da ~= dbb then
                return da < dbb
            end

            local na = GetSortName(a)
            local nb = GetSortName(b)
            return na < nb
        end)
    end

    return list
end

function Party:Apply(frame)
    local db = GetDB()
    local u = frame.unit
    if not u or not UnitExists(u) then return end

    UpdatePowerLayout(frame, db.showPower)

    if frame._rhDebuffs then PlaceDebuffs(frame) end

    local FriendlyBuffs = ns.FriendlyBuffs
    if FriendlyBuffs and FriendlyBuffs.Place then
        FriendlyBuffs:Place(frame)
    end

    local displayName = GetDisplayName(u, frame)
    SafeSetText(frame.nameText, displayName)

    if db.showRole then
        local role = UnitGroupRolesAssigned(u)
        SafeSetText(frame.roleText, RoleLetter(role))

        if role == "TANK" then
            frame.roleText:SetTextColor(0.2, 0.6, 1.0, 1)
        elseif role == "HEALER" then
            frame.roleText:SetTextColor(0.2, 1.0, 0.2, 1)
        else
            frame.roleText:SetTextColor(1.0, 0.2, 0.2, 1)
        end

        frame.roleText:Show()
    else
        SafeSetText(frame.roleText, "")
        frame.roleText:Hide()
    end

    local cur, mx = GetHealthValues(u)
    SafeSetMinMax(frame.hp, 0, mx)
    SafeSetValue(frame.hp, cur)

    if frame._hpPctText then
        if not IsSafeUnitForHP(u) then
            SafeSetText(frame._hpPctText, "")
        elseif UnitIsDeadOrGhost(u) then
            SafeSetText(frame._hpPctText, "0%")
        else
            local percentValue = nil

            if UnitHealthPercent then
                local ok = pcall(function()
                    local scaling = (CurveConstants and CurveConstants.ScaleTo100) or 1
                    percentValue = UnitHealthPercent(u, true, scaling)
                end)
                if not ok then
                    percentValue = nil
                end
            else
                local ok = pcall(function()
                    local maxH = UnitHealthMax(u)
                    local curH = UnitHealth(u, true)
                    if maxH and curH then
                        percentValue = (curH / maxH) * 100
                    end
                end)
                if not ok then
                    percentValue = nil
                end
            end

            if percentValue ~= nil then
                if IsSecretValue(percentValue) then
                    if not SafeSetFormattedText(frame._hpPctText, "%d%%", percentValue) then
                        SafeSetText(frame._hpPctText, "")
                    end
                else
                    local n = tonumber(percentValue)
                    if n then
                        SafeSetText(frame._hpPctText, string.format("%d%%", n))
                    else
                        SafeSetText(frame._hpPctText, "")
                    end
                end
            else
                SafeSetText(frame._hpPctText, "")
            end
        end

        frame._hpPctText:Show()
        if frame._hpPctOverlay then
            frame._hpPctOverlay:Show()
        end
    end

    if db.classColor then
        local _, class = UnitClass(u)
        local c = class and RAID_CLASS_COLORS[class]
        if c then
            frame.hp:SetStatusBarColor(c.r, c.g, c.b)
        else
            frame.hp:SetStatusBarColor(0.2, 0.8, 0.2)
        end
    else
        frame.hp:SetStatusBarColor(0.2, 0.8, 0.2)
    end

    if db.showPower then
        local p, pm = GetPowerValues(u)
        SafeSetMinMax(frame.power, 0, pm)
        SafeSetValue(frame.power, p)
    end

    if Dispel and Dispel.Update then Dispel:Update(frame, u) end
    if Debuffs and Debuffs.Update then Debuffs:Update(frame, u) end

    if ns.IncomingHeals and ns.IncomingHeals.Update then ns.IncomingHeals:Update(frame, u, cur, mx) end
    if ns.HealAbsorb   and ns.HealAbsorb.Update   then ns.HealAbsorb:Update(frame, u, cur, mx) end
    if ns.ShieldAbsorb and ns.ShieldAbsorb.Update then ns.ShieldAbsorb:Update(frame, u, cur, mx) end

    if FriendlyBuffs and FriendlyBuffs.Update then
        FriendlyBuffs:Update(frame, u)
    end

    local TargetedSpells = ns.TargetedSpells
    if TargetedSpells and TargetedSpells.UpdateFrame then
        TargetedSpells:UpdateFrame(frame, u)
    end

    self:UpdateSelectionHighlights()
end

function Party:Layout(frames)
    local db = GetDB()
    local FriendlyBuffs = ns.FriendlyBuffs

    for i, f in ipairs(frames) do
        f:SetSize(db.w, db.h)
        f:ClearAllPoints()

        if i == 1 then
            f:SetPoint("TOPLEFT", self.mover, "TOPLEFT", 0, 0)
        else
            local prev = frames[i - 1]
            if db.orientation == "HORIZONTAL" then
                f:SetPoint("LEFT", prev, "RIGHT", db.spacing, 0)
            else
                f:SetPoint("TOP", prev, "BOTTOM", 0, -db.spacing)
            end
        end

        if f._rhDebuffs then PlaceDebuffs(f) end
        if FriendlyBuffs and FriendlyBuffs.Place then FriendlyBuffs:Place(f) end

        EnsureTargetedSquare(f)
        EnsureSelectedHighlight(f)

        if f._hpPctOverlay then
            f._hpPctOverlay:ClearAllPoints()
            f._hpPctOverlay:SetPoint("CENTER", f, "CENTER", 0, 0)
        end
    end

    self:UpdateSelectionHighlights()
end

function Party:Build()
    local db = GetDB()

    if db.showMover == nil then db.showMover = true end

    if not self.mover then
        self.mover = CreateMover()
    end

    ApplyMoverPosition(self.mover)

    if IsInRaid and IsInRaid() then
        if not InCombatLockdown() then
            for _, f in ipairs(self.frames) do
                f:Hide()
                if f._hpPctOverlay then f._hpPctOverlay:Hide() end
            end
        else
            for _, f in ipairs(self.frames) do
                SoftHide(f)
            end
        end
        if self.mover then self.mover:Hide() end
        return
    end

    local showMover = (db.showMover ~= false) and (not db.locked) and (not InCombatLockdown())
    self.mover:SetShown(showMover)

    if not db.enabled then
        if not InCombatLockdown() then
            for _, f in ipairs(self.frames) do
                f:Hide()
                if f._hpPctOverlay then f._hpPctOverlay:Hide() end
            end
        else
            for _, f in ipairs(self.frames) do
                SoftHide(f)
            end
        end
        return
    end

    local units = self:GetUnits()
    local shown = {}

    for i = 1, #units do
        local f = self.frames[i]
        if not f then
            f = CreateUnitButton()
            self.frames[i] = f
        end

        f.unit = units[i]

        if not InCombatLockdown() then
            f:Show()
        end
        SoftShow(f)

        if _G.RobHeal_RegisterFrame then
            _G.RobHeal_RegisterFrame(f, f.unit)
        end

        self:Apply(f)
        shown[#shown + 1] = f
    end

    for i = #units + 1, #self.frames do
        local f = self.frames[i]
        if not InCombatLockdown() then
            f:Hide()
            if f._hpPctOverlay then f._hpPctOverlay:Hide() end
        else
            SoftHide(f)
        end
    end

    self:Layout(shown)
    self:UpdateSelectionHighlights()
end

function Party:OnUnit(unit, event)
    if event == "UNIT_AURA" then
        local FriendlyBuffs = ns.FriendlyBuffs
        local TargetedSpells = ns.TargetedSpells

        for _, f in ipairs(self.frames) do
            if f:IsShown() and f.unit == unit then
                if Dispel and Dispel.Update then Dispel:Update(f, unit) end
                if Debuffs and Debuffs.Update then Debuffs:Update(f, unit) end
                if FriendlyBuffs and FriendlyBuffs.Update then FriendlyBuffs:Update(f, unit) end
                if TargetedSpells and TargetedSpells.UpdateFrame then TargetedSpells:UpdateFrame(f, unit) end
                return
            end
        end
        return
    end

    if event == "UNIT_HEAL_PREDICTION" or event == "UNIT_ABSORB_AMOUNT_CHANGED" or event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
        for _, f in ipairs(self.frames) do
            if f:IsShown() and f.unit == unit then
                local cur, mx = GetHealthValues(unit)
                if ns.IncomingHeals and ns.IncomingHeals.Update then ns.IncomingHeals:Update(f, unit, cur, mx) end
                if ns.HealAbsorb   and ns.HealAbsorb.Update   then ns.HealAbsorb:Update(f, unit, cur, mx) end
                if ns.ShieldAbsorb and ns.ShieldAbsorb.Update then ns.ShieldAbsorb:Update(f, unit, cur, mx) end
                return
            end
        end
        return
    end

    for _, f in ipairs(self.frames) do
        if f:IsShown() and f.unit == unit then
            self:Apply(f)
            return
        end
    end
end

function Party:Init()
    if self.eventFrame then return end

    local ef = CreateFrame("Frame")
    self.eventFrame = ef

    ef:RegisterEvent("GROUP_ROSTER_UPDATE")
    ef:RegisterEvent("PLAYER_ENTERING_WORLD")
    ef:RegisterEvent("PLAYER_ROLES_ASSIGNED")

    ef:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    ef:RegisterEvent("SPELLS_CHANGED")

    ef:RegisterEvent("UNIT_HEALTH")
    ef:RegisterEvent("UNIT_MAXHEALTH")
    ef:RegisterEvent("UNIT_POWER_UPDATE")
    ef:RegisterEvent("UNIT_MAXPOWER")
    ef:RegisterEvent("UNIT_NAME_UPDATE")
    ef:RegisterEvent("UNIT_CONNECTION")
    ef:RegisterEvent("UNIT_PHASE")
    ef:RegisterEvent("UNIT_AURA")

    ef:RegisterEvent("UNIT_HEAL_PREDICTION")
    ef:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")
    ef:RegisterEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")

    ef:RegisterEvent("PLAYER_TARGET_CHANGED")

    ef:SetScript("OnEvent", function(_, event, unit)
        if event == "GROUP_ROSTER_UPDATE"
        or event == "PLAYER_ENTERING_WORLD"
        or event == "PLAYER_ROLES_ASSIGNED"
        or event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "SPELLS_CHANGED" then
            if ns.UpdateActiveProfile then ns:UpdateActiveProfile(false) end
            if ns.RequestPartyRebuild then ns:RequestPartyRebuild() else Party:Build() end

        elseif event == "PLAYER_TARGET_CHANGED" then
            Party.selectedUnit = nil
            if UnitExists("target") then
                for _, f in ipairs(Party.frames) do
                    if f and f.unit and UnitExists(f.unit) and UnitIsUnit("target", f.unit) then
                        Party.selectedUnit = f.unit
                        break
                    end
                end
            end
            Party:UpdateSelectionHighlights()

        elseif unit then
            Party:OnUnit(unit, event)
        end
    end)

    if ns.UpdateActiveProfile then ns:UpdateActiveProfile(true) end
    if ns.RequestPartyRebuild then ns:RequestPartyRebuild() else Party:Build() end
end
    if ns.UpdateActiveProfile then ns:UpdateActiveProfile(true) end
    if ns.RequestPartyRebuild then ns:RequestPartyRebuild() else Party:Build() end
end
