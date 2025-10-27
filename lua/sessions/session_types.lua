-- Session Types

local cjson = require "cjson"
local SessionBase = require "sessions.base"
local config_manager = require "config.manager"
local logger = require "utils.logger"

local _M = {}

local AuthSession = {}
AuthSession.__index = AuthSession
setmetatable(AuthSession, { __index = SessionBase })

-- Constructor
function AuthSession.new(user_id, user_data, metadata)
    local self = SessionBase.new("auth", user_id, metadata)
    setmetatable(self, AuthSession)
    
    -- Auth-specific properties
    self.user_data = user_data or {}
    self.tokens = {}
    
    -- Load lua-resty-session
    local ok, session = pcall(require, "resty.session")
    if not ok then
        self:handle_error("Failed to load lua-resty-session: " .. (session or "unknown error"))
        return nil
    end
    self.session_lib = session
    
    return self
end

-- Create authentication session
function AuthSession:create()
    if self.state ~= SessionBase.SESSION_STATES.CREATING then
        return false, "Session is not in creating state"
    end
    
    -- Get session configuration
    local config = self:_get_session_config()
    if not config then
        return false, "Failed to get session configuration"
    end
    
    -- Start lua-resty-session
    local sess = self.session_lib.start(config)
    if not sess then
        return false, "Failed to start session"
    end
    
    -- Store session instance
    self.resty_session = sess
    
    -- Store user data in session
    sess.data.user = self.user_data
    sess.data.authenticated = true
    sess.data.auth_time = ngx.time()
    sess.data.session_id = self.session_id
    
    -- Set expiration
    local lifetime = config.lifetime or 3600
    self.expires_at = ngx.time() + lifetime
    
    -- Save session
    local ok, err = sess:save()
    if not ok then
        return false, "Failed to save session: " .. (err or "unknown error")
    end
    
    -- Set session as active
    self:set_state(SessionBase.SESSION_STATES.ACTIVE)
    
    return true
end

-- Destroy authentication session
function AuthSession:destroy()
    if self.resty_session then
        -- Mark session as destroyed in the session data
        self.resty_session.data.destroyed = true
        self.resty_session.data.authenticated = false
        
        -- Clear all session data
        self.resty_session.data.user = nil
        self.resty_session.data.tokens = nil
        self.resty_session.data.auth_time = nil
        self.resty_session.data.session_id = nil
        
        -- Save the changes before destroying
        local ok, err = self.resty_session:save()
        if not ok then
            logger.warn("Failed to save session destruction state:", (err or "unknown error"))
        end
        
        -- Destroy the session
        self.resty_session:destroy()
        self.resty_session = nil
    end
    
    self:set_state(SessionBase.SESSION_STATES.DESTROYED)
    return true
end

-- Validate authentication session
function AuthSession:validate()
    if not self.resty_session then
        return false, "No session instance"
    end
    
    -- Check if session is authenticated
    if not self.resty_session.data.authenticated then
        return false, "Session not authenticated"
    end
    
    -- Check if session has been marked as destroyed
    if self.resty_session.data.destroyed then
        return false, "Session has been destroyed"
    end
    
    -- Check if session is expired
    if self:is_expired() then
        self:set_state(SessionBase.SESSION_STATES.EXPIRED)
        return false, "Session expired"
    end
    
    -- Update activity
    self:update_activity()
    
    return true
end

-- Refresh authentication session
function AuthSession:refresh()
    if not self.resty_session then
        return false, "No session instance"
    end
    
    -- Update auth time
    self.resty_session.data.auth_time = ngx.time()
    
    -- Save session
    local ok, err = self.resty_session:save()
    if not ok then
        return false, "Failed to refresh session: " .. (err or "unknown error")
    end
    
    -- Update activity
    self:update_activity()
    
    return true
end

-- Store OIDC tokens in session
function AuthSession:store_tokens(tokens)
    if not self.resty_session then
        return false, "No session instance"
    end
    
    -- Store tokens securely in session
    self.resty_session.data.tokens = {
        access_token = tokens.access_token,
        refresh_token = tokens.refresh_token,
        token_type = tokens.token_type or "Bearer",
        expires_at = tokens.expires_at or (ngx.time() + 3600)
    }
    
    -- Save session
    local ok, err = self.resty_session:save()
    if not ok then
        return false, "Failed to save tokens: " .. (err or "unknown error")
    end
    
    self.tokens = self.resty_session.data.tokens
    return true
end

-- Get OIDC tokens from session
function AuthSession:get_tokens()
    if not self.resty_session then
        return nil
    end
    
    return self.resty_session.data.tokens
end

