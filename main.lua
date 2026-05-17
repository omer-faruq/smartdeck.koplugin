-- SmartDeck plugin entry point.
--
-- Responsibilities:
--   * Plugin lifecycle (init / onReaderReady / onFlushSettings).
--   * Injecting the "SmartDeck" action into the highlight menu and the
--     dictionary popup.
--   * Rendering the main menu under the `tools` sorting hint.
--   * Instantiating the AI querier from smartdeck_configuration.lua and
--     bridging it into the enrichment helpers.
local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local koutil = require("util")
local logger = require("logger")

local DB = require("smartdeck_db")
local Enrich = require("smartdeck_enrich")
local SettingsModule = require("smartdeck_settings")
local Querier = require("smartdeck_ai")
local Importer = require("smartdeck_import")
local EditModule = require("smartdeck_edit")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/smartdeck.lua"

local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/smartdeck.koplugin/"
local CONFIG_FILE_PATH = PLUGIN_DIR .. "smartdeck_configuration.lua"

-- ── Load optional configuration.lua ──────────────────────────────────────

local function loadConfigurationFile()
    if not koutil.pathExists(CONFIG_FILE_PATH) then
        return nil, nil
    end
    local ok, result = pcall(function() return dofile(CONFIG_FILE_PATH) end)
    if not ok then
        logger.warn("smartdeck: configuration load failed:", result)
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, _("smartdeck_configuration.lua did not return a table.")
    end
    return result, nil
end

local CONFIGURATION, CONFIG_ERROR = loadConfigurationFile()

-- ── Plugin definition ────────────────────────────────────────────────────

local SmartDeck = InputContainer:extend{
    name = "smartdeck",
    is_doc_only = false,
    CONFIGURATION = nil,
    settings = nil,
    querier = nil,
}

function SmartDeck:readSetting(key, default)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    local val = self.settings:readSetting(key)
    if val == nil then return default end
    return val
end

function SmartDeck:saveSetting(key, value)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function SmartDeck:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

function SmartDeck:getDefaultProvider()
    local config = self.CONFIGURATION
    if not config then return nil end
    if config.provider and koutil.tableGetValue(config, "provider_settings", config.provider) then
        return config.provider
    end
    if type(config.provider_settings) == "table" then
        for name, _settings in pairs(config.provider_settings) do
            return name
        end
    end
    return nil
end

function SmartDeck:getActiveProvider()
    return self.settings:readSetting("provider") or self:getDefaultProvider()
end

-- ── Document helpers ─────────────────────────────────────────────────────

function SmartDeck:getDocumentFilePath()
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file
    end
    return nil
end

function SmartDeck:getDocumentTitle()
    if self.ui and self.ui.doc_props then
        local title = self.ui.doc_props.title
        if title and title ~= "" then return title end
    end
    local filepath = self:getDocumentFilePath()
    if filepath then
        local filename = filepath:match("([^/\\]+)$") or filepath
        return filename:match("(.+)%.[^%.]+$") or filename
    end
    return _("Unknown")
end

-- ── Card creation workflow ───────────────────────────────────────────────

local function isOnline()
    return NetworkMgr:isOnline()
end

function SmartDeck:_triggerEnrichment(card_id)
    if not card_id then return end
    local card = DB.getCard(card_id)
    if not card then return end
    Trapper:wrap(function()
        local trap = InfoMessage:new{
            text = string.format(_("Fetching AI data for:\n%s\n\nTap outside to cancel."), card.phrase or ""),
            timeout = nil,
        }
        UIManager:show(trap)
        local ok, err = Enrich.enrichAndSave(self, card, trap)
        UIManager:close(trap)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = string.format(_("AI fetch failed:\n%s"), err or _("Unknown error")),
                timeout = 4,
            })
        else
            UIManager:show(Notification:new{ text = _("Card enriched.") })
        end
    end)
end

