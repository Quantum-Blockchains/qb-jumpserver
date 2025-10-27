-- Session Manager

local cjson = require "cjson"
local data_utils = require("utils.data_utils")
local SessionBase = require "sessions.base"
local SessionTypes = require "sessions.session_types"
local config_manager = require "config.manager"
local logger = require "utils.logger"

local _M = {}

local SessionManager = {}
SessionManager.__index = SessionManager

function SessionManager.new()
    local self = setmetatable({}, SessionManager)
    
    -- Session storage (shared memory)
    self.sessions = ngx.shared.sessions
    
    -- Session type mappings
    self.session_classes = {
        auth = SessionTypes.AuthSession,
        http_proxy = SessionTypes.HttpProxySession,
        ssh_proxy = SessionTypes.SshProxySession
    }
    
    -- Callbacks
    self.on_session_created = nil
    self.on_session_destroyed = nil
    self.on_session_expired = nil
    self.on_session_error = nil
    
    return self
end

function SessionManager.init()
    logger.info("Initializing session manager")
    
    -- Validate shared memory is available
    if not ngx.shared.sessions then
        logger.error("Shared memory 'sessions' not available")
        return false
    end
    
    logger.info("Session manager initialized successfully")
    return true
end

function SessionManager:create_session(session_type, user_id, service_id, service_config, metadata)
    local session_class = self.session_classes[session_type]
    if not session_class then
        logger.error("Unknown session type: " .. tostring(session_type))
        return nil, "Unknown session type"
    end
    
    local session = session_class.new(user_id, service_id, service_config, metadata)
    if not session then
        logger.error("Failed to create session instance")
        return nil, "Failed to create session instance"
    end
    
    -- Create the session
    local success, err = session:create()
    if not success then
        logger.error("Failed to create session: " .. (err or "unknown error"))
        return nil, err
    end
    
    -- Store session in shared memory
    local session_data = session:serialize()
    local stored = self.sessions:set(session.session_id, cjson.encode(session_data), 3600)
    if not stored then
        logger.error("Failed to store session in shared memory")
        session:destroy()
        return nil, "Failed to store session"
    end
    
    -- Trigger callback
    if self.on_session_created then
        self.on_session_created(session)
    end
    
    logger.info("Session created: " .. session.session_id .. " (type: " .. session_type .. ", user: " .. user_id .. ")")
    return session
end

function SessionManager:get_session(session_id)
    if not session_id then
        return nil
    end
    
    local session_data = self.sessions:get(session_id)
    if not session_data then
        return nil
    end
    
    local ok, data = pcall(cjson.decode, session_data)
    if not ok then
        logger.error("Failed to decode session data for: " .. session_id)
        return nil
    end
    
    local session_class = self.session_classes[data.session_type]
    if not session_class then
        logger.error("Unknown session type in stored data: " .. tostring(data.session_type))
        return nil
    end
    
    local session = session_class.new(data.user_id, data.service_id, data.service_config, data.metadata)
    if not session then
        return nil
    end
    
    local success, err = session:deserialize(data)
    if not success then
        logger.error("Failed to deserialize session: " .. (err or "unknown error"))
        return nil
    end
    
    return session
end

function SessionManager:get_sessions_by_user(user_id)
    local sessions = {}
    
    for _, session_id in ipairs(self.sessions:get_keys()) do
        local session = self:get_session(session_id)
        if session and session.user_id == user_id then
            table.insert(sessions, session)
        end
    end
    
    return sessions
end

function SessionManager:get_sessions_by_type(session_type)
    local sessions = {}
    
    for _, session_id in ipairs(self.sessions:get_keys()) do
        local session = self:get_session(session_id)
        if session and session.session_type == session_type then
            table.insert(sessions, session)
        end
    end
    
    return sessions
end

function SessionManager:get_all_sessions()
    local sessions = {}
    
    for _, session_id in ipairs(self.sessions:get_keys()) do
        local session = self:get_session(session_id)
        if session then
            table.insert(sessions, session)
        end
    end
    
    return sessions
end