-- Clear OIDC tokens from session
function AuthSession:clear_tokens()
    if not self.resty_session then
        return false, "No session instance"
    end
    
    self.resty_session.data.tokens = nil
    local ok, err = self.resty_session:save()
    if not ok then
        return false, "Failed to clear tokens: " .. (err or "unknown error")
    end
    
    self.tokens = {}
    return true
end

-- Get current user data
function AuthSession:get_user()
    if not self.resty_session then
        return nil
    end
    
    return self.resty_session.data.user
end

-- Update user data
function AuthSession:update_user(user_data)
    if not self.resty_session then
        return false, "No session instance"
    end
    
    self.resty_session.data.user = user_data
    self.user_data = user_data
    
    local ok, err = self.resty_session:save()
    if not ok then
        return false, "Failed to update user data: " .. (err or "unknown error")
    end
    
    return true
end

-- Get session configuration
function AuthSession:_get_session_config()
    -- Session configuration (static values only)
    local session_config = config_manager.get_session_config()
    local config = {
        name = "session",
        secret = session_config.secret,
        storage = "cookie",
        cookie = {
            domain = session_config.domain,
            path = "/",
            secure = session_config.secure,
            httponly = true,
            samesite = "Lax",
        },
        lifetime = session_config.lifetime,
        rolling = true,
        rolling_timeout = session_config.rolling_timeout,
    }
    
    -- Set secure flag based on current request scheme
    if ngx.var.scheme then
        local is_secure = config.cookie.secure or ngx.var.scheme == "https"
        config.cookie.secure = is_secure
    end
    
    return config
end

-- Get session info with auth-specific data
function AuthSession:get_info()
    local info = SessionBase.get_info(self)
    
    -- Add auth-specific info
    info.user_email = self.user_data.email
    info.user_name = self.user_data.name
    info.has_tokens = self.resty_session and self.resty_session.data.tokens ~= nil
    
    return info
end

-- Create from existing lua-resty-session
function AuthSession.from_resty_session(resty_session, user_id)
    if not resty_session or not resty_session.data.authenticated then
        return nil, "Invalid session"
    end
    
    local user_data = resty_session.data.user or {}
    local self = AuthSession.new(user_id, user_data)
    
    -- Set existing session
    self.resty_session = resty_session
    self.session_id = resty_session.data.session_id or self.session_id
    
    -- Set state based on session validity
    if self:is_expired() then
        self:set_state(SessionBase.SESSION_STATES.EXPIRED)
    else
        self:set_state(SessionBase.SESSION_STATES.ACTIVE)
    end
    
    return self
end

local HttpProxySession = {}
HttpProxySession.__index = HttpProxySession
setmetatable(HttpProxySession, { __index = SessionBase })

-- Constructor
function HttpProxySession.new(user_id, service_id, service_config, metadata)
    local self = SessionBase.new("http_proxy", user_id, metadata)
    setmetatable(self, HttpProxySession)
    
    -- HTTP proxy-specific properties
    self.service_id = service_id
    self.service_config = service_config or {}
    self.proxy_path = "/http/" .. (service_id or "unknown") .. "/"
    self.request_count = 0
    self.bytes_transferred = 0
    self.last_request_time = nil
    
    -- Set expiration (1 hour default for HTTP proxy sessions)
    local session_config = config_manager.get_session_config()
    self.expires_at = ngx.time() + session_config.http_proxy_lifetime
    
    return self
end

-- Create HTTP proxy session
function HttpProxySession:create()
    if self.state ~= SessionBase.SESSION_STATES.CREATING then
        return false, "Session is not in creating state"
    end
    
    -- Validate service configuration
    if not self.service_config.host or not self.service_config.port then
        return false, "Invalid service configuration"
    end
    
    -- Store service info in session data
    self:set_data("service_id", self.service_id)
    self:set_data("service_host", self.service_config.host)
    self:set_data("service_port", self.service_config.port)
    self:set_data("service_protocol", self.service_config.protocol or "http")
    self:set_data("service_path", self.service_config.path or "/")
    
    -- Set session as active
    self:set_state(SessionBase.SESSION_STATES.ACTIVE)
    
    return true
end

-- Destroy HTTP proxy session
function HttpProxySession:destroy()
    self:set_state(SessionBase.SESSION_STATES.DESTROYED)
    return true
end

-- Validate HTTP proxy session
function HttpProxySession:validate()
    -- Check if session is expired
    if self:is_expired() then
        self:set_state(SessionBase.SESSION_STATES.EXPIRED)
        return false, "Session expired"
    end
    
    -- Check if service is still enabled
    if not self.service_config.enabled then
        return false, "Service is disabled"
    end
    
    -- Update activity
    self:update_activity()
    
    return true
