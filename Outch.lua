-- Outch: tracks the outcome of using a Satchel of Potions (item 280766).
--
-- The satchel isn't used up; it goes on a 10 minute cooldown and makes you
-- drink one of three potions on the spot, or burns you. WoW Forever runs on
-- the modern client, where addons can't read the combat log, so:
--   * a use is detected when the satchel's cooldown starts (or you cast its
--     spell),
--   * the potion is detected from you casting its spell, with backups: the
--     Swiftness buff appearing, or a big jump in your mana or health,
--   * nothing within a few seconds means the satchel burned you (Outch); the
--     damage is read from your own health dropping.

local SATCHEL_ID = 280766

-- Potion spell ID -> counter key
local OUTCOME_SPELLS = {
    [2024] = "heal",  -- Greater Healing Potion
    [2023] = "mana",  -- Mana Potion
    [2379] = "swift", -- Swiftness Potion
}

-- Spell names as a fallback, in case Forever uses different spell IDs.
local OUTCOME_SPELL_NAMES = {
    ["Healing Potion"] = "heal",
    ["Greater Healing Potion"] = "heal",
    ["Restore Mana"] = "mana",
    ["Mana Potion"] = "mana",
    ["Speed"] = "swift",
    ["Swiftness Potion"] = "swift",
}

local SWIFTNESS_AURA = 2379

-- A jump at least this big in mana/health right after using the satchel
-- counts as the mana/healing potion when the spell itself wasn't seen.
local MIN_MANA_GAIN = 200
local MIN_HEALTH_GAIN = 200

-- Seconds between using the satchel and its outcome.
local WINDOW = 5

-- Damage the satchel deals; used only if your health can't be read.
local OUTCH_DAMAGE = 216

-- Shorter cooldowns aren't a satchel use (global cooldown, or a 2 minute
-- potion cooldown the satchel might share). The satchel's is 10 minutes.
local MIN_COOLDOWN = 300

