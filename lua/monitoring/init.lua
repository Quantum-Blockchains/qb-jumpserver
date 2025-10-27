-- Monitoring Core

local cjson = require "cjson"
local monitoring_model = require("models.monitoring")
local data_utils = require("utils.data_utils")
-- Lazy load auth_core to avoid circular dependency
local function get_auth_service()
    local ok, auth_service = pcall(require, "auth.auth_service")
    return ok and auth_service or nil
end
-- session_uid is now in data_utils
local config_manager = require "config.manager"
local logger = require "utils.logger"

local _M = {}

-- No levels: we record ONLY HTML responses, determined at runtime via content-type

-- Build a base event from current request and user
local function build_base_event()
    local auth_service = get_auth_service()
    local user = auth_service and auth_service.get_current_user() or nil
    local headers = ngx.req.get_headers() or {}
    local forwarded_for = headers["x-forwarded-for"] or headers["X-Forwarded-For"] or ngx.var.http_x_forwarded_for
    -- If multiple IPs in XFF, take the first hop
    if type(forwarded_for) == "string" and forwarded_for:find(",") then
        forwarded_for = forwarded_for:match("^%s*([^,]+)")
    end
    local real_ip = ngx.var.http_x_real_ip or ngx.var.realip_remote_addr
    local remote_ip = ngx.var.remote_addr
    local remote_port = ngx.var.remote_port
    local server_port = ngx.var.server_port
    local scheme = ngx.var.scheme
    local host = ngx.var.host or headers["host"] or headers["Host"]
    local server_name = ngx.var.server_name
    local xfp = headers["x-forwarded-proto"] or headers["X-Forwarded-Proto"]
    local xfp_port = headers["x-forwarded-port"] or headers["X-Forwarded-Port"]
    local user_agent = headers["user-agent"] or headers["User-Agent"]
    local accept_language = headers["accept-language"] or headers["Accept-Language"]
    local origin = headers["origin"] or headers["Origin"]
    local referer = headers["referer"] or headers["Referer"]
    local request_id = headers["x-request-id"] or headers["X-Request-Id"] or ngx.var.request_id

    local sid = data_utils.get_session_uid()
    if not sid then
        local phase = ngx.get_phase and ngx.get_phase() or ""
        if phase ~= "log" then
            local ok, ensured = pcall(data_utils.ensure_session_uid)
            if ok then sid = ensured end
        else
            -- In log phase, use ensure_for_logging to avoid setting headers
            local ok, ensured = pcall(data_utils.ensure_session_uid_for_logging)
            if ok then sid = ensured end
        end
    end

    local resolved_user_id = user and (user.user_id or user.sub or user.id) or nil
    local resolved_username = user and (user.username or user.preferred_username or user.email or user.name) or nil
    local client_ip = (forwarded_for and tostring(forwarded_for)) or (real_ip and tostring(real_ip)) or remote_ip
    local absolute_url = (scheme or "") .. "://" .. (host or "") .. (ngx.var.request_uri or "")

    local base = {
        user_id = resolved_user_id,
        username = resolved_username,
        ip = client_ip,
        request_method = ngx.req.get_method(),
        request_uri = ngx.var.request_uri,
        session_id = sid,
        metadata = {
            user_agent = user_agent,
            accept_language = accept_language,
            referer = referer,
            origin = origin,
            request_id = request_id,
            auth_provider = user and user.auth_provider or nil,
            auth_method = user and user.auth_method or nil,
            roles = user and user.roles or nil,
            groups = user and user.groups or nil,
            user = user and {
                id = resolved_user_id,
                username = resolved_username,
                email = user.email,
                name = user.name,
            } or nil,
            user_guid = resolved_user_id,
            session_id = sid,
            client_ip = client_ip,
            client_port = remote_port,
            absolute_url = absolute_url,
            connection = {
                remote_addr = remote_ip,
                remote_port = remote_port,
                client = (remote_ip and remote_port) and (tostring(remote_ip) .. ":" .. tostring(remote_port)) or nil,
                real_ip = real_ip,
                forwarded_for = forwarded_for,
                scheme = scheme,
                forwarded_proto = xfp,
                host = host,
                server_name = server_name,
                server_port = server_port,
                forwarded_port = xfp_port,
            }
        }
    }
    return base
end

