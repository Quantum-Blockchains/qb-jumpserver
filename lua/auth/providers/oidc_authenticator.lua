-- OIDC Authentication Provider

local cjson = require "cjson"
local _M = {}
local auth_endpoints = require "auth.auth_endpoints"
local logger = require "utils.logger"

-- Inherit from base authenticator
local authenticator = require "auth.core"
local Authenticator = authenticator.Authenticator

-- OIDC Configuration Manager
local OidcConfigManager = {}
OidcConfigManager.__index = OidcConfigManager

function OidcConfigManager.new()
    local self = setmetatable({}, OidcConfigManager)
    
    self.config_cache = ngx.shared.oidc_config_cache or ngx.shared.sessions
    self.cache_ttl = 3600 -- 1 hour for discovery documents
    
    return self
end

function OidcConfigManager:get_cached_config(key)
    local cached = self.config_cache:get(key)
    if cached then
        local data = cjson.decode(cached)
        if data and data.expires_at and data.expires_at > ngx.time() then
            return data.value
        end
    end
    return nil
end

function OidcConfigManager:set_cached_config(key, value, ttl)
    ttl = ttl or self.cache_ttl
    local data = {
        value = value,
        expires_at = ngx.time() + ttl,
        cached_at = ngx.time()
    }
    local success = self.config_cache:set(key, cjson.encode(data), ttl)
    return success
end

function OidcConfigManager:get_discovery_document(discovery_url)
    local cache_key = "oidc_discovery_" .. ngx.md5(discovery_url)
    local cached = self:get_cached_config(cache_key)
    if cached then
        return cached
    end
    
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeout(10000)
    
    local res, err = httpc:request_uri(discovery_url, {
        method = "GET",
        headers = {
            ["Accept"] = "application/json"
        }
    })
    
    if not res or res.status ~= 200 then
        local error_msg = err or ("HTTP " .. (res and res.status or "unknown"))
        logger.error("OIDC discovery failed: " .. error_msg .. " (URL: " .. discovery_url .. ")")
        return nil
    end
    
    local discovery = cjson.decode(res.body)
    if discovery then
        self:set_cached_config(cache_key, discovery, 3600) -- Cache for 1 hour
    end
    
    return discovery
end

function OidcConfigManager:get_userinfo_from_token(access_token, userinfo_endpoint)
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeout(5000)
    
    local res, err = httpc:request_uri(userinfo_endpoint, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Accept"] = "application/json"
        }
    })
    
    if not res or res.status ~= 200 then
        return nil, "Userinfo fetch failed: " .. (err or res.status)
    end
    
    local userinfo = cjson.decode(res.body)
    return userinfo
end

function OidcConfigManager:introspect_token(access_token, introspection_endpoint, client_id, client_secret)
    if not access_token or not introspection_endpoint then
        return nil, "Missing token or introspection endpoint"
    end
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeout(5000)

    local body = "token=" .. ngx.escape_uri(access_token)
    if client_id then body = body .. "&client_id=" .. ngx.escape_uri(client_id) end
    if client_secret then body = body .. "&client_secret=" .. ngx.escape_uri(client_secret) end

    local res, err = httpc:request_uri(introspection_endpoint, {
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json"
        }
    })

    if not res or res.status ~= 200 then
        return nil, "Introspection failed: " .. (err or (res and res.status) or "unknown")
    end

    local info = cjson.decode(res.body)
    return info
end

local OidcAuthenticator = {}
OidcAuthenticator.__index = OidcAuthenticator
setmetatable(OidcAuthenticator, { __index = Authenticator })

