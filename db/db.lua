-- ============================================================================
-- db/db.lua (RobHeal)
-- SavedVariables + Defaults + Accessors (profile-aware) - CPU SAFE
-- ============================================================================
local ADDON, ns = ...
ns = _G[ADDON] or ns or {}
_G[ADDON] = ns

-- Using new global name to avoid overwriting from old character specific files
_G.RobHealGlobalDB = _G.RobHealGlobalDB or {}
_G.RobHealCharDB   = _G.RobHealCharDB   or {}

local SV     = _G.RobHealGlobalDB
local CharSV = _G.RobHealCharDB

ns.DB = ns.DB or {}
local DB = ns.DB

local type = type
local pairs = pairs
local tonumber = tonumber

-- ------------------------------------------------------------
-- Profile payload defaults (per profile)
-- ------------------------------------------------------------
local DEFAULTS_PROFILE = {
    range = {
        enabled   = true,
        alphaIn   = 1.0,
        alphaOut  = 0.5,
        update    = 0.20,
        smoothing = 10,
    },

    targetedSpells = {
        enabled = true,
        maxIcons = 1,
        size     = 18,
        scale    = 1.0,
        spacing  = 2,
        anchor   = "TOPRIGHT",
        x        = -2,
        y        = -2,
        ignoreParentAlpha = true,
        showSwipe = true,
        showText  = true,
        watchNameplates = true,
    },

    party = {
        enabled = true,
        orientation = "HORIZONTAL",
        w = 210,
        h = 70,
        spacing = 6,
        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = -140,
        locked = false,
        showRole = true,
        showPower = true,
        sort = "NONE",
        classColor = true,
        showMover = true,
        allowDrag = true,

        fbuff = {
            enabled    = true,
            onlyMine   = false,
            maxIcons   = 3,
            size       = 16,
            spacing    = 2,
            anchor     = "TOP",
            relTo      = "hp",
            relPoint   = "TOP",
            x          = 0,
            y          = 2,
            showTimers = true,
            showStacks = true,
            mode       = "IMPORTANT",
            custom     = {},
        },

        debuff = {
            enabled = true,
            mode = "IMPORTANT",
            maxIcons = 3,
            size = 16,
            customOnlyDispellable = false,
            custom = {},
        },
    },

    raid = {
        enabled = true,
        orientation = "VERTICAL",
        w = 160,
        h = 46,
        spacing = 4,

        columns = 8,
        max = 40,

        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = 120,

        locked = false,

        showRole = false,
        showPower = false,
        sort = "NONE",
        classColor = true,

        showGroup = false,
        groupGap = nil,

        fbuff = {
            enabled    = true,
            onlyMine   = false,
            maxIcons   = 3,
            size       = 14,
            spacing    = 2,
            anchor     = "TOP",
            relTo      = "hp",
            relPoint   = "TOP",
            x          = 0,
            y          = 2,
            showTimers = true,
            showStacks = true,
            mode       = "IMPORTANT",
            custom     = {},
        },

        debuff = {
            enabled = true,
            mode = "IMPORTANT",
            maxIcons = 3,
            size = 14,
            customOnlyDispellable = false,
            custom = {},
        },

        tankFrames = false,
        tankAlsoInRaid = true,
        tankSide = "LEFT",
        tankW = nil,
        tankH = nil,
        tankSpacing = nil,
        tankOffsetX = nil,
        tankOffsetY = nil,

        _settingsRaid = {
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = 0,
        },

        _simOn = false,
    },
}

-- ------------------------------------------------------------
-- DB Root defaults
-- ------------------------------------------------------------
local CURRENT_DB_VERSION = 1

-- GLOBAL (Account-wide)
local DEFAULTS_GLOBAL = {
    dbVersion = CURRENT_DB_VERSION,
    profiles = {
        ["Default"] = {},
    },
}

-- LOCAL (Per-character)
local DEFAULTS_CHAR = {
    activeProfile = "Default",
    specProfile = {},
    profileOpts = {
        autoLoadOnSpecChange = true,
    },
}

-- ------------------------------------------------------------
-- Deep copy + merge-missing
-- ------------------------------------------------------------
local function DeepCopy(src)
    local t = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            t[k] = DeepCopy(v)
        else
            t[k] = v
        end
    end
    return t
end

local function MergeMissing(dst, defaults)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(defaults) do
        local cur = dst[k]
        if cur == nil then
            dst[k] = (type(v) == "table") and DeepCopy(v) or v
        elseif type(cur) == "table" and type(v) == "table" then
            MergeMissing(cur, v)
        end
    end
    return dst
end

local function NormalizeProfileName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    return name
end

-- ------------------------------------------------------------
-- Internal state (CPU guards + cache)
-- ------------------------------------------------------------
DB._ensured   = DB._ensured or false
DB._activeKey = DB._activeKey or nil
DB._activeTbl = DB._activeTbl or nil

function ns:InvalidateProfileCache()
    if ns.DB then
        ns.DB._activeKey = nil
        ns.DB._activeTbl = nil
    end
end

