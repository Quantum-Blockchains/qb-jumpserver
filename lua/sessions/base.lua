-- Session Base Class

local cjson = require "cjson"
local data_utils = require("utils.data_utils")
local logger = require "utils.logger"

local _M = {}
_M.__index = _M

_M.SESSION_TYPES = {
    AUTH = "auth",
    HTTP_PROXY = "http_proxy", 
    SSH_PROXY = "ssh_proxy"
}

_M.SESSION_STATES = {
    CREATING = "creating",
    ACTIVE = "active",
    EXPIRED = "expired",
    DESTROYED = "destroyed",
    ERROR = "error"
}

function _M.new(session_type, user_id, metadata)
    if not session_type or not _M.SESSION_TYPES[session_type:upper()] then
        error("Invalid session type: " .. tostring(session_type))
    end
    
    if not user_id then
        error("User ID is required")
    end
    
    local self = setmetatable({}, _M)
    
    self.session_type = session_type
    self.user_id = user_id
    self.metadata = metadata or {}
    self.session_id = self:_generate_session_id()
    
    self.state = _M.SESSION_STATES.CREATING
    self.created_at = ngx.time()
    self.last_activity = ngx.time()
    self.expires_at = nil
    
    self.data = {}
    
    self.on_create = nil
    self.on_destroy = nil
    self.on_expire = nil
    self.on_error = nil
    
    return self
end

function _M:_generate_session_id()
    local timestamp = ngx.time()
    local random = math.random(100000, 999999)
    return string.format("%s_%s_%d_%d", self.session_type, self.user_id, timestamp, random)
end

function _M:create()
    error("create() method must be implemented by subclass")
end

function _M:destroy()
    error("destroy() method must be implemented by subclass")
end

function _M:validate()
    error("validate() method must be implemented by subclass")
end

function _M:refresh()
    error("refresh() method must be implemented by subclass")
end

function _M:update_activity()
    self.last_activity = ngx.time()
    self:_log_activity("activity_updated")
end

function _M:is_active()
    return self.state == _M.SESSION_STATES.ACTIVE
end

function _M:is_expired()
    if not self.expires_at then
        return false
    end
    return ngx.time() > self.expires_at
end

function _M:get_age()
    return ngx.time() - self.created_at
end

function _M:get_idle_time()
    return ngx.time() - self.last_activity
end

function _M:set_data(key, value)
    self.data[key] = value
    self:_log_activity("data_updated", { key = key })
end

function _M:get_data(key)
    return self.data[key]
end

function _M:set_callbacks(callbacks)
    if callbacks.on_create then
        self.on_create = callbacks.on_create
    end
    if callbacks.on_destroy then
        self.on_destroy = callbacks.on_destroy
    end
    if callbacks.on_expire then
        self.on_expire = callbacks.on_expire
    end
    if callbacks.on_error then
        self.on_error = callbacks.on_error
    end
end

function _M:_execute_callback(callback_name, ...)
    local callback = self[callback_name]
    if callback and type(callback) == "function" then
        local ok, err = pcall(callback, self, ...)
        if not ok then
            logger.error("Session callback error:", tostring(err))
        end
    end
end

function _M:_log_activity(action, extra_data)
    local log_data = {
        session_id = self.session_id,
        session_type = self.session_type,
        user_id = self.user_id,
        action = action,
        timestamp = ngx and ngx.time() or os.time(),
        state = self.state
    }
    
    if extra_data then
        for k, v in pairs(extra_data) do
            log_data[k] = v
        end
    end
    
    if action == "state_changed" then
        local old_state = extra_data and extra_data.old_state or "unknown"
        local new_state = extra_data and extra_data.new_state or "unknown"
        local service_info = self:_get_service_info()
        logger.info(string.format("Session %s: %s -> %s (user: %s%s)", 
            self.session_type, old_state, new_state, self.user_id, service_info))
    elseif action == "error" then
        local error_msg = extra_data and extra_data.error or "unknown error"
        local service_info = self:_get_service_info()
        logger.error(string.format("Session %s error: %s (user: %s%s)", 
            self.session_type, error_msg, self.user_id, service_info))
    elseif action == "created" or action == "destroyed" then
        local service_info = self:_get_service_info()
        logger.info(string.format("Session %s %s (user: %s%s)", 
            self.session_type, action, self.user_id, service_info))
    else
        local service_info = self:_get_service_info()
        logger.debug(string.format("Session %s: %s (user: %s%s)", 
            self.session_type, action, self.user_id, service_info))
    end
    
    self:_write_session_log(action, log_data)
    
    self:_write_session_db_log(action, log_data)
