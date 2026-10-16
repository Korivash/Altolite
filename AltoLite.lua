local addonName, addon = ...
local eventFrame = CreateFrame("Frame")
local defaults = { columns = { name = true, level = true, itemLevel = true, rating = true, keystone = true, vault = true, gold = true, seen = true }, currencies = {}, sortKey = "name", sortAscending = true, realmFilter = "All realms", width = 960, height = 480, scale = 1, lastTab = "Overview", minimap = { hide = false, angle = 220 }, display = { showRealm = true }, appearance = { accent = { 0.25, 0.72, 0.95, 1 }, background = { 0.035, 0.045, 0.06, 0.98 }, header = { 0.10, 0.15, 0.21, 1 }, stripe = { 0.14, 0.17, 0.21, 0.18 }, hover = { 0.25, 0.72, 0.95, 0.18 }, text = { 0.9, 0.92, 0.95, 1 }, borderColor = { 0.24, 0.30, 0.37, 1 }, border = 1, fontSize = 12, rowHeight = 24, classNames = true, summary = true, compact = false }, accent = { 0.25, 0.72, 0.95 }, weeklyQuestIDs = {} }
local columnOrder = { "name", "level", "itemLevel", "rating", "keystone", "vault", "gold", "seen" }
local columnLabels = { name = "Character", level = "Level", itemLevel = "Item level", rating = "M+", keystone = "Keystone", vault = "Vault", gold = "Gold", seen = "Last seen" }
local columnWidths = { name = 190, level = 60, itemLevel = 88, rating = 58, keystone = 150, vault = 132, gold = 105, seen = 130 }
local mainFrame, optionsFrame, minimapButton
local checkWeeklyReset
local refreshPending, refreshQueued, timePlayedRequested = false, false, false
local playerEnteredWorld = false
local activeTab = "Overview"
local tabs = { "Overview", "Mythic+", "Great Vault", "Currencies", "Lockouts", "Weekly" }
local professionIndexes = {}
local weeklyCategories = { "raid", "dungeon", "world" }
local timePlayedFilterInstalled = false
local appearance
local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end
local function widgetCall(widget, method, ...)
    local fn = widget and widget[method]
    if type(fn) == "function" then return safeCall(fn, widget, ...) end
end
local function copyDefaults(source, target)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            copyDefaults(value, target[key])
        elseif target[key] == nil then target[key] = value end
    end
end
local function now() return time and time() or 0 end
local function resetSeconds() return safeCall(C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset) end
local function getResetBoundary()
    local seconds = resetSeconds()
    if type(seconds) == "number" then return now() - (604800 - seconds) end
end
local function normalizeRealmValue(realm)
    if type(realm) ~= "string" or realm == "" then return nil end
    return realm:gsub("[%s%-']", "")
end
local function normalizedRealm(realm)
    local liveRealm = type(GetRealmName) == "function" and safeCall(GetRealmName)
    if (not realm or realm == "" or realm == liveRealm) and type(GetNormalizedRealmName) == "function" then
        local value = safeCall(GetNormalizedRealmName)
        if type(value) == "string" and value ~= "" then return value end
    end
    realm = realm or liveRealm
    return normalizeRealmValue(realm)
end
local function canonicalRealm(realm)
    local value = normalizedRealm(realm)
    if type(value) ~= "string" or value == "" then return nil end
    return normalizeRealmValue(value)
end
local function charKey(name, realm)
    local normalized = canonicalRealm(realm)
    if type(name) ~= "string" or name == "" or not normalized or normalized == "" then return nil end
    return name .. "-" .. normalized
end
local function classColor(classFile)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color then return color.r, color.g, color.b end
    return 0.9, 0.9, 0.92
end
local function className(classFile) return classFile and _G[classFile] or classFile or "Unknown" end
local function readKeystone()
    local mapID = safeCall(C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID)
    local level = safeCall(C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel)
    local mapName = mapID and safeCall(C_ChallengeMode and C_ChallengeMode.GetMapUIInfo, mapID)
    if mapName and level then return "+" .. tostring(level) .. " " .. tostring(mapName), tonumber(level) end
    return mapID and tostring(mapID) or "None", tonumber(level)
end
local function readVault()
    local result = { raid = { 0, 0 }, dungeon = { 0, 0 }, world = { 0, 0 } }
    local activities = safeCall(C_WeeklyRewards and C_WeeklyRewards.GetActivities)
    if type(activities) ~= "table" then return result end
    for _, activity in ipairs(activities) do
        local category = activity.type or activity.activityType
        local target
        local types = Enum and Enum.WeeklyRewardChestThresholdType
        if types then
            if category == types.Raid then target = result.raid elseif category == types.MythicPlus then target = result.dungeon elseif category == types.World then target = result.world end
        end
        local text = tostring(category or ""):lower()
        if not target then
            if text:find("raid", 1, true) then target = result.raid elseif text:find("dungeon", 1, true) or text:find("mythic", 1, true) then target = result.dungeon elseif text:find("world", 1, true) then target = result.world end
        end
        if target then target[1] = math.max(target[1], tonumber(activity.progress) or 0); target[2] = math.max(target[2], tonumber(activity.threshold) or 0) end
    end
    return result
end
local function captureMythicMaps(snapshot)
    local mapIDs = safeCall(C_ChallengeMode and C_ChallengeMode.GetMapTable)
    if type(mapIDs) ~= "table" then return end
    local runs = safeCall(C_MythicPlus and C_MythicPlus.GetRunHistory, true, true)
    local bestWeek, bestWeekLevel
    if type(runs) == "table" then
        for _, run in ipairs(runs) do
            local level = tonumber(run.level or run.mythicLevel) or 0
            if not bestWeekLevel or level > bestWeekLevel then bestWeekLevel, bestWeek = level, run end
        end
    end
    snapshot.bestRunWeek = bestWeek and ((bestWeek.mapName or bestWeek.name or "Dungeon") .. " +" .. tostring(bestWeekLevel)) or nil
    for _, mapID in ipairs(mapIDs) do
        local mapName = safeCall(C_ChallengeMode and C_ChallengeMode.GetMapUIInfo, mapID)
        local best = safeCall(C_MythicPlus and C_MythicPlus.GetSeasonBestForMap, mapID)
        local bestLevel = type(best) == "table" and (best.bestLevel or best.level or best.bestRunLevel) or type(best) == "number" and best
        local weekly = safeCall(C_MythicPlus and C_MythicPlus.GetWeeklyBestForMap, mapID)
        local weeklyLevel = type(weekly) == "table" and (weekly.bestLevel or weekly.level or weekly.bestRunLevel) or type(weekly) == "number" and weekly
        local map = snapshot.mythicMaps[mapID] or {}
        map.name, map.level, map.weekLevel = mapName or tostring(mapID), tonumber(bestLevel) or 0, tonumber(weeklyLevel) or 0
        snapshot.mythicMaps[mapID] = map
    end
