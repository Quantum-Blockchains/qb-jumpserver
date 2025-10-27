-- Base Model

local cjson = require "cjson"
local db = require("models.init")
local logger = require "utils.logger"

local _M = {}
_M.__index = _M

function _M.new(table_name, primary_key)
    local self = setmetatable({}, _M)
    self.table_name = table_name
    self.primary_key = primary_key or "id"
    return self
end

function _M.create(self, data)
    if not data or not data[self.primary_key] then
        return nil, "Primary key is required"
    end
    
    if not data.config_hash then
        data.config_hash = self:generate_config_hash(data)
    end
    
    local columns = {}
    local placeholders = {}
    local values = {}
    
    for key, value in pairs(data) do
        if value ~= nil then
            table.insert(columns, key)
            table.insert(placeholders, "?")
            table.insert(values, value)
        end
    end
    
    local sql = string.format(
        "INSERT INTO %s (%s) VALUES (%s)",
        self.table_name,
        table.concat(columns, ", "),
        table.concat(placeholders, ", ")
    )
    
    local success, err = db.execute(sql, values)
    if not success then
        logger.error(string.format("Failed to create %s: %s", self.table_name, err or "unknown error"))
        return nil, "Create failed: " .. (err or "unknown error")
    end
    
    return self:get(data[self.primary_key])
end

function _M.update(self, id, data)
    if not id then
        return nil, "ID is required"
    end
    
    local existing = self:get(id)
    if not existing then
        return nil, string.format("%s not found", self.table_name:gsub("_", " "):gsub("^%l", string.upper))
    end
    
    -- Generate config hash if not provided
    if not data.config_hash then
        data.config_hash = self:generate_config_hash(data)
    end
    
    local updates = {}
    local values = {}
    
    for key, value in pairs(data) do
        if key ~= self.primary_key and value ~= nil then
            table.insert(updates, string.format("%s = ?", key))
            table.insert(values, value)
        end
    end
    
    table.insert(updates, "updated_at = CURRENT_TIMESTAMP")
    table.insert(values, id)
    
    local sql = string.format(
        "UPDATE %s SET %s WHERE %s = ?",
        self.table_name,
        table.concat(updates, ", "),
        self.primary_key
    )
    
    local success, err = db.execute(sql, values)
    if not success then
        logger.error(string.format("Failed to update %s: %s", self.table_name, err or "unknown error"))
        return nil, "Update failed: " .. (err or "unknown error")
    end
    
    return self:get(id)
end

function _M.delete(self, id)
    if not id then
        return nil, "ID is required"
    end
    
    local existing = self:get(id)
    if not existing then
        return nil, string.format("%s not found", self.table_name:gsub("_", " "):gsub("^%l", string.upper))
    end
    
    local sql = string.format("DELETE FROM %s WHERE %s = ?", self.table_name, self.primary_key)
    local success, err = db.execute(sql, { id })
    
    if not success then
        logger.error(string.format("Failed to delete %s: %s", self.table_name, err or "unknown error"))
        return false, "Delete failed: " .. (err or "unknown error")
    end
    
    return true
end

function _M.get(self, id)
    if not id then
        return nil, "ID is required"
    end
    
    local sql = string.format("SELECT * FROM %s WHERE %s = ?", self.table_name, self.primary_key)
    local results, err = db.query(sql, { id })
    
    if not results or #results == 0 then
        return nil
    end
    
    return results[1]
end

function _M.get_all(self, order_by)
    order_by = order_by or string.format("%s ASC", self.primary_key)
    local sql = string.format("SELECT * FROM %s ORDER BY %s", self.table_name, order_by)
    local results, err = db.query(sql)
    
    if not results then
        return {}
    end
    
    return results
end

function _M.get_enabled(self, order_by)
    order_by = order_by or string.format("%s ASC", self.primary_key)
    local sql = string.format("SELECT * FROM %s WHERE enabled = 1 ORDER BY %s", self.table_name, order_by)
    local results, err = db.query(sql)
    
    if not results then
        return {}
    end
    
    return results
end

function _M.exists(self, id)
    if not id then
        return false
    end
    
    local sql = string.format("SELECT 1 FROM %s WHERE %s = ? LIMIT 1", self.table_name, self.primary_key)
    local results, err = db.query(sql, { id })
    
    return results and #results > 0
end

function _M.count(self, where_clause, params)
    local sql = string.format("SELECT COUNT(*) as count FROM %s", self.table_name)
    
    if where_clause then
        sql = sql .. " WHERE " .. where_clause
    end
    
    local results, err = db.query(sql, params or {})
    
    if not results or #results == 0 then
        return 0
    end
    
    return results[1].count
end

function _M.search(self, search_term, search_fields, order_by)
    if not search_term or not search_fields or #search_fields == 0 then
        return self:get_all(order_by)
    end
    
    local conditions = {}
    local params = {}
    
    for _, field in ipairs(search_fields) do
        table.insert(conditions, string.format("%s LIKE ?", field))
        table.insert(params, string.format("%%%s%%", search_term))
    end
    
    local sql = string.format(
        "SELECT * FROM %s WHERE %s ORDER BY %s",
        self.table_name,
        table.concat(conditions, " OR "),
        order_by or string.format("%s ASC", self.primary_key)
    )
    
    local results, err = db.query(sql, params)
    
    if not results then
        return {}
    end
    
    return results
end

-- Utility methods
function _M.generate_config_hash(self, data)
    local config_copy = {}
    for key, value in pairs(data) do
        if key ~= "id" and key ~= "created_at" and key ~= "updated_at" and key ~= "config_hash" then
            config_copy[key] = value
        end
    end
    
    local keys = {}
    for key in pairs(config_copy) do
        table.insert(keys, key)
    end
    table.sort(keys)
    
    local hash_string = ""
    for _, key in ipairs(keys) do
        hash_string = hash_string .. key .. ":" .. tostring(config_copy[key]) .. ";"
    end
    
    return ngx.md5(hash_string)
end

function _M.validate_required_fields(self, data, required_fields)
    local missing = {}
    for _, field in ipairs(required_fields) do
        if not data[field] or data[field] == "" then
            table.insert(missing, field)
        end
    end
    
    if #missing > 0 then
        return false, "Missing required fields: " .. table.concat(missing, ", ")
    end
    
    return true
end

function _M.validate_enum_field(self, value, allowed_values, field_name)
    if not value then
        return false, string.format("%s is required", field_name)
    end
    
    -- Check if value exists in the allowed_values array
    local found = false
    for _, allowed_value in ipairs(allowed_values) do
        if value == allowed_value then
            found = true
            break
        end
    end
    
    if not found then
        return false, string.format("%s must be one of: %s", field_name, table.concat(allowed_values, ", "))
    end
    
    return true
end

function _M.validate_numeric_range(self, value, min_val, max_val, field_name)
    local num = tonumber(value)
    if not num then
        return false, string.format("%s must be a number", field_name)
    end
    
    if min_val and num < min_val then
        return false, string.format("%s must be at least %s", field_name, min_val)
    end
    
    if max_val and num > max_val then
        return false, string.format("%s must be at most %s", field_name, max_val)
    end
    
    return true
end

function _M.sanitize_input(self, data, allowed_fields)
    local sanitized = {}
    for field, value in pairs(data) do
        if allowed_fields[field] then
            if type(value) == "string" then
                value = value:gsub("<script", "&lt;script")
                value = value:gsub("javascript:", "javascript&#58;")
            end
            sanitized[field] = value
        end
    end
    return sanitized
end

return _M
