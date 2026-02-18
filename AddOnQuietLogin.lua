-- AddOnQuietLogin

local ADDON_FOLDER = ...
local addonName = "AddOnQuietLogin"
local suppressDuration = 10 -- seconds after entering world (only for addon-like output)

local GetTime = GetTime
local tostring = tostring
local type = type
local pcall = pcall
local pairs = pairs
local select = select
local table_sort = table.sort
local strlower = string.lower
local strmatch = string.match
local C_Timer = C_Timer

local ChatFrame_AddMessageEventFilter = ChatFrame_AddMessageEventFilter
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME
local LibStub = LibStub

-- SavedVariables (add to .toc: ## SavedVariables: AddOnQuietLoginDB)
AddOnQuietLoginDB = AddOnQuietLoginDB or nil

-- Start suppressed immediately (catches early startup spam)
local suppressUntil = GetTime() + suppressDuration
local function ShouldSuppress()
    return GetTime() <= suppressUntil
end

local showingBlocked = false
local inAddMessage = false
local dbReady = false

local function BaseAddMessage(frame, text, ...)
    local f = frame or DEFAULT_CHAT_FRAME or _G.ChatFrame1
    if not f then return end

    -- ScrollingMessageFrame:AddMessage via metatable (bypasses replacements)
    local mt = getmetatable(f)
    local idx = mt and mt.__index
    local fn = idx and idx.AddMessage
    if type(fn) == "function" then
        pcall(fn, f, text, ...)
        return
    end
    if type(f.AddMessage) == "function" then
        pcall(f.AddMessage, f, text, ...)
    end
end

local function PrintMsg(msg)
    BaseAddMessage(DEFAULT_CHAT_FRAME, "|cffffcc00AddOnQuietLogin:|r " .. tostring(msg))
end

local function CleanName(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- ============================================================
-- SAFETY: Detect real chat lines (player/channel messages)
-- ============================================================
local function LooksLikeNormalChatLine(msg)
    local s = tostring(msg or "")
    if s == "" then return false end

    if s:find("|Hplayer:", 1, true) then return true end
    if s:find("|HBNplayer:", 1, true) then return true end
    if s:find("|Hchannel:", 1, true) then return true end
    if s:find("|HclubTicket:", 1, true) then return true end
    if s:find("|HclubFinder:", 1, true) then return true end
    if s:find("|Hguild:", 1, true) then return true end

    return false
end

-- ============================================================
-- SAFETY: Detect NPC speech + text-emote lines
-- ============================================================
local function LooksLikeNpcOrEmoteLine(msg)
    local s = tostring(msg or "")
    if s == "" then return false end
    if LooksLikeNormalChatLine(s) then return false end

    local sl = strlower(s)

    if sl:find(" says:", 1, true) then return true end
    if sl:find(" yells:", 1, true) then return true end
    if sl:find(" whispers:", 1, true) then return true end
    if sl:find(" exclaims:", 1, true) then return true end
    if sl:find(" shouts:", 1, true) then return true end
    if sl:find(" calls out:", 1, true) then return true end

    -- Common text-emote patterns (best-effort)
    if sl:find("'s ", 1, true) then
        local last = sl:sub(-1)
        if last == "." or last == "!" or last == "?" then
            return true
        end
    end
    if sl:find(" at ", 1, true) then
        local last = sl:sub(-1)
        if last == "." or last == "!" or last == "?" then
            return true
        end
    end

    return false
end

-- ============================================================
-- Heuristic: Colon-tag prefix lines (handles timestamps: "[21:36] TAG: ...")
-- Rationale: block very short addon tags safely without adding short needles to the main list.
-- Customize by changing COLON_TAG (lowercase).
-- ============================================================
local COLON_TAGS = { "mfp", "dbm", "details" }

local function IsColonTagLine(msg)
    local s = tostring(msg or "")
    if s == "" then return false end
    local sl = strlower(s)

    for i = 1, #COLON_TAGS do
        local tag = COLON_TAGS[i]
        if tag and tag ~= "" then
            if sl:match("^[%s%[]*" .. tag .. ":") ~= nil or sl:match("^%[[^%]]+%]%s*" .. tag .. ":") ~= nil then
                return true
            end
        end
    end
    return false
end


-- ============================================================
-- Stack gate: use stack to decide if output is addon-originated
-- (only used for login suppression window; blocks do not depend on it)
-- ============================================================
local function MessageLikelyFromAddon()
    local ok, stack = pcall(debugstack, 4, 14, 14)
    if not ok or type(stack) ~= "string" then return false end

    local addonFolder = strmatch(stack, "Interface/AddOns/([^/]+)/")
    if not addonFolder or addonFolder == "" then
        return false
    end

    -- Don't treat our own prints as "addon spam"
    if addonFolder == ADDON_FOLDER or addonFolder == addonName then
        return false
    end

    return true
end

-- Suppress window should NEVER hide real player/NPC chat.
-- During login, we only suppress addon-like output (stack-gated) and known MFP tag lines.
local function ShouldSuppressLine(msg)
    if not ShouldSuppress() then return false end
    local s = tostring(msg or "")
    if s == "" then return true end
    if LooksLikeNormalChatLine(s) then return false end
    if LooksLikeNpcOrEmoteLine(s) then return false end
    if IsColonTagLine(s) then return true end
    if not MessageLikelyFromAddon() then return false end
    return true
end

-- ============================================================
-- DB + Profiles + Migration
-- ============================================================
local function EnsureDB()
    if dbReady then return end
    if type(AddOnQuietLoginDB) ~= "table" then AddOnQuietLoginDB = {} end
    if type(AddOnQuietLoginDB.profiles) ~= "table" then AddOnQuietLoginDB.profiles = {} end

    if type(AddOnQuietLoginDB.activeProfile) ~= "string" or AddOnQuietLoginDB.activeProfile == "" then
        AddOnQuietLoginDB.activeProfile = "Default"
    end

    -- migrate legacy global showBlocked (if present) -> Default profile
    local legacyShow = nil
    if AddOnQuietLoginDB.showBlocked ~= nil then
        legacyShow = AddOnQuietLoginDB.showBlocked and true or false
        AddOnQuietLoginDB.showBlocked = nil
    end

    -- Create Default profile
    if type(AddOnQuietLoginDB.profiles["Default"]) ~= "table" then
        AddOnQuietLoginDB.profiles["Default"] = { Blocks = {}, showBlocked = (legacyShow ~= nil and legacyShow) or false, MatchMode = "substring" }
    end
    if legacyShow ~= nil then
        AddOnQuietLoginDB.profiles["Default"].showBlocked = legacyShow
    end

    -- Ensure active profile exists
    if type(AddOnQuietLoginDB.profiles[AddOnQuietLoginDB.activeProfile]) ~= "table" then
        AddOnQuietLoginDB.profiles[AddOnQuietLoginDB.activeProfile] = {
            Blocks = {},
            showBlocked = AddOnQuietLoginDB.profiles["Default"].showBlocked and true or false,
            MatchMode = "substring",
        }
    end

    local def = AddOnQuietLoginDB.profiles["Default"]
    if type(def.Blocks) ~= "table" then def.Blocks = {} end
    if def.MatchMode ~= "word" and def.MatchMode ~= "substring" then def.MatchMode = "substring" end

    -- Migrate older flat Blocks into Default profile
    if type(AddOnQuietLoginDB.Blocks) == "table" then
        for needle, enabled in pairs(AddOnQuietLoginDB.Blocks) do
            if enabled then def.Blocks[needle] = true end
        end
        AddOnQuietLoginDB.Blocks = nil
    end

    -- Migrate very old keys if present
    if type(AddOnQuietLoginDB.BlocksAlways) == "table" then
        for needle, enabled in pairs(AddOnQuietLoginDB.BlocksAlways) do
            if enabled then def.Blocks[needle] = true end
        end
        AddOnQuietLoginDB.BlocksAlways = nil
    end

    -- Purge deprecated / removed keys to keep DB clean
    AddOnQuietLoginDB.addonBlocks = nil
    AddOnQuietLoginDB.mutedStringsAlways = nil
    AddOnQuietLoginDB.mutedStringsLogin = nil
    AddOnQuietLoginDB.mutedStrings = nil
    AddOnQuietLoginDB.blockMode = nil
    AddOnQuietLoginDB.mutedAddons = nil
    AddOnQuietLoginDB.reportNew = nil
    AddOnQuietLoginDB.automute = nil
    AddOnQuietLoginDB.debug = nil
    AddOnQuietLoginDB.debugFilter = nil
    dbReady = true
end

local function GetActiveProfileName()
    EnsureDB()
    return AddOnQuietLoginDB.activeProfile or "Default"
end

local function GetActiveProfile()
    EnsureDB()
    local name = GetActiveProfileName()
    local p = AddOnQuietLoginDB.profiles[name]
    if type(p) ~= "table" then
        p = { Blocks = {}, showBlocked = AddOnQuietLoginDB.profiles["Default"].showBlocked and true or false, MatchMode = "substring" }
        AddOnQuietLoginDB.profiles[name] = p
    end
    if type(p.Blocks) ~= "table" then p.Blocks = {} end
    if p.showBlocked == nil then p.showBlocked = AddOnQuietLoginDB.profiles["Default"].showBlocked and true or false end
    if p.MatchMode ~= "word" and p.MatchMode ~= "substring" then p.MatchMode = "substring" end
    return p
end

local function BuildSortedKeys(t)
    local out = {}
    for k, v in pairs(t or {}) do
        if v then out[#out+1] = k end
    end
    table_sort(out, function(a,b) return strlower(a) < strlower(b) end)
    return out
end

local function BuildSortedProfileNames()
    EnsureDB()
    local out = {}
    for name, _ in pairs(AddOnQuietLoginDB.profiles or {}) do
        local n = tostring(name or "")
        if n ~= "" then out[#out+1] = n end
    end
    table_sort(out, function(a,b) return strlower(a) < strlower(b) end)
    return out
end

local function SetActiveProfile(name)
    EnsureDB()
    name = CleanName(name)
    if name == "" then return false, "Enter a non-empty profile name." end
    if type(AddOnQuietLoginDB.profiles[name]) ~= "table" then
        AddOnQuietLoginDB.profiles[name] = { Blocks = {}, showBlocked = AddOnQuietLoginDB.profiles["Default"].showBlocked and true or false, MatchMode = "substring" }
    end
    AddOnQuietLoginDB.activeProfile = name
    return true
end

local function DeleteProfile(name)
    EnsureDB()
    name = CleanName(name)
    if name == "" then return false, "Enter a non-empty profile name." end
    if name == "Default" then return false, "Default profile cannot be deleted." end
    if type(AddOnQuietLoginDB.profiles[name]) ~= "table" then return false, "Profile not found." end

    if AddOnQuietLoginDB.activeProfile == name then
        AddOnQuietLoginDB.activeProfile = "Default"
    end

    AddOnQuietLoginDB.profiles[name] = nil
    return true
end

local function DuplicateProfile(srcName, dstName)
    EnsureDB()
    srcName = CleanName(srcName)
    dstName = CleanName(dstName)
    if srcName == "" or dstName == "" then return false, "Enter a non-empty profile name." end
    if srcName == dstName then return false, "Destination name must be different." end
    if type(AddOnQuietLoginDB.profiles[srcName]) ~= "table" then return false, "Source profile not found." end
    if type(AddOnQuietLoginDB.profiles[dstName]) == "table" then return false, "A profile with that name already exists." end

    local src = AddOnQuietLoginDB.profiles[srcName]
    local dst = { Blocks = {}, showBlocked = (src.showBlocked and true or false), MatchMode = src.MatchMode or "substring" }

    if type(src.Blocks) == "table" then
        for k, v in pairs(src.Blocks) do
            if v then dst.Blocks[k] = true end
        end
    end

    AddOnQuietLoginDB.profiles[dstName] = dst
    return true
end

local function NextCopyName(baseName)
    EnsureDB()
    baseName = CleanName(baseName)
    if baseName == "" then baseName = "Profile" end

    local candidate = baseName .. " Copy"
    if type(AddOnQuietLoginDB.profiles[candidate]) ~= "table" then
        return candidate
    end

    local i = 2
    while true do
        local c = baseName .. " Copy " .. tostring(i)
        if type(AddOnQuietLoginDB.profiles[c]) ~= "table" then
            return c
        end
        i = i + 1
    end
end

local function DuplicateActiveProfileAuto()
    EnsureDB()
    local src = GetActiveProfileName()
    local dst = NextCopyName(src)
    local ok, err = DuplicateProfile(src, dst)
    if not ok then return false, err end
    AddOnQuietLoginDB.activeProfile = dst
    return true, dst
end

local function RenameProfile(oldName, newName)
    EnsureDB()
    oldName = CleanName(oldName)
    newName = CleanName(newName)
    if oldName == "" or newName == "" then return false, "Enter old and new profile names." end
    if oldName == "Default" then return false, "Default profile cannot be renamed." end
    if type(AddOnQuietLoginDB.profiles[oldName]) ~= "table" then return false, "Profile not found." end
    if type(AddOnQuietLoginDB.profiles[newName]) == "table" then return false, "A profile with that name already exists." end

    AddOnQuietLoginDB.profiles[newName] = AddOnQuietLoginDB.profiles[oldName]
    AddOnQuietLoginDB.profiles[oldName] = nil

    if AddOnQuietLoginDB.activeProfile == oldName then
        AddOnQuietLoginDB.activeProfile = newName
    end
    return true
end

-- ============================================================
-- Visual highlighting of blocked messages (optional, per profile)
-- ============================================================
local function ShowBlocked(msg)
    local prof = GetActiveProfile()
    if not prof.showBlocked then return end
    if showingBlocked then return end

    local s = tostring(msg or "")
    if s == "" then return end
    if LooksLikeNormalChatLine(s) then return end
    if LooksLikeNpcOrEmoteLine(s) then return end

    showingBlocked = true
    BaseAddMessage(DEFAULT_CHAT_FRAME, "|cffff3333[AQL Blocked]|r " .. s)
    showingBlocked = false
end

-- ============================================================
-- Block checks
-- ============================================================
local function SafetyAllowsBlocking(s)
    if s:find("AddOnQuietLogin:", 1, true) then return false end
    if s:find("[AQL Blocked]", 1, true) then return false end
    if LooksLikeNormalChatLine(s) then return false end
    if LooksLikeNpcOrEmoteLine(s) then return false end
    return true
end

-- Whole-word matching helpers
local function IsWordChar(c)
    return c and c ~= "" and c:match("[%w]") ~= nil
end

local function FindWholeWord(haystackLower, needleLower)
    if not needleLower or needleLower == "" then return false end
    local startPos = 1
    while true do
        local i, j = haystackLower:find(needleLower, startPos, true)
        if not i then return false end

        local before = (i > 1) and haystackLower:sub(i - 1, i - 1) or ""
        local after  = haystackLower:sub(j + 1, j + 1)

        if (before == "" or not IsWordChar(before)) and (after == "" or not IsWordChar(after)) then
            return true
        end

        startPos = j + 1
    end
end

local function ShouldBlockBlocks(msg)
    local profile = GetActiveProfile()
    local t = profile.Blocks
    if type(t) ~= "table" then return false end

    local s = tostring(msg or "")
    if s == "" then return false end
    if not SafetyAllowsBlocking(s) then return false end

    local mode = profile.MatchMode or "substring"
    local sl = strlower(s)

    for needle, enabled in pairs(t) do
        if enabled then
            local n = tostring(needle or "")
            if n ~= "" then
                local nl = strlower(n)
                if mode == "word" then
                    if FindWholeWord(sl, nl) then return true end
                else
                    if sl:find(nl, 1, true) then return true end
                end
            end
        end
    end

    return false
end

local function ShouldBlockAny(msg)
    return ShouldBlockBlocks(msg)
end

-- Optional: explain why a message would be blocked (for /aql test)
local function ExplainBlock(msg)
    local profile = GetActiveProfile()
    local s = tostring(msg or "")
    if s == "" then return false, "empty" end

    if ShouldSuppressLine(s) then
        return true, "login-suppress (addon-originated or colon-tag)"
    end

    if not SafetyAllowsBlocking(s) then
        return false, "safety-exempt (looks like real chat/NPC/emote or AQL line)"
    end

    local t = profile.Blocks
    if type(t) ~= "table" then return false, "no-block-table" end

    local mode = profile.MatchMode or "substring"
    local sl = strlower(s)

    for needle, enabled in pairs(t) do
        if enabled then
            local n = tostring(needle or "")
            if n ~= "" then
                local nl = strlower(n)
                if mode == "word" then
                    if FindWholeWord(sl, nl) then
                        return true, 'match(word): "' .. n .. '"'
                    end
                else
                    if sl:find(nl, 1, true) then
                        return true, 'match(substring): "' .. n .. '"'
                    end
                end
            end
        end
    end

    return false, "no-match"
end


-- ============================================================
-- Add/remove helpers (profile-aware)
-- ============================================================
local function AddToTable(t, s)
    EnsureDB()
    s = CleanName(s)
    if s == "" then return false, "Enter a non-empty string." end
    t[s] = true
    return true
end

local function RemoveFromTable(t, s)
    EnsureDB()
    s = CleanName(s)
    if s == "" then return false, "Enter a non-empty string." end
    t[s] = nil
    return true
end

local function AddBlock(s)  return AddToTable(GetActiveProfile().Blocks, s) end
local function RemBlock(s)  return RemoveFromTable(GetActiveProfile().Blocks, s) end

-- ============================================================
-- 1) PRINT HANDLER HOOK
-- ============================================================
do
    local origSet = setprinthandler
    local current = (getprinthandler and getprinthandler()) or nil
    local inHandler = false

    local function WrappedHandler(...)
        if inHandler then return end
        local first = tostring((select(1, ...)) or "")

        if ShouldBlockAny(first) then
            ShowBlocked(first)
            return
        end
        if ShouldSuppressLine(first) then
            return
        end

        inHandler = true
        if current then pcall(current, ...) end
        inHandler = false
    end

    if type(origSet) == "function" then
        origSet(function(...) return WrappedHandler(...) end)
        setprinthandler = function(newHandler)
            current = newHandler
            origSet(function(...) return WrappedHandler(...) end)
        end
    else
        local origPrint = print
        print = function(...)
            local first = tostring((select(1, ...)) or "")
            if ShouldBlockAny(first) then
                ShowBlocked(first)
                return
            end
            if ShouldSuppressLine(first) then return end
            return origPrint(...)
        end
    end
end

-- ============================================================
-- 2) CHAT_MSG_SYSTEM FILTER
-- ============================================================
local function systemFilter(_, _, msg, ...)
    if ShouldBlockAny(msg) then
        ShowBlocked(msg)
        return true
    end
    -- We do NOT suppress system lines blindly (can hide real notifications).
    return false
end
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)

-- ============================================================
-- 3) AceConsole-3.0 suppression
-- ============================================================
local aceHooked = false
local function TryHookAceConsole()
    if aceHooked then return end
    if not LibStub then return end

    local ok, AceConsole = pcall(LibStub, "AceConsole-3.0", true)
    if not ok or not AceConsole then return end

    if type(AceConsole.Print) == "function" then
        local orig = AceConsole.Print
        AceConsole.Print = function(self, ...)
            local msg = select(1, ...)
            if ShouldBlockAny(msg) then
                ShowBlocked(msg)
                return
            end
            if ShouldSuppressLine(msg) then return end
            return orig(self, ...)
        end
    end

    if type(AceConsole.Printf) == "function" then
        local origp = AceConsole.Printf
        AceConsole.Printf = function(self, fmt, ...)
            local okf, rendered = pcall(string.format, tostring(fmt or ""), ...)
            local probe = okf and rendered or tostring(fmt or "")
            if ShouldBlockAny(probe) then
                ShowBlocked(probe)
                return
            end
            if ShouldSuppressLine(probe) then return end
            return origp(self, fmt, ...)
        end
    end

    aceHooked = true