-- Create and store a monitoring event
function _M.record(event)
    local base = build_base_event()
    for k, v in pairs(base) do
        if k == "metadata" then
            local md
            if type(event.metadata) == "table" then
                md = event.metadata
            elseif event.metadata ~= nil then
                md = { message = tostring(event.metadata) }
            else
                md = {}
            end
            -- Merge base metadata with provided metadata (provided overrides base)
            for mk, mv in pairs(base.metadata or {}) do
                if md[mk] == nil then md[mk] = mv end
            end
            event.metadata = md
        else
            if event[k] == nil then
                event[k] = v
            end
        end
    end
    return monitoring_model.insert_event(event)
end

-- Shorthand functions
function _M.auth_event(action, status, extra)
    extra = extra or {}
    extra.flow = extra.flow or "auth"
    extra.action = action
    extra.status = status
    -- ensure description is present for admin readability
    if not extra.description then
        extra.description = string.format("%s %s", action or "event", status or "")
    end
    return _M.record(extra)
end

function _M.http_event(action, status, extra)
    extra = extra or {}
    extra.flow = extra.flow or "http"
    extra.action = action
    extra.status = status
    return _M.record(extra)
end

function _M.ssh_event(action, status, extra)
    extra = extra or {}
    extra.flow = extra.flow or "ssh"
    extra.action = action
    extra.status = status
    return _M.record(extra)
end

-- Record request access (called from nginx log phase)
function _M.record_access()
    -- Only record when the response content-type indicates HTML
    local ct = ngx.var.sent_http_content_type or ngx.var.content_type or ""
    if not ct or ct == "" then return end
    local lct = string.lower(ct)
    if not (lct:find("text/html", 1, true) or lct:find("application/xhtml+xml", 1, true)) then
        return
    end

    local access_loggers_ok, access_loggers = pcall(require, "monitoring.access_loggers")
    if not access_loggers_ok or not access_loggers then
        return
    end

    local uri = ngx.var.uri or ngx.var.request_uri or ""
    local logger = access_loggers.pick_logger(uri)
    if not logger or not logger.should_log or not logger.build_event then
        return
    end
    if not logger:should_log(uri) then
        return
    end

    local event = logger:build_event(uri)
    -- Record synchronously in log phase so request context is available
    pcall(function()
        _M.record(event)
    end)
end

-- Periodic cleanup of old monitoring rows based on environment variable
-- MONITORING_RETENTION: duration string, supports suffixes s, m, h, d (default: 7d)
local function parse_duration(env_val)
    local v = tostring(env_val or "")
    if v == "" then return 7 * 24 * 3600 end
    local num, unit = v:match("^(%d+)%s*([smhdSMHD]?)$")
    num = tonumber(num)
    if not num then return 7 * 24 * 3600 end
    unit = (unit or ""):lower()
    if unit == "" or unit == "s" then return num end
    if unit == "m" then return num * 60 end
    if unit == "h" then return num * 3600 end
    if unit == "d" then return num * 86400 end
    return 7 * 24 * 3600
end


local function cleanup_old_events()
    local retention = parse_duration(config_manager.get_env("monitoring_retention", "7d"))
    if retention <= 0 then return end
    local ok, model = pcall(require, "models.monitoring")
    if not ok or not model then return end
    pcall(function()
        local ok_del, deleted_or_err = model.delete_older_than(retention)
        if not ok_del then
            logger.warn("Monitoring cleanup failed:", tostring(deleted_or_err))
            return
        end
        -- Quiet success: only log if we actually deleted rows, to reduce verbosity
        local deleted = tonumber(deleted_or_err) or 0
        if deleted > 0 then
            logger.debug("Monitoring cleanup removed " .. tostring(deleted) .. " events (retention=" .. tostring(retention) .. "s)")
        end
    end)
end

-- Setup periodic cleanup (every 10 minutes)
local _cleanup_initialized = false
function _M.setup_rotation_timer()
    if _cleanup_initialized then return end
    _cleanup_initialized = true
    local interval = parse_duration(config_manager.get_env("monitoring_cleanup_interval", "600s"))
    if interval < 1 then interval = 10 end
    -- Single INFO on startup; no per-tick logs
    logger.debug("Monitoring rotation timer active (interval=" .. tostring(interval) .. "s)")
    ngx.timer.every(interval, function(premature)
        if premature then return end
        cleanup_old_events()
    end)
    -- Run once immediately for testing
    ngx.timer.at(0, function(premature)
        if premature then return end
        cleanup_old_events()
    end)
end

-- Query passthrough
function _M.list(opts)
    return monitoring_model.list_events(opts)
end

-- Grouped list by session id (pagination based on groups)
function _M.list_grouped(opts)
    return monitoring_model.list_events_grouped(opts)
end

return _M


