-- Configuration Manager

local cjson = require "cjson"
local logger = require "utils.logger"

local _M = {}

local config_cache = {}
local config_loaded = false

local DEFAULT_PATHS = {
    services = "/app/services.json",           -- Unified services file (preferred)
    http_services = "/app/http-services.json",
    ssh_services = "/app/ssh-services.json",
    env_file = "/app/env"
}

local ENV_MAPPINGS = {
    -- Network configuration
    host = "JUMP_SERVER_HOST",
    port = "JUMP_SERVER_PORT",
    port_https = "JUMP_SERVER_PORT_HTTPS",
    https_enabled = "HTTPS_ENABLED",
    
    
    
    -- OIDC configuration
    oidc_enabled = "OIDC_ENABLED",
    oidc_discovery_url = "OIDC_DISCOVERY_URL",
    oidc_base_url = "OIDC_BASE_URL",
    oidc_realm = "OIDC_REALM",
    oidc_client_id = "OIDC_CLIENT_ID",
    oidc_client_secret = "OIDC_CLIENT_SECRET",
    oidc_backchannel_logout_enabled = "OIDC_BACKCHANNEL_LOGOUT_ENABLED",
    show_oidc_menu = "SHOW_OIDC_MENU_OPTION",
    
    session_secret = "SESSION_SECRET",
    session_domain = "SESSION_DOMAIN",
    session_secure = "SESSION_SECURE",
    session_lifetime = "SESSION_LIFETIME",
    session_rolling_timeout = "SESSION_ROLLING_TIMEOUT",
    session_max_per_user = "SESSION_MAX_PER_USER",
    session_max_idle_time = "SESSION_MAX_IDLE_TIME",
    session_error_rate_threshold = "SESSION_ERROR_RATE_THRESHOLD",
    session_monitor_interval = "SESSION_MONITOR_INTERVAL",
    session_log_retention = "SESSION_LOG_RETENTION",
    ssh_proxy_session_lifetime = "SSH_PROXY_SESSION_LIFETIME",
    http_proxy_session_lifetime = "HTTP_PROXY_SESSION_LIFETIME",
    
    docker_network = "DOCKER_NETWORK",
    environment = "ENVIRONMENT",
    
    monitoring_retention = "MONITORING_RETENTION",
    monitoring_cleanup_interval = "MONITORING_CLEANUP_INTERVAL",
    log_level = "LOG_LEVEL",
    
    jump_server_title = "JUMP_SERVER_TITLE"
}

-- Initialize the configuration manager
function _M.init()
    if config_loaded then
        logger.info("Configuration already loaded, skipping initialization")
        return true
    end
    
    logger.debug("Initializing unified configuration manager...")
    
    config_cache = {
        env = {},
        http_services = {},
        ssh_services = {},
        paths = DEFAULT_PATHS
    }
    
    local success = true
    success = success and _M._load_environment()
    success = success and _M._load_services_config()
    
    if success then
        config_loaded = true
        logger.debug("Unified configuration manager initialized successfully")
        _M._log_config_summary()
    else
        logger.error("Failed to initialize configuration manager")
    end
    
    return success
end

function _M.clear_cache()
    config_loaded = false
    config_cache = {}
    logger.info("Configuration cache cleared")
end

function _M._load_environment()
    logger.debug("Loading environment configuration...")
    
    _M._load_env_file()
    
    -- Load environment variables using mappings
    for key, env_var in pairs(ENV_MAPPINGS) do
        local value = os.getenv(env_var)
        if value then
            -- Keep session duration parameters as strings for parsing
            local is_session_duration = (key == "session_lifetime" or 
                                       key == "session_rolling_timeout" or 
                                       key == "session_max_idle_time" or 
                                       key == "session_monitor_interval" or 
                                       key == "ssh_proxy_session_lifetime" or 
                                       key == "http_proxy_session_lifetime")
            
            if is_session_duration then
                config_cache.env[key] = value
            elseif value == "true" then
                config_cache.env[key] = true
            elseif value == "false" then
                config_cache.env[key] = false
            else
                local num_value = tonumber(value)
                if num_value then
                    config_cache.env[key] = num_value
                else
                    config_cache.env[key] = value
                end
            end
        end
    end
    
    -- Set computed URLs
    _M._compute_derived_urls()
    
    logger.debug(string.format("Loaded %d environment variables", 
        _M._count_keys(config_cache.env)))
    return true
