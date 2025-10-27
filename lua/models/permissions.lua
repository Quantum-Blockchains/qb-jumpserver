-- Permissions Model

local cjson = require "cjson"
local db = require("models.init")
local logger = require "utils.logger"

local _M = {}

_M.PERMISSION_TYPES = {
    ALLOW = "allow",
    DENY = "deny"
}

function _M.create_service_permission(permission_data)
    if not permission_data.service_id then
        logger.error("create_service_permission: service_id is required")
        return nil
    end
    
    local permission_type = permission_data.permission_type
    if not permission_type then
        permission_type = "allow"
    end
    
    if permission_type ~= "allow" and permission_type ~= "deny" then
        logger.error("Invalid permission type: " .. tostring(permission_type) .. " (only 'allow' and 'deny' supported)")
        return nil
    end
    
    local service_id = permission_data.service_id
    local service_type = permission_data.service_type or "http"
    local role_id = permission_data.role_id
    local group_name = permission_data.group_name
    
    if not role_id and not group_name then
        logger.error("create_service_permission: either role_id or group_name must be provided")
        return nil
    end
    
    local check_sql, check_params
    if role_id then
        check_sql = "SELECT COUNT(*) as count FROM service_permissions WHERE service_id = ? AND service_type = ? AND role_id = ? AND permission_type = ?"
        check_params = {service_id, service_type, role_id, permission_type}
    else
        check_sql = "SELECT COUNT(*) as count FROM service_permissions WHERE service_id = ? AND service_type = ? AND group_name = ? AND permission_type = ?"
        check_params = {service_id, service_type, group_name, permission_type}
    end
    local check_results = db.query(check_sql, check_params)
    if check_results and check_results[1] and check_results[1].count > 0 then
        logger.debug("Permission already exists for service " .. service_id .. " (role: " .. (role_id or "none") .. ")")
        return check_results[1].count
    end
    
    local sql, params
    if role_id then
        sql = [[
            INSERT INTO service_permissions 
            (service_id, service_type, role_id, permission_type) 
            VALUES (?, ?, ?, ?)
        ]]
        params = {service_id, service_type, role_id, permission_type}
    else
        sql = [[
            INSERT INTO service_permissions 
            (service_id, service_type, group_name, permission_type) 
            VALUES (?, ?, ?, ?)
        ]]
        params = {service_id, service_type, group_name, permission_type}
    end
    
    local success, err = db.execute(sql, params)
    if not success then
        logger.error("Failed to create service permission for " .. service_id .. ": " .. (err or "unknown error"))
        return nil
    end
    
    local rowid = db.last_insert_rowid()
    logger.debug("Created permission for service " .. service_id .. " (role: " .. (role_id or "none") .. ") with ID: " .. tostring(rowid))
    
    return rowid
end

function _M.get_service_permissions(service_id, service_type)
    local sql = [[
        SELECT sp.*
        FROM service_permissions sp
        WHERE sp.service_id = ? AND sp.service_type = ?
        ORDER BY 
            CASE sp.permission_type 
                WHEN 'deny' THEN 1
                WHEN 'allow' THEN 2
            END,
            sp.role_id, sp.group_name
    ]]
    
    local results = db.query(sql, {service_id, service_type or "http"})
    return results or {}
end

function _M.get_all_service_permissions()
    local sql = [[
        SELECT sp.*
        FROM service_permissions sp
        ORDER BY sp.service_id, 
            CASE sp.permission_type 
                WHEN 'deny' THEN 1
                WHEN 'allow' THEN 2
            END,
            sp.role_id, sp.group_name
    ]]
    
    local results = db.query(sql)
    return results or {}
end

function _M.delete_service_permission(permission_id)
    local sql = "DELETE FROM service_permissions WHERE id = ?"
    
    local success, err = db.execute(sql, {permission_id})
    if not success then
        logger.error("Failed to delete service permission: " .. (err or "unknown error"))
        return false
    end
    
    return true
end

function _M.delete_service_permissions(service_id, service_type)
    local sql = "DELETE FROM service_permissions WHERE service_id = ? AND service_type = ?"
    
    local success, err = db.execute(sql, {service_id, service_type or "http"})
    if not success then
        logger.error("Failed to delete service permissions: " .. (err or "unknown error"))
        return false
    end
    
    return true
end

function _M.grant_role_access(service_id, service_type, role_id)
    return _M.create_service_permission({
        service_id = service_id,
        service_type = service_type,
        role_id = role_id,
        permission_type = "allow"
    })
end

function _M.deny_role_access(service_id, service_type, role_id)
    return _M.create_service_permission({
        service_id = service_id,
        service_type = service_type,
        role_id = role_id,
        permission_type = "deny"
    })
