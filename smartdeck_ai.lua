-- SmartDeck querier: thin wrapper over smartdeck_providers/* handlers.
--
-- Dispatch logic mirrors the AI Assistant plugin:
--   provider name "openai_grok" -> loads smartdeck_providers/openai
--   provider name "openai"      -> loads smartdeck_providers/openai
-- The bit before the first underscore selects the handler file.
local _ = require("gettext")
local koutil = require("util")
local logger = require("logger")

local Querier = {
    plugin = nil,
    handler = nil,
    handler_name = nil,
    provider_settings = nil,
    provider_name = nil,
}

function Querier:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Querier:isInited()
    return self.handler ~= nil
end

function Querier:loadProvider(provider_name)
    if provider_name == self.provider_name and self:isInited() then
        return true
    end
    local config = self.plugin and self.plugin.CONFIGURATION
    if not config then
        return false, _("SmartDeck configuration file is not loaded.")
    end
    local provider_settings = koutil.tableGetValue(config, "provider_settings", provider_name)
    if not provider_settings then
        return false, string.format(
            _("Provider settings not found for: %s. Check smartdeck_configuration.lua."),
            tostring(provider_name)
        )
    end

    local handler_name
    local underscore_pos = provider_name:find("_")
    if underscore_pos and underscore_pos > 0 then
        handler_name = provider_name:sub(1, underscore_pos - 1)
    else
        handler_name = provider_name
    end

    local ok, handler = pcall(function()
        return require("smartdeck_providers." .. handler_name)
    end)
    if not ok then
        local err = string.format(
            _("The handler for %s was not found in smartdeck_providers/."),
            handler_name
        )
        logger.warn("smartdeck: " .. err)
        return false, err
    end

    self.handler = handler
    self.handler_name = handler_name
    self.provider_settings = provider_settings
    self.provider_name = provider_name
    return true
end

function Querier:getModel()
    return koutil.tableGetValue(self.provider_settings or {}, "model")
end

-- Perform a single chat completion request.
-- @param messages  list of {role=..., content=...}
-- @param trap_widget optional widget used for cancellation (Trapper).
-- @return string|nil response, string|nil error
function Querier:query(messages, trap_widget)
    if not self:isInited() then
        return nil, _("SmartDeck AI provider is not configured.")
    end
    if trap_widget then
        self.handler:setTrapWidget(trap_widget)
    end
    local response, err = self.handler:query(messages, self.provider_settings)
    if trap_widget then
        self.handler:resetTrapWidget()
    end
    return response, err
end

return Querier
