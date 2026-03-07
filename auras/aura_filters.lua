-- ============================================================================
-- aura_filters.lua (RobHeal) - WoW 12.0 / Midnight
-- Central place for aura spell lists + priorities.
--
-- Goal:
--  - One source of truth for tracked auras (friendly buffs, etc)
--  - Avoid duplicates, keep stable priority order
--  - Allow other modules to fetch a list without embedding big tables everywhere
--
-- API:
--   local AF = ns.AuraFilters
--   AF:GetList("FRIENDLYBUFFS") -> array of spellIDs (priority order)
--   AF:BuildMaps(list) -> whitelistSet, prioMap
-- ============================================================================

local _, ns = ...
ns.AuraFilters = ns.AuraFilters or {}
local AF = ns.AuraFilters

local type = type
local ipairs = ipairs
local wipe = wipe

-- ---------------------------------------------------------------------------
-- FRIENDLY BUFFS (HoTs / Shields / Externals / Defensives)
-- Priority order matters: earlier = more important.
-- ---------------------------------------------------------------------------
AF.DEFAULT_FRIENDLYBUFFS = {
    -- Holy Paladin
    53563,    -- Beacon of Light
    156910,   -- Beacon of Faith
    1244893,  -- Beacon of the Savior
    156322,   -- Eternal Flame

    -- Shields / Externals
    17,      -- Power Word: Shield
    974,     -- Earth Shield
    1022,    -- Blessing of Protection
    6940,    -- Blessing of Sacrifice
    47788,   -- Guardian Spirit
    33206,   -- Pain Suppression
    102342,  -- Ironbark
    116849,  -- Life Cocoon
    204018,  -- Blessing of Spellwarding (if exists)
    1044,    -- Blessing of Freedom

    -- HoTs
    774,     -- Rejuvenation
    8936,    -- Regrowth
    33763,   -- Lifebloom
    139,     -- Renew
    61295,   -- Riptide
    119611,  -- Renewing Mist
    157982,  -- Tranquility (hot ticks, sometimes useful) - optional

    -- Utility / class mechanics
    194384,  -- Atonement
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Dedup(list)
local out = {}
local seen = {}
for _, id in ipairs(list or {}) do
    if type(id) == "number" and id > 0 and not seen[id] then
        seen[id] = true
        out[#out + 1] = id
        end
        end
        return out
        end

        function AF:GetList(which)
        if which == "FRIENDLYBUFFS" then
            return Dedup(self.DEFAULT_FRIENDLYBUFFS)
            end
            return {}
            end

            -- Build whitelist set + priority map from list
            function AF:BuildMaps(list)
            local wl = {}
            local pr = {}
            local p = 1
            for _, id in ipairs(list or {}) do
                if type(id) == "number" and id > 0 then
                    if not wl[id] then
                        wl[id] = true
                        pr[id] = p
                        p = p + 1
                        end
                        end
                        end
                        return wl, pr
                        end