function SessionManager:update_session(session)
    if not session or not session.session_id then
        return false, "Invalid session"
    end
    
    local session_data = session:serialize()
    local stored = self.sessions:set(session.session_id, cjson.encode(session_data), 3600)
    if not stored then
        logger.error("Failed to update session in shared memory: " .. session.session_id)
        return false, "Failed to update session"
    end
    
    return true
end

function SessionManager:destroy_session(session_id)
    local session = self:get_session(session_id)
    if not session then
        return false, "Session not found"
    end
    
    -- Destroy the session
    local success, err = session:destroy()
    if not success then
        logger.error("Failed to destroy session: " .. (err or "unknown error"))
        return false, err
    end
    
    -- Remove from shared memory
    self.sessions:delete(session_id)
    
    -- Trigger callback
    if self.on_session_destroyed then
        self.on_session_destroyed(session)
    end
    
    logger.info("Session destroyed: " .. session_id)
    return true
end

function SessionManager:cleanup_expired_sessions()
    local expired_count = 0
    
    for _, session_id in ipairs(self.sessions:get_keys()) do
        local session = self:get_session(session_id)
        if session then
            local valid, err = session:validate()
            if not valid then
                logger.info("Cleaning up expired session: " .. session_id .. " (" .. (err or "unknown reason") .. ")")
                self:destroy_session(session_id)
                expired_count = expired_count + 1
            end
        end
    end
    
    if expired_count > 0 then
        logger.info("Cleaned up " .. expired_count .. " expired sessions")
    end
    
    return expired_count
end

function SessionManager:set_callbacks(callbacks)
    self.on_session_created = callbacks.on_session_created
    self.on_session_destroyed = callbacks.on_session_destroyed
    self.on_session_expired = callbacks.on_session_expired
    self.on_session_error = callbacks.on_session_error
end

function SessionManager:get_statistics()
    local stats = {
        total_sessions = 0,
        sessions_by_type = {},
        sessions_by_user = {},
        expired_sessions = 0
    }
    
    for _, session_id in ipairs(self.sessions:get_keys()) do
        local session = self:get_session(session_id)
        if session then
            stats.total_sessions = stats.total_sessions + 1
            
            -- Count by type
            stats.sessions_by_type[session.session_type] = (stats.sessions_by_type[session.session_type] or 0) + 1
            
            -- Count by user
            stats.sessions_by_user[session.user_id] = (stats.sessions_by_user[session.user_id] or 0) + 1
            
            -- Check if expired
            if session:is_expired() then
                stats.expired_sessions = stats.expired_sessions + 1
            end
        end
    end
    
    return stats
end

local SessionMonitor = {}
SessionMonitor.__index = SessionMonitor

function SessionMonitor.new()
    local self = setmetatable({}, SessionMonitor)
    
    -- Monitoring configuration
    local session_config = config_manager.get_session_config()
    self.config = {
        alert_thresholds = {
            max_sessions_per_user = session_config.max_per_user,
            max_idle_time = session_config.max_idle_time, -- 2 hours
            -- Use SESSION_LIFETIME if set (>0); otherwise disable old_session alert
            max_session_age = session_config.lifetime,
            high_error_rate = session_config.error_rate_threshold -- 10%
        },
        monitoring_interval = session_config.monitor_interval, -- 1 minute
        log_retention_days = session_config.log_retention_days
    }
    
    -- Monitoring data
    self.metrics = {
        session_creations = 0,
        session_destructions = 0,
        session_errors = 0,
        total_requests = 0,
        total_bytes_transferred = 0,
        alerts_generated = 0
    }
    
    -- Alert history
    self.alerts = {}
    
    -- Performance tracking
    self.performance_data = {
        response_times = {},
        error_rates = {},
        session_lifetimes = {}
    }
    
    return self
end

function SessionMonitor.init()
    logger.info("Initializing session monitor")
    
    -- Set up session manager callbacks
    local manager = SessionManager.get_instance()
    manager:set_callbacks({
        on_session_created = function(session) SessionMonitor.get_instance():_handle_session_created(session) end,
        on_session_destroyed = function(session) SessionMonitor.get_instance():_handle_session_destroyed(session) end,
        on_session_expired = function(session) SessionMonitor.get_instance():_handle_session_expired(session) end,
        on_session_error = function(session) SessionMonitor.get_instance():_handle_session_error(session) end
    })
    
    logger.info("Session monitor initialized successfully")
    return true
