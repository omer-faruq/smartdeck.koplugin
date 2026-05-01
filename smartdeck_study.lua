-- SmartDeck study screen.
--
-- Structurally similar to PhraseDeck's study screen, but the front and back of
-- each card are assembled from the field-visibility toggles stored via
-- smartdeck_settings. The user can choose which subset of the enriched fields
-- (phrase, pronunciation, word_type, meaning, examples, sentence, context,
-- note) is shown on each side – mirrors the AnkiViewer pattern.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local DB = require("smartdeck_db")
local Enrich = require("smartdeck_enrich")
local SettingsModule = require("smartdeck_settings")

local VERTICAL_SPAN_SMALL = rawget(Size.span, "vertical_small")
    or rawget(Size.span, "vertical_default")
    or rawget(Size.span, "vertical_large")
    or 0

local StudyScreen = InputContainer:extend{}

-- ── Text assembly helpers ────────────────────────────────────────────────

local function appendSection(parts, label, text)
    if not text or text == "" then return end
    if label and label ~= "" then
        parts[#parts + 1] = "【" .. label .. "】"
    end
    parts[#parts + 1] = text
end

-- Build the content for one side of the card.
--
-- `show_labels` controls whether section markers like 【Pronunciation】 are
-- printed before each field. When false, fields are concatenated as bare
-- paragraphs which lets the content fit on smaller screens. The full-text
-- viewer called by tapping the card always passes true so the user can see
-- the structured view regardless of the compact setting.
local function buildSide(card, field_state, show_labels)
    local parts = {}
    local function add(label, text)
        if not text or text == "" then return end
        if show_labels and label and label ~= "" then
            parts[#parts + 1] = "【" .. label .. "】 " .. text
        else
            parts[#parts + 1] = text
        end
    end
    if field_state.phrase then
        add(nil, card.phrase or "")
    end
    if field_state.pronunciation then
        add(_("Pronunciation"), card.pronunciation)
    end
    if field_state.word_type then
        add(_("Type"), card.word_type)
    end
    if field_state.meaning then
        add(_("Meaning"), card.meaning)
    end
    if field_state.examples then
        local examples = Enrich.decodeExamples(card.examples)
        if #examples > 0 then
            if show_labels then
                parts[#parts + 1] = "【" .. _("Examples") .. "】"
            end
            for i, ex in ipairs(examples) do
                parts[#parts + 1] = string.format("%d. %s", i, ex)
            end
        end
    end
    if field_state.sentence then
        add(_("Sentence"), card.sentence)
    end
    if field_state.display_context then
        add(_("Context"), card.display_context)
    end
    if field_state.user_note then
        add(_("Note"), card.user_note)
    end
    if #parts == 0 then
        parts[#parts + 1] = card.phrase or ""
    end
    -- Single newline keeps the content compact enough to fit on-screen. The
    -- full-text viewer uses double newlines because it supports scrolling.
    return table.concat(parts, "\n")
end

-- ── StudyScreen ──────────────────────────────────────────────────────────

function StudyScreen:init()
    local Screen = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local books = DB.listBooks()
    local last_book_id = self.plugin and tonumber(self.plugin:readSetting("last_study_book_id"))
    self.book_id = nil
    self.book_title = _("All Books")
    if last_book_id then
        for _idx, b in ipairs(books) do
            if b.id == last_book_id then
                self.book_id = b.id
                self.book_title = b.title
                break
            end
        end
    end

    self.current_card = nil
    self.showing_back = false

    -- Match phrasedeck's proportions so we get the same stable layout.
    local card_width = math.floor(Screen:getWidth() * 0.85)
    local card_height = Size.item.height_large * 10
    local top_bottom_spacing = VERTICAL_SPAN_SMALL
    self.fullscreen_top_bottom_spacing = top_bottom_spacing

    local title_face = Font:getFace("cfont", 26)
    local title_height = math.floor((1 + 0.3) * title_face.size) * 2
    self.title_widget = TextBoxWidget:new{
        face = title_face,
        text = self.book_title or "",
        width = math.floor(Screen:getWidth() * 0.9),
        height = title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }

    local card_inner_width = card_width - (Size.margin.default * 2 + Size.padding.fullscreen * 2 + Size.border.window * 2)
    local card_inner_height = card_height - (Size.margin.default * 2 + Size.padding.fullscreen * 2 + Size.border.window * 2)
    self.card_widget = TextBoxWidget:new{
        face = Font:getFace("cfont"),
        text = "",
        width = card_inner_width,
        height = card_inner_height,
        alignment = "center",
        height_overflow_show_ellipsis = true,
    }
    self.card_full_text = ""

    self.card_container = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = card_width, h = card_height },
        CenterContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = card_width, h = card_height },
            self.card_widget,
        },
    }
    if Device:isTouchDevice() then
        self.card_container.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = self.card_container.dimen,
                },
            },
        }
        self.card_container.onTap = function()
            self:showFullText()
            return true
        end
    end

    self.card_frame = FrameContainer:new{
        padding = Size.padding.fullscreen,
        margin = Size.margin.default,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        self.card_container,
    }

    local function makeToolbarButton(text, callback)
        return Button:new{
            text = text,
            background = Blitbuffer.COLOR_WHITE,
            callback = callback,
            text_font_face = "cfont",
            text_font_size = 22,
            text_font_bold = false,
            bordersize = 0,
            margin = 0,
            radius = 0,
        }
    end

    self.books_button = makeToolbarButton(_("Books"), function() self:showBookSelection() end)
    self.settings_button = makeToolbarButton(_("Settings"), function() self:showFieldMenu() end)
    self.close_button = makeToolbarButton(_("Close"), function() self:onClose() end)

    local separator = function()
        return TextWidget:new{ face = Font:getFace("cfont", 22), text = "|" }
    end

    local top_controls = HorizontalGroup:new{
        align = "center",
        self.books_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        separator(),
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.settings_button,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        separator(),
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        self.close_button,
    }

    local top_bar = VerticalGroup:new{
        align = "center",
        top_controls,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.title_widget,
    }

    -- Show-answer button
    local show_row = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.85),
        buttons = {
            {
                {
                    id = "show_button",
                    text = _("Show answer"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() self:onShowOrNext() end,
                },
            },
        },
    }
    self.show_button = show_row:getButtonById("show_button")

    -- Rating buttons
    local btn_width = math.floor(Screen:getWidth() * 0.18)
    local function makeRatingButton(text, callback)
        return Button:new{
            text = text,
            background = Blitbuffer.COLOR_WHITE,
            callback = callback,
            width = btn_width,
            bordersize = 0,
            margin = 0,
            radius = 0,
        }
    end
    self.again_button  = makeRatingButton(_("Again"), function() self:onRate("again") end)
    self.hard_button   = makeRatingButton(_("Hard"),  function() self:onRate("hard")  end)
    self.good_button   = makeRatingButton(_("Good"),  function() self:onRate("good")  end)
    self.easy_button   = makeRatingButton(_("Easy"),  function() self:onRate("easy")  end)
    self.delete_button = makeRatingButton(_("Delete"), function() self:onDeleteCard() end)

    local small_interval_face = Font:getFace("smallinfofont",
        math.floor(Font.sizemap.smallinfofont * 0.85))
    self.interval_again = TextWidget:new{ face = small_interval_face, text = "" }
    self.interval_hard  = TextWidget:new{ face = small_interval_face, text = "" }
    self.interval_good  = TextWidget:new{ face = small_interval_face, text = "" }
    self.interval_easy  = TextWidget:new{ face = small_interval_face, text = "" }

    local function ratingCol(label_widget, button, rate_name)
        local inner = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = btn_width, h = small_interval_face.size },
                label_widget,
            },
            VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
            button,
        }
        local container = InputContainer:new{
            inner,
            dimen = Geom:new{ w = btn_width, h = inner:getSize().h },
        }
        container.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return container.dimen end,
                },
            },
        }
        container.onTap = function() self:onRate(rate_name) end
        return container
    end

    local col_again = ratingCol(self.interval_again, self.again_button, "again")
    local col_hard  = ratingCol(self.interval_hard,  self.hard_button,  "hard")
    local col_good  = ratingCol(self.interval_good,  self.good_button,  "good")
    local col_easy  = ratingCol(self.interval_easy,  self.easy_button,  "easy")

    local col_delete_inner = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = btn_width, h = small_interval_face.size },
            TextWidget:new{ face = small_interval_face, text = "" },
        },
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.delete_button,
    }
    local col_delete = InputContainer:new{
        col_delete_inner,
        dimen = Geom:new{ w = btn_width, h = col_delete_inner:getSize().h },
    }
    col_delete.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return col_delete.dimen end,
            },
        },
    }
    col_delete.onTap = function() self:onDeleteCard() end

    local rating_row = HorizontalGroup:new{
        align = "center",
        col_again,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_hard,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_good,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_easy,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        col_delete,
    }

    self.front_layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        top_bar,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.card_frame,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        show_row,
        VerticalSpan:new{ width = Size.padding.small },
    }

    self.back_layout = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        top_bar,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        self.card_frame,
        VerticalSpan:new{ width = VERTICAL_SPAN_SMALL },
        rating_row,
        VerticalSpan:new{ width = Size.padding.small },
    }

    self[1] = self.front_layout
    self:setRatingButtonsEnabled(false)
    self:setShowButtonVisible(true)
    self:loadNextCard()

    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function StudyScreen:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function StudyScreen:setRatingButtonsEnabled(enabled)
    local flag = not not enabled
    if self.again_button  then self.again_button:enableDisable(flag)  end
    if self.hard_button   then self.hard_button:enableDisable(flag)   end
    if self.good_button   then self.good_button:enableDisable(flag)   end
    if self.easy_button   then self.easy_button:enableDisable(flag)   end
    if self.delete_button then self.delete_button:enableDisable(flag) end
