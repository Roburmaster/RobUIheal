-- ============================================================================
-- range.lua (RobHeal)
--
-- Purpose
-- -------
-- Handles range-based fading for Party and Raid frames only.
--
-- Important
-- ---------
-- This file must stay combat-safe in WoW Midnight.
--
-- Safe design:
--   • No hostile checks
--   • No CheckInteractDistance
--   • No UnitInRange
--   • No item-based fallback
--
-- Reason:
--   • CheckInteractDistance caused ADDON_ACTION_BLOCKED
--   • UnitInRange / spell APIs may return secret booleans
--   • We only use spell range where it is actually available
--
-- Final rule set:
--   • Classes with friendly spell range use spell range
--   • Classes without friendly spell range do not force fallback here
--   • Unknown result keeps previous latched state
-- ============================================================================

local ADDON, ns = ...
ns.Range = ns.Range or {}
local Range = ns.Range

-- ============================================================================
-- FRIENDLY RANGE SPELLS
-- ----------------------------------------------------------------------------
-- These are the only classes/specs that get real friendly spell range checks.
-- We select the first spell the player actually knows.
-- ============================================================================
local CLASS_FRIENDLY = {
    PRIEST  = { 2061, 2050, 17 },
    DRUID   = { 8936, 774, 33763 },
    PALADIN = { 19750, 82326 },
    SHAMAN  = { 8004, 77472, 61295 },
    MONK    = { 116670, 124682, 115175 },
    EVOKER  = { 361469, 355913, 360995 },
    WARLOCK = { 20707 },
}

-- ============================================================================
-- API REFERENCES
-- ----------------------------------------------------------------------------
-- Localized for slightly lower overhead and cleaner code.
-- ============================================================================
local C_Spell_IsSpellInRange = C_Spell and C_Spell.IsSpellInRange

local UnitExists        = UnitExists
local UnitClass         = UnitClass
local UnitIsConnected   = UnitIsConnected
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local IsPlayerSpell     = IsPlayerSpell
local pcall             = pcall

local ipairs   = ipairs
local math_abs = math.abs
local type     = type
local tonumber = tonumber

-- Active spell used for friendly range checks.
local friendlySpellID

-- ============================================================================
-- SAFE NUMERIC HELPERS
-- ----------------------------------------------------------------------------
-- Sanitizes DB values so alpha/smoothing/update stay valid.
-- ============================================================================
local function Clamp01(x)
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

local function SafeNumber(v, fallback)
    if type(v) == "number" then
        if v ~= v then return fallback end -- NaN
        return v
    end

    local n = tonumber(v)
    if type(n) ~= "number" or n ~= n then
        return fallback
    end

    return n
end

local function SafeAlpha(v, fallback)
    return Clamp01(SafeNumber(v, fallback))
end

local function SafeUpdateRate(v)
    local n = SafeNumber(v, 0.20)
    if n < 0.05 then n = 0.05 end
    if n > 1.00 then n = 1.00 end
    return n
end

local function SafeSmoothing(v)
    local n = SafeNumber(v, 10)
    if n < 1 then n = 1 end
    if n > 60 then n = 60 end
    return n
end

-- ============================================================================
-- DB ACCESS
-- ----------------------------------------------------------------------------
-- Reads the range DB.
-- ============================================================================
local function GetRangeDB()
    return ns.GetRangeDB and ns:GetRangeDB() or nil
end

-- ============================================================================
-- SPELL PICKING
-- ----------------------------------------------------------------------------
-- Picks the first known spell from the class list.
-- ============================================================================
local function PickSpell(list)
    if not list then return nil end
    if not IsPlayerSpell then return nil end

    for _, id in ipairs(list) do
        if IsPlayerSpell(id) then
            return id
        end
    end

    return nil
end

-- ============================================================================
-- SPELL REFRESH
-- ----------------------------------------------------------------------------
-- Updates active spell when login/spec/talents/spellbook change.
-- ============================================================================
local function RefreshSpells()
    local _, class = UnitClass("player")
    friendlySpellID = PickSpell(CLASS_FRIENDLY[class])
end

