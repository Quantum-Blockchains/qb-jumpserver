-- Authentication Service

local cjson = require "cjson"
local logger = require "utils.logger"

local _M = {}

local monitoring = require "monitoring.init"
local db = require("models.init")
local permissions_model = require "models.permissions"
local web_utils = require "utils.web_utils"

local function _get_jwt_exp(token)
    if not token or type(token) ~= "string" then return nil end
    local ok_jwt, jwt = pcall(require, "resty.jwt")
    if not ok_jwt or not jwt or not jwt.load_jwt then return nil end
    local ok_load, obj = pcall(jwt.load_jwt, jwt, token)
    if not ok_load or not obj or not obj.payload then return nil end
    return obj.payload.exp
end

function _M.init()
    logger.info("Initializing authentication service (stateless token mode)")
    return true
end

function _M.is_auth_enabled()
    return true
end

function _M.is_development_mode()
    local config = require "config.manager"
    return config.is_development_mode()
end

function _M.validate_admin_token(token)
    if not _M.is_development_mode() then
        return { success = false, error = "Development mode not enabled" }
    end
    
    -- WARNING: Insecure development mode - never use in production
    if token == "admin-token" then
        local roles = { "jumpserver:admin", "jumpserver:audit" }
        local user_id = "dev-admin"
        local email = "admin@dev.local"
        local name = "Development Admin"
        
        local content_type = ngx.var.content_type
        if content_type and content_type:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, params = pcall(cjson.decode, body)
                if ok and params then
                    if params.roles and type(params.roles) == "table" then
                        roles = params.roles
                    end
                    if params.user_id and type(params.user_id) == "string" then
                        user_id = params.user_id
                    end
                    if params.email and type(params.email) == "string" then
                        email = params.email
                    end
                    if params.name and type(params.name) == "string" then
                        name = params.name
                    end
                end
            end
        end
        
        local admin_user = {
            user_id = user_id,
            email = email,
            name = name,
            roles = roles,
            is_admin = true
        }
        
        logger.info("Development mode: Admin token validated for development user: " .. user_id .. " with roles: " .. table.concat(roles, ", "))
        return { success = true, user = admin_user }
    end
    
    return { success = false, error = "Invalid admin token" }
end

