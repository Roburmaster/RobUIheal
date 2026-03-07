-- ============================================================================
-- Tooltip IDs (WoW 12.0+ / Midnight safe)
-- Adds SpellID (spells + auras) and ItemID to tooltips via TooltipDataProcessor
-- ============================================================================

local function AddIDsToTooltip(tooltip, data)
    if not tooltip or not data then return end

    -- Spells
    if data.type == Enum.TooltipDataType.Spell then
        local spellID = data.id
        if spellID then
            tooltip:AddLine(" ")
            tooltip:AddLine("|cffffcc00SpellID:|r " .. spellID)
        end
    end

    -- Unit auras (buff/debuff)
    if data.type == Enum.TooltipDataType.UnitAura then
        if data.auraInstanceID and data.unit then
            local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(data.unit, data.auraInstanceID)
            if aura and aura.spellId then
                tooltip:AddLine(" ")
                tooltip:AddLine("|cffffcc00SpellID:|r " .. aura.spellId)
            end
        end
    end

    -- Items
    if data.type == Enum.TooltipDataType.Item then
        -- In 12.0 tooltip data often has itemID directly; if not, fall back to link parsing
        local itemID = data.id

        if not itemID then
            -- Try to find an item hyperlink in the tooltip data
            if data.hyperlink and type(data.hyperlink) == "string" then
                itemID = tonumber(data.hyperlink:match("item:(%d+)"))
            end
        end

        if itemID then
            tooltip:AddLine(" ")
            tooltip:AddLine("|cffffcc00ItemID:|r " .. itemID)
        end
    end
end

TooltipDataProcessor.AddTooltipPostCall(TooltipDataProcessor.AllTypes, AddIDsToTooltip)