end

-- ============================================================
-- 4) DEFAULT_CHAT_FRAME:AddMessage filter (safe with chat UI mods)
-- ============================================================
do
    local cf = DEFAULT_CHAT_FRAME or _G.ChatFrame1
    if cf and type(cf.AddMessage) == "function" then
        local baseAdd = cf.AddMessage -- preserve current implementation
        cf.AddMessage = function(self, msg, ...)
            if inAddMessage or showingBlocked then
                return baseAdd(self, msg, ...)
            end

            if ShouldBlockAny(msg) then
                ShowBlocked(msg)
                return
            end
            if ShouldSuppressLine(msg) then return end

            inAddMessage = true
            local r = baseAdd(self, msg, ...)
            inAddMessage = false
            return r
        end
    end
end

-- ============================================================
-- Options panel (profiles + per-profile showBlocked + blocks list)
-- ============================================================
local optionsPanel

local function ApplyFilter(keys, needle)
    if not needle or needle == "" then return keys end
    local n = strlower(needle)
    local out = {}
    for i = 1, #keys do
        local k = tostring(keys[i] or "")
        if k ~= "" and strlower(k):find(n, 1, true) then
            out[#out+1] = k
        end
    end
    return out
end

local function CreatePagedList(panel, anchorFrame, xOffset, titleText, colWidth, listHeight, rows, deleteFn)
    local section = {}
    section.page = 1
    section.rows = rows
    section.keysAll = {}
    section.keysFiltered = {}
    section.deleteFn = deleteFn

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", xOffset, -12)
    header:SetText(titleText)
    section.header = header

    local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addBtn:SetSize(110, 22)
    addBtn:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    addBtn:SetText("Add")

    local remBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    remBtn:SetSize(110, 22)
    remBtn:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
    remBtn:SetText("Remove")

    section.addBtn = addBtn
    section.remBtn = remBtn

    local filterLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    filterLabel:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -8)
    filterLabel:SetText("Filter:")

    local filter = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    filter:SetSize(colWidth - 120, 18)
    filter:SetPoint("LEFT", filterLabel, "RIGHT", 6, 0)
    filter:SetAutoFocus(false)

    local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 18)
    clearBtn:SetPoint("LEFT", filter, "RIGHT", 6, 0)
    clearBtn:SetText("Clear")

    section.filter = filter
    section.clearBtn = clearBtn

    local prevBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prevBtn:SetSize(50, 18)
    prevBtn:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", 0, -6)
    prevBtn:SetText("<")

    local pageText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    pageText:SetPoint("LEFT", prevBtn, "RIGHT", 8, 0)
    pageText:SetText("Page 1/1")

    local nextBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    nextBtn:SetSize(50, 18)
    nextBtn:SetPoint("LEFT", pageText, "RIGHT", 8, 0)
    nextBtn:SetText(">")

    section.prevBtn = prevBtn
    section.nextBtn = nextBtn
    section.pageText = pageText

    local listTop = CreateFrame("Frame", nil, panel)
    listTop:SetPoint("TOPLEFT", prevBtn, "BOTTOMLEFT", 0, -8)
    listTop:SetSize(colWidth, listHeight)
    section.listTop = listTop

    section.rowsUI = {}
    for i = 1, rows do
        local row = CreateFrame("Frame", nil, listTop)
        row:SetHeight(18)
        row:SetPoint("TOPLEFT", listTop, "TOPLEFT", 0, -((i - 1) * 18))
        row:SetPoint("TOPRIGHT", listTop, "TOPRIGHT", 0, -((i - 1) * 18))

        local b = CreateFrame("Button", nil, row)
        b:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        b:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -36, 0)
        b:SetNormalFontObject("GameFontHighlightSmall")
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:GetHighlightTexture():SetAlpha(0.35)

        b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        b.text:SetAllPoints(true)
        b.text:SetJustifyH("LEFT")

        b:SetScript("OnClick", function(self)
            if panel and panel.editBox and self.value then
                panel.editBox:SetText(self.value)
                panel.editBox:SetFocus()
                if panel.editBox.HighlightText then panel.editBox:HighlightText() end
            end
        end)

        local del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        del:SetSize(34, 18)
        del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        del:SetText("X")
        del:SetScript("OnClick", function()
            if section.deleteFn and b.value then
                section.deleteFn(b.value)
            end
        end)

        row:Hide()
        section.rowsUI[i] = { row=row, btn=b, del=del }
    end

    local function TotalPages()
        local n = #section.keysFiltered
        if n <= 0 then return 1 end
        return math.ceil(n / section.rows)
    end

    local function ClampPage()
        local tp = TotalPages()
        if section.page < 1 then section.page = 1 end
        if section.page > tp then section.page = tp end
    end

    local function Render()
        section.keysFiltered = ApplyFilter(section.keysAll, CleanName(filter:GetText()))
        ClampPage()
        local tp = TotalPages()

        section.pageText:SetText("Page " .. tostring(section.page) .. "/" .. tostring(tp))

        local startIndex = (section.page - 1) * section.rows + 1
        for rowi = 1, section.rows do
            local idx = startIndex + (rowi - 1)
            local key = section.keysFiltered[idx]
            local ui = section.rowsUI[rowi]

            if key then
                ui.btn.value = key
                ui.btn.text:SetText(key)
                ui.row:Show()
                ui.del:Show()
            else
                ui.btn.value = nil
                ui.btn.text:SetText("")
                ui.del:Hide()
                ui.row:Hide()
            end
        end

        prevBtn:SetEnabled(section.page > 1)
        nextBtn:SetEnabled(section.page < tp)
    end

    section.Render = Render

    filter:SetScript("OnTextChanged", function()
        section.page = 1
        Render()
    end)
    filter:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        section.page = 1
        Render()
    end)
    clearBtn:SetScript("OnClick", function()
        filter:SetText("")
        filter:ClearFocus()
        section.page = 1
        Render()
    end)
    prevBtn:SetScript("OnClick", function()
        section.page = section.page - 1
        Render()
    end)
    nextBtn:SetScript("OnClick", function()
        section.page = section.page + 1
        Render()
    end)

    return section