end

-- Refresh HTTP proxy session
function HttpProxySession:refresh()
    -- Extend session lifetime
    local session_config = config_manager.get_session_config()
    local lifetime = session_config.http_proxy_lifetime
    self.expires_at = ngx.time() + lifetime
    
    -- Update activity
    self:update_activity()
    
    return true
end

-- Record HTTP request
function HttpProxySession:record_request(request_info)
    self.request_count = self.request_count + 1
    self.last_request_time = ngx.time()
    
    -- Update activity
    self:update_activity()
    
    -- Store request info
    local requests = self:get_data("requests") or {}
    table.insert(requests, {
        timestamp = ngx.time(),
        method = request_info.method,
        path = request_info.path,
        status = request_info.status,
        bytes = request_info.bytes or 0,
        duration = request_info.duration or 0
    })
    
    -- Keep only last 100 requests
    if #requests > 100 then
        table.remove(requests, 1)
    end
    
    self:set_data("requests", requests)
    
    -- Update bytes transferred
    if request_info.bytes then
        self.bytes_transferred = self.bytes_transferred + request_info.bytes
    end
end

-- Get service configuration
function HttpProxySession:get_service_config()
    return self.service_config
end

function HttpProxySession:get_proxy_path()
    return self.proxy_path
end

-- Get request statistics
function HttpProxySession:get_stats()
    return {
        request_count = self.request_count,
        bytes_transferred = self.bytes_transferred,
        last_request_time = self.last_request_time,
        requests = self:get_data("requests") or {}
    }
end

-- Get session info with HTTP proxy-specific data
function HttpProxySession:get_info()
    local info = SessionBase.get_info(self)
    
    -- Add HTTP proxy-specific info
    info.service_id = self.service_id
    info.service_host = self.service_config.host
    info.service_port = self.service_config.port
    info.proxy_path = self.proxy_path
    info.request_count = self.request_count
    info.bytes_transferred = self.bytes_transferred
    info.last_request_time = self.last_request_time
    
    return info
end

-- Check if service is accessible
function HttpProxySession:is_service_accessible()
    return self.service_config.enabled and self:is_active()
end

-- Get target URL for proxy
function HttpProxySession:get_target_url(path)
    local protocol = self.service_config.protocol or "http"
    local host = self.service_config.host
    local port = self.service_config.port
    local base_path = self.service_config.path or "/"
    
    -- Build target URL
    local target_url = string.format("%s://%s:%d", protocol, host, port)
    
    -- Handle path concatenation
    if base_path == "/" and path == "/" then
        target_url = target_url .. "/"
    elseif base_path == "/" then
        target_url = target_url .. path
    elseif path == "/" then
        target_url = target_url .. base_path
    else
        target_url = target_url .. base_path .. path
    end
    
    return target_url
end

-- Validate service configuration
function HttpProxySession:validate_service_config()
    local errors = {}
    
    if not self.service_config.host or self.service_config.host == "" then
        table.insert(errors, "Service host is required")
    end
    
    if not self.service_config.port or type(self.service_config.port) ~= "number" or 
       self.service_config.port < 1 or self.service_config.port > 65535 then
        table.insert(errors, "Service port must be a number between 1 and 65535")
    end
    
    if self.service_config.protocol and 
       self.service_config.protocol ~= "http" and 
       self.service_config.protocol ~= "https" then
        table.insert(errors, "Service protocol must be http or https")
    end
    
    return #errors == 0, errors
end

local SshProxySession = {}
SshProxySession.__index = SshProxySession
setmetatable(SshProxySession, { __index = SessionBase })

-- Constructor
function SshProxySession.new(user_id, service_id, service_config, metadata)
    local self = SessionBase.new("ssh_proxy", user_id, metadata)
    setmetatable(self, SshProxySession)
    
    -- SSH proxy-specific properties
    self.service_id = service_id
    self.service_config = service_config or {}
    self.proxy_path = "/ssh/" .. (service_id or "unknown") .. "/"
    self.socket_path = nil
    self.ttyd_pid = nil
    self.ssh_command = nil
    
    -- Set expiration (1 hour default for SSH proxy sessions)
    local session_config = config_manager.get_session_config()
    self.expires_at = ngx.time() + session_config.ssh_proxy_lifetime
    
    return self
end

