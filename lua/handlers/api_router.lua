-- Centralized API Router

local cjson = require "cjson"
local logger = require "utils.logger"
local auth_service = require "auth.auth_service"
local monitoring = require "monitoring.init"
local data_utils = require "utils.data_utils"
local web_utils = require "utils.web_utils"

local _M = {}

-- API Response format
local function api_response(success, data, error, status)
    local response = {
        success = success,
        timestamp = os.time(),
        status = status or (success and 200 or 400)
    }
    
    if success then
        response.data = data
    else
        response.error = error or "Unknown error"
    end
    
    return response
end

-- Send standardized JSON response
local function send_response(status, success, data, error)
    -- Always return JSON for API routes to keep frontend fetch happy
    local uri = ngx.var and ngx.var.uri or ""
    local is_api = uri:sub(1, 5) == "/api/"

    -- JSON only (no HTML error rendering)

    -- Default JSON response for API clients (and all API endpoints)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate"
    ngx.say(cjson.encode(api_response(success, data, error, status)))
    ngx.exit(status)
end

-- Parse JSON request body
local function parse_json_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return nil, "No request body provided"
    end
    
    local ok, data = pcall(cjson.decode, body)
    if not ok then
        return nil, "Invalid JSON: " .. (data or "unknown error")
    end
    
    return data
end

local function require_auth()
    local user = auth_service.get_current_user()
    if not user and auth_service.is_auth_enabled() then
        monitoring.auth_event("access_denied", "failure", { description = "API request without authentication" })
        send_response(401, false, nil, "Authentication required")
    end
    return user
end

local function require_admin()
    local user = require_auth()
    if user and not auth_service.is_admin(user) then
        monitoring.auth_event("admin_denied", "failure", { description = "Admin privileges required", user_id = user.user_id, username = user.email or user.name })
        send_response(403, false, nil, "Administrator privileges required")
    end
    return user
end

local function require_service_permission(service_id, service_type)
    local user = require_auth()
    if user and not auth_service.check_service_access(user, service_id, service_type) then
        send_response(403, false, nil, "Access denied to this service")
    end
    return user
end