end

function StudyScreen:setShowButtonVisible(visible)
    if not self.show_button then return end
    if visible then
        self.show_button:enableDisable(true)
        self.show_button:setText(_("Show answer"))
    else
        self.show_button:enableDisable(false)
        self.show_button:setText("")
    end
end

function StudyScreen:updateRatingLabels(previews)
    if not previews then return end
    local function setLabel(widget, key)
        local info = previews[key]
        if info and widget then widget:setText(info.label or "") end
    end
    setLabel(self.interval_again, "again")
    setLabel(self.interval_hard,  "hard")
    setLabel(self.interval_good,  "good")
    setLabel(self.interval_easy,  "easy")
end

function StudyScreen:loadNextCard()
    local plugin = self.plugin
    local randomize = plugin and plugin:readSetting("randomize_cards", false) or false
    local daily_new_limit = plugin and (tonumber(plugin:readSetting("daily_new_cards_limit", 20)) or 20) or 20
    -- Default ON: when no preference has been persisted we skip cards that
    -- are still pending AI enrichment so the user is not shown bare phrases.
    local require_enriched
    if plugin then
        local v = plugin:readSetting("require_enriched_for_study")
        if v == nil then
            require_enriched = true
        else
            require_enriched = v and true or false
        end
    else
        require_enriched = true
    end

    local card = DB.fetchNextDueCard(self.book_id, nil, randomize, daily_new_limit, require_enriched)
    if not card then
        self.current_card = nil
        self.showing_back = false
        self.card_widget:setText(_("No cards due."))
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(false)
        self[1] = self.front_layout
        self:refresh()
        return
    end
    self.current_card = card
    self.showing_back = false
    local front_state = SettingsModule.getFieldState(plugin, "front")
    local show_labels = plugin and plugin:readSetting("show_section_labels", true) and true or false
    local front_text = buildSide(card, front_state, show_labels)
    -- Tapping the card always presents the labelled version.
    self.card_full_text = buildSide(card, front_state, true)
    self.card_widget:setText(front_text)
    self:setShowButtonVisible(true)
    self:setRatingButtonsEnabled(false)
    self[1] = self.front_layout
    self:refresh()