end

-- Load environment from .env file
function _M._load_env_file()
    local env_files = {"/app/env", "/app/.env", "/app/env.development", "/app/env.production"}
    
    for _, file_path in ipairs(env_files) do
        local file = io.open(file_path, "r")
        if file then
            -- Try to process the file, catching errors if it's a directory
            local ok, err = pcall(function() 
                logger.debug("Loading environment from: " .. file_path)
                for line in file:lines() do
                    -- Skip comments and empty lines
                    if line and not line:match("^%s*#") and line:match("%S") then
                        local key, value = line:match("^%s*([^=]+)=(.*)%s*$")
                        if key and value then
                            -- Remove quotes if present
                            value = value:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
                            -- Note: os.setenv not available in all Lua environments
                            -- Environment variables are already loaded via os.getenv
                        end
                    end
                end
            end)
            
            file:close()
            
            -- If successful, we're done
            if ok then
                break
            else
                -- Skip this path (likely a directory or invalid file)
                logger.debug("Skipping invalid file path: " .. file_path .. " (" .. (err or "unknown error") .. ")")
            end
        end
    end
end

-- Compute derived URLs from environment variables
function _M._compute_derived_urls()
    local env = config_cache.env
    
    -- Determine scheme and external port for this app
    local scheme = (env.https_enabled and env.https_enabled == true) and "https" or "http"
    local external_port = env.port

    -- Jump Server URL
    if env.host and external_port then
        env.jump_server_url = string.format("%s://%s:%s", scheme, env.host, tostring(external_port))
    end
    
    -- OIDC Discovery URL: derive from base URL and realm if not explicitly set
    if not env.oidc_discovery_url then
        if env.oidc_base_url and env.oidc_realm then
            env.oidc_discovery_url = string.format("%s/realms/%s/.well-known/openid-configuration", tostring(env.oidc_base_url), tostring(env.oidc_realm))
            logger.debug("Derived OIDC discovery URL from base URL and realm: " .. env.oidc_discovery_url)
        end
    else
        logger.info("Using OIDC discovery URL: " .. env.oidc_discovery_url)
    end

    -- OIDC Admin URL: prefer base URL when provided; otherwise derive from discovery URL
    if env.oidc_base_url then
        env.oidc_admin_url = tostring(env.oidc_base_url) .. "/admin"
    elseif env.oidc_discovery_url then
        local base_url = env.oidc_discovery_url:gsub("/realms/.*", "")
        env.oidc_admin_url = base_url .. "/admin"
    end
    
    -- OIDC Redirect URI - use explicit setting if provided, otherwise construct from host/port
    if not env.oidc_redirect_uri and env.host and external_port then
        env.oidc_redirect_uri = string.format("%s://%s:%s/auth/oidc/callback", scheme, env.host, tostring(external_port))
        logger.debug("Generated OIDC redirect URI from host/port: " .. env.oidc_redirect_uri)
    elseif env.oidc_redirect_uri then
        logger.info("Using explicit OIDC redirect URI: " .. env.oidc_redirect_uri)
    end

    -- OIDC Post-Logout Redirect URI - default to /login on this app
    if not env.oidc_post_logout_redirect_uri and env.host and external_port then
        env.oidc_post_logout_redirect_uri = string.format("%s://%s:%s/login", scheme, env.host, tostring(external_port))
        logger.debug("Generated OIDC post-logout redirect URI from host/port: " .. env.oidc_post_logout_redirect_uri)
    elseif env.oidc_post_logout_redirect_uri then
        logger.info("Using explicit OIDC post-logout redirect URI: " .. env.oidc_post_logout_redirect_uri)
    end
end

-- Load services configuration (HTTP and SSH)
function _M._load_services_config()
    logger.debug("Loading services configuration...")
    
    -- Load unified services.json first (preferred format)
    local unified_loaded = _M._load_json_file(DEFAULT_PATHS.services, "services")
    if unified_loaded and config_cache.services then
        if config_cache.services.services then
            -- New format: {"services": [...]}
            logger.info("Loading services from unified services.json (array format)")
            _M._split_services_array(config_cache.services.services)
        else
            logger.info("Loading services from unified services.json (object format)")
            _M._split_services(config_cache.services)
        end
    else
        -- Fallback to separate files
        logger.info("Unified services.json not found, trying separate files...")
        local http_loaded = _M._load_json_file(DEFAULT_PATHS.http_services, "http_services")
        local ssh_loaded = _M._load_json_file(DEFAULT_PATHS.ssh_services, "ssh_services")
        
        if not http_loaded and not ssh_loaded then
            logger.warn("No service configuration files found")
        end
    end
    
    logger.debug(string.format("Loaded %d HTTP services and %d SSH services",
        _M._count_keys(config_cache.http_services),
        _M._count_keys(config_cache.ssh_services)))
    
    return true
