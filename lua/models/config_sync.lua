-- Configuration Module

local cjson = require "cjson"
local db = require("models.init")
local permissions_model = require "models.permissions"

local _M = {}

function _M.generate_system_config_hash()
    local hash_data = {
        permissions = {},
        roles = {},
        services = {},
        timestamp = ngx.time()
    }
    
    local all_permissions = permissions_model.get_all_service_permissions() or {}
    for _, perm in ipairs(all_permissions) do
        table.insert(hash_data.permissions, {
            service_id = perm.service_id,
            service_type = perm.service_type,
            role_id = perm.role_id,
            group_name = perm.group_name,
            permission_type = perm.permission_type,
            updated_at = perm.updated_at
        })
    end
    
    local http_services_model = require "models.http_services"
    local http_services = http_services_model.get_all_http_services() or {}
    for _, service in ipairs(http_services) do
        table.insert(hash_data.services, {
            id = service.id,
            name = service.name,
            enabled = service.enabled,
            config_hash = service.config_hash,
            updated_at = service.updated_at
        })
    end
    
    local ssh_services_model = require "models.ssh_services"
    local ssh_services = ssh_services_model.get_all_ssh_services() or {}
    for _, service in ipairs(ssh_services) do
        table.insert(hash_data.services, {
            id = service.id,
            name = service.name,
            enabled = service.enabled,
            config_hash = service.config_hash,
            updated_at = service.updated_at
        })
    end
    
    local json_string = cjson.encode(hash_data)
    return ngx.md5(json_string)
end

function _M.generate_user_config_hash(user)
    if not user then
        return nil
    end
    
    local hash_data = {
        user_id = user.user_id,
        roles = user.roles or {},
        groups = user.groups or {},
        timestamp = ngx.time()
    }
    
    local json_string = cjson.encode(hash_data)
    return ngx.md5(json_string)
end

function _M.should_refresh_user_config(session, user)
    if not session or not user then
        return false
    end
    
    local current_hash = _M.generate_user_config_hash(user)
    local stored_hash = session.data.user_config_hash
    local last_refresh = session.data.user_config_last_refresh or 0
    
    -- Refresh if no hash exists or if it's been more than 1 hour
    if not stored_hash or stored_hash ~= current_hash then
        return true
    end
    
    -- Refresh every hour
    if ngx.time() - last_refresh > 3600 then
        return true
    end
    
    return false
end

function _M.force_refresh_user_config(session, user)
    if not session or not user then
        return false
    end
    
    local current_hash = _M.generate_user_config_hash(user)
    session.data.user_config_hash = current_hash
    session.data.user_config_last_refresh = ngx.time()
    session:save()
    
    return true
end

function _M.get_config_details()
    return {
        system_hash = _M.generate_system_config_hash(),
        timestamp = ngx.time(),
        sync_enabled = false
    }
end

function _M.force_refresh_all_configs()
    return {
        system = true,
        timestamp = ngx.time()
    }
end

function _M.monitor_config_changes()
    return {
        system_changes = false,
        timestamp = ngx.time()
    }
end

function _M.get_config_health_status()
    return {
        healthy = true,
        timestamp = ngx.time(),
        details = {
            system_hash = _M.generate_system_config_hash(),
            sync_enabled = false
        }
    }
end

return _M