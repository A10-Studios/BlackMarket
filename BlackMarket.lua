-- BlackMarket.lua
-- Custom Black Market Auction House UI

local ADDON_NAME = "BlackMarket"
local BM = {}
_G[ADDON_NAME] = BM

-- Forward-declared locals used across multiple sections
local _countdownTicker    = nil
local _filterDropdown     = nil   -- shared dropdown for Type filter
local _filtersBtn         = nil   -- Filters toggle button (Time + Collection panel)
local _filterPanel        = nil   -- multi-select filter popup panel
local _settingsPanel      = nil   -- column-visibility settings popup
local GetCollectedStatus  -- defined after collection APIs are referenced

-- Auto-close timers for filter/settings panels
local _filterCloseTimer   = nil
local _settingsCloseTimer = nil

local function SchedulePanelClose(panel, timerRef)
    if timerRef and timerRef[1] then timerRef[1]:Cancel() end
    timerRef[1] = C_Timer.NewTimer(0.4, function()
        timerRef[1] = nil
        -- IsMouseOver covers the panel AND all its child frames (checkboxes, etc.)
        if panel and panel:IsShown() and not panel:IsMouseOver() then
            panel:Hide()
        end
    end)
end
local function CancelPanelClose(timerRef)
    if timerRef and timerRef[1] then timerRef[1]:Cancel() ; timerRef[1] = nil end
end
-- Wrap as closures so callers don't need to pass the ref table each time
local _filterTimerRef   = {}
local _settingsTimerRef = {}
local function ScheduleFilterClose()   SchedulePanelClose(_filterPanel,   _filterTimerRef)   end
local function CancelFilterClose()     CancelPanelClose(_filterTimerRef)                     end
local function ScheduleSettingsClose() SchedulePanelClose(_settingsPanel,  _settingsTimerRef) end
local function CancelSettingsClose()   CancelPanelClose(_settingsTimerRef)                    end

-- Auto-refresh state (always on while at BMAH, no user toggle)
local _autoRefreshTicker   = nil
local AUTOREFRESH_INTERVAL = 60   -- seconds between background refreshes

local function StopAutoRefreshTicker()
    if _autoRefreshTicker then _autoRefreshTicker:Cancel() ; _autoRefreshTicker = nil end
end

local function StartAutoRefreshTicker()
    StopAutoRefreshTicker()
    _autoRefreshTicker = C_Timer.NewTicker(AUTOREFRESH_INTERVAL, function()
        if BM.isAtBMAH and C_BlackMarket and C_BlackMarket.RequestItems then
            BM.isAutoRefresh = true   -- tell RefreshList not to re-anchor time estimates
            C_BlackMarket.RequestItems()
        end
    end)
end

-- ============================================================
-- CONSTANTS
-- ============================================================

local MAX_VISIBLE_ROWS = 11   -- unified list (live + history)
local ROW_HEIGHT       = 52
local ICON_SIZE        = 36
local MAIN_WIDTH       = 910
local MAIN_HEIGHT      = 720
local LIST_WIDTH       = 660
local DETAIL_WIDTH     = 225

local TIME_LEFT_TEXT = { "Short", "Medium", "Long", "Very Long" }

-- Time-bracket expiry ranges in seconds (for countdown estimation)
-- NO_UPPER (0) = sentinel meaning "no known upper bound"
local NO_UPPER = 0
local BRACKET_RANGES = {
    [1] = { min = 0,     max = 1800  },   -- Short  : 0 – 30 min
    [2] = { min = 1800,  max = 7200  },   -- Medium : 30 min – 2 h
    [3] = { min = 7200,  max = 43200 },   -- Long   : 2 h – 12 h
    [4] = { min = 43200, max = nil   },   -- Very Long: 12 h+ (no upper bound)
}

-- Column left-offsets (pixels from row LEFT).
-- statusIcon and icon are fixed; variable columns are recomputed by ApplyColumnLayout.
local COL = {
    statusIcon = 4,
    watch      = 4,   -- fixed pre-icon position
    icon       = 26,  -- shifted right to make room for watch
    name       = 68,
    level      = 194,
    itemType   = 222,
    timeLeft   = 278,
    seller     = 372,
    bid        = 414,
    goldIcon   = 482,
}

-- Ordered column definitions — drives auto-sizing and column-visibility settings.
-- fixed=true columns use minW directly (no content measurement).
-- isBid=true column reserves BID_ICON_W pixels at its right edge for the gold icon.
-- "watch" is NOT in COLS_DEF — it is a fixed pre-icon widget handled separately.
local COLS_DEF = {
    { key = "name",     header = "Name",        minW = 120, maxW = 230 },
    { key = "level",    header = "Lvl",         minW = 22,  maxW = 36,  fixed = true },
    { key = "itemType", header = "Type",        minW = 50,  maxW = 110 },
    { key = "timeLeft", header = "Time Left",   minW = 100, maxW = 100, fixed = true },
    { key = "seller",   header = "Seller",      minW = 36,  maxW = 90  },
    { key = "numBids",  header = "Bids",        minW = 28,  maxW = 40,  fixed = true },
    { key = "bid",      header = "Current Bid", minW = 66,  maxW = 130, isBid = true },
}
local COL_GAP    = 6   -- pixels between columns
local BID_ICON_W = 18  -- space reserved inside bid column for the gold icon

-- ============================================================
-- HELPERS
-- ============================================================

local function QualityColor(quality)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function QualityHex(quality)
    local r, g, b = QualityColor(quality)
    return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

local function GoldText(copper)
    if not copper or copper == 0 then return "0" end
    local g = math.floor(copper / 10000)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)
end

local function TimeLeftText(timeLeft)
    if timeLeft == 0 then return "|cff00ff00Completed!|r" end
    return TIME_LEFT_TEXT[timeLeft] or "Unknown"
end

local function FormatTimeShort(secs)
    secs = math.floor(secs)
    if secs <= 0 then return "0s" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then
        return m > 0 and (h .. "h " .. m .. "m") or (h .. "h")
    elseif m > 0 then
        return s > 0 and (m .. "m " .. s .. "s") or (m .. "m")
    else
        return s .. "s"
    end
end

-- Intersect a new bracket observation into an existing estimate.
-- minExpiry / maxExpiry are Unix timestamps. NO_UPPER (0) = no upper bound known.
-- When the new observation contradicts the accumulated interval (empty intersection),
-- the item was likely refreshed; reset to the new observation alone.
local function UpdateTimeEstimate(existing, nowTs, bracket)
    local range = BRACKET_RANGES[bracket]
    if not range then return existing end
    local newMin = nowTs + range.min
    local newMax = range.max and (nowTs + range.max) or NO_UPPER

    if not existing then
        return { minExpiry = newMin, maxExpiry = newMax }
    end

    local oldMin = existing.minExpiry or 0
    local oldMax = existing.maxExpiry or NO_UPPER

    local resultMin = math.max(oldMin, newMin)
    local resultMax
    if oldMax == NO_UPPER then
        resultMax = newMax
    elseif newMax == NO_UPPER then
        resultMax = oldMax
    else
        resultMax = math.min(oldMax, newMax)
    end

    -- Empty intersection means a contradiction (item refreshed / bad data); reset.
    if resultMax ~= NO_UPPER and resultMin > resultMax then
        return { minExpiry = newMin, maxExpiry = newMax }
    end

    return { minExpiry = resultMin, maxExpiry = resultMax }
end

-- Display estimated time remaining as a min–max range.
-- The LOWER bound comes from the current bracket (e.g. Long = always ≥2h right now),
-- so it does NOT tick down between refreshes — only the upper bound counts down.
-- Falls back to bracket label when no estimate has been accumulated yet.
local function FormatEstimatedTime(est, bracket)
    if bracket == 0 then return "|cffaaaaaa(ended)|r" end
    if not est then
        return "|cff888888" .. (TIME_LEFT_TEXT[bracket] or "?") .. "|r"
    end
    local now    = time()
    local maxExp = est.maxExpiry
    -- Do NOT call it ended based on estimate alone — only bracket==0 (actual scan)
    -- means an auction is truly over. If the estimate runs out we fall through and
    -- display <0s, which clears on the next real scan if the item is actually gone.
    -- Lower bound: use the accumulated minExpiry directly so it counts down naturally.
    -- bracketFloor is only a fallback when there is no running estimate.
    -- After a fresh NPC scan UpdateTimeEstimate guarantees minExpiry >= now+bracketFloor,
    -- so the initial display is correct; between NPC visits it ticks down freely.
    local bracketRange = BRACKET_RANGES[bracket]
    local bracketFloor = bracketRange and bracketRange.min or 0
    local minR
    if est.minExpiry and est.minExpiry > 0 then
        minR = math.max(0, est.minExpiry - now)
    else
        minR = bracketFloor
    end
    if maxExp == NO_UPPER then
        return "|cff88aaff>~" .. FormatTimeShort(minR) .. "|r"
    end
    local maxR = math.max(0, maxExp - now)
    -- If accumulated cap has narrowed below the bracket floor, trust the cap
    if maxR < minR then minR = 0 end
    -- Color by effective bracket derived from maxR (upper bound of remaining time)
    local col
    if     maxR < 1800  then col = "ff4444"  -- Short     (<30 min): red
    elseif maxR < 7200  then col = "ffaa00"  -- Medium    (<2 h):    orange
    elseif maxR < 43200 then col = "44dd44"  -- Long      (<12 h):   green
    else                     col = "88aaff"  -- Very Long (12 h+):   blue
    end
    if minR == 0 then
        return "|cff" .. col .. "<" .. FormatTimeShort(maxR) .. "|r"
    end
    return "|cff" .. col .. FormatTimeShort(minR) .. "-" .. FormatTimeShort(maxR) .. "|r"
end

-- Returns the effective time-left bracket for an item, derived from its running
-- time estimate when available. RequestItems() does not update the timeLeft field
-- from the server — only a full NPC interaction does — so item.timeLeft goes stale
-- between sessions. Using maxExpiry from the estimate keeps the bracket current.
local function EffectiveBracket(item)
    local est = item and item.timeEstimate
    if est and est.maxExpiry ~= NO_UPPER then
        local remaining = est.maxExpiry - time()
        if remaining <= 0  then return 0 end   -- ended
        if remaining < 1800  then return 1 end -- Short    (<30 min)
        if remaining < 7200  then return 2 end -- Medium   (<2 h)
        if remaining < 43200 then return 3 end -- Long     (<12 h)
        return 4                               -- Very Long
    end
    return item and item.timeLeft or 0
end

local function PlayerMoneyString()
    local money = GetMoney and GetMoney() or 0
    local g = math.floor(money / 10000)
    local s = math.floor((money % 10000) / 100)
    local c = money % 100
    return string.format(
        "|cffffd700%s|r|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t "
        .. "|cffc0c0c0%d|r|TInterface\\MoneyFrame\\UI-SilverIcon:14:14:2:0|t "
        .. "|cffeda55f%d|r|TInterface\\MoneyFrame\\UI-CopperIcon:14:14:2:0|t",
        BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g, s, c
    )
end

local function FormatTimeSince(ts)
    if not ts then return "Never" end
    local d = time() - ts
    if d < 60        then return "Just now"
    elseif d < 3600  then return string.format("%dm ago",  math.floor(d / 60))
    elseif d < 86400 then return string.format("%dh ago",  math.floor(d / 3600))
    else                  return string.format("%dd ago",  math.floor(d / 86400))
    end
end

-- Returns true when item passes all active filters
local function ItemMatchesFilters(item)
    if not item then return false end
    local f = BM.filters
    if not f then return true end
    if f.name and f.name ~= "" then
        local haystack = (item.name or ""):lower()
        if not haystack:find(f.name:lower(), 1, true) then return false end
    end
    if f.itemType and next(f.itemType) then
        if not f.itemType[item.typeLabel or ""] then return false end
    end
    if f.timeLeft and next(f.timeLeft) then
        local bracket = EffectiveBracket(item)
        if not f.timeLeft[bracket] then return false end
    end
    if f.collected and next(f.collected) then
        local base = GetCollectedStatus(item.itemLink, item.typeLabel)
        local filterKey
        if base == nil then
            filterKey = "other"
        elseif base == "learnable" then
            filterKey = "learnable"
        else
            filterKey = "collected"
        end
        if not f.collected[filterKey] then return false end
    end
    if f.bid and next(f.bid) then
        local passes = false
        if f.bid["myBid"]    and item.isHighBid      then passes = true end
        if f.bid["notMyBid"] and not item.isHighBid  then passes = true end
        if not passes then return false end
    end
    if f.watched and next(f.watched) then
        local watchKey = item.itemLink and item.firstSeen and (item.itemLink .. "|" .. tostring(item.firstSeen)) or item.itemLink
        local isWatched = watchKey and BlackMarketDB.watched and BlackMarketDB.watched[watchKey] == true
        local passes = false
        if f.watched["watched"]   and isWatched     then passes = true end
        if f.watched["unwatched"] and not isWatched then passes = true end
        if not passes then return false end
    end
    return true
end

local function GetSessionKey()
    local realm = GetRealmName() or "Unknown"
    local char  = UnitName("player") or "Unknown"
    -- Key is realm-only so all characters on the same realm share one history record.
    -- charName is stored in the record and updated to whoever visited most recently.
    return realm, realm, char
end

-- Handle shift/ctrl clicks on item links.
-- Shift-click  → insert item link into active chat box.
-- Ctrl-click   → open dressing room / mount / pet preview.
-- Returns true if a modifier was handled (caller should skip normal click logic).
local function HandleItemModifierClick(itemLink)
    if not itemLink then return false end
    if IsShiftKeyDown() or IsControlKeyDown() then
        HandleModifiedItemClick(itemLink)
        return true
    end
    return false
end

-- ============================================================
-- COLUMN AUTO-SIZING
-- ============================================================

local _measureFS      = nil   -- GameFontNormalSmall measurement string
local _measureFSNorm  = nil   -- GameFontNormal measurement string (for item names)

local function MeasureText(text)
    if not _measureFS then
        _measureFS = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    end
    _measureFS:SetText(text or "")
    return _measureFS:GetStringWidth()
end