local routes = {
    -- Health endpoint
    ["^/api/health/?$"] = {
        GET = function() 
            return send_response(200, true, {
                status = "healthy",
                timestamp = os.time(),
                version = "1.0.0"
            })
        end,
        middleware = {}
    },
    
    -- Services API
    ["^/api/v1/services/http/?$"] = {
        GET = function() return require("handlers.api.services").http_services_list() end,
        POST = function() return require("handlers.api.services").http_services_create() end,
        middleware = { require_admin }
    },
    ["^/api/v1/services/http/available/?$"] = {
        GET = function() return require("handlers.api.services").http_services_available() end,
        middleware = { require_auth }
    },
    ["^/api/v1/services/http/([^/]+)/?$"] = {
        GET = function(service_id) return require("handlers.api.services").http_services_get(service_id) end,
        PUT = function(service_id) return require("handlers.api.services").http_services_update(service_id) end,
        DELETE = function(service_id) return require("handlers.api.services").http_services_delete(service_id) end,
        middleware = { require_admin }
    },
    ["^/api/v1/services/http/([^/]+)/toggle/?$"] = {
        POST = function(service_id) return require("handlers.api.services").http_services_toggle(service_id) end,
        middleware = { require_admin }
    },
    ["^/api/v1/services/http/([^/]+)/health/target/?$"] = {
        GET = function(service_id) return require("handlers.api.health").http_target_health(service_id) end,
        middleware = { require_auth }
    },
    ["^/api/v1/services/http/([^/]+)/health/proxy/?$"] = {
        GET = function(service_id) return require("handlers.api.health").http_proxy_health(service_id) end,
        middleware = { require_auth }
    },
    ["^/api/v1/services/http/([^/]+)/health/?$"] = {
        GET = function(service_id) return require("handlers.api.health").http_combined_health(service_id) end,
        middleware = { require_auth }
    },
    ["^/api/v1/services/http/([^/]+)/favicon/?$"] = {
        GET = function(service_id) return require("handlers.api.health").http_favicon(service_id) end,
        middleware = { require_auth }
    },
    ["^/api/v1/services/ssh/?$"] = {
        GET = function() return require("handlers.api.services").ssh_services_list() end,
        POST = function() return require("handlers.api.services").ssh_services_create() end,
        middleware = { require_admin }
    },
    ["^/api/v1/services/ssh/available/?$"] = {
        GET = function() return require("handlers.api.services").ssh_services_available() end,
        middleware = { require_auth }
    },
    ["^/api/v1/services/ssh/([^/]+)/?$"] = {
        GET = function(service_id) return require("handlers.api.services").ssh_services_get(service_id) end,
        PUT = function(service_id) return require("handlers.api.services").ssh_services_update(service_id) end,
        DELETE = function(service_id) return require("handlers.api.services").ssh_services_delete(service_id) end,
        middleware = { require_admin }
    },
    ["^/api/v1/services/ssh/([^/]+)/toggle/?$"] = {
        POST = function(service_id) return require("handlers.api.services").ssh_services_toggle(service_id) end,
        middleware = { require_admin }
    },
    ["^/api/v1/services/ssh/([^/]+)/status/?$"] = {
        GET = function(service_id) return require("handlers.api.health").ssh_status(service_id) end,
        middleware = { require_auth }
    },
    
    -- Auth API
    ["^/api/v1/auth/session/?$"] = {
        GET = function() return require("handlers.api.auth").get_session() end,
        DELETE = function() return require("handlers.api.auth").logout() end,
        middleware = { require_auth }
    },
    ["^/api/v1/auth/permissions/?$"] = {
        GET = function() return require("handlers.api.auth").get_permissions() end,
        middleware = { require_auth }
    },
    ["^/api/v1/auth/refresh/?$"] = {
        POST = function() return require("handlers.api.auth").refresh_user_data() end,
        middleware = { require_auth }
    },
    ["^/api/v1/config/frontend/?$"] = {
        GET = function() return require("handlers.api.auth").get_frontend_config() end,
        middleware = {}
    },
    
    -- Admin API
    ["^/api/v1/admin/system/health/?$"] = {
        GET = function() return require("handlers.api.admin").admin_get_system_health() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/system/logs/?$"] = {
        GET = function() return require("handlers.api.admin").admin_get_logs() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/config/export/?$"] = {
        GET = function() return require("handlers.api.admin").admin_export_config() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/docs/?$"] = {
        GET = function() return require("handlers.api.admin").admin_show_api_docs() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/diagnostics/?$"] = {
        GET = function() return require("handlers.api.admin").admin_get_diagnostics() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/monitoring/events/?$"] = {
        GET = function() return require("handlers.api.monitoring").list_events() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/oidc/config/?$"] = {
        GET = function() return require("handlers.api.admin").admin_get_oidc_config() end,
        PUT = function() return require("handlers.api.admin").admin_update_oidc_config() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/oidc/test/?$"] = {
        POST = function() return require("handlers.api.admin").admin_test_oidc_connection() end,
        middleware = { require_admin }
    },

    -- Roles API
    ["^/api/v1/admin/roles/?$"] = {
        GET = function() return require("handlers.api.admin").roles_list() end,
        POST = function() return require("handlers.api.admin").roles_create() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/roles/([^/]+)/?$"] = {
        GET = function(id) return require("handlers.api.admin").roles_get(id) end,
        PUT = function(id) return require("handlers.api.admin").roles_update(id) end,
        DELETE = function(id) return require("handlers.api.admin").roles_delete(id) end,
        middleware = { require_admin }
    },
    
    -- User API  
    ["^/api/v1/user/profile/?$"] = {
        GET = function() return require("handlers.api.user").user_get_profile() end,
        PUT = function() return require("handlers.api.user").user_update_profile() end,
        middleware = { require_auth }
    },

    ["^/api/v1/admin/oidc/status/?$"] = {
        GET = function() return require("handlers.api.auth").get_oidc_status() end,
        middleware = { require_admin }
    },
    ["^/api/v1/admin/system/status/?$"] = {
        GET = function() return require("handlers.api.auth").get_system_status() end,
        middleware = { require_admin }
    }
}

-- Route matching and execution
function _M.handle_request()
    -- Ensure a visitor session UID exists for API requests
    data_utils.ensure_session_uid()
    local method = ngx.req.get_method()
    local uri = ngx.var.uri
    
    logger.debug("API Router: " .. method .. " " .. uri)
    
    local patterns = {}
    for pattern, _ in pairs(routes) do
        table.insert(patterns, pattern)
    end
    table.sort(patterns, function(a, b)
        return #a > #b
    end)

    for _, pattern in ipairs(patterns) do
        local route_config = routes[pattern]
        local matches = {uri:match(pattern)}
        if #matches > 0 or uri:match(pattern) then
            local handler = route_config[method]
            if not handler then
                return send_response(405, false, nil, "Method " .. method .. " not allowed")
            end
            
            if route_config.middleware then
                for _, middleware_fn in ipairs(route_config.middleware) do
                    middleware_fn()
                end
            end
            
            local ok, result = pcall(handler, table.unpack(matches))
            if not ok then
                logger.error("API Handler error: " .. tostring(result))
                return send_response(500, false, nil, "Internal server error")
            end
            
            return result
        end
    end
    
    return send_response(404, false, nil, "API endpoint not found")
end

-- Functions for handlers
_M.send_response = send_response
_M.parse_json_body = parse_json_body
_M.require_auth = require_auth
_M.require_admin = require_admin
_M.require_service_permission = require_service_permission

return _M 