local GetItemCooldownFn = (C_Item and C_Item.GetItemCooldown)
    or (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
local GetItemSpellFn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
local SendChatFn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local debugMode = false
local useTime            -- when the satchel was used, until its outcome is counted
local outcome            -- latest potion effect seen: { key, time }
local healthLosses = {}  -- recent drops in your health: { time, amount }
local lastHealth, lastMana
local hadSwiftness = false
local lastUseTime = -1000
local lastCooldownStart

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

local function Debug(msg)
    if debugMode then Print("|cff888888[Outch debug]|r " .. msg) end
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function InitDB()
    OutchDB = OutchDB or {}
    OutchDB.heal = OutchDB.heal or 0
    OutchDB.mana = OutchDB.mana or 0
    OutchDB.swift = OutchDB.swift or 0
    OutchDB.outch = OutchDB.outch or 0
    OutchDB.outchDamage = OutchDB.outchDamage or 0
end

local function ReadNumber(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok or type(v) ~= "number" or IsSecret(v) then return nil end
    return v
end

local function ReadHealth()
    return ReadNumber(UnitHealth, "player")
end

local function ReadMana()
    local manaType = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
    return ReadNumber(UnitPower, "player", manaType)
end

local function HasSwiftness()
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, SWIFTNESS_AURA)
        return ok and aura ~= nil
    end
    return false
end

local function SpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok then return name end
    elseif GetSpellInfo then
        return (GetSpellInfo(spellID))
    end
end

local function ReadCooldown()
    if not GetItemCooldownFn then return nil end
    local ok, start, duration = pcall(GetItemCooldownFn, SATCHEL_ID)
    if not ok or type(start) ~= "number" or type(duration) ~= "number" then return nil end
    if IsSecret(start) or IsSecret(duration) then return nil end
    return start, duration
end

local function SatchelSpellID()
    if not GetItemSpellFn then return nil end
    local ok, _, spellID = pcall(GetItemSpellFn, SATCHEL_ID)
    if ok then return spellID end
end

---------------------------------------------------------------------------
-- Matching a satchel use to its outcome
---------------------------------------------------------------------------

-- Largest single health drop around the time the satchel was used.
local function DamageNear(t)
    local best
    for _, loss in ipairs(healthLosses) do
        if loss.time >= t - 1.5 and loss.time <= t + WINDOW then
            if not best or loss.amount > best then best = loss.amount end
        end
    end
    return best
end

local function Resolve()
    local now = GetTime()

    if useTime then
        if outcome and math.abs(outcome.time - useTime) <= WINDOW then
            OutchDB[outcome.key] = OutchDB[outcome.key] + 1
            Debug("Counted " .. outcome.key)
            useTime, outcome = nil, nil
        elseif now - useTime > WINDOW then
            local damage = DamageNear(useTime)
            OutchDB.outch = OutchDB.outch + 1
            OutchDB.outchDamage = OutchDB.outchDamage + (damage or OUTCH_DAMAGE)
            Debug("Counted Outch for " .. (damage or OUTCH_DAMAGE)
                .. (damage and "" or " (health unreadable, assumed)"))
            useTime = nil
        end
    end

    if outcome and now - outcome.time > WINDOW then outcome = nil end
    for i = #healthLosses, 1, -1 do
        if now - healthLosses[i].time > WINDOW * 3 then table.remove(healthLosses, i) end
    end
end

-- Called by every use-detection path. The satchel's 10 minute cooldown means
-- anything within a few seconds of the last use is the same use.
local function MarkUse(how)
    local now = GetTime()
    if now - lastUseTime < 10 then return end
    lastUseTime = now
    useTime = now
    Debug("Satchel used (" .. how .. ")")
    C_Timer.After(WINDOW + 0.2, Resolve)
    Resolve()
end

-- An outcome may be seen just before the use is detected, so it's kept for
-- WINDOW seconds and matched either way round.
local function AddOutcome(key, how)
    outcome = { key = key, time = GetTime() }
    Debug(key .. " seen (" .. how .. ")")
    Resolve()
end

local function NearUse()
    return useTime ~= nil or GetTime() - lastUseTime <= WINDOW
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------

local function CheckCooldown()
    local start, duration = ReadCooldown()
    if not start then return end
    if start > 0 and duration >= MIN_COOLDOWN then
        if lastCooldownStart ~= start then
            lastCooldownStart = start
            MarkUse("cooldown started")
        end
    else
        lastCooldownStart = nil
    end
end

local function OnSpellCast(spellID)
    if IsSecret(spellID) then
        Debug("You cast a spell (hidden by the game)")
        return
    end
    local name = SpellName(spellID)
    Debug("You cast: " .. tostring(name) .. " (spell " .. tostring(spellID) .. ")")

    if spellID == SatchelSpellID() then
        MarkUse("spell cast")
    end

    local key = OUTCOME_SPELLS[spellID] or (name and OUTCOME_SPELL_NAMES[name])
    if key then AddOutcome(key, "spell " .. tostring(name)) end
end

local function OnHealthChanged()
    local h = ReadHealth()
    if h and lastHealth then
        if h < lastHealth then
            table.insert(healthLosses, { time = GetTime(), amount = lastHealth - h })
            Debug("Health -" .. (lastHealth - h))
        elseif h - lastHealth >= MIN_HEALTH_GAIN and NearUse() then
            Debug("Health +" .. (h - lastHealth))
            AddOutcome("heal", "health jump")
        end
    end
    lastHealth = h
end

local function OnManaChanged()
    local m = ReadMana()
    if m and lastMana and m - lastMana >= MIN_MANA_GAIN and NearUse() then
        Debug("Mana +" .. (m - lastMana))
        AddOutcome("mana", "mana jump")
    end
    lastMana = m
end

local function OnAuraChanged()
    local has = HasSwiftness()
    if has and not hadSwiftness then
        AddOutcome("swift", "speed buff")
    end
    hadSwiftness = has
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("BAG_UPDATE_COOLDOWN")
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_HEALTH", "player")
frame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
frame:RegisterUnitEvent("UNIT_AURA", "player")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "Outch" then InitDB() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        lastHealth = ReadHealth()
        lastMana = ReadMana()
        hadSwiftness = HasSwiftness()
        -- Don't count a cooldown that was already running when you logged in.
        local start, duration = ReadCooldown()
        if start and start > 0 and duration >= MIN_COOLDOWN then
            lastCooldownStart = start
        end

    elseif event == "BAG_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" then
        CheckCooldown()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        OnSpellCast(spellID)

    elseif event == "UNIT_HEALTH" then
        OnHealthChanged()

    elseif event == "UNIT_POWER_UPDATE" then
        OnManaChanged()

    elseif event == "UNIT_AURA" then
        OnAuraChanged()
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
        if debugMode then
            Debug("Satchel cooldown readable: " .. (ReadCooldown() and "yes" or "no")
                .. ", satchel spell: " .. tostring(SatchelSpellID())
                .. ", health readable: " .. (ReadHealth() and "yes" or "no")
                .. ", mana readable: " .. (ReadMana() and "yes" or "no"))
        end
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
            if not IsInGroup() then
                Print("Outch: you are not in a party.")
                return
            end
            channel = "PARTY"
        end

        for _, line in ipairs(lines) do
            if channel then
                SendChatFn(line, channel)
            else
                Print(line)
            end
        end
    end
end