local function MeasureTextNorm(text)
    if not _measureFSNorm then
        _measureFSNorm = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    end
    _measureFSNorm:SetText(text or "")
    return _measureFSNorm:GetStringWidth()
end

-- Scan all live items and history to find max content width per variable column.
local function ComputeColumnWidths()
    local colW = {}
    for _, cd in ipairs(COLS_DEF) do
        colW[cd.key] = MeasureText(cd.header) + 8  -- header text is the minimum
    end

    local function scanItem(item)
        if not item then return end
        if item.name then
            local w = MeasureTextNorm(item.name) + 8
            colW.name = math.max(colW.name or 0, w)
        end
        if item.typeLabel then
            local w = MeasureText(item.typeLabel) + 6
            colW.itemType = math.max(colW.itemType or 0, w)
        end
        if item.sellerName then
            local w = MeasureText(item.sellerName) + 6
            colW.seller = math.max(colW.seller or 0, w)
        end
        local bidAmt = (item.currentBid and item.currentBid > 0)
                       and item.currentBid or (item.nextMinBid or 0)
        local w = MeasureText(GoldText(bidAmt)) + BID_ICON_W + 6
        colW.bid = math.max(colW.bid or 0, w)
    end

    for i = 1, (BM.numItems or 0) do scanItem(BM.items and BM.items[i]) end
    if BlackMarketDB and BlackMarketDB.history then
        for _, sess in pairs(BlackMarketDB.history) do
            for _, item in pairs(sess.auctions or {}) do scanItem(item) end
        end
    end

    for _, cd in ipairs(COLS_DEF) do
        colW[cd.key] = math.max(cd.minW, math.min(cd.maxW, colW[cd.key] or cd.minW))
    end
    return colW
end

-- Reposition all header labels and pool row font strings.
-- colW: map col.key → pixel width; colVis: map col.key → bool (nil = all visible).
local function ApplyColumnLayout(colW, colVis)
    colVis = colVis or {}

    -- Grow or shrink flex columns so the row exactly fills the available list width.
    -- Fixed columns (level, timeLeft) are never touched.
    -- On grow: name absorbs all extra space.
    -- On shrink: reduce flex columns toward their minW, name first then others.
    local listW = BM.listWidth or LIST_WIDTH
    local usedW = 68  -- fixed icon area: watch(22) + icon(36) + gap(10)
    for _, cd in ipairs(COLS_DEF) do
        if colVis[cd.key] ~= false then
            usedW = usedW + (colW[cd.key] or cd.minW) + COL_GAP
        end
    end
    local delta = listW - usedW - 8

    if delta > 0 then
        -- Grow: give all extra to name
        if colVis["name"] ~= false then
            colW["name"] = colW["name"] + delta
        end
    elseif delta < 0 then
        -- Shrink: take from flex columns toward their minW; name first, then rest
        local deficit = -delta
        for _, cd in ipairs(COLS_DEF) do
            if deficit <= 0 then break end
            if not cd.fixed and colVis[cd.key] ~= false then
                local current  = colW[cd.key] or cd.minW
                local canShrink = current - cd.minW
                local take     = math.min(canShrink, deficit)
                if take > 0 then
                    colW[cd.key] = current - take
                    deficit = deficit - take
                end
            end
        end
    end

    local x = 68  -- first variable column: after watch(4+22) + icon(26+36) + gap(6)

    for _, cd in ipairs(COLS_DEF) do
        local key = cd.key
        local w   = colW[key] or cd.minW
        local vis = colVis[key] ~= false

        COL[key] = x
        if cd.isBid then COL.goldIcon = x + w - BID_ICON_W + 4 end

        -- Header label
        local hlbl = BM.headerLabelMap and BM.headerLabelMap[key]
        if hlbl then
            hlbl:ClearAllPoints()
            if vis then
                hlbl:SetPoint("LEFT", BM.headerFrame, "LEFT", x, 0)
                hlbl:SetWidth(w)
                hlbl:Show()
            else
                hlbl:Hide()
            end
        end

        -- Pool rows
        for _, row in ipairs(BM.rows or {}) do
            local fs = row.colFS and row.colFS[key]
            if fs then
                fs:ClearAllPoints()
                if vis then
                    local yOff = (key == "name") and 5 or 0
                    fs:SetPoint("LEFT", row, "LEFT", x, yOff)
                    if key == "name" then
                        fs:SetSize(w, ROW_HEIGHT - 4)
                    elseif key == "itemType" or key == "seller" then
                        fs:SetSize(w, ROW_HEIGHT)
                    elseif cd.isBid then
                        fs:SetWidth(w - BID_ICON_W)
                    else
                        fs:SetWidth(w)
                    end
                    fs:Show()
                else
                    fs:SetWidth(0)
                    fs:Hide()
                end
            end
            if cd.isBid then
                if row.goldIcon then
                    row.goldIcon:ClearAllPoints()
                    row.goldIcon:SetPoint("LEFT", row, "LEFT", COL.goldIcon, 0)
                    if vis then row.goldIcon:Show() else row.goldIcon:Hide() end
                end
            end
        end

        if vis then x = x + w + COL_GAP end
    end

    -- Watch header and buttons are fixed pre-icon — not part of the variable-column loop.
    local watchHlbl = BM.headerLabelMap and BM.headerLabelMap["watch"]
    if watchHlbl then
        watchHlbl:ClearAllPoints()
        if colVis["watch"] ~= false then
            watchHlbl:SetPoint("LEFT", BM.headerFrame, "LEFT", COL.watch, 0)
            watchHlbl:SetWidth(22)
            watchHlbl:Show()
        else
            watchHlbl:Hide()
        end
    end
end

-- Recompute and apply the minimum window width based on visible column minW values.
local function UpdateMinSize()
    if not BM.mainFrame then return end
    local minW = 68 + 34  -- icon area (watch+icon) + right padding/scrollbar
    local vis = BM.colVisible or {}
    for _, cd in ipairs(COLS_DEF) do
        if vis[cd.key] ~= false then
            minW = minW + cd.minW + COL_GAP
        end
    end
    minW = math.max(300, minW + 16)  -- a little breathing room
    BM.mainFrame:SetResizeBounds(minW, 300, 1600, 1100)
end

-- Show/hide column font strings for a row based on BM.colVisible.
-- Called at the top of each item render function.
local function ApplyColVisibility(row)
    local vis = BM.colVisible or {}
    for _, cd in ipairs(COLS_DEF) do
        local fs = row.colFS and row.colFS[cd.key]
        if fs then
            if vis[cd.key] == false then fs:Hide() else fs:Show() end
        end
    end
    if row.goldIcon then
        if vis.bid == false then row.goldIcon:Hide() else row.goldIcon:Show() end
    end
end

-- ============================================================
-- MAIN FRAME
-- ============================================================

local function CreateMainFrame()
    local f = CreateFrame("Frame", "BMMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(MAIN_WIDTH, MAIN_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(300, 300, 1600, 1100)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetLeft(), self:GetTop()
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
        BlackMarketDB = BlackMarketDB or {}
        BlackMarketDB.windowX, BlackMarketDB.windowY = x, y
    end)
    f:SetScript("OnSizeChanged", function(self, w, h)
        if not BM.scrollFrame then return end
        local listW = math.max(200, w - 34)
        BM.listWidth = listW
        -- Bottom bar may switch to 2-row layout; query its height after update
        local barH = 38
        if BM.bottomBar and BM.bottomBar.ApplyLayout then
            BM.bottomBar.ApplyLayout(w - 12)
            barH = BM.bottomBar:GetHeight()
        end
        -- scroll top = 102, bar occupies (barH + 6 bottom offset + 8 gap) from bottom
        local scrollH = math.max(ROW_HEIGHT, h - barH - 112)
        BM.scrollFrame:SetHeight(scrollH)
        BM.scrollAreaHeight = scrollH
        if BM.scrollContent then BM.scrollContent:SetWidth(listW) end
        for _, row in ipairs(BM.rows or {}) do row:SetWidth(listW) end
        BM.layoutDirty = true
        BM.RefreshMainRows()
    end)
    f:Hide()

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    f:SetBackdropColor(0.08, 0.06, 0.03, 0.98)
    f:SetBackdropBorderColor(0.45, 0.33, 0.10, 1)

    -- Title bar background
    local titleBg = f:CreateTexture(nil, "BACKGROUND")
    titleBg:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    titleBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    titleBg:SetHeight(46)
    titleBg:SetColorTexture(0.13, 0.09, 0.03, 0.95)

    -- Title text
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("|cffffd700Black Market\nAuction House|r")
    title:SetJustifyH("CENTER")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function()
        if _countdownTicker then _countdownTicker:Cancel() ; _countdownTicker = nil end
        f:Hide()
        -- End the NPC session properly so the player can re-open it without walking away.
        -- CloseBlackMarket() fires BLACK_MARKET_CLOSE (which our handler already guards
        -- against a double-hide) and tells the server the dialogue is over.
        if CloseBlackMarket then
            CloseBlackMarket()
        elseif BlackMarketFrame then
            BlackMarketFrame:Hide()
        end
    end)

    -- (divider hidden — detail panel not shown)

    -- Resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        local x, y = f:GetLeft(), f:GetTop()
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
        BlackMarketDB = BlackMarketDB or {}
        BlackMarketDB.windowX, BlackMarketDB.windowY = x, y
        BlackMarketDB.windowWidth  = f:GetWidth()
        BlackMarketDB.windowHeight = f:GetHeight()
    end)

    return f
end

-- ============================================================
-- COLUMN HEADERS
-- ============================================================

local function CreateColumnHeaders(parent)
    local hf = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    hf:SetPoint("TOPLEFT",  parent, "TOPLEFT",  8,   -76)
    hf:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -26, -76)
    hf:SetHeight(22)
    hf:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    hf:SetBackdropColor(0.18, 0.13, 0.04, 0.92)
    hf:SetBackdropBorderColor(0.42, 0.30, 0.08, 0.8)

    BM.headerFrame    = hf
    BM.headerLabelMap = {}

    -- Watch header: fixed pre-icon widget, not in COLS_DEF loop
    local watchLbl = hf:CreateFontString(nil, "OVERLAY")
    watchLbl:SetFont("Fonts\\2002.TTF", 13)
    watchLbl:SetPoint("LEFT", hf, "LEFT", COL.watch, 0)
    watchLbl:SetWidth(22)
    watchLbl:SetText("|cffe0c060★|r")
    watchLbl:SetJustifyH("CENTER")
    BM.headerLabelMap["watch"] = watchLbl

    for _, cd in ipairs(COLS_DEF) do
        local lbl = hf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", hf, "LEFT", COL[cd.key] or 0, 0)
        lbl:SetWidth(cd.minW)
        lbl:SetText("|cffe0c060" .. cd.header .. "|r")
        lbl:SetJustifyH("LEFT")
        BM.headerLabelMap[cd.key] = lbl
    end

    return hf
end

-- ============================================================
-- FILTER BAR
-- ============================================================

-- Opens (or closes) the shared filter dropdown anchored below `anchorBtn`.
-- `opts` is an array of {val=..., label=...} where val=nil means "All".
-- `currentVal` is the currently active filter value.
-- `onSelect(val)` is called with the chosen value.
local function OpenFilterDropdown(anchorBtn, opts, currentVal, onSelect)
    if _filterPanel then _filterPanel:Hide() end
    if not _filterDropdown then
        _filterDropdown = CreateFrame("Frame", "BMFilterDropdown", UIParent, "BackdropTemplate")
        _filterDropdown:SetFrameStrata("TOOLTIP")
        _filterDropdown:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        _filterDropdown:SetBackdropColor(0.08, 0.06, 0.03, 0.98)
        _filterDropdown:SetBackdropBorderColor(0.45, 0.33, 0.10, 1)
        _filterDropdown.optBtns = {}
        _filterDropdown.currentAnchor = nil
    end

    -- Toggle: close if same button clicked again
    if _filterDropdown:IsShown() and _filterDropdown.currentAnchor == anchorBtn then
        _filterDropdown:Hide()
        return
    end
    _filterDropdown.currentAnchor = anchorBtn

    -- Hide leftover buttons from previous use
    for _, btn in ipairs(_filterDropdown.optBtns) do btn:Hide() end

    local y = -4
    for i, opt in ipairs(opts) do
        local btn = _filterDropdown.optBtns[i]
        if not btn then
            btn = CreateFrame("Button", nil, _filterDropdown)
            btn:SetHeight(22)
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints() ; hl:SetColorTexture(0.55, 0.42, 0.10, 0.3)
            btn:SetHighlightTexture(hl)
            local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT",  btn, "LEFT",  6, 0)
            lbl:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
            lbl:SetJustifyH("LEFT")
            btn.lbl = lbl
            _filterDropdown.optBtns[i] = btn
        end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT",  _filterDropdown, "TOPLEFT",  4, y)
        btn:SetPoint("TOPRIGHT", _filterDropdown, "TOPRIGHT", -4, y)

        local dispText = (opt.val == currentVal)
            and ("|cffffd700" .. opt.label .. "|r")
            or  (opt.val == nil and "|cffaaaaaa" .. opt.label .. "|r" or opt.label)
        btn.lbl:SetText(dispText)

        local captVal = opt.val
        btn:SetScript("OnClick", function()
            onSelect(captVal)
            _filterDropdown:Hide()
        end)
        btn:Show()
        y = y - 22
    end

    _filterDropdown:SetWidth(160)
    _filterDropdown:SetHeight(-y + 4)
    _filterDropdown:ClearAllPoints()
    _filterDropdown:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -2)
    _filterDropdown:Show()
end

local function UpdateFiltersBtn()
    if not _filtersBtn then return end
    local count = 0
    for _ in pairs(BM.filters.itemType  or {}) do count = count + 1 end
    for _ in pairs(BM.filters.timeLeft  or {}) do count = count + 1 end
    for _ in pairs(BM.filters.collected or {}) do count = count + 1 end
    for _ in pairs(BM.filters.watched   or {}) do count = count + 1 end
    for _ in pairs(BM.filters.bid or {}) do count = count + 1 end

    if _filtersBtn.badge then
        if count > 0 then _filtersBtn.badge:SetText(count) ; _filtersBtn.badge:Show()
        else _filtersBtn.badge:Hide() end
    end

    -- Show X only when something is active (filter count OR non-empty search)
    if _filtersBtn.clearBtn then
        local hasAny = count > 0 or (BM.filters.name and BM.filters.name ~= "")
        if hasAny then
            _filtersBtn.clearBtn:SetBackdropBorderColor(0.85, 0.25, 0.25, 1)
            _filtersBtn.clearBtn.x:SetTextColor(1, 0.35, 0.35)
            _filtersBtn.clearBtn:Show()
        else
            _filtersBtn.clearBtn:Hide()
        end
    end
