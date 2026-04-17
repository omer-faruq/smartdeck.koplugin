-- SmartDeck SQLite database module.
--
-- Holds books and AI-enriched cards (pronunciation, meaning, type, examples)
-- plus SM-2 style scheduling state and a per-book daily new-card counter.
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")

local DB = {}

local DB_SCHEMA_VERSION = 1
local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "smartdeck")
local DB_PATH = ffiUtil.joinPath(DB_DIRECTORY, "smartdeck.sqlite3")

local SCHEMA_STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        filepath TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE TABLE IF NOT EXISTS cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        phrase TEXT NOT NULL,
        sentence TEXT NOT NULL DEFAULT '',
        ai_context TEXT NOT NULL DEFAULT '',
        display_context TEXT NOT NULL DEFAULT '',
        pronunciation TEXT NOT NULL DEFAULT '',
        meaning TEXT NOT NULL DEFAULT '',
        word_type TEXT NOT NULL DEFAULT '',
        examples TEXT NOT NULL DEFAULT '',
        user_note TEXT NOT NULL DEFAULT '',
        ai_status INTEGER NOT NULL DEFAULT 0,
        ai_error TEXT NOT NULL DEFAULT '',
        ease REAL NOT NULL DEFAULT 2.5,
        interval REAL NOT NULL DEFAULT 0,
        due INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        reps INTEGER NOT NULL DEFAULT 0,
        lapses INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_book ON cards(book_id)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_book_due ON cards(book_id, due)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_ai_status ON cards(ai_status)]],
    [[CREATE TABLE IF NOT EXISTS daily_new_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        date TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        UNIQUE(book_id, date)
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_daily_new_cards_book_date ON daily_new_cards(book_id, date)]],
}

-- ai_status values:
-- 0 = pending enrichment, needs AI fetch
-- 1 = enriched successfully
-- 2 = AI fetch failed last time (retry allowed)
DB.STATUS_PENDING = 0
DB.STATUS_ENRICHED = 1
DB.STATUS_ERROR = 2

local initialized = false

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = util.trim(statement)
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("smartdeck sqlite schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

local function ensureDirectory()
    local ok, err = util.makePath(DB_DIRECTORY)
    if not ok then
        logger.warn("smartdeck: unable to create database directory", err)
    end
end

local function openConnection()
    ensureDirectory()
    local conn = SQ3.open(DB_PATH)
    conn:exec("PRAGMA foreign_keys = ON;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA journal_mode = WAL;")
    return conn
end

local function withConnection(fn)
    local conn = openConnection()
    local results = { pcall(fn, conn) }
    conn:close()
    if not results[1] then
        error(results[2])
    end
    return table.unpack(results, 2)
end

function DB.init()
    if initialized then
        return
    end
    ensureDirectory()
    local conn = openConnection()
    local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if current_version < DB_SCHEMA_VERSION then
        conn:exec("PRAGMA writable_schema = ON;")
        conn:exec("DELETE FROM sqlite_master WHERE type IN ('table','index','trigger');")
        conn:exec("PRAGMA writable_schema = OFF;")
        conn:exec("VACUUM;")
        execStatements(conn, SCHEMA_STATEMENTS)
        conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
    else
        execStatements(conn, SCHEMA_STATEMENTS)
    end
    conn:close()
    initialized = true
end

local function coerceNumber(value, default)
    if value == nil then
        return default
    end
    local n = tonumber(value)
    if not n then
        return default
    end
    return n
end

-- ── Book CRUD ──────────────────────────────────────────────────────────────

function DB.getOrCreateBook(title, filepath)
    if not filepath or filepath == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local existing_id = conn:rowexec(
            string.format("SELECT id FROM books WHERE filepath = '%s';", filepath:gsub("'", "''"))
        )
        if existing_id then
            return tonumber(existing_id)
        end
        local stmt = conn:prepare("INSERT INTO books (title, filepath) VALUES (?, ?);")
        stmt:bind(title or "", filepath)
        stmt:step()
        stmt:close()
        local new_id = conn:rowexec("SELECT last_insert_rowid();")
        return new_id and tonumber(new_id) or nil
    end)
end

