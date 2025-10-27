-- SSH Services Manager

local cjson = require "cjson"
local SshServices = require("models.ssh_services")
local models = require("models.init")
local sessions = require "sessions.init"
local SessionManager = sessions.SessionManager
local SshProxySession = sessions.SshProxySession
local monitoring = require("monitoring.init")
local logger = require "utils.logger"

local _M = {}

function _M.init()
    -- Initialize database
    local success = models.init_db()
    if not success then
        logger.error("Failed to initialize database")
        return false
    end
    
    -- Import initial SSH services from file only if database is empty
    local ok, count = pcall(function()
        return SshServices.count_ssh_services()
    end)
    if ok and (tonumber(count) or 0) == 0 then
        logger.info("Importing SSH services from services.json")
        _M.import_initial_ssh_services()
    else
        logger.info(string.format("Skipping SSH import - %d services already in database", tonumber(count) or 0))
    end
    
    return true
end

function _M.import_initial_ssh_services()
    logger.info("Importing SSH services from unified configuration...")
    
    local config_manager = require "config.manager"
    if not config_manager.is_loaded() then
        logger.error("Configuration manager not loaded")
        return
    end
    
    local ssh_services = config_manager.get_ssh_services()
    if not ssh_services or not next(ssh_services) then
        logger.info("No SSH services found in configuration")
        return
    end
    
    local services_array = {}
    for service_id, service in pairs(ssh_services) do
        service.id = service_id
        service.type = service.type or "ssh"
        service.port = service.port or 22
        service.username = service.username or ""
        service.enabled = service.enabled ~= false -- default to true
        service.source = service.source or "json"
        
        table.insert(services_array, service)
    end
    
    local import_data = {
        services = services_array
    }
    
    local imported, skipped, errors = SshServices.import_ssh_services_from_json(import_data)
    
    if skipped and skipped > 0 then
        logger.info(string.format("SSH import: %d imported, %d skipped", imported, skipped))
    else
        logger.info(string.format("SSH import: %d imported", imported))
    end
    
    if #errors > 0 then
        for _, error in ipairs(errors) do
            logger.error("SSH import error: " .. error)
        end
    end
end

function _M.load_ssh_services(expand_permissions)
    local services = SshServices.get_all_ssh_services()
    local result = {}
    
    for _, service in ipairs(services) do
        local out = {
            id = service.id,
            name = service.name,
            type = service.type,
            host = service.host,
            port = service.port,
            username = service.username,
            enabled = service.enabled == true,
            description = service.description,
            source = service.source,
            created_at = service.created_at,
            updated_at = service.updated_at
        }
        if expand_permissions then
            local permissions_model = require("models.permissions")
            local perms = permissions_model.get_service_permissions(service.id, "ssh") or {}
            local list = {}
            for _, p in ipairs(perms) do
                table.insert(list, { type = p.permission_type, role = p.role_id })
            end
            out.permissions = list
        end
        result[service.id] = out
    end
    
    return result
end

-- Load only enabled SSH services
function _M.load_enabled_ssh_services(expand_permissions)
    local services = SshServices.get_enabled_ssh_services()
    local result = {}
    
    for _, service in ipairs(services) do
        local out = {
            id = service.id,
            name = service.name,
            type = service.type,
            host = service.host,
            port = service.port,
            username = service.username,
            enabled = service.enabled == true,
            description = service.description,
            source = service.source,
            created_at = service.created_at,
            updated_at = service.updated_at
        }
        if expand_permissions then
            local permissions_model = require("models.permissions")
            local perms = permissions_model.get_service_permissions(service.id, "ssh") or {}
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

function _M.get_ssh_service(service_id)
    if not service_id then
        return nil
    end
    
    local service = SshServices.get_ssh_service(service_id)
    if not service then
        return nil
    end
    
    -- Load permissions for this service
    local permissions_model = require("models.permissions")
    local permissions = permissions_model.get_service_permissions(service_id, "ssh")
    
    -- Convert permissions to the format expected by the frontend
    local permission_list = {}
    if permissions then
        for _, permission in ipairs(permissions) do
            table.insert(permission_list, {
                type = permission.permission_type,
                role = permission.role_id
            })
        end
    end
    
    return {
        id = service.id,
        name = service.name,
        type = service.type,
        host = service.host,
        port = service.port,
        username = service.username,
        enabled = service.enabled,
        description = service.description,
        source = service.source,
        created_at = service.created_at,
        updated_at = service.updated_at,
        permissions = permission_list
    }