end

-- Creates a labelled checkbox toggle inside `parent` at (x, y).
-- Returns the frame; frame.SetChecked(bool) updates visual state.
local function MakeFilterCheck(parent, label, x, y, width, onToggle)
    local CBOX  = 14
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 90, CBOX)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local box = CreateFrame("Button", nil, frame, "BackdropTemplate")
    box:SetSize(CBOX, CBOX)
    box:SetPoint("LEFT", frame, "LEFT", 0, 0)
    box:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    box:SetBackdropColor(0.05, 0.04, 0.01, 1)
    box:SetBackdropBorderColor(0.38, 0.27, 0.07, 0.9)

    local checkTex = box:CreateTexture(nil, "OVERLAY")
    checkTex:SetSize(CBOX - 2, CBOX - 2)
    checkTex:SetPoint("CENTER")
    checkTex:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    checkTex:SetVertexColor(1, 0.82, 0.20, 1)
    checkTex:Hide()

    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", box, "RIGHT", 5, 0)
    lbl:SetText(label)
    lbl:SetTextColor(0.92, 0.92, 0.92)
    frame.lbl = lbl   -- exposed for dynamic label updates

    box.isChecked = false

    frame.SetChecked = function(val)
        box.isChecked = val
        if val then
            box:SetBackdropColor(0.38, 0.26, 0.05, 1)
            box:SetBackdropBorderColor(0.80, 0.64, 0.16, 1)
            checkTex:Show()
        else
            box:SetBackdropColor(0.05, 0.04, 0.01, 1)
            box:SetBackdropBorderColor(0.38, 0.27, 0.07, 0.9)
            checkTex:Hide()
        end
    end
    frame._box = box  -- exposed for dynamic callback rewiring

    box:SetScript("OnClick", function()
        frame.SetChecked(not box.isChecked)
        onToggle(box.isChecked)
    end)

    return frame
end

local function BuildFilterPanel()
    if _filterPanel then return _filterPanel end

    local p = CreateFrame("Frame", "BMFilterPanel", UIParent, "BackdropTemplate")
    p:SetFrameStrata("TOOLTIP")
    p:SetWidth(320)
    p:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    p:SetBackdropColor(0.08, 0.06, 0.03, 0.98)
    p:SetBackdropBorderColor(0.45, 0.33, 0.10, 1)
    p:Hide()

    local PAD   = 10
    local ROW   = 22
    local THIRD = 100  -- (320 - 2*PAD) / 3

    local function Sep()
        local s = p:CreateTexture(nil, "ARTWORK")
        s:SetHeight(1) ; s:SetColorTexture(0.40, 0.28, 0.07, 0.7)
        return s
    end

    local function Header(text)
        local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetTextColor(1, 0.82, 0.20, 1)
        lbl:SetText(text)
        return lbl
    end

    -- ── Watch (first) ─────────────────────────────────────────────
    local watchHeader = Header("Watch")
    local watchSep    = Sep()
    local watchOpts   = {
        { val = "watched",   label = "Watched"   },
        { val = "unwatched", label = "Unwatched" },
    }
    local watchChecks = {}
    for _, opt in ipairs(watchOpts) do
        local val = opt.val
        watchChecks[val] = MakeFilterCheck(p, opt.label, 0, 0, THIRD - 6, function(on)
            BM.filters.watched = BM.filters.watched or {}
            if on then BM.filters.watched[val] = true
            else       BM.filters.watched[val] = nil end
            UpdateFiltersBtn() ; BM.RefreshMainRows()
        end)
    end
    p.watchChecks = watchChecks

    -- ── Type (dynamic pool) ────────────────────────────────────────
    local typeHeader     = Header("Type")
    local typeSep        = Sep()
    local MAX_TYPE_SLOTS = 20
    local typePool       = {}
    for i = 1, MAX_TYPE_SLOTS do
        local slot = MakeFilterCheck(p, "", 0, 0, THIRD - 6, function() end)
        slot:Hide() ; slot.typeVal = nil ; typePool[i] = slot
    end

    -- ── Time Left ─────────────────────────────────────────────────
    local timeHeader = Header("Time Left")
    local timeSep    = Sep()
    local timeOpts   = {
        { val = 1, label = "Short"     },
        { val = 2, label = "Medium"    },
        { val = 3, label = "Long"      },
        { val = 4, label = "Very Long" },
        { val = 0, label = "Completed" },
    }
    local timeChecks = {}
    for _, opt in ipairs(timeOpts) do
        local val = opt.val
        timeChecks[val] = MakeFilterCheck(p, opt.label, 0, 0, THIRD - 6, function(on)
            BM.filters.timeLeft = BM.filters.timeLeft or {}
            if on then BM.filters.timeLeft[val] = true
            else       BM.filters.timeLeft[val] = nil end
            UpdateFiltersBtn() ; BM.RefreshMainRows()
        end)
    end
    p.timeChecks = timeChecks

    -- ── Collection ────────────────────────────────────────────────
    local collHeader = Header("Collection")
    local collSep    = Sep()
    local collOpts   = {
        { val = "learnable", label = "Uncollected" },
        { val = "collected", label = "Collected"   },
        { val = "other",     label = "Other"       },
    }
    local collChecks = {}
    for _, opt in ipairs(collOpts) do
        local val = opt.val
        collChecks[val] = MakeFilterCheck(p, opt.label, 0, 0, THIRD - 6, function(on)
            BM.filters.collected = BM.filters.collected or {}
            if on then BM.filters.collected[val] = true
            else       BM.filters.collected[val] = nil end
            UpdateFiltersBtn() ; BM.RefreshMainRows()
        end)
    end
    p.collChecks = collChecks

    -- ── Bid ───────────────────────────────────────────────────────
    local bidHeader = Header("Bid")
    local bidOpts   = {
        { val = "myBid",    label = "My Bid"     },
        { val = "notMyBid", label = "Not My Bid" },
    }
    local bidChecks = {}
    for _, opt in ipairs(bidOpts) do
        local val = opt.val
        bidChecks[val] = MakeFilterCheck(p, opt.label, 0, 0, THIRD - 6, function(on)
            BM.filters.bid = BM.filters.bid or {}
            if on then BM.filters.bid[val] = true
            else       BM.filters.bid[val] = nil end
            UpdateFiltersBtn() ; BM.RefreshMainRows()
        end)
    end
    p.bidChecks = bidChecks

    -- ── Layout: position all widgets, refresh type pool ───────────
    local function LayoutPanel()
        local y = -10

        -- Watch
        watchHeader:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y) ; y = y - 20
        for i, opt in ipairs(watchOpts) do
            watchChecks[opt.val]:ClearAllPoints()
            watchChecks[opt.val]:SetPoint("TOPLEFT", p, "TOPLEFT",
                PAD + ((i-1) % 3) * THIRD, y - math.floor((i-1) / 3) * ROW)
        end
        y = y - math.ceil(#watchOpts / 3) * ROW - 8
        watchSep:SetPoint("TOPLEFT",  p, "TOPLEFT",  PAD, y)
        watchSep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, y) ; y = y - 10

        -- Type
        typeHeader:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y) ; y = y - 20
        local typeBodyY = y
        local seen, types = {}, {}
        local function addType(t)
            if t and t ~= "" and not seen[t] then seen[t] = true ; table.insert(types, t) end
        end
        for _, item in pairs(BM.items or {}) do addType(item.typeLabel) end
        if BlackMarketDB and BlackMarketDB.history then
            for _, sess in pairs(BlackMarketDB.history) do
                for _, item in pairs(sess.auctions or {}) do addType(item.typeLabel) end
            end
        end
        table.sort(types)
        for i, slot in ipairs(typePool) do
            local t = types[i]
            if t then
                slot.typeVal = t
                slot.lbl:SetText(t)
                slot.SetChecked(BM.filters.itemType and BM.filters.itemType[t] or false)
                slot:ClearAllPoints()
                slot:SetPoint("TOPLEFT", p, "TOPLEFT",
                    PAD + ((i-1) % 3) * THIRD, typeBodyY - math.floor((i-1) / 3) * ROW)
                slot._box:SetScript("OnClick", function()
                    slot.SetChecked(not slot._box.isChecked)
                    BM.filters.itemType = BM.filters.itemType or {}
                    if slot._box.isChecked then BM.filters.itemType[slot.typeVal] = true
                    else                        BM.filters.itemType[slot.typeVal] = nil end
                    UpdateFiltersBtn() ; BM.RefreshMainRows()
                end)
                slot:Show()
            else
                slot.typeVal = nil ; slot:Hide()
            end
        end
        local numTypeRows = math.max(1, math.ceil(math.min(#types, MAX_TYPE_SLOTS) / 3))
        y = y - numTypeRows * ROW - 8
        typeSep:SetPoint("TOPLEFT",  p, "TOPLEFT",  PAD, y)
        typeSep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, y) ; y = y - 10

        -- Time Left
        timeHeader:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y) ; y = y - 20
        for i, opt in ipairs(timeOpts) do
            timeChecks[opt.val]:ClearAllPoints()
            timeChecks[opt.val]:SetPoint("TOPLEFT", p, "TOPLEFT",
                PAD + ((i-1) % 3) * THIRD, y - math.floor((i-1) / 3) * ROW)
        end
        y = y - math.ceil(#timeOpts / 3) * ROW - 8
        timeSep:SetPoint("TOPLEFT",  p, "TOPLEFT",  PAD, y)
        timeSep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, y) ; y = y - 10

        -- Collection
        collHeader:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y) ; y = y - 20
        for i, opt in ipairs(collOpts) do
            collChecks[opt.val]:ClearAllPoints()
            collChecks[opt.val]:SetPoint("TOPLEFT", p, "TOPLEFT",
                PAD + ((i-1) % 3) * THIRD, y - math.floor((i-1) / 3) * ROW)
        end
        y = y - math.ceil(#collOpts / 3) * ROW - 8
        collSep:SetPoint("TOPLEFT",  p, "TOPLEFT",  PAD, y)
        collSep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, y) ; y = y - 10

        -- Bid
        bidHeader:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y) ; y = y - 20
        for i, opt in ipairs(bidOpts) do
            bidChecks[opt.val]:ClearAllPoints()
            bidChecks[opt.val]:SetPoint("TOPLEFT", p, "TOPLEFT",
                PAD + ((i-1) % 3) * THIRD, y - math.floor((i-1) / 3) * ROW)
        end
        y = y - math.ceil(#bidOpts / 3) * ROW

        p:SetHeight(math.abs(y) + 14)
    end

    p.RefreshTypeSlots = LayoutPanel

    p:SetScript("OnShow", function()
        LayoutPanel()
        for val, cb in pairs(timeChecks)  do cb.SetChecked(BM.filters.timeLeft  and BM.filters.timeLeft[val]  or false) end
        for val, cb in pairs(collChecks)  do cb.SetChecked(BM.filters.collected and BM.filters.collected[val] or false) end
        for val, cb in pairs(bidChecks)   do cb.SetChecked(BM.filters.bid        and BM.filters.bid[val]       or false) end
        for val, cb in pairs(watchChecks) do cb.SetChecked(BM.filters.watched    and BM.filters.watched[val]   or false) end
    end)

    LayoutPanel()

    p:SetScript("OnEnter", CancelFilterClose)
    p:SetScript("OnLeave", ScheduleFilterClose)

    _filterPanel = p
    return p
end

local function BuildSettingsPanel()
    if _settingsPanel then return _settingsPanel end

    local p = CreateFrame("Frame", "BMSettingsPanel", UIParent, "BackdropTemplate")
    p:SetFrameStrata("TOOLTIP")
    p:SetWidth(160)
    p:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    p:SetBackdropColor(0.08, 0.06, 0.03, 0.98)
    p:SetBackdropBorderColor(0.45, 0.33, 0.10, 1)
    p:Hide()

    local PAD = 10
    local ROW = 22

    local hdr = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -PAD)
    hdr:SetTextColor(1, 0.82, 0.20, 1)
    hdr:SetText("Columns")

    local sep = p:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT",  p, "TOPLEFT",  PAD, -PAD - 18)
    sep:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -PAD - 18)
    sep:SetHeight(1)
    sep:SetColorTexture(0.40, 0.28, 0.07, 0.7)

    local cbs = {}
    for i, col in ipairs(COLS_DEF) do
        local captKey = col.key
        local y = -(PAD + 22 + (i - 1) * ROW)
        local cb = MakeFilterCheck(p, col.header, PAD, y, 140, function(on)
            BM.colVisible = BM.colVisible or {}
            BM.colVisible[captKey] = on
            if BlackMarketDB then
                BlackMarketDB.colVisible = BlackMarketDB.colVisible or {}
                BlackMarketDB.colVisible[captKey] = on
            end
            BM.layoutDirty = true
            UpdateMinSize()
            BM.RefreshMainRows()
        end)
        cbs[captKey] = cb
    end
    p.colCbs = cbs

    p:SetHeight(PAD + 22 + #COLS_DEF * ROW + PAD)

    p:SetScript("OnShow", function()
        for key, cb in pairs(cbs) do
            cb.SetChecked(not (BM.colVisible and BM.colVisible[key] == false))
        end
    end)

    p:SetScript("OnEnter", CancelSettingsClose)
    p:SetScript("OnLeave", ScheduleSettingsClose)

    _settingsPanel = p
    return p
end

local function CreateFilterBar(parent)
    local fb = CreateFrame("Frame", "BMFilterBar", parent, "BackdropTemplate")
    fb:SetPoint("TOPLEFT",  parent, "TOPLEFT",  8,   -54)
    fb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -26, -54)
    fb:SetHeight(24)
    fb:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    fb:SetBackdropColor(0.07, 0.05, 0.015, 0.94)
    fb:SetBackdropBorderColor(0.35, 0.25, 0.06, 0.8)

    -- ── Search ──────────────────────────────────────────────
    local sLbl = fb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sLbl:SetPoint("LEFT", fb, "LEFT", 6, 0)
    sLbl:SetText("|cffe0c060Search|r")

    local searchBox = CreateFrame("EditBox", "BMSearchBox", fb, "InputBoxTemplate")
    searchBox:SetSize(130, 18)
    searchBox:SetPoint("LEFT", sLbl, "RIGHT", 4, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(50)
    searchBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            BM.filters.name = self:GetText()
            if _filterDropdown then _filterDropdown:Hide() end
            UpdateFiltersBtn()
            BM.RefreshMainRows()
        end
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("") ; BM.filters.name = "" ; BM.RefreshMainRows() ; self:ClearFocus()
    end)
    fb.searchBox = searchBox

    -- ── Filter icon button (bars-filter style) ───────────────
    local filterIconBtn = CreateFrame("Button", "BMFilterIconBtn", fb, "BackdropTemplate")
    filterIconBtn:SetSize(26, 20)
    filterIconBtn:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)
    filterIconBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    filterIconBtn:SetBackdropColor(0.06, 0.05, 0.02, 0.92)
    filterIconBtn:SetBackdropBorderColor(0.45, 0.32, 0.08, 0.85)

    -- 3 descending bars inside the button
    local barWidths = { 14, 10, 6 }
    for i, bw in ipairs(barWidths) do
        local bar = filterIconBtn:CreateTexture(nil, "ARTWORK")
        bar:SetHeight(2)
        bar:SetWidth(bw)
        bar:SetPoint("TOP", filterIconBtn, "TOP", 0, -(3 + (i - 1) * 5))
        bar:SetColorTexture(0.88, 0.70, 0.22, 1)
    end

    -- Small active-filter count badge (bottom of icon, inset from right edge)
    local badge = filterIconBtn:CreateFontString(nil, "OVERLAY")
    badge:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    badge:SetPoint("BOTTOMRIGHT", filterIconBtn, "BOTTOMRIGHT", -1, 1)
    badge:SetTextColor(1, 0.30, 0.30)
    badge:Hide()
    filterIconBtn.badge = badge

    filterIconBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.16, 0.12, 0.04, 0.95)
        self:SetBackdropBorderColor(0.75, 0.58, 0.18, 1)
    end)
    filterIconBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.06, 0.05, 0.02, 0.92)
        self:SetBackdropBorderColor(0.45, 0.32, 0.08, 0.85)
        ScheduleFilterClose()
    end)
    filterIconBtn:SetScript("OnClick", function()
        local panel = BuildFilterPanel()
        if _settingsPanel then _settingsPanel:Hide() end
        if panel:IsShown() then
            panel:Hide()
        else
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", filterIconBtn, "BOTTOMLEFT", 0, -2)
            panel:Show()
        end
    end)

    -- ── Clear (×) button ─────────────────────────────────────
    local clearIconBtn = CreateFrame("Button", "BMClearIconBtn", fb, "BackdropTemplate")
    clearIconBtn:SetSize(20, 20)
    clearIconBtn:SetPoint("LEFT", filterIconBtn, "RIGHT", 3, 0)
    clearIconBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    clearIconBtn:SetBackdropColor(0.06, 0.04, 0.04, 0.92)
    clearIconBtn:SetBackdropBorderColor(0.28, 0.20, 0.05, 0.6)

    local xTex = clearIconBtn:CreateFontString(nil, "OVERLAY")
    xTex:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    xTex:SetPoint("CENTER", 0, 1)
    xTex:SetText("x")
    xTex:SetTextColor(0.50, 0.40, 0.15)
    clearIconBtn.x = xTex

    clearIconBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.18, 0.05, 0.05, 0.95)
        self:SetBackdropBorderColor(0.80, 0.20, 0.20, 1)
        xTex:SetTextColor(1, 0.40, 0.40)
    end)
    clearIconBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.06, 0.04, 0.04, 0.92)
        -- restore to active/inactive state
        UpdateFiltersBtn()
    end)

    local function DoClearFilters()
        BM.filters.name      = ""
        BM.filters.itemType  = {}
        BM.filters.timeLeft  = {}
        BM.filters.collected = {}
        BM.filters.bid       = {}
        BM.filters.watched   = {}
        searchBox:SetText("")
        if _filterPanel then
            for _, cb in pairs(_filterPanel.timeChecks  or {}) do cb.SetChecked(false) end
            for _, cb in pairs(_filterPanel.collChecks  or {}) do cb.SetChecked(false) end
            for _, cb in pairs(_filterPanel.watchChecks or {}) do cb.SetChecked(false) end
            for _, cb in pairs(_filterPanel.bidChecks or {}) do cb.SetChecked(false) end
            _filterPanel:Hide()
        end
        UpdateFiltersBtn()
        BM.RefreshMainRows()
    end
    clearIconBtn:SetScript("OnClick", DoClearFilters)

    -- Wire up to UpdateFiltersBtn for state tracking
    _filtersBtn = filterIconBtn
    _filtersBtn.badge    = badge
    _filtersBtn.clearBtn = clearIconBtn
    fb.filtersBtn = filterIconBtn
    fb.clearBtn   = clearIconBtn

    -- ── Settings (gear) button ───────────────────────────────
    local gearBtn = CreateFrame("Button", "BMGearBtn", fb, "BackdropTemplate")
    gearBtn:SetSize(20, 20)
    gearBtn:SetPoint("RIGHT", fb, "RIGHT", -4, 0)
    gearBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    gearBtn:SetBackdropColor(0.06, 0.05, 0.02, 0.92)
    gearBtn:SetBackdropBorderColor(0.45, 0.32, 0.08, 0.85)

    -- Gear icon: WoW options/settings cog texture
    local cogTex = gearBtn:CreateTexture(nil, "OVERLAY")
    cogTex:SetSize(16, 16)
    cogTex:SetPoint("CENTER", gearBtn, "CENTER", 0, 0)
    cogTex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    cogTex:SetVertexColor(0.88, 0.70, 0.22, 1)

    gearBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.16, 0.12, 0.04, 0.95)
        self:SetBackdropBorderColor(0.75, 0.58, 0.18, 1)
    end)
    gearBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.06, 0.05, 0.02, 0.92)
        self:SetBackdropBorderColor(0.45, 0.32, 0.08, 0.85)
        ScheduleSettingsClose()
    end)
    gearBtn:SetScript("OnClick", function()
        local panel = BuildSettingsPanel()
        if _filterPanel then _filterPanel:Hide() end
        if panel:IsShown() then
            panel:Hide()
        else
            panel:ClearAllPoints()
            panel:SetPoint("TOPRIGHT", gearBtn, "BOTTOMRIGHT", 0, -2)
            panel:Show()
        end
    end)
    fb.gearBtn = gearBtn

    return fb