-- ============================================================================
-- SECRET BOOLEAN SANITIZER
-- ----------------------------------------------------------------------------
-- WoW Midnight can return secret booleans.
-- We never directly test range API results.
--
-- Returns:
--   true / false = safe plain boolean
--   nil          = could not safely evaluate
-- ============================================================================
local function ToPlainBool(v)
    local ok, r = pcall(function()
        if v then
            return true
        end
        return false
    end)

    if ok then
        return r
    end

    return nil
end

-- ============================================================================
-- SAFE SPELL RANGE
-- ----------------------------------------------------------------------------
-- Safe wrapper for C_Spell.IsSpellInRange.
-- If the value is secret/unusable, returns nil.
-- ============================================================================
local function SafeSpellRange(spellID, unit)
    if not C_Spell_IsSpellInRange or not spellID or not unit then
        return nil
    end

    local ok, r = pcall(C_Spell_IsSpellInRange, spellID, unit)
    if not ok then
        return nil
    end

    return ToPlainBool(r)
end

-- ============================================================================
-- RAW RANGE RESULT
-- ----------------------------------------------------------------------------
-- Friendly-only logic for party/raid frames.
--
-- Rules:
--   • Missing/dead/offline units are treated as out of range
--   • If we have a friendly spell, use spell range
--   • If we do not have a friendly spell, return nil
--     (keep the current latched state instead of risking bad API usage)
--
-- Returns:
--   true  = in range
--   false = out of range
--   nil   = unknown / unsupported
-- ============================================================================
local function RawRangeResult(unit)
    if not unit or not UnitExists(unit) then
        return false
    end

    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
        return false
    end

    if UnitIsConnected and not UnitIsConnected(unit) then
        return false
    end

    if friendlySpellID then
        return SafeSpellRange(friendlySpellID, unit)
    end

    return nil
end

