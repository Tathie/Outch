-- Outch: tracks the outcome of using a Satchel of Potions (item 280766).

local SATCHEL_ID = 280766

-- Item ID -> counter key
local OUTCOME_ITEMS = {
    [1710] = "heal",  -- Greater Healing Potion
    [3827] = "mana",  -- Mana Potion
    [2459] = "swift", -- Swiftness Potion
}

-- How long after using the satchel we will attribute a result to it (seconds).
local WINDOW = 3

local pendingUntil = 0
local debugMode = false
local playerGUID

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

local function Debug(msg)
    if debugMode then Print("|cff888888[Outch debug]|r " .. msg) end
end

local function InitDB()
    OutchDB = OutchDB or {}
    OutchDB.heal = OutchDB.heal or 0
    OutchDB.mana = OutchDB.mana or 0
    OutchDB.swift = OutchDB.swift or 0
    OutchDB.outch = OutchDB.outch or 0
    OutchDB.outchDamage = OutchDB.outchDamage or 0
end

local function MarkUse(source)
    pendingUntil = GetTime() + WINDOW
    Debug("Satchel used (" .. source .. ")")
end

local function IsPending()
    return GetTime() <= pendingUntil
end

local function ClearPending()
    pendingUntil = 0
end

local GetItemSpellFn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
local function GetSatchelSpell()
    if GetItemSpellFn then
        return GetItemSpellFn(SATCHEL_ID) -- name, spellID (may be nil until item is cached)
    end
end

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- Turn a GlobalStrings format like "You receive item: %s." into a Lua pattern.
local function FormatToPattern(fmt)
    local p = fmt:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local SELF_LOOT_PATTERNS = {}
for _, key in ipairs({
    "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
}) do
    if _G[key] then table.insert(SELF_LOOT_PATTERNS, FormatToPattern(_G[key])) end
end

local function IsSelfLoot(msg)
    for _, pattern in ipairs(SELF_LOOT_PATTERNS) do
        if msg:match(pattern) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Detect satchel use (several paths, any one is enough)
---------------------------------------------------------------------------

local function GetContainerItemIDSafe(bag, slot)
    if C_Container and C_Container.GetContainerItemID then
        return C_Container.GetContainerItemID(bag, slot)
    elseif GetContainerItemID then
        return GetContainerItemID(bag, slot)
    end
end

local function OnUseContainerItem(bag, slot)
    if GetContainerItemIDSafe(bag, slot) == SATCHEL_ID then MarkUse("bag") end
end

if C_Container and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)
end
if UseContainerItem then
    hooksecurefunc("UseContainerItem", OnUseContainerItem)
end

if UseAction then
    hooksecurefunc("UseAction", function(slot)
        local actionType, id = GetActionInfo(slot)
        if actionType == "item" and id == SATCHEL_ID then MarkUse("action bar") end
    end)
end

if UseItemByName then
    hooksecurefunc("UseItemByName", function(name)
        local _, link = GetItemInfo(name)
        if ItemIDFromLink(link) == SATCHEL_ID then MarkUse("macro") end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

local function RecordOutch(amount, how)
    OutchDB.outch = OutchDB.outch + 1
    OutchDB.outchDamage = OutchDB.outchDamage + (amount or 0)
    ClearPending()
    Debug("Counted Outch for " .. tostring(amount) .. " (" .. how .. ")")
end

local function OnCombatLog()
    if not IsPending() then return end
    local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _, a12, a13, a14, a15 =
        CombatLogGetCurrentEventInfo()
    if destGUID ~= playerGUID then return end

    if subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" then
        -- a12 = spellID, a13 = spellName, a14 = spellSchool, a15 = amount
        local satchelSpellName = GetSatchelSpell()
        local isFire = bit.band(a14 or 0, 0x4) ~= 0
        Debug(("Self damage: %s %s school=%s amount=%s"):format(subevent, tostring(a13), tostring(a14), tostring(a15)))
        if sourceGUID == playerGUID or (isFire and a13 == satchelSpellName) then
            RecordOutch(a15, a13 or subevent)
        end
    elseif subevent == "ENVIRONMENTAL_DAMAGE" then
        -- a12 = environmentalType, a13 = amount
        Debug(("Environmental damage: %s amount=%s"):format(tostring(a12), tostring(a13)))
        if type(a12) == "string" and a12:upper() == "FIRE" then
            RecordOutch(a13, "environmental fire")
        end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "Outch" then InitDB() end

    elseif event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        GetSatchelSpell() -- warm the item cache

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" then
            local _, satchelSpellID = GetSatchelSpell()
            if satchelSpellID and spellID == satchelSpellID then MarkUse("spellcast") end
        end

    elseif event == "CHAT_MSG_LOOT" then
        if not IsPending() then return end
        local msg = ...
        local itemID = ItemIDFromLink(msg)
        Debug("Loot message: " .. msg)
        local key = itemID and OUTCOME_ITEMS[itemID]
        if key and IsSelfLoot(msg) then
            OutchDB[key] = OutchDB[key] + 1
            ClearPending()
            Debug("Counted " .. key)
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    end
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

SLASH_OUTCH1 = "/outch"
SlashCmdList["OUTCH"] = function(arg)
    arg = (arg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "reset" then
        OutchDB = nil
        InitDB()
        Print("Outch: counters reset.")
    elseif arg == "debug" then
        debugMode = not debugMode
        Print("Outch: debug " .. (debugMode and "on" or "off") .. ".")
    else
        local lines = {
            "Potion of Healing: " .. OutchDB.heal,
            "Mana Potion: " .. OutchDB.mana,
            "Go fast potion: " .. OutchDB.swift,
            ("Outch: %d (%d damage)"):format(OutchDB.outch, OutchDB.outchDamage),
        }

        local channel
        if arg == "s" then
            channel = "SAY"
        elseif arg == "p" then
            if not (IsInGroup and IsInGroup() or GetNumPartyMembers and GetNumPartyMembers() > 0) then
                Print("Outch: you are not in a party.")
                return
            end
            channel = "PARTY"
        end

        for _, line in ipairs(lines) do
            if channel then
                SendChatMessage(line, channel)
            else
                Print(line)
            end
        end
    end
end