end

-- Split combined services into HTTP and SSH categories (array format)
function _M._split_services_array(services)
    if type(services) ~= "table" then
        logger.error("Services must be a table/array")
        return
    end
    
    for _, service in ipairs(services) do
        if service.id then
            if service.type == "http" then
                config_cache.http_services[service.id] = service
            elseif service.type == "ssh" then
                config_cache.ssh_services[service.id] = service
            else
                logger.warn("Unknown service type '" .. (service.type or "nil") .. "' for service: " .. (service.id or "unknown"))
            end
        else
            logger.warn("Service missing 'id' field, skipping")
        end
    end
end

-- Split combined services into HTTP and SSH categories (object format)
function _M._split_services(services)
    for service_id, service in pairs(services) do
        if service.type == "http" then
            config_cache.http_services[service_id] = service
        elseif service.type == "ssh" then
            config_cache.ssh_services[service_id] = service
        else
            logger.warn("Unknown service type '" .. (service.type or "nil") .. "' for service: " .. service_id)
        end
    end
end


-- Load JSON file with error handling
function _M._load_json_file(file_path, cache_key)
    local file = io.open(file_path, "r")
    if not file then
        logger.info("Configuration file not found: " .. file_path)
        return false
    end
    
    -- Try to read - catches the "Is a directory" error
    local ok_read, content = pcall(function() return file:read("*all") end)
    file:close()
    
    if not ok_read then
        logger.debug("Skipping " .. file_path .. " (is a directory or unreadable)")
        return false
    end
    
    if not content or content == "" then
        logger.warn("Configuration file is empty: " .. file_path)
        return false
    end
    
    local ok, data = pcall(cjson.decode, content)
    if not ok then
        logger.error("Invalid JSON in " .. file_path .. ": " .. (data or "unknown error"))
        return false
    end
    
    config_cache[cache_key] = data
    logger.debug("Loaded configuration from: " .. file_path)
    return true
end

-- Get configuration value with hierarchical lookup
function _M.get(section, key, default)
    if not config_loaded then
        logger.warn("Configuration not loaded, initializing...")
        _M.init()
    end
    
    if not section then
        return config_cache
    end
    
    local section_data = config_cache[section]
    if not section_data then
        return default
    end
    
    if not key then
        return section_data
    end
    
    return section_data[key] or default
end

function _M.get_env(key, default)
    return _M.get("env", key, default)
end

-- Check if development mode is enabled
function _M.is_development_mode()
    local env = _M.get_env("environment", "production")
    return env == "development"
end

function _M.get_http_services()
    return _M.get("http_services") or {}
end

function _M.get_ssh_services()
    return _M.get("ssh_services") or {}
end

-- Parse duration string with suffixes (s, m, h, d)
local function parse_duration(env_val)
    local v = tostring(env_val or "")
    if v == "" then return nil end
    local num, unit = v:match("^(%d+)%s*([smhdSMHD]?)$")
    num = tonumber(num)
    if not num then return nil end
    unit = (unit or ""):lower()
    if unit == "" or unit == "s" then return num end
    if unit == "m" then return num * 60 end
    if unit == "h" then return num * 3600 end
    if unit == "d" then return num * 86400 end
    return nil
end

-- Generate a secure random session secret
local _session_secret_cache = nil
local function generate_session_secret()
    if _session_secret_cache then
        return _session_secret_cache
    end
    
    -- Generate 32 random bytes and encode as base64
    local random = require "resty.random"
    local str = require "resty.string"
    
    local bytes = random.bytes(32)
    if not bytes then
        logger.error("Failed to generate random session secret, using fallback")
        _session_secret_cache = "fallback-" .. ngx.time() .. "-" .. ngx.worker.pid()
        return _session_secret_cache
    end
    
    _session_secret_cache = str.to_hex(bytes)
    logger.info("Auto-generated session secret (will invalidate sessions on restart)")
    
    return _session_secret_cache