function DB.listBooks()
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT b.id, b.title, b.filepath, COUNT(c.id) AS card_count
            FROM books b
            LEFT JOIN cards c ON c.book_id = b.id
            GROUP BY b.id, b.title, b.filepath
            ORDER BY b.title COLLATE NOCASE;]])
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[0] or #rows[0] == 0 then
            return {}
        end
        local headers = rows[0]
        local list = {}
        if not rows[1] then return list end
        for i = 1, #rows[1] do
            local row = {}
            for col_index, col_name in ipairs(headers) do
                local column_values = rows[col_index]
                row[col_name] = column_values[i]
            end
            list[#list + 1] = {
                id = coerceNumber(row.id, nil),
                title = tostring(row.title or ""),
                filepath = tostring(row.filepath or ""),
                card_count = coerceNumber(row.card_count, 0),
            }
        end
        return list
    end)
end

function DB.getBookTitle(book_id)
    if not book_id then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        return conn:rowexec(string.format("SELECT title FROM books WHERE id = %d;", book_id))
    end)
end

function DB.deleteBook(book_id)
    if not book_id then
        return false
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("DELETE FROM cards WHERE book_id = ?;")
        stmt:bind(book_id); stmt:step(); stmt:close()
        stmt = conn:prepare("DELETE FROM daily_new_cards WHERE book_id = ?;")
        stmt:bind(book_id); stmt:step(); stmt:close()
        stmt = conn:prepare("DELETE FROM books WHERE id = ?;")
        stmt:bind(book_id); stmt:step(); stmt:close()
        return true
    end)
end

-- ── Card CRUD ──────────────────────────────────────────────────────────────

-- card_data: {phrase, sentence, ai_context, display_context, user_note, ai_status?}
function DB.addCard(book_id, card_data)
    if not book_id or not card_data or not card_data.phrase or card_data.phrase == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[INSERT INTO cards
            (book_id, phrase, sentence, ai_context, display_context, user_note, ai_status)
            VALUES (?, ?, ?, ?, ?, ?, ?);]])
        stmt:bind(
            book_id,
            card_data.phrase,
            card_data.sentence or "",
            card_data.ai_context or "",
            card_data.display_context or "",
            card_data.user_note or "",
            card_data.ai_status or DB.STATUS_PENDING
        )
        stmt:step()
        stmt:close()
        local new_id = conn:rowexec("SELECT last_insert_rowid();")
        return new_id and tonumber(new_id) or nil
    end)
end

function DB.deleteCard(card_id)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("DELETE FROM cards WHERE id = ?;")
        stmt:bind(card_id); stmt:step(); stmt:close()
        return true
    end)
end

-- Delete every card that belongs to `book_id` together with the book row
-- itself. Returns the number of cards that were removed.
function DB.deleteBookAndCards(book_id)
    if not book_id then return 0 end
    DB.init()
    return withConnection(function(conn)
        local count_stmt = conn:prepare("SELECT COUNT(*) AS n FROM cards WHERE book_id = ?;")
        count_stmt:bind(book_id)
        local row = count_stmt:step()
        local deleted = row and coerceNumber(row.n, 0) or 0
        count_stmt:close()

        local del_cards = conn:prepare("DELETE FROM cards WHERE book_id = ?;")
        del_cards:bind(book_id); del_cards:step(); del_cards:close()

        local del_book = conn:prepare("DELETE FROM books WHERE id = ?;")
        del_book:bind(book_id); del_book:step(); del_book:close()
        return deleted
    end)
end

local function mapCardRow(row)
    if not row then return nil end
    return {
        id = coerceNumber(row.id, nil),
        book_id = coerceNumber(row.book_id, nil),
        phrase = row.phrase or "",
        sentence = row.sentence or "",
        ai_context = row.ai_context or "",
        display_context = row.display_context or "",
        pronunciation = row.pronunciation or "",
        meaning = row.meaning or "",
        word_type = row.word_type or "",
        examples = row.examples or "",
        user_note = row.user_note or "",
        ai_status = coerceNumber(row.ai_status, DB.STATUS_PENDING),
        ai_error = row.ai_error or "",
        ease = coerceNumber(row.ease, 2.5),
        interval = coerceNumber(row.interval, 0),
        due = coerceNumber(row.due, os.time()),
        reps = coerceNumber(row.reps, 0),
        lapses = coerceNumber(row.lapses, 0),
    }
end

