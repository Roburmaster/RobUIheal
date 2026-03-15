-- ============================================================================
-- Tooltip IDs (WoW 12.0+ / Midnight safe)
-- Adds SpellID (spells + auras) and ItemID to tooltips via TooltipDataProcessor
-- Combat-guarded to reduce taint risk
-- ============================================================================

local InCombatLockdown = InCombatLockdown
local type = type
local tonumber = tonumber

local function SafeAddLine(tooltip, left, value)
    if not tooltip or value == nil then return end
    tooltip:AddLine(" ")
    tooltip:AddLine(left .. tostring(value))
end

local function AddSpellID(tooltip, data)
    if InCombatLockdown and InCombatLockdown() then return end
    if not tooltip or not data then return end

    local spellID = data.id
    if type(spellID) == "number" then
        SafeAddLine(tooltip, "|cffffcc00SpellID:|r ", spellID)
    end
end

local function AddAuraSpellID(tooltip, data)
    if InCombatLockdown and InCombatLockdown() then return end
    if not tooltip or not data then return end
    if not data.auraInstanceID or not data.unit then return end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByAuraInstanceID then return end

    local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, data.unit, data.auraInstanceID)
    if not ok or not aura then return end

    local spellID = aura.spellId
    if type(spellID) == "number" then
        SafeAddLine(tooltip, "|cffffcc00SpellID:|r ", spellID)
    end
end

local function AddItemID(tooltip, data)
    if InCombatLockdown and InCombatLockdown() then return end
    if not tooltip or not data then return end

    local itemID = data.id

    if type(itemID) ~= "number" then
        itemID = nil
        if type(data.hyperlink) == "string" then
            itemID = tonumber(data.hyperlink:match("item:(%d+)"))
        end
    end

    if type(itemID) == "number" then
        SafeAddLine(tooltip, "|cffffcc00ItemID:|r ", itemID)
    end
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, AddSpellID)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.UnitAura, AddAuraSpellID)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddItemID)
end