-- Create SSH proxy session
function SshProxySession:create()
    if self.state ~= SessionBase.SESSION_STATES.CREATING then
        return false, "Session is not in creating state"
    end
    
    -- Validate service configuration
    local valid, errors = self:validate_service_config()
    if not valid then
        return false, "Invalid service configuration: " .. table.concat(errors, ", ")
    end
    
    -- Generate unique socket path
    self.socket_path = self:_generate_socket_path()
    
    -- Build interactive SSH script command
    self.ssh_command = string.format("/app/scripts/ssh-interactive-login.sh %s %d", 
        self.service_config.host, 
        self.service_config.port
    )
    
    -- Start ttyd process
    local success, err = self:_start_ttyd_process()
    if not success then
        return false, "Failed to start ttyd process: " .. (err or "unknown error")
    end
    
    -- Store session info
    self:set_data("service_id", self.service_id)
    self:set_data("service_host", self.service_config.host)
    self:set_data("service_port", self.service_config.port)
    self:set_data("socket_path", self.socket_path)
    self:set_data("ttyd_pid", self.ttyd_pid)
    self:set_data("ssh_command", self.ssh_command)
    
    -- Set session as active
    self:set_state(SessionBase.SESSION_STATES.ACTIVE)
    
    return true
end

-- Deserialize SSH proxy session from storage
function SshProxySession:deserialize(data)
    -- Call base class deserialize first
    local success, err = SessionBase.deserialize(self, data)
    if not success then
        return false, err
    end
    
    -- Restore SSH proxy-specific properties from data
    if data.data then
        self.socket_path = data.data.socket_path
        self.ttyd_pid = data.data.ttyd_pid
        self.ssh_command = data.data.ssh_command
        self.service_id = data.data.service_id
        self.proxy_path = "/ssh/" .. (data.data.service_id or "") .. "/"
    end
    
    return true
end

-- Destroy SSH proxy session
function SshProxySession:destroy()
    logger.info("Destroying SSH session " .. self.session_id)
    
    -- Stop ttyd process
    if self.ttyd_pid then
        self:_stop_ttyd_process()
        logger.info("SSH session " .. self.session_id .. " ttyd process stopped (PID: " .. tostring(self.ttyd_pid) .. ")")
    else
        logger.info("SSH session " .. self.session_id .. " destroyed (no ttyd process)")
    end
    
    -- Remove socket file
    if self.socket_path then
        os.execute("rm -f " .. self.socket_path)
        logger.info("SSH session " .. self.session_id .. " socket removed: " .. self.socket_path)
    else
        logger.info("SSH session " .. self.session_id .. " destroyed (no socket path)")
    end
    
    self:set_state(SessionBase.SESSION_STATES.DESTROYED)
    return true
end

-- Clean up orphaned socket files
function SshProxySession.cleanup_orphaned_sockets()
    local socket_dir = "/app/ttyd_sockets"
    local cleanup_command = "find " .. socket_dir .. " -name 'ttyd_*.sock' -mtime +1 -delete 2>/dev/null || true"
    os.execute(cleanup_command)
    logger.debug("Cleaned up orphaned ttyd socket files")
end

-- Validate SSH proxy session
function SshProxySession:validate()
    -- Check if session is expired
    if self:is_expired() then
        self:set_state(SessionBase.SESSION_STATES.EXPIRED)
        return false, "Session expired"
    end
    
    -- Check if service is still enabled
    if not self.service_config.enabled then
        return false, "Service is disabled"
    end
    
    -- Check if ttyd process is still running
    if self.ttyd_pid and not self:_is_process_running() then
        return false, "ttyd process not running"
    end
    
    -- Check if socket exists (but don't fail if it doesn't - SSH connection might be failing)
    if self.socket_path and not self:_socket_exists() then
        -- Log the issue but don't fail validation
        logger.warn("SSH proxy session socket not found: " .. self.socket_path .. " - SSH connection may be failing")
    end
    
    -- Update activity
    self:update_activity()
    
    return true
end

-- Refresh SSH proxy session
function SshProxySession:refresh()
    -- Extend session lifetime
    local session_config = config_manager.get_session_config()
    local lifetime = session_config.ssh_proxy_lifetime
    self.expires_at = ngx.time() + lifetime
    
    -- Update activity
    self:update_activity()
    
    return true
end

-- Generate unique socket path
function SshProxySession:_generate_socket_path()
    local timestamp = os.time()
    local random_suffix = math.random(1000, 9999)
    return string.format("/app/ttyd_sockets/ttyd_%s_%s_%d_%d.sock", 
        self.user_id, self.service_id, timestamp, random_suffix)
end