end

function StudyScreen:onShowOrNext()
    if not self.current_card then
        self:loadNextCard()
        return
    end
    if not self.showing_back then
        self.showing_back = true
        local plugin = self.plugin
        local back_state = SettingsModule.getFieldState(plugin, "back")
        local show_labels = plugin and plugin:readSetting("show_section_labels", true) and true or false
        local back_text = buildSide(self.current_card, back_state, show_labels)
        -- Full-text viewer always shows labelled, double-newline version.
        self.card_full_text = buildSide(self.current_card, back_state, true):gsub("\n", "\n\n")
        self.card_widget:setText(back_text)
        local min_interval = plugin and (tonumber(plugin:readSetting("min_interval_days", 0)) or 0) or 0
        local max_interval = plugin and (tonumber(plugin:readSetting("max_interval_days", 365)) or 365) or 365
        local algorithm_type = plugin and (plugin:readSetting("algorithm_type", "scheduled") or "scheduled") or "scheduled"
        local previews = DB.previewIntervals(self.current_card, nil, min_interval, max_interval, algorithm_type)
        self:updateRatingLabels(previews)
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(true)
        self[1] = self.back_layout
        self:refresh()
    end
end

function StudyScreen:showFullText()
    if not self.card_full_text or self.card_full_text == "" then return end
    UIManager:show(TextViewer:new{
        title = _("Full text"),
        text = self.card_full_text,
    })
end

function StudyScreen:onDeleteCard()
    if not self.current_card then return end
    UIManager:show(ConfirmBox:new{
        text = _("Delete this card?"),
        ok_text = _("Delete"),
        ok_callback = function()
            DB.deleteCard(self.current_card.id)
            self.current_card = nil
            self.showing_back = false
            self:loadNextCard()
        end,
    })
end

