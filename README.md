# SmartDeck

AI-powered flashcard plugin for KOReader.

Select a word or phrase from the book (via the highlight menu) or from the
dictionary popup, and SmartDeck will store the card into an SQLite database.
When an internet connection is available, the plugin will use an
OpenAI-compatible AI provider to enrich every card with:

* Pronunciation / phonetics
* Word type (part of speech)
* Meaning in your preferred target language
* Up to three example sentences
* The surrounding context (X words around the selection) that was sent to the AI

Cards can be reviewed in a study screen similar to PhraseDeck, with a
configurable **front** and **back** (choose which fields are shown on each side,
similar to the AnkiViewer plugin). Editing and deleting cards are both
supported; after editing the phrase you can decide whether to keep the current
content, clear it for a later refetch, or refetch immediately.

## Configuration

Copy `smartdeck_configuration.sample.lua` to `smartdeck_configuration.lua` and
fill in the API key(s) for your provider. Multiple named providers are
supported (e.g. `openai`, `openai_grok`) – name-based dispatch selects the
handler (the part before the first `_`) in exactly the same way as the
AI Assistant plugin does.

Only OpenAI-compatible providers are shipped by default. The
`smartdeck_providers` folder is structured so that adding new handlers
(Anthropic, Gemini, …) is straightforward.

## Main menu

* **Study** — open the spaced-repetition review screen.
* **Cards** — browse, edit, or delete cards (per current book or across all
  books).
* **Fetch missing info** — cancellable bulk enrichment of cards that don't
  yet have AI data; tap outside the progress popup to stop.
* **Import from Vocabulary Builder** — imports words collected by the built-in
  Vocabulary Builder into the current book's deck.
* **Settings** — provider selection, target language, context-word counts,
  auto-fetch toggle, example count, front/back field selection, daily new
  card limit, randomization, etc.

## Highlight menu & dictionary popup

* A "SmartDeck" button is injected into the highlight menu while reading.
* A "SmartDeck" button is injected into the dictionary popup; tap it to send
  the looked-up word directly to the deck.

## Credits
This project was created with assistance from Windsurf (AI).