end

local function RegisterOptionsPanel(panel)
    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    elseif Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, addonName)
        if category then
            Settings.RegisterAddOnCategory(category)
            panel._settingsCategory = category
        end
    end
end

local function OpenOptionsPanel()
    if not optionsPanel then return end
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        return
    end
    if Settings and Settings.OpenToCategory and optionsPanel._settingsCategory then
        Settings.OpenToCategory(optionsPanel._settingsCategory:GetID())
        return
    end
    PrintMsg("Open your Interface Options and select AddOnQuietLogin.")
end

local function RefreshOptionsUI()
    if not optionsPanel then return end
    EnsureDB()

    local profile = GetActiveProfile()
    local hardKeys = BuildSortedKeys(profile.Blocks)

    if optionsPanel.profileCurrent then
        optionsPanel.profileCurrent:SetText("Current profile: " .. GetActiveProfileName())
    end
    if optionsPanel.profileEdit then
        optionsPanel.profileEdit:SetText(GetActiveProfileName())
    end
    if optionsPanel.RefreshProfileDropdown then optionsPanel.RefreshProfileDropdown() end

    if optionsPanel.showChk then
        optionsPanel.showChk:SetChecked(profile.showBlocked and true or false)
    end

    -- NEW: Word Mode checkbox (checked = word, unchecked = substring)
    if optionsPanel.wordModeChk then
        optionsPanel.wordModeChk:SetChecked((profile.MatchMode or "substring") == "word")
    end

    if optionsPanel.hardSection then
        optionsPanel.hardSection.keysAll = hardKeys
        optionsPanel.hardSection.header:SetText("Addon / Text Blocks (" .. tostring(#hardKeys) .. ")")
        optionsPanel.hardSection.Render()
    end
end

local function CreateOptionsPanel()
    if optionsPanel then return end

    optionsPanel = CreateFrame("Frame", addonName .. "Options", UIParent)
    optionsPanel.name = addonName

    local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AddOnQuietLogin")

    local profLabel = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -14)
    profLabel:SetText("Profile Name:")

    local profEdit = CreateFrame("EditBox", nil, optionsPanel, "InputBoxTemplate")
    profEdit:SetSize(220, 20)
    profEdit:SetPoint("LEFT", profLabel, "RIGHT", 8, 0)
    profEdit:SetAutoFocus(false)
    optionsPanel.profileEdit = profEdit

    local profLoad = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    profLoad:SetSize(110, 22)
    profLoad:SetPoint("LEFT", profEdit, "RIGHT", 8, 0)
    profLoad:SetText("Load/Create")

    local profDel = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    profDel:SetSize(80, 22)
    profDel:SetPoint("LEFT", profLoad, "RIGHT", 8, 0)
    profDel:SetText("Delete")

    local profCurrent = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    profCurrent:SetPoint("TOPLEFT", profLabel, "BOTTOMLEFT", 0, -6)
    profCurrent:SetText("Current profile: " .. GetActiveProfileName())
    optionsPanel.profileCurrent = profCurrent

    -- Profile dropdown (quick switch)
    local dd = CreateFrame("Frame", nil, optionsPanel, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", profCurrent, "BOTTOMLEFT", -16, -2)
    optionsPanel.profileDropdown = dd

    -- Secondary profile actions (right of dropdown)
    local profListBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    profListBtn:SetSize(60, 22)
    profListBtn:SetPoint("TOPLEFT", dd, "TOPRIGHT", 18, -2)
    profListBtn:SetText("List")

    local profRenameBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    profRenameBtn:SetSize(80, 22)
    profRenameBtn:SetPoint("LEFT", profListBtn, "RIGHT", 8, 0)
    profRenameBtn:SetText("Rename")

    local profDupBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
    profDupBtn:SetSize(90, 22)
    profDupBtn:SetPoint("LEFT", profRenameBtn, "RIGHT", 8, 0)
    profDupBtn:SetText("Duplicate")

    local function RefreshProfileDropdown()
        if not dd then return end
        local active = GetActiveProfileName()

        if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(dd, 220) end
        if UIDropDownMenu_SetButtonWidth then UIDropDownMenu_SetButtonWidth(dd, 220) end

        UIDropDownMenu_Initialize(dd, function(self, level)
            local names = BuildSortedProfileNames()
            for i = 1, #names do
                local name = names[i]
                local info = UIDropDownMenu_CreateInfo()
                info.text = name
                info.value = name
                info.func = function()
                    local ok, err = SetActiveProfile(name)
                    if ok then
                        PrintMsg('Active profile set to "' .. GetActiveProfileName() .. '"')
                        RefreshOptionsUI()
                    else
                        PrintMsg(err or "Could not set profile.")
                    end
                end
                info.checked = (name == active)
                UIDropDownMenu_AddButton(info, level)
            end
        end)

        UIDropDownMenu_SetSelectedValue(dd, active)
        UIDropDownMenu_SetText(dd, active)
        UIDropDownMenu_SetText(dd, active)
    end
    optionsPanel.RefreshProfileDropdown = RefreshProfileDropdown

    profLoad:SetScript("OnClick", function()
        local name = CleanName(profEdit:GetText())
        local ok, err = SetActiveProfile(name)
        if ok then
            PrintMsg('Active profile set to "' .. GetActiveProfileName() .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not set profile.")
        end
        profEdit:SetFocus()
    end)

    profDel:SetScript("OnClick", function()
        local name = CleanName(profEdit:GetText())
        local ok, err = DeleteProfile(name)
        if ok then
            PrintMsg('Deleted profile "' .. name .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not delete profile.")
        end
        profEdit:SetFocus()
    end)

    profListBtn:SetScript("OnClick", function()
        local names = BuildSortedProfileNames()
        PrintMsg("Profiles: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
    end)

    profRenameBtn:SetScript("OnClick", function()
        local oldName = GetActiveProfileName()
        local newName = CleanName(profEdit:GetText())
        local ok, err = RenameProfile(oldName, newName)
        if ok then
            PrintMsg('Renamed profile "' .. oldName .. '" -> "' .. GetActiveProfileName() .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not rename profile.")
        end
        profEdit:SetFocus()
    end)

    profDupBtn:SetScript("OnClick", function()
        local ok, nameOrErr = DuplicateActiveProfileAuto()
        if ok then
            PrintMsg('Duplicated active profile -> "' .. nameOrErr .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(nameOrErr or "Could not duplicate profile.")
        end
        profEdit:SetFocus()
    end)

    local showChk = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
    showChk:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 16, -8)
    showChk.text:SetText("Show blocked messages in chat")
    showChk:SetChecked(GetActiveProfile().showBlocked and true or false)
    showChk:SetScript("OnClick", function(self)
        GetActiveProfile().showBlocked = self:GetChecked() and true or false
        PrintMsg("Show blocked previews (this profile): " .. (GetActiveProfile().showBlocked and "ON" or "OFF"))
        RefreshOptionsUI()
    end)
    optionsPanel.showChk = showChk

    -- NEW: checkbox to switch Block Mode between Substring and Word (per profile)
    local wordModeChk = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
    wordModeChk:SetPoint("LEFT", showChk, "RIGHT", 210, 0) -- right of ShowBlocked checkbox
    wordModeChk.text:SetText("Word Mode (Safe Mode)")
    wordModeChk:SetChecked((GetActiveProfile().MatchMode or "substring") == "word")
    wordModeChk:SetScript("OnClick", function(self)
        local p = GetActiveProfile()
        p.MatchMode = (self:GetChecked() and "word") or "substring"
        PrintMsg("Blocks match mode (this profile): " .. tostring(p.MatchMode))
        RefreshOptionsUI()
    end)
    optionsPanel.wordModeChk = wordModeChk

    local helpText = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    helpText:SetJustifyH("LEFT")
    helpText:SetPoint("TOPLEFT", showChk, "BOTTOMLEFT", 0, -8)
    helpText:SetWidth(650)
    helpText:SetText(
        "The Default profile cannot be deleted. Default applies to all characters unless using a specific profile.\n" ..
        "Enter a profile name and click (Load/Create) to create or switch profiles.\n" ..
        "(List) displays all profiles in a chat message. Use the dropdown menu to select specific profiles.\n" ..
        "Select a profile & click (Delete) to remove it. Enter a name & click (Rename) to rename it.\n\n" ..
        "Enter an addon name or word text in the field below & click (Add) under Addon/Text Blocks to block it.\n" ..
        "Enter = Add Addon name to block list. Shift+Enter = Remove Addon from block list.\n" ..
        "Click addon name to select it. Use (X) to remove entries. Use Filter to search blocked addons & text.\n\n" ..
        "WARNING!!!: Some chat messages may be blocked despite safeguards. Accidental blocks may still occur.\n" ..
        "There are 2 different Modes to block unwanted text. (Block Modes: Substring Mode / Word Mode)\n" ..
        "The Default setting is Substring Mode. (Very aggressive to block any message containing your exact text)\n" ..
        "Word Mode is (precise/safer). (Use Word Mode if you notice any normal chat messages being blocked)\n" ..
        "You can switch modes with the (Word Mode) checkbox or with /aql mode substring | /aql mode word.\n" ..
        "Substring Mode blocks any message text containing what you block. Ex: (raid) will block (afraid) & (raiding)\n" ..
        "Word Mode will block only message text containing what you block. Ex: (raid) wont block (afraid) & (raiding)\n" ..
        "(Be careful using Default Mode with blocked text as it may block any message containing that specific text)"
    )

    local editLabel = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    editLabel:SetPoint("TOPLEFT", helpText, "BOTTOMLEFT", 0, -10)
    editLabel:SetText("Addon Name / Text to Block:")

    local edit = CreateFrame("EditBox", nil, optionsPanel, "InputBoxTemplate")
    edit:SetSize(520, 20)
    edit:SetPoint("TOPLEFT", editLabel, "BOTTOMLEFT", 0, -6)
    edit:SetAutoFocus(false)
    optionsPanel.editBox = edit

    local colWidth = 560
    local listHeight = 220
    local rows = 5

    optionsPanel.hardSection = CreatePagedList(optionsPanel, edit, 0, "Blocks", colWidth, listHeight, rows, function(value)
        local ok, err = RemBlock(value)
        if ok then
            PrintMsg('Removed Block: "' .. value .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not remove.")
        end
    end)

    optionsPanel.hardSection.addBtn:SetScript("OnClick", function()
        local v = CleanName(edit:GetText())
        local ok, err = AddBlock(v)
        if ok then
            PrintMsg('Added Block: "' .. v .. '"')
            edit:SetText("")
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not add.")
        end
        edit:SetFocus()
    end)

    optionsPanel.hardSection.remBtn:SetScript("OnClick", function()
        local v = CleanName(edit:GetText())
        local ok, err = RemBlock(v)
        if ok then
            PrintMsg('Removed Block: "' .. v .. '"')
            edit:SetText("")
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not remove.")
        end
        edit:SetFocus()
    end)

    -- Hotkeys (keeps your muscle memory simple)
    edit:SetScript("OnEnterPressed", function()
        local shift = IsShiftKeyDown and IsShiftKeyDown()
        if shift then
            optionsPanel.hardSection.remBtn:Click()
        else
            optionsPanel.hardSection.addBtn:Click()
        end
    end)
    edit:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    optionsPanel:SetScript("OnShow", function()
        RefreshOptionsUI()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if edit and edit:IsVisible() then
                    edit:SetFocus()
                    if edit.HighlightText then edit:HighlightText() end
                end
            end)
        end
    end)

    RegisterOptionsPanel(optionsPanel)
end

-- ============================================================
-- Slash commands
-- ============================================================
SLASH_AQL1 = "/aql"
SlashCmdList.AQL = function(msg)
    EnsureDB()
    msg = CleanName(msg)

    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = (cmd and cmd:lower()) or "list"
    rest = CleanName(rest)

    if cmd == "list" or cmd == "options" or cmd == "" then
        CreateOptionsPanel()
        OpenOptionsPanel()
        local profile = GetActiveProfile()
        local h = BuildSortedKeys(profile.Blocks)

        PrintMsg("profile=" .. GetActiveProfileName() ..
                 ", showBlocked=" .. (profile.showBlocked and "on" or "off") ..
                 ", mode=" .. tostring(profile.MatchMode or "substring"))
        PrintMsg("Blocks: " .. tostring(#h))
        PrintMsg('Blocks: /aql block <text> | /aql unblock <text> | /aql blocks')
        PrintMsg('Profiles: /aql profiles | /aql profile <name> | /aql profiledelete <name> | /aql profilerename <newname> | /aql profiledup')
        PrintMsg('Show blocked: /aql showblocked on | off | toggle')
        PrintMsg('Mode: /aql mode substring | /aql mode word')
        PrintMsg('Tools: /aql test <text> | /aql why <text> | /aql import a;b;c')
        PrintMsg('Options: /aql | /aql list | /aql options')
        return
    end

    if cmd == "profile" then
        if rest == "" then PrintMsg('Usage: /aql profile <name>'); return end
        local ok, err = SetActiveProfile(rest)
        if ok then
            PrintMsg('Active profile set to "' .. GetActiveProfileName() .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not set profile.")
        end
        return
    end


if cmd == "test" or cmd == "why" then
    if rest == "" then
        PrintMsg('Usage: /aql test <message text>')
        PrintMsg('Example: /aql test MFP: hello')
        return
    end
    local blocked, reason = ExplainBlock(rest)
    if blocked then
        PrintMsg('|cffff3333BLOCKED|r — ' .. tostring(reason))
    else
        PrintMsg('|cff33ff33ALLOWED|r — ' .. tostring(reason))
    end
    return
end

        if cmd == "import" then
            if rest == "" then
                PrintMsg("Usage: /aql import a;b;c")
                return
            end
            local added = 0
            local skipped = 0
            for part in rest:gmatch("[^;]+") do
                part = CleanName(part)
                if part ~= "" then
                    local ok = AddBlock(part)
                    if ok then added = added + 1 else skipped = skipped + 1 end
                end
            end
            RefreshOptionsUI()
            PrintMsg("Imported: " .. added .. " added" .. (skipped > 0 and (", " .. skipped .. " skipped") or ""))
            return
        end

    if cmd == "profiles" then
        local names = BuildSortedProfileNames()
        PrintMsg("Profiles: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
        return
    end

    if cmd == "profiledelete" then
        if rest == "" then PrintMsg('Usage: /aql profiledelete <name>'); return end
        local ok, err = DeleteProfile(rest)
        if ok then
            PrintMsg('Deleted profile "' .. rest .. '" (active: ' .. GetActiveProfileName() .. ")")
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not delete profile.")
        end
        return
    end

    if cmd == "profilerename" then
        if rest == "" then PrintMsg('Usage: /aql profilerename <newname>'); return end
        local old = GetActiveProfileName()
        local ok, err = RenameProfile(old, rest)
        if ok then
            PrintMsg('Renamed profile "' .. old .. '" -> "' .. GetActiveProfileName() .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(err or "Could not rename profile.")
        end
        return
    end

    if cmd == "profiledup" then
        local ok, nameOrErr = DuplicateActiveProfileAuto()
        if ok then
            PrintMsg('Duplicated active profile -> "' .. nameOrErr .. '"')
            RefreshOptionsUI()
        else
            PrintMsg(nameOrErr or "Could not duplicate profile.")
        end
        return
    end

    if cmd == "showblocked" then
        local v = strlower(rest)
        local p = GetActiveProfile()
        if v == "on" then
            p.showBlocked = true
        elseif v == "off" then
            p.showBlocked = false
        elseif v == "toggle" or v == "" then
            p.showBlocked = not p.showBlocked
        else
            PrintMsg("Usage: /aql showblocked on | off | toggle")
            return
        end
        PrintMsg("Show blocked previews (this profile): " .. (p.showBlocked and "ON" or "OFF"))
        RefreshOptionsUI()
        return
    end

    if cmd == "mode" then
        local v = strlower(rest)
        if v ~= "substring" and v ~= "word" then
            PrintMsg("Usage: /aql mode substring | /aql mode word")
            return
        end
        local p = GetActiveProfile()
        p.MatchMode = v
        PrintMsg("Blocks match mode (this profile): " .. v)
        RefreshOptionsUI()
        return
    end

    if cmd == "block" then
        if rest == "" then PrintMsg('Usage: /aql block <text>'); return end
        local ok, err = AddBlock(rest)
        if ok then PrintMsg('Added Block: "' .. rest .. '"')
        else PrintMsg(err or "Could not add.") end
        RefreshOptionsUI()
        return
    end

    if cmd == "unblock" then
        if rest == "" then PrintMsg('Usage: /aql unblock <text>'); return end
        local ok, err = RemBlock(rest)
        if ok then PrintMsg('Removed Block: "' .. rest .. '"')
        else PrintMsg(err or "Could not remove.") end
        RefreshOptionsUI()
        return
    end

    if cmd == "blocks" then
        local keys = BuildSortedKeys(GetActiveProfile().Blocks)
        PrintMsg("Blocks (" .. tostring(#keys) .. "): " .. (#keys > 0 and table.concat(keys, ", ") or "(none)"))
        return
    end

    PrintMsg("Unknown command. Try /aql list")
end

-- ============================================================
-- Events
-- ============================================================
local frame = CreateFrame("Frame", addonName .. "Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_FOLDER then
            EnsureDB()
            CreateOptionsPanel()
        end
        TryHookAceConsole()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        EnsureDB()
        suppressUntil = GetTime() + suppressDuration
        TryHookAceConsole()
    end
end)
