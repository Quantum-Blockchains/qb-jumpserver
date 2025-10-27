-- Authentication Initialization

local _M = {}
local logger = require "utils.logger"

function _M.init()
    logger.info("Initializing authentication system...")
    
    local provider_registry = require "auth.core"
    provider_registry.init_default_providers()
    
    local auth_service = require "auth.auth_service"
    auth_service.init_all()
    
    logger.info("Authentication system initialization complete")
    return true
end

function _M.get_auth_service()
    return require "auth.auth_service"
end

function _M.get_middleware()
    return require "auth.auth_service"
end

function _M.get_provider_registry()
    return require "auth.core"
end

function _M.get_authorization_service()
    return require "auth.auth_service"
end

return _M 