end

function _M:_get_service_info()
    if not self.service_id then
        return ""
    end
    
    local info = ", service: " .. self.service_id
    
    -- Add service-specific details
    if self.service_config then
        if self.service_config.host and self.service_config.port then
            info = info .. " (" .. self.service_config.host .. ":" .. self.service_config.port .. ")"
        elseif self.service_config.name then
            info = info .. " (" .. self.service_config.name .. ")"
        end
    end
    
    return info
end

function _M:_write_session_log(action, log_data)
    local log_file = string.format("/app/logs/%s-session.log", self.session_type)
    local timestamp = data_utils.log_timestamp()
    local log_entry = string.format("[%s] %s: %s\n", timestamp, action:upper(), cjson.encode(log_data))
    
    local file = io.open(log_file, "a")
    if file then
        file:write(log_entry)
        file:close()
    end
end

function _M:_write_session_db_log(action, log_data)
    local db_log_file = "/app/logs/session-db.log"
    local timestamp = data_utils.log_timestamp()
    local log_entry = string.format("[%s] DB_LOG: %s: %s\n", timestamp, action:upper(), cjson.encode(log_data))
    
    local file = io.open(db_log_file, "a")
    if file then
        file:write(log_entry)
        file:close()
    end
end

function _M:get_info()
    return {
        session_id = self.session_id,
        session_type = self.session_type,
        user_id = self.user_id,
        state = self.state,
        created_at = self.created_at,
        last_activity = self.last_activity,
        expires_at = self.expires_at,
        age = self:get_age(),
        idle_time = self:get_idle_time(),
        metadata = self.metadata,
        data_keys = self:_get_data_keys()
    }
end

function _M:_get_data_keys()
    local keys = {}
    for key, _ in pairs(self.data) do
        table.insert(keys, key)
    end
    return keys
end

function _M:serialize()
    return {
        session_id = self.session_id,
        session_type = self.session_type,
        user_id = self.user_id,
        state = self.state,
        created_at = self.created_at,
        last_activity = self.last_activity,
        expires_at = self.expires_at,
        metadata = self.metadata,
        data = self.data
    }
end

function _M:deserialize(data)
    if not data or not data.session_id then
        return false, "Invalid session data"
    end
    
    self.session_id = data.session_id
    self.session_type = data.session_type
    self.user_id = data.user_id
    self.state = data.state
    self.created_at = data.created_at
    self.last_activity = data.last_activity
    self.expires_at = data.expires_at
    self.metadata = data.metadata or {}
    self.data = data.data or {}
    
    return true
end

function _M:set_state(new_state)
    local old_state = self.state
    self.state = new_state
    
    self:_log_activity("state_changed", { 
        old_state = old_state, 
        new_state = new_state 
    })
    
    if new_state == _M.SESSION_STATES.ACTIVE then
        self:_execute_callback("on_create")
    elseif new_state == _M.SESSION_STATES.DESTROYED then
        self:_execute_callback("on_destroy")
    elseif new_state == _M.SESSION_STATES.EXPIRED then
        self:_execute_callback("on_expire")
    elseif new_state == _M.SESSION_STATES.ERROR then
        self:_execute_callback("on_error")
    end
end

function _M:handle_error(error_msg)
    self:set_state(_M.SESSION_STATES.ERROR)
    self:_log_activity("error", { error = error_msg })
    logger.error("Session error:", tostring(error_msg))
end

return _M 