-- SmartDeck card list / edit / delete UI.
--
-- Lists cards for the current book (or all books) inside a Menu. Tapping a
-- card opens an action dialog (view / edit / delete). Editing the phrase also
-- offers the user a choice between keeping the enrichment, clearing it for a
-- later fetch, or refetching right now.
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local Device = require("device")
local Button = require("ui/widget/button")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Blitbuffer = require("ffi/blitbuffer")

local Screen = Device.screen

local DB = require("smartdeck_db")
local Enrich = require("smartdeck_enrich")

local Edit = {}

local function buildCardLabel(card)
    local prefix = card.ai_status == DB.STATUS_ENRICHED and "" or "[!] "
    local phrase = card.phrase or ""
    local hint = card.meaning
    if hint and hint ~= "" then
        if #hint > 60 then hint = hint:sub(1, 60) .. "…" end
        return prefix .. phrase .. "  —  " .. hint
    end
    return prefix .. phrase
end

local function buildPreviewText(card)
    local parts = { string.format(_("Phrase: %s"), card.phrase or "") }
    if card.pronunciation ~= "" then
        parts[#parts + 1] = string.format(_("Pronunciation: %s"), card.pronunciation)
    end
    if card.word_type ~= "" then
        parts[#parts + 1] = string.format(_("Word type: %s"), card.word_type)
    end
    if card.meaning ~= "" then
        parts[#parts + 1] = string.format(_("Meaning: %s"), card.meaning)
    end
    local examples = Enrich.decodeExamples(card.examples)
    if #examples > 0 then
        parts[#parts + 1] = _("Examples:")
        for i, ex in ipairs(examples) do
            parts[#parts + 1] = string.format("  %d. %s", i, ex)
        end
    end
    if card.sentence ~= "" then
        parts[#parts + 1] = string.format(_("Source sentence: %s"), card.sentence)
    end
    if card.display_context ~= "" and card.display_context ~= card.sentence then
        parts[#parts + 1] = string.format(_("Surrounding context: %s"), card.display_context)
    end
    if card.user_note ~= "" then
        parts[#parts + 1] = string.format(_("Note: %s"), card.user_note)
    end
    if card.ai_status == DB.STATUS_ERROR and card.ai_error ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Last AI error: %s"), card.ai_error)
    elseif card.ai_status == DB.STATUS_PENDING then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("This card has not been enriched yet.")
    end
    return table.concat(parts, "\n")
end

-- Ask the user what should happen to the AI fields after an edit.
local function askPostEditAction(plugin, card, on_done)
    local dialog
    dialog = ButtonDialog:new{
        title = _("What should happen to the existing AI data?"),
        buttons = {
            { {
                text = _("Keep existing data"),
                callback = function()
                    UIManager:close(dialog)
                    on_done("keep")
                end,
            } },
            { {
                text = _("Clear, fetch later"),
                callback = function()
                    UIManager:close(dialog)
                    on_done("clear")
                end,
            } },
            { {
                text = _("Clear and refetch now"),
                callback = function()
                    UIManager:close(dialog)
                    on_done("refetch")
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

local function runSingleFetch(plugin, card, after)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local trap = InfoMessage:new{
                text = string.format(_("Fetching AI data for:\n%s\n\nTap outside to cancel."), card.phrase or ""),
                timeout = nil,
            }
            UIManager:show(trap)
            local ok, err = Enrich.enrichAndSave(plugin, card, trap)
            UIManager:close(trap)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("AI fetch failed:\n%s"), err or _("Unknown error")),
                    timeout = 4,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Card enriched."),
                    timeout = 2,
                })
            end
            if after then after() end
        end)
    end)
end

-- Edit dialog for a single card.
local function showEditDialog(plugin, card, on_saved)
    local dialog
    local original_phrase = card.phrase or ""
    dialog = InputDialog:new{
        title = _("Edit card"),
        description = _("Phrase on the first line, your note on the second. Leave the note line empty to clear it."),
        input = (card.phrase or "") .. "\n" .. (card.user_note or ""),
        allow_newline = true,
        rows = 3,
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local raw = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    local newline_pos = raw:find("\n")
                    local new_phrase, new_note
                    if newline_pos then
                        new_phrase = raw:sub(1, newline_pos - 1)
                        new_note = raw:sub(newline_pos + 1)
                    else
                        new_phrase = raw
                        new_note = ""
                    end
                    new_phrase = (new_phrase or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    new_note = (new_note or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if new_phrase == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("Phrase cannot be empty."),
                            timeout = 3,
                        })
                        return
                    end

                    local phrase_changed = new_phrase ~= original_phrase
                    local fields = {
                        phrase = new_phrase,
                        sentence = card.sentence or "",
                        ai_context = card.ai_context or "",
                        display_context = card.display_context or "",
                        user_note = new_note,
                    }

                    local function commit(clear_ai, refetch_now)
                        DB.updateCardContent(card.id, fields, clear_ai)
                        local fresh = DB.getCard(card.id)
                        if fresh then
                            for k, v in pairs(fresh) do card[k] = v end
                        end
                        if refetch_now then
                            runSingleFetch(plugin, card, on_saved)
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Card saved."),
                                timeout = 2,
                            })
                            if on_saved then on_saved() end
                        end
                    end

                    if phrase_changed and card.ai_status == DB.STATUS_ENRICHED then
                        askPostEditAction(plugin, card, function(choice)
                            if choice == "keep" then
                                commit(false, false)
                            elseif choice == "clear" then
                                commit(true, false)
                            else -- refetch
                                commit(true, true)
                            end
                        end)
                    else
                        commit(false, false)
                    end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function showCardActionDialog(plugin, card, on_refresh)
    local dialog
    dialog = ButtonDialog:new{
        title = card.phrase or "",
        buttons = {
            { {
                text = _("View details"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(TextViewer:new{
                        title = _("Card details"),
                        text = buildPreviewText(card),
                    })
                end,
            } },
            { {
                text = _("Edit"),
                callback = function()
                    UIManager:close(dialog)
                    showEditDialog(plugin, card, on_refresh)
                end,
            } },
            { {
                text = card.ai_status == DB.STATUS_ENRICHED and _("Refetch AI data") or _("Fetch AI data"),
                callback = function()
                    UIManager:close(dialog)
                    runSingleFetch(plugin, card, on_refresh)
                end,
            } },
            { {
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this card?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            DB.deleteCard(card.id)
                            UIManager:show(InfoMessage:new{ text = _("Card deleted."), timeout = 2 })
                            if on_refresh then on_refresh() end
                        end,
                    })
                end,
            } },
            { {
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            } },
        },
    }
    UIManager:show(dialog)
end

-- Case-insensitive substring match across the most user-facing text fields.
local function matchesFilter(card, query)
    if not query or query == "" then return true end
    query = query:lower()
    local haystacks = {
        card.phrase or "",
        card.meaning or "",
        card.user_note or "",
        card.word_type or "",
        card.pronunciation or "",
        card.sentence or "",
    }
    for _, h in ipairs(haystacks) do
        if h ~= "" and h:lower():find(query, 1, true) then
            return true
        end
    end
    return false
end

-- Public: open the card list screen.
-- @param plugin   SmartDeck plugin instance
-- @param book_id  nil = all books
-- @param title    string shown in the menu title bar
function Edit.showList(plugin, book_id, title)
    local screen = Device.screen
    local menu
    -- Session-only filter state. Intentionally NOT persisted: reopening the
    -- list from the main menu always starts with no filter.
    local filter_text = ""

    local final_title = title or _("SmartDeck cards")

    local function currentTitle()
        if filter_text ~= "" then
            return string.format("%s  [%s]", final_title, filter_text)
        end
        return final_title
    end

    local function buildItems()
        local cards = DB.listCards(book_id, false)
        local items = {}
        for _, card in ipairs(cards) do
            if matchesFilter(card, filter_text) then
                items[#items + 1] = {
                    text = buildCardLabel(card),
                    card = card,
                }
            end
        end
        if #items == 0 then
            if filter_text ~= "" then
                items[#items + 1] = { text = _("(no cards match filter)"), dim = true }
            else
                items[#items + 1] = { text = _("(no cards)"), dim = true }
            end
        end
        return items
    end

    local function refresh()
        if menu and menu.switchItemTable then
            menu:switchItemTable(currentTitle(), buildItems())
        end
    end

    local function showFilterDialog()
        local dialog
        dialog = InputDialog:new{
            title = _("Filter cards"),
            description = _("Match phrase, meaning, note, word type, pronunciation or sentence."),
            input = filter_text,
            input_hint = _("Filter text"),
            buttons = { {
                {
                    text = _("Cancel"),
                    id = "close",
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear filter"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                        filter_text = ""
                        refresh()
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        local raw = dialog:getInputText() or ""
                        raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        filter_text = raw
                        refresh()
                    end,
                },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    menu = Menu:new{
        title = final_title,
        item_table = buildItems(),
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.95),
        height = math.floor(screen:getHeight() * 0.95),
    }

    function menu:onMenuChoice(item)
        if item and item.card then
            showCardActionDialog(plugin, item.card, refresh)
        end
        return true
    end

    function menu:onMenuHold(item)
        if item and item.card then
            UIManager:show(ConfirmBox:new{
                text = string.format(_("Delete card \"%s\"?"), item.card.phrase or ""),
                ok_text = _("Delete"),
                ok_callback = function()
                    DB.deleteCard(item.card.id)
                    refresh()
                end,
            })
        end
        return true
    end

    -- Inject a "Filter" button into the bottom icon bar of the menu, next to
    -- the page navigation chevrons. Mirrors the rssreader "More" button
    -- pattern.
    if menu.page_info then
        local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
        local filter_button = Button:new{
            text = _("Filter"),
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            show_parent = menu.show_parent or menu,
            callback = showFilterDialog,
        }
        table.insert(menu.page_info, spacer)
        table.insert(menu.page_info, filter_button)
        if menu.page_info.resetLayout then
            menu.page_info:resetLayout()
        end
    end

    UIManager:show(menu)
end

return Edit
