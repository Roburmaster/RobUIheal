-- ============================================================================
-- range.lua (RobHeal)
--
-- Purpose
-- -------
-- Handles range-based fading for Party and Raid frames only.
--
-- Design decisions
-- ----------------
-- 1) No hostile checks
--    Party/Raid frames are friendly units, so hostile logic is wasted work.
--
-- 2) Friendly spell classes use spell range only
--    For healer/support classes, spell range is the correct and precise check.
--
-- 3) Classes without a friendly spell use CheckInteractDistance fallback
--    This gives Warrior / DK / Rogue / Mage / Hunter / DH a cheap fallback.
--
-- 4) Midnight-safe
--    WoW can return secret booleans. Never test range API returns directly.
--    All range results are sanitized through pcall wrappers.
--
-- 5) CPU-budgeted
--    Only a limited number of frames are processed per tick.
--    Frames are processed round-robin instead of scanning every frame every update.
-- ============================================================================

local ADDON, ns = ...
ns.Range = ns.Range or {}
local Range = ns.Range

-- ============================================================================
-- FRIENDLY RANGE SPELLS
-- ----------------------------------------------------------------------------
-- These are used only for classes/specs that should use real spell range for
-- friendly units. We pick the first spell the player actually knows.
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
-- Localized for slightly lower overhead and cleaner access.
-- ============================================================================
local C_Spell_IsSpellInRange = C_Spell and C_Spell.IsSpellInRange

local UnitExists            = UnitExists
local UnitClass             = UnitClass
local UnitIsConnected       = UnitIsConnected
local UnitIsDeadOrGhost     = UnitIsDeadOrGhost
local CheckInteractDistance = CheckInteractDistance
local IsPlayerSpell         = IsPlayerSpell
local pcall                 = pcall

local ipairs   = ipairs
local math_abs = math.abs
local type     = type
local tonumber = tonumber

-- Active friendly spell selected for the player's class/spec.
local friendlySpellID

-- ============================================================================
-- SAFE NUMERIC HELPERS
-- ----------------------------------------------------------------------------
-- Protect against bad DB values and keep alpha/smoothing sane.
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
-- Reads the range DB once per tick in the driver.
-- ============================================================================
local function GetRangeDB()
    return ns.GetRangeDB and ns:GetRangeDB() or nil
end

-- ============================================================================
-- SPELL PICKING
-- ----------------------------------------------------------------------------
-- Chooses the first known spell from the class list.
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
-- Re-run this on login / talent change / spec change / spells changed.
-- ============================================================================
local function RefreshSpells()
    local _, class = UnitClass("player")
    friendlySpellID = PickSpell(CLASS_FRIENDLY[class])
end

-- ============================================================================
-- SECRET BOOLEAN SANITIZER
-- ----------------------------------------------------------------------------
-- Midnight can taint booleans returned from APIs.
-- Never do: if v then ...
-- unless wrapped safely.
--
-- Returns:
--   true / false = safe plain boolean
--   nil          = could not safely read it
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
-- Uses C_Spell.IsSpellInRange in a Midnight-safe way.
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
-- SAFE INTERACT FALLBACK
-- ----------------------------------------------------------------------------
-- Used only for classes that do not have a friendly spell range option.
-- This is cheaper and less precise than spell range, but good enough as a
-- fallback for non-healer classes on party/raid frames.
-- ============================================================================
local function SafeInteractRange(unit)
    if not CheckInteractDistance or not unit then
        return nil
    end

    local ok, r = pcall(CheckInteractDistance, unit, 4)
    if not ok then
        return nil
    end

    if type(r) == "boolean" then
        return r
    end

    return ToPlainBool(r)
end

-- ============================================================================
-- RAW RANGE RESULT
-- ----------------------------------------------------------------------------
-- Friendly-only logic, because this file is for Party/Raid frames.
--
-- Rules:
--   • Dead/offline/missing units are treated as out of range (false)
--   • If class has a friendly spell range, use only that
--   • Otherwise use interact fallback
--
-- Returns:
--   true  = in range
--   false = out of range
--   nil   = unknown (keep existing latched state)
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

    return SafeInteractRange(unit)
end

-- ============================================================================
-- ALPHA TARGET CACHE
-- ----------------------------------------------------------------------------
-- We only fade the regions we care about instead of touching the full frame.
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
-- Initializes the fading state for a frame the first time it is processed.
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
-- Main per-frame logic.
--
-- CPU notes:
--   • Early-out if disabled
--   • Early-out for dead/offline already happens inside RawRangeResult
--   • If result is nil, keep current latched state
--   • Smoothing prevents blink / snapping
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

    -- Already at target and not animating -> nothing to do.
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
-- Round-robin update state.
-- MAX_CHECKS_PER_TICK is the main CPU budget knob.
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
-- Only refresh spell selection when the player's spellbook/spec changes.
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
--
-- CPU optimizations:
--   • Skip nil frames
--   • Skip frames with no unit
--   • Skip hidden frames
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
-- Runs every frame, but only performs work when enough time has accumulated.
--
-- Per tick:
--   • Read DB once
--   • Sanitize settings once
--   • Process Party first, then Raid, under a shared budget
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