-- Shared card-add flow used by both the highlight and dictionary entry
-- points. `ai_context`, `display_context` and `sentence` may be empty strings
-- when no document context is available (e.g. coming from the dict popup).
--
-- The two prompt steps (phrase edit + note input) are individually
-- skippable through the settings so power users can add cards with a
-- single tap. When both prompts are disabled the phrase is persisted
-- verbatim with an empty note.
function SmartDeck:_showAddDialog(params)
    params = params or {}
    local phrase = params.phrase or ""
    if phrase == "" then
        UIManager:show(InfoMessage:new{ text = _("No text selected."), timeout = 3 })
        return
    end
    local filepath = self:getDocumentFilePath()
    if not filepath then
        UIManager:show(InfoMessage:new{ text = _("Open a book to save cards."), timeout = 3 })
        return
    end

    -- Defaults are intentionally off so a single tap on "Add to SmartDeck"
    -- saves the card immediately. Users can re-enable either prompt from
    -- the settings screen.
    local ask_phrase = self.settings:readSetting("ask_phrase_edit_on_add", false) and true or false
    local ask_note = self.settings:readSetting("ask_note_on_add", false) and true or false

    -- Short-circuit when both prompts are disabled.
    if not ask_phrase and not ask_note then
        self:_persistCard(phrase, "", params)
        return
    end

    if not ask_phrase then
        self:_showNoteDialog(phrase, params)
        return
    end

    local phrase_dialog
    phrase_dialog = InputDialog:new{
        title = _("Add to SmartDeck"),
        description = _("Edit phrase if needed."),
        input = phrase,
        input_hint = _("Selected phrase"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(phrase_dialog) end,
            },
            {
                -- Wording depends on whether a second step follows.
                text = ask_note and _("Next") or _("Save"),
                is_enter_default = true,
                callback = function()
                    local final_phrase = phrase_dialog:getInputText() or ""
                    final_phrase = final_phrase:gsub("^%s+", ""):gsub("%s+$", "")
                    if final_phrase == "" then final_phrase = phrase end
                    UIManager:close(phrase_dialog)
                    if ask_note then
                        self:_showNoteDialog(final_phrase, params)
                    else
                        self:_persistCard(final_phrase, "", params)
                    end
                end,
            },
        } },
    }
    UIManager:show(phrase_dialog)
    phrase_dialog:onShowKeyboard()
end

function SmartDeck:_showNoteDialog(final_phrase, params)
    local description
    if params.sentence and params.sentence ~= "" then
        description = _("Sentence: ") .. params.sentence
    end
    local note_dialog
    note_dialog = InputDialog:new{
        title = _("Add note / meaning"),
        description = description,
        input = "",
        input_hint = _("Optional personal note…"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(note_dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local note = note_dialog:getInputText() or ""
                    UIManager:close(note_dialog)
                    self:_persistCard(final_phrase, note, params)
                end,
            },
        } },
    }
    UIManager:show(note_dialog)
    note_dialog:onShowKeyboard()
end

function SmartDeck:_persistCard(phrase, note, params)
    local filepath = self:getDocumentFilePath()
    if not filepath then
        UIManager:show(InfoMessage:new{ text = _("Could not determine document."), timeout = 3 })
        return
    end
    local book_id = DB.getOrCreateBook(self:getDocumentTitle(), filepath)
    if not book_id then
        UIManager:show(InfoMessage:new{ text = _("Failed to create book record."), timeout = 3 })
        return
    end
    local card_id = DB.addCard(book_id, {
        phrase = phrase,
        sentence = params.sentence or "",
        ai_context = params.ai_context or "",
        display_context = params.display_context or "",
        user_note = note or "",
    })
    if not card_id then
        UIManager:show(InfoMessage:new{ text = _("Failed to save card."), timeout = 3 })
        return
    end

    UIManager:show(Notification:new{ text = _("Phrase added to SmartDeck.") })

    local auto_fetch = self.settings:readSetting("auto_fetch", true) and true or false
    if auto_fetch and self.querier and self.querier:isInited() then
        if isOnline() then
            self:_triggerEnrichment(card_id)
        else
            UIManager:show(InfoMessage:new{
                text = _("Offline: card saved without AI data. Use \"Fetch missing info\" later."),
                timeout = 3,
            })
        end
    end