end

function _M.get_session_config()
    local env = config_cache.env or {}
    
    -- Auto-generate secret if not provided
    local secret = env.session_secret
    if not secret or secret == "" or secret == "your-secret-key-change-this-in-production" then
        secret = generate_session_secret()
    end
    
    -- Auto-detect secure flag based on HTTPS_ENABLED (or allow explicit override)
    local secure = env.session_secure
    if secure == nil then
        -- Default to true if HTTPS is enabled, false otherwise
        secure = env.https_enabled == true
    end
    
    -- Parse duration values with suffixes (s, m, h, d)
    local lifetime = parse_duration(env.session_lifetime) or 3600
    local rolling_timeout = parse_duration(env.session_rolling_timeout) or 300
    local max_idle_time = parse_duration(env.session_max_idle_time) or 7200
    local monitor_interval = parse_duration(env.session_monitor_interval) or 60
    local ssh_proxy_lifetime = parse_duration(env.ssh_proxy_session_lifetime) or 3600
    local http_proxy_lifetime = parse_duration(env.http_proxy_session_lifetime) or 3600
    
    return {
        secret = secret,
        domain = env.session_domain,
        secure = secure,
        lifetime = lifetime,
        rolling_timeout = rolling_timeout,
        max_per_user = env.session_max_per_user or 10,
        max_idle_time = max_idle_time,
        error_rate_threshold = env.session_error_rate_threshold or 0.1,
        monitor_interval = monitor_interval,
        log_retention_days = env.session_log_retention or 7,
        ssh_proxy_lifetime = ssh_proxy_lifetime,
        http_proxy_lifetime = http_proxy_lifetime
    }
end


-- Get OIDC configuration from environment variables only
function _M.get_oidc_config()
    local env = config_cache.env or {}
    
    return {
        enabled = env.oidc_enabled ~= false, -- Respect OIDC_ENABLED setting, default to true if not set
        discovery_url = env.oidc_discovery_url or "",
        base_url = env.oidc_base_url or "",
        realm = env.oidc_realm or "",
        admin_url = env.oidc_admin_url or "",
        client_id = env.oidc_client_id or "",
        client_secret = env.oidc_client_secret or "",
        backchannel_logout_enabled = env.oidc_backchannel_logout_enabled == true,
        show_oidc_menu = env.show_oidc_menu == true,
        ssl_verify = false, -- Default to false for development
        timeout = 10 -- Default timeout
    }
end

function _M.get_admin_oidc_config()
    if not _M.is_loaded() then
        return nil
    end
    
    return _M.get_oidc_config()
end

function _M.get_keycloak_admin_url()
    if not _M.is_loaded() then
        return nil
    end
    
    local env = config_cache.env or {}
    if env.oidc_admin_url and env.oidc_admin_url ~= "" then
        return env.oidc_admin_url
    end

    local oidc_config = _M.get_oidc_config()
    if not oidc_config then return nil end
    if oidc_config.base_url and oidc_config.base_url ~= "" then
        return tostring(oidc_config.base_url) .. "/admin"
    end
    if oidc_config.discovery_url and oidc_config.discovery_url ~= "" then
        local base_url = oidc_config.discovery_url:gsub("/realms/.*", "")
        return base_url .. "/admin"
    end
    return nil
end

function _M.get_all_services()
    local all_services = {}
    
    -- Add HTTP services
    for service_id, service in pairs(_M.get_http_services()) do
        all_services[service_id] = service
    end
    
    -- Add SSH services
    for service_id, service in pairs(_M.get_ssh_services()) do
        all_services[service_id] = service
    end
    
    return all_services
end

-- Check if configuration is loaded
function _M.is_loaded()
    return config_loaded
end

-- Reload configuration
function _M.reload()
    logger.info("Reloading configuration...")
    config_loaded = false
    config_cache = {}
    return _M.init()
end

