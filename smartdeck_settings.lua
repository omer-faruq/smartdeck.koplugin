-- SmartDeck settings dialog.
--
-- A single Menu widget that exposes the plugin's tunables. Most settings are
-- stored on `plugin.settings` (a LuaSettings instance on the plugin itself).
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("ui/widget/menu")
local Device = require("device")
local koutil = require("util")

local Settings = {}

-- Default state for the front/back field visibility.
Settings.DEFAULT_FRONT_FIELDS = {
    phrase = true,
    display_context = false,
    sentence = false,
    pronunciation = false,
    word_type = false,
    meaning = false,
    examples = false,
    user_note = false,
}
Settings.DEFAULT_BACK_FIELDS = {
    phrase = true,
    display_context = false,
    sentence = true,
    pronunciation = true,
    word_type = true,
    meaning = true,
    examples = true,
    user_note = true,
}

Settings.FIELD_LABELS = {
    { key = "phrase",          label = _("Phrase") },
    { key = "pronunciation",   label = _("Pronunciation") },
    { key = "word_type",       label = _("Word type") },
    { key = "meaning",         label = _("Meaning") },
    { key = "examples",        label = _("Examples") },
    { key = "sentence",        label = _("Source sentence") },
    { key = "display_context", label = _("Surrounding context") },
    { key = "user_note",       label = _("User note") },
}

local FIELD_MAP = {}
for _, f in ipairs(Settings.FIELD_LABELS) do
    FIELD_MAP[f.key] = f.label
end

function Settings.getFieldState(plugin, side)
    local setting_key = side == "front" and "front_fields" or "back_fields"
    local defaults = side == "front" and Settings.DEFAULT_FRONT_FIELDS or Settings.DEFAULT_BACK_FIELDS
    local state = plugin.settings:readSetting(setting_key)
    if type(state) ~= "table" then
        state = {}
    end
    local merged = {}
    for key, default_value in pairs(defaults) do
        if state[key] == nil then
            merged[key] = default_value
        else
            merged[key] = state[key] and true or false
        end
    end
    return merged
end

function Settings.setFieldState(plugin, side, state)
    local setting_key = side == "front" and "front_fields" or "back_fields"
    plugin.settings:saveSetting(setting_key, state)
    plugin.settings:flush()
end

-- Return a localized "Field A, Field B, …" string for display.
function Settings.describeFields(state)
    local parts = {}
    for _, f in ipairs(Settings.FIELD_LABELS) do
        if state[f.key] then parts[#parts + 1] = f.label end
    end
    if #parts == 0 then return _("(none)") end
    return table.concat(parts, ", ")
end

-- ── Sub-dialog helpers ───────────────────────────────────────────────────

local function listProviders(plugin)
    local config = plugin.CONFIGURATION
    if not config or type(config.provider_settings) ~= "table" then
        return {}
    end
    local names = {}
    for name, settings_table in pairs(config.provider_settings) do
        if settings_table.visible ~= false then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function showProviderPicker(plugin, on_change)
    local providers = listProviders(plugin)
    if #providers == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No providers are configured. Edit smartdeck_configuration.lua first."),
            timeout = 4,
        })
        return
    end
    local current = plugin.settings:readSetting("provider") or plugin:getDefaultProvider()
    local buttons = {}
    -- Use a named loop variable instead of `_` so the closures below can
    -- still reach the gettext `_` from the enclosing scope.
    local dialog
    for _idx, name in ipairs(providers) do
        local label = name
        if name == current then label = "• " .. name end
        buttons[#buttons + 1] = { {
            text = label,
            callback = function()
                -- Close the picker first so the follow-up InfoMessage is the
                -- topmost widget and the user isn't left with a stale popup.
                if dialog then UIManager:close(dialog) end
                plugin.settings:saveSetting("provider", name)
                plugin.settings:flush()
                local ok, err = plugin.querier:loadProvider(name)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = err or _("Failed to load provider."), timeout = 4 })
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Active provider: %s"), name),
                        timeout = 2,
                    })
                end
                if on_change then on_change() end
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title = _("Select AI provider"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local function showNumberInput(title, description, current, min_value, on_save)
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        description = description,
        input = tostring(current),
        input_type = "number",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = tonumber(input_dialog:getInputText()) or current
                    if min_value and value < min_value then value = min_value end
                    UIManager:close(input_dialog)
                    on_save(value)
                end,
            },
        } },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function showTextInput(title, description, current, on_save)
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        description = description,
        input = current or "",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = (input_dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(input_dialog)
                    on_save(text)
                end,
            },
        } },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function showFieldSelection(plugin, side, on_done)
    local state = Settings.getFieldState(plugin, side)
    local menu
    local title = side == "front" and _("Front side fields") or _("Back side fields")

    local function buildItems()
        local items = {}
        for _idx, f in ipairs(Settings.FIELD_LABELS) do
            local key = f.key
            local marker = state[key] and "☑" or "☐"
            table.insert(items, {
                text = marker .. "  " .. f.label,
                keep_menu_open = true,
                callback = function()
                    state[key] = not state[key]
                    Settings.setFieldState(plugin, side, state)
                    if menu and menu.switchItemTable then
                        menu:switchItemTable(title, buildItems())
                    end
                end,
            })
        end
        table.insert(items, {
            text = _("Close"),
            callback = function() if menu then UIManager:close(menu) end end,
        })
        return items
    end

    local screen = Device.screen
    menu = Menu:new{
        title = title,
        item_table = buildItems(),
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
        close_callback = function()
            if on_done then on_done() end
        end,
    }
    UIManager:show(menu)
