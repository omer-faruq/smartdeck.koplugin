-- SmartDeck configuration
--
-- Copy this file to `smartdeck_configuration.lua` in the same folder and fill
-- in your API keys. The plugin picks `provider` as the default provider. You
-- can switch providers at runtime from the SmartDeck settings menu.
--
-- The handler used for each provider is derived from the provider name: the
-- part before the first `_` must match a file in `smartdeck_providers/`. Thus
-- `openai_x` uses `smartdeck_providers/openai.lua`, `openai` does too, and
-- so on.

local CONFIGURATION = {
    provider = "openai",

    provider_settings = {
        openai = {
            visible = true,
            model = "gpt-4o-mini",
            base_url = "https://api.openai.com/v1/chat/completions",
            api_key = "your-openai-api-key",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        openai_groq = {
            visible = true,
            model = "llama-3.3-70b-versatile", -- model list: https://console.groq.com/docs/models
            base_url = "https://api.groq.com/openai/v1/chat/completions",
            api_key = "your-groq-api-key",
            additional_parameters = {
                temperature = 0.7,
            }
        },

        openai_grok = {
            visible = true,
            model = "grok-3-mini-fast",
            base_url = "https://api.x.ai/v1/chat/completions",
            api_key = "your-grok-api-key",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        -- Example: a local Ollama server that speaks the OpenAI protocol.
        openai_local = {
            visible = true,
            model = "llama3.1",
            base_url = "http://127.0.0.1:11434/v1/chat/completions",
            api_key = "ollama",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        -- Anthropic Claude. Uses the Messages API (smartdeck_providers/anthropic.lua).
        anthropic = {
            visible = true,
            model = "claude-3-5-haiku-latest",
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "your-anthropic-api-key",
            additional_parameters = {
                max_tokens = 1024,
                temperature = 0.3,
                anthropic_version = "2023-06-01",
            },
        },

        -- Google Gemini. Uses the native generateContent endpoint
        -- (smartdeck_providers/gemini.lua). `base_url` must end with a slash.
        gemini = {
            visible = true,
            model = "gemini-2.0-flash",
            base_url = "https://generativelanguage.googleapis.com/v1beta/models/",
            api_key = "your-gemini-api-key",
            additional_parameters = {
                temperature = 0.3,
                maxOutputTokens = 1024,
            },
        },

        -- Ollama using its native /api/chat endpoint
        -- (smartdeck_providers/ollama.lua).
        ollama = {
            visible = true,
            model = "llama3.1",
            base_url = "http://127.0.0.1:11434/api/chat",
            api_key = "", -- leave empty unless your server needs one
            additional_parameters = {
                options = {
                    temperature = 0.3,
                    num_predict = 1024,
                },
            },
        },
    },
}

return CONFIGURATION