function OidcAuthenticator.new(config)
    local self = setmetatable(Authenticator.new(config), OidcAuthenticator)
    self.name = "oidc"
    self.display_name = "OpenID Connect"
    
    self.config_manager = OidcConfigManager.new()
    local config_manager = require "config.manager"
    self.discovery_url = config_manager.get_env("oidc_discovery_url") or config.discovery_url
    self.client_id = config_manager.get_env("oidc_client_id") or config.client_id
    self.client_secret = config_manager.get_env("oidc_client_secret") or config.client_secret
    self.backchannel_logout_enabled = config.backchannel_logout_enabled or false
    
    self.scope = "openid profile email offline_access"
    self.redirect_uri = nil -- Will be built dynamically
    self.post_logout_redirect_uri = nil -- Will be built dynamically
    
    -- SSL verification
    local ssl_verify = config_manager.get_env("oidc_ssl_verify")
    if ssl_verify ~= nil then
        self.ssl_verify = ssl_verify ~= false
    else
        self.ssl_verify = config.ssl_verify ~= false
    end
    
    self.timeout = tonumber(config_manager.get_env("oidc_timeout")) or tonumber(config.timeout) or 10
    local ok, openidc = pcall(require, "resty.openidc")
    if not ok then
        logger.error("Failed to load lua-resty-openidc library")
        self.enabled = false
    else
        self.openidc = openidc
    end
    
    return self
end

function OidcAuthenticator:authenticate(request_data)
    if not self:is_enabled() then
        return { success = false, error = "OIDC authentication is disabled" }
    end
    
    local discovery = self.config_manager:get_discovery_document(self.discovery_url)
    if not discovery then
        return { success = false, error = "Failed to fetch OIDC discovery document" }
    end
    
    local config_manager = require "config.manager"
    local https_enabled = config_manager.get_env("https_enabled", false)
    local scheme = https_enabled and "https" or "http"
    local host = config_manager.get_env("host") or "localhost"
    local port = config_manager.get_env("port") or (scheme == "https" and "8443" or "8080")
    
    local redirect_uri
    if (scheme == "https" and port == "443") or (scheme == "http" and port == "80") then
        redirect_uri = scheme .. "://" .. host .. "/auth/oidc/callback"
    else
        redirect_uri = scheme .. "://" .. host .. ":" .. port .. "/auth/oidc/callback"
    end
    
    local opts = {
        redirect_uri = redirect_uri,
        discovery = self.discovery_url,
        client_id = self.client_id,
        client_secret = self.client_secret,
        scope = self.scope,
        ssl_verify = self.ssl_verify,
        use_nonce = true,
        use_pkce = true,
        token_endpoint_auth_method = "client_secret_post",
        prompt = "login",
        max_age = 0,
        timeout = {
            connect = 10000,
            send = self.timeout * 1000,
            read = self.timeout * 1000
        }
    }
    
    local res, err = self.openidc.authenticate(opts)
    if not res then
        local error_msg = err or "unknown error"
        logger.error("OIDC authentication failed: " .. error_msg .. " - Check Keycloak connectivity")
        return { success = false, error = err or "OIDC authentication failed" }
    end
    
    local userinfo = nil
    if res.access_token and discovery.userinfo_endpoint then
        userinfo = self.config_manager:get_userinfo_from_token(res.access_token, discovery.userinfo_endpoint)
    end
    
    local user_data = self:extract_user_data(res, userinfo)
    if not user_data then
        return { success = false, error = "Failed to extract user data" }
    end
    
    return {
        success = true,
        user = {
            user_id = user_data.sub,
            email = user_data.email,
            name = user_data.name,
            roles = user_data.roles,
            groups = user_data.groups,
            authenticated = true,
            auth_method = "oidc",
            auth_provider = "oidc"
        },
        tokens = {
            access_token = res.access_token,
            id_token = res.id_token,
            id_token_raw = res.id_token or res.enc_id_token,
            refresh_token = res.refresh_token,
            token_type = "Bearer",
            expires_at = res.expires_at,
            userinfo_endpoint = discovery.userinfo_endpoint
        },
        oidc_data = res,
        discovery = discovery
    }
end