end

-- ============================================================
-- UNIFIED ROW  (live items Â· history headers Â· history items)
-- ============================================================

local function CreateRow(parent, rowIndex)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(LIST_WIDTH, ROW_HEIGHT)
    row:EnableMouse(true)

    -- Alternating item-row bg
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(rowIndex % 2 == 0 and 0.10 or 0.07,
                       rowIndex % 2 == 0 and 0.075 or 0.053,
                       rowIndex % 2 == 0 and 0.03 or 0.02, 0.75)
    row.bg = bg

    -- Header-row bg (near-black band, shown instead of bg for group headers)
    local headerBg = row:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(0.04, 0.03, 0.02, 0.97)
    headerBg:Hide()
    row.headerBg = headerBg

    -- Coloured left-edge accent for header rows
    local accent = row:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("LEFT", row, "LEFT", 0, 0)
    accent:SetSize(4, ROW_HEIGHT)
    accent:Hide()
    row.headerAccent = accent

    local hl = row:CreateTexture(nil, "ARTWORK")
    hl:SetAllPoints()
    hl:SetColorTexture(0.15, 0.35, 0.75, 0.22)
    hl:Hide()
    row.hlTex = hl

    local sel = row:CreateTexture(nil, "ARTWORK")
    sel:SetAllPoints()
    sel:SetColorTexture(0.60, 0.48, 0.10, 0.28)
    sel:Hide()
    row.selTex = sel

    -- My-bid row highlight: green tint + left-edge accent
    local myBidBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    myBidBg:SetAllPoints()
    myBidBg:SetColorTexture(0.10, 0.45, 0.15, 0.28)
    myBidBg:Hide()
    row.myBidBg = myBidBg

    local myBidAccent = row:CreateTexture(nil, "ARTWORK")
    myBidAccent:SetPoint("TOPLEFT",    row, "TOPLEFT",    0, 0)
    myBidAccent:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    myBidAccent:SetWidth(3)
    myBidAccent:SetColorTexture(0.30, 0.90, 0.35, 1)
    myBidAccent:Hide()
    row.myBidAccent = myBidAccent

    -- Dim overlay for non-biddable history items
    local dim = row:CreateTexture(nil, "OVERLAY")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.42)
    dim:Hide()
    row.dimOverlay = dim

    local sep = row:CreateTexture(nil, "BACKGROUND")
    sep:SetPoint("BOTTOMLEFT", 0, 0)
    sep:SetPoint("BOTTOMRIGHT", 0, 0)
    sep:SetHeight(1)
    sep:SetColorTexture(0.30, 0.20, 0.06, 0.50)

    -- â"€â"€ Header-only widgets â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    local serverLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    serverLabel:SetPoint("LEFT", row, "LEFT", 14, 0)
    serverLabel:SetWidth(440)
    serverLabel:SetJustifyH("LEFT")
    row.serverLabel = serverLabel

    -- kept in pool for hide/show logic but no longer populated
    local charLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charLabel:Hide()
    row.charLabel = charLabel

    local lastSeenLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lastSeenLabel:Hide()
    row.lastSeenLabel = lastSeenLabel

    local countLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countLabel:Hide()
    row.countLabel = countLabel

    local statusBadge = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusBadge:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    statusBadge:SetWidth(180)
    statusBadge:SetJustifyH("RIGHT")
    row.statusBadge = statusBadge

    -- â"€â"€ Item widgets (live + history items) â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    local statusIcon = row:CreateTexture(nil, "OVERLAY")
    statusIcon:SetSize(16, 16)
    statusIcon:SetPoint("LEFT", row, "LEFT", COL.statusIcon, 0)
    row.statusIcon = statusIcon

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", row, "LEFT", COL.icon, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local iconBorder = row:CreateTexture(nil, "OVERLAY")
    iconBorder:SetSize(ICON_SIZE + 4, ICON_SIZE + 4)
    iconBorder:SetPoint("CENTER", icon, "CENTER")
    iconBorder:SetTexture("Interface\\Common\\WhiteIconFrame")
    row.iconBorder = iconBorder

    -- Watch (star) toggle button
    local watchBtn = CreateFrame("Button", nil, row)
    watchBtn:SetSize(22, ROW_HEIGHT)
    watchBtn:SetPoint("LEFT", row, "LEFT", COL.watch, 0)
    watchBtn:SetFrameLevel(row:GetFrameLevel() + 2)
    watchBtn:EnableMouse(true)
    watchBtn:Hide()
    local watchStar = watchBtn:CreateFontString(nil, "OVERLAY")
    watchStar:SetFont("Fonts\\2002.TTF", 14)
    watchStar:SetAllPoints()
    watchStar:SetJustifyH("CENTER")
    watchStar:SetJustifyV("MIDDLE")
    watchStar:SetText("☆")
    watchStar:SetTextColor(0.40, 0.40, 0.40)
    watchBtn.star = watchStar
    watchBtn:SetScript("OnEnter", function() row.hlTex:Show() end)
    watchBtn:SetScript("OnLeave", function() row.hlTex:Hide() end)
    row.watchBtn = watchBtn

    -- Transparent hit-area over the icon — tooltip is shown only when hovering the icon
    local iconBtn = CreateFrame("Frame", nil, row)
    iconBtn:SetSize(ICON_SIZE, ICON_SIZE)
    iconBtn:SetPoint("CENTER", icon, "CENTER")
    iconBtn:EnableMouse(true)
    iconBtn:SetFrameLevel(row:GetFrameLevel() + 5)
    row.iconBtn = iconBtn

    -- Collected/missing badge — top-right corner of the icon, with black bg like CanIMogIt
    local collectBg = iconBtn:CreateTexture(nil, "OVERLAY", nil, 6)
    collectBg:SetColorTexture(0, 0, 0, 0.80)
    collectBg:SetSize(16, 16)
    collectBg:SetPoint("TOPRIGHT", iconBtn, "TOPRIGHT", 2, 2)
    collectBg:Hide()
    row.collectBg = collectBg

    local collectIcon = iconBtn:CreateTexture(nil, "OVERLAY", nil, 7)
    collectIcon:SetSize(15, 15)
    collectIcon:SetPoint("CENTER", collectBg, "CENTER")
    collectIcon:Hide()
    row.collectIcon = collectIcon

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", row, "LEFT", COL.name, 5)
    name:SetSize(195, ROW_HEIGHT - 4)
    name:SetJustifyH("LEFT")
    name:SetJustifyV("MIDDLE")
    name:SetWordWrap(true)
    row.name = name

    local level = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    level:SetPoint("LEFT", row, "LEFT", COL.level, 0)
    level:SetWidth(28)
    level:SetJustifyH("CENTER")
    level:SetTextColor(0.9, 0.9, 0.9)
    row.level = level

    local itype = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itype:SetPoint("LEFT", row, "LEFT", COL.itemType, 0)
    itype:SetSize(82, ROW_HEIGHT)
    itype:SetJustifyH("LEFT")
    itype:SetJustifyV("MIDDLE")
    itype:SetWordWrap(true)
    itype:SetTextColor(0.9, 0.9, 0.9)
    row.itemType = itype

    local tl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tl:SetPoint("LEFT", row, "LEFT", COL.timeLeft, 0)
    tl:SetWidth(104)
    tl:SetJustifyH("LEFT")
    tl:SetTextColor(0.9, 0.9, 0.9)
    row.timeLeft = tl

    local seller = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    seller:SetPoint("LEFT", row, "LEFT", COL.seller, 0)
    seller:SetSize(56, ROW_HEIGHT)
    seller:SetJustifyH("LEFT")
    seller:SetJustifyV("MIDDLE")
    seller:SetWordWrap(true)
    seller:SetTextColor(0.9, 0.9, 0.9)
    row.seller = seller

    local numBids = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    numBids:SetPoint("LEFT", row, "LEFT", COL.numBids, 0)
    numBids:SetWidth(34)
    numBids:SetJustifyH("CENTER")
    numBids:SetTextColor(0.9, 0.9, 0.9)
    row.numBids = numBids

    local bid = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bid:SetPoint("LEFT", row, "LEFT", COL.bid, 4)
    bid:SetWidth(60)
    bid:SetJustifyH("RIGHT")
    bid:SetTextColor(1, 0.85, 0)
    row.bid = bid

    local goldIcon = row:CreateTexture(nil, "OVERLAY")
    goldIcon:SetSize(14, 14)
    goldIcon:SetPoint("LEFT", row, "LEFT", COL.goldIcon, 0)
    goldIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    row.goldIcon = goldIcon

    -- "Your Bid!" label — shown above the bid price when the player holds the high bid
    local yourBid = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yourBid:SetPoint("BOTTOMRIGHT", bid, "TOPRIGHT", 0, 1)
    yourBid:SetWidth(80)
    yourBid:SetJustifyH("RIGHT")
    yourBid:SetTextColor(1, 0.85, 0.10, 1)
    yourBid:SetText("Your Bid!")
    yourBid:Hide()
    row.yourBid = yourBid

    -- "Updated X ago" (history items only)
    local updated = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    updated:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    updated:SetWidth(90)
    updated:SetJustifyH("RIGHT")
    updated:SetTextColor(0.50, 0.50, 0.50)
    updated:Hide()
    row.updated = updated

    -- References keyed by column for ApplyColumnLayout / ApplyColVisibility
    row.colFS = {
        name     = name,
        level    = level,
        itemType = itype,
        timeLeft = tl,
        seller   = seller,
        numBids  = numBids,
        bid      = bid,
    }

    return row
