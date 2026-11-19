-- Outch: tracks the outcome of using a Satchel of Potions (item 280766).
--
-- The satchel isn't used up; it goes on a 10 minute cooldown. WoW Forever
-- runs on the modern client, where addons can't read the combat log, so:
--   * a use is detected when the satchel's cooldown starts (or when you cast
--     its spell),
--   * a potion appearing in your bags within a few seconds is that outcome,
--   * no potion means the satchel burned you (Outch); the damage is read from
--     your own health dropping.

local SATCHEL_ID = 280766

-- Item ID -> counter key
local OUTCOME_ITEMS = {
    [1710] = "heal",  -- Greater Healing Potion
    [3827] = "mana",  -- Mana Potion
    [2459] = "swift", -- Swiftness Potion
}

-- Seconds between using the satchel and a potion appearing that we still
-- treat as the same use.
local WINDOW = 3

-- Damage the satchel deals; used only if your health can't be read.
local OUTCH_DAMAGE = 216

-- Cooldowns shorter than this aren't a satchel use (global cooldown, or a
-- 2 minute potion cooldown the satchel might share). The satchel's is 10 min.
local MIN_COOLDOWN = 300

local GetItemCountFn = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetItemCooldownFn = (C_Item and C_Item.GetItemCooldown)
    or (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
local GetItemSpellFn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
local SendChatFn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local debugMode = false
local counts = {}        -- last seen bag counts, by item ID
local pendingUses = {}   -- satchel uses not resolved yet: { time }
local recentGains = {}   -- potions that appeared recently: { key, time }
local healthLosses = {}  -- recent drops in your health: { time, amount }
local lastHealth
local lastUseTime = -1000
local lastCooldownStart
local openFrames = {}    -- vendor/bank/mail/trade etc. currently open

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

local function Count(itemID)
    return GetItemCountFn(itemID) or 0
end

-- Potions arriving while you're at a vendor, bank, mailbox or trade window
-- are bought/moved, not from the satchel.
local function IsBusy()
    return next(openFrames) ~= nil
end

---------------------------------------------------------------------------
-- Health tracking (for Outch damage)
---------------------------------------------------------------------------

local function ReadHealth()
    local ok, h = pcall(UnitHealth, "player")
    if not ok or type(h) ~= "number" or IsSecret(h) then return nil end
    return h
end

local function OnHealthChanged()
    local h = ReadHealth()
    if h and lastHealth and h < lastHealth then
        table.insert(healthLosses, { time = GetTime(), amount = lastHealth - h })
        Debug("Health -" .. (lastHealth - h))
    end
    lastHealth = h
end

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

---------------------------------------------------------------------------
-- Matching satchel uses to outcomes
---------------------------------------------------------------------------

local function Resolve()
    local now = GetTime()

    local i = 1
    while i <= #pendingUses do
        local use = pendingUses[i]
        local matched
        for j, gain in ipairs(recentGains) do
            if math.abs(gain.time - use.time) <= WINDOW then
                matched = j
                break
            end
        end

        if matched then
            local key = table.remove(recentGains, matched).key
            OutchDB[key] = OutchDB[key] + 1
            table.remove(pendingUses, i)
            Debug("Counted " .. key)
        elseif now - use.time > WINDOW then
            local damage = DamageNear(use.time)
            OutchDB.outch = OutchDB.outch + 1
            OutchDB.outchDamage = OutchDB.outchDamage + (damage or OUTCH_DAMAGE)
            table.remove(pendingUses, i)
            Debug("Counted Outch for " .. (damage or OUTCH_DAMAGE)
                .. (damage and "" or " (health unreadable, assumed)"))
        else
            i = i + 1
        end
    end

    for j = #recentGains, 1, -1 do
        if now - recentGains[j].time > WINDOW then table.remove(recentGains, j) end
    end
    for j = #healthLosses, 1, -1 do
        if now - healthLosses[j].time > WINDOW * 3 then table.remove(healthLosses, j) end
    end
end

-- Called by every detection path; the satchel's 10 minute cooldown means
-- anything within a few seconds of the last use is the same use.
local function MarkUse(how)
    local now = GetTime()
    if now - lastUseTime < 10 then return end
    lastUseTime = now
    table.insert(pendingUses, { time = now })
    Debug("Satchel used (" .. how .. ")")
    C_Timer.After(WINDOW + 0.2, Resolve)
    Resolve()
end

---------------------------------------------------------------------------
-- Detecting a use
---------------------------------------------------------------------------

local function ReadCooldown()
    if not GetItemCooldownFn then return nil end
    local ok, start, duration = pcall(GetItemCooldownFn, SATCHEL_ID)
    if not ok or type(start) ~= "number" or type(duration) ~= "number" then return nil end
    if IsSecret(start) or IsSecret(duration) then return nil end
    return start, duration
end

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

local function SatchelSpellID()
    if not GetItemSpellFn then return nil end
    local ok, _, spellID = pcall(GetItemSpellFn, SATCHEL_ID)
    if ok then return spellID end
end

---------------------------------------------------------------------------
-- Watching bags for potions
---------------------------------------------------------------------------

local function ScanBags()
    local now = GetTime()
    local busy = IsBusy()

    for itemID, key in pairs(OUTCOME_ITEMS) do
        local c = Count(itemID)
        local before = counts[itemID]
        if before and c > before then
            if busy then
                Debug(key .. " +" .. (c - before) .. " ignored (vendor/bank/mail open)")
            else
                table.insert(recentGains, { key = key, time = now })
                Debug(key .. " +" .. (c - before))
            end
        end
        counts[itemID] = c
    end

    Resolve()
end

local function SnapshotBags()
    for itemID in pairs(OUTCOME_ITEMS) do
        counts[itemID] = Count(itemID)
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local function SafeRegister(event)
    pcall(frame.RegisterEvent, frame, event)
end

SafeRegister("ADDON_LOADED")
SafeRegister("PLAYER_ENTERING_WORLD")
SafeRegister("BAG_UPDATE_DELAYED")
SafeRegister("BAG_UPDATE_COOLDOWN")
SafeRegister("SPELL_UPDATE_COOLDOWN")
SafeRegister("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
SafeRegister("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
pcall(frame.RegisterUnitEvent, frame, "UNIT_HEALTH", "player")
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player")

-- Older-style open/close events, in case the interaction manager misses any.
local CLASSIC_FRAME_EVENTS = {
    MERCHANT_SHOW = "merchant", MERCHANT_CLOSED = "merchant",
    BANKFRAME_OPENED = "bank", BANKFRAME_CLOSED = "bank",
    MAIL_SHOW = "mail", MAIL_CLOSED = "mail",
    TRADE_SHOW = "trade", TRADE_CLOSED = "trade",
    GUILDBANKFRAME_OPENED = "guildbank", GUILDBANKFRAME_CLOSED = "guildbank",
    AUCTION_HOUSE_SHOW = "auction", AUCTION_HOUSE_CLOSED = "auction",
}
for event in pairs(CLASSIC_FRAME_EVENTS) do SafeRegister(event) end

local OPEN_EVENTS = {
    MERCHANT_SHOW = true, BANKFRAME_OPENED = true, MAIL_SHOW = true,
    TRADE_SHOW = true, GUILDBANKFRAME_OPENED = true, AUCTION_HOUSE_SHOW = true,
}

-- Interaction windows where potions can arrive without the satchel.
local TRANSFER_INTERACTIONS = {}
if Enum and Enum.PlayerInteractionType then
    for _, name in ipairs({
        "TradePartner", "Merchant", "Banker", "MailInfo", "GuildBanker",
        "Auctioneer", "AccountBanker", "CharacterBanker", "VoidStorageBanker",
    }) do
        local value = Enum.PlayerInteractionType[name]
        if value ~= nil then TRANSFER_INTERACTIONS[value] = true end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "Outch" then InitDB() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        wipe(openFrames)
        lastHealth = ReadHealth()
        SnapshotBags()
        -- Don't count a cooldown that was already running when you logged in.
        local start, duration = ReadCooldown()
        if start and start > 0 and duration >= MIN_COOLDOWN then
            lastCooldownStart = start
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        ScanBags()

    elseif event == "BAG_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" then
        CheckCooldown()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        if IsSecret(spellID) then return end
        local satchelSpell = SatchelSpellID()
        if satchelSpell and spellID == satchelSpell then
            MarkUse("spell cast")
        end

    elseif event == "UNIT_HEALTH" then
        OnHealthChanged()

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local kind = ...
        if TRANSFER_INTERACTIONS[kind] then openFrames["pim" .. kind] = true end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local kind = ...
        if kind ~= nil then openFrames["pim" .. tostring(kind)] = nil end

    elseif CLASSIC_FRAME_EVENTS[event] then
        openFrames[CLASSIC_FRAME_EVENTS[event]] = OPEN_EVENTS[event] or nil
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
            local start, duration = ReadCooldown()
            Debug("Satchel cooldown readable: " .. (start and "yes" or "no")
                .. ", satchel spell: " .. tostring(SatchelSpellID())
                .. ", health readable: " .. (ReadHealth() and "yes" or "no"))
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