function _M.should_skip_auth(uri)
    local skip_paths = {
        "/auth/",
        "/static/",
        "/health",
        "/login",
        "/favicon.ico"
    }
    
    for _, path in ipairs(skip_paths) do
        if uri:sub(1, #path) == path then
            return true
        end
    end
    
    return false
end

function _M.is_api_request(uri)
    return uri:sub(1, 4) == "/api"
end

function _M.extract_token()
    local auth_header = ngx.var.http_authorization
    if auth_header then
        local token = auth_header:match("Bearer%s+(.+)")
        if token then
            return token, "header"
        end
    end
    
    local cookie_value = ngx.var.cookie_access_token
    if cookie_value then
        return cookie_value, "cookie"
    end
    
    return nil, nil
end

function _M.validate_token(token)
    local exp = _get_jwt_exp(token)
    if exp and type(exp) == "number" and exp < ngx.time() then
        return { success = false, error = "Token expired" }
    end
    local provider_registry = require "auth.core"
    local default_provider = provider_registry.get_default_provider()
    if not default_provider then
        return { success = false, error = "No authentication provider available" }
    end
    return default_provider:validate_token(token)
end

function _M.get_current_auth_session()
    local user = _M.get_current_user()
    if not user then
        return nil, "No active session"
    end
    local tokens = nil
    pcall(function() 
        local session_manager = require "auth.core"
        tokens = session_manager.get_tokens() 
    end)
    return { authenticated = true, user = user, tokens = tokens }
end

function _M.is_authenticated()
    if ngx.ctx.authenticated_user then
        return true
    end
    -- Consider server-side session as authenticated
    local ok_session = false
    pcall(function()
        local session_manager = require "auth.core"
        ok_session = session_manager.is_session_valid()
    end)
    if ok_session then
        local session_manager = require "auth.core"
        local user = session_manager.get_user()
        if user then
            ngx.ctx.authenticated_user = user
            return true
        end
    end
    local token = select(1, _M.extract_token())
    if not token then return false end
    local result = _M.validate_token(token)
    if result and result.success and result.user then
        ngx.ctx.authenticated_user = result.user
        return true
    end
    return false
end

function _M.get_current_user()
    if ngx.ctx.authenticated_user then
        return ngx.ctx.authenticated_user
    end
    local token = select(1, _M.extract_token())
    if token then
        local result = _M.validate_token(token)
        if result and result.success then
            ngx.ctx.authenticated_user = result.user
            return result.user
        end
    end
    -- Fallback to server-side session user
    local user = nil
    pcall(function() 
        local session_manager = require "auth.core"
        user = session_manager.get_user() 
    end)
    if user then
        ngx.ctx.authenticated_user = user
        return user
    end
    return nil
end

function _M.authenticate_user(user_data, tokens, _remember_me)
    if not user_data or not user_data.user_id then
        return { success = false, error = "Invalid user data" }
    end
    local session_manager = require "auth.core"
    local sess_res = session_manager.create_session(user_data)
    if not sess_res or not sess_res.success then
        return { success = false, error = "Failed to create session" }
    end
    if tokens then
        pcall(function() session_manager.store_tokens(tokens) end)
    end
    if tokens and tokens.access_token then
        local auth_endpoints = require "auth.auth_endpoints"
        auth_endpoints.set_auth_cookies(tokens)
    end
    ngx.ctx.authenticated_user = user_data
    monitoring.auth_event("session_created", "success", {
        description = "Token-based login",
        user_id = user_data.user_id,
        username = user_data.email or user_data.name
    })
    return { success = true }
end

function _M.logout_user()
    pcall(function() 
        local session_manager = require "auth.core"
        session_manager.destroy_session() 
    end)
    local auth_endpoints = require "auth.auth_endpoints"
    auth_endpoints.clear_auth_cookies()
    if monitoring then
        monitoring.auth_event("logout", "success", { description = "User logout" })
    end
    return { success = true }
end

function _M.refresh_session()
    local session_manager = require "auth.core"
    local res = session_manager.refresh_session()
    return res and res.success and { success = true } or { success = false }
end

function _M.refresh_user_session()
    return _M.refresh_session()
end

function _M.cleanup_expired_sessions()
    return 0
end

function _M.init_authorization()
    logger.info("Initializing authorization service")
    logger.info("Authorization service initialized")
    return true
end

function _M.check_service_access(user, service_id, service_type)
    if not user or not service_id then
        logger.debug("Authorization check failed: missing user or service_id")
        return false
    end
    
    service_type = service_type or "http"
    
    logger.debug("Checking service access for user: " .. (user.user_id or "unknown") .. 
                      ", service: " .. service_id .. ", type: " .. service_type)
    
    if _M.is_admin(user) then
        logger.debug("Admin user " .. (user.user_id or "unknown") .. " granted access to service: " .. service_id .. " (admin bypass)")
        return true
    end
    
    local user_override = permissions_model.get_user_service_override(user.user_id, service_id, service_type)
    if user_override then
        local has_access = user_override.permission_type == "allow"
        logger.debug("User override found for " .. user.user_id .. ": " .. user_override.permission_type)
        return has_access
    end
    
    if user.roles then
        local has_deny = false
        local has_allow = false
        
        for _, user_role in ipairs(user.roles) do
            if permissions_model.check_role_access(service_id, service_type, user_role) == false then
                local sql = [[
                    SELECT permission_type FROM service_permissions 
                    WHERE service_id = ? AND service_type = ? AND role_id = ?
                    AND permission_type = 'deny'
                    LIMIT 1
                ]]
                local results = db.query(sql, {service_id, service_type, user_role})
                if results and results[1] then
                    has_deny = true
                    logger.debug("User role " .. user_role .. " has explicit deny for service: " .. service_id)
                    break
                end
            end
            
            if permissions_model.check_role_access(service_id, service_type, user_role) then
                has_allow = true
                logger.debug("User role " .. user_role .. " has allow access to service: " .. service_id)
            end
        end
        
        if has_deny then
            logger.debug("Access denied due to explicit deny permission")
            return false
        end
        
        if has_allow then
            logger.debug("Access granted due to allow permission")
            return true
        end
    end
    
    if user.groups then
        local has_group_deny = false
        local has_group_allow = false
        
        for _, group in ipairs(user.groups) do
            if permissions_model.check_group_access(service_id, service_type, group) == false then
                local sql = [[
                    SELECT permission_type FROM service_permissions 
                    WHERE service_id = ? AND service_type = ? AND group_name = ?
                    AND permission_type = 'deny'
                    LIMIT 1
                ]]
                local results = db.query(sql, {service_id, service_type, group})
                if results and results[1] then
                    has_group_deny = true
                    logger.debug("User group " .. group .. " has explicit deny for service: " .. service_id)
                    break
                end
            end
            
            if permissions_model.check_group_access(service_id, service_type, group) then
                has_group_allow = true
                logger.debug("User group " .. group .. " has allow access to service: " .. service_id)
            end
        end
        
        if has_group_deny then
            logger.debug("Access denied due to group deny permission")
            return false
        end
        
        if has_group_allow then
            logger.debug("Access granted due to group allow permission")
            return true
        end
    end
    
    logger.debug("Access denied - no matching permissions found (default deny)")
    return false
end

function _M.get_user_permissions(user)
    if not user then
        return {}
    end
    
    local permissions = {
        roles = user.roles or {},
        groups = user.groups or {},
        overrides = {},
        accessible_services = {
            http = {},
            ssh = {}
        }
    }
    
    permissions.overrides = permissions_model.get_user_overrides(user.user_id)
    
    if user.roles then
        for _, role in ipairs(user.roles) do
            local http_services = permissions_model.get_role_accessible_services(role, "http")
            local ssh_services = permissions_model.get_role_accessible_services(role, "ssh")
            
            for _, service_id in ipairs(http_services) do
                permissions.accessible_services.http[service_id] = true
            end
            
            for _, service_id in ipairs(ssh_services) do
                permissions.accessible_services.ssh[service_id] = true
            end
        end
    end
    
    if user.groups then
        for _, group in ipairs(user.groups) do
            local http_services = permissions_model.get_group_accessible_services(group, "http")
            local ssh_services = permissions_model.get_group_accessible_services(group, "ssh")
            
            for _, service_id in ipairs(http_services) do
                permissions.accessible_services.http[service_id] = true
            end
            
            for _, service_id in ipairs(ssh_services) do
                permissions.accessible_services.ssh[service_id] = true
            end
        end
    end
    
    for _, override in ipairs(permissions.overrides) do
        if override.permission_type == "allow" then
            permissions.accessible_services[override.service_type][override.service_id] = true
        elseif override.permission_type == "deny" then
            permissions.accessible_services[override.service_type][override.service_id] = false
        end
    end
    
    local http_list = {}
    local ssh_list = {}
    
    for service_id, allowed in pairs(permissions.accessible_services.http) do
        if allowed then
            table.insert(http_list, service_id)
        end
    end
    
    for service_id, allowed in pairs(permissions.accessible_services.ssh) do
        if allowed then
            table.insert(ssh_list, service_id)
        end
    end
    
    permissions.accessible_services.http = http_list
    permissions.accessible_services.ssh = ssh_list
    
    return permissions
end

function _M.get_accessible_services(user, service_type)
    if not user then
        return {}
    end
    
    local permissions = _M.get_user_permissions(user)
    
    if service_type then
        return permissions.accessible_services[service_type] or {}
    else
        return permissions.accessible_services
    end
end

function _M.has_permission(user, permission)
    if not user or not permission then
        return false
    end
    if user.roles then
        for _, user_role in ipairs(user.roles) do
            if user_role == permission then
                return true
            end
        end
    end
    return false
end

function _M.is_admin(user)
    return _M.has_permission(user, "jumpserver:admin")
end

function _M.is_developer(user)
    return _M.has_permission(user, "jumpserver:audit") or _M.is_admin(user)
end

function _M.filter_accessible_services(user, services, service_type)
    if not user or not services then
        return {}
    end
    
    local accessible_services = {}
    
    for service_id, service in pairs(services) do
        if _M.check_service_access(user, service_id, service_type) then
            accessible_services[service_id] = service
        end
    end
    
    return accessible_services
end

function _M.get_user_roles(user)
    return (user and user.roles) or {}
end

function _M.create_default_service_permissions(service_id, service_type)
    service_type = service_type or "http"
    
    logger.debug("Skipping default permission creation for service: " .. service_id .. " (type: " .. service_type .. ") - services now start with no assigned permissions")
    
    return true
end

function _M.get_service_required_roles(service_id, service_type)
    return permissions_model.get_required_roles(service_id, service_type)
end

local function return_unauthorized(message)
    ngx.status = 401
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        error = "unauthorized",
        message = message or "Authentication required",
        timestamp = ngx.time()
    }))
    return ngx.exit(401)
