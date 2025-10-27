-- Roles Model

local cjson = require "cjson"
local db = require("models.init")
local logger = require "utils.logger"

local _M = {}

function _M.create_role(role_data)
    local sql = [[
        INSERT INTO roles (id, name, description, permissions, enabled)
        VALUES (?, ?, ?, ?, ?)
    ]]
    
    local permissions_json = role_data.permissions
    if type(permissions_json) == "table" then
        permissions_json = cjson.encode(permissions_json)
    end
    
    local params = {
        role_data.id,
        role_data.name,
        role_data.description,
        permissions_json,
        role_data.enabled ~= false and 1 or 0
    }
    
    local success, err = db.execute(sql, params)
    if not success then
        logger.error("Failed to create role: " .. (err or "unknown error"))
        return nil
    end
    
    return _M.get_role(role_data.id)
end

function _M.update_role(role_id, role_data)
    local sql = [[
        UPDATE roles 
        SET name = ?, description = ?, permissions = ?, enabled = ?, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
    ]]
    
    local permissions_json = role_data.permissions
    if type(permissions_json) == "table" then
        permissions_json = cjson.encode(permissions_json)
    end
    
    local params = {
        role_data.name,
        role_data.description,
        permissions_json,
        role_data.enabled ~= false and 1 or 0,
        role_id
    }
    
    local success, err = db.execute(sql, params)
    if not success then
        logger.error("Failed to update role: " .. (err or "unknown error"))
        return nil
    end
    
    return _M.get_role(role_id)
end

function _M.get_role(role_id)
    local sql = "SELECT * FROM roles WHERE id = ?"
    local results = db.query(sql, {role_id})
    
    if not results or #results == 0 then
        return nil
    end
    
    local role = results[1]
    
    -- Parse permissions JSON
    if role.permissions then
        local ok, permissions = pcall(cjson.decode, role.permissions)
        if ok then
            role.permissions = permissions
        else
            role.permissions = {}
        end
    else
        role.permissions = {}
    end
    
    -- Convert enabled to boolean
    role.enabled = role.enabled == 1
    
    return role
end

-- Get a single role by name (case-insensitive)
function _M.get_role_by_name(role_name)
    local sql = "SELECT * FROM roles WHERE LOWER(name) = LOWER(?)"
    local results = db.query(sql, {role_name})
    
    if not results or #results == 0 then
        return nil
    end
    
    local role = results[1]
    
    -- Parse permissions JSON
    if role.permissions then
        local ok, permissions = pcall(cjson.decode, role.permissions)
        if ok then
            role.permissions = permissions
        else
            role.permissions = {}
        end
    else
        role.permissions = {}
    end
    
    -- Convert enabled to boolean
    role.enabled = role.enabled == 1
    
    return role
end

function _M.get_all_roles()
    local sql = "SELECT * FROM roles ORDER BY name"
    local results = db.query(sql)
    
    if not results then
        return {}
    end
    
    -- Process each role
    for _, role in ipairs(results) do
        -- Parse permissions JSON
        if role.permissions then
            local ok, permissions = pcall(cjson.decode, role.permissions)
            if ok then
                role.permissions = permissions
            else
                role.permissions = {}
            end
        else
            role.permissions = {}
        end
        
        -- Convert enabled to boolean
        role.enabled = role.enabled == 1
    end
    
    return results
end

-- Get enabled roles only
function _M.get_enabled_roles()
    local sql = "SELECT * FROM roles WHERE enabled = 1 ORDER BY name"
    local results = db.query(sql)
    
    if not results then
        return {}
    end
    
    -- Process each role
    for _, role in ipairs(results) do
        -- Parse permissions JSON
        if role.permissions then
            local ok, permissions = pcall(cjson.decode, role.permissions)
            if ok then
                role.permissions = permissions
            else
                role.permissions = {}
            end
        else
            role.permissions = {}
        end
        
        -- Convert enabled to boolean
        role.enabled = role.enabled == 1
    end
    
    return results
end

function _M.delete_role(role_id)
    -- First, delete any service permissions that reference this role
    local delete_perms_sql = "DELETE FROM service_permissions WHERE role_id = ?"
    local success, err = db.execute(delete_perms_sql, {role_id})
    if not success then
        logger.error("Failed to delete role permissions: " .. (err or "unknown error"))
        return false
    end
    
    -- Then delete the role
    local delete_role_sql = "DELETE FROM roles WHERE id = ?"
    success, err = db.execute(delete_role_sql, {role_id})
    if not success then
        logger.error("Failed to delete role: " .. (err or "unknown error"))
        return false
    end
    
    return true
end

function _M.role_exists(role_id)
    local sql = "SELECT COUNT(*) as count FROM roles WHERE id = ?"
    local results = db.query(sql, {role_id})
    
    return results and results[1] and results[1].count > 0
end

-- Get roles by permission
function _M.get_roles_with_permission(permission)
    local roles = _M.get_enabled_roles()
    local matching_roles = {}
    
    for _, role in ipairs(roles) do
        if role.permissions then
            for _, perm in ipairs(role.permissions) do
                if perm == permission then
                    table.insert(matching_roles, role)
                    break
                end
            end
        end
    end
    
    return matching_roles
end

return _M 