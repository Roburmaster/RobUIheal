-- ============================================================================
-- auralib.lua (RobHeal) - WoW 12.0 secret-safe (RAID/BOSS SAFE)
-- Provides strict sanitizers + safe aura getters based on C_UnitAuras.
--
-- PATCH (works with Midnight 12.0 dispel logic):
--   - Supports filter "RAID_PLAYER_DISPELLABLE"
--   - Returns canDispel (sanitized) from aura.canActivePlayerDispel
--   - dispelType remains best-effort only (may be nil in combat)
-- ============================================================================

local _, ns = ...
ns.Aura = ns.Aura or {}
local A = ns.Aura

local CUA = C_UnitAuras
local UnitExists = UnitExists
local pcall = pcall
local tostring = tostring
local type = type

A.secretsEnabled = false

-- ------------------------------------------------------------
-- STRICT SANITIZERS
-- ------------------------------------------------------------
local function GetSafeNumber(val)
local ok, t = pcall(type, val)
if ok and t == "number" then
    local ok2 = pcall(function() return val == val end)
    if ok2 then return val end
        end
        return 0
        end

        local function GetSafeString(val)
        local ok, t = pcall(type, val)
        if ok and t == "string" then
            local ok2 = pcall(function() return val == "" end)
            if ok2 then return val end
                end
                return nil
                end

                local function GetSafeID(val)
                local ok, t = pcall(type, val)
                if ok and t == "number" then
                    local ok2 = pcall(function() return val == val end)
                    if ok2 then return val end
                        end
                        return nil
                        end

                        local function GetSafeBoolean(val)
                        local ok, t = pcall(type, val)
                        if ok and t == "boolean" then
                            local ok2 = pcall(function() return val == true end)
                            if ok2 then return val end
                                end

                                -- secret-wrapped booleans: touch-test
                                local ok3, res = pcall(function() return val == true end)
                                if ok3 and res == true then
                                    return true
                                    end

                                    return false
                                    end

                                    local function GetSafeStringish(val)
                                    local ok, t = pcall(type, val)
                                    if ok and t == "string" then
                                        local ok2 = pcall(function() return val == "" end)
                                        if ok2 then return val end
                                            return nil
                                            end

                                            local ok3, s = pcall(tostring, val)
                                            if ok3 then
                                                local ok4, ts = pcall(type, s)
                                                if ok4 and ts == "string" and s ~= "" then
                                                    return s
                                                    end
                                                    end

                                                    return nil
                                                    end

                                                    local function GetDispelTypeFromAura(aura)
                                                    -- Best-effort only. In combat this may still return nil.
                                                    local dt =
                                                    GetSafeStringish(aura.dispelName) or
                                                    GetSafeStringish(aura.dispelTypeName) or
                                                    GetSafeStringish(aura.dispelType)

                                                    if dt then return dt end

                                                        local n = GetSafeNumber(aura.dispelType)
                                                        if n ~= 0 then
                                                            if n == 1 then return "Magic" end
                                                                if n == 2 then return "Curse" end
                                                                    if n == 3 then return "Disease" end
                                                                        if n == 4 then return "Poison" end
                                                                            end

                                                                            return nil
                                                                            end

                                                                            -- ------------------------------------------------------------
                                                                            -- Internal helper: get aura by index with fallback
                                                                            -- IMPORTANT:
                                                                            --   - If caller passes "RAID_PLAYER_DISPELLABLE", we try that first (best).
                                                                            --   - Fallback to "HARMFUL" always.
                                                                            -- ------------------------------------------------------------
                                                                            local function GetAuraByIndex(unit, index, filter)
                                                                            if not (CUA and CUA.GetAuraDataByIndex) then return nil, nil end

                                                                                -- Caller decides. Default: HARMFUL (safe baseline).
                                                                                filter = filter or "HARMFUL"

                                                                                local aura = CUA.GetAuraDataByIndex(unit, index, filter)
                                                                                if aura then
                                                                                    return aura, filter
                                                                                    end

                                                                                    if filter ~= "HARMFUL" then
                                                                                        aura = CUA.GetAuraDataByIndex(unit, index, "HARMFUL")
                                                                                        if aura then
                                                                                            return aura, "HARMFUL"
                                                                                            end
                                                                                            end

                                                                                            return nil, nil
                                                                                            end

                                                                                            -- ------------------------------------------------------------
                                                                                            -- Safe debuff getter
                                                                                            -- Returns sanitized primitives:
                                                                                            --   name, icon, applications, dispelType, duration, expirationTime, spellId, filterUsed, canDispel
                                                                                            -- ------------------------------------------------------------
                                                                                            function A:UnitDebuffLite(unit, index, filter)
                                                                                            if self.secretsEnabled then return nil end
                                                                                                if not unit or not UnitExists(unit) then return nil end
                                                                                                    if not index then return nil end

                                                                                                        local aura, filterUsed = GetAuraByIndex(unit, index, filter)
                                                                                                        if not aura then return nil end

                                                                                                            local spellId = GetSafeID(aura.spellId)
                                                                                                            local name = GetSafeString(aura.name)
                                                                                                            if not name then
                                                                                                                if spellId then name = "Spell #" .. spellId else name = "Unknown" end
                                                                                                                    end

                                                                                                                    local icon = aura.icon
                                                                                                                    local applications = GetSafeNumber(aura.applications)

                                                                                                                    -- Best-effort only (can be nil in combat)
                                                                                                                    local dispelType = GetDispelTypeFromAura(aura)

                                                                                                                    local duration   = GetSafeNumber(aura.duration)
                                                                                                                    local expiration = GetSafeNumber(aura.expirationTime)

                                                                                                                    -- Combat-safe truth:
                                                                                                                    local canDispel = GetSafeBoolean(aura.canActivePlayerDispel)

                                                                                                                    return name, icon, applications, dispelType, duration, expiration, spellId, filterUsed, canDispel
                                                                                                                    end

