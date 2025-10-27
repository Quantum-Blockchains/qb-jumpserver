-- Authentication Core

local cjson = require "cjson"
local config_manager = require "config.manager"
local logger = require "utils.logger"

local _M = {}

local Authenticator = {}
Authenticator.__index = Authenticator

function Authenticator.new(config)
    local self = setmetatable({}, Authenticator)
    self.config = config or {}
    self.enabled = config.enabled ~= false
    return self
end

-- Methods that providers must implement
function Authenticator:authenticate(request_data)
    error("authenticate() must be implemented by provider")
end

function Authenticator:validate_token(token)
    error("validate_token() must be implemented by provider")
end

function Authenticator:refresh_token(refresh_token)
    error("refresh_token() must be implemented by provider")
end

function Authenticator:logout(session_data)
    error("logout() must be implemented by provider")
end

function Authenticator:is_enabled()
    return self.enabled
end

function Authenticator:get_name()
    return self.name or "unknown"
end

function Authenticator:get_display_name()
    return self.display_name or self.name or "Unknown"
end

function Authenticator:get_login_url()
    return "/auth/" .. (self.name or "unknown") .. "/login"
end

function Authenticator:get_api_config()
    return {
        enabled = self:is_enabled(),
        display_name = self:get_display_name(),
        login_url = self:get_login_url()
    }
end

function _M.create_authenticator(provider_type, config)
    if provider_type == "oidc" then
        local OidcAuthenticator = require "auth.providers.oidc_authenticator"
        return OidcAuthenticator.new(config)
    else
        error("Unknown provider type: " .. tostring(provider_type))
    end
end

_M.providers = {
    oidc = "auth.providers.oidc_authenticator"
}

function _M.register_provider_module(name, module_path)
    _M.providers[name] = module_path
end

_M.Authenticator = Authenticator

local ok, session = pcall(require, "resty.session")

local function get_session_config()
    local session_config = config_manager.get_session_config()
    return {
        name = "session",
        secret = session_config.secret,
        storage = "cookie",
        cookie = {
            domain = session_config.domain,
            path = "/",
            secure = session_config.secure,
            httponly = true,
            samesite = "Lax",
        },
        lifetime = session_config.lifetime,
        rolling = true,
        rolling_timeout = session_config.rolling_timeout,
    }
end

local SESSION_CONFIG = get_session_config()

function _M.init_session_manager()
    logger.info("Initializing session manager")
    logger.info("Session manager initialized with " .. SESSION_CONFIG.storage .. " storage")
    return true
end

function _M.get_session_config()
    local config = {}
    
    for key, value in pairs(SESSION_CONFIG) do
        if type(value) == "table" then
            config[key] = {}
            for k, v in pairs(value) do
                config[key][k] = v
            end
        else
            config[key] = value
        end
    end
    
    if ngx.var.scheme then
        local is_secure = SESSION_CONFIG.cookie.secure or ngx.var.scheme == "https"
        config.cookie.secure = is_secure
    end
    
    return config
end

function _M.get_session()
    local config = _M.get_session_config()
    return session.start(config)
end

function _M.create_session(user_data)
    local sess = _M.get_session()
    
    if not sess then
        return { success = false, error = "Failed to create session" }
    end
    
    sess.data.user = user_data
    sess.data.authenticated = true
    sess.data.auth_time = ngx.time()
    sess.data.last_activity = ngx.time()
    sess:save()
    
    return { success = true, session = sess }
end

function _M.get_current_session()
    local sess = _M.get_session()
    
    if not sess then
        return { success = false, error = "Failed to get session" }
    end
    
    if not sess.data.authenticated then
        return { success = false, error = "Session not authenticated" }
    end
    
    local now = ngx.time()
    local auth_time = sess.data.auth_time or now
    local last_activity = sess.data.last_activity or auth_time
    local absolute_lifetime = tonumber(SESSION_CONFIG.lifetime) or 0
    local idle_timeout = tonumber(SESSION_CONFIG.rolling_timeout) or 0
    
    if absolute_lifetime > 0 and (now - auth_time) > absolute_lifetime then
        sess.data.authenticated = false
        sess.data.destroyed = true
        sess.data.logout_time = now
        sess.data.user = nil
        sess.data.tokens = nil
        sess:save()
        return { success = false, error = "Session expired (absolute)" }
    end
    
    if idle_timeout > 0 and (now - last_activity) > idle_timeout then
        sess.data.authenticated = false
        sess.data.destroyed = true
        sess.data.logout_time = now
        sess.data.user = nil
        sess.data.tokens = nil
        sess:save()
        return { success = false, error = "Session expired (idle)" }
    end
    
    sess.data.last_activity = now
    pcall(function() sess:save() end)
    
    return { success = true, session = sess, user = sess.data.user }
