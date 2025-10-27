-- Authentication Endpoints

local cjson = require "cjson"
local logger = require "utils.logger"

local _M = {}

local monitoring = require "monitoring.init"
local web_utils = require "utils.web_utils"

-- Internal: append a Set-Cookie without clobbering existing headers
local function append_set_cookie(cookie)
    local existing = ngx.header["Set-Cookie"]
    if not existing then
        ngx.header["Set-Cookie"] = { cookie }
    elseif type(existing) == "table" then
        table.insert(existing, cookie)
        ngx.header["Set-Cookie"] = existing
    else
        ngx.header["Set-Cookie"] = { existing, cookie }
    end
end

function _M.set_auth_cookies(tokens)
    local cookie_options = "Path=/; HttpOnly; SameSite=Lax"
    if ngx.var.scheme == "https" then
        cookie_options = cookie_options .. "; Secure"
    end

    local access_token = tokens and tokens.access_token
    if not access_token or access_token == "" then
        return
    end

    local max_age = nil
    if tokens.expires_at and type(tokens.expires_at) == "number" then
        local ttl = math.max(0, tokens.expires_at - ngx.time())
        if ttl > 0 then max_age = ttl end
    end

    local cookie = "access_token=" .. access_token .. "; " .. cookie_options
    if max_age then
        cookie = cookie .. "; Max-Age=" .. tostring(max_age)
    end
    append_set_cookie(cookie)
end

function _M.set_cookie(name, value, options)
    if not name or name == "" then return end
    value = value or ""
    local opts = options or {}
    local cookie_options = "Path=/"
    if opts.http_only ~= false then
        cookie_options = cookie_options .. "; HttpOnly"
    end
    if opts.same_site then
        cookie_options = cookie_options .. "; SameSite=" .. opts.same_site
    else
        cookie_options = cookie_options .. "; SameSite=Lax"
    end
    if opts.secure or ngx.var.scheme == "https" then
        cookie_options = cookie_options .. "; Secure"
    end
    if opts.max_age then
        cookie_options = cookie_options .. "; Max-Age=" .. tostring(opts.max_age)
    end
    append_set_cookie(name .. "=" .. ngx.escape_uri(value) .. "; " .. cookie_options)
end

function _M.set_cookies_from_provider(cookies_config)
    if not cookies_config then
        return
    end
    
    local cookies = {}
    
    for name, config in pairs(cookies_config) do
        local cookie_options = "Path=/"
        
        if config.http_only then
            cookie_options = cookie_options .. "; HttpOnly"
        end
        
        if config.secure or ngx.var.scheme == "https" then
            cookie_options = cookie_options .. "; Secure"
        end
        
        if config.same_site then
            cookie_options = cookie_options .. "; SameSite=" .. config.same_site
        end
        
        if config.max_age then
            cookie_options = cookie_options .. "; Max-Age=" .. config.max_age
        end
        
        table.insert(cookies, name .. "=" .. config.value .. "; " .. cookie_options)
    end
    
    if #cookies > 0 then
        for _, c in ipairs(cookies) do append_set_cookie(c) end
    end
end

function _M.clear_cookie(name)
    if not name or name == "" then return end
    local base_opts = "Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    local https_only = (ngx.var.scheme == "https") and "; Secure" or ""
    local opts_no_domain = base_opts .. https_only
    append_set_cookie(name .. "=; " .. opts_no_domain)
end

function _M.clear_auth_cookies()
    _M.clear_cookie("access_token")
    _M.clear_cookie("session") -- openidc/resty.session cookie
    _M.clear_cookie("session_uid")
end

function _M.extract_token()
    -- Check Authorization header first
    local auth_header = ngx.var.http_authorization
    if auth_header then
        local token = auth_header:match("Bearer%s+(.+)")
        if token then
            return token, "header"
        end
    end
    
    -- Check cookie as fallback
    local cookie_value = ngx.var.cookie_access_token
    if cookie_value then
        return cookie_value, "cookie"
    end
    
    return nil, nil
end

local function send_json_response(status, data)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(data))
    return ngx.exit(status)
end

