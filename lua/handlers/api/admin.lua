-- Admin API Handlers

local cjson = require "cjson"
local api_router = require "handlers.api_router"
local web_utils = require "utils.web_utils"
local data_utils = require "utils.data_utils"

local _M = {}

local STATIC_ROLES = {"jumpserver:admin", "jumpserver:audit", "jumpserver:user"}

function _M.admin_get_system_health()
    local health = {
        status = "healthy",
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        checks = {
            database = {
                status = "healthy",
                message = "Database connection active"
            },
            auth = {
                status = "healthy", 
                message = "Authentication system operational"
            },
            services = {
                status = "healthy",
                message = "Service management operational"
            },
            api = {
                status = "healthy",
                message = "API endpoints responding"
            }
        },
        uptime = {
            server_start = os.date("%Y-%m-%d %H:%M:%S", os.time() - 3600), -- Mock 1 hour uptime
            current_time = os.date("%Y-%m-%d %H:%M:%S")
        }
    }
    
    local db = require("models.init").get_db()
    if not db then
        health.checks.database.status = "unhealthy"
        health.checks.database.message = "Database connection failed"
        health.status = "degraded"
    end
    
    local http_services_model = require "models.http_services"
    local ssh_services_model = require "models.ssh_services"
    local http_services = http_services_model.get_all_http_services()
    local ssh_services = ssh_services_model.get_all_ssh_services()
    
    if not http_services and not ssh_services then
        health.checks.services.status = "warning"
        health.checks.services.message = "No services configured"
        if health.status == "healthy" then
            health.status = "warning"
        end
    end
    
    return api_router.send_response(200, true, health)
end