end

function _M.update_session(updates)
    local sess = _M.get_current_session()
    
    if not sess.success then
        return sess
    end
    
    for key, value in pairs(updates) do
        sess.session.data[key] = value
    end
    
    sess.session:save()
    
    return { success = true, session = sess.session }
end

function _M.refresh_session()
    local sess = _M.get_current_session()
    
    if not sess.success then
        return sess
    end
    
    sess.session.data.auth_time = ngx.time()
    sess.session:save()
    
    return { success = true, session = sess.session }
end

function _M.destroy_session()
    local config = _M.get_session_config()
    pcall(function()
        local ok2, err2, exists2, logged_out2 = session.logout(config)
        logger.debug(string.format("session.logout ok=%s exists=%s logged_out=%s err=%s",
            tostring(ok2), tostring(exists2), tostring(logged_out2), tostring(err2)))
    end)
    
    local sess = _M.get_session()
    if sess then
        pcall(function()
            sess.data = {}
            sess.data.authenticated = false
            sess.data.destroyed = true
            sess.data.logout_time = ngx.time()
            sess:save()
            pcall(function() sess:forget() end)
            sess:destroy()
        end)
    end
    
    logger.info("Session completely destroyed - user will need to re-authenticate")
    return { success = true }
end

function _M.is_session_valid()
    local result = _M.get_current_session()
    return result.success
end

function _M.get_user()
    local result = _M.get_current_session()
    if result.success then
        return result.user
    end
    return nil
end

function _M.validate_token()
    local tokens = _M.get_tokens()
    if not tokens or not tokens.access_token then
        return false
    end
    
    if tokens.expires_at and tokens.expires_at < ngx.time() then
        return false
    end
    
    return true
end

function _M.store_tokens(tokens)
    local sess = _M.get_current_session()
    
    if not sess.success then
        return sess
    end
    
    sess.session.data.tokens = {
        access_token = tokens.access_token,
        refresh_token = tokens.refresh_token,
        id_token = tokens.id_token,
        id_token_raw = tokens.id_token_raw,
        token_type = tokens.token_type or "Bearer",
        expires_at = tokens.expires_at or (ngx.time() + 3600),
        introspection_endpoint = tokens.introspection_endpoint
    }
    
    sess.session:save()
    
    return { success = true }
end

function _M.get_tokens()
    local sess = _M.get_current_session()
    
    if not sess.success then
        return nil
    end
    
    return sess.session.data.tokens
end

function _M.clear_tokens()
    local sess = _M.get_current_session()
    
    if not sess.success then
        return sess
    end
    
    sess.session.data.tokens = nil
    sess.session:save()
    
    return { success = true }
end

function _M.get_config()
    return SESSION_CONFIG
end

local providers = {}
local default_provider = "oidc"

function _M.register_provider(name, provider_instance)
    if not name or not provider_instance then
        error("Provider name and instance are required")
    end
    
    providers[name] = provider_instance
    logger.info("Provider registered: " .. name)
end

function _M.get_provider(name)
    return providers[name]
end

function _M.get_default_provider()
    return providers[default_provider]
end

function _M.set_default_provider(name)
    if not providers[name] then
        error("Provider not found: " .. name)
    end
    default_provider = name
    logger.info("Default provider set to: " .. name)
end

function _M.get_all_providers()
    return providers
end

function _M.get_available_providers()
    local available = {}
    for name, provider in pairs(providers) do
        if provider:is_enabled() then
            table.insert(available, {
                name = name,
                display_name = provider:get_display_name(),
                login_url = provider:get_login_url()
            })
        end
    end
    return available
end

function _M.count_providers()
    local count = 0
    for _, provider in pairs(providers) do
        if provider:is_enabled() then
            count = count + 1
        end
    end
    return count
end

function _M.remove_provider(name)
    if providers[name] then
        providers[name] = nil
        logger.info("Provider removed: " .. name)
        return true
    end
    return false
end

function _M.clear_providers()
    providers = {}
    logger.info("All providers cleared")
end

function _M.init_default_providers()
    local config_manager = require "config.manager"
    local oidc_config = config_manager.get_oidc_config()
    
    if oidc_config and oidc_config.enabled then
        logger.info("OIDC config loaded from unified configuration")
        
        local OidcAuthenticator = require "auth.providers.oidc_authenticator"
        local oidc_provider = OidcAuthenticator.OidcAuthenticator.new(oidc_config)
        _M.register_provider("oidc", oidc_provider)
        
        logger.info("OIDC provider registered successfully")
    else
        logger.warn("OIDC authentication is disabled or not configured")
    end
    
    logger.info("Provider registry initialized with " .. _M.count_providers() .. " providers")
end

return _M