-- ============================================================================
-- ALPHA TARGET CACHE
-- ----------------------------------------------------------------------------
-- We fade only the regions we actually want to dim.
-- Cached once per frame.
-- ============================================================================
local function CacheAlphaTargets(frame)
    if frame._rangeTargets then return end

    local t = {}

    if frame.bg then t[#t+1] = frame.bg end
    if frame.hp then t[#t+1] = frame.hp end
    if frame.hpbg then t[#t+1] = frame.hpbg end
    if frame.power then t[#t+1] = frame.power end
    if frame.nameText then t[#t+1] = frame.nameText end
    if frame.roleText then t[#t+1] = frame.roleText end

    frame._rangeTargets = t
end

-- ============================================================================
-- APPLY ALPHA
-- ----------------------------------------------------------------------------
-- Avoids reapplying alpha if the value barely changed.
-- ============================================================================
local function ApplyAlpha(frame, a)
    if not frame then return end

    a = SafeAlpha(a, 1.0)

    local last = frame._rangeLastApplied
    if last and math_abs(last - a) < 0.01 then
        return
    end
    frame._rangeLastApplied = a

    CacheAlphaTargets(frame)
    local targets = frame._rangeTargets
    if not targets then return end

    for i = 1, #targets do
        local obj = targets[i]
        if obj and obj.SetAlpha then
            obj:SetAlpha(a)
        end
    end
end

-- ============================================================================
-- FRAME STATE INIT
-- ----------------------------------------------------------------------------
-- Initializes fading state for a frame the first time it is processed.
-- ============================================================================
local function InitFrameState(frame, ain)
    if frame._rangeIn == nil then
        local safeIn = SafeAlpha(ain, 1.0)

        frame._rangeIn = true
        frame._rangeAlpha = safeIn
        frame._rangeLastApplied = nil
        frame._rangeAnimating = false
        frame._rangeTargets = nil
    end
end

-- ============================================================================
-- RANGE APPLY
-- ----------------------------------------------------------------------------
-- Main per-frame update.
--
-- Notes:
--   • If range is unsupported for this class/spec, result stays latched
--   • Dead/offline units become faded
--   • Smooth transition prevents blinking
-- ============================================================================
function Range:Apply(frame, unit, dt, enabled, ain, aout, smoothing)
    if not frame or not unit then return end

    ain = SafeAlpha(ain, 1.0)
    aout = SafeAlpha(aout, 0.5)
    smoothing = SafeSmoothing(smoothing)

    InitFrameState(frame, ain)

    if not enabled then
        frame._rangeIn = true
        frame._rangeAlpha = ain
        frame._rangeAnimating = false
        ApplyAlpha(frame, ain)
        return
    end

    local r = RawRangeResult(unit)

    if r == false then
        if frame._rangeIn ~= false then
            frame._rangeIn = false
            frame._rangeAnimating = true
        end
    elseif r == true then
        if frame._rangeIn ~= true then
            frame._rangeIn = true
            frame._rangeAnimating = true
        end
    end

    local target = frame._rangeIn and ain or aout
    local cur = SafeAlpha(frame._rangeAlpha, target)

    if not frame._rangeAnimating and math_abs(cur - target) < 0.01 then
        return
    end

    local step = (dt or 0.2) * smoothing
    if step > 1 then step = 1 end
    if step < 0 then step = 0 end

    local nextA = cur + (target - cur) * step
    nextA = SafeAlpha(nextA, target)
    frame._rangeAlpha = nextA

    if math_abs(nextA - target) < 0.01 then
        frame._rangeAlpha = target
        frame._rangeAnimating = false
        ApplyAlpha(frame, target)
        return
    end

    ApplyAlpha(frame, nextA)
end

-- ============================================================================
-- DRIVER STATE
-- ----------------------------------------------------------------------------
-- Budgeted round-robin update state.
-- MAX_CHECKS_PER_TICK is the main CPU tuning knob.
-- ============================================================================
local acc = 0
local currentUpdateRate = 0.20
local MAX_CHECKS_PER_TICK = 10

local partyIndex = 1
local raidIndex  = 1

local f = CreateFrame("Frame")

-- ============================================================================
-- EVENTS
-- ----------------------------------------------------------------------------
-- Refresh known range spell when player setup changes.
-- ============================================================================
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("PLAYER_TALENT_UPDATE")
f:SetScript("OnEvent", RefreshSpells)

-- ============================================================================
-- FRAME PROCESSOR
-- ----------------------------------------------------------------------------
-- Processes only a limited number of visible frames each tick.
-- ============================================================================
local function ProcessFrames(list, startIndex, checksLeft, tickTime, enabled, ain, aout, smoothing)
    if not list or checksLeft <= 0 then
        return startIndex, checksLeft
    end

    local n = #list
    if n < 1 then
        return 1, checksLeft
    end

    local i = startIndex
    local loops = 0

    while checksLeft > 0 and loops < n do
        local frame = list[i]

        if frame and frame.unit and frame.IsShown and frame:IsShown() then
            Range:Apply(frame, frame.unit, tickTime, enabled, ain, aout, smoothing)
            checksLeft = checksLeft - 1
        end

        i = i + 1
        if i > n then i = 1 end
        loops = loops + 1
    end

    return i, checksLeft
end

-- ============================================================================
-- MAIN UPDATE LOOP
-- ----------------------------------------------------------------------------
-- Runs on accumulated time, not every raw frame.
--
-- Per tick:
--   • Read DB once
--   • Sanitize settings once
--   • Process Party first, then Raid, under shared CPU budget
-- ============================================================================
f:SetScript("OnUpdate", function(_, dt)
    acc = acc + (dt or 0)
    if acc < currentUpdateRate then return end

    local tickTime = acc
    acc = 0

    local rdb = GetRangeDB()
    local enabled = (rdb == nil) and true or (rdb.enabled ~= false)

    currentUpdateRate = SafeUpdateRate(rdb and rdb.update)

    if not enabled then
        return
    end

    local ain = SafeAlpha(rdb and rdb.alphaIn, 1.0)
    local aout = SafeAlpha(rdb and rdb.alphaOut, 0.5)
    local smoothing = SafeSmoothing(rdb and rdb.smoothing)

    local checksLeft = MAX_CHECKS_PER_TICK

    local partyFrames = ns.Party and ns.Party.frames
    partyIndex, checksLeft = ProcessFrames(
        partyFrames, partyIndex, checksLeft, tickTime, enabled, ain, aout, smoothing
    )

    local raidFrames = ns.Raid and ns.Raid.frames
    raidIndex, checksLeft = ProcessFrames(
        raidFrames, raidIndex, checksLeft, tickTime, enabled, ain, aout, smoothing
    )
end)

-- Initial spell setup on load.
RefreshSpells()