end

function SmartDeck:addFromHighlight(reader_highlight)
    if not reader_highlight or not reader_highlight.selected_text then
        return
    end
    local selected = reader_highlight.selected_text
    local ai_context, display_context, sentence = Enrich.captureContexts(self, self.ui, selected)
    if reader_highlight.highlight_dialog then
        UIManager:close(reader_highlight.highlight_dialog)
        reader_highlight.highlight_dialog = nil
    end
    reader_highlight:clear()
    self:_showAddDialog{
        phrase = selected.text,
        ai_context = ai_context,
        display_context = display_context,
        sentence = sentence,
    }
end

function SmartDeck:addFromDictionary(word)
    -- Dictionary popup does not provide surrounding document context, so
    -- ai_context / display_context / sentence are left empty; the AI will be
    -- asked about the bare phrase.
    self:_showAddDialog{
        phrase = word or "",
        ai_context = "",
        display_context = "",
        sentence = "",
    }
end

-- ── Bulk operations ──────────────────────────────────────────────────────

function SmartDeck:bulkFetchMissing(book_id)
    if not self.querier or not self.querier:isInited() then
        UIManager:show(InfoMessage:new{
            text = _("Configure smartdeck_configuration.lua with a valid AI provider first."),
            timeout = 4,
        })
        return
    end
    local cards = DB.listPendingCards(book_id)
    if #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All cards are already enriched."),
            timeout = 3,
        })
        return
    end
    NetworkMgr:runWhenOnline(function()
        Enrich.bulkEnrich(self, cards)
    end)
end

-- ── Menu ─────────────────────────────────────────────────────────────────

function SmartDeck:addToMainMenu(menu_items)
    menu_items.smartdeck = {
        sorting_hint = "tools",
        text = _("SmartDeck"),
        sub_item_table_func = function() return self:_buildMenu() end,
    }
end

function SmartDeck:_buildMenu()
    local has_book = self:getDocumentFilePath() ~= nil
    return {
        {
            text = _("Study"),
            callback = function() self:openStudy() end,
        },
        {
            text = _("Cards for this book"),
            enabled_func = function() return has_book end,
            callback = function()
                local filepath = self:getDocumentFilePath()
                if not filepath then return end
                local book_id = DB.getOrCreateBook(self:getDocumentTitle(), filepath)
                EditModule.showList(self, book_id, self:getDocumentTitle())
            end,
        },
        {
            text = _("All cards"),
            callback = function()
                EditModule.showList(self, nil, _("All SmartDeck cards"))
            end,
        },
        {
            text = _("Fetch missing info (this book)"),
            enabled_func = function() return has_book end,
            callback = function()
                local filepath = self:getDocumentFilePath()
                if not filepath then return end
                local book_id = DB.getOrCreateBook(self:getDocumentTitle(), filepath)
                self:bulkFetchMissing(book_id)
            end,
        },
        {
            text = _("Fetch missing info (all books)"),
            callback = function() self:bulkFetchMissing(nil) end,
        },
        {
            text = _("Import from Vocabulary Builder"),
            enabled_func = function() return has_book end,
            callback = function()
                Importer.showImportDialog(self)
            end,
        },
        {
            text = _("Settings"),
            callback = function() SettingsModule.show(self) end,
            separator = true,
        },
        {
            text = _("About SmartDeck"),
            keep_menu_open = true,
            callback = function()
                local provider = self:getActiveProvider() or _("(not configured)")
                local model
                if self.querier and self.querier:isInited() then
                    model = self.querier:getModel() or "-"
                else
                    model = "-"
                end
                local cfg_status
                if self.CONFIGURATION then
                    cfg_status = _("Loaded")
                elseif CONFIG_ERROR then
                    cfg_status = CONFIG_ERROR
                else
                    cfg_status = _("smartdeck_configuration.lua not found")
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("SmartDeck\n\nProvider: %s\nModel: %s\nConfig: %s"),
                        provider, model, cfg_status
                    ),
                    timeout = 6,
                })
            end,
        },
    }