end

-- ============================================================
-- SCROLL FRAME + ROWS
-- ============================================================

local MAX_POOL_ROWS = 25   -- enough for any realistic window height

local function CreateScrollArea(parent)
    local sf = CreateFrame("ScrollFrame", "BMScrollFrame", parent)
    sf:SetPoint("TOPLEFT",  parent, "TOPLEFT",  8,   -100)
    sf:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -26, -100)
    sf:SetHeight(MAX_VISIBLE_ROWS * ROW_HEIGHT)

    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(LIST_WIDTH, MAX_POOL_ROWS * ROW_HEIGHT)
    sf:SetScrollChild(content)

    -- Scrollbar: slider top at y=-70 so the UIPanelScrollBarTemplate up-arrow
    -- (which renders 16px ABOVE the slider top) lands at y=-54 (filter bar top).
    local sb = CreateFrame("Slider", "BMScrollBar", parent, "UIPanelScrollBarTemplate")
    sb:SetPoint("TOPLEFT",    parent, "TOPRIGHT", -24, -70)
    sb:SetPoint("BOTTOMLEFT", sf,     "BOTTOMRIGHT", 2,  16)
    sb:SetMinMaxValues(0, 0)
    sb:SetValueStep(ROW_HEIGHT)
    sb:SetObeyStepOnDrag(true)
    sb:SetValue(0)
    sb:SetScript("OnValueChanged", function(self, val)
        sf:SetVerticalScroll(val)
        BM.RefreshMainRows()
    end)

    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = sb:GetValue()
        local mn, mx = sb:GetMinMaxValues()
        sb:SetValue(math.max(mn, math.min(mx, cur - delta * ROW_HEIGHT)))
    end)

    -- Pooled rows — enough for the largest supported window height
    local rows = {}
    for i = 1, MAX_POOL_ROWS do
        local row = CreateRow(content, i)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        rows[i] = row
    end

    return sf, content, sb, rows
end

-- ============================================================
-- DETAIL PANEL  ("Hot Item!")
-- ============================================================

local function CreateDetailPanel(parent)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -54)
    p:SetSize(DETAIL_WIDTH, MAIN_HEIGHT - 112)
    p:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    p:SetBackdropColor(0.05, 0.038, 0.015, 0.97)
    p:SetBackdropBorderColor(0.35, 0.24, 0.06, 0.9)

    -- "Hot Item!" header band
    local hotBg = p:CreateTexture(nil, "BACKGROUND")
    hotBg:SetPoint("TOPLEFT", p, "TOPLEFT", 5, -5)
    hotBg:SetPoint("TOPRIGHT", p, "TOPRIGHT", -5, -5)
    hotBg:SetHeight(42)
    hotBg:SetColorTexture(0.14, 0.10, 0.03, 0.92)

    local hotTitle = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hotTitle:SetPoint("TOP", p, "TOP", 0, -18)
    hotTitle:SetText("|cffffd700Hot Item!|r")

    -- Large item icon frame
    local iconHolder = CreateFrame("Frame", nil, p, "BackdropTemplate")
    iconHolder:SetSize(58, 58)
    iconHolder:SetPoint("TOP", p, "TOP", 0, -58)
    iconHolder:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    iconHolder:SetBackdropColor(0, 0, 0, 1)
    iconHolder:SetBackdropBorderColor(0.64, 0.21, 0.93, 1)
    p.iconHolder = iconHolder

    local icon = iconHolder:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    p.icon = icon

    -- Item name
    local itemName = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemName:SetPoint("TOP", iconHolder, "BOTTOM", 0, -8)
    itemName:SetWidth(DETAIL_WIDTH - 20)
    itemName:SetJustifyH("CENTER")
    itemName:SetWordWrap(true)
    p.itemName = itemName

    -- Level + Type line
    local levelType = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelType:SetPoint("TOP", itemName, "BOTTOM", 0, -4)
    levelType:SetWidth(DETAIL_WIDTH - 20)
    levelType:SetJustifyH("CENTER")
    levelType:SetTextColor(0.88, 0.88, 0.88)
    p.levelType = levelType

    -- Separator
    local sep = p:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOP", levelType, "BOTTOM", 0, -10)
    sep:SetSize(DETAIL_WIDTH - 28, 1)
    sep:SetColorTexture(0.42, 0.30, 0.08, 0.65)

    -- Seller
    local sellerLbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sellerLbl:SetPoint("TOP", sep, "BOTTOM", 0, -12)
    sellerLbl:SetWidth(DETAIL_WIDTH - 20)
    sellerLbl:SetJustifyH("CENTER")
    sellerLbl:SetTextColor(0.88, 0.88, 0.88)
    sellerLbl:SetText("Seller:")
    p.sellerLbl = sellerLbl

    local sellerName = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sellerName:SetPoint("TOP", sellerLbl, "BOTTOM", 0, -2)
    sellerName:SetWidth(DETAIL_WIDTH - 20)
    sellerName:SetJustifyH("CENTER")
    sellerName:SetTextColor(1, 1, 1)
    sellerName:SetWordWrap(true)
    p.sellerName = sellerName

    -- Time left
    local timeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeLabel:SetPoint("TOP", sellerName, "BOTTOM", 0, -10)
    timeLabel:SetWidth(DETAIL_WIDTH - 20)
    timeLabel:SetJustifyH("CENTER")
    timeLabel:SetTextColor(0.88, 0.88, 0.88)
    p.timeLabel = timeLabel

    -- Current bid
    local bidLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bidLabel:SetPoint("TOP", timeLabel, "BOTTOM", 0, -10)
    bidLabel:SetWidth(DETAIL_WIDTH - 20)
    bidLabel:SetJustifyH("CENTER")
    bidLabel:SetTextColor(0.88, 0.88, 0.88)
    p.bidLabel = bidLabel

    -- "Your Bid!" tag
    local yourBid = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yourBid:SetPoint("TOP", bidLabel, "BOTTOM", 0, -2)
    yourBid:SetWidth(DETAIL_WIDTH - 20)
    yourBid:SetJustifyH("CENTER")
    yourBid:SetTextColor(1, 0.85, 0)
    yourBid:SetText("|cffffd700Your Bid!|r")
    yourBid:Hide()
    p.yourBid = yourBid

    p:Hide()
    return p
end

-- ============================================================
-- BOTTOM BAR (money + bid input + button)
-- ============================================================

local function CreateBottomBar(parent)
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 6, 6)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 6)
    bar:SetHeight(38)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bar:SetBackdropColor(0.10, 0.07, 0.025, 0.92)
    bar:SetBackdropBorderColor(0.38, 0.27, 0.08, 0.85)

    -- Player money — auto-sized to content so bid input anchors flush against it
    local moneyText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    moneyText:SetJustifyH("LEFT")
    bar.moneyText = moneyText

    -- Bid cluster: all fixed sizes, anchored from the right edge
    local bidBtn = CreateFrame("Button", "BMBidButton", bar, "UIPanelButtonTemplate")
    bidBtn:SetSize(80, 26)
    bidBtn:SetText("Bid")
    bidBtn:SetEnabled(false)
    bar.bidBtn = bidBtn

    local goldIcon = bar:CreateTexture(nil, "OVERLAY")
    goldIcon:SetSize(16, 16)
    goldIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")

    local bidInput = CreateFrame("EditBox", "BMBidInput", bar, "InputBoxTemplate")
    bidInput:SetSize(110, 20)
    bidInput:SetAutoFocus(false)
    bidInput:SetNumeric(true)
    bidInput:SetMaxLetters(10)
    bar.bidInput = bidInput

    -- Layout:
    --   Single-row: money LEFT | bid+icon CENTERED | Bid+Refresh RIGHT
    --     Gap on both sides of the centered group compresses as window shrinks.
    --   Double-row: top = money LEFT + bid+icon RIGHT  |  bottom = Bid+Refresh RIGHT
    --
    -- Bid group (input 110 + gap 4 + icon 16) = 130px; centered offset = -10 (shifts group center left)
    -- Right group: 80(Bid) + 8(margin) = 88px
    -- WRAP_AT: only wrap if the bar gets extremely narrow (columns hidden etc.)
    local WRAP_AT  = 280
    local SINGLE_H = 38
    local DOUBLE_H = 68
    bar.isDoubleRow = nil  -- nil forces initial layout pass

    local function ApplyLayout(barW)
        local doDouble = (barW < WRAP_AT)
        if doDouble == bar.isDoubleRow then return end
        bar.isDoubleRow = doDouble

        bar:SetHeight(doDouble and DOUBLE_H or SINGLE_H)

        if doDouble then
            -- Top row: money LEFT, bid input + gold icon RIGHT
            moneyText:ClearAllPoints()
            moneyText:SetPoint("LEFT", bar, "LEFT", 10, 17)

            goldIcon:ClearAllPoints()
            goldIcon:SetPoint("RIGHT", bar, "RIGHT", -8, 17)

            bidInput:ClearAllPoints()
            bidInput:SetPoint("RIGHT", goldIcon, "LEFT", -4, 0)

            -- Bottom row: Bid RIGHT
            bidBtn:ClearAllPoints()
            bidBtn:SetPoint("RIGHT", bar, "RIGHT", -8, -17)
        else
            -- Single row: money LEFT | [bidInput + goldIcon] CENTERED | Bid RIGHT
            moneyText:ClearAllPoints()
            moneyText:SetPoint("LEFT", bar, "LEFT", 10, 0)

            bidInput:ClearAllPoints()
            bidInput:SetPoint("CENTER", bar, "CENTER", -10, 0)

            goldIcon:ClearAllPoints()
            goldIcon:SetPoint("LEFT", bidInput, "RIGHT", 4, 0)

            bidBtn:ClearAllPoints()
            bidBtn:SetPoint("RIGHT", bar, "RIGHT", -8, 0)
        end
    end

    bar.ApplyLayout = ApplyLayout
    ApplyLayout(MAIN_WIDTH - 12)

    return bar
end

-- ============================================================
-- UNIFIED ROW RENDERING + VIRTUAL LIST
-- ============================================================

-- Icon textures (copied from CanIMogIt — no runtime dependency on that addon).
-- Indexed by [base_status][bind_type].  Simple statuses (mounts/pets/toys) use
-- a plain string rather than a nested table.
local ICON_BASE = "Interface\\Addons\\BlackMarket\\Icons\\"
local COLLECT_ICONS = {
    -- Transmog: this char has this exact source
    known = {
        bop      = ICON_BASE .. "KNOWN",
        boe      = ICON_BASE .. "KNOWN_BOE",
        warbound = ICON_BASE .. "KNOWN_WARBOUND",
    },
    -- Transmog: appearance known from a *different* item source
    known_other_item = {
        bop      = ICON_BASE .. "KNOWN_circle",
        boe      = ICON_BASE .. "KNOWN_BOE_circle",
        warbound = ICON_BASE .. "KNOWN_WARBOUND_circle",
    },
    -- Transmog: this source known, but appearance is class-restricted to another char
    known_other_char = {
        bop      = ICON_BASE .. "KNOWN_BOP",
        boe      = ICON_BASE .. "KNOWN_BOE",      -- yellow check (CanIMogIt uses same icon)
        warbound = ICON_BASE .. "KNOWN_WARBOUND",
    },
    -- Transmog: different source AND class-restricted to another char
    known_other_both = {
        bop      = ICON_BASE .. "KNOWN_BOP_circle",
        boe      = ICON_BASE .. "KNOWN_BOE_circle",
        warbound = ICON_BASE .. "KNOWN_WARBOUND_circle",
    },
    -- Not yet collected but collectible (transmog, mount, toy, pet)
    learnable   = ICON_BASE .. "UNKNOWN",
    -- Already have it (mounts, pets, toys — no bind variant needed)
    collected   = ICON_BASE .. "KNOWN",
}

local function GetCollectIconPath(base, bind)
    if not base then return nil end
    local entry = COLLECT_ICONS[base]
    if type(entry) == "table" then
        return entry[bind or "bop"]
    end
    return entry
end