end
local function readLockouts()
    local rows = {}
    if not GetNumSavedInstances or not GetSavedInstanceInfo then return rows end
    for index = 1, tonumber(safeCall(GetNumSavedInstances)) or 0 do
        local ok, name, _, reset, difficulty, locked, _, _, _, _, numEncounters, encounterProgress = pcall(GetSavedInstanceInfo, index)
        if ok and locked and (tonumber(reset) or 0) > 0 then rows[#rows + 1] = { name = name or "Raid", reset = tonumber(reset) or 0, difficulty = difficulty, progress = tostring(encounterProgress or 0) .. "/" .. tostring(numEncounters or 0) } end
    end
    return rows
end
local function captureCurrencies()
    local saved, chosen = {}, AltoLiteDB.settings.currencies or {}
    for currencyID, enabled in pairs(chosen) do
        if enabled then
            local info = safeCall(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo, tonumber(currencyID) or currencyID)
            if type(info) == "table" then saved[tostring(currencyID)] = { name = info.name or tostring(currencyID), quantity = tonumber(info.quantity) or 0, icon = info.iconFileID } end
        end
    end
    return saved
end
local function currentCharacter(saveDetails)
    if not playerEnteredWorld or not AltoLiteDB or not AltoLiteDB.characters then return end
    local name, realm
    if UnitFullName then name, realm = UnitFullName("player") end
    if not name and UnitName then name = UnitName("player") end
    if not realm or realm == "" then realm = GetRealmName and GetRealmName() end
    local id = charKey(name, realm)
    if not id then return end
    local classFile
    if UnitClass then local _, value = UnitClass("player"); classFile = value end
    local level = UnitLevel and UnitLevel("player") or 0
    local itemLevel = GetAverageItemLevel and GetAverageItemLevel() or 0
    local rating = safeCall(C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore) or 0
    local key, keyLevel = readKeystone()
    local snapshot = AltoLiteDB.characters[id] or {}
    snapshot.name, snapshot.realm, snapshot.class = name, realm or normalizedRealm(), classFile
    snapshot.guid = type(UnitGUID) == "function" and safeCall(UnitGUID, "player") or snapshot.guid
    snapshot.level, snapshot.itemLevel, snapshot.rating = tonumber(level) or 0, tonumber(itemLevel) or 0, tonumber(rating) or 0
    snapshot.gold, snapshot.keystone, snapshot.keystoneLevel = GetMoney and (tonumber(GetMoney()) or 0) or 0, key, keyLevel
    snapshot.vault = readVault()
    if saveDetails then snapshot.lockouts, snapshot.currencies = readLockouts(), captureCurrencies() end
    snapshot.lastSeen = now()
    snapshot.resetBoundary = getResetBoundary() or snapshot.resetBoundary
    snapshot.keyBoundary, snapshot.vaultBoundary, snapshot.lockoutBoundary = snapshot.resetBoundary, snapshot.resetBoundary, snapshot.resetBoundary
    snapshot.stale = snapshot.stale or { key = false, vault = false, lockouts = false }
    snapshot.equipment = snapshot.equipment or {}
    snapshot.professions = snapshot.professions or {}
    snapshot.mythicMaps = snapshot.mythicMaps or {}
    snapshot.renown = snapshot.renown or {}
    if saveDetails and UnitLevel and UnitLevel("player") < (GetMaxLevelForPlayerExpansion and (safeCall(GetMaxLevelForPlayerExpansion) or 80) or 80) then snapshot.restedXP = GetXPExhaustion and GetXPExhaustion() or 0 end
    if saveDetails then captureMythicMaps(snapshot) end
    if saveDetails then for slot = 1, 19 do
        local link = safeCall(GetInventoryItemLink, "player", slot)
        snapshot.equipment[slot] = link and safeCall(C_Item and C_Item.GetDetailedItemLevelInfo, link) or nil
    end end
    for key in pairs(snapshot.professions) do snapshot.professions[key] = nil end
    if saveDetails and type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        local p1, p2, p3, p4, p5, p6, p7, p8 = safeCall(GetProfessions)
        wipe(professionIndexes)
        professionIndexes[1], professionIndexes[2], professionIndexes[3], professionIndexes[4] = p1, p2, p3, p4
        professionIndexes[5], professionIndexes[6], professionIndexes[7], professionIndexes[8] = p5, p6, p7, p8
        for _, index in ipairs(professionIndexes) do
            if index then local name, _, rank, maxRank = safeCall(GetProfessionInfo, index); if name then snapshot.professions[#snapshot.professions + 1] = { name = name, rank = rank or 0, max = maxRank or 0 } end end
        end
    end
    for key in pairs(snapshot.renown) do snapshot.renown[key] = nil end
    local factions = saveDetails and safeCall(C_MajorFactions and C_MajorFactions.GetMajorFactionIDs)
    if type(factions) == "table" then for _, id in ipairs(factions) do local info = safeCall(C_MajorFactions and C_MajorFactions.GetMajorFactionData, id); if info then snapshot.renown[#snapshot.renown + 1] = { name = info.name or tostring(id), level = info.renownLevel or 0 } end end end
    snapshot.weekly = snapshot.weekly or { quests = {} }
    snapshot.weekly.quests = snapshot.weekly.quests or {}
    if saveDetails then for _, questID in ipairs(AltoLiteDB.settings.weeklyQuestIDs or {}) do snapshot.weekly.quests[questID] = safeCall(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, questID) == true end end
    AltoLiteDB.characters[id] = snapshot
end
local function resetCurrencyChoices()
    local list, seen = {}, {}
    local size = safeCall(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) or 0
    for index = 1, tonumber(size) or 0 do
        local info = safeCall(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo, index)
        if type(info) == "table" and info.currencyID and info.name then list[#list + 1] = { id = info.currencyID, name = info.name, icon = info.iconFileID } end
    end
    for _, id in ipairs({ 1813, 2245, 2003, 2032, 1906 }) do
        local info = safeCall(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo, id)
        if type(info) == "table" and info.name then list[#list + 1] = { id = id, name = info.name, icon = info.iconFileID } end
    end
    local unique = {}
    for _, item in ipairs(list) do local id = tostring(item.id); if not seen[id] then seen[id] = true; unique[#unique + 1] = item end end
    table.sort(unique, function(a, b) return a.name < b.name end)
    return unique
end
local function formatDate(value)
    if not value or value == 0 then return "Unknown" end
    local diff = math.max(0, now() - value)
    if diff < 60 then return "Just now" end
    if diff < 3600 then return math.floor(diff / 60) .. " minutes ago" end
    if diff < 86400 then return math.floor(diff / 3600) .. " hours ago" end
    return math.floor(diff / 86400) .. " days ago"
end
local function goldString(amount)
    if GetCoinTextureString then return GetCoinTextureString(tonumber(amount) or 0) end
    return tostring(math.floor((tonumber(amount) or 0) / 10000)) .. "g"
end
local function detailTooltip(character)
    if not GameTooltip then return end
    GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    local r, g, b = classColor(character.class)
    GameTooltip:AddLine((character.name or "Unknown") .. " - " .. (character.realm or "Unknown"), r, g, b)
    GameTooltip:AddDoubleLine("Class", className(character.class), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Level / item level", tostring(character.level or 0) .. " / " .. string.format("%.1f", tonumber(character.itemLevel) or 0), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Mythic+ score", tostring(character.rating or 0), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Keystone", character.stale and character.stale.key and "Reset since last login" or character.keystone or "None", 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddLine("Dungeon bests", 1, 0.82, 0)
    for _, map in pairs(character.mythicMaps or {}) do GameTooltip:AddDoubleLine(map.name or "Dungeon", "Season +" .. tostring(map.level or 0) .. "  Week +" .. tostring(map.weekLevel or 0), 0.8, 0.8, 0.8, 1, 1, 1) end
    GameTooltip:AddLine("Equipment slots", 1, 0.82, 0)
    local lowest = math.huge
    for _, level in pairs(character.equipment or {}) do if level then lowest = math.min(lowest, level) end end
    for slot, level in pairs(character.equipment or {}) do if level then GameTooltip:AddDoubleLine("Slot " .. tostring(slot), tostring(level) .. (level == lowest and "  Upgrade first" or ""), level == lowest and 1 or 0.8, level == lowest and 0.55 or 0.8, 0.3, 1, 1, 1) end end
    for _, profession in ipairs(character.professions or {}) do GameTooltip:AddDoubleLine(profession.name, tostring(profession.rank) .. "/" .. tostring(profession.max), 0.8, 0.8, 0.8, 1, 1, 1) end
    for _, faction in ipairs(character.renown or {}) do GameTooltip:AddDoubleLine(faction.name, "Renown " .. tostring(faction.level), 0.8, 0.8, 0.8, 1, 1, 1) end
    GameTooltip:AddLine("Played: " .. tostring(character.playedTotal or "Unknown"), 0.8, 0.8, 0.8)
    if character.restedXP then GameTooltip:AddLine("Rested XP: " .. tostring(character.restedXP), 0.6, 0.8, 1) end
    GameTooltip:AddLine("Great Vault", 1, 0.82, 0)
    for _, key in ipairs({ "raid", "dungeon", "world" }) do local pair = (character.vault or {})[key] or { 0, 0 }; GameTooltip:AddDoubleLine(key, tostring(pair[1] or 0) .. "/" .. tostring(pair[2] or 0), 0.8, 0.8, 0.8, 1, 1, 1) end
    GameTooltip:AddLine("Raid lockouts", 1, 0.82, 0)
    for _, lockout in ipairs(character.lockouts or {}) do GameTooltip:AddLine(tostring(lockout.name) .. " " .. tostring(lockout.progress), 0.8, 0.8, 0.8) end
    GameTooltip:AddLine("Gold: " .. goldString(character.gold), 0.8, 0.8, 0.8)
    for _, currency in pairs(character.currencies or {}) do GameTooltip:AddDoubleLine(currency.name or "Currency", tostring(currency.quantity or 0), 0.8, 0.8, 0.8, 1, 1, 1) end
    GameTooltip:AddLine("Last seen: " .. formatDate(character.lastSeen), 0.65, 0.65, 0.65)
    GameTooltip:Show()
end
local function queueRefresh()
    if InCombatLockdown and InCombatLockdown() then refreshPending = true; return end
    if refreshQueued then return end
    refreshQueued = true
    if C_Timer and C_Timer.After then C_Timer.After(0.15, function() refreshQueued = false; if mainFrame and mainFrame:IsShown() then mainFrame:Refresh() end end) elseif mainFrame and mainFrame:IsShown() then refreshQueued = false; mainFrame:Refresh() end
end
local function backdrop(frame, color, border)
    if not frame.SetBackdrop then return end
    local edge = appearance and appearance().border or 1
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = edge, insets = { left = edge, right = edge, top = edge, bottom = edge } })
    frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end
local function glassBackdrop(frame, color, border)
    if not frame.SetBackdrop then return backdrop(frame, color, border) end
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 8, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end
appearance = function()
    return AltoLiteDB and AltoLiteDB.settings and AltoLiteDB.settings.appearance or defaults.appearance
end
local function applyAppearance()
    if InCombatLockdown and InCombatLockdown() then refreshPending = true; return end
    local a = appearance()
    if mainFrame then
        widgetCall(mainFrame, "SetScale", (AltoLiteDB and AltoLiteDB.settings and AltoLiteDB.settings.scale) or 1)
        glassBackdrop(mainFrame, a.background, a.border == 0 and { 0, 0, 0, 0 } or a.accent)
        if mainFrame.glassWash and type(mainFrame.glassWash.SetGradient) == "function" and type(CreateColor) == "function" then
            safeCall(mainFrame.glassWash.SetGradient, mainFrame.glassWash, "VERTICAL", CreateColor(a.accent[1], a.accent[2], a.accent[3], 0.12), CreateColor(a.accent[1], a.accent[2], a.accent[3], 0))
        end
        if mainFrame.header then backdrop(mainFrame.header, a.header, a.header) end
        if mainFrame.content and mainFrame.content.headerBg then mainFrame.content.headerBg:SetVertexColor(a.header[1], a.header[2], a.header[3], a.header[4] or 1) end
        if mainFrame.statChips then for _, chip in ipairs(mainFrame.statChips) do chip:SetShown(a.summary) end end
        if mainFrame.Refresh then mainFrame:Refresh() end
    end
end
local function text(parent, template)
    return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end
local function filteredCharacters()
    local list, query, realmFilter = {}, tostring(mainFrame.search:GetText() or ""):lower(), tostring(AltoLiteDB.settings.realmFilter or "All realms")
    for id, character in pairs(AltoLiteDB.characters) do
        local searchable = (tostring(character.name or "") .. " " .. tostring(character.realm or "")):lower()
        if searchable:find(query, 1, true) and (realmFilter == "All realms" or character.realm == realmFilter) then list[#list + 1] = { id = id, data = character } end
    end
    table.sort(list, function(a, b)
        local playerName, playerRealm
        if UnitFullName then playerName, playerRealm = UnitFullName("player") elseif UnitName then playerName = UnitName("player") end
        playerRealm = playerRealm or (GetRealmName and GetRealmName())
        local currentID = charKey(playerName, playerRealm)
        if a.id == currentID and b.id ~= currentID then return true end
        if b.id == currentID and a.id ~= currentID then return false end
        local key = AltoLiteDB.settings.sortKey or "name"
        local av, bv = a.data[key], b.data[key]
        if key == "name" then av, bv = tostring(a.data.name), tostring(b.data.name) end
        if type(av) == "number" and type(bv) == "number" and av ~= bv then return AltoLiteDB.settings.sortAscending and av < bv or av > bv end
        av, bv = tostring(av or ""):lower(), tostring(bv or ""):lower()
        if av == bv then return a.id < b.id end
        return AltoLiteDB.settings.sortAscending and av < bv or av > bv
    end)
    return list
end
local function cellText(row, index)
    if not row.cells[index] then row.cells[index] = text(row) end
    return row.cells[index]
end
local function layoutColumns(columns, availableWidth)
    local total = 0
    for _, col in ipairs(columns) do total = total + col[3] end
    local scale = total > availableWidth and availableWidth / total or 1
    local result, x = {}, 0
    for i, col in ipairs(columns) do
        local width = i == #columns and math.max(36, availableWidth - x) or math.max(36, math.floor(col[3] * scale))
        result[#result + 1] = { col[1], col[2], width, x }
        x = x + width
    end
    return result
end
local function resetRowCells(row)
    for _, cell in ipairs(row.cells) do cell:SetText(""); cell:Hide() end
    for _, tip in ipairs(row.tooltipCells or {}) do tip:Hide() end
    if row.edge then row.edge:Hide() end
end
local function createMainFrame()
    if mainFrame or not CreateFrame then return mainFrame end
    local settings = AltoLiteDB and AltoLiteDB.settings or {}
    for _, savedTab in ipairs(tabs) do if savedTab == settings.lastTab then activeTab = savedTab end end
    local frame = CreateFrame("Frame", "AltoLiteFrame", UIParent, "BackdropTemplate")
    mainFrame = frame
    frame:SetSize(math.max(760, settings.width or defaults.width), math.max(430, settings.height or defaults.height))
    if type(frame.SetResizeBounds) == "function" then widgetCall(frame, "SetResizeBounds", 760, 430) else widgetCall(frame, "SetMinResize", 760, 430) end
    widgetCall(frame, "SetScale", settings.scale or 1)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); widgetCall(frame, "SetResizable", true); widgetCall(frame, "SetClampedToScreen", true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); local point, _, relative, x, y = self:GetPoint(1); AltoLiteDB.settings.point = { point, relative, x, y } end)
    glassBackdrop(frame, appearance().background, appearance().accent)
    local wash = frame:CreateTexture(nil, "BACKGROUND", nil, 1); frame.glassWash = wash; wash:SetTexture("Interface\\Buttons\\WHITE8X8"); wash:SetPoint("TOPLEFT", 4, -4); wash:SetPoint("BOTTOMRIGHT", -4, 4)
    local washAccent = appearance().accent
    if type(wash.SetGradient) == "function" and type(CreateColor) == "function" then safeCall(wash.SetGradient, wash, "VERTICAL", CreateColor(washAccent[1], washAccent[2], washAccent[3], 0.12), CreateColor(washAccent[1], washAccent[2], washAccent[3], 0)) else wash:SetVertexColor(washAccent[1], washAccent[2], washAccent[3], 0.04) end
    if AltoLiteDB.settings.point then local p = AltoLiteDB.settings.point; frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate"); frame.header = header; header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1); header:SetHeight(38)
    backdrop(header, appearance().header, appearance().header)
    local icon = header:CreateTexture(nil, "ARTWORK"); icon:SetSize(25, 25); icon:SetPoint("LEFT", 12, 0); icon:SetTexture("Interface\\AddOns\\AltoLite\\icon.png")
    local title = text(header); title:SetPoint("LEFT", icon, "RIGHT", 10, 0); title:SetText("ALTOLITE"); widgetCall(title, "SetFont", "Fonts\\FRIZQT__.TTF", 15, "OUTLINE"); title:SetTextColor(0.93, 0.96, 1)
    local close = CreateFrame("Button", nil, header, "BackdropTemplate"); close:SetSize(24, 24); close:SetPoint("RIGHT", -7, 0); backdrop(close, { 0.10, 0.15, 0.21, 1 }, { 0.24, 0.30, 0.37, 1 }); close.label = text(close); close.label:SetPoint("TOPLEFT"); close.label:SetPoint("BOTTOMRIGHT"); widgetCall(close.label, "SetJustifyH", "CENTER"); close.label:SetText("X"); close:SetScript("OnEnter", function(self) backdrop(self, { 0.35, 0.12, 0.14, 1 }, { 0.65, 0.25, 0.28, 1 }) end); close:SetScript("OnLeave", function(self) backdrop(self, { 0.10, 0.15, 0.21, 1 }, { 0.24, 0.30, 0.37, 1 }) end); close:SetScript("OnClick", function() frame:Hide() end)
    frame.summary = text(frame, "GameFontHighlightSmall"); frame.summary:Hide(); frame.statChips = {}
    local chipLabels = { "GOLD", "CHARACTERS", "BEST ILVL", "BEST M+" }
    for i, label in ipairs(chipLabels) do
        local chip = CreateFrame("Frame", nil, frame, "BackdropTemplate"); chip:SetSize(i == 2 and 112 or 104, 30); chip:SetPoint("TOPLEFT", 14 + (i - 1) * 112, -43)
        backdrop(chip, { 0.07, 0.10, 0.14, 0.95 }, { 0.13, 0.20, 0.28, 1 })
        chip.caption = text(chip); chip.caption:SetPoint("TOPLEFT", 8, -3); chip.caption:SetText(label); widgetCall(chip.caption, "SetFont", "Fonts\\FRIZQT__.TTF", 8, "OUTLINE"); chip.caption:SetTextColor(0.48, 0.72, 0.86)
        chip.value = text(chip); chip.value:SetPoint("BOTTOMLEFT", 8, 3); chip.value:SetText("—"); widgetCall(chip.value, "SetFont", "Fonts\\FRIZQT__.TTF", 11, "OUTLINE"); chip.value:SetTextColor(0.92, 0.95, 1)
        frame.statChips[i] = chip
    end
    frame.timer = text(frame, "GameFontHighlightSmall"); frame.timer:SetPoint("TOPRIGHT", -205, -55); frame.timer:SetTextColor(0.62, 0.76, 0.88)
    frame.search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate"); frame.search:SetSize(180, 24); frame.search:SetPoint("TOPRIGHT", -18, -94); widgetCall(frame.search, "SetAutoFocus", false); widgetCall(frame.search, "SetTextInsets", 9, 8, 0, 0); frame.search:SetScript("OnTextChanged", function() frame:Refresh() end)
    if UIDropDownMenuTemplate and UIDropDownMenu_Initialize and UIDropDownMenu_CreateInfo and UIDropDownMenu_AddButton and ToggleDropDownMenu then
        frame.realmDropdown = CreateFrame("Frame", "AltoLiteRealmDropdown", frame, "UIDropDownMenuTemplate")
        frame.realmDropdown:SetPoint("TOPRIGHT", frame.search, "TOPLEFT", -8, 4)
        safeCall(UIDropDownMenu_SetWidth, frame.realmDropdown, 130)
        safeCall(UIDropDownMenu_SetText, frame.realmDropdown, AltoLiteDB.settings.realmFilter or "All realms")
        UIDropDownMenu_Initialize(frame.realmDropdown, function(_, level)
            local choices, seen = { "All realms" }, { ["All realms"] = true }
            for _, character in pairs(AltoLiteDB.characters) do if character.realm and not seen[character.realm] then seen[character.realm] = true; choices[#choices + 1] = character.realm end end
            table.sort(choices)
            for _, realmName in ipairs(choices) do
                local info = UIDropDownMenu_CreateInfo(); info.text = realmName; info.checked = AltoLiteDB.settings.realmFilter == realmName
                info.func = function() AltoLiteDB.settings.realmFilter = realmName; safeCall(UIDropDownMenu_SetText, frame.realmDropdown, realmName); frame:Refresh() end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end
    local tabBar = CreateFrame("Frame", nil, frame); tabBar:SetPoint("TOPLEFT", 14, -126); tabBar:SetSize(540, 28); frame.tabButtons = {}
    for i, name in ipairs(tabs) do
        local button = CreateFrame("Button", nil, tabBar, "BackdropTemplate"); button:SetSize(84, 26); button:SetPoint("LEFT", (i - 1) * 86, 0); backdrop(button, { 0.07, 0.09, 0.12, 1 }, { 0.20, 0.25, 0.31, 1 })
        button.label = text(button); button.label:SetPoint("TOPLEFT"); button.label:SetPoint("BOTTOMRIGHT"); widgetCall(button.label, "SetJustifyH", "CENTER"); button.label:SetText(name)
        button:SetScript("OnLeave", function(self) if tabs[i] ~= activeTab then backdrop(self, { 0.055, 0.07, 0.095, 1 }, { 0.14, 0.19, 0.25, 1 }) end end)
        button:SetScript("OnClick", function() activeTab = name; AltoLiteDB.settings.lastTab = name; frame:Refresh(true) end); frame.tabButtons[i] = button
    end
    for i = 1, #tabs do
        local button = frame.tabButtons[i]
        button:SetScript("OnEnter", function(self) if tabs[i] ~= activeTab then backdrop(self, { appearance().accent[1] * .16, appearance().accent[2] * .16, appearance().accent[3] * .16, 1 }, appearance().accent) end end)
    end
    frame.content = CreateFrame("Frame", nil, frame); frame.content:SetPoint("TOPLEFT", 14, -158); frame.content:SetPoint("BOTTOMRIGHT", -14, 14)
    frame.content.headerBg = frame.content:CreateTexture(nil, "BACKGROUND"); frame.content.headerBg:SetTexture("Interface\\Buttons\\WHITE8X8"); frame.content.headerBg:SetVertexColor(appearance().header[1], appearance().header[2], appearance().header[3], appearance().header[4] or 1); frame.content.headerBg:SetPoint("TOPLEFT", 0, 0); frame.content.headerBg:SetPoint("TOPRIGHT", 0, 0); frame.content.headerBg:SetHeight(24)
    frame.empty = text(frame.content, "GameFontHighlight"); frame.empty:SetPoint("TOP", 0, -64); frame.empty:SetText("No characters yet. Your character will appear after entering the world.")
    frame.rows, frame.headers = {}, {}
    frame.Refresh = function(self, animate)
        if InCombatLockdown and InCombatLockdown() then refreshPending = true; return end
        local chars, all, gold, bestIlvl, bestScore, realms = filteredCharacters(), {}, 0, 0, 0, { ["All realms"] = true }
        for _, char in pairs(AltoLiteDB.characters) do gold = gold + (tonumber(char.gold) or 0); bestIlvl = math.max(bestIlvl, tonumber(char.itemLevel) or 0); bestScore = math.max(bestScore, tonumber(char.rating) or 0); realms[char.realm or "Unknown"] = true end
        local charCount = 0; for _ in pairs(AltoLiteDB.characters) do charCount = charCount + 1 end
        self.statChips[1].value:SetText(goldString(gold)); self.statChips[2].value:SetText(tostring(charCount)); self.statChips[3].value:SetText(string.format("%.1f", bestIlvl)); self.statChips[4].value:SetText(tostring(bestScore))
        for i, name in ipairs(tabs) do
            local active = name == activeTab
            frame.tabButtons[i].label:SetText(active and "|cff9de1ff" .. name .. "|r" or name)
            backdrop(frame.tabButtons[i], active and { appearance().accent[1] * 0.28, appearance().accent[2] * 0.28, appearance().accent[3] * 0.28, 1 } or { 0.055, 0.07, 0.095, 1 }, active and appearance().accent or { 0.14, 0.19, 0.25, 1 })
        end
        for _, h in ipairs(self.headers) do if h.label then h.label:SetText(""); h.label:Hide() end; h:Hide() end
        for _, row in ipairs(self.rows) do row:Hide(); resetRowCells(row) end
        local function addHeader(label, x, width, key)
            local headerIndex = #self.headers + 1
            local h = self.headers[headerIndex]
            if not h then h = CreateFrame("Button", nil, self.content); self.headers[headerIndex] = h end
            h:ClearAllPoints(); h:SetPoint("TOPLEFT", x, 0); h:SetSize(width, 24)
            if not h.label then h.label = text(h); h.label:SetPoint("TOPLEFT", 0, 0); h.label:SetPoint("BOTTOMRIGHT", -12, 0); widgetCall(h.label, "SetJustifyH", "LEFT"); h.sortArrow = h:CreateTexture(nil, "OVERLAY"); h.sortArrow:SetSize(8, 8); h.sortArrow:SetPoint("RIGHT", -2, 0); h.sortArrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up") end
            h.label:Show(); h.label:SetWidth(width - 8)
            h.label:SetText(label:upper()); widgetCall(h.label, "SetFont", "Fonts\\FRIZQT__.TTF", 10, "OUTLINE"); widgetCall(h.label, "SetWordWrap", false); widgetCall(h.label, "SetMaxLines", 1); widgetCall(h.label, "SetJustifyH", "LEFT")
            if key and AltoLiteDB.settings.sortKey == key then
                if AltoLiteDB.settings.sortAscending then h.sortArrow:SetTexCoord(0, 1, 0, 1) else h.sortArrow:SetTexCoord(0, 1, 1, 0) end
                h.sortArrow:Show()
            else h.sortArrow:Hide() end
            h:SetScript("OnClick", function() if key then if AltoLiteDB.settings.sortKey == key then AltoLiteDB.settings.sortAscending = not AltoLiteDB.settings.sortAscending else AltoLiteDB.settings.sortKey = key; AltoLiteDB.settings.sortAscending = true end; self:Refresh() end end); h:Show()
        end
        local columns = {}
        if activeTab == "Overview" then for _, key in ipairs(columnOrder) do if AltoLiteDB.settings.columns[key] then columns[#columns + 1] = { key, columnLabels[key], columnWidths[key] } end end
        elseif activeTab == "Mythic+" then columns = { { "name", "Character", 200 }, { "rating", "Score", 85 }, { "keystone", "Keystone", 190 }, { "bestRun", "Best run this week", 190 } }
        elseif activeTab == "Great Vault" then columns = { { "name", "Character", 200 }, { "raid", "Raid", 150 }, { "dungeon", "Dungeons", 170 }, { "world", "World", 150 } }
        elseif activeTab == "Currencies" then columns = { { "name", "Character", 200 } }; local seen = {}; for _, entry in ipairs(chars) do for id, c in pairs(entry.data.currencies or {}) do if not seen[id] then seen[id] = true; columns[#columns + 1] = { "currency:" .. id, (c.icon and "|T" .. c.icon .. ":14|t " or "") .. (c.name or id), 120 } end end end
        elseif activeTab == "Weekly" then columns = { { "name", "Character", 200 }, { "weekly", "Vault and weekly quests", 500 } }
        else columns = { { "name", "Character", 200 }, { "lockouts", "Raid lockouts", 400 } } end
        local contentWidth = self.content:GetWidth()
        if not contentWidth or contentWidth < 100 then contentWidth = (self:GetWidth() or defaults.width) - 28 end
        columns = layoutColumns(columns, contentWidth)
        local x = 0
        for _, col in ipairs(columns) do addHeader(col[2], x, col[3], col[1]); x = x + col[3] end
        if #chars == 0 then
            local message = activeTab == "Lockouts" and "No lockouts this week" or activeTab == "Currencies" and "No tracked currencies yet" or "No characters match this view"
            self.empty:SetText(message)
        else self.empty:SetText("No characters yet. Your character will appear after entering the world.") end
        self.empty:SetShown(#chars == 0)
        for index, entry in ipairs(chars) do
            local row = self.rows[index]
            if not row then row = CreateFrame("Button", nil, self.content, "BackdropTemplate"); row.cells = {}; row:SetScript("OnEnter", function(self) detailTooltip(self.character); local ap = appearance(); backdrop(self, ap.hover, ap.border == 0 and { 0, 0, 0, 0 } or ap.borderColor); self.edge:Show() end); row:SetScript("OnLeave", function(self) if GameTooltip then GameTooltip:Hide() end; self.activeValueTip = nil; local ap = appearance(); backdrop(self, self.rowIndex % 2 == 0 and ap.stripe or { 0, 0, 0, 0 }, ap.border == 0 and { 0, 0, 0, 0 } or ap.borderColor); self.edge:Hide() end); row:SetScript("OnUpdate", function(self)
                if not self:IsMouseOver() or not GetCursorPosition then return end
                local scale = self:GetEffectiveScale(); local cursorX = GetCursorPosition() / scale
                local left = self:GetLeft() or 0; local cellIndex
                for i, tipCell in ipairs(self.tooltipCells or {}) do
                    local tipLeft = left + (((self.columns or {})[i] and (self.columns or {})[i][4]) or 0)
                    if cursorX >= tipLeft and cursorX < tipLeft + (((self.columns or {})[i] and (self.columns or {})[i][3]) or 0) then cellIndex = i; break end
                end
                local tipCell = cellIndex and self.tooltipCells[cellIndex]
                if tipCell and tipCell.truncated and GameTooltip then
                    if self.activeValueTip ~= tipCell then self.fullValue = tipCell.fullValue; GameTooltip:SetOwner(self, "ANCHOR_CURSOR"); GameTooltip:ClearLines(); GameTooltip:AddLine(self.fullValue, 1, 1, 1, true); GameTooltip:Show(); self.activeValueTip = tipCell end
                elseif self.activeValueTip then self.activeValueTip = nil; detailTooltip(self.character) end
            end); row.cells = {}; row.edge = row:CreateTexture(nil, "OVERLAY"); row.edge:SetTexture("Interface\\Buttons\\WHITE8X8"); row.edge:SetPoint("TOPLEFT"); row.edge:SetPoint("BOTTOMLEFT"); row.edge:SetWidth(3); row.edge:Hide(); self.rows[index] = row end
            local ap = appearance(); local rowHeight = ap.compact and math.min(ap.rowHeight, 20) or ap.rowHeight; row.character = entry.data; row.rowIndex = index; row:SetHeight(rowHeight); row:SetPoint("TOPLEFT", 0, -24 - (index - 1) * rowHeight); row:SetPoint("RIGHT", 0, 0)
            backdrop(row, index % 2 == 0 and ap.stripe or { 0, 0, 0, 0 }, ap.border == 0 and { 0, 0, 0, 0 } or ap.borderColor); row.edge:SetVertexColor(unpack(ap.accent))
            row.tooltipCells = row.tooltipCells or {}; row.columns = columns; row.activeValueTip = nil
            for cellIndex, col in ipairs(columns) do
                local key, value = col[1], ""
            if key == "name" then
                    local playerName, playerRealm
                    if UnitFullName then playerName, playerRealm = UnitFullName("player") elseif UnitName then playerName = UnitName("player") end
                    playerRealm = playerRealm or (GetRealmName and GetRealmName())
                    local player = entry.id == charKey(playerName, playerRealm)
                    local classCoords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[entry.data.class]
                    local classIcon = classCoords and "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:18:18:0:0:256:256:" .. table.concat(classCoords, ":") .. "|t " or ""
                    local realm = AltoLiteDB.settings.display.showRealm and ("  |cff8996a5" .. tostring(entry.data.realm or "") .. "|r") or ""
                    value = (player and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t " or "") .. classIcon .. tostring(entry.data.name or "Unknown") .. realm
                elseif key == "level" then value = tostring(entry.data.level or 0)
                elseif key == "itemLevel" then local il = tonumber(entry.data.itemLevel) or 0; local c = il >= bestIlvl and "|cffffa64d" or il >= bestIlvl * .95 and "|cffa56bff" or il >= bestIlvl * .85 and "|cff4c9fff" or il >= bestIlvl * .7 and "|cff56d277" or "|cffaaaaaa"; value = c .. string.format("%.1f", il) .. "|r"
                elseif key == "rating" then value = tostring(entry.data.rating or 0); local color = safeCall(C_ChallengeMode and C_ChallengeMode.GetDungeonScoreRarityColor, tonumber(entry.data.rating) or 0); if color and color.GenerateHexColor then value = "|c" .. color:GenerateHexColor() .. value .. "|r" end
                elseif key == "keystone" then value = entry.data.stale and entry.data.stale.key and "Reset since reset" or entry.data.keystone or "None"
                elseif key == "gold" then value = goldString(entry.data.gold)
                elseif key == "seen" then value = formatDate(entry.data.lastSeen)
                elseif key == "vault" then local v = entry.data.vault or {}; local d = v.dungeon or { 0, 0 }; value = "D " .. tostring(d[1] or 0) .. "/" .. tostring(d[2] or 0)
                elseif key == "bestRun" then value = entry.data.bestRunWeek or "—"
                elseif key == "weekly" then local parts = {}; for _, category in ipairs({ "raid", "dungeon", "world" }) do local p = (entry.data.vault or {})[category] or { 0, 0 }; parts[#parts + 1] = category .. " " .. tostring(p[1] or 0) .. "/" .. tostring(p[2] or 0) end; parts[#parts + 1] = "Key " .. tostring(entry.data.bestRunWeek or "unknown"); for _, questID in ipairs(AltoLiteDB.settings.weeklyQuestIDs or {}) do local done = entry.data.weekly and entry.data.weekly.quests and entry.data.weekly.quests[questID]; parts[#parts + 1] = tostring(questID) .. (done and " done" or " todo") end; value = table.concat(parts, "  ·  ")
                elseif key == "raid" or key == "dungeon" or key == "world" then local pair = (entry.data.vault or {})[key] or { 0, 0 }; value = tostring(math.min(pair[1] or 0, 3)) .. "/3"
                elseif key == "lockouts" then local parts = {}; if entry.data.stale and entry.data.stale.lockouts then parts[1] = "Reset since last login" else for _, l in ipairs(entry.data.lockouts or {}) do parts[#parts + 1] = tostring(l.name) .. " H " .. tostring(l.progress) end end; value = #parts > 0 and table.concat(parts, "  ·  ") or "No active lockouts"
                elseif key:find("currency:", 1, true) == 1 then local c = (entry.data.currencies or {})[key:sub(10)]; value = c and tostring(c.quantity or 0) or "—" end
                local cell = cellText(row, cellIndex); cell:ClearAllPoints(); cell:SetPoint("LEFT", row, "LEFT", (col[4] or 0) + 7, 0); cell:SetWidth(col[3] - 8); cell:SetWordWrap(false); widgetCall(cell, "SetMaxLines", 1); widgetCall(cell, "SetFont", "Fonts\\FRIZQT__.TTF", ap.fontSize, ""); widgetCall(cell, "SetJustifyH", key == "name" and "LEFT" or "RIGHT"); cell:SetText(value); cell:Show()
                local stringWidth = cell:GetStringWidth()
                local tip = row.tooltipCells[cellIndex]
                if not tip then
                    tip = CreateFrame("Button", nil, row); row.tooltipCells[cellIndex] = tip
                    tip:EnableMouse(false)
                end
                tip:ClearAllPoints(); tip:SetPoint("LEFT", row, "LEFT", col[4] or 0, 0); tip:SetSize(col[3], rowHeight); tip.fullValue = value; tip.truncated = stringWidth > (col[3] - 8); tip:Show()
                if key == "name" and ap.classNames then local r, g, b = classColor(entry.data.class); cell:SetTextColor(r, g, b) else cell:SetTextColor(unpack(ap.text)) end
            end
            for tipIndex = #columns + 1, #row.tooltipCells do row.tooltipCells[tipIndex]:Hide() end
            row:Show()
        end
        if animate and UIFrameFade then self.content:SetAlpha(0); UIFrameFade(self.content, { mode = "IN", timeToFade = 0.12, startAlpha = 0, endAlpha = 1 }) end
        self:SetHeight(math.max(430, AltoLiteDB.settings.height or defaults.height)); self:SetWidth(math.max(760, AltoLiteDB.settings.width or defaults.width))
    end
    local resize = CreateFrame("Button", nil, frame); resize:SetSize(18, 18); resize:SetPoint("BOTTOMRIGHT", -3, 3)
    local grip = resize:CreateTexture(nil, "OVERLAY"); grip:SetTexture("Interface\\Buttons\\WHITE8X8"); grip:SetAllPoints(resize); grip:SetVertexColor(0.45, 0.58, 0.70, 0.9)
    resize:SetScript("OnMouseDown", function() if frame.StartSizing then frame:StartSizing("BOTTOMRIGHT") end end)
    resize:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); local w, h = frame:GetSize(); AltoLiteDB.settings.width, AltoLiteDB.settings.height = w, h end)
    frame:SetScript("OnSizeChanged", function(_, w, h) if InCombatLockdown and InCombatLockdown() then refreshPending = true; return end; AltoLiteDB.settings.width, AltoLiteDB.settings.height = w, h; if frame.Refresh then frame:Refresh() end end)
    frame:SetScript("OnShow", function() frame:Refresh(); frame.timer:SetText("Reset in " .. "—"); if frame.timerTicker then frame.timerTicker:Cancel() end; frame.timerTicker = C_Timer and C_Timer.NewTicker(1, function() if frame:IsShown() then local s = tonumber(resetSeconds()) or 0; frame.timer:SetText(string.format("Reset in %dd %02dh %02dm", math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60))) end end) end)
    frame:SetScript("OnHide", function() if frame.timerTicker then frame.timerTicker:Cancel(); frame.timerTicker = nil end end)
    frame:Hide()
    if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "AltoLiteFrame" end
    return frame
end
local function createOptions()
    if optionsFrame or not CreateFrame then return optionsFrame end
    local panel = CreateFrame("Frame", "AltoLiteOptionsPanel", UIParent); optionsFrame = panel; panel.name = "AltoLite"
    local title = text(panel, "GameFontNormalLarge"); title:SetPoint("TOPLEFT", 18, -18); title:SetText("AltoLite Settings")
    local function label(value, x, y, font) local t = text(panel, font or "GameFontHighlight"); t:SetPoint("TOPLEFT", x, y); t:SetText(value); return t end
    local function checkbox(value, x, y, key)
        local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate"); box:SetPoint("TOPLEFT", x, y); local txt = box.Text or box.text; if txt then txt:SetText(value) end
        box:SetChecked(appearance()[key]); box:SetScript("OnClick", function(self) appearance()[key] = self:GetChecked() and true or false; applyAppearance() end); return box
    end
    local function slider(value, x, y, min, max, step, getter, setter)
        label(value, x, y)
        local control = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate"); control:SetPoint("TOPLEFT", x, y - 20); control:SetMinMaxValues(min, max); control:SetValueStep(step); control:SetObeyStepOnDrag(true); control:SetWidth(190); control:SetValue(getter())
        control:SetScript("OnValueChanged", function(_, amount) setter(math.floor(amount / step + 0.5) * step); applyAppearance() end); return control
    end
    local colorNames = { { "Accent color", "accent" }, { "Window background", "background" }, { "Header bar color", "header" }, { "Row stripe color", "stripe" }, { "Row hover color", "hover" }, { "Text color", "text" }, { "Border color", "borderColor" } }
    for i, entry in ipairs(colorNames) do
        local col = (i - 1) % 2; local row = math.floor((i - 1) / 2); local x, y = 20 + col * 260, -62 - row * 48
        label(entry[1], x, y)
        local swatch = CreateFrame("Button", nil, panel, "BackdropTemplate"); swatch:SetSize(36, 22); swatch:SetPoint("TOPLEFT", x + 150, y + 2)
        local function paint() local c = appearance()[entry[2]]; swatch:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" }); swatch:SetBackdropColor(c[1], c[2], c[3], c[4] or 1) end
        paint()
        swatch:SetScript("OnClick", function()
            if not ColorPickerFrame then return end
            local c = appearance()[entry[2]]
            local function changed() local r, g, b = ColorPickerFrame:GetColorRGB(); local alpha = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or c[4] or 1; appearance()[entry[2]] = { r, g, b, alpha }; paint(); applyAppearance() end
            local info = { r = c[1], g = c[2], b = c[3], opacity = c[4] or 1, hasOpacity = true, swatchFunc = changed, opacityFunc = changed, cancelFunc = function(previous) if previous then appearance()[entry[2]] = { previous.r, previous.g, previous.b, previous.opacity }; paint(); applyAppearance() end end }
            if ColorPickerFrame.SetupColorPickerAndShow then ColorPickerFrame:SetupColorPickerAndShow(info) elseif ColorPickerFrame.SetColorRGB then ColorPickerFrame.func = changed; ColorPickerFrame.opacityFunc = changed; ColorPickerFrame.hasOpacity = true; ColorPickerFrame:SetColorRGB(c[1], c[2], c[3]); ColorPickerFrame:Show() end
        end)
    end
    local function button(value, x, y, width, callback) local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); b:SetSize(width or 140, 24); b:SetPoint("TOPLEFT", x, y); b:SetText(value); b:SetScript("OnClick", callback); return b end
    local presets = {
        { "Default Dark", { 0.25, 0.72, 0.95, 1 }, { 0.035, 0.045, 0.06, 0.98 }, { 0.10, 0.15, 0.21, 1 } },
        { "Transparent", { 0.25, 0.72, 0.95, 1 }, { 0.035, 0.045, 0.06, 0 }, { 0.10, 0.15, 0.21, 0.75 } },
        { "Midnight Purple", { 0.72, 0.40, 0.95, 1 }, { 0.045, 0.025, 0.08, 0.96 }, { 0.16, 0.08, 0.25, 1 } },
        { "Light", { 0.12, 0.43, 0.72, 1 }, { 0.88, 0.90, 0.93, 1 }, { 0.72, 0.76, 0.81, 1 } },
        { "Class Color Accent", nil, nil, nil }
    }
    label("Presets", 20, -212, "GameFontNormal")
    for i, preset in ipairs(presets) do button(preset[1], 20 + ((i - 1) % 3) * 145, -234 - math.floor((i - 1) / 3) * 30, 138, function()
        local a = appearance()
        if preset[1] == "Class Color Accent" then local class; if UnitClass then local _, value = UnitClass("player"); class = value end; local r, g, b = classColor(class); a.accent = { r, g, b, 1 }
        else a.accent, a.background, a.header = { unpack(preset[2]) }, { unpack(preset[3]) }, { unpack(preset[4]) } end
        applyAppearance()
    end) end
    button("Reset appearance", 20, -296, 150, function() AltoLiteDB.settings.appearance = {}; copyDefaults(defaults.appearance, AltoLiteDB.settings.appearance); applyAppearance() end)
    checkbox("Class-colored names", 20, -336, "classNames")
    checkbox("Show header summary", 250, -336, "summary")
    checkbox("Compact mode", 480, -336, "compact")
    slider("Background opacity", 20, -375, 0, 100, 1, function() return math.floor((appearance().background[4] or 1) * 100) end, function(v) appearance().background[4] = v / 100 end)
    slider("Border width", 250, -375, 0, 2, 1, function() return appearance().border end, function(v) appearance().border = v end)
    slider("Font size", 480, -375, 10, 16, 1, function() return appearance().fontSize end, function(v) appearance().fontSize = v end)
    slider("Row height", 20, -445, 18, 32, 1, function() return appearance().rowHeight end, function(v) appearance().rowHeight = v end)
    slider("Window scale", 250, -445, 0.75, 1.25, 0.05, function() return AltoLiteDB.settings.scale or 1 end, function(v) AltoLiteDB.settings.scale = v end)
    label("Border style: 0 none, 1 px, 2 px", 480, -445)
    label("Display and tracking", 20, -520, "GameFontNormal")
    local function ordinaryCheck(value, x, y, checked, callback) local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate"); box:SetPoint("TOPLEFT", x, y); local t = box.Text or box.text; if t then t:SetText(value) end; box:SetChecked(checked); box:SetScript("OnClick", function(self) callback(self:GetChecked()) end) end
    ordinaryCheck("Show realm beside character", 16, -542, AltoLiteDB.settings.display.showRealm, function(v) AltoLiteDB.settings.display.showRealm = v; queueRefresh() end)
    ordinaryCheck("Hide minimap button", 250, -542, AltoLiteDB.settings.minimap.hide, function(v) AltoLiteDB.settings.minimap.hide = v; if minimapButton then minimapButton:SetShown(not v) end end)
    label("Tracked currencies", 20, -585, "GameFontNormal")
    local y = -607
    for _, currency in ipairs(resetCurrencyChoices()) do local id = tostring(currency.id); ordinaryCheck(currency.name, 16, y, AltoLiteDB.settings.currencies[id] == true, function(v) AltoLiteDB.settings.currencies[id] = v and true or nil; currentCharacter(); queueRefresh() end); y = y - 25 end
    label("Columns", 360, -585, "GameFontNormal")
    local cy = -607
    for _, key in ipairs(columnOrder) do ordinaryCheck(columnLabels[key], 352, cy, AltoLiteDB.settings.columns[key] ~= false, function(v) AltoLiteDB.settings.columns[key] = v; queueRefresh() end); cy = cy - 25 end
    button("Reset window position", 650, -80, 180, function() AltoLiteDB.settings.point = nil; if mainFrame then mainFrame:ClearAllPoints(); mainFrame:SetPoint("CENTER") end end)
    if Settings and Settings.RegisterCanvasLayoutCategory then local category = Settings.RegisterCanvasLayoutCategory(panel, "AltoLite"); if Settings.RegisterAddOnCategory then Settings.RegisterAddOnCategory(category) end; panel.category = category elseif InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel) end
    return panel
end
local function showOptions()
    local panel = createOptions(); if not panel then return end
    if Settings and Settings.OpenToCategory and panel.category then Settings.OpenToCategory(panel.category:GetID()) elseif InterfaceOptionsFrame_OpenToCategory then InterfaceOptionsFrame_OpenToCategory(panel); InterfaceOptionsFrame_OpenToCategory(panel) end
end
local function requestPlayedTime()
    if timePlayedRequested or type(RequestTimePlayed) ~= "function" then return end
    if not timePlayedFilterInstalled and type(ChatFrame_AddMessageEventFilter) == "function" then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, message)
            local lower = type(message) == "string" and message:lower() or ""
            if lower:find("time played", 1, true) or lower:find("played for", 1, true) then return true end
            return false
        end)
        timePlayedFilterInstalled = true
    end
    timePlayedRequested = true
    safeCall(RequestTimePlayed)
end
local function toggleWindow() local frame = createMainFrame(); if frame:IsShown() then frame:Hide() else requestPlayedTime(); checkWeeklyReset(); frame:Show() end end
local function createMinimapButton()
    if minimapButton or not CreateFrame or not Minimap then return minimapButton end
    local button = CreateFrame("Button", "AltoLiteMinimapButton", Minimap); minimapButton = button; button:SetSize(32, 32); button:SetFrameStrata("MEDIUM"); button:SetMovable(true); button:EnableMouse(true); button:RegisterForClicks("LeftButtonUp", "RightButtonUp"); button:RegisterForDrag("LeftButton")
    local bg = button:CreateTexture(nil, "BACKGROUND"); bg:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); bg:SetSize(54, 54); bg:SetPoint("TOPLEFT")
    local icon = button:CreateTexture(nil, "ARTWORK"); icon:SetTexture("Interface\\AddOns\\AltoLite\\icon.png"); icon:SetSize(20, 20); icon:SetPoint("CENTER", 0, 1)
    local function position() local angle = math.rad(AltoLiteDB.settings.minimap.angle or 220); button:ClearAllPoints(); button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80) end
    local function updatePosition() local mx, my = Minimap:GetCenter(); local x, y = GetCursorPosition(); local scale = UIParent:GetEffectiveScale(); local dx, dy = x / scale - mx, y / scale - my; AltoLiteDB.settings.minimap.angle = math.deg(math.atan2(dy, dx)); position() end
    button:SetScript("OnDragStop", updatePosition)
    button:SetScript("OnClick", function(_, click) if click == "RightButton" then showOptions() else toggleWindow() end end)
    button:SetScript("OnEnter", function() if GameTooltip then GameTooltip:SetOwner(button, "ANCHOR_LEFT"); GameTooltip:AddLine("AltoLite"); GameTooltip:AddLine("Left click: dashboard  Right click: settings", 1, 1, 1); GameTooltip:Show() end end); button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    position(); if AltoLiteDB.settings.minimap.hide then button:Hide() end
    return button
end
checkWeeklyReset = function()
    local boundary = getResetBoundary(); if not boundary then return end
    for _, character in pairs(AltoLiteDB.characters) do
        local previous = tonumber(character.resetBoundary) or boundary
        if boundary > previous + 3600 then character.stale = character.stale or {}; character.stale.key = true; character.stale.vault = true; character.stale.lockouts = true end
    end
end
local function initialize()
    AltoLiteDB = AltoLiteDB or {}; AltoLiteDB.characters = AltoLiteDB.characters or {}; AltoLiteDB.settings = AltoLiteDB.settings or {}; copyDefaults(defaults, AltoLiteDB.settings)
    local version = tonumber(AltoLiteDB.version) or 1
    if version < 2 then
        for _, character in pairs(AltoLiteDB.characters) do
            character.weekly = character.weekly or { quests = {} }
            character.equipment = character.equipment or {}
            character.professions = character.professions or {}
            character.mythicMaps = character.mythicMaps or {}
            character.renown = character.renown or {}
        end
    end
    if version < 3 then for _, character in pairs(AltoLiteDB.characters) do character.weekly = character.weekly or { quests = {} }; character.weekly.quests = character.weekly.quests or {} end end
    local grouped, aliases, oldKeys = {}, {}, {}
    for oldID, character in pairs(AltoLiteDB.characters) do
        if type(character) == "table" and type(character.name) == "string" and character.name ~= "" and character.name ~= "Unknown" then
            local realmKey = canonicalRealm(character.realm) or normalizeRealmValue(type(oldID) == "string" and oldID:match("^.*%-(.+)$"))
            local nameKey = realmKey and ("name:" .. character.name .. "|" .. realmKey)
            local guidKey = type(character.guid) == "string" and character.guid ~= "" and ("guid:" .. character.guid)
            local signature = (guidKey and aliases[guidKey]) or (nameKey and aliases[nameKey]) or nameKey or guidKey
            if signature then
                local record = grouped[signature]
                if not record then record = { data = {}, canonical = nil, seen = -1 }; grouped[signature] = record end
                local seen = tonumber(character.lastSeen) or 0
                if seen >= record.seen then
                    for field, value in pairs(record.data) do if character[field] == nil then character[field] = value end end
                    record.data = character
                    record.seen = seen
                    record.canonical = charKey(character.name, character.realm) or oldID
                else
                    for field, value in pairs(character) do if record.data[field] == nil then record.data[field] = value end end
                end
                if nameKey then aliases[nameKey] = signature end
                if guidKey then aliases[guidKey] = signature end
                oldKeys[oldID] = signature
                if not record.canonical and realmKey then record.canonical = charKey(character.name, realmKey) or oldID end
            end
        end
    end
    local migrated, canonicalBySignature = {}, {}
    for signature, record in pairs(grouped) do migrated[record.canonical] = record.data; canonicalBySignature[signature] = record.canonical end
    AltoLiteDB.characters = migrated
    local settings = AltoLiteDB.settings
    local function normalizeSettingReferences(value)
        if type(value) ~= "table" then
            local signature = type(value) == "string" and oldKeys[value]
            return signature and canonicalBySignature[signature] or value
        end
        local result = {}
        for key, item in pairs(value) do
            local signature = type(key) == "string" and oldKeys[key]
            local normalizedKey = signature and canonicalBySignature[signature] or key
            result[normalizedKey] = normalizeSettingReferences(item)
        end
        return result
    end
    AltoLiteDB.settings = normalizeSettingReferences(settings)
    AltoLiteDB.settings.lastTab = AltoLiteDB.settings.lastTab or "Overview"
    AltoLiteDB.version = 4
end
SLASH_ALTOLITE1 = "/alto"
SlashCmdList = SlashCmdList or {}
SlashCmdList.ALTOLITE = function(message) message = tostring(message or ""):lower(); if message == "options" or message == "settings" then showOptions() else toggleWindow() end end
AddonCompartmentFunc = toggleWindow
AddonCompartmentFuncOnEnter = function() if GameTooltip then GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR"); GameTooltip:AddLine("AltoLite"); GameTooltip:AddLine("Open the alt dashboard", 1, 1, 1); GameTooltip:Show() end end
AddonCompartmentFuncOnLeave = function() if GameTooltip then GameTooltip:Hide() end end
eventFrame:RegisterEvent("PLAYER_LOGIN"); eventFrame:RegisterEvent("PLAYER_LOGOUT"); eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD"); eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED"); eventFrame:RegisterEvent("PLAYER_MONEY"); eventFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE"); eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED"); eventFrame:RegisterEvent("WEEKLY_REWARDS_UPDATE"); eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO"); eventFrame:RegisterEvent("PLAYER_LEVEL_UP"); eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED"); eventFrame:RegisterEvent("TIME_PLAYED_MSG")
eventFrame:SetScript("OnEvent", function(_, event, total, level)
    if event == "PLAYER_LOGIN" then initialize()
    elseif event == "PLAYER_ENTERING_WORLD" then playerEnteredWorld = true; if AltoLiteDB then currentCharacter(true); checkWeeklyReset(); queueRefresh() end
    elseif event == "PLAYER_REGEN_ENABLED" then if refreshPending then refreshPending = false; applyAppearance(); queueRefresh() end
    elseif event == "TIME_PLAYED_MSG" and AltoLiteDB and AltoLiteDB.characters then
        local name, realm; if UnitFullName then name, realm = UnitFullName("player") elseif UnitName then name = UnitName("player") end; realm = realm or (GetRealmName and GetRealmName()); local char = AltoLiteDB.characters[charKey(name, realm)]; if char then char.playedTotal, char.playedLevel = tonumber(total), tonumber(level) end; queueRefresh()
    elseif playerEnteredWorld and AltoLiteDB and AltoLiteDB.characters then
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            local name, realm; if UnitFullName then name, realm = UnitFullName("player") elseif UnitName then name = UnitName("player") end; realm = realm or (GetRealmName and GetRealmName()); local char = AltoLiteDB.characters[charKey(name, realm)]
            if char then local slot = tonumber(total); if slot and slot >= 1 and slot <= 19 then local link = safeCall(GetInventoryItemLink, "player", slot); char.equipment = char.equipment or {}; char.equipment[slot] = link and safeCall(C_Item and C_Item.GetDetailedItemLevelInfo, link) or nil end end
        else currentCharacter(true) end
        if event ~= "PLAYER_LOGOUT" then queueRefresh() end
    end
end)