local function EnsureProfileExistsAndDefaults(profileKey)
    profileKey = NormalizeProfileName(profileKey) or "Default"
    SV.profiles = SV.profiles or {}
    SV.profiles[profileKey] = SV.profiles[profileKey] or {}
    SV.profiles[profileKey] = MergeMissing(SV.profiles[profileKey], DEFAULTS_PROFILE)
    return profileKey, SV.profiles[profileKey]
end

-- ------------------------------------------------------------
-- Ensure root structure + defaults + MIGRATION (RUN ONCE)
-- ------------------------------------------------------------
function DB:Ensure()
    if self._ensured then
        return _G.RobHealGlobalDB, _G.RobHealCharDB
    end

    -- MIGRATION CHECK: Old RobHealDB -> new global/char split
    if _G.RobHealDB and type(_G.RobHealDB) == "table" and not _G.RobHealGlobalDB then
        _G.RobHealGlobalDB = {}
        _G.RobHealCharDB = {}

        if _G.RobHealDB.profiles then
            _G.RobHealGlobalDB.profiles = DeepCopy(_G.RobHealDB.profiles)
        end

        if _G.RobHealDB.activeProfile then
            _G.RobHealCharDB.activeProfile = _G.RobHealDB.activeProfile
        end
        if _G.RobHealDB.specProfile then
            _G.RobHealCharDB.specProfile = DeepCopy(_G.RobHealDB.specProfile)
        end
        if _G.RobHealDB.profileOpts then
            _G.RobHealCharDB.profileOpts = DeepCopy(_G.RobHealDB.profileOpts)
        end

        _G.RobHealDB = nil
    end

    SV = _G.RobHealGlobalDB or {}
    _G.RobHealGlobalDB = SV

    CharSV = _G.RobHealCharDB or {}
    _G.RobHealCharDB = CharSV

    -- Root defaults (cheap)
    MergeMissing(SV, DEFAULTS_GLOBAL)
    MergeMissing(CharSV, DEFAULTS_CHAR)

    if type(SV.profiles) ~= "table" then SV.profiles = {} end
    if type(CharSV.specProfile) ~= "table" then CharSV.specProfile = {} end
    if type(CharSV.profileOpts) ~= "table" then CharSV.profileOpts = {} end
    if CharSV.profileOpts.autoLoadOnSpecChange == nil then
        CharSV.profileOpts.autoLoadOnSpecChange = true
    end

    -- Normalize active profile
    local ap = NormalizeProfileName(CharSV.activeProfile) or "Default"
    CharSV.activeProfile = ap

    -- Ensure Default + Active profile exist and have defaults merged (ONLY THESE)
    EnsureProfileExistsAndDefaults("Default")
    EnsureProfileExistsAndDefaults(ap)

    SV.dbVersion = tonumber(SV.dbVersion) or CURRENT_DB_VERSION
    if SV.dbVersion < CURRENT_DB_VERSION then SV.dbVersion = CURRENT_DB_VERSION end

    self._ensured = true
    return SV, CharSV
end

-- ------------------------------------------------------------
-- Public accessors used by the addon
-- ------------------------------------------------------------
function ns:GetGlobalDB()
    local g, _ = DB:Ensure()
    return g
end

function ns:GetCharDB()
    local _, c = DB:Ensure()
    return c
end

-- Backwards compatibility mapping
function ns:GetDB()
    return ns:GetGlobalDB()
end

function ns:GetActiveProfileKey()
    DB:Ensure()
    local g = SV
    local c = CharSV

    local ap = NormalizeProfileName(c.activeProfile) or "Default"
    if type(g.profiles[ap]) ~= "table" then
        ap = "Default"
        c.activeProfile = ap
        EnsureProfileExistsAndDefaults(ap)
        ns:InvalidateProfileCache()
    end
    return ap
end

function ns:GetProfileDB()
    DB:Ensure()
    local ap = ns:GetActiveProfileKey()

    if DB._activeKey == ap and DB._activeTbl then
        return DB._activeTbl
    end

    local _, tbl = EnsureProfileExistsAndDefaults(ap)
    DB._activeKey = ap
    DB._activeTbl = tbl
    return tbl
end

function ns:GetPartyDB()
    local p = ns:GetProfileDB()
    p.party = MergeMissing(p.party or {}, DEFAULTS_PROFILE.party)
    return p.party
end

function ns:GetRaidDB()
    local p = ns:GetProfileDB()
    p.raid = MergeMissing(p.raid or {}, DEFAULTS_PROFILE.raid)
    return p.raid
end

function ns:GetRangeDB()
    local p = ns:GetProfileDB()
    p.range = MergeMissing(p.range or {}, DEFAULTS_PROFILE.range)
    return p.range
end

function ns:GetTargetedSpellsDB()
    local p = ns:GetProfileDB()
    p.targetedSpells = MergeMissing(p.targetedSpells or {}, DEFAULTS_PROFILE.targetedSpells)
    return p.targetedSpells
end

-- Give Profile module access to helpers
DB._MergeMissing = MergeMissing
DB._NormalizeProfileName = NormalizeProfileName
DB._DEFAULTS_PROFILE = DEFAULTS_PROFILE