end

function _M.grant_group_access(service_id, service_type, group_name)
    return _M.create_service_permission({
        service_id = service_id,
        service_type = service_type,
        group_name = group_name,
        permission_type = "allow"
    })
end

function _M.deny_group_access(service_id, service_type, group_name)
    return _M.create_service_permission({
        service_id = service_id,
        service_type = service_type,
        group_name = group_name,
        permission_type = "deny"
    })
end

function _M.check_role_access(service_id, service_type, role_id)
    local sql = [[
        SELECT permission_type FROM service_permissions 
        WHERE service_id = ? AND service_type = ? AND role_id = ?
        ORDER BY 
            CASE permission_type 
                WHEN 'deny' THEN 1
                WHEN 'allow' THEN 2
            END
        LIMIT 1
    ]]
    
    local results = db.query(sql, {service_id, service_type or "http", role_id})
    if results and results[1] then
        local permission_type = results[1].permission_type
        if permission_type == "deny" then
            return false
        elseif permission_type == "allow" then
            return true
        end
    end
    
    return false  -- Default deny
end

function _M.check_group_access(service_id, service_type, group_name)
    local sql = [[
        SELECT permission_type FROM service_permissions 
        WHERE service_id = ? AND service_type = ? AND group_name = ?
        ORDER BY 
            CASE permission_type 
                WHEN 'deny' THEN 1
                WHEN 'allow' THEN 2
            END
        LIMIT 1
    ]]
    
    local results = db.query(sql, {service_id, service_type or "http", group_name})
    if results and results[1] then
        local permission_type = results[1].permission_type
        if permission_type == "deny" then
            return false
        elseif permission_type == "allow" then
            return true
        end
    end
    
    return false  -- Default deny
end

function _M.get_role_accessible_services(role_id, service_type)
    local sql = [[
        SELECT DISTINCT service_id FROM service_permissions 
        WHERE role_id = ? AND service_type = ? AND permission_type = 'allow'
        AND service_id NOT IN (
            SELECT service_id FROM service_permissions 
            WHERE role_id = ? AND service_type = ? AND permission_type = 'deny'
        )
    ]]
    
    local results = db.query(sql, {role_id, service_type or "http", role_id, service_type or "http"})
    
    local services = {}
    if results then
        for _, row in ipairs(results) do
            table.insert(services, row.service_id)
        end
    end
    
    return services
end

function _M.get_group_accessible_services(group_name, service_type)
    local sql = [[
        SELECT DISTINCT service_id FROM service_permissions 
        WHERE group_name = ? AND service_type = ? AND permission_type = 'allow'
        AND service_id NOT IN (
            SELECT service_id FROM service_permissions 
            WHERE group_name = ? AND service_type = ? AND permission_type = 'deny'
        )
    ]]
    
    local results = db.query(sql, {group_name, service_type or "http", group_name, service_type or "http"})
    
    local services = {}
    if results then
        for _, row in ipairs(results) do
            table.insert(services, row.service_id)
        end
    end
    
    return services
end

function _M.get_user_service_override(user_id, service_id, service_type)
    local sql = [[
        SELECT * FROM user_role_overrides 
        WHERE user_id = ? AND service_id = ? AND service_type = ?
    ]]
    
    local results = db.query(sql, {user_id, service_id, service_type or "http"})
    return results and results[1] or nil
end

function _M.get_user_overrides(user_id)
    local sql = [[
        SELECT * FROM user_role_overrides 
        WHERE user_id = ?
        ORDER BY service_id, service_type
    ]]
    
    local results = db.query(sql, {user_id})
    return results or {}
end

function _M.create_user_override(override_data)
    local sql = [[
        INSERT INTO user_role_overrides (user_id, service_id, service_type, permission_type)
        VALUES (?, ?, ?, ?)
    ]]
    
    local params = {
        override_data.user_id,
        override_data.service_id,
        override_data.service_type or "http",
        override_data.permission_type or "allow"
    }
    
    local success, err = db.execute(sql, params)
    if not success then
        logger.error("Failed to create user override: " .. (err or "unknown error"))
        return nil
    end
    
    return db.last_insert_rowid()
end

function _M.delete_user_override(user_id, service_id, service_type)
    local sql = [[
        DELETE FROM user_role_overrides 
        WHERE user_id = ? AND service_id = ? AND service_type = ?
    ]]
    
    local success, err = db.execute(sql, {user_id, service_id, service_type or "http"})
    if not success then
        logger.error("Failed to delete user override: " .. (err or "unknown error"))
        return false
    end
    
    return true
end



return _M 