-- Validate OIDC token by fetching fresh userinfo
function OidcAuthenticator:validate_token(token, token_data)
    if not self:is_enabled() then
        return { success = false, error = "OIDC authentication is disabled" }
    end
    
    if not token then
        return { success = false, error = "Token is required" }
    end
    
    -- Get discovery document to find userinfo endpoint
    local discovery = self.config_manager:get_discovery_document(self.discovery_url)
    if not discovery or not discovery.userinfo_endpoint then
        return { success = false, error = "No userinfo endpoint available" }
    end
    
    -- Get fresh userinfo from token for identity basics
    local userinfo = self.config_manager:get_userinfo_from_token(token, discovery.userinfo_endpoint)
    if not userinfo then
        return { success = false, error = "Failed to fetch userinfo" }
    end

    -- Prefer live roles from token introspection (reflects immediate changes)
    local roles, groups = nil, nil
    if discovery.introspection_endpoint then
        local introspect = self.config_manager:introspect_token(token, discovery.introspection_endpoint, self.client_id, self.client_secret)
        if introspect and (introspect.active == nil or introspect.active == true) then
            if introspect.realm_access and introspect.realm_access.roles then
                roles = introspect.realm_access.roles
            end
            if introspect.resource_access then
                roles = roles or {}
                for _, access in pairs(introspect.resource_access) do
                    if access.roles then
                        for _, r in ipairs(access.roles) do table.insert(roles, r) end
                    end
                end
            end
            if introspect.groups then
                groups = introspect.groups
            end
        end
    end

    -- Extract user data and override roles/groups if introspection provided them
    local user_data = self:extract_user_data_from_userinfo(userinfo)
    if not user_data then
        return { success = false, error = "Failed to extract user data" }
    end
    
    if roles and #roles > 0 then user_data.roles = roles end
    if groups and #groups > 0 then user_data.groups = groups end
    
    return {
        success = true,
        user = {
            user_id = user_data.sub or "",
            email = user_data.email or "",
            name = user_data.name or "",
            roles = user_data.roles or {},
            groups = user_data.groups or {},
            authenticated = true,
            auth_method = "oidc",
            auth_provider = "oidc"
        }
    }
end

-- Extract user data from OIDC response or userinfo
function OidcAuthenticator:extract_user_data(oidc_response, userinfo)
    -- Use userinfo if provided, otherwise fallback to token claims
    local user_data_source = userinfo or oidc_response.user or oidc_response.id_token
    
    if not user_data_source then
        logger.error("No user information found in OIDC response")
        return nil
    end
    
    local user_data = self:extract_user_data_from_userinfo(user_data_source)
    
    -- Also check access token JWT payload for roles (Keycloak often puts client roles here)
    if oidc_response.access_token and user_data then
        local access_token_roles = self:extract_roles_from_access_token(oidc_response.access_token)
        if access_token_roles and #access_token_roles > 0 then
            -- Merge roles from access token
            for _, role in ipairs(access_token_roles) do
                local found = false
                for _, existing_role in ipairs(user_data.roles) do
                    if existing_role == role then
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(user_data.roles, role)
                end
            end
        end
    end
    
    return user_data
end

-- Extract user data from userinfo object
function OidcAuthenticator:extract_user_data_from_userinfo(userinfo)
    if not userinfo then
        return nil
    end
    
    -- Extract roles from various possible locations
    local roles = {}
    local groups = {}
    
    -- Extract roles from realm_access (Keycloak)
    if userinfo.realm_access and userinfo.realm_access.roles then
        roles = userinfo.realm_access.roles
    elseif userinfo.resource_access then
        -- Extract roles from resource access
        for resource, access in pairs(userinfo.resource_access) do
            if access.roles then
                for _, role in ipairs(access.roles) do
                    table.insert(roles, role)
                end
            end
        end
    elseif userinfo.roles then
        roles = userinfo.roles
    end
    
    -- Extract groups
    if userinfo.groups then
        groups = userinfo.groups
    end
    
    -- Extract standard claims
    local user_data = {
        sub = userinfo.sub,
        email = userinfo.email,
        name = userinfo.name or userinfo.preferred_username or 
               (userinfo.given_name and userinfo.family_name and 
                userinfo.given_name .. " " .. userinfo.family_name) or userinfo.sub,
        roles = roles,
        groups = groups
    }
    
    return user_data
end