function StudyScreen:onRate(rating)
    if not self.current_card then return end
    local is_new_card = (self.current_card.reps == 0 and self.current_card.interval == 0)
    local plugin = self.plugin
    local min_interval = plugin and (tonumber(plugin:readSetting("min_interval_days", 0)) or 0) or 0
    local max_interval = plugin and (tonumber(plugin:readSetting("max_interval_days", 365)) or 365) or 365
    local algorithm_type = plugin and (plugin:readSetting("algorithm_type", "scheduled") or "scheduled") or "scheduled"
    DB.updateCardScheduling(self.current_card, rating, nil, min_interval, max_interval, algorithm_type)
    if is_new_card and self.book_id then
        DB.incrementDailyNewCardsCount(self.book_id)
    end
    self.current_card = nil
    self.showing_back = false
    self:loadNextCard()
end

function StudyScreen:showBookSelection()
    local study = self
    local menu
    local screen = Device.screen
    local title = _("Select book (hold to delete)")

    local function buildItems()
        local books = DB.listBooks()
        local items = {}
        table.insert(items, {
            text = string.format("%s (%d)", _("All Books"), DB.getCardCountForBook(nil)),
            callback = function()
                study.book_id = nil
                study.book_title = _("All Books")
                if study.title_widget then study.title_widget:setText(study.book_title) end
                if study.plugin then study.plugin:saveSetting("last_study_book_id", nil) end
                study:loadNextCard()
            end,
        })
        for _idx, b in ipairs(books) do
            local base = b.title or ""
            if base == "" then base = b.filepath or "Book" end
            local label = base
            if b.card_count and b.card_count > 0 then
                label = string.format("%s (%d)", base, b.card_count)
            end
            local book_id = b.id
            local book_title = b.title or ""
            table.insert(items, {
                text = label,
                book_id = book_id,
                callback = function()
                    study.book_id = book_id
                    study.book_title = book_title
                    if study.title_widget then study.title_widget:setText(study.book_title) end
                    if study.plugin then study.plugin:saveSetting("last_study_book_id", book_id) end
                    study:loadNextCard()
                end,
                -- Long-press on a book row prompts for confirmation and then
                -- wipes the book together with every card belonging to it.
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = string.format(
                            _("Delete book \"%s\" and all its %d cards? This cannot be undone."),
                            base, tonumber(b.card_count) or 0
                        ),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local deleted = DB.deleteBookAndCards(book_id) or 0
                            -- If the user was studying that book, fall back to All Books.
                            if study.book_id == book_id then
                                study.book_id = nil
                                study.book_title = _("All Books")
                                if study.title_widget then study.title_widget:setText(study.book_title) end
                                if study.plugin then study.plugin:saveSetting("last_study_book_id", nil) end
                                study:loadNextCard()
                            end
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Deleted %d cards."), deleted),
                                timeout = 2,
                            })
                            if menu and menu.switchItemTable then
                                menu:switchItemTable(title, buildItems())
                            end
                        end,
                    })
                end,
            })
        end
        return items
    end

    local items = buildItems()
    if #items <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("No books with cards yet. Add phrases from the highlight menu while reading."),
            timeout = 4,
        })
        return
    end

    menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }
    -- Default Menu:onMenuChoice closes the menu on tap; we keep the same
    -- behavior. Menu's default `onMenuHold` is a no-op, so we override it to
    -- forward hold gestures to the item's `hold_callback`.
    function menu:onMenuChoice(item)
        if item.callback then item.callback() end
        UIManager:close(self)
        return true
    end
    function menu:onMenuHold(item)
        if item and item.hold_callback then
            item.hold_callback()
        end
        return true
    end
    UIManager:show(menu)
end

function StudyScreen:showFieldMenu()
    -- Delegate directly to the main settings screen; the dedicated front/back
    -- pickers are reached from there and their state is persisted through the
    -- same path. Reloading the current card reflects the changes.
    local study = self
    SettingsModule.show(self.plugin)
    UIManager:scheduleIn(0.1, function()
        if study.current_card then
            if study.showing_back then
                study.showing_back = false
            end
            study:loadNextCard()
        end
    end)
end

function StudyScreen:onClose()
    UIManager:close(self)
    -- Request a full refresh so the reader screen behind us is redrawn
    -- cleanly (no leftover pixels from the deck screen).
    UIManager:setDirty(nil, "full")
    return true
end

function StudyScreen:onCloseWidget()
    -- Also fires on system dismissals (e.g. the user presses Back or switches
    -- documents). Same motivation as onClose.
    UIManager:setDirty(nil, "full")
end

-- Paint the whole fullscreen area with white before laying out the
-- internal widgets. This prevents leftover pixels from the previous screen
-- (reader, file manager, toolbars) bleeding through around the margins and
-- below the button row.
function StudyScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    if self[1] then
        local content_size = self[1]:getSize()
        local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
        local offset_y = y + math.floor((self.dimen.h - content_size.h) / 2)
        self[1]:paintTo(bb, offset_x, offset_y)
    end
end

return StudyScreen