end

-- ── Main entry point ─────────────────────────────────────────────────────

-- Trim a long mandatory string so it never eats into the item's text column,
-- which would trigger a "width must be strictly positive" paint error on
-- narrow screens. We cap to 28 visible characters.
local function shortMandatory(str)
    str = tostring(str or "")
    if #str <= 28 then return str end
    return str:sub(1, 26) .. "…"
end

local function boolMark(value)
    return value and "✓" or "✗"
end

function Settings.show(plugin)
    local menu
    local screen = Device.screen
    local title = _("SmartDeck Settings")

    local function readBool(key, default)
        local v = plugin.settings:readSetting(key)
        if v == nil then return default end
        return v and true or false
    end

    local function buildItems()
        local auto_fetch = readBool("auto_fetch", true)
        local randomize = readBool("randomize_cards", false)
        local require_enriched = readBool("require_enriched_for_study", true)
        local daily_limit = tonumber(plugin.settings:readSetting("daily_new_cards_limit", 20)) or 20
        local daily_label = daily_limit == 0 and _("Unlimited") or tostring(daily_limit)

        return {
            {
                text = _("AI provider"),
                mandatory = shortMandatory(plugin.settings:readSetting("provider")
                    or plugin:getDefaultProvider() or "-"),
                keep_menu_open = true,
                callback = function()
                    showProviderPicker(plugin, function()
                        if menu then menu:switchItemTable(title, buildItems()) end
                    end)
                end,
            },
            {
                text = _("Target language"),
                mandatory = shortMandatory(plugin.settings:readSetting("target_language", "English") or "English"),
                keep_menu_open = true,
                callback = function()
                    local current = plugin.settings:readSetting("target_language", "English") or "English"
                    showTextInput(
                        _("Target language"),
                        _("Language used for meanings generated by the AI (e.g. Turkish, English, German)."),
                        current,
                        function(value)
                            if value == "" then value = "English" end
                            plugin.settings:saveSetting("target_language", value)
                            plugin.settings:flush()
                            if menu then menu:switchItemTable(title, buildItems()) end
                        end
                    )
                end,
            },
            {
                text = _("AI context words"),
                mandatory = tostring(tonumber(plugin.settings:readSetting("ai_context_words", 30)) or 30),
                keep_menu_open = true,
                callback = function()
                    local current = tonumber(plugin.settings:readSetting("ai_context_words", 30)) or 30
                    showNumberInput(
                        _("AI context words"),
                        _("Number of words around the selection that will be sent to the AI as context. 0 = only the selected phrase."),
                        current, 0,
                        function(value)
                            plugin.settings:saveSetting("ai_context_words", value)
                            plugin.settings:flush()
                            if menu then menu:switchItemTable(title, buildItems()) end
                        end
                    )
                end,
            },
            {
                text = _("Display context words"),
                mandatory = tostring(tonumber(plugin.settings:readSetting("display_context_words", 15)) or 15),
                keep_menu_open = true,
                callback = function()
                    local current = tonumber(plugin.settings:readSetting("display_context_words", 15)) or 15
                    showNumberInput(
                        _("Display context words"),
                        _("Words around the phrase stored for display on cards. 0 = hide."),
                        current, 0,
                        function(value)
                            plugin.settings:saveSetting("display_context_words", value)
                            plugin.settings:flush()
                            if menu then menu:switchItemTable(title, buildItems()) end
                        end
                    )
                end,
            },
            {
                text = _("Example sentences per card"),
                mandatory = tostring(tonumber(plugin.settings:readSetting("example_count", 3)) or 3),
                keep_menu_open = true,
                callback = function()
                    local current = tonumber(plugin.settings:readSetting("example_count", 3)) or 3
                    showNumberInput(
                        _("Example sentences per card"),
                        _("How many example sentences the AI should return."),
                        current, 1,
                        function(value)
                            plugin.settings:saveSetting("example_count", value)
                            plugin.settings:flush()
                            if menu then menu:switchItemTable(title, buildItems()) end
                        end
                    )
                end,
            },
            {
                text = _("Auto fetch when online"),
                mandatory = boolMark(auto_fetch),
                keep_menu_open = true,
                callback = function()
                    plugin.settings:saveSetting("auto_fetch", not auto_fetch)
                    plugin.settings:flush()
                    if menu then menu:switchItemTable(title, buildItems()) end
                end,
            },
            {
                text = _("Prompt to edit phrase before saving"),
                mandatory = boolMark(readBool("ask_phrase_edit_on_add", true)),
                keep_menu_open = true,
                callback = function()
                    local current = readBool("ask_phrase_edit_on_add", true)
                    plugin.settings:saveSetting("ask_phrase_edit_on_add", not current)
                    plugin.settings:flush()
                    if menu then menu:switchItemTable(title, buildItems()) end
                end,
            },
            {
                text = _("Prompt for note before saving"),
                mandatory = boolMark(readBool("ask_note_on_add", true)),
                keep_menu_open = true,
                callback = function()
                    local current = readBool("ask_note_on_add", true)
                    plugin.settings:saveSetting("ask_note_on_add", not current)
                    plugin.settings:flush()
                    if menu then menu:switchItemTable(title, buildItems()) end
                end,
            },
            {
                text = _("Front side fields"),
                mandatory = shortMandatory(Settings.describeFields(Settings.getFieldState(plugin, "front"))),
                keep_menu_open = true,
                callback = function()
                    showFieldSelection(plugin, "front", function()
                        if menu then menu:switchItemTable(title, buildItems()) end
                    end)
                end,
            },
            {
                text = _("Back side fields"),
                mandatory = shortMandatory(Settings.describeFields(Settings.getFieldState(plugin, "back"))),
                keep_menu_open = true,
                callback = function()
                    showFieldSelection(plugin, "back", function()
                        if menu then menu:switchItemTable(title, buildItems()) end
                    end)
                end,
            },
            {
                text = _("Randomize cards with same due date"),
                mandatory = boolMark(randomize),
                keep_menu_open = true,
                callback = function()
                    plugin.settings:saveSetting("randomize_cards", not randomize)
                    plugin.settings:flush()
                    if menu then menu:switchItemTable(title, buildItems()) end
                end,
            },
            {
                text = _("Daily new cards limit"),
                mandatory = daily_label,
                keep_menu_open = true,
                callback = function()
                    showNumberInput(
                        _("Daily new cards limit"),
                        _("Maximum new cards per day per book. 0 = unlimited."),
                        daily_limit, 0,
                        function(value)
                            plugin.settings:saveSetting("daily_new_cards_limit", value)
                            plugin.settings:flush()
                            if menu then menu:switchItemTable(title, buildItems()) end
                        end
                    )
                end,
            },
            {
                text = _("Study only enriched cards"),
                mandatory = boolMark(require_enriched),
                keep_menu_open = true,
                callback = function()
                    -- Default is ON; storing the opposite persists the user
                    -- preference. We read the flag through `readBool` which
                    -- honours the default when the key is absent.
                    plugin.settings:saveSetting("require_enriched_for_study", not require_enriched)
                    plugin.settings:flush()
                    if menu then menu:switchItemTable(title, buildItems()) end
                end,
            },
            {
                text = _("Show section labels on cards"),
                mandatory = boolMark(readBool("show_section_labels", true)),
                keep_menu_open = true,
                callback = function()
                    local current = readBool("show_section_labels", true)
                    plugin.settings:saveSetting("show_section_labels", not current)
                    plugin.settings:flush()
                    if menu then menu:switchItemTable(title, buildItems()) end
                end,
            },
            {
                text = _("Close"),
                callback = function() if menu then UIManager:close(menu) end end,
            },
        }
    end

    menu = Menu:new{
        title = title,
        item_table = buildItems(),
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

return Settings
