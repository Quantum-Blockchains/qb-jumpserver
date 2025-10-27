-- HTTP Services Manager

local cjson = require "cjson"
local HttpServices = require("models.http_services")
local models = require("models.init")
local sessions = require "sessions.init"
local SessionManager = sessions.SessionManager
local HttpProxySession = sessions.HttpProxySession
local monitoring = require("monitoring.init")
local web_utils = require("utils.web_utils")
local logger = require "utils.logger"

local _M = {}

function _M._count_keys(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

function _M.init()
    local success = models.init_db()
    if not success then
        logger.error("Failed to initialize database")
        return false
    end
    
    -- Import initial HTTP services from file only if database is empty
    local ok, count = pcall(function()
        return HttpServices.count_http_services()
    end)
    if ok and (tonumber(count) or 0) == 0 then
        logger.info("Importing HTTP services from services.json")
        _M.import_initial_http_services()
    else
        logger.info(string.format("Skipping HTTP import - %d services already in database", tonumber(count) or 0))
    end
    
    return true
end

function _M.import_initial_http_services()
    logger.info("HTTP services import starting")
    
    local config_manager = require "config.manager"
    logger.debug("Config manager loaded: " .. tostring(config_manager))
    
    if not config_manager.is_loaded() then
        logger.warn("Configuration manager not loaded")
        return
    end
    
    logger.debug("Configuration manager is loaded")
    local http_services = config_manager.get_http_services()
    logger.debug("HTTP services from config: " .. tostring(http_services))
    
    if not http_services or not next(http_services) then
        logger.info("No HTTP services found in configuration")
        return
    end
    
    logger.info("Found " .. _M._count_keys(http_services) .. " HTTP services in configuration")
    
    local services_array = {}
    for service_id, service in pairs(http_services) do
        logger.debug("Processing service: " .. service_id .. " with URL: " .. (service.url or "nil"))
        
        local new_service = {
            id = service_id,
            name = service.name or service_id,
            type = "http",
            enabled = service.enabled ~= false,
            description = service.description or "",
            source = "json",
            created_at = os.date("%Y-%m-%d %H:%M:%S"),
            updated_at = os.date("%Y-%m-%d %H:%M:%S"),
            valid = true
        }
        
        if service.url then
            local parsed, err = web_utils.parse_url(service.url)
            if parsed then
                logger.debug("Parsed URL for " .. service_id .. ": protocol=" .. parsed.protocol .. ", host=" .. parsed.host .. ", port=" .. parsed.port .. ", path=" .. parsed.path)
                new_service.protocol = parsed.protocol
                new_service.host = parsed.host
                new_service.port = parsed.port
                new_service.path = parsed.path
            else
                logger.warn("Failed to parse URL for service " .. service_id .. ": " .. (err or "unknown error"))
                -- Set defaults if URL parsing fails
                new_service.protocol = "http"
                new_service.host = "localhost"
                new_service.port = 80
                new_service.path = "/"
            end
        else
            -- No URL provided, set defaults
            logger.debug("No URL provided for service " .. service_id .. ", using defaults")
            new_service.protocol = "http"
            new_service.host = "localhost"
            new_service.port = 80
            new_service.path = "/"
        end
        
        logger.debug(string.format("Final service %s: type=%s, protocol=%s, host=%s, port=%d, path=%s", 
            service_id, new_service.type, new_service.protocol, new_service.host, new_service.port, new_service.path))
        
        table.insert(services_array, new_service)
    end
    
    -- Convert to the format expected by the import function
    local import_data = {
        services = services_array
    }
    
    logger.info("About to import " .. #services_array .. " services")
    
    -- Import services
    local imported, skipped, errors = HttpServices.import_http_services_from_json(import_data)
    
    if skipped and skipped > 0 then
        logger.info(string.format("HTTP import: %d imported, %d skipped", imported, skipped))
    else
        logger.info(string.format("HTTP import: %d imported", imported))
    end
    
    if #errors > 0 then
        for _, error in ipairs(errors) do
            logger.warn("HTTP import error: " .. error)
        end
    end
    
    logger.info("HTTP services import complete")
end

function _M.load_http_services(expand_permissions)
    local services = HttpServices.get_all_http_services()
    local result = {}
    
    for _, service in ipairs(services) do
        local out = {
            id = service.id,
            name = service.name,
            type = service.type,
            host = service.host,
            port = service.port,
            protocol = service.protocol,
            url = service.url,
            path = service.path,
            enabled = service.enabled == true,
            description = service.description,
            source = service.source,
            created_at = service.created_at,
            updated_at = service.updated_at
        }
        if expand_permissions then
            local permissions_model = require("models.permissions")
            local perms = permissions_model.get_service_permissions(service.id, "http") or {}
            local list = {}
            for _, p in ipairs(perms) do
                table.insert(list, { type = p.permission_type, role = p.role_name or p.role_id })
            end
            out.permissions = list
        end
        result[service.id] = out
    end
    
    return result
end

function _M.load_enabled_http_services(expand_permissions)
    local services = HttpServices.get_enabled_http_services()
    local result = {}
    
    for _, service in ipairs(services) do
        local out = {
            id = service.id,
            name = service.name,
            type = service.type,
            host = service.host,
            port = service.port,
            protocol = service.protocol,
            url = service.url,
            path = service.path,
            enabled = service.enabled == true,
            description = service.description,
            source = service.source,
            created_at = service.created_at,
            updated_at = service.updated_at
        }
        if expand_permissions then
            local permissions_model = require("models.permissions")
            local perms = permissions_model.get_service_permissions(service.id, "http") or {}
            local list = {}
            for _, p in ipairs(perms) do
                table.insert(list, { type = p.permission_type, role = p.role_name or p.role_id })
            end
            out.permissions = list
        end
        result[service.id] = out
    end
    
    return result
end

function _M.get_http_service(service_id)
    if not service_id then
        return nil
    end
    
    local service = HttpServices.get_http_service(service_id)
    if not service then
        return nil
    end
    
    -- Load permissions for this service
    local permissions_model = require("models.permissions")
    local permissions = permissions_model.get_service_permissions(service_id, "http")
    
    -- Convert permissions to the format expected by the frontend
    local permission_list = {}
    if permissions then
        for _, permission in ipairs(permissions) do
            table.insert(permission_list, {
                type = permission.permission_type,
                role = permission.role_name or permission.role_id
            })
        end
    end
    
    return {
        id = service.id,
        name = service.name,
        type = service.type,
        host = service.host,
        port = service.port,
        protocol = service.protocol,
        url = service.url,
        path = service.path,
        enabled = service.enabled,
        description = service.description,
        source = service.source,
        created_at = service.created_at,
        updated_at = service.updated_at,
        permissions = permission_list
    }
end

function _M.create_http_proxy_session(user_id, service_id)
    if not user_id or not service_id then
        return nil, "User ID and service ID are required"
    end
    
    -- Get service configuration
    local service = _M.get_http_service(service_id)
    if not service then
        return nil, "HTTP service not found"
    end
    
    if not service.enabled then
        return nil, "HTTP service is disabled"
    end
    
    local manager = SessionManager.get_instance()
    
    local session, err = manager:create_session("http_proxy", user_id, service_id, service)
    
    if not session then
        return nil, "Failed to create HTTP proxy session: " .. (err or "unknown error")
    end
    return session
end

function _M.get_http_proxy_session(user_id, service_id)
    if not user_id or not service_id then
        return nil, "User ID and service ID are required"
    end
    
    local manager = SessionManager.get_instance()
    local all_sessions = manager:get_sessions_by_type("http_proxy")
    
    for session_id, session in pairs(all_sessions) do
        if session.user_id == user_id and session.service_id == service_id then
            return session
        end
    end
    
    return nil, "HTTP proxy session not found"
end

function _M.get_or_create_http_proxy_session(user_id, service_id)
    local session, err = _M.get_http_proxy_session(user_id, service_id)
    if session then
        local valid, err = session:validate()
        if valid then
            return session
        else
            -- Session is invalid, destroy it
            session:destroy()
        end
    end
    
    return _M.create_http_proxy_session(user_id, service_id)
end

function _M.record_http_request(user_id, service_id, request_info)
    local session, err = _M.get_http_proxy_session(user_id, service_id)
    if not session then
        return false, "HTTP proxy session not found"
    end
    
    session:record_request(request_info)
    
    local manager = SessionManager.get_instance()
    manager:store_session(session)
    return true
end


function _M.cleanup_expired_http_sessions()
    local manager = SessionManager.get_instance()
    local http_sessions = manager:get_sessions_by_type("http_proxy")
    local cleaned_count = 0
    
    for session_id, session in pairs(http_sessions) do
        if session:is_expired() then
            logger.debug("Cleaning up expired HTTP proxy session: " .. session_id)
            session:destroy()
            cleaned_count = cleaned_count + 1
        end
    end
    
    if cleaned_count > 0 then
        logger.info("Cleaned up " .. cleaned_count .. " expired HTTP proxy sessions")
    else
        logger.debug("Cleaned up " .. cleaned_count .. " expired HTTP proxy sessions")
    end
    return cleaned_count
end

function _M.validate_http_service(service_data)
    local errors = {}
    
    if not service_data.id or service_data.id == "" then
        table.insert(errors, "HTTP service ID is required")
    end
    
    if not service_data.name or service_data.name == "" then
        table.insert(errors, "HTTP service name is required")
    end
    
    if not service_data.host or service_data.host == "" then
        table.insert(errors, "HTTP service host is required")
    end
    
    if not service_data.port or type(service_data.port) ~= "number" or 
       service_data.port < 1 or service_data.port > 65535 then
        table.insert(errors, "HTTP service port must be a number between 1 and 65535")
    end
    
    if service_data.protocol and 
       service_data.protocol ~= "http" and 
       service_data.protocol ~= "https" then
        table.insert(errors, "HTTP service protocol must be http or https")
    end
    
    return #errors == 0, errors
end

function _M.create_http_service(service_data)
    -- Strip unknown fields like permissions before DB write
    local sanitized = HttpServices.sanitize_http_service(service_data)
    local service = HttpServices.create_http_service(sanitized)
    if service then
        logger.info("HTTP service created", { id = service.id, config = service })
        -- Handle permissions if provided
        if service_data.permissions and type(service_data.permissions) == "table" then
            local permissions_model = require("models.permissions")
            for _, permission in ipairs(service_data.permissions) do
                if permission.type and permission.role then
                    -- Use raw role string from OIDC
                    local role_id = tostring(permission.role)
                    if permission.type == "allow" then
                        permissions_model.grant_role_access(service.id, "http", role_id)
                    elseif permission.type == "deny" then
                        permissions_model.deny_role_access(service.id, "http", role_id)
                    else
                        logger.warn("Invalid permission type: " .. tostring(permission.type) .. " for service: " .. service.id)
                    end
                end
            end
            logger.debug("HTTP permissions created", { id = service.id, count = #service_data.permissions })
        else
            -- Create default permissions for the new service
            local auth_service = require("auth.auth_service")
            pcall(function()
                auth_service.create_default_service_permissions(service.id, "http")
                logger.debug("HTTP default permissions created", { id = service.id })
            end)
        end
        -- Attach permissions to response for UI
        local permissions_model = require("models.permissions")
        local perms = permissions_model.get_service_permissions(service.id, "http") or {}
        local list = {}
        for _, p in ipairs(perms) do
            table.insert(list, { type = p.permission_type, role = p.role_name or p.role_id })
        end
        service.permissions = list
        service.enabled = service.enabled == true
    end
    return service
end

function _M.update_http_service(service_id, service_data)
    -- Strip unknown fields like permissions before DB write
    local sanitized = HttpServices.sanitize_http_service(service_data)
    local service = HttpServices.update_http_service(service_id, sanitized)
    if service then
        logger.info("HTTP service updated", { id = service_id, config = service })
        if service_data.permissions and type(service_data.permissions) == "table" then
            -- Clear existing permissions and create new ones
            local permissions_model = require("models.permissions")
            permissions_model.delete_service_permissions(service_id, "http")

            local grants, denies = 0, 0
            for _, permission in ipairs(service_data.permissions) do
                if permission.type and permission.role then
                    local role_id = tostring(permission.role)
                    if permission.type == "allow" then
                        permissions_model.grant_role_access(service_id, "http", role_id)
                        grants = grants + 1
                    elseif permission.type == "deny" then
                        permissions_model.deny_role_access(service_id, "http", role_id)
                        denies = denies + 1
                    end
                end
            end
            logger.debug("HTTP permissions updated", { id = service_id, allow = grants, deny = denies })
        end
        -- Attach current permissions and normalize enabled for response
        local permissions_model = require("models.permissions")
        local perms = permissions_model.get_service_permissions(service_id, "http") or {}
        local list = {}
        for _, p in ipairs(perms) do
            table.insert(list, { type = p.permission_type, role = p.role_id })
        end
        service.permissions = list
        service.enabled = service.enabled == true
    end
    return service
end

function _M.delete_http_service(service_id)
    local existing = HttpServices.get_http_service(service_id)
    local ok, err = HttpServices.delete_http_service(service_id)
    if ok then
        logger.info("HTTP service deleted", { id = tostring(service_id), config = existing })
        -- also remove any lingering permissions
        local permissions_model = require("models.permissions")
        permissions_model.delete_service_permissions(service_id, "http")
        return true
    end
    return ok, err
end

function _M.toggle_http_service(service_id)
    local service = HttpServices.get_http_service(service_id)
    if not service then
        return nil, "HTTP service not found"
    end
    
    -- Toggle enabled status (normalize to boolean)
    local updated_data = {
        id = service.id,
        name = service.name,
        type = service.type,
        host = service.host,
        port = service.port,
        protocol = service.protocol,
        url = service.url,
        path = service.path,
        enabled = not (service.enabled == true),
        description = service.description
    }
    
    local updated = HttpServices.update_http_service(service_id, updated_data)
    if updated then
        logger.info("HTTP service toggled", { id = service_id, enabled = updated.enabled, config = updated })
        -- include permissions in toggle response for UI consistency
        local permissions_model = require("models.permissions")
        local perms = permissions_model.get_service_permissions(service_id, "http") or {}
        local list = {}
        for _, p in ipairs(perms) do
            table.insert(list, { type = p.permission_type, role = p.role_name or p.role_id })
        end
        updated.permissions = list
        -- ensure enabled is boolean in response
        updated.enabled = updated.enabled == true
    end
    return updated
end



function _M.export_http_services_to_file()
    local export_data = HttpServices.export_http_services_to_json()
    local export_path = "/app/services_export.json"
    
    local file = io.open(export_path, "w")
    if not file then
        return false, "Failed to open export file"
    end
    
    local cjson = require "cjson"
    file:write(cjson.encode(export_data))
    file:close()
    
    return true
end

function _M.import_http_services_from_file(file_path)
    file_path = file_path or "/app/services.json"
    
    local file = io.open(file_path, "r")
    if not file then
        return 0, {"File not found: " .. file_path}
    end
    
    local content = file:read("*all")
    file:close()
    
    if not content or content == "" then
        return 0, {"File is empty: " .. file_path}
    end
    
    local ok, data = pcall(cjson.decode, content)
    if not ok then
        return 0, 0, {"Invalid JSON in file: " .. file_path}
    end
    
    return HttpServices.import_http_services_from_json(data)
end

function _M.get_proxy_path(service_id)
    if not service_id then
        return nil
    end
    
    return "/http/" .. service_id .. "/"
end

return _M 