function _M.route_provider_request(uri, method)
    local provider_registry = require "auth.core"
    
    local provider_name = uri:match("/auth/([^/]+)/")
    if not provider_name then
        return send_json_response(404, {
            error = "invalid_endpoint",
            message = "Invalid authentication endpoint"
        })
    end
    
    local provider = provider_registry.get_provider(provider_name)
    if not provider then
        return send_json_response(400, {
            error = "provider_unavailable",
            message = "Provider '" .. provider_name .. "' is not available"
        })
    end
    
    local action = nil
    if uri:match("/login$") then
        action = "login"
    elseif uri:match("/callback$") then
        action = "callback"
    else
        return send_json_response(404, {
            error = "invalid_action",
            message = "Invalid action for provider '" .. provider_name .. "'"
        })
    end
    
    if action == "login" then
        monitoring.auth_event("login_start", "info", { description = "Login flow started", metadata = { provider = provider_name } })
    elseif action == "callback" then
        monitoring.auth_event("callback_received", "info", { description = "OIDC callback received", metadata = { provider = provider_name } })
    end

    -- Call provider handler
    local handler_method = "handle_" .. action
    if not provider[handler_method] then
        return send_json_response(501, {
            error = "not_implemented",
            message = "Action '" .. action .. "' not implemented for provider '" .. provider_name .. "'"
        })
    end
    
    local result = provider[handler_method](provider)
    
    if action == "login" then
        if result and result.success then
            local user = result.user or {}
            monitoring.auth_event("login", "success", {
                description = "User login succeeded",
                user_id = user.user_id,
                username = user.email or user.name,
                metadata = { auth_provider = provider_name, roles = user.roles, groups = user.groups }
            })
        else
            monitoring.auth_event("login", "failure", { description = result and result.error or "Login failed", metadata = { auth_provider = provider_name } })
        end
    elseif action == "callback" then
        if result and result.success then
            local user = result.user or {}
            monitoring.auth_event("callback", "success", {
                    description = "OIDC callback succeeded",
                    user_id = user.user_id,
                    username = user.email or user.name,
                    metadata = { auth_provider = provider_name, roles = user.roles, groups = user.groups }
                })
        else
            monitoring.auth_event("callback", "failure", { description = result and result.error or "OIDC callback failed", metadata = { auth_provider = provider_name } })
        end
    end
    return _M.handle_provider_response(result)
end

function _M.handle_provider_response(result)
    if not result.success then
        local status = result.status or 503
        if web_utils.is_browser_request() then
            return web_utils.handle_error_response(status, "Authentication service unavailable")
        end
        -- For non-browsers, return sanitized JSON
        return send_json_response(status, {
            error = "authentication_failed",
            message = "Authentication service unavailable"
        })
    end
    
    if result.action == "redirect" then
        return ngx.redirect(result.redirect_url)
    end
    
    local response_data = {
        success = true
    }
    
    if result.tokens then
        response_data.tokens = result.tokens
    end
    
    if result.user then
        response_data.user = result.user
    end
    
    if result.message then
        response_data.message = result.message
    end
    
    return send_json_response(200, response_data)
end

function _M.handle_token_refresh()
    if ngx.var.request_method ~= "POST" then
        return send_json_response(405, {
            error = "method_not_allowed",
            message = "Only POST method is allowed"
        })
    end
    
    local auth_service = require "auth.auth_core"
    
    local current = auth_service.get_current_auth_session()
    local tokens = current and current.tokens or nil
    if not tokens or not tokens.refresh_token then
        monitoring.auth_event("refresh", "failure", { description = "Missing refresh token" })
        return send_json_response(400, {
            error = "missing_refresh_token",
            message = "No refresh token available"
        })
    end
    
    local provider_registry = require "auth.core"
    local default_provider = provider_registry.get_default_provider()
    
    if not default_provider then
        monitoring.auth_event("refresh", "failure", { description = "No auth provider available" })
        return send_json_response(500, {
            error = "provider_unavailable",
            message = "No authentication provider available"
        })
    end
    
    local result = default_provider:refresh_token(tokens.refresh_token)
    if not result.success then
        monitoring.auth_event("refresh", "failure", { description = result.error or "Token refresh failed" })
        return send_json_response(401, {
            error = "invalid_refresh_token",
            message = result.error
        })
    end
    
    pcall(function()
        local session_manager = require "auth.core"
        session_manager.store_tokens(result.tokens)
    end)
    if result.tokens and result.tokens.access_token then
        _M.set_auth_cookies(result.tokens)
    end
    
    -- Refresh session
    auth_service.refresh_user_session()
    local user = auth_service.get_current_user()
    monitoring.auth_event("refresh", "success", {
        description = "Token refresh successful",
        user_id = user and user.user_id or nil,
        username = user and (user.email or user.name) or nil
    })
    
    return send_json_response(200, {
        success = true,
        tokens = result.tokens
    })
end