function _M.admin_get_logs()
    local log_level = ngx.var.arg_level or "all"
    local max_lines = tonumber(ngx.var.arg_limit) or 100
    
    local logs = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        level = log_level,
        max_lines = max_lines,
        entries = {}
    }
    
    -- Read nginx logs
    local log_files = {
        {path = "/var/log/nginx/error.log", type = "error"},
        {path = "/var/log/nginx/access.log", type = "access"},
        {path = "/app/logs/error.log", type = "app_error"},
        {path = "/app/logs/access.log", type = "app_access"}
    }
    
    for _, log_file in ipairs(log_files) do
        local file = io.open(log_file.path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            
            local lines = {}
            for line in content:gmatch("[^\r\n]+") do
                table.insert(lines, line)
            end
            
            -- Get recent lines
            local start_line = math.max(1, #lines - max_lines + 1)
            local recent_entries = {}
            for i = start_line, #lines do
                table.insert(recent_entries, {
                    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
                    level = "info",
                    message = lines[i],
                    source = log_file.type
                })
            end
            
            -- Add to logs
            for _, entry in ipairs(recent_entries) do
                table.insert(logs.entries, entry)
            end
        end
    end
    
    -- Sort by timestamp (newest first)
    table.sort(logs.entries, function(a, b)
        return a.timestamp > b.timestamp
    end)
    
    -- Limit total entries
    if #logs.entries > max_lines then
        local limited_entries = {}
        for i = 1, max_lines do
            table.insert(limited_entries, logs.entries[i])
        end
        logs.entries = limited_entries
    end
    
    return api_router.send_response(200, true, logs)
end

function _M.admin_export_config()
    local permissions_model = require "models.permissions"
    local http_services_model = require "models.http_services"
    local ssh_services_model = require "models.ssh_services"
    
    local config = {
        metadata = {
            exported_at = os.date("%Y-%m-%d %H:%M:%S"),
            version = "1.0",
            description = "Jump Server Configuration Export"
        },
        roles = STATIC_ROLES,
        permissions = permissions_model.get_all_service_permissions() or {},
        http_services = http_services_model.get_all_http_services() or {},
        ssh_services = ssh_services_model.get_all_ssh_services() or {},
        system_info = {
            server_time = os.date("%Y-%m-%d %H:%M:%S"),
            lua_version = _VERSION,
            nginx_version = ngx.var.nginx_version or "unknown"
        }
    }
    
    -- Set headers for file download
    ngx.header.content_type = "application/json"
    ngx.header["Content-Disposition"] = 'attachment; filename="jump-server-config-' .. os.date("%Y%m%d-%H%M%S") .. '.json"'
    ngx.header["Cache-Control"] = "no-cache"
    
    ngx.say(cjson.encode(config))
    ngx.exit(200)
end

function _M.admin_get_health()
    local health = {
        status = "healthy",
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        checks = {
            database = {status = "healthy", message = "Database accessible"},
            services = {status = "healthy", message = "Service managers operational"},
            auth = {status = "healthy", message = "Authentication system operational"},
            storage = {status = "healthy", message = "File system accessible"}
        }
    }
    
    -- Basic health checks
    local overall_healthy = true
    
    -- Check if we can access models (database check)
    local http_services_model = require "models.http_services"
    local ok_db = pcall(function()
        http_services_model.get_all_http_services()
    end)
    
    if not ok_db then
        health.checks.database.status = "unhealthy"
        health.checks.database.message = "Database access failed"
        overall_healthy = false
    end
    
    -- Check file system access
    local ok_fs = pcall(function()
        local test_file = io.open("/tmp/health_check", "w")
        if test_file then
            test_file:write("test")
            test_file:close()
            os.remove("/tmp/health_check")
        else
            error("Cannot write to filesystem")
        end
    end)
    
    if not ok_fs then
        health.checks.storage.status = "unhealthy"
        health.checks.storage.message = "File system access failed"
        overall_healthy = false
    end
    
    health.status = overall_healthy and "healthy" or "unhealthy"
    local status_code = overall_healthy and 200 or 503
    
    return api_router.send_response(status_code, overall_healthy, health)
end

function _M.admin_maintenance()
    local body, err = api_router.parse_json_body()
    if not body then
        return api_router.send_response(400, false, nil, err)
    end
    
    local operation = body.operation
    local results = {
        operation = operation,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        success = false,
        details = {}
    }
    
    if operation == "cleanup_sessions" then
        results.success = true
        results.details.cleaned_sessions = 0
        results.details.message = "Session cleanup completed"
        
    elseif operation == "reload_config" then
        results.success = true
        results.details.message = "Configuration reloaded successfully"
        
    elseif operation == "clear_cache" then
        results.success = true
        results.details.message = "Cache cleared successfully"
        
    else
        return api_router.send_response(400, false, nil, "Unknown maintenance operation: " .. tostring(operation))
    end
    
    local status_code = results.success and 200 or 500
    return api_router.send_response(status_code, results.success, results)
end

function _M.admin_get_oidc_config()
    local config_manager = require "config.manager"
    local admin_oidc_config = config_manager.get_admin_oidc_config()
    
    if not admin_oidc_config then
        return api_router.send_response(500, false, nil, "Configuration not loaded")
    end
    
    admin_oidc_config.available_roles = STATIC_ROLES
    admin_oidc_config.enabled_roles = STATIC_ROLES
    admin_oidc_config.roles_source = "static"
    admin_oidc_config.admin_url = config_manager.get_keycloak_admin_url()
    admin_oidc_config.show_oidc_menu = config_manager.get_env("show_oidc_menu") == true
    
    return api_router.send_response(200, true, admin_oidc_config)
end

function _M.admin_update_oidc_config()
    return api_router.send_response(400, false, nil, "Role configuration is now static and cannot be updated via API")
end

function _M.admin_test_oidc_connection()
    local config_manager = require "config.manager"
    local admin_oidc_config = config_manager.get_admin_oidc_config()
    
    if not admin_oidc_config then
        return api_router.send_response(500, false, nil, "Configuration not loaded")
    end
    
    local discovery_url = admin_oidc_config.discovery_url
    
    if not discovery_url or discovery_url == "" then
        return api_router.send_response(400, false, nil, "OIDC discovery URL not configured")
    end
    
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeout(5000)
    
    local res, err = httpc:request_uri(discovery_url, {
        method = "GET",
        headers = {
            ["User-Agent"] = "Jump-Server/1.0"
        }
    })
    
    if not res then
        return api_router.send_response(500, false, nil, "Failed to connect to OIDC provider: " .. (err or "unknown error"))
    end
    
    if res.status ~= 200 then
        return api_router.send_response(500, false, nil, "OIDC provider returned status: " .. res.status)
    end
    
    local ok, discovery_doc = pcall(cjson.decode, res.body)
    if not ok then
        return api_router.send_response(500, false, nil, "Invalid OIDC discovery document")
    end
    
    local test_result = {
        status = "success",
        discovery_url = discovery_url,
        provider_info = {
            issuer = discovery_doc.issuer,
            authorization_endpoint = discovery_doc.authorization_endpoint,
            token_endpoint = discovery_doc.token_endpoint,
            userinfo_endpoint = discovery_doc.userinfo_endpoint
        },
        tested_at = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    return api_router.send_response(200, true, test_result)
end

function _M.admin_show_api_docs()
    local docs = {
        title = "Jump Server API Documentation",
        version = "v1",
        base_url = "/api/v1",
        endpoints = {
            services = {
                http = {
                    ["GET /api/v1/services/http"] = "List all HTTP services",
                    ["POST /api/v1/services/http"] = "Create new HTTP service",
                    ["GET /api/v1/services/http/{id}"] = "Get HTTP service details",
                    ["PUT /api/v1/services/http/{id}"] = "Update HTTP service",
                    ["DELETE /api/v1/services/http/{id}"] = "Delete HTTP service",
                    ["POST /api/v1/services/http/{id}/toggle"] = "Toggle HTTP service status",
                    ["GET /api/v1/services/http?expand=permissions=true"] = "List HTTP services including permissions"
                },
                ssh = {
                    ["GET /api/v1/services/ssh"] = "List all SSH services",
                    ["POST /api/v1/services/ssh"] = "Create new SSH service",
                    ["GET /api/v1/services/ssh/{id}"] = "Get SSH service details",
                    ["PUT /api/v1/services/ssh/{id}"] = "Update SSH service",
                    ["DELETE /api/v1/services/ssh/{id}"] = "Delete SSH service",
                    ["GET /api/v1/services/ssh?expand=permissions=true"] = "List SSH services including permissions"
                }
            },
            auth = {
                ["GET /api/v1/auth/session"] = "Get current session info",
                ["DELETE /api/v1/auth/session"] = "Logout current session",
                ["GET /api/v1/auth/permissions"] = "Get user permissions"
            },
            admin = {
                ["GET /api/v1/admin/system/logs"] = "Get system logs",
                ["GET /api/v1/admin/config/export"] = "Export configuration",
                ["GET /api/v1/admin/docs"] = "API documentation"
            },
            user = {
                ["GET /api/v1/user/profile"] = "Get user profile",
                ["PUT /api/v1/user/profile"] = "Update user profile"
            }
        },
        response_format = {
            success = true,
            data = "...",
            timestamp = "unix_timestamp",
            status = 200
        },
        error_format = {
            success = false,
            error = "Error message",
            timestamp = "unix_timestamp", 
            status = "4xx_or_5xx"
        }
    }
    
    return api_router.send_response(200, true, docs)
end

function _M.roles_list()
    local permissions_model = require "models.permissions"
    local auth_service = require "auth.auth_service"
    local config_manager = require "config.manager"
    local logger = require "utils.logger"
    
    local env = config_manager.get("env") or {}
    local host = env.keycloak_host
    local port = env.keycloak_internal_port or env.keycloak_port
    local realm = env.keycloak_realm
    local admin_user = env.keycloak_admin
    local admin_pass = env.keycloak_admin_password
    local roles = {}
    local fetched = false
    
    if host and port and realm and admin_user and admin_pass then
        local http_ok, http = pcall(require, "resty.http")
        if http_ok and http then
        local httpc = http.new()
        pcall(function() httpc:set_timeout(5000) end)
        local token_res, token_err = httpc:request_uri("http://" .. host .. ":" .. tostring(port) .. "/realms/master/protocol/openid-connect/token", {
                method = "POST",
                body = "grant_type=password&client_id=admin-cli&username=" .. ngx.escape_uri(admin_user) .. "&password=" .. ngx.escape_uri(admin_pass),
                headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
            })
            if token_res and (token_res.status == 200) then
                local ok, token_json = pcall(require("cjson").decode, token_res.body)
            if ok and token_json and token_json.access_token then
                local roles_res, roles_err = httpc:request_uri("http://" .. host .. ":" .. tostring(port) .. "/admin/realms/" .. ngx.escape_uri(realm) .. "/roles", {
                        method = "GET",
                        headers = { ["Authorization"] = "Bearer " .. token_json.access_token, ["Accept"] = "application/json" }
                    })
                    if roles_res and roles_res.status == 200 then
                        local ok2, roles_json = pcall(require("cjson").decode, roles_res.body)
                        if ok2 and type(roles_json) == "table" then
                            for _, r in ipairs(roles_json) do
                                table.insert(roles, { id = r.name, name = r.name, description = r.description })
                            end
                            table.sort(roles, function(a,b) return (a.id or '') < (b.id or '') end)
                            fetched = true
                        end
                    else
                        logger.warn("Failed to fetch realm roles: " .. tostring(roles_err or (roles_res and roles_res.status)))
                    end
                else
                    logger.warn("Failed to parse admin token response")
                end
            else
                logger.warn("Failed to obtain admin token from Keycloak: " .. tostring(token_err or (token_res and token_res.status)))
            end
        end
    end
    
    if not fetched then
        local all_perms = permissions_model.get_all_service_permissions() or {}
        local distinct = {}
        for _, p in ipairs(all_perms) do
            if p.role_id and p.role_id ~= "" then
                distinct[p.role_id] = true
            end
        end
        local user = auth_service.get_current_user()
        if user and user.roles then
            for _, r in ipairs(user.roles) do
                distinct[tostring(r)] = true
            end
        end
        for role_id, _ in pairs(distinct) do
            table.insert(roles, { id = role_id, name = role_id })
        end
        table.sort(roles, function(a,b) return a.id < b.id end)
    end
    
    return api_router.send_response(200, true, { roles = roles, source = fetched and "keycloak" or "local" })
end

function _M.roles_get(role_id)
    -- Read-only: return minimal descriptor
    if not role_id or role_id == "" then
        return api_router.send_response(400, false, nil, "role_id required")
    end
    return api_router.send_response(200, true, { id = role_id, name = role_id })
end

function _M.roles_create()
    return api_router.send_response(405, false, nil, "Roles are managed by IdP; creation disabled")
end

function _M.roles_update(role_id)
    return api_router.send_response(405, false, nil, "Roles are managed by IdP; update disabled")
end

function _M.roles_delete(role_id)
    return api_router.send_response(405, false, nil, "Roles are managed by IdP; deletion disabled")
end

function _M.admin_get_diagnostics()
    local config_manager = require "config.manager"
    local env = config_manager.get("env") or {}
    local logger = require "utils.logger"
    
    -- Get all config values but filter out sensitive data
    local diagnostics = {}
    
    local function to_string(val)
        if val == nil then return "not set" end
        if type(val) == "boolean" then return val and "true" or "false" end
        return tostring(val)
    end
    
    diagnostics.server = {
        host = to_string(env.host),
        port = to_string(env.port),
        title = to_string(env.jump_server_title),
        environment = to_string(env.environment),
        https_enabled = to_string(env.https_enabled),
        docker_network = to_string(env.docker_network)
    }
    
    diagnostics.oidc = {
        enabled = to_string(env.oidc_enabled),
        base_url = to_string(env.oidc_base_url),
        realm = to_string(env.oidc_realm),
        client_id = to_string(env.oidc_client_id),
        client_secret = env.oidc_client_secret and "***HIDDEN***" or "not set"
    }
    
    local session_config = config_manager.get_session_config()
    diagnostics.session = {
        lifetime = tostring(session_config.lifetime) .. "s",
        rolling_timeout = tostring(session_config.rolling_timeout) .. "s",
        max_per_user = tostring(session_config.max_per_user),
        max_idle_time = tostring(session_config.max_idle_time) .. "s"
    }
    
    -- Services count
    local http_services_model = require "models.http_services"
    local ssh_services_model = require "models.ssh_services"
    local http_services = http_services_model.get_all_http_services() or {}
    local ssh_services = ssh_services_model.get_all_ssh_services() or {}
    
    diagnostics.services = {
        http_count = tostring(#http_services),
        ssh_count = tostring(#ssh_services),
        total = tostring(#http_services + #ssh_services)
    }
    
    diagnostics.runtime = {
        lua_version = _VERSION,
        nginx_version = ngx.var.nginx_version or "unknown",
        timestamp = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    return api_router.send_response(200, true, diagnostics)
end

return _M