-- Extract roles from access token JWT payload
function OidcAuthenticator:extract_roles_from_access_token(access_token)
    if not access_token or type(access_token) ~= "string" then
        return {}
    end
    
    local roles = {}
    -- Prefer robust parsing via lua-resty-jwt
    local ok_jwt, jwt = pcall(require, "resty.jwt")
    local claims = nil
    if ok_jwt and jwt and jwt.load_jwt then
        local ok_load, obj = pcall(jwt.load_jwt, jwt, access_token)
        if ok_load and obj and obj.payload then
            claims = obj.payload
        end
    end
    if not claims then return roles end
    
    -- Extract roles from various locations in the access token
    if claims.realm_access and claims.realm_access.roles then
        for _, role in ipairs(claims.realm_access.roles) do
            table.insert(roles, role)
        end
    end
    
    if claims.resource_access then
        for resource, access in pairs(claims.resource_access) do
            if access.roles then
                for _, role in ipairs(access.roles) do
                    table.insert(roles, role)
                end
            end
        end
    end
    
    if claims.roles then
        for _, role in ipairs(claims.roles) do
            table.insert(roles, role)
        end
    end
    
    return roles
end


-- Refresh OIDC token
function OidcAuthenticator:refresh_token(refresh_token)
    if not self:is_enabled() then
        return { success = false, error = "OIDC authentication is disabled" }
    end
    
    if not refresh_token then
        return { success = false, error = "Refresh token is required" }
    end
    
    local opts = {
        discovery = self.discovery_url,
        client_id = self.client_id,
        client_secret = self.client_secret,
        ssl_verify = self.ssl_verify,
        timeout = self.timeout
    }
    
    local res, err = self.openidc.refresh_token(opts, refresh_token)
    if not res then
        return { success = false, error = err or "Token refresh failed" }
    end
    
    return {
        success = true,
        tokens = {
            access_token = res.access_token,
            id_token = res.id_token,
            refresh_token = res.refresh_token,
            token_type = "Bearer",
            expires_at = res.expires_at
        }
    }
end

-- Logout from OIDC provider
function OidcAuthenticator:logout(logout_data)
    if not self:is_enabled() then
        return { success = false, error = "OIDC authentication is disabled" }
    end
    
    -- Get end session endpoint from discovery
    local discovery = self.config_manager:get_discovery_document(self.discovery_url)
    local end_session_endpoint = discovery and discovery.end_session_endpoint
    
    if not end_session_endpoint then
        return { success = false, error = "No logout endpoint available" }
    end
    
    -- Get id_token_hint if available
    local id_token_hint = nil
    if logout_data and logout_data.tokens then
        id_token_hint = logout_data.tokens.id_token_raw or logout_data.tokens.id_token
    end
    
    -- Build logout URL
    local logout_url = end_session_endpoint
    if id_token_hint then
        logout_url = logout_url .. "?id_token_hint=" .. ngx.escape_uri(id_token_hint)
    end
    
    local post_logout_redirect_uri = self.post_logout_redirect_uri or 
        (ngx.var.scheme .. "://" .. ngx.var.host .. (ngx.var.server_port and (":" .. ngx.var.server_port) or "") .. "/login")
    
    if logout_url:find("?") then
        logout_url = logout_url .. "&post_logout_redirect_uri=" .. ngx.escape_uri(post_logout_redirect_uri)
    else
        logout_url = logout_url .. "?post_logout_redirect_uri=" .. ngx.escape_uri(post_logout_redirect_uri)
    end
    
    return {
        success = true,
        logout_url = logout_url
    }
end

-- Handle OIDC login
function OidcAuthenticator:handle_login()
    if not self:is_enabled() then
        return { 
            success = false, 
            error = "OIDC authentication is disabled",
            status = 400
        }
    end
    
    -- Preserve return-to path across login
    -- No next parameter support: always land based on auth status
    -- Start OIDC authentication flow
    local result = self:authenticate({})
    if not result.success then
        -- Sanitize error for external response; log the detailed error internally
        local error_detail = result.error or "unknown error"
        logger.error("OIDC login failed: " .. error_detail .. " - Keycloak may be starting up or unreachable")
        return {
            success = false,
            error = "Authentication service unavailable",
            status = 503
        }
    end
    
    -- Create session with user data
    local auth_service = require "auth.auth_service"
    local session_result = auth_service.authenticate_user(
        result.user, 
        result.tokens, 
        false -- remember me
    )
    
    if not session_result.success then
        return {
            success = false,
            error = "Failed to create session: " .. (session_result.error or "unknown error"),
            status = 500
        }
    end
    
    -- Redirect to original destination or dashboard after successful login
    local redirect_url = "/dashboard"
    return {
        success = true,
        action = "redirect",
        redirect_url = redirect_url,
        user = result.user
    }
