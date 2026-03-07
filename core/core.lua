-- ============================================================================
-- core.lua (RobHeal) - init + safe rebuild queue
-- - Central init on PLAYER_LOGIN
-- - Queues party/raid rebuild requests until out of combat
-- - Rebuild on spells/spec changes
-- ============================================================================

local ADDON, ns = ...
_G[ADDON] = ns

-- ------------------------------------------------------------
-- Safe rebuild helpers (queue rebuild until out of combat)
-- ------------------------------------------------------------
local pendingParty, pendingRaid = false, false

local function InCombat()
    return InCombatLockdown and InCombatLockdown()
end

function ns:RequestPartyRebuild()
    if InCombat() then
        pendingParty = true
        return
    end
    if ns.Party and ns.Party.Build then
        ns.Party:Build()
    end
end

function ns:RequestRaidRebuild()
    if InCombat() then
        pendingRaid = true
        return
    end
    if ns.Raid and ns.Raid.Build then
        ns.Raid:Build()
    end
end

-- ------------------------------------------------------------
-- Core events
-- ------------------------------------------------------------
local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:RegisterEvent("PLAYER_REGEN_ENABLED")

-- useful: changes can affect dispel / modules / layout
ef:RegisterEvent("SPELLS_CHANGED")
ef:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

ef:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" then
        -- Init modules (only if present)
        if ns.BlizzDispel and ns.BlizzDispel.Init then ns.BlizzDispel:Init() end
        if ns.Dispel and ns.Dispel.Init then ns.Dispel:Init() end

        if ns.Party and ns.Party.Init then ns.Party:Init() end
        if ns.Raid  and ns.Raid.Init  then ns.Raid:Init()  end

        if ns.TargetedSpells and ns.TargetedSpells.Init then ns.TargetedSpells:Init() end

        -- Settings (tabbed unified settings.lua)
        if ns.Settings and ns.Settings.Init then ns.Settings:Init() end

        return
    end

    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        if unit and unit ~= "player" then return end
        ns:RequestPartyRebuild()
        ns:RequestRaidRebuild()
        return
    end

    if event == "SPELLS_CHANGED" then
        ns:RequestPartyRebuild()
        ns:RequestRaidRebuild()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if pendingParty then
            pendingParty = false
            ns:RequestPartyRebuild()
        end
        if pendingRaid then
            pendingRaid = false
            ns:RequestRaidRebuild()
        end
        return
    end
end)