local CARD_SELECT_COLUMNS = table.concat({
    "id", "book_id", "phrase", "sentence", "ai_context", "display_context",
    "pronunciation", "meaning", "word_type", "examples", "user_note",
    "ai_status", "ai_error", "ease", "interval", "due", "reps", "lapses",
}, ", ")

local function fetchSingle(conn, sql)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] or #rows[1] == 0 then
        return nil
    end
    local headers = rows[0]
    local row = {}
    for header_index, header in ipairs(headers) do
        row[header] = rows[header_index][1]
    end
    return mapCardRow(row)
end

local function fetchList(conn, sql)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] then return {} end
    local headers = rows[0]
    local list = {}
    for i = 1, #rows[1] do
        local row = {}
        for header_index, header in ipairs(headers) do
            row[header] = rows[header_index][i]
        end
        list[#list + 1] = mapCardRow(row)
    end
    return list
end

function DB.getCard(card_id)
    if not card_id then return nil end
    DB.init()
    return withConnection(function(conn)
        local sql = string.format("SELECT %s FROM cards WHERE id = %d;", CARD_SELECT_COLUMNS, card_id)
        return fetchSingle(conn, sql)
    end)
end

function DB.listCards(book_id, include_enriched_only)
    DB.init()
    return withConnection(function(conn)
        local where = ""
        if book_id then
            where = string.format(" WHERE book_id = %d", book_id)
        end
        if include_enriched_only then
            if where == "" then
                where = " WHERE ai_status = 1"
            else
                where = where .. " AND ai_status = 1"
            end
        end
        local sql = string.format("SELECT %s FROM cards%s ORDER BY created_at DESC;",
            CARD_SELECT_COLUMNS, where)
        return fetchList(conn, sql)
    end)
end

function DB.listPendingCards(book_id)
    DB.init()
    return withConnection(function(conn)
        local where = " WHERE ai_status <> 1"
        if book_id then
            where = where .. string.format(" AND book_id = %d", book_id)
        end
        local sql = string.format("SELECT %s FROM cards%s ORDER BY created_at ASC;",
            CARD_SELECT_COLUMNS, where)
        return fetchList(conn, sql)
    end)
end

function DB.getCardCountForBook(book_id)
    DB.init()
    return withConnection(function(conn)
        local query
        if book_id then
            query = string.format("SELECT COUNT(*) FROM cards WHERE book_id = %d;", book_id)
        else
            query = "SELECT COUNT(*) FROM cards;"
        end
        return tonumber(conn:rowexec(query)) or 0
    end)
end

function DB.getPendingCountForBook(book_id)
    DB.init()
    return withConnection(function(conn)
        local query
        if book_id then
            query = string.format("SELECT COUNT(*) FROM cards WHERE ai_status <> 1 AND book_id = %d;", book_id)
        else
            query = "SELECT COUNT(*) FROM cards WHERE ai_status <> 1;"
        end
        return tonumber(conn:rowexec(query)) or 0
    end)
end

function DB.phraseExists(book_id, phrase)
    if not book_id or not phrase or phrase == "" then
        return false
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT id FROM cards WHERE book_id = ? AND phrase = ? LIMIT 1;")
        stmt:bind(book_id, phrase)
        local row = stmt:step()
        stmt:close()
        return row ~= nil
    end)
end

-- Apply AI enrichment result to a card.
-- result: {pronunciation, meaning, word_type, examples, status, error}
function DB.applyEnrichment(card_id, result)
    if not card_id or not result then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            pronunciation = ?, meaning = ?, word_type = ?, examples = ?,
            ai_status = ?, ai_error = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(
            result.pronunciation or "",
            result.meaning or "",
            result.word_type or "",
            result.examples or "",
            result.status or DB.STATUS_ENRICHED,
            result.error or "",
            os.time(),
            card_id
        )
        stmt:step()
        stmt:close()
        return true
    end)
end