end

-- Handle OIDC callback
function OidcAuthenticator:handle_callback()
    if not self:is_enabled() then
        return { 
            success = false, 
            error = "OIDC authentication is disabled",
            status = 400
        }
    end
    
    -- Preserve return-to path across login
    -- No next parameter support: always land based on auth status
    -- Process OIDC callback
    local client_ip = ngx.var.remote_addr or "unknown"
    logger.info("Processing OIDC callback (client: " .. client_ip .. ")")
    local result = self:authenticate({})
    if not result.success then
        -- Sanitize error for external response; log the detailed error internally
        logger.error("OIDC callback failed: " .. (result.error or "unknown") .. " - Authentication flow interrupted")
        return {
            success = false,
            error = "Authentication service unavailable",
            status = 503
        }
    end
    
    -- Create session with user data
    local auth_service = require "auth.auth_service"
    local session_result = auth_service.authenticate_user(
        result.user, 
        result.tokens, 
        false -- remember me
    )
    
    if not session_result.success then
        return {
            success = false,
            error = "Failed to create session: " .. (session_result.error or "unknown error"),
            status = 500
        }
    end
    
    -- Redirect to original destination or dashboard after successful login
    local redirect_url = "/dashboard"
    return {
        success = true,
        action = "redirect",
        redirect_url = redirect_url,
        user = result.user
    }
end

function OidcAuthenticator:get_login_url()
    return "/auth/oidc/login"
end

function OidcAuthenticator:get_api_config()
    return {
        enabled = self:is_enabled(),
        display_name = self.display_name,
        login_url = self:get_login_url(),
        discovery_url = self.discovery_url,
        client_id = self.client_id,
        scope = self.scope,
        backchannel_logout_enabled = self.backchannel_logout_enabled
    }
end

-- Handle backchannel logout notification
function OidcAuthenticator:handle_backchannel_logout()
    if not self.backchannel_logout_enabled then
        return {
            success = false,
            error = "Backchannel logout is not enabled",
            status = 400
        }
    end
    
    -- Read the request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    
    if not body then
        return {
            success = false,
            error = "No request body received",
            status = 400
        }
    end
    
    -- Parse the logout token (JWT)
    local logout_token = body:match("logout_token=([^&]+)")
    if not logout_token then
        return {
            success = false,
            error = "No logout token found in request",
            status = 400
        }
    end
    
    -- Decode and validate the logout token
    local ok, decoded = pcall(function()
        return self.openidc.jwt_verify(logout_token, {
            discovery = self.discovery_url,
            ssl_verify = self.ssl_verify,
            timeout = self.timeout
        })
    end)
    
    if not ok or not decoded then
        logger.error("Failed to verify logout token")
        return {
            success = false,
            error = "Invalid logout token",
            status = 400
        }
    end
    
    -- Extract session ID from the logout token
    local session_id = decoded.sid
    if not session_id then
        logger.warn("No session ID found in logout token")
        return {
            success = true,
            message = "No session to logout"
        }
    end
    
    -- Destroy the session
    local session_manager = require "sessions.session_manager"
    local session_mgr = session_manager.SessionManager.new()
    local success, err = session_mgr:destroy_session(session_id)
    
    if success then
        logger.info("Session invalidated via backchannel logout: " .. session_id)
        return {
            success = true,
            message = "Session invalidated successfully"
        }
    else
        logger.warn("Failed to invalidate session via backchannel logout: " .. (err or "unknown error"))
        return {
            success = false,
            error = "Failed to invalidate session: " .. (err or "unknown error"),
            status = 500
        }
    end
end

-- Export the module
_M.OidcAuthenticator = OidcAuthenticator
return _M
