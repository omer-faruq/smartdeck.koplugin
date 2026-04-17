local _ = require("gettext")

return {
    name = "smartdeck",
    fullname = _("SmartDeck"),
    description = _([[AI-enriched flashcards for words and phrases collected while reading. Cards are enriched with pronunciation, meaning, type, and example sentences through any OpenAI-compatible provider, stored in SQLite, and reviewed with a spaced-repetition study screen.]]),
    version = "1.0.0",
}