end

local function redirect_to_login(reason)
    reason = reason or "authentication_required"
    logger.info("Authentication required: " .. reason .. " for URI: " .. ngx.var.request_uri)

    if web_utils.is_browser_request() then
        return ngx.redirect("/", ngx.HTTP_TEMPORARY_REDIRECT)
    end

    return return_unauthorized("Authentication required")
end

function _M.require_authentication()
    if not _M.is_auth_enabled() then
        logger.debug("Authentication disabled, allowing request")
        return true
    end
    
    local uri = ngx.var.request_uri or ngx.var.uri
    
    if _M.should_skip_auth(uri) then
        logger.debug("Skipping auth for path: " .. uri)
        return true
    end
    
    if _M.is_authenticated() then
        local user = _M.get_current_user()
        if user then
            ngx.ctx.authenticated_user = user
            pcall(function() ngx.var.user_id = user.user_id end)
            pcall(function() ngx.var.user_email = user.email end)
            pcall(function() ngx.var.user_name = user.name end)

            logger.debug("Session authentication successful for user: " .. user.user_id .. " URI: " .. uri)
            return true
        end
    end
    
    if _M.is_api_request(uri) or ngx.var.http_authorization or ngx.var.cookie_access_token then
        local token, source = _M.extract_token()
        
        if token and _M.is_development_mode() then
            local admin_result = _M.validate_admin_token(token)
            if admin_result.success then
                local user = admin_result.user
                ngx.ctx.authenticated_user = user
                pcall(function() ngx.var.user_id = user.user_id end)
                pcall(function() ngx.var.user_email = user.email end)
                pcall(function() ngx.var.user_name = user.name end)
                
                logger.info("Development mode: Admin token authentication successful for user: " .. user.user_id .. " URI: " .. uri)
                return true
            end
        end
        
        pcall(function()
            local session_manager = require "auth.core"
            local provider_registry = require "auth.core"
            local default_provider = provider_registry.get_default_provider()
            local sess_tokens = session_manager.get_tokens()
            local now = ngx.time()
            if default_provider and sess_tokens and sess_tokens.refresh_token then
                local expires_at = tonumber(sess_tokens.expires_at or 0)
                if expires_at > 0 and (expires_at - now) <= 5 then
                    local refresh_res = default_provider:refresh_token(sess_tokens.refresh_token)
                    if refresh_res and refresh_res.success and refresh_res.tokens and refresh_res.tokens.access_token then
                        session_manager.store_tokens(refresh_res.tokens)
                        local auth_endpoints = require "auth.auth_endpoints"
                        auth_endpoints.set_auth_cookies(refresh_res.tokens)
                        token = refresh_res.tokens.access_token
                    end
                end
            end
        end)
        
        if token then
            local result = _M.validate_token(token)
            if result.success then
                local user = result.user
                ngx.ctx.authenticated_user = user
                pcall(function() ngx.var.user_id = user.user_id end)
                pcall(function() ngx.var.user_email = user.email end)
                pcall(function() ngx.var.user_name = user.name end)
                
                logger.debug("Token authentication successful for user: " .. user.user_id .. " URI: " .. uri)
                return true
            else
                -- Automatic refresh using server-side session tokens
                local refreshed = false
                local ok_refresh, _ = pcall(function()
                    local session_manager = require "auth.core"
                    local provider_registry = require "auth.core"
                    local default_provider = provider_registry.get_default_provider()
                    local sess_tokens = session_manager.get_tokens()
                    if default_provider and sess_tokens and sess_tokens.refresh_token then
                        local refresh_res = default_provider:refresh_token(sess_tokens.refresh_token)
                        if refresh_res and refresh_res.success and refresh_res.tokens and refresh_res.tokens.access_token then
                            session_manager.store_tokens(refresh_res.tokens)
                            local auth_endpoints = require "auth.auth_endpoints"
                            auth_endpoints.set_auth_cookies(refresh_res.tokens)
                            -- Validate with new access token
                            local retry = _M.validate_token(refresh_res.tokens.access_token)
                            if retry and retry.success and retry.user then
                                local user = retry.user
                                ngx.ctx.authenticated_user = user
                                pcall(function() ngx.var.user_id = user.user_id end)
                                pcall(function() ngx.var.user_email = user.email end)
                                pcall(function() ngx.var.user_name = user.name end)
                                refreshed = true
                            end
                        end
                    end
                end)
                if refreshed then
                    logger.debug("Token auto-refreshed and validated for URI: " .. uri)
                    return true
                end
                if web_utils.is_browser_request() then
                    return ngx.redirect("/login", ngx.HTTP_TEMPORARY_REDIRECT)
                end
                return return_unauthorized("Authentication required")
            end
        else
            if web_utils.is_browser_request() then
                local restored = false
                pcall(function()
                    local session_manager = require "auth.core"
                    local provider_registry = require "auth.core"
                    local default_provider = provider_registry.get_default_provider()
                    local sess_tokens = session_manager.get_tokens()
                    if default_provider and sess_tokens and sess_tokens.refresh_token then
                        local refresh_res = default_provider:refresh_token(sess_tokens.refresh_token)
                        if refresh_res and refresh_res.success and refresh_res.tokens and refresh_res.tokens.access_token then
                            session_manager.store_tokens(refresh_res.tokens)
                            local auth_endpoints = require "auth.auth_endpoints"
                            auth_endpoints.set_auth_cookies(refresh_res.tokens)
                            restored = true
                        end
                    end
                end)
                if restored then
                    -- With a new cookie, re-run authentication quickly
                    return _M.require_authentication()
                end
                return ngx.redirect("/login", ngx.HTTP_TEMPORARY_REDIRECT)
            end
            return return_unauthorized("No authentication token found")
        end
    end
    
    logger.info("No valid authentication found for URI: " .. uri)
    return redirect_to_login("no_valid_authentication")
