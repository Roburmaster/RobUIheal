-- ============================================================================
-- range.lua (RobHeal) - NO BLINK (LATCH) - CPU BUDGETED
-- Owns alpha for Party + Raid frames.
--
-- Key CPU fixes:
--  - Budgeted round-robin checks (limits IsSpellInRange calls per tick)
--  - Per-frame cached alpha targets (avoid touching many regions repeatedly)
--  - Scrub settings once per tick
-- ============================================================================

local ADDON, ns = ...
ns.Range = ns.Range or {}
local Range = ns.Range

local CLASS_FRIENDLY = {
    PRIEST  = { 2061, 2050, 17 },
    DRUID   = { 8936, 774, 33763 },
    PALADIN = { 19750, 82326 },
    SHAMAN  = { 8004, 77472, 61295 },
    MONK    = { 116670, 124682, 115175 },
    EVOKER  = { 361469, 355913, 360995 },
    WARLOCK = { 20707 },
}

local CLASS_HOSTILE = {
    PRIEST  = { 585 },
    DRUID   = { 8921 },
    SHAMAN  = { 188196 },
    PALADIN = { 62124 },
    MONK    = { 115546 },
    EVOKER  = { 361469 },
    WARLOCK = { 686 },
    WARRIOR = { 355 },
    DEATHKNIGHT = { 49576, 47541 },
    MAGE    = { 116, 133, 30451 },
    HUNTER  = { 19434, 56641, 132031 },
    ROGUE   = { 6770, 36554 },
    DEMONHUNTER = { 185123 },
}

local C_Spell_IsSpellInRange = C_Spell and C_Spell.IsSpellInRange
local UnitExists    = UnitExists
local UnitCanAttack = UnitCanAttack
local UnitClass     = UnitClass
local IsPlayerSpell = IsPlayerSpell

local ipairs = ipairs
local math_abs = math.abs
local type = type
local tonumber = tonumber

local friendlySpellID
local hostileSpellID

-- ------------------------------------------------------------
-- Safe numeric helpers (prevents SetAlpha(nil) + clamps 0..1)
-- ------------------------------------------------------------
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

local function GetRangeDB()
    return ns.GetRangeDB and ns:GetRangeDB() or nil
end

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

local function RefreshSpells()
    local _, class = UnitClass("player")
    friendlySpellID = PickSpell(CLASS_FRIENDLY[class])
    hostileSpellID  = PickSpell(CLASS_HOSTILE[class])
end

local function RawRangeResult(unit)
    if not unit or not UnitExists(unit) then return nil end
    if not C_Spell_IsSpellInRange then return nil end

    local hostile = UnitCanAttack("player", unit) and true or false
    local spellID = hostile and hostileSpellID or friendlySpellID
    if not spellID then return nil end

    return C_Spell_IsSpellInRange(spellID, unit)
end

-- ------------------------------------------------------------
-- Alpha application
-- ------------------------------------------------------------
local function CacheAlphaTargets(frame)
    if frame._rangeTargets then return end
    local t = {}

    -- Keep it strict: only fields you already used before
    if frame.bg then t[#t+1] = frame.bg end
    if frame.hp then t[#t+1] = frame.hp end
    if frame.hpbg then t[#t+1] = frame.hpbg end
    if frame.power then t[#t+1] = frame.power end
    if frame.nameText then t[#t+1] = frame.nameText end
    if frame.roleText then t[#t+1] = frame.roleText end

    frame._rangeTargets = t
end

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

-- Modified to accept settings directly instead of fetching DB per unit
function Range:Apply(frame, unit, dt, enabled, ain, aout, smoothing)
    if not frame or not unit then return end

    ain = SafeAlpha(ain, 1.0)
    aout = SafeAlpha(aout, 0.5)
    smoothing = SafeSmoothing(smoothing)

    InitFrameState(frame, ain)

    if not enabled or (not friendlySpellID and not hostileSpellID) then
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

-- ---------------------------------------------------------------------------
-- Driver (budgeted round-robin)
-- ---------------------------------------------------------------------------
local acc = 0
local currentUpdateRate = 0.20

-- HARD budget: max units checked per tick (combined party+raid)
-- If you want: 8 for ultra-light, 12 for safer responsiveness.
local MAX_CHECKS_PER_TICK = 10

local partyIndex = 1
local raidIndex  = 1

local f = CreateFrame("Frame")

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("PLAYER_TALENT_UPDATE")
f:SetScript("OnEvent", RefreshSpells)

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

f:SetScript("OnUpdate", function(_, dt)
    acc = acc + (dt or 0)
    if acc < currentUpdateRate then return end

    local tickTime = acc
    acc = 0

    local rdb = GetRangeDB()

    -- enabled default true unless explicitly false
    local enabled = (rdb == nil) and true or (rdb.enabled ~= false)

    -- scrub update rate every tick (and use it next frame)
    currentUpdateRate = SafeUpdateRate(rdb and rdb.update)

    if not enabled or (not friendlySpellID and not hostileSpellID) then
        return
    end

    -- Fetch settings ONCE per tick
    local ain = SafeAlpha(rdb and rdb.alphaIn, 1.0)
    local aout = SafeAlpha(rdb and rdb.alphaOut, 0.5)
    local smoothing = SafeSmoothing(rdb and rdb.smoothing)

    local checksLeft = MAX_CHECKS_PER_TICK

    local partyFrames = ns.Party and ns.Party.frames
    partyIndex, checksLeft = ProcessFrames(partyFrames, partyIndex, checksLeft, tickTime, enabled, ain, aout, smoothing)

    local raidFrames = ns.Raid and ns.Raid.frames
    raidIndex, checksLeft = ProcessFrames(raidFrames, raidIndex, checksLeft, tickTime, enabled, ain, aout, smoothing)
end)

RefreshSpells()