-- Returns the item's bind type: "bop", "boe", or "warbound".
-- bindType from GetItemInfo: 1=BOP, 2=BOE, 3=BOA(warbound), 4=BNET(warbound)
local function GetItemBindType(itemLink)
    if not itemLink then return "bop" end
    local bindType = select(14, GetItemInfo(itemLink))
    if bindType == 2 then return "boe" end
    if bindType == 3 or bindType == 4 then return "warbound" end
    return "bop"
end

-- Returns (base, bind) describing the collection state of this item.
--
--  base: "known"            — this char has this exact transmog source
--        "known_other_item" — appearance in wardrobe from a different source
--        "known_other_char" — source known, but appearance class-locked to another char
--        "known_other_both" — different source + class-locked
--        "learnable"        — not collected; can learn (transmog, mount, toy, pet)
--        "collected"        — already own it (mount, toy, pet)
--        nil                — not a collectible (containers, currency, etc.)
--
--  bind: "bop" | "boe" | "warbound"  (nil for non-transmog statuses)
--
-- Mirrors CanIMogIt's AppearanceData:CalculateKnownStatus() + CalculateBindStateText().
GetCollectedStatus = function(itemLink, typeLabel)
    if not itemLink then return nil end
    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if not itemID then return nil end

    -- Mounts
    if typeLabel == "Mount" then
        if C_MountJournal and C_MountJournal.GetMountFromItem then
            local mountID = C_MountJournal.GetMountFromItem(itemID)
            if mountID and mountID > 0 then
                local isCollected = select(11, C_MountJournal.GetMountInfoByID(mountID))
                return isCollected and "collected" or "learnable"
            end
        end
        return nil
    end

    -- Toys: detect by API (BMAH typeLabel may not read "Toy")
    if C_ToyBox and C_ToyBox.GetToyInfo then
        if C_ToyBox.GetToyInfo(itemID) then
            return PlayerHasToy(itemID) and "collected" or "learnable"
        end
    end

    -- Battle pets
    if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
        if C_PetJournal.GetPetInfoByItemID(itemID) then
            local speciesID = select(13, C_PetJournal.GetPetInfoByItemID(itemID))
            if speciesID then
                return C_PetJournal.GetNumCollectedInfo(speciesID) > 0 and "collected" or "learnable"
            end
        end
    end

    -- Transmog: full CanIMogIt-style status with bind type
    if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
        local sourceID = select(2, C_TransmogCollection.GetItemInfo(itemLink))
        if not sourceID or sourceID == 0 then return nil end

        local bind = GetItemBindType(itemLink)

        -- Does this character have this specific source?
        local knowsFromItem = C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance(sourceID)

        -- Appearance info: needed for class-validity and appearance ID
        local appearanceInfo = C_TransmogCollection.GetAppearanceSourceInfo and
                               C_TransmogCollection.GetAppearanceSourceInfo(sourceID)

        -- Is the appearance valid for this character's class/armor type?
        local isValidForChar = (appearanceInfo == nil) or
                               (appearanceInfo.isAnySourceValidForPlayer ~= false)

        -- Does this char know the appearance from a *different* source?
        local knowsFromOtherSource = false
        if not knowsFromItem and appearanceInfo then
            local appearanceID = appearanceInfo.itemAppearanceID
            if appearanceID and C_TransmogCollection.GetAllAppearanceSources then
                local allSources = C_TransmogCollection.GetAllAppearanceSources(appearanceID)
                if allSources then
                    for _, sid in ipairs(allSources) do
                        if sid ~= sourceID and
                           C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance(sid) then
                            knowsFromOtherSource = true
                            break
                        end
                    end
                end
            end
        end

        if knowsFromItem then
            return isValidForChar and "known" or "known_other_char", bind
        elseif knowsFromOtherSource then
            return isValidForChar and "known_other_item" or "known_other_both", bind
        else
            return "learnable", bind
        end
    end

    return nil
end

local function ApplyCollectIcon(row, itemLink, typeLabel)
    local base, bind = GetCollectedStatus(itemLink, typeLabel)
    local tex = GetCollectIconPath(base, bind)
    if tex then
        row.collectIcon:SetTexture(tex)
        row.collectIcon:SetVertexColor(1, 1, 1, 1)
        row.collectIcon:Show()
        row.collectBg:Show()
    else
        row.collectIcon:Hide()
        row.collectBg:Hide()
    end
end