-- Start ttyd process
function SshProxySession:_start_ttyd_process()
    -- Build ttyd command
    local ttyd_command = string.format(
        "ttyd -q -o --writable -i %s --base-path /ssh/%s/ %s",
        self.socket_path, self.service_id, self.ssh_command
    )
    
    -- Log the command being executed
    logger.debug("Starting ttyd for SSH session: " .. self.session_id .. " | Command: " .. ttyd_command)
    
    -- Start ttyd process in background and capture PID
    local background_command = ttyd_command .. " >/dev/null 2>&1 & echo $!"
    
    local handle = io.popen(background_command)
    if not handle then
        return false, "Failed to start ttyd process"
    end
    
    local pid = handle:read("*line")
    handle:close()
    
    if not pid or pid == "" then
        return false, "Failed to get ttyd process ID"
    end
    
    self.ttyd_pid = tonumber(pid)
    
    -- Wait a moment for ttyd to start
    os.execute("sleep 1")
    
    -- Check if socket was created and fix permissions
    if self:_socket_exists() then
        -- Fix socket permissions for nginx (use numeric UID/GID for reliability)
        os.execute("chmod 666 " .. self.socket_path)
        -- Set ownership to nginx user (UID 101 in Alpine)
        os.execute("chown 101:101 " .. self.socket_path .. " 2>/dev/null || true")
        logger.info("SSH session " .. self.session_id .. " socket created: " .. self.socket_path)
        return true
    else
        -- Check if process is still running
        if self:_is_process_running() then
            logger.debug("SSH session " .. self.session_id .. " process running but socket not created - SSH connection may be failing")
            -- Don't fail the session creation - let it continue and the user can see the connection issue
            return true
        else
            logger.error("SSH session " .. self.session_id .. " ttyd process exited")
            return false, "ttyd process exited"
        end
    end
end

-- Stop ttyd process
function SshProxySession:_stop_ttyd_process()
    if self.ttyd_pid then
        os.execute("kill " .. self.ttyd_pid)
        self.ttyd_pid = nil
    end
end

-- Check if process is running
function SshProxySession:_is_process_running()
    if not self.ttyd_pid then
        return false
    end
    
    local check_handle = io.popen("ps -p " .. tostring(self.ttyd_pid) .. " >/dev/null 2>&1; echo $?")
    if not check_handle then
        return false
    end
    
    local process_status = check_handle:read("*line")
    check_handle:close()
    
    return process_status == "0"
end

-- Check if socket exists
function SshProxySession:_socket_exists()
    if not self.socket_path then
        return false
    end
    
    return os.execute("test -S " .. self.socket_path) == 0
end

-- Get service configuration
function SshProxySession:get_service_config()
    return self.service_config
end

function SshProxySession:get_proxy_path()
    return self.proxy_path
end

function SshProxySession:get_socket_path()
    return self.socket_path
end

-- Get SSH command
function SshProxySession:get_ssh_command()
    return self.ssh_command
end

function SshProxySession:get_process_info()
    return {
        ttyd_pid = self.ttyd_pid,
        socket_path = self.socket_path,
        ssh_command = self.ssh_command,
        is_running = self:_is_process_running(),
        socket_exists = self:_socket_exists()
    }
end

-- Get session info with SSH proxy-specific data
function SshProxySession:get_info()
    local info = SessionBase.get_info(self)
    
    -- Add SSH proxy-specific info
    info.service_id = self.service_id
    info.service_host = self.service_config.host
    info.service_port = self.service_config.port
    info.service_username = self.service_config.username or "interactive"
    info.proxy_path = self.proxy_path
    info.socket_path = self.socket_path
    info.ttyd_pid = self.ttyd_pid
    info.process_running = self:_is_process_running()
    info.socket_exists = self:_socket_exists()
    
    return info
end

-- Check if service is accessible
function SshProxySession:is_service_accessible()
    return self.service_config.enabled and self:is_active() and 
           self:_is_process_running() and self:_socket_exists()
end

-- Validate service configuration
function SshProxySession:validate_service_config()
    local errors = {}
    
    if not self.service_config.id or self.service_config.id == "" then
        table.insert(errors, "SSH service ID is required")
    end
    
    if not self.service_config.name or self.service_config.name == "" then
        table.insert(errors, "SSH service name is required")
    end
    
    if not self.service_config.host or self.service_config.host == "" then
        table.insert(errors, "SSH service host is required")
    end
    
    if not self.service_config.port or type(self.service_config.port) ~= "number" or 
       self.service_config.port < 1 or self.service_config.port > 65535 then
        table.insert(errors, "SSH service port must be a number between 1 and 65535")
    end
    
    return #errors == 0, errors
end

_M.AuthSession = AuthSession
_M.HttpProxySession = HttpProxySession
_M.SshProxySession = SshProxySession

return _M