function _M.handle_logout()
    local provider_registry = require "auth.core"
    local auth_service = require "auth.auth_core"
    
    -- Provider logout regardless of user object state
    local default_provider = provider_registry.get_default_provider()
    if default_provider then
        -- Get tokens from session for provider logout
        local session, err = auth_service.get_current_auth_session()
        if session and session.tokens then
            -- Provider logout. If provider returns redirect, honor it after destroying local session
            local provider_result = default_provider:logout({
                tokens = session.tokens,
                id_token = session.tokens.id_token_raw or session.tokens.id_token,
                access_token = session.tokens.access_token
            })
            
            -- Destroy local session before any redirect and clear cookies
            auth_service.logout_user()
            _M.clear_auth_cookies()
            
            if provider_result and provider_result.action == "redirect" and provider_result.redirect_url then
                logger.info("Provider logout redirect: " .. provider_result.redirect_url)
                return ngx.redirect(provider_result.redirect_url)
            end
        end
    end
    
    -- Logout using server-side authentication
    local logout_result = auth_service.logout_user()
    _M.clear_auth_cookies()
    
    local user = auth_service.get_current_user()
    monitoring.auth_event("logout", logout_result.success and "success" or "failure", {
        description = "User logout",
        user_id = user and user.user_id or nil,
        username = user and (user.email or user.name) or nil
    })
    
    logger.info("Logout result: " .. (logout_result.success and "success" or "failed: " .. (logout_result.error or "unknown error")))
    
    -- Redirect to login page after logout (user will always need to re-authenticate)
    ngx.redirect("/login")
    return
end

function _M.handle_auth_providers()
    local provider_registry = require "auth.core"
    local providers = provider_registry.get_available_providers()
    
    return send_json_response(200, {
        success = true,
        providers = providers
    })
end

function _M.handle_backchannel_logout()
    if ngx.var.request_method ~= "POST" then
        return send_json_response(405, {
            error = "method_not_allowed",
            message = "Only POST method is allowed for backchannel logout"
        })
    end
    
    local provider_registry = require "auth.core"
    local oidc_provider = provider_registry.get_provider("oidc")
    
    if not oidc_provider then
        return send_json_response(404, {
            error = "provider_not_found",
            message = "OIDC provider not found"
        })
    end
    
    local result = oidc_provider:handle_backchannel_logout()
    
    if result.success then
        monitoring.auth_event("backchannel_logout", "success", { 
            description = "Backchannel logout succeeded",
            metadata = { provider = "oidc" }
        })
        return send_json_response(200, {
            success = true,
            message = result.message or "Logout successful"
        })
    else
        monitoring.auth_event("backchannel_logout", "failure", { 
            description = result.error or "Backchannel logout failed",
            metadata = { provider = "oidc" }
        })
        return send_json_response(result.status or 400, {
            success = false,
            error = result.error or "Backchannel logout failed"
        })
    end
end

function _M.handle_login_page()
    local provider_registry = require "auth.core"
    local providers = provider_registry.get_available_providers()
    local auth_service = require "auth.auth_core"
    local is_auth = auth_service.is_authenticated()
    
    logger.info("Login page - User authenticated: " .. tostring(is_auth))
    
    if is_auth then
        monitoring.auth_event("login_page", "already_authenticated", { description = "Redirecting authenticated user to dashboard"         })
        logger.info("User is authenticated, redirecting to dashboard")
        ngx.redirect("/dashboard")
        return
    end
    
    local config_manager = require "config.manager"
    local server_title = config_manager.get_env("jump_server_title") or "Jump Server"
    
    local template_data = {
        title = "Login - " .. server_title,
        description = "Sign in to access " .. server_title,
        providers = providers,
        flash_message = ngx.var.flash_message,
        flash_type = ngx.var.flash_type
    }
    -- Capture optional next param and persist for after auth
    local next_param = ngx.var.arg_next
    if next_param and next_param ~= "" then
        template_data.next = next_param
    end
    
    -- Redirect to static login page
    monitoring.auth_event("login_page", "view", { description = "Login page viewed" })
    ngx.redirect("/login")
    return
end

function _M.handle_request()
    local uri = ngx.var.uri
    local method = ngx.var.request_method
    
    logger.debug("Auth request: " .. method .. " " .. uri)
    
    -- Route provider-specific endpoints to provider router
    if uri:match("^/auth/[^/]+/") then
        return _M.route_provider_request(uri, method)
    end
    
    -- Route generic authentication endpoints
    if uri == "/auth/login" or uri == "/login" then
        return _M.handle_login_page()
    elseif uri == "/auth/refresh" then
        return _M.handle_token_refresh()
    elseif uri == "/auth/logout" then
        return _M.handle_logout()
    elseif uri == "/auth/providers" then
        return _M.handle_auth_providers()
    elseif uri == "/auth/backchannel-logout" then
        return _M.handle_backchannel_logout()
    else
        return send_json_response(404, {
            error = "not_found",
            message = "Authentication endpoint not found"
        })
    end
end

function _M.init()
    logger.info("Authentication handler initialized and ready")
    return true
end

return _M