end

function SessionMonitor:_handle_session_created(session)
    self.metrics.session_creations = self.metrics.session_creations + 1
    
    -- Track session creation performance
    self:_track_session_lifetime(session)
    
    -- Check for alerts
    self:_check_session_limits(session)
    
    -- Log session creation
    self:_log_session_event("created", session)
end

function SessionMonitor:_handle_session_destroyed(session)
    self.metrics.session_destructions = self.metrics.session_destructions + 1
    
    -- Log session destruction
    self:_log_session_event("destroyed", session)
end

function SessionMonitor:_handle_session_expired(session)
    -- Log session expiration
    self:_log_session_event("expired", session)
end

function SessionMonitor:_handle_session_error(session)
    self.metrics.session_errors = self.metrics.session_errors + 1
    
    -- Generate error alert
    self:_generate_alert("session_error", {
        session_id = session.session_id,
        user_id = session.user_id,
        session_type = session.session_type,
        error = session:get_data("last_error")
    })
    
    -- Log session error
    self:_log_session_event("error", session)
end

-- Check session limits and generate alerts
function SessionMonitor:_check_session_limits(session)
    local manager = SessionManager.get_instance()
    local user_sessions = manager:get_sessions_by_user(session.user_id)
    
    -- Check max sessions per user
    if #user_sessions > self.config.alert_thresholds.max_sessions_per_user then
        self:_generate_alert("max_sessions_per_user", {
            user_id = session.user_id,
            session_count = #user_sessions,
            threshold = self.config.alert_thresholds.max_sessions_per_user
        })
    end
    
    -- Check idle time
    local idle_time = session:get_idle_time()
    if idle_time > self.config.alert_thresholds.max_idle_time then
        self:_generate_alert("high_idle_time", {
            session_id = session.session_id,
            user_id = session.user_id,
            idle_time = idle_time,
            threshold = self.config.alert_thresholds.max_idle_time
        })
    end
    
    -- Check session age
    local age = session:get_age()
    if age > self.config.alert_thresholds.max_session_age then
        self:_generate_alert("old_session", {
            session_id = session.session_id,
            user_id = session.user_id,
            age = age,
            threshold = self.config.alert_thresholds.max_session_age
        })
    end
end

function SessionMonitor:_generate_alert(alert_type, data)
    local alert = {
        id = self:_generate_alert_id(),
        type = alert_type,
        timestamp = ngx and ngx.time() or os.time(),
        data = data,
        severity = self:_get_alert_severity(alert_type)
    }
    
    table.insert(self.alerts, alert)
    self.metrics.alerts_generated = self.metrics.alerts_generated + 1
    
    -- Keep only last 1000 alerts
    if #self.alerts > 1000 then
        table.remove(self.alerts, 1)
    end
    
    -- Log alert
    logger.warn("Session alert:", cjson.encode(alert))
    
    return alert
end

function SessionMonitor:_get_alert_severity(alert_type)
    local severities = {
        session_error = "high",
        max_sessions_per_user = "medium",
        high_idle_time = "low",
        old_session = "low"
    }
    
    return severities[alert_type] or "medium"
end

function SessionMonitor:_generate_alert_id()
    return "alert_" .. ngx.time() .. "_" .. math.random(1000, 9999)
end

function SessionMonitor:_track_session_lifetime(session)
    table.insert(self.performance_data.session_lifetimes, {
        session_id = session.session_id,
        session_type = session.session_type,
        created_at = session.created_at
    })
    
    -- Keep only last 1000 entries
    if #self.performance_data.session_lifetimes > 1000 then
        table.remove(self.performance_data.session_lifetimes, 1)
    end
end

