-- SmartDeck: import words from the KOReader Vocabulary Builder database.
--
-- The VocabBuilder plugin stores its entries in a SQLite database located at
-- `<settings_dir>/vocabulary_builder.sqlite3`. We only read from it; we never
-- write. Words are imported into the current book's deck; if the book has no
-- title registered in vocabulary_builder, all words are imported.
local _ = require("gettext")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")

local DB = require("smartdeck_db")
local Enrich = require("smartdeck_enrich")

local Importer = {}

local function getVocabDbPath()
    return ffiUtil.joinPath(DataStorage:getSettingsDir(), "vocabulary_builder.sqlite3")
end

local function vocabDbExists()
    return util.pathExists(getVocabDbPath())
end

-- Load words from vocabbuilder restricted to a specific title_id (book).
-- If book_title is nil or no matching title, return all words.
local function loadVocabWords(book_title)
    local path = getVocabDbPath()
    if not util.pathExists(path) then
        return nil, _("Vocabulary Builder database not found.")
    end
    local conn = SQ3.open(path)
    local title_id
    if book_title and book_title ~= "" then
        local escaped = book_title:gsub("'", "''")
        local stmt = conn:prepare("SELECT id FROM title WHERE name = ? LIMIT 1;")
        stmt:bind(book_title)
        local row = stmt:step()
        stmt:close()
        if row and row[1] then
            title_id = tonumber(row[1])
        end
    end

    local sql
    if title_id then
        sql = string.format(
            "SELECT word, prev_context, next_context FROM vocabulary WHERE title_id = %d ORDER BY create_time ASC;",
            title_id
        )
    else
        sql = "SELECT word, prev_context, next_context FROM vocabulary ORDER BY create_time ASC;"
    end

    local stmt = conn:prepare(sql)
    local words = {}
    while true do
        local row = stmt:step()
        if not row then break end
        words[#words + 1] = {
            word = row[1] or "",
            prev_context = row[2] or "",
            next_context = row[3] or "",
        }
    end
    stmt:close()
    conn:close()
    return words
end

-- Import entries belonging to the active book into `book_id`.
function Importer.importForBook(plugin, book_id, book_title)
    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot import — no book record is available."),
            timeout = 3,
        })
        return
    end
    if not vocabDbExists() then
        UIManager:show(InfoMessage:new{
            text = _("Vocabulary Builder database not found. Open a book and look up at least one word first."),
            timeout = 4,
        })
        return
    end

    local words, err = loadVocabWords(book_title)
    if not words then
        UIManager:show(InfoMessage:new{ text = err or _("Import failed."), timeout = 3 })
        return
    end
    if #words == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No words found for this book in Vocabulary Builder."),
            timeout = 3,
        })
        return
    end

    local ai_words = tonumber(plugin.settings:readSetting("ai_context_words", 30)) or 30
    local display_words = tonumber(plugin.settings:readSetting("display_context_words", 15)) or 15

    local imported = 0
    local skipped = 0
    for _, entry in ipairs(words) do
        local phrase = entry.word or ""
        if phrase ~= "" then
            if DB.phraseExists(book_id, phrase) then
                skipped = skipped + 1
            else
                local ai_context, display_context = Enrich.buildContextWindows(
                    phrase, entry.prev_context, entry.next_context, ai_words, display_words
                )
                local sentence = Enrich.extractSentence(phrase, entry.prev_context, entry.next_context)
                local ok = DB.addCard(book_id, {
                    phrase = phrase,
                    sentence = sentence,
                    ai_context = ai_context,
                    display_context = display_context,
                })
                if ok then imported = imported + 1 end
            end
        end
    end

    local msg = string.format(
        _("Imported %d new cards. Skipped %d duplicates."),
        imported, skipped
    )
    UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
    logger.info("smartdeck: vocabbuilder import", imported, skipped)
end

-- Ask the user how to scope the import (current book only vs. all entries)
-- and then run it.
function Importer.showImportDialog(plugin)
    local book_title = plugin:getDocumentTitle()
    local filepath = plugin:getDocumentFilePath()
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("Open a book before importing from Vocabulary Builder."),
            timeout = 3,
        })
        return
    end
    local book_id = DB.getOrCreateBook(book_title, filepath)
    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Could not prepare book record."),
            timeout = 3,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format(
            _("Import all Vocabulary Builder entries recorded for \"%s\" into this book's SmartDeck?"),
            book_title or _("this book")
        ),
        ok_text = _("Import"),
        ok_callback = function()
            Importer.importForBook(plugin, book_id, book_title)
        end,
    })
end

return Importer