end

local function return_forbidden(message)
    if web_utils.is_browser_request() then
        ngx.status = 403
        return ngx.exec("/_error/403")
    end

    ngx.status = 403
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        error = "forbidden",
        message = message or "Access denied",
        timestamp = ngx.time()
    }))
    return ngx.exit(403)
end

function _M.require_authorization(service_id, service_type)
    local auth_result = _M.require_authentication()
    if not auth_result then
        return false
    end
    
    if not _M.is_auth_enabled() then
        logger.debug("Authentication disabled, skipping authorization")
        return true
    end
    
    if not service_id then
        logger.debug("No service ID specified, skipping authorization")
        return true
    end
    
    -- Get current user
    local user = ngx.ctx.authenticated_user
    if not user then
        logger.error("Authorization check failed: no authenticated user in context")
        return return_forbidden("Authentication required")
    end
    
    service_type = service_type or "http"
    
    if _M.is_development_mode() and user.user_id == "dev-admin" then
        logger.info("Development mode: Admin user bypassing authorization for service: " .. service_id)
        return true
    end
    
    local has_access = _M.check_service_access(user, service_id, service_type)
    if not has_access then
        logger.info("Authorization denied for user " .. (user.user_id or "unknown") .. 
                          " to service " .. service_id .. " (" .. service_type .. ")")
        return return_forbidden("Access denied to service: " .. service_id)
    end
    
    logger.debug("Authorization granted for user " .. (user.user_id or "unknown") .. 
                      " to service " .. service_id .. " (" .. service_type .. ")")
    return true