-- Replace phrase/context fields (after an edit). When clear_ai is true, the
-- AI-sourced fields are wiped and the status is reset to pending.
function DB.updateCardContent(card_id, fields, clear_ai)
    if not card_id or not fields then return false end
    DB.init()
    return withConnection(function(conn)
        if clear_ai then
            local stmt = conn:prepare([[UPDATE cards SET
                phrase = ?, sentence = ?, ai_context = ?, display_context = ?,
                user_note = ?, pronunciation = '', meaning = '', word_type = '',
                examples = '', ai_status = 0, ai_error = '', updated_at = ?
                WHERE id = ?;]])
            stmt:bind(
                fields.phrase or "",
                fields.sentence or "",
                fields.ai_context or "",
                fields.display_context or "",
                fields.user_note or "",
                os.time(),
                card_id
            )
            stmt:step()
            stmt:close()
        else
            local stmt = conn:prepare([[UPDATE cards SET
                phrase = ?, sentence = ?, ai_context = ?, display_context = ?,
                user_note = ?, updated_at = ? WHERE id = ?;]])
            stmt:bind(
                fields.phrase or "",
                fields.sentence or "",
                fields.ai_context or "",
                fields.display_context or "",
                fields.user_note or "",
                os.time(),
                card_id
            )
            stmt:step()
            stmt:close()
        end
        return true
    end)
end

-- ── SM-2 scheduling (mirrors phrasedeck) ──────────────────────────────────

local function computeScheduling(card, rating, now_ts, min_interval_days)
    local ease = card.ease or 2.5
    local interval = card.interval or 0
    local reps = card.reps or 0
    local lapses = card.lapses or 0
    local now = now_ts or os.time()
    local min_interval_multiplier = tonumber(min_interval_days) or 0

    local is_new = (interval == 0) and (reps == 0)

    if is_new then
        if rating == "again" then
            lapses = lapses + 1
            ease = math.max(1.3, ease - 0.2)
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier
                return ease, interval, reps, lapses, now + interval * 86400
            end
            return ease, interval, reps, lapses, now + 60
        elseif rating == "hard" then
            reps = reps + 1
            ease = math.max(1.3, ease - 0.15)
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier * 1.5
                return ease, interval, reps, lapses, now + interval * 86400
            end
            return ease, interval, reps, lapses, now + 6 * 60
        elseif rating == "good" then
            reps = reps + 1
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier * 2
                return ease, interval, reps, lapses, now + interval * 86400
            end
            return ease, interval, reps, lapses, now + 10 * 60
        elseif rating == "easy" then
            reps = reps + 1
            ease = ease + 0.15
            interval = min_interval_multiplier > 0 and (min_interval_multiplier * 4) or 4
            return ease, interval, reps, lapses, now + interval * 86400
        end
    end

    if rating == "again" then
        reps = 0
        lapses = lapses + 1
        ease = math.max(1.3, ease - 0.2)
        if min_interval_multiplier > 0 then
            interval = min_interval_multiplier
            return ease, interval, reps, lapses, now + interval * 86400
        end
        interval = 0
        return ease, interval, reps, lapses, now + 10 * 60
    elseif rating == "hard" then
        reps = reps + 1
        ease = math.max(1.3, ease - 0.15)
        if interval < 1 then interval = 1 end
        interval = interval * 1.2
        if min_interval_multiplier > 0 then
            interval = math.max(interval, min_interval_multiplier * 1.5)
        end
        return ease, interval, reps, lapses, now + interval * 86400
    elseif rating == "good" then
        reps = reps + 1
        if interval == 0 then interval = 1 else interval = interval * ease end
        if min_interval_multiplier > 0 then
            interval = math.max(interval, min_interval_multiplier * 2)
        end
        return ease, interval, reps, lapses, now + interval * 86400
    elseif rating == "easy" then
        reps = reps + 1
        ease = ease + 0.15
        if interval == 0 then interval = 3 else interval = interval * ease * 1.3 end
        if min_interval_multiplier > 0 then
            interval = math.max(interval, min_interval_multiplier * 4)
        end
        return ease, interval, reps, lapses, now + interval * 86400
    end

    return ease, interval, reps, lapses, card.due or now
end

local function formatDelta(delta)
    if delta <= 0 then return "0m" end
    if delta < 3600 then return tostring(math.floor(delta / 60 + 0.5)) .. "m" end
    if delta < 86400 then return tostring(math.floor(delta / 3600 + 0.5)) .. "h" end
    return tostring(math.floor(delta / 86400 + 0.5)) .. "d"
end

local function getTodayDateString()
    return os.date("%Y-%m-%d", os.time())
end