function SessionMonitor:_log_session_event(event_type, session)
    local log_entry = {
        timestamp = ngx and ngx.time() or os.time(),
        event_type = event_type,
        session_id = session.session_id,
        session_type = session.session_type,
        user_id = session.user_id,
        state = session.state
    }
    
    -- Add session-specific data
    if session.session_type == "http_proxy" then
        log_entry.request_count = session.request_count
        log_entry.bytes_transferred = session.bytes_transferred
    elseif session.session_type == "ssh_proxy" then
        log_entry.socket_path = session.socket_path
        log_entry.ttyd_pid = session.ttyd_pid
    end
    
    -- Write to session-specific monitor log
    local log_file = string.format("/app/logs/%s-monitor.log", session.session_type)
    local timestamp = data_utils.log_timestamp()
    local log_line = string.format("[%s] MONITOR: %s: %s\n", timestamp, event_type:upper(), cjson.encode(log_entry))
    
    local file = io.open(log_file, "a")
    if file then
        file:write(log_line)
        file:close()
    end
    
    -- Also write to general session monitor log
    local general_log_file = "/app/logs/session_monitor.log"
    local general_file = io.open(general_log_file, "a")
    if general_file then
        general_file:write(cjson.encode(log_entry) .. "\n")
        general_file:close()
    end
end

function SessionMonitor:get_metrics()
    -- Calculate error rate
    local total_sessions = self.metrics.session_creations + self.metrics.session_destructions
    local error_rate = total_sessions > 0 and (self.metrics.session_errors / total_sessions) or 0
    
    return {
        metrics = self.metrics,
        error_rate = error_rate,
        alert_count = #self.alerts,
        config = self.config
    }
end

function SessionMonitor:get_alerts(limit, severity)
    limit = limit or 100
    severity = severity or nil
    
    local filtered_alerts = {}
    local count = 0
    
    for i = #self.alerts, 1, -1 do -- Reverse order to get latest first
        local alert = self.alerts[i]
        
        if not severity or alert.severity == severity then
            table.insert(filtered_alerts, alert)
            count = count + 1
            
            if count >= limit then
                break
            end
        end
    end
    
    return filtered_alerts
end

function SessionMonitor:get_performance_data()
    return {
        session_lifetimes = self.performance_data.session_lifetimes,
        response_times = self.performance_data.response_times,
        error_rates = self.performance_data.error_rates
    }
end

function SessionMonitor:cleanup_old_logs()
    local log_file = "/app/logs/session_monitor.log"
    local retention_days = self.config.log_retention_days
    local cutoff_time = ngx.time() - (retention_days * 86400)
    
    -- Read current log file
    local file = io.open(log_file, "r")
    if not file then
        return
    end
    
    local lines = {}
    for line in file:lines() do
        local ok, data = pcall(cjson.decode, line)
        if ok and data.timestamp and data.timestamp > cutoff_time then
            table.insert(lines, line)
        end
    end
    file:close()
    
    -- Write back filtered lines
    file = io.open(log_file, "w")
    if file then
        for _, line in ipairs(lines) do
            file:write(line .. "\n")
        end
        file:close()
    end
end

function SessionMonitor.setup_monitoring_timer()
    local interval = SessionMonitor.get_instance().config.monitoring_interval
    
    local monitor_timer = ngx.timer.every(interval, function(premature)
        if premature then
            return
        end
        
        local monitor = SessionMonitor.get_instance()
        
        -- Check for expired sessions
        local manager = SessionManager.get_instance()
        manager:cleanup_expired_sessions()
        
        -- Clean up old logs
        monitor:cleanup_old_logs()
        
        -- Log monitoring metrics (only if there are issues or significant changes)
        local metrics = monitor:get_metrics()
        if metrics.metrics.session_errors > 0 or metrics.alert_count > 0 then
            logger.info("Session monitoring:", cjson.encode(metrics))
        else
            logger.debug("Session monitoring:", cjson.encode(metrics))
        end
    end)
    
    if not monitor_timer then
        logger.error("Failed to create monitoring timer")
    else
        logger.debug("Session monitoring timer created (interval: " .. interval .. "s")
    end
end

local _session_manager_instance = nil
local _session_monitor_instance = nil

function SessionManager.get_instance()
    if not _session_manager_instance then
        _session_manager_instance = SessionManager.new()
    end
    return _session_manager_instance
end

function SessionMonitor.get_instance()
    if not _session_monitor_instance then
        _session_monitor_instance = SessionMonitor.new()
    end
    return _session_monitor_instance
end

_M.SessionManager = SessionManager
_M.SessionMonitor = SessionMonitor

return _M