end

-- Create SSH proxy session for user
function _M.create_ssh_proxy_session(user_id, service_id)
    if not user_id or not service_id then
        return nil, "User ID and service ID are required"
    end
    
    -- Get service configuration
    local service = _M.get_ssh_service(service_id)
    if not service then
        return nil, "SSH service not found"
    end
    
    if not service.enabled then
        return nil, "SSH service is disabled"
    end
    
    local manager = SessionManager.get_instance()
    
    -- Create SSH proxy session
    local session, err = manager:create_session("ssh_proxy", user_id, service_id, service)
    
    if not session then
        return nil, "Failed to create SSH proxy session: " .. (err or "unknown error")
    end
    return session
end

function _M.get_ssh_proxy_session(user_id, service_id)
    if not user_id or not service_id then
        return nil, "User ID and service ID are required"
    end
    
    local manager = SessionManager.get_instance()
    local all_sessions = manager:get_sessions_by_type("ssh_proxy")
    
    -- Find session for this user and service
    for session_id, session in pairs(all_sessions) do
        if session.user_id == user_id and session.service_id == service_id then
            return session
        end
    end
    
    return nil, "SSH proxy session not found"
end

-- Create new SSH proxy session (always creates a new session)
function _M.create_new_ssh_proxy_session(user_id, service_id)
    -- Always create a new session for each connection
    return _M.create_ssh_proxy_session(user_id, service_id)
end


function _M.get_or_create_ssh_proxy_session(user_id, service_id)
    local existing = _M.get_ssh_proxy_session(user_id, service_id)
    if existing then
        return existing
    end
    return _M.create_ssh_proxy_session(user_id, service_id)
end

 

function _M.get_all_ssh_sessions()
    local manager = SessionManager.get_instance()
    return manager:get_sessions_by_type("ssh_proxy")
end

function _M.get_ssh_session_by_socket(socket_path)
    if not socket_path then
        return nil
    end
    
    local manager = SessionManager.get_instance()
    local all_sessions = manager:get_sessions_by_type("ssh_proxy")
    
    for session_id, session in pairs(all_sessions) do
        if session.socket_path == socket_path then
            return session
        end
    end
    
    return nil
end



-- Clean up expired SSH proxy sessions
function _M.cleanup_expired_ssh_sessions()
    local manager = SessionManager.get_instance()
    local ssh_sessions = manager:get_sessions_by_type("ssh_proxy")
    local cleaned_count = 0
    
    for session_id, session in pairs(ssh_sessions) do
        if session:is_expired() then
            logger.debug("Cleaning up expired SSH proxy session: " .. session_id)
            session:destroy()
            cleaned_count = cleaned_count + 1
        end
    end
    
    if cleaned_count > 0 then
        logger.info("Cleaned up " .. cleaned_count .. " expired SSH proxy sessions")
    else
        logger.debug("Cleaned up " .. cleaned_count .. " expired SSH proxy sessions")
    end
    return cleaned_count
end

-- Validate SSH service configuration
function _M.validate_ssh_service(service_data)
    local errors = {}
    
    if not service_data.id or service_data.id == "" then
        table.insert(errors, "SSH service ID is required")
    end
    
    if not service_data.name or service_data.name == "" then
        table.insert(errors, "SSH service name is required")
    end
    
    if not service_data.host or service_data.host == "" then
        table.insert(errors, "SSH service host is required")
    end
    
    if not service_data.port or type(service_data.port) ~= "number" or 
       service_data.port < 1 or service_data.port > 65535 then
        table.insert(errors, "SSH service port must be a number between 1 and 65535")
    end
    
    -- Username is now provided interactively, so it's optional in the service config
    -- if not service_data.username or service_data.username == "" then
    --     table.insert(errors, "SSH service username is required")
    -- end
    
    return #errors == 0, errors