end

function SmartDeck:openStudy()
    local total = DB.getCardCountForBook(nil)
    if total == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards yet. Add words or phrases from the highlight menu or dictionary popup."),
            timeout = 4,
        })
        return
    end
    local StudyScreen = require("smartdeck_study")
    local study = StudyScreen:new{ plugin = self }
    UIManager:show(study)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function SmartDeck:init()
    DB.init()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    self.CONFIGURATION = CONFIGURATION

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Load AI provider lazily so the plugin still works if the configuration
    -- is missing (adding cards without AI).
    if CONFIGURATION then
        self.querier = Querier:new{ plugin = self }
        local provider = self:getActiveProvider()
        if provider then
            local ok, err = self.querier:loadProvider(provider)
            if not ok then
                logger.warn("smartdeck: unable to load provider", provider, err)
            end
        end
    end

    -- Register SmartDeck button with new KOReader dict API (PR #15184+)
    -- Safe no-op on older versions where addToDictButtons doesn't exist.
    if self.ui and self.ui.dictionary
        and type(self.ui.dictionary.addToDictButtons) == "function" then
        self.ui.dictionary:addToDictButtons({
            id = "smartdeck_add",
            text = _("Add to SmartDeck"),
            callback = self:_buildSmartDeckDictButton(nil).callback,
        })
    end
end

function SmartDeck:onReaderReady()
    if not self.ui then return end

    -- Highlight menu entry.
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("smartdeck_add", function(reader_highlight)
            return {
                text = _("Add to SmartDeck"),
                callback = function()
                    self:addFromHighlight(reader_highlight)
                end,
            }
        end)
    end
end

-- Builds the SmartDeck button spec for the dict popup.
-- Used by both the new addToDictButtons API and the legacy onDictButtonsReady hook.
function SmartDeck:_buildSmartDeckDictButton(dict_popup_arg)
    -- dict_popup_arg is either:
    -- new API: the DictQuickLookup widget instance (passed by KOReader as arg to callback)
    -- old API: the dict_popup captured as upvalue in onDictButtonsReady
    return {
        text = _("Add to SmartDeck"),
        callback = function(widget_instance)
            -- In new API, widget_instance is passed. In old API, use upvalue.
            local popup = widget_instance or dict_popup_arg
            local word = popup and popup.word
            self:addFromDictionary(word)
        end,
    }
end

-- Dictionary popup integration. The DictButtonsReady event is fired by
-- dictquicklookup.lua as it assembles its action rows. `dict_buttons` is a
-- 2-D array (rows of buttons), so we inject a new row holding the SmartDeck
-- button just below the built-in row.
function SmartDeck:onDictButtonsReady(dict_popup, dict_buttons)
    if not dict_popup or type(dict_buttons) ~= "table" then return end
    -- If new KOReader API is present, we already registered at init() time.
    -- This hook won't be called on new KOReader anyway, but guard for safety.
    if self.ui and self.ui.dictionary
        and type(self.ui.dictionary.addToDictButtons) == "function" then
        return
    end

    local btn = self:_buildSmartDeckDictButton(dict_popup)
    local row = { {
        id = "smartdeck_add",
        text = btn.text,
        font_bold = true,
        callback = function() btn.callback(nil) end,
    } }
    local insert_index = #dict_buttons > 1 and 2 or 1
    table.insert(dict_buttons, insert_index, row)
end

return SmartDeck