-- Validate configuration
function _M.validate()
    local errors = {}
    
    -- Validate required global environment variables (deployment-specific)
    -- Note: session_secret is auto-generated if not provided
    local required_global_env = {"host", "port"}
    for _, key in ipairs(required_global_env) do
        if not _M.get_env(key) then
            table.insert(errors, "Missing required global environment variable: " .. ENV_MAPPINGS[key])
        end
    end
    
    -- Validate OIDC configuration (always required)
    local oidc_config = _M.get_oidc_config()
    -- Require client id/secret
    if not oidc_config.client_id or oidc_config.client_id == "" then
        table.insert(errors, "Missing required OIDC configuration 'client_id' - set OIDC_CLIENT_ID")
    end
    if not oidc_config.client_secret or oidc_config.client_secret == "" then
        table.insert(errors, "Missing required OIDC configuration 'client_secret' - set OIDC_CLIENT_SECRET")
    end
    -- Require either discovery URL, or base URL + realm
    local has_discovery = oidc_config.discovery_url and oidc_config.discovery_url ~= ""
    local has_base_and_realm = (oidc_config.base_url and oidc_config.base_url ~= "") and (oidc_config.realm and oidc_config.realm ~= "")
    if not has_discovery and not has_base_and_realm then
        table.insert(errors, "Missing OIDC endpoints. Set OIDC_DISCOVERY_URL or both OIDC_BASE_URL and OIDC_REALM")
    end
    
    -- Validate that service configurations exist
    local http_services = _M.get_http_services()
    local ssh_services = _M.get_ssh_services()
    
    if not http_services and not ssh_services then
        table.insert(errors, "No services configured - define services in http-services.json, ssh-services.json, or services.json")
    end
    
    return #errors == 0, errors
end

function _M.get_summary()
    if not config_loaded then
        return "Configuration not loaded"
    end
    
    return {
        environment_vars = _M._count_keys(config_cache.env),
        http_services = _M._count_keys(config_cache.http_services),
        ssh_services = _M._count_keys(config_cache.ssh_services),
        oidc_enabled = true, -- OIDC is always enabled
        auth_enabled = true  -- Auth is always enabled
    }
end

-- Count keys in a table
function _M._count_keys(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- Log configuration summary
function _M._log_config_summary()
    local summary = _M.get_summary()
    local env = config_cache.env or {}
    
    logger.info(string.format(
        "Configuration Summary - Environment: %d vars, File-based Services: %d HTTP + %d SSH, OIDC: %s, Auth: %s",
        summary.environment_vars,
        summary.http_services,
        summary.ssh_services,
        summary.oidc_enabled and "enabled" or "disabled",
        summary.auth_enabled and "enabled" or "disabled"
    ))
    
    -- Log network configuration details
    local scheme = (env.https_enabled and env.https_enabled == true) and "https" or "http"
    local external_port = env.port or "unknown"
    local internal_port = "8080"  -- nginx always runs on port 8080 internally
    logger.info(string.format("Network: %s://%s:%s (external), internal port: %s (HTTPS: %s)", 
        scheme, env.host or "unknown", external_port, internal_port,
        env.https_enabled and "enabled" or "disabled"))
    
    -- Log OIDC configuration details
    local oidc_config = _M.get_oidc_config()
    if oidc_config.enabled then
        logger.info(string.format("OIDC: %s (realm: %s, client: %s)", 
            oidc_config.discovery_url or "discovery URL not set",
            oidc_config.realm or "unknown",
            oidc_config.client_id or "unknown"))
        if env.oidc_redirect_uri then
            logger.info("OIDC Redirect URI: " .. env.oidc_redirect_uri)
        end
    end
    
    -- Log session configuration
    local session_config = _M.get_session_config()
    logger.info(string.format("Sessions: lifetime=%ds, rolling_timeout=%ds, max_per_user=%d, secure=%s", 
        session_config.lifetime, session_config.rolling_timeout, session_config.max_per_user,
        session_config.secure and "true" or "false"))
    
    -- Log SSL configuration if HTTPS is enabled
    if env.https_enabled and env.https_enabled == true then
        logger.info(string.format("SSL: cert=%s, key=%s", 
            os.getenv("SSL_CERT_PATH") or "not set",
            os.getenv("SSL_KEY_PATH") or "not set"))
    end
    
    -- Log monitoring configuration
    if env.monitoring_retention or env.monitoring_cleanup_interval then
        logger.info(string.format("Monitoring: retention=%s, cleanup_interval=%s", 
            env.monitoring_retention or "default",
            env.monitoring_cleanup_interval or "default"))
    end
end

return _M