end

function _M.create_ssh_service(service_data)
    -- Strip unknown fields like permissions before DB write
    local sanitized = SshServices.sanitize_ssh_service(service_data)
    local service = SshServices.create_ssh_service(sanitized)
    if service then
        logger.info("SSH service created", { id = service.id, config = service })
        -- Handle permissions if provided
        if service_data.permissions and type(service_data.permissions) == "table" then
            local permissions_model = require("models.permissions")
            for _, permission in ipairs(service_data.permissions) do
                if permission.type and permission.role then
                    local role_id = tostring(permission.role)
                    if permission.type == "allow" then
                        permissions_model.grant_role_access(service.id, "ssh", role_id)
                    elseif permission.type == "deny" then
                        permissions_model.deny_role_access(service.id, "ssh", role_id)
                    else
                        logger.warn("Invalid permission type: " .. tostring(permission.type) .. " for service: " .. service.id)
                    end
                end
            end
            logger.debug("SSH permissions created", { id = service.id, count = #service_data.permissions })
        else
            -- Create default permissions for the new service
            local auth_service = require("auth.auth_service")
            pcall(function()
                auth_service.create_default_service_permissions(service.id, "ssh")
                logger.debug("SSH default permissions created", { id = service.id })
            end)
        end
    end
    return service
end

function _M.update_ssh_service(service_id, service_data)
    -- Strip unknown fields like permissions before DB write
    local sanitized = SshServices.sanitize_ssh_service(service_data)
    local service = SshServices.update_ssh_service(service_id, sanitized)
    if service and service_data.permissions and type(service_data.permissions) == "table" then
        logger.info("SSH service updated", { id = service_id, config = service })
        -- Clear existing permissions and create new ones
        local permissions_model = require("models.permissions")
        permissions_model.delete_service_permissions(service_id, "ssh")

        local grants, denies = 0, 0
        for _, permission in ipairs(service_data.permissions) do
            if permission.type and permission.role then
                local role_id = tostring(permission.role)
                if permission.type == "allow" then
                    permissions_model.grant_role_access(service_id, "ssh", role_id)
                    grants = grants + 1
                elseif permission.type == "deny" then
                    permissions_model.deny_role_access(service_id, "ssh", role_id)
                    denies = denies + 1
                end
            end
        end
        logger.debug("SSH permissions updated", { id = service_id, allow = grants, deny = denies })
    end
    return service
end

function _M.delete_ssh_service(service_id)
    local existing = SshServices.get_ssh_service(service_id)
    local ok, err = SshServices.delete_ssh_service(service_id)
    if ok then
        logger.info("SSH service deleted", { id = tostring(service_id), config = existing })
        local permissions_model = require("models.permissions")
        permissions_model.delete_service_permissions(service_id, "ssh")
        return true
    end
    return ok, err
end

-- Toggle SSH service enabled status
function _M.toggle_ssh_service(service_id)
    local service = SshServices.get_ssh_service(service_id)
    if not service then
        return nil, "SSH service not found"
    end
    
    -- Toggle enabled status (normalize to boolean)
    local updated_data = {
        id = service.id,
        name = service.name,
        type = service.type,
        host = service.host,
        port = service.port,
        username = service.username,
        enabled = not (service.enabled == true),
        description = service.description
    }

    local updated = SshServices.update_ssh_service(service_id, updated_data)
    if updated then
        logger.info("SSH service toggled", { id = service_id, enabled = updated.enabled, config = updated })
        -- include permissions for UI consistency
        local permissions_model = require("models.permissions")
        local perms = permissions_model.get_service_permissions(service_id, "ssh") or {}
        local list = {}
        for _, p in ipairs(perms) do
            table.insert(list, { type = p.permission_type, role = p.role_name or p.role_id })
        end
        updated.permissions = list
        updated.enabled = updated.enabled == true
    end
    return updated
end



function _M.get_proxy_path(service_id)
    if not service_id then
        return nil
    end
    
    return "/ssh/" .. service_id .. "/"
end

return _M 