-- Populate a row frame as a live BMAH item
local function RenderLiveItem(row, data)
    row.bg:Show() ; row.headerBg:Hide() ; row.headerAccent:Hide()
    row.serverLabel:Hide() ; row.charLabel:Hide()
    row.lastSeenLabel:Hide() ; row.countLabel:Hide() ; row.statusBadge:Hide()
    row.dimOverlay:Hide()
    row.icon:Show() ; row.iconBorder:Show()
    ApplyColVisibility(row)
    row.updated:Hide()

    row.icon:SetTexture(data.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    local r, g, b = QualityColor(data.quality)
    row.iconBorder:SetVertexColor(r, g, b, 1)

    row.statusIcon:SetTexture(nil)
    if data.isHighBid then
        row.myBidBg:Show()
        row.myBidAccent:Show()
        row.yourBid:Show()
        -- shift price + gold icon down so the two-line block is vertically centered
        row.bid:ClearAllPoints()
        row.bid:SetPoint("LEFT", row, "LEFT", COL.bid, -5)
        row.goldIcon:ClearAllPoints()
        row.goldIcon:SetPoint("LEFT", row, "LEFT", COL.goldIcon, -5)
    else
        row.myBidBg:Hide()
        row.myBidAccent:Hide()
        row.yourBid:Hide()
        row.bid:ClearAllPoints()
        row.bid:SetPoint("LEFT", row, "LEFT", COL.bid, 0)
        row.goldIcon:ClearAllPoints()
        row.goldIcon:SetPoint("LEFT", row, "LEFT", COL.goldIcon, 0)
    end

    row.name:SetText(string.format("|cff%s%s|r", QualityHex(data.quality), data.name or "Unknown"))
    row.level:SetText((data.itemLevel and data.itemLevel > 0) and tostring(data.itemLevel) or "")
    row.itemType:SetText(data.typeLabel or "")
    row.timeLeft:SetText(FormatEstimatedTime(data.timeEstimate, data.timeLeft))
    row.seller:SetText(data.sellerName or "")
    row.numBids:SetText(data.numBids and tostring(data.numBids) or "")
    local bidAmt = (data.currentBid and data.currentBid > 0) and data.currentBid or (data.nextMinBid or 0)
    row.bid:SetText(GoldText(bidAmt))
    ApplyCollectIcon(row, data.itemLink, data.typeLabel)

    -- Watch star
    if BM.colVisible and BM.colVisible.watch ~= false then
        local watchKey = data.itemLink and data.firstSeen and (data.itemLink .. "|" .. tostring(data.firstSeen)) or data.itemLink
        local isWatched = watchKey and BlackMarketDB.watched and BlackMarketDB.watched[watchKey]
        row.watchBtn.star:SetText(isWatched and "★" or "☆")
        row.watchBtn.star:SetTextColor(
            isWatched and 1    or 0.40,
            isWatched and 0.82 or 0.40,
            isWatched and 0.20 or 0.40)
        row.watchBtn:SetScript("OnClick", function()
            if not watchKey then return end
            BlackMarketDB.watched = BlackMarketDB.watched or {}
            if BlackMarketDB.watched[watchKey] then
                BlackMarketDB.watched[watchKey] = nil
            else
                BlackMarketDB.watched[watchKey] = true
            end
            BM.RefreshMainRows()
        end)
        row.watchBtn:Show()
    else
        row.watchBtn:Hide()
    end

    -- Tooltip and modifier-click on icon
    local captLink = data.itemLink
    row.iconBtn:SetScript("OnMouseUp", function()
        HandleItemModifierClick(captLink)
    end)
    row.iconBtn:SetScript("OnEnter", function(self)
        row.hlTex:Show()
        if captLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(captLink)
            GameTooltip:Show()
        end
    end)
    row.iconBtn:SetScript("OnLeave", function()
        row.hlTex:Hide()
        GameTooltip:Hide()
    end)
end

-- Populate a row frame as a history item (dimmed if not biddable)
local function RenderHistItem(row, data, canBid)
    row.bg:Show() ; row.headerBg:Hide() ; row.headerAccent:Hide()
    row.serverLabel:Hide() ; row.charLabel:Hide()
    row.lastSeenLabel:Hide() ; row.countLabel:Hide() ; row.statusBadge:Hide()
    row.statusIcon:SetTexture(nil)
    row.icon:Show() ; row.iconBorder:Show()
    ApplyColVisibility(row)
    row.updated:Hide()

    row.icon:SetTexture(data.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    local r, g, b = QualityColor(data.quality)
    row.iconBorder:SetVertexColor(r, g, b, canBid and 1 or 0.5)

    if data.isHighBid then
        row.myBidBg:Show()
        row.myBidAccent:Show()
        row.yourBid:Show()
        row.bid:ClearAllPoints()
        row.bid:SetPoint("LEFT", row, "LEFT", COL.bid, -5)
        row.goldIcon:ClearAllPoints()
        row.goldIcon:SetPoint("LEFT", row, "LEFT", COL.goldIcon, -5)
    else
        row.myBidBg:Hide()
        row.myBidAccent:Hide()
        row.yourBid:Hide()
        row.bid:ClearAllPoints()
        row.bid:SetPoint("LEFT", row, "LEFT", COL.bid, 0)
        row.goldIcon:ClearAllPoints()
        row.goldIcon:SetPoint("LEFT", row, "LEFT", COL.goldIcon, 0)
    end

    row.name:SetText(string.format("|cff%s%s|r", QualityHex(data.quality), data.name or "Unknown"))
    row.level:SetText((data.itemLevel and data.itemLevel > 0) and tostring(data.itemLevel) or "")
    row.itemType:SetText(data.typeLabel or "")
    row.timeLeft:SetText(FormatEstimatedTime(data.timeEstimate, data.timeLeft))
    row.seller:SetText(data.sellerName or "")
    row.numBids:SetText(data.numBids and tostring(data.numBids) or "")
    local bidAmt = (data.currentBid and data.currentBid > 0) and data.currentBid or (data.nextMinBid or 0)
    row.bid:SetText(GoldText(bidAmt))
    ApplyCollectIcon(row, data.itemLink, data.typeLabel)

    if canBid then
        row.dimOverlay:Hide()
    else
        row.dimOverlay:Show()
    end

    -- Watch star
    if BM.colVisible and BM.colVisible.watch ~= false then
        local watchKey = data.itemLink and data.firstSeen and (data.itemLink .. "|" .. tostring(data.firstSeen)) or data.itemLink
        local isWatched = watchKey and BlackMarketDB.watched and BlackMarketDB.watched[watchKey]
        row.watchBtn.star:SetText(isWatched and "★" or "☆")
        row.watchBtn.star:SetTextColor(
            isWatched and 1    or 0.40,
            isWatched and 0.82 or 0.40,
            isWatched and 0.20 or 0.40)
        row.watchBtn:SetScript("OnClick", function()
            if not watchKey then return end
            BlackMarketDB.watched = BlackMarketDB.watched or {}
            if BlackMarketDB.watched[watchKey] then
                BlackMarketDB.watched[watchKey] = nil
            else
                BlackMarketDB.watched[watchKey] = true
            end
            BM.RefreshMainRows()
        end)
        row.watchBtn:Show()
    else
        row.watchBtn:Hide()
    end

    -- Tooltip and modifier-click on icon
    local captLink = data.itemLink
    row.iconBtn:SetScript("OnMouseUp", function()
        HandleItemModifierClick(captLink)
    end)
    row.iconBtn:SetScript("OnEnter", function(self)
        row.hlTex:Show()
        if captLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(captLink)
            GameTooltip:Show()
        end
    end)
    row.iconBtn:SetScript("OnLeave", function()
        row.hlTex:Hide()
        GameTooltip:Hide()
    end)
end

-- Populate a row frame as a server group header
local function RenderHeader(row, rd)
    row.headerBg:Show() ; row.bg:Hide() ; row.dimOverlay:Hide()
    row.selTex:Hide()
    row.icon:Hide() ; row.iconBorder:Hide() ; row.name:Hide()
    row.level:Hide() ; row.itemType:Hide() ; row.timeLeft:Hide()
    row.seller:Hide() ; row.numBids:Hide() ; row.bid:Hide() ; row.goldIcon:Hide()
    row.statusIcon:SetTexture(nil) ; row.yourBid:Hide() ; row.myBidBg:Hide() ; row.myBidAccent:Hide() ; row.updated:Hide()
    row.watchBtn:Hide()
    row.collectIcon:Hide() ; row.collectBg:Hide()
    row.charLabel:Hide() ; row.lastSeenLabel:Hide() ; row.countLabel:Hide()
    row.serverLabel:Show() ; row.statusBadge:Show()
    row.headerAccent:Show()
    row.hlTex:Hide()
    row.watchBtn:Hide()
    row:EnableMouse(false)
    row:SetScript("OnClick", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    row.iconBtn:SetScript("OnEnter", nil)
    row.iconBtn:SetScript("OnLeave", nil)

    -- Class-colored character name
    local classColor = rd.charClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[rd.charClass]
    local nameStr
    if classColor then
        nameStr = "|c" .. classColor.colorStr .. (rd.charName or "Unknown") .. "|r"
    else
        nameStr = "|cffc8c8c8" .. (rd.charName or "Unknown") .. "|r"
    end

    local timeStr  = FormatTimeSince(rd.lastSeen)
    local combined = nameStr
        .. " |cff888888-|r "
        .. "|cffcccccc" .. (rd.serverName or "Unknown") .. "|r"
        .. " |cff888888(" .. timeStr .. ")|r"
        .. " |cff888888-|r "
        .. "|cff888888" .. rd.count .. " item(s)|r"

    if rd.isLive then
        row.headerAccent:SetColorTexture(0, 1, 0.4, 0.9)
        row.statusBadge:SetText(
            "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14:0:0|t |cff00ff00LIVE|r")
    elseif rd.isCurrent then
        row.headerAccent:SetColorTexture(1, 0.85, 0, 0.9)
        row.statusBadge:SetText(
            "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14:0:0|t |cffffff00Your Server|r")
    else
        row.headerAccent:SetColorTexture(1, 0.25, 0.25, 0.7)
        row.statusBadge:SetText(
            "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14:0:0|t |cffff5555Other Server|r")
    end

    row.serverLabel:SetText(combined)
end

-- Build flat virtual list: live items first, then history groups
-- Sort key for time-remaining: use minExpiry when available, bracket min otherwise.
local function ItemTimeSortKey(item)
    local est = item.timeEstimate
    if est and est.minExpiry and est.minExpiry > 0 then
        return est.minExpiry
    end
    local range = BRACKET_RANGES[item.timeLeft or 0]
    return range and (time() + range.min) or math.huge
end

function BM.BuildCombinedList()
    local list = {}
    local currentKey = GetSessionKey()

    -- Live section (only when at BMAH and there are items)
    if BM.isAtBMAH and BM.numItems > 0 then
        local _, realm, char = GetSessionKey()
        local _, charClass = UnitClass("player")
        local liveItems = {}
        for i = 1, BM.numItems do
            if BM.items[i] and ItemMatchesFilters(BM.items[i]) then
                table.insert(liveItems, { rowType = "live_item", item = BM.items[i], dataIndex = i })
            end
        end
        if #liveItems > 0 then
            table.sort(liveItems, function(a, b)
                return ItemTimeSortKey(a.item) < ItemTimeSortKey(b.item)
            end)
            table.insert(list, {
                rowType    = "header",
                serverName = realm,
                charName   = char,
                charClass  = charClass,
                lastSeen   = time(),
                isCurrent  = true,
                isLive     = true,
                count      = #liveItems,
            })
            for _, row in ipairs(liveItems) do table.insert(list, row) end
        end
    end

    -- History section
    if not BlackMarketDB or not BlackMarketDB.history then return list end

    local sessions = {}
    for key, session in pairs(BlackMarketDB.history) do
        table.insert(sessions, { key = key, session = session })
    end
    table.sort(sessions, function(a, b)
        if a.key == currentKey then return true  end
        if b.key == currentKey then return false end
        return (a.session.lastSeen or 0) > (b.session.lastSeen or 0)
    end)

    for _, entry in ipairs(sessions) do
        local key     = entry.key
        local session = entry.session
        local isCurrent = (key == currentKey)

        -- While live at the BMAH, skip current server's snapshot (live rows already show it)
        if isCurrent and BM.isAtBMAH and BM.numItems > 0 then
        else
            local histItems = {}
            for _, item in pairs(session.auctions or {}) do
                if not item.serverName then item.serverName = session.serverName end
                if ItemMatchesFilters(item) then
                    table.insert(histItems, item)
                end
            end
            if #histItems > 0 then
                table.sort(histItems, function(a, b)
                    return ItemTimeSortKey(a) < ItemTimeSortKey(b)
                end)
                table.insert(list, {
                    rowType    = "header",
                    serverName = session.serverName or "Unknown",
                    charName   = session.charName   or "Unknown",
                    charClass  = session.charClass,
                    lastSeen   = session.lastSeen,
                    isCurrent  = isCurrent,
                    isLive     = false,
                    count      = #histItems,
                })
                for _, item in ipairs(histItems) do
                    table.insert(list, {
                        rowType   = "hist_item",
                        item      = item,
                        isCurrent = isCurrent,
                    })
                end
            end
        end
    end
    return list
end

-- Render the visible slice of the combined list into the row pool
function BM.RefreshMainRows()
    if not BM.scrollFrame then return end
    if BM.layoutDirty then
        BM.layoutDirty = false
        ApplyColumnLayout(ComputeColumnWidths(), BM.colVisible)
    end
    local list   = BM.BuildCombinedList()
    local total  = #list
    local areaH = BM.scrollAreaHeight or (MAX_VISIBLE_ROWS * ROW_HEIGHT)
    local visibleRows = math.max(1, math.floor(areaH / ROW_HEIGHT))
    local maxScroll = math.max(0, (total - visibleRows) * ROW_HEIGHT)
    BM.scrollBar:SetMinMaxValues(0, maxScroll)

    local offset = math.floor((BM.scrollBar:GetValue() or 0) / ROW_HEIGHT)

    for i = 1, #BM.rows do
        local rd  = list[offset + i]
        local row = BM.rows[i]

        if not rd then
            row:Hide()
        elseif rd.rowType == "header" then
            row:Show()
            RenderHeader(row, rd)

        elseif rd.rowType == "live_item" then
            row:Show()
            local data = rd.item
            RenderLiveItem(row, data)

            if rd.dataIndex == BM.selectedIndex then
                row.selTex:Show()
            else
                row.selTex:Hide()
            end

            local capturedIdx  = rd.dataIndex
            local capturedData = data
            row:EnableMouse(true)
            row:SetScript("OnClick", function()
                if HandleItemModifierClick(capturedData.itemLink) then return end
                BM.selectedIndex = capturedIdx
                BM.UpdateDetail(capturedData)
                BM.UpdateBidSuggestion(capturedData)
                BM.RefreshMainRows()
            end)
            row:SetScript("OnEnter", function() row.hlTex:Show() end)
            row:SetScript("OnLeave", function() row.hlTex:Hide() end)

        elseif rd.rowType == "hist_item" then
            row:Show()
            local item = rd.item
            RenderHistItem(row, item, false)
            row.selTex:Hide()
            row:EnableMouse(true)
            row:SetScript("OnClick", function()
                HandleItemModifierClick(item.itemLink)
            end)
            row:SetScript("OnEnter", function() row.hlTex:Show() end)
            row:SetScript("OnLeave", function() row.hlTex:Hide() end)
        end
    end
end

-- Legacy alias used by UpdateDetail / UpdateBidSuggestion paths
BM.UpdateVisibleRows = BM.RefreshMainRows

function BM.UpdateDetail(data)
    if not data or not BM.detailPanel then return end
    -- panel is intentionally hidden; data is captured but not displayed
    if not BM.detailPanel:IsShown() then return end
    BM.detailPanel:Show()

    -- Icon
    BM.detailPanel.icon:SetTexture(data.texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Border quality color
    local r, g, b = QualityColor(data.quality)
    BM.detailPanel.iconHolder:SetBackdropBorderColor(r, g, b, 1)

    -- Name
    BM.detailPanel.itemName:SetText(
        string.format("|cff%s%s|r", QualityHex(data.quality), data.name or "Unknown")
    )

    -- Level + Type
    local lvl = (data.itemLevel and data.itemLevel > 0) and tostring(data.itemLevel) or ""
    BM.detailPanel.levelType:SetText(lvl .. "  " .. (data.typeLabel or ""))

    -- Seller
    BM.detailPanel.sellerName:SetText(data.sellerName or "Unknown")

    -- Time left (estimated)
    BM.detailPanel.timeLabel:SetText(
        "Est. Expires: " .. FormatEstimatedTime(data.timeEstimate, data.timeLeft))

    -- Current bid (fall back to nextMinBid/starting price when no bids placed yet)
    local bidAmt  = (data.currentBid and data.currentBid > 0) and data.currentBid or (data.nextMinBid or 0)
    local goldStr = GoldText(bidAmt)
    BM.detailPanel.bidLabel:SetText(
        "Current Bid: |cffffd700" .. goldStr .. "|r|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t"
    )

    -- Your Bid
    if data.isHighBid then
        BM.detailPanel.yourBid:Show()
    else
        BM.detailPanel.yourBid:Hide()
    end
end

function BM.UpdateBidSuggestion(data)
    if not data or (data.timeLeft or 0) == 0 then
        BM.bottomBar.bidBtn:SetEnabled(false)
        BM.bottomBar.bidInput:SetText("")
        return
    end
    local minGold = math.ceil((data.nextMinBid or 0) / 10000)
    BM.bottomBar.bidInput:SetText(tostring(minGold))
    BM.bottomBar.bidBtn:SetEnabled(true)
end

function BM.UpdateMoneyDisplay()
    BM.bottomBar.moneyText:SetText(PlayerMoneyString())
end

function BM.RefreshList()
    -- Capture and clear the auto-refresh flag. When true, the bracket values from
    -- GetItemInfoByIndex are stale (server only refreshes them on NPC interaction),
    -- so we must NOT re-anchor the time estimate — that would push minExpiry forward
    -- on every background tick and corrupt the narrowing logic.
    local isAutoRefresh = BM.isAutoRefresh
    BM.isAutoRefresh    = false

    BM.items    = {}
    BM.numItems = C_BlackMarket.GetNumItems() or 0

    for i = 1, BM.numItems do
        -- Confirmed field order from /bmdebug on Midnight 12.0.5 (17 return values):
        -- [1]  name           [2]  texture        [3]  quantity
        -- [4]  typeLabel      [5]  hasBeenActive  [6]  itemLevel
        -- [7]  _reqLabel(skip)[8]  sellerName     [9]  nextMinBid (next minimum to beat)
        -- [10] minIncrement   [11] currentBid     [12] isHighBid
        -- [13] numBids        [14] timeLeft        [15] itemLink
        -- [16] marketID       [17] quality
        local name, texture, quantity, typeLabel, hasBeenActive,
              itemLevel, _, sellerName, nextMinBid, minIncrement,
              currentBid, isHighBid, numBids, timeLeft, itemLink,
              marketID, quality = C_BlackMarket.GetItemInfoByIndex(i)

        if name ~= nil then
            -- Pull existing timeEstimate, prior numBids, prior bracket, and firstSeen
            local existingEst  = nil
            local prevNumBids  = nil
            local prevTimeLeft = nil
            local firstSeen    = time()   -- default: first time we're seeing this item
            if BlackMarketDB and BlackMarketDB.history then
                local key = GetSessionKey()
                local sess = BlackMarketDB.history[key]
                if sess and sess.auctions then
                    local prev = itemLink and sess.auctions[itemLink]
                    if prev then
                        existingEst  = prev.timeEstimate
                        prevNumBids  = prev.numBids
                        prevTimeLeft = prev.timeLeft
                        -- Preserve firstSeen so the same continuing auction keeps
                        -- its watch key even across multiple scans/logins.
                        if prev.firstSeen then firstSeen = prev.firstSeen end
                    end
                end
            end
            -- 5-minute snipe protection: BMAH resets the timer to exactly 5 min when a
            -- bid comes in with less than 5 min remaining.
            -- * If BOTH bounds were < 5 min: reset is certain → clamp both to now+300.
            -- * If only the LOWER bound was < 5 min: reset is possible → raise lower
            --   bound to now+300 but leave upper bound (we can't be sure it fired).
            -- This avoids a min>max contradiction that would wipe the estimate entirely.
            -- Only apply snipe protection when we detect the new bid LIVE (during an
            -- active session). On the first scan after login we can't know WHEN the
            -- bid happened — it could have landed the instant we logged out — so we
            -- must not assume a +5 reset there.
            if not BM.isFirstScan and existingEst and prevNumBids and numBids and numBids > prevNumBids then
                local now    = time()
                local minExp = existingEst.minExpiry
                local maxExp = existingEst.maxExpiry
                -- Lower bound under 5 min means the auction was in the snipe window
                -- when the bid landed, so the timer was extended:
                --   * Lower bound -> always reset to the 5-min snipe floor (now + 300).
                --   * Upper bound -> only adjust if it too is under 5 min, in which case
                --     ADD 5 min (reports vary on reset-vs-add; adding is the safer
                --     assumption and keeps the estimate from hitting 0 prematurely).
                --     If the upper bound is already past 5 min, leave it untouched.
                -- math.max guards against a stale past upper bound producing min > max.
                if minExp and (minExp - now) < 300 then
                    local newMax = maxExp
                    if maxExp ~= NO_UPPER and (maxExp - now) < 300 then
                        newMax = math.max(maxExp + 300, now + 300)
                    end
                    existingEst = { minExpiry = now + 300, maxExpiry = newMax }
                end
            end
            -- On auto-refresh the bracket is stale, so keep the existing estimate
            -- unchanged and let it count down naturally. Only re-anchor on genuine
            -- NPC scans (isAutoRefresh=false) where bracket data is fresh from server.
            local timeEstimate
            if isAutoRefresh and existingEst then
                timeEstimate = existingEst
            else
                timeEstimate = UpdateTimeEstimate(existingEst, time(), timeLeft)
            end
            BM.items[i] = {
                name          = name,
                texture       = texture,
                quantity      = quantity,
                typeLabel     = typeLabel,
                hasBeenActive = hasBeenActive,
                itemLevel     = itemLevel,
                sellerName    = sellerName,
                nextMinBid    = nextMinBid,
                minIncrement  = minIncrement,
                currentBid    = currentBid,
                isHighBid     = isHighBid,
                marketID      = marketID,
                timeLeft      = timeLeft,
                itemLink      = itemLink,
                numBids       = numBids,
                quality       = quality,
                timeEstimate  = timeEstimate,
                serverName    = GetRealmName() or "unknown",
                firstSeen     = firstSeen,
            }
        end
    end

    BM.scrollBar:SetValue(0)
    BM.layoutDirty = true

    BM.SaveHistory()
    BM.UpdateVisibleRows()
    -- Only consider the "first scan" consumed once we've actually seen items.
    -- Early empty/not-ready updates shouldn't unlock live snipe detection, and
    -- SaveHistory above syncs prevNumBids so later scans only catch live bids.
    if BM.numItems and BM.numItems > 0 then
        BM.isFirstScan = false
    end
end

-- ============================================================
-- BID HANDLER
-- ============================================================

StaticPopupDialogs["BM_CONFIRM_BID"] = {
    text        = "Place bid of %s on\n%s?",
    button1     = "Confirm",
    button2     = "Cancel",
    timeout     = 0,
    whileDead   = true,
    hideOnEscape = true,
    OnAccept    = function(self)
        local data = BM.items[BM.selectedIndex]
        if not data then return end
        local gold      = tonumber(BM.bottomBar.bidInput:GetText()) or 0
        local bidCopper = gold * 10000
        C_BlackMarket.ItemPlaceBid(data.marketID, bidCopper)
    end,
}

local function HandleBidClick()
    if not BM.isAtBMAH then
        print("|cffffd700BlackMarket:|r You must be at the Black Market Auction House to bid.")
        return
    end
    if not BM.selectedIndex then
        print("|cffffd700BlackMarket:|r Select an item first.")
        return
    end
    local data = BM.items[BM.selectedIndex]
    if not data then return end
    if (data.timeLeft or 0) == 0 then
        print("|cffffd700BlackMarket:|r That auction has already ended.")
        return
    end

    local gold       = tonumber(BM.bottomBar.bidInput:GetText()) or 0
    local bidCopper  = gold * 10000
    local nextMinBid = data.nextMinBid or 0

    if bidCopper < nextMinBid then
        print(string.format("|cffffd700BlackMarket:|r Minimum bid is %d gold.", math.ceil(nextMinBid / 10000)))
        return
    end
    if bidCopper > (GetMoney and GetMoney() or 0) then
        print("|cffffd700BlackMarket:|r Not enough gold.")
        return
    end

    local goldStr  = (BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold))
    local goldFmt  = "|cffffd700" .. goldStr .. "|r|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t"
    local iconStr  = data.texture and ("|T" .. tostring(data.texture) .. ":32:32:0:0|t ") or ""
    local nameStr  = iconStr .. string.format("|cff%s%s|r", QualityHex(data.quality), data.name or "this item")
    StaticPopup_Show("BM_CONFIRM_BID", goldFmt, nameStr)
end

-- ============================================================
-- HISTORY SYSTEM
-- ============================================================

BM.isAtBMAH = false

function BM.SaveHistory()
    if not BlackMarketDB then BlackMarketDB = {} end
    if not BlackMarketDB.history then BlackMarketDB.history = {} end
    if BM.numItems == 0 then return end

    local key, realm, char = GetSessionKey()
    local now = time()

    if not BlackMarketDB.history[key] then
        BlackMarketDB.history[key] = { serverName = realm, charName = char, auctions = {} }
    end

    local session = BlackMarketDB.history[key]
    session.lastSeen   = now
    session.serverName = realm
    session.charName   = char
    session.charClass  = select(2, UnitClass("player"))

    -- Build a fresh auctions table containing only the items currently on the BMAH.
    -- This removes stale entries from prior visits while preserving accumulated
    -- timeEstimate data (which was loaded from the old table in UpdateItems).
    local newAuctions = {}
    for _, item in pairs(BM.items) do
        -- Skip entries not yet fully loaded (first update may have blank name/link)
        if item.itemLink and item.name and item.name ~= "" then
            newAuctions[item.itemLink] = {
                marketID     = item.marketID,
                name         = item.name,
                texture      = item.texture,
                quality      = item.quality,
                typeLabel    = item.typeLabel,
                itemLevel    = item.itemLevel,
                sellerName   = item.sellerName,
                currentBid   = item.currentBid,
                nextMinBid   = item.nextMinBid,
                minIncrement = item.minIncrement,
                timeLeft     = item.timeLeft,
                itemLink     = item.itemLink,
                numBids      = item.numBids,
                isHighBid    = item.isHighBid,
                timeEstimate = item.timeEstimate,
                firstSeen    = item.firstSeen,
                lastUpdated  = now,
                serverName   = realm,
            }
        end
    end
    session.auctions = newAuctions
end


-- ============================================================
-- SLASH COMMANDS
-- ============================================================

-- /bmreset         — reset window position/size to center (keeps history)
-- /bmreset history — also wipe all saved auction history
SLASH_BMRESET1 = "/bmreset"
SlashCmdList["BMRESET"] = function(arg)
    if arg and arg:lower():find("history") then
        BlackMarketDB = { history = {} }
        print("|cffffd700BlackMarket:|r History and position cleared. Reloading UI...")
    else
        BlackMarketDB.windowX      = nil
        BlackMarketDB.windowY      = nil
        BlackMarketDB.windowWidth  = nil
        BlackMarketDB.windowHeight = nil
        print("|cffffd700BlackMarket:|r Window position reset. Reloading UI...")
    end
    ReloadUI()
end

-- /bm  — open the main window from anywhere (not just at the BMAH)
SLASH_BM1 = "/bm"
SlashCmdList["BM"] = function()
    if not BM.mainFrame then return end
    if BM.mainFrame:IsShown() then
        BM.mainFrame:Hide()
    else
        -- Defer to next tick so WoW finishes clearing the chat edit box
        -- before we show a frame that contains an EditBox child.
        C_Timer.After(0, function()
            BM.openedViaSlashCmd = true
            BM.mainFrame:ClearAllPoints()
            local sx, sy = BlackMarketDB and BlackMarketDB.windowX, BlackMarketDB and BlackMarketDB.windowY
            if sx and sy then
                BM.mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", sx, sy)
            else
                local uw = UIParent:GetWidth()
                local uh = UIParent:GetHeight()
                local x = math.floor((uw - MAIN_WIDTH)  / 2)
                local y = math.floor((uh + MAIN_HEIGHT) / 2)
                BM.mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
                BlackMarketDB = BlackMarketDB or {}
                BlackMarketDB.windowX, BlackMarketDB.windowY = x, y
            end
            BM.RefreshMainRows()
            BM.mainFrame:Show()
            StartCountdownTicker()
        end)
    end
end

-- ============================================================
-- COUNTDOWN TICKER  (refreshes visible rows every 5 s)
-- ============================================================

local function StartCountdownTicker()
    if _countdownTicker then return end
    _countdownTicker = C_Timer.NewTicker(1, function()
        if BM.mainFrame and BM.mainFrame:IsShown() then
            BM.RefreshMainRows()
        else
            _countdownTicker:Cancel()
            _countdownTicker = nil
        end
    end)
end

local function StopCountdownTicker()
    if _countdownTicker then _countdownTicker:Cancel() ; _countdownTicker = nil end
end

-- ============================================================
-- EVENT HANDLING + INIT
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("BLACK_MARKET_OPEN")
eventFrame:RegisterEvent("BLACK_MARKET_CLOSE")
eventFrame:RegisterEvent("BLACK_MARKET_ITEM_UPDATE")
eventFrame:RegisterEvent("BLACK_MARKET_OUTBID")
eventFrame:RegisterEvent("PLAYER_MONEY")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

function BM.FireWinAlert()
    print("|cff44ff44BlackMarket:|r You won a Black Market auction!")
    UIErrorsFrame:AddMessage("|cff44ff44You won a Black Market auction!|r")
    PlaySoundFile("Interface\\AddOns\\BlackMarket\\Media\\win.ogg", "Master")
    if FlashClientIcon then
        FlashClientIcon()
    else
        print("|cffffff00BlackMarket:|r FlashClientIcon not available")
    end
end

-- /bmtest: fires the win alert after 5 seconds so you can tab away to test taskbar flash
SLASH_BMTEST1 = "/bmtest"
SlashCmdList["BMTEST"] = function()
    print("|cffffd700BlackMarket:|r Win alert firing in 5 seconds — tab away now!")
    C_Timer.After(5, function() BM.FireWinAlert() end)
end

-- Debug: /bmdebug â€" dumps all raw return values from GetItemInfoByIndex
SLASH_BMDEBUG1 = "/bmdebug"
SlashCmdList["BMDEBUG"] = function()
    local num = C_BlackMarket.GetNumItems() or 0
    print(string.format("|cffffd700BlackMarket Debug:|r %d item(s)", num))
    if num > 0 then
        local vals = { C_BlackMarket.GetItemInfoByIndex(1) }
        print("  return count: " .. #vals)
        for i, v in ipairs(vals) do
            print(string.format("  [%d] (%s) = %s", i, type(v), tostring(v)))
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        -- Build the UI
        BM.mainFrame   = CreateMainFrame()
        CreateColumnHeaders(BM.mainFrame)
        BM.filterBar   = CreateFilterBar(BM.mainFrame)
        BM.scrollFrame, BM.scrollContent, BM.scrollBar, BM.rows = CreateScrollArea(BM.mainFrame)
        BM.detailPanel = CreateDetailPanel(BM.mainFrame)
        BM.detailPanel:Hide()
        BM.bottomBar   = CreateBottomBar(BM.mainFrame)

        -- Initial list width (updated on every OnSizeChanged)
        BM.listWidth = MAIN_WIDTH - 34
        BM.items       = {}
        BM.numItems    = 0
        BM.selectedIndex = nil
        BM.filters     = { name = "", itemType = {}, timeLeft = {}, collected = {}, bid = {}, watched = {} }
        BM.scrollAreaHeight = MAX_VISIBLE_ROWS * ROW_HEIGHT
        UpdateFiltersBtn()

        -- Column visibility: load from SavedVariables, default all to true
        BlackMarketDB.colVisible = BlackMarketDB.colVisible or {}
        BM.colVisible = {}
        for _, col in ipairs(COLS_DEF) do
            local saved = BlackMarketDB.colVisible[col.key]
            BM.colVisible[col.key] = (saved == nil) and true or saved
        end
        BM.layoutDirty = true
        UpdateMinSize()

        BM.bottomBar.bidBtn:SetScript("OnClick", HandleBidClick)

        -- Ensure SavedVariables structure exists
        if not BlackMarketDB then BlackMarketDB = {} end
        if not BlackMarketDB.history then BlackMarketDB.history = {} end
        if not BlackMarketDB.watched then BlackMarketDB.watched = {} end

        -- One-time migration: old keys were "realm|char"; new keys are realm-only.
        -- For each old-format key, merge into the realm-only key keeping whichever
        -- record has the more recent lastSeen timestamp, then drop the old key.
        do
            local toDelete = {}
            for key, session in pairs(BlackMarketDB.history) do
                if key:find("|", 1, true) then
                    local realm = key:match("^(.+)|.+$")
                    if realm then
                        local existing = BlackMarketDB.history[realm]
                        if not existing
                           or (session.lastSeen or 0) > (existing.lastSeen or 0) then
                            BlackMarketDB.history[realm] = session
                        end
                        toDelete[#toDelete + 1] = key
                    end
                end
            end
            for _, key in ipairs(toDelete) do
                BlackMarketDB.history[key] = nil
            end
        end

        -- Restore saved window size (position is applied at open-time so UIParent is fully ready)
        if BlackMarketDB.windowWidth and BlackMarketDB.windowHeight then
            BM.mainFrame:SetSize(BlackMarketDB.windowWidth, BlackMarketDB.windowHeight)
        end

        print("|cffffd700BlackMarket|r loaded.  |cff888888/bm to open|r")

    elseif event == "BLACK_MARKET_OPEN" then
        -- Suppress the default Blizzard frame.
        -- We try synchronously first: if BlackMarketFrame already exists in memory
        -- (every open after the first in a session) we banish it before it renders.
        -- If it doesn’t exist yet (lazily created by Blizzard’s handler which may run
        -- after ours) we fall back to a one-tick defer — unavoidable one-frame flash
        -- on the very first open of a fresh session, but the OnShow hook we set here
        -- prevents any flash on every subsequent open.
        local function banishDefault(f)
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", 100000, 100000)
            f:SetAlpha(0)
            f:EnableMouse(false)
        end
        local function hookAndBanish()
            if not BlackMarketFrame then return end
            if not BM.defaultFrameHooked then
                BM.defaultFrameHooked = true
                BlackMarketFrame:HookScript("OnShow", banishDefault)
            end
            banishDefault(BlackMarketFrame)
        end
        if BlackMarketFrame then
            hookAndBanish()
        else
            C_Timer.After(0, hookAndBanish)
        end

        if C_BlackMarket and C_BlackMarket.RequestItems then
            C_BlackMarket.RequestItems()
        end
        -- Do NOT wipe session.auctions here — the accumulated timeEstimate values
        -- in the saved snapshot are needed so UpdateItems can intersect them with
        -- the new bracket observation and produce a narrowing range over time.
        -- SaveHistory replaces session.auctions with a fresh table after each scan,
        -- so stale items are removed then.
        BM.isAtBMAH = true
        BM.isFirstScan = true
        BM.openedViaSlashCmd = false
        BM.mainFrame:ClearAllPoints()
        local sx, sy = BlackMarketDB.windowX, BlackMarketDB.windowY
        if sx and sy then
            BM.mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", sx, sy)
        else
            local uw = UIParent:GetWidth()
            local uh = UIParent:GetHeight()
            local x = math.floor((uw - MAIN_WIDTH)  / 2)
            local y = math.floor((uh + MAIN_HEIGHT) / 2)
            BM.mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
            BlackMarketDB = BlackMarketDB or {}
            BlackMarketDB.windowX, BlackMarketDB.windowY = x, y
        end
        BM.mainFrame:Show()
        BM.RefreshMainRows()
        BM.UpdateMoneyDisplay()
        StartCountdownTicker()
        StartAutoRefreshTicker()

    elseif event == "BLACK_MARKET_CLOSE" then
        BM.isAtBMAH = false
        StopAutoRefreshTicker()
        if BM.mainFrame:IsShown() then
            BM.RefreshMainRows()
            if not BM.openedViaSlashCmd then
                BM.mainFrame:Hide()
                StopCountdownTicker()
            end
        end


    elseif event == "BLACK_MARKET_ITEM_UPDATE" then
        BM.RefreshList()
        -- Refresh detail panel for selected item
        if BM.selectedIndex and BM.items[BM.selectedIndex] then
            BM.UpdateDetail(BM.items[BM.selectedIndex])
            BM.UpdateBidSuggestion(BM.items[BM.selectedIndex])
        end

    elseif event == "BLACK_MARKET_OUTBID" then
        print("|cffff4444BlackMarket:|r You have been outbid!")
        -- Suppress sound/flash if this fires on the first BMAH scan after login —
        -- it's a stale catch-up notification, not a live outbid.
        if not BM.isFirstScan then
            UIErrorsFrame:AddMessage("|cffff4444You have been outbid on a Black Market item!|r")
            PlaySound(SOUNDKIT.RAID_WARNING, "Master")
            if FlashClientIcon then FlashClientIcon() else print("|cffffff00BlackMarket:|r FlashClientIcon not available") end
        end

    elseif event == "PLAYER_MONEY" then
        if BM.mainFrame and BM.mainFrame:IsShown() then
            BM.UpdateMoneyDisplay()
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if msg and (msg:find("won an auction for") or msg:find("won the Black Market auction")) then
            BM.FireWinAlert()
        end
    end
end)
