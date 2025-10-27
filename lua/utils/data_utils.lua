-- Data Utilities

local cjson = require "cjson"
local _M = {}

function _M.now()
    return ngx and ngx.time() or os.time()
end

function _M.log_timestamp(timestamp)
    timestamp = timestamp or (ngx and ngx.time() or os.time())
    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

function _M.create_filter_conditions(opts)
    local conditions = {}
    local params = {}
    
    if opts.since_epoch and tonumber(opts.since_epoch) then
        table.insert(conditions, "timestamp >= ?")
        table.insert(params, tonumber(opts.since_epoch))
    end
    
    if opts.until_epoch and tonumber(opts.until_epoch) then
        table.insert(conditions, "timestamp <= ?")
        table.insert(params, tonumber(opts.until_epoch))
    end
    
    return conditions, params
end

local COOKIE_NAME = "session_uid"

local function to_hex(str)
    return (str:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

local function generate_uid()
    local ok, random = pcall(require, "resty.random")
    if ok and random and random.bytes then
        local bytes = random.bytes(16, true)
        if bytes then
            return to_hex(bytes)
        end
    end
    -- Fallback: time + worker pid + randoms
    math.randomseed(math.floor(ngx.now() * 1000) + (ngx.worker and ngx.worker.pid() or 0))
    return string.format("%08x%08x%08x", ngx.time(), math.random(0, 0xffffffff), math.random(0, 0xffffffff))
end

local function build_cookie(value)
    local parts = { COOKIE_NAME .. "=" .. value, "Path=/", "SameSite=Lax" }
    if ngx.var.scheme == "https" then
        table.insert(parts, "Secure")
    end
    table.insert(parts, "HttpOnly")
    return table.concat(parts, "; ")
end

local function set_cookie(value)
    local cookie = build_cookie(value)
    local existing = ngx.header["Set-Cookie"]
    if not existing then
        ngx.header["Set-Cookie"] = { cookie }
    elseif type(existing) == "table" then
        table.insert(existing, cookie)
        ngx.header["Set-Cookie"] = existing
    else
        ngx.header["Set-Cookie"] = { existing, cookie }
    end
end

function _M.ensure_session_uid()
    local existing = ngx.var["cookie_" .. COOKIE_NAME]
    if existing and existing ~= "" then
        ngx.ctx.session_uid = existing
        return existing
    end

    if ngx.ctx.session_uid and ngx.ctx.session_uid ~= "" then
        return ngx.ctx.session_uid
    end

    local ip = ngx.var.remote_addr or ""
    local ua = ngx.var.http_user_agent or ""
    local key = string.format("session_uid:%s|%s", ip, ua)
    local dict = ngx.shared.system_data
    local uid
    if dict then
        uid = dict:get(key)
        if not uid or uid == "" then
            uid = generate_uid()
            dict:set(key, uid, 60)
        end
    else
        uid = generate_uid()
    end
    ngx.ctx.session_uid = uid
    set_cookie(uid)
    return uid
end

function _M.ensure_session_uid_for_logging()
    local existing = ngx.var["cookie_" .. COOKIE_NAME]
    if existing and existing ~= "" then
        ngx.ctx.session_uid = existing
        return existing
    end
    if ngx.ctx.session_uid and ngx.ctx.session_uid ~= "" then
        return ngx.ctx.session_uid
    end
    local ip = ngx.var.remote_addr or ""
    local ua = ngx.var.http_user_agent or ""
    local key = string.format("session_uid:%s|%s", ip, ua)
    local dict = ngx.shared.system_data
    local uid
    if dict then
        uid = dict:get(key)
        if not uid or uid == "" then
            uid = generate_uid()
            dict:set(key, uid, 60)
        end
    else
        uid = generate_uid()
    end
    ngx.ctx.session_uid = uid
    return uid
end

function _M.get_session_uid()
    return ngx.ctx.session_uid or ngx.var["cookie_" .. COOKIE_NAME]
end

function _M.session_uid_cookie_name()
    return COOKIE_NAME
end

local ValidationResult = {}
ValidationResult.__index = ValidationResult

function ValidationResult.new()
    local self = setmetatable({}, ValidationResult)
    self.is_valid = true
    self.errors = {}
    self.warnings = {}
    return self
end

function ValidationResult:add_error(field, message)
    self.is_valid = false
    if not self.errors[field] then
        self.errors[field] = {}
    end
    table.insert(self.errors[field], message)
end

function ValidationResult:add_warning(field, message)
    if not self.warnings[field] then
        self.warnings[field] = {}
    end
    table.insert(self.warnings[field], message)
end

function ValidationResult:get_errors()
    return self.errors
end

function ValidationResult:get_warnings()
    return self.warnings
end

function ValidationResult:has_errors()
    return not self.is_valid
end

function ValidationResult:get_error_summary()
    local summary = {}
    for field, errors in pairs(self.errors) do
        for _, error in ipairs(errors) do
            table.insert(summary, string.format("%s: %s", field, error))
        end
    end
    return summary
end

local function define_field(name, validators)
    return {
        name = name,
        validators = validators or {}
    }
end

local function required()
    return function(value, field_name)
        if value == nil or value == "" then
            return false, string.format("%s is required", field_name)
        end
        return true
    end
end

local function string_type()
    return function(value, field_name)
        if value ~= nil and type(value) ~= "string" then
            return false, string.format("%s must be a string", field_name)
        end
        return true
    end
end

local function number_type()
    return function(value, field_name)
        if value ~= nil and type(value) ~= "number" then
            return false, string.format("%s must be a number", field_name)
        end
        return true
    end
end

local function boolean_type()
    return function(value, field_name)
        if value ~= nil and type(value) ~= "boolean" then
            return false, string.format("%s must be a boolean", field_name)
        end
        return true
    end
end

local function min_length(min)
    return function(value, field_name)
        if value and type(value) == "string" and #value < min then
            return false, string.format("%s must be at least %d characters long", field_name, min)
        end
        return true
    end
end

local function max_length(max)
    return function(value, field_name)
        if value and type(value) == "string" and #value > max then
            return false, string.format("%s must be no more than %d characters long", field_name, max)
        end
        return true
    end
end

local function min_value(min)
    return function(value, field_name)
        if value and type(value) == "number" and value < min then
            return false, string.format("%s must be at least %s", field_name, tostring(min))
        end
        return true
    end
end

local function max_value(max)
    return function(value, field_name)
        if value and type(value) == "number" and value > max then
            return false, string.format("%s must be no more than %s", field_name, tostring(max))
        end
        return true
    end
end

local function enum(allowed_values)
    return function(value, field_name)
        if value and not allowed_values[value] then
            local values_list = {}
            for val in pairs(allowed_values) do
                table.insert(values_list, tostring(val))
            end
            return false, string.format("%s must be one of: %s", field_name, table.concat(values_list, ", "))
        end
        return true
    end
end

local function pattern(regex, description)
    return function(value, field_name)
        if value and type(value) == "string" and not value:match(regex) then
            return false, string.format("%s format is invalid: %s", field_name, description or "does not match expected pattern")
        end
        return true
    end
end

local function url()
    return function(value, field_name)
        if value and type(value) == "string" then
            if not value:match("^https?://") then
                return false, string.format("%s must be a valid URL starting with http:// or https://", field_name)
            end
        end
        return true
    end
end

local function hostname()
    return function(value, field_name)
        if value and type(value) == "string" then
            if not value:match("^[%w%-%.]+$") then
                return false, string.format("%s must be a valid hostname", field_name)
            end
        end
        return true
    end
end

local function port()
    return function(value, field_name)
        if value then
            local num = tonumber(value)
            if not num or num < 1 or num > 65535 then
                return false, string.format("%s must be a valid port number (1-65535)", field_name)
            end
        end
        return true
    end
end

local function username()
    return function(value, field_name)
        if value and type(value) == "string" then
            if not value:match("^[%w%-_]+$") then
                return false, string.format("%s contains invalid characters (only letters, numbers, hyphens, and underscores allowed)", field_name)
            end
        end
        return true
    end
end

local function email()
    return function(value, field_name)
        if value and type(value) == "string" then
            if not value:match("^[%w%.%-]+@[%w%.%-]+%.[%w%.%-]+$") then
                return false, string.format("%s must be a valid email address", field_name)
            end
        end
        return true
    end
end

local function xss_safe()
    return function(value, field_name)
        if value and type(value) == "string" then
            if value:find("<script") or value:find("javascript:") then
                return false, string.format("%s contains potentially dangerous content", field_name)
            end
        end
        return true
    end
end

_M.schemas = {
    http_service = {
        id = define_field("id", {required(), string_type(), min_length(1), max_length(100), xss_safe()}),
        name = define_field("name", {required(), string_type(), min_length(1), max_length(200), xss_safe()}),
        type = define_field("type", {string_type(), enum({http = true, https = true})}),
        host = define_field("host", {required(), string_type(), hostname()}),
        port = define_field("port", {required(), number_type(), min_value(1), max_value(65535)}),
        protocol = define_field("protocol", {string_type(), enum({http = true, https = true})}),
        url = define_field("url", {string_type(), url()}),
        path = define_field("path", {string_type(), pattern("^/.*", "must start with /")}),
        enabled = define_field("enabled", {boolean_type()}),
        description = define_field("description", {string_type(), max_length(1000), xss_safe()}),
        source = define_field("source", {string_type(), enum({database = true, file = true, api = true})})
    },
    
    ssh_service = {
        id = define_field("id", {required(), string_type(), min_length(1), max_length(100), xss_safe()}),
        name = define_field("name", {required(), string_type(), min_length(1), max_length(200), xss_safe()}),
        type = define_field("type", {string_type(), enum({ssh = true})}),
        host = define_field("host", {required(), string_type(), hostname()}),
        port = define_field("port", {required(), number_type(), min_value(1), max_value(65535)}),
        username = define_field("username", {string_type(), username()}),
        enabled = define_field("enabled", {boolean_type()}),
        description = define_field("description", {string_type(), max_length(1000), xss_safe()}),
        source = define_field("source", {string_type(), enum({database = true, file = true, api = true})})
    },
    
    user_profile = {
        name = define_field("name", {string_type(), min_length(1), max_length(200), xss_safe()}),
        email = define_field("email", {string_type(), email()}),
        preferences = define_field("preferences", {})
    }
}

-- Main validation function
function _M.validate(data, schema_name)
    local schema = _M.schemas[schema_name]
    if not schema then
        error("Unknown schema: " .. tostring(schema_name))
    end
    
    local result = ValidationResult.new()
    
    for field_name, field_def in pairs(schema) do
        local value = data[field_name]
        
        -- Run all validators for this field
        for _, validator in ipairs(field_def.validators) do
            local valid, message = validator(value, field_def.name)
            if not valid then
                result:add_error(field_name, message)
                break -- Stop validating this field after first error
            end
        end
    end
    
    return result
end

function _M.validate_http_service(data)
    return _M.validate(data, "http_service")
end

function _M.validate_ssh_service(data)
    return _M.validate(data, "ssh_service")
end

function _M.validate_user_profile(data)
    return _M.validate(data, "user_profile")
end

function _M.is_valid_email(email)
    if not email or type(email) ~= "string" then
        return false
    end
    return email:match("^[%w%.%-]+@[%w%.%-]+%.[%w%.%-]+$") ~= nil
end

function _M.is_valid_hostname(hostname)
    if not hostname or type(hostname) ~= "string" then
        return false
    end
    return hostname:match("^[%w%-%.]+$") ~= nil
end

function _M.is_valid_port(port)
    if not port then
        return false
    end
    local num = tonumber(port)
    return num and num >= 1 and num <= 65535
end

function _M.is_valid_url(url)
    if not url or type(url) ~= "string" then
        return false
    end
    return url:match("^https?://") ~= nil
end

function _M.sanitize_string(str, max_length)
    if not str or type(str) ~= "string" then
        return str
    end
    
    str = str:gsub("<script", "&lt;script")
    str = str:gsub("javascript:", "javascript&#58;")
    
    if max_length and #str > max_length then
        str = str:sub(1, max_length)
    end
    
    return str
end

return _M