function DB.getDailyNewCardsCount(book_id)
    DB.init()
    if not book_id then return 0 end
    local today = getTodayDateString()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT count FROM daily_new_cards WHERE book_id = ? AND date = ?;")
        stmt:bind(book_id, today)
        local row = stmt:step()
        stmt:close()
        if row and row[1] then
            return tonumber(row[1]) or 0
        end
        return 0
    end)
end

function DB.incrementDailyNewCardsCount(book_id)
    DB.init()
    if not book_id then return end
    local today = getTodayDateString()
    withConnection(function(conn)
        local stmt = conn:prepare([[INSERT INTO daily_new_cards (book_id, date, count) VALUES (?, ?, 1)
            ON CONFLICT(book_id, date) DO UPDATE SET count = count + 1;]])
        stmt:bind(book_id, today); stmt:step(); stmt:close()
    end)
end

function DB.fetchNextDueCard(book_id, now_ts, randomize, daily_new_limit, require_enriched)
    DB.init()
    local now = now_ts or os.time()
    return withConnection(function(conn)
        randomize = not not randomize
        local new_limit = tonumber(daily_new_limit) or 0

        local book_filter = ""
        if book_id then
            book_filter = string.format(" AND book_id = %d", book_id)
        end

        local enriched_filter = ""
        if require_enriched then
            enriched_filter = " AND ai_status = 1"
        end

        local skip_new = false
        if new_limit > 0 and book_id then
            local today = getTodayDateString()
            local count_stmt = conn:prepare("SELECT count FROM daily_new_cards WHERE book_id = ? AND date = ?;")
            count_stmt:bind(book_id, today)
            local count_row = count_stmt:step()
            count_stmt:close()
            if count_row and count_row[1] then
                if (tonumber(count_row[1]) or 0) >= new_limit then
                    skip_new = true
                end
            end
        end

        local new_filter = ""
        if skip_new then
            new_filter = " AND NOT (reps = 0 AND interval = 0)"
        end

        local sql
        if randomize then
            sql = string.format([[WITH mindue AS (
                    SELECT MIN(due) AS due FROM cards WHERE due <= %d%s%s%s
                ), candidates AS (
                    SELECT id FROM cards WHERE due = (SELECT due FROM mindue)%s%s%s
                ), stats AS (
                    SELECT COUNT(*) AS cnt FROM candidates
                ), picked AS (
                    SELECT id FROM candidates
                    LIMIT 1
                    OFFSET (
                        CASE
                            WHEN (SELECT cnt FROM stats) <= 1 THEN 0
                            ELSE (abs(random()) %% (SELECT cnt FROM stats))
                        END
                    )
                )
                SELECT %s FROM cards WHERE id = (SELECT id FROM picked) LIMIT 1;]],
                now, book_filter, new_filter, enriched_filter,
                book_filter, new_filter, enriched_filter,
                CARD_SELECT_COLUMNS)
        else
            sql = string.format([[SELECT %s FROM cards WHERE due <= %d%s%s%s
                ORDER BY due ASC LIMIT 1;]],
                CARD_SELECT_COLUMNS, now, book_filter, new_filter, enriched_filter)
        end
        return fetchSingle(conn, sql)
    end)
end

function DB.previewIntervals(card, now_ts, min_interval_days)
    if not card or not card.id then return nil end
    local now = now_ts or os.time()
    local result = {}
    local ratings = { "again", "hard", "good", "easy" }
    for _, rating in ipairs(ratings) do
        local ease, interval, reps, lapses, due = computeScheduling(card, rating, now, min_interval_days)
        result[rating] = {
            ease = ease, interval = interval, reps = reps, lapses = lapses,
            due = due, label = formatDelta(due - now),
        }
    end
    return result
end

function DB.updateCardScheduling(card, rating, now_ts, min_interval_days)
    if not card or not card.id then return nil end
    DB.init()
    local now = now_ts or os.time()
    local new_ease, new_interval, new_reps, new_lapses, new_due =
        computeScheduling(card, rating, now, min_interval_days)
    withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards
            SET ease = ?, interval = ?, due = ?, reps = ?, lapses = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(new_ease, new_interval, new_due, new_reps, new_lapses, now, card.id)
        stmt:step()
        stmt:close()
    end)
    card.ease = new_ease
    card.interval = new_interval
    card.due = new_due
    card.reps = new_reps
    card.lapses = new_lapses
    return card
end

return DB
