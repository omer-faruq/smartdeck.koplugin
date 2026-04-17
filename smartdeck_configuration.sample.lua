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
    },
}

return CONFIGURATION
