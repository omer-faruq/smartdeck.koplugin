-- SmartDeck AI enrichment.
--
-- Handles the prompt construction and response parsing used to populate the
-- pronunciation / word_type / meaning / examples fields of a card. Exposes
-- three entry points:
--   * buildContextAroundSelection   – helper to split "prev + phrase + next"
--                                     context into AI + display windows.
--   * enrichCard                    – single synchronous enrichment.
--   * bulkEnrich                    – cancellable enrichment of many cards.
local _ = require("gettext")
local json = require("json")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")

local DB = require("smartdeck_db")

local Enrich = {}

-- ── Context helpers ───────────────────────────────────────────────────────

-- Cut a trailing/leading chunk of `text` containing at most `nb_words` words.
-- `from_end=true` keeps the tail (used for prev context), otherwise the head
-- (used for next context). Whitespace runs count as word boundaries.
local function trimToWords(text, nb_words, from_end)
    if not text or text == "" or nb_words <= 0 then
        return ""
    end
    local words = {}
    for w in text:gmatch("%S+") do
        words[#words + 1] = w
    end
    if #words <= nb_words then
        return text
    end
    local start_idx, end_idx
    if from_end then
        start_idx = #words - nb_words + 1
        end_idx = #words
    else
        start_idx = 1
        end_idx = nb_words
    end
    local result = {}
    for i = start_idx, end_idx do
        result[#result + 1] = words[i]
    end
    return table.concat(result, " ")
end

-- prev_ctx / next_ctx come from document:getSelectedWordContext which already
-- returns requested word counts. We combine them into single strings.
function Enrich.buildContextWindows(phrase, prev_ctx, next_ctx, ai_words, display_words)
    phrase = phrase or ""
    prev_ctx = prev_ctx or ""
    next_ctx = next_ctx or ""

    local function compose(prev, next_)
        local left = prev or ""
        local right = next_ or ""
        local middle = phrase
        if left ~= "" and not left:match("%s$") then left = left .. " " end
        if right ~= "" and not right:match("^%s") then right = " " .. right end
        return (left .. middle .. right):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local ai_prev = trimToWords(prev_ctx, ai_words or 0, true)
    local ai_next = trimToWords(next_ctx, ai_words or 0, false)
    local disp_prev = trimToWords(prev_ctx, display_words or 0, true)
    local disp_next = trimToWords(next_ctx, display_words or 0, false)

    return compose(ai_prev, ai_next), compose(disp_prev, disp_next)
end

-- Extract the sentence containing the phrase from a prev/next context.
local SENTENCE_DELIMITERS = "[%.%?!;]"
function Enrich.extractSentence(phrase, prev_ctx, next_ctx)
    if not phrase or phrase == "" then return phrase or "" end
    local full = (prev_ctx or "") .. phrase .. (next_ctx or "")
    if full == "" then return phrase end
    local phrase_start = #(prev_ctx or "") + 1
    local phrase_end = phrase_start + #phrase - 1

    local sent_start = 1
    for i = phrase_start - 1, 1, -1 do
        if full:sub(i, i):match(SENTENCE_DELIMITERS) then
            sent_start = i + 1
            break
        end
    end
    local sent_end = #full
    for i = phrase_end + 1, #full do
        if full:sub(i, i):match(SENTENCE_DELIMITERS) then
            sent_end = i
            break
        end
    end
    local sentence = full:sub(sent_start, sent_end)
    sentence = sentence:gsub("^%s+", ""):gsub("%s+$", "")
    if sentence == "" then return phrase end
    return sentence
end

-- ── Prompt construction & JSON parsing ────────────────────────────────────

local function buildMessages(phrase, ai_context, target_language, example_count)
    target_language = target_language or "English"
    example_count = example_count or 3

    local system_prompt = string.format(
        "You are a multilingual language tutor. You MUST reply with a single valid JSON object and nothing else " ..
        "(no prose, no code fences). The JSON object must contain the following keys and nothing more:\n" ..
        "  pronunciation : IPA phonetic transcription of the phrase (empty string if unknown).\n" ..
        "  word_type     : part of speech or a short grammatical label.\n" ..
        "  meaning       : concise definition written in %s.\n" ..
        "  examples      : an array of exactly %d short example sentences (in the source language) that use the phrase naturally.\n" ..
        "Use the provided context only to disambiguate senses; do not translate or mention the context.",
        target_language, example_count
    )

    local user_parts = { "Phrase: \"" .. phrase .. "\"" }
    if ai_context and ai_context ~= "" and ai_context ~= phrase then
        user_parts[#user_parts + 1] = "Context:\n" .. ai_context
    end
    user_parts[#user_parts + 1] = "Return JSON only."
    local user_prompt = table.concat(user_parts, "\n\n")

    return {
        { role = "system", content = system_prompt },
        { role = "user",   content = user_prompt   },
    }
end

-- Strip common code fences before attempting JSON decode.
local function cleanupResponse(response)
    if type(response) ~= "string" then return "" end
    local cleaned = response:gsub("^%s+", ""):gsub("%s+$", "")
    cleaned = cleaned:gsub("^```%w*%s*", ""):gsub("```%s*$", "")
    -- extract first {...} block if surrounded by prose
    local brace_start = cleaned:find("{")
    local brace_end = cleaned:match(".*()}")
    if brace_start and brace_end and brace_end > brace_start then
        cleaned = cleaned:sub(brace_start, brace_end)
    end
    return cleaned
end

local function parseResponse(response)
    if not response or response == "" then
        return nil, "empty response"
    end
    local cleaned = cleanupResponse(response)
    local ok, parsed = pcall(json.decode, cleaned)
    if not ok or type(parsed) ~= "table" then
        return nil, "invalid JSON response"
    end

    local examples_tbl = parsed.examples
    local examples_json = ""
    if type(examples_tbl) == "table" then
        local list = {}
        for _, ex in ipairs(examples_tbl) do
            if type(ex) == "string" and ex ~= "" then
                list[#list + 1] = ex
            end
        end
        if #list > 0 then
            local ok_enc, enc = pcall(json.encode, list)
            if ok_enc then examples_json = enc end
        end
    elseif type(examples_tbl) == "string" and examples_tbl ~= "" then
        local ok_enc, enc = pcall(json.encode, { examples_tbl })
        if ok_enc then examples_json = enc end
    end

    return {
        pronunciation = type(parsed.pronunciation) == "string" and parsed.pronunciation or "",
        meaning       = type(parsed.meaning) == "string"       and parsed.meaning       or "",
        word_type     = type(parsed.word_type) == "string"     and parsed.word_type     or "",
        examples      = examples_json,
    }
end

-- Decode the JSON-encoded examples field back into a Lua list.
function Enrich.decodeExamples(examples_json)
    if not examples_json or examples_json == "" then return {} end
    local ok, parsed = pcall(json.decode, examples_json)
    if ok and type(parsed) == "table" then
        local list = {}
        for _, ex in ipairs(parsed) do
            if type(ex) == "string" and ex ~= "" then
                list[#list + 1] = ex
            end
        end
        return list
    end
    return {}
end

-- ── Single card enrichment ────────────────────────────────────────────────

-- Perform the enrichment; returns the writable result table on success,
-- otherwise nil plus an error message. Uses the already-loaded querier.
function Enrich.enrichCard(plugin, card, trap_widget)
    if not card or not plugin or not plugin.querier then
        return nil, _("SmartDeck AI provider is not configured.")
    end
    local settings = plugin.settings
    local target_language = settings:readSetting("target_language", "English") or "English"
    local example_count = tonumber(settings:readSetting("example_count", 3)) or 3
    if example_count < 1 then example_count = 1 end

    local messages = buildMessages(card.phrase, card.ai_context, target_language, example_count)
    local response, err = plugin.querier:query(messages, trap_widget)
    if not response then
        return nil, err or _("No response from AI provider.")
    end

    local result, parse_err = parseResponse(response)
    if not result then
        return nil, parse_err or _("Could not parse AI response.")
    end
    result.status = DB.STATUS_ENRICHED
    result.error = ""
    return result
end

-- Enrich the card in-place and persist the result to the database. Returns
-- `true` on success, otherwise `false` plus an error string.
function Enrich.enrichAndSave(plugin, card, trap_widget)
    local result, err = Enrich.enrichCard(plugin, card, trap_widget)
    if not result then
        DB.applyEnrichment(card.id, {
            status = DB.STATUS_ERROR,
            error = err or "",
        })
        return false, err
    end
    DB.applyEnrichment(card.id, result)
    -- reflect on the in-memory card too
    card.pronunciation = result.pronunciation
    card.meaning = result.meaning
    card.word_type = result.word_type
    card.examples = result.examples
    card.ai_status = DB.STATUS_ENRICHED
    card.ai_error = ""
    return true
end

-- ── Cancellable bulk enrichment ───────────────────────────────────────────

function Enrich.bulkEnrich(plugin, cards, on_finished)
    if not cards or #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards require AI enrichment."),
            timeout = 3,
        })
        if on_finished then on_finished(0, 0) end
        return
    end

    local total = #cards
    local index = 0
    local succeeded = 0
    local failed = 0
    local cancelled = false
    local progress_widget

    local function showProgress(idx, phrase)
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
        local text = string.format(
            _("Fetching card %d of %d…\n\n\"%s\"\n\nTap outside to cancel."),
            idx, total, phrase or ""
        )
        progress_widget = InfoMessage:new{
            text = text,
            timeout = nil,
        }
        progress_widget.dismiss_callback = function()
            if not cancelled then cancelled = true end
        end
        UIManager:show(progress_widget)
        UIManager:forceRePaint()
    end

    local function closeProgress()
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
    end

    local function finalize(msg)
        closeProgress()
        UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
        if on_finished then on_finished(succeeded, failed) end
    end

    local function processNext()
        if cancelled then
            finalize(string.format(
                _("Cancelled. %d succeeded, %d failed, %d skipped."),
                succeeded, failed, total - succeeded - failed
            ))
            return
        end
        index = index + 1
        if index > total then
            finalize(string.format(
                _("Done. %d succeeded, %d failed."), succeeded, failed
            ))
            return
        end
        local card = cards[index]
        showProgress(index, card.phrase or "")

        -- Run the enrichment on next tick so the UI gets a chance to paint.
        UIManager:scheduleIn(0.05, function()
            local ok, err = Enrich.enrichAndSave(plugin, card)
            if cancelled then
                finalize(string.format(
                    _("Cancelled. %d succeeded, %d failed, %d skipped."),
                    succeeded, failed, total - succeeded - failed
                ))
                return
            end
            if ok then
                succeeded = succeeded + 1
            else
                failed = failed + 1
                logger.warn("smartdeck: enrichment failed for", card.phrase, err)
            end
            UIManager:scheduleIn(0.05, processNext)
        end)
    end

    processNext()
end

-- ── Sentence extraction helper when user selects text in the reader ──────

-- Returns: ai_context, display_context, sentence
function Enrich.captureContexts(plugin, ui, selected_text_obj)
    if not selected_text_obj or not selected_text_obj.text then
        return "", "", ""
    end
    local phrase = selected_text_obj.text
    local settings = plugin.settings
    local ai_words = tonumber(settings:readSetting("ai_context_words", 30)) or 30
    local display_words = tonumber(settings:readSetting("display_context_words", 15)) or 15
    local max_words = math.max(ai_words, display_words, 10)

    local prev_ctx, next_ctx
    if ui and ui.document and not ui.document.info.has_pages
        and selected_text_obj.pos0 and selected_text_obj.pos1
        and ui.document.getSelectedWordContext then
        local ok, prev, next_ = pcall(
            ui.document.getSelectedWordContext,
            ui.document,
            phrase, max_words,
            selected_text_obj.pos0, selected_text_obj.pos1,
            false
        )
        if ok then
            prev_ctx = prev
            next_ctx = next_
        end
    end

    local ai_context, display_context =
        Enrich.buildContextWindows(phrase, prev_ctx, next_ctx, ai_words, display_words)
    local sentence = Enrich.extractSentence(phrase, prev_ctx, next_ctx)
    return ai_context, display_context, sentence
end

return Enrich