end

function _M.require_permission(permission)
    local auth_result = _M.require_authentication()
    if not auth_result then
        return false
    end
    
    if not _M.is_auth_enabled() then
        logger.debug("Authentication disabled, skipping permission check")
        return true
    end
    
    local user = ngx.ctx.authenticated_user
    if not user then
        logger.error("Permission check failed: no authenticated user in context")
        return return_forbidden("Authentication required")
    end
    
    if _M.is_development_mode() and user.user_id == "dev-admin" then
        logger.info("Development mode: Admin user bypassing permission check for: " .. permission)
        return true
    end
    
    local has_permission = _M.has_permission(user, permission)
    if not has_permission then
        logger.info("Permission denied for user " .. (user.user_id or "unknown") .. 
                          " for permission: " .. permission)
        return return_forbidden("Insufficient permissions: " .. permission)
    end
    
    logger.debug("Permission granted for user " .. (user.user_id or "unknown") .. 
                      " for permission: " .. permission)
    return true
end

function _M.require_service_access(service_id, service_type)
    return _M.require_authorization(service_id, service_type)
end

function _M.require_admin()
    return _M.require_permission("jumpserver:admin")
end

function _M.require_developer()
    return _M.require_permission("jumpserver:audit")
end

function _M.init_middleware()
    logger.info("Initializing authentication middleware")
    return true
end

function _M.init_all()
    local success = true
    success = success and _M.init()
    success = success and _M.init_authorization()
    success = success and _M.init_middleware()
    return success
end

return _M
