-- System Initialization

local _M = {}
local logger = require "utils.logger"

local init_state = {
    config_manager = false,
    models = false,
    auth = false,
    services = false,
    sessions = false,
    system_ready = false
}

function _M.init()
    pcall(function()
        if logger and logger.reload_from_env then logger.reload_from_env() end
    end)
    logger.info("Starting system initialization...")
    
    local start_time = ngx.now()
    local success = true
    
    success = success and _M._init_config_manager()
    success = success and _M._validate_configuration()
    success = success and _M._init_models()
    success = success and _M._init_auth_system()
    success = success and _M._init_services()
    success = success and _M._init_sessions()
    
    local duration = ngx.now() - start_time
    
    if success then
        init_state.system_ready = true
        logger.info(string.format("System initialized successfully in %.3fs", duration))
        _M._log_system_status()
        
        pcall(function()
            local monitoring = require "monitoring.init"
            if monitoring and monitoring.record then
                monitoring.record({
                    flow = "system",
                    action = "startup",
                    status = "success",
                    description = "Jump server system startup completed",
                    metadata = {
                        duration = duration,
                        components = init_state
                    }
                })
            end
        end)
    else
        logger.error(string.format("System initialization failed after %.3fs", duration))
        _M._log_failure_state()
        
        pcall(function()
            local monitoring = require "monitoring.init"
            if monitoring and monitoring.record then
                monitoring.record({
                    flow = "system",
                    action = "startup",
                    status = "failed",
                    description = "Jump server system startup failed",
                    metadata = {
                        duration = duration,
                        components = init_state
                    }
                })
            end
        end)
    end
    
    return success
end

function _M._init_config_manager()
    logger.debug("Initializing configuration manager...")
    
    local config_manager = require "config.manager"
    local success = config_manager.init()
    
    if success then
        init_state.config_manager = true
        local summary = config_manager.get_summary()
        logger.info(string.format("Config loaded: %d env vars, %d HTTP + %d SSH file-based services",
            summary.environment_vars, summary.http_services, summary.ssh_services))
    else
        logger.error("Failed to initialize configuration manager")
    end
    
    return success
end

function _M._validate_configuration()
    logger.debug("Validating configuration...")
    
    local config_manager = require "config.manager"
    local valid, errors = config_manager.validate()
    
    if not valid then
        logger.warn("Configuration validation warnings (continuing with defaults):")
        for _, error in ipairs(errors) do
            logger.warn("  - " .. error)
        end
    end
    
    return true
end

function _M._init_models()
    logger.debug("Initializing database models...")
    
    local models = require "models.init"
    local success = models.init_db()
    
    if success then
        success = models.init_models()
        if success then
            init_state.models = true
            logger.debug("Database initialized")
        else
            logger.error("Failed to initialize default roles")
        end
    else
        logger.error("Failed to initialize database")
    end
    
    return success
end

function _M._init_auth_system()
    logger.debug("Initializing authentication system...")
    
    local config_manager = require "config.manager"
    local auth_enabled = config_manager.get_env("auth_enabled", true)
    
    if not auth_enabled then
        logger.warn("Authentication disabled by configuration")
        init_state.auth = true
        return true
    end
    
    local auth = require "auth.init"
    
    local auth_success = auth.init()
    if auth_success then
        init_state.auth = true
        logger.info("Authentication system ready")
    else
        logger.error("Failed to initialize authentication system")
    end
    
    return auth_success
end

function _M._init_services()
    logger.debug("Initializing services...")
    
    local http_services_manager = require "services.http_services_manager"
    local ssh_services_manager = require "services.ssh_services_manager"
    local config_manager = require "config.manager"
    
    local http_success = http_services_manager.init()
    if not http_success then
        logger.error("Failed to initialize HTTP services manager")
        return false
    end
    
    local ssh_success = ssh_services_manager.init()
    if not ssh_success then
        logger.error("Failed to initialize SSH services manager")
        return false
    end
    
    local http_services = http_services_manager.load_enabled_http_services()
    local ssh_services = ssh_services_manager.load_enabled_ssh_services()
    local http_count = _M._count_enabled_services(http_services)
    local ssh_count = _M._count_enabled_services(ssh_services)
    
    init_state.services = true
    logger.info(string.format("Services ready: %d HTTP + %d SSH", http_count, ssh_count))
    
    _M._log_service_details(http_services, ssh_services)
    
    return true
end

function _M._init_sessions()
    logger.debug("Initializing session management...")
    
    local sessions = require "sessions.init"
    local session_success = sessions.init()
    
    if session_success then
        init_state.sessions = true
        logger.info("Session management ready")
    else
        logger.error("Failed to initialize session management")
    end
    
    return session_success
end

function _M.init_worker()
    logger.debug("Initializing worker components...")
    
    if not init_state.system_ready then
        logger.error("Cannot initialize worker - system not ready")
        return false
    end
    
    local sessions = require "sessions.init"
    local worker_success = true
    if sessions.init_worker then
        worker_success = sessions.init_worker()
    end
    
    if worker_success then
        logger.debug("Worker components ready")
    else
        logger.error("Failed to initialize worker components")
    end

    pcall(function()
        local monitoring = require "monitoring.init"
        if monitoring and monitoring.setup_rotation_timer then
            monitoring.setup_rotation_timer()
        end
    end)
    
    return worker_success
end

function _M.get_init_state()
    return init_state
end

function _M.is_system_ready()
    return init_state.system_ready
end

function _M.get_config_manager()
    if not init_state.config_manager then
        logger.warn("Configuration manager not initialized")
        return nil
    end
    return require "config.manager"
end

function _M._count_enabled_services(services)
    local count = 0
    for _, service in pairs(services or {}) do
        if service.enabled then
            count = count + 1
        end
    end
    return count
end

function _M._log_service_details(http_services, ssh_services)
    if http_services and next(http_services) then
        logger.info("HTTP Services:")
        for service_id, service in pairs(http_services) do
            if service.enabled then
                local source_info = service.source and string.format(" [%s]", service.source) or ""
                logger.info(string.format("  - %s: %s (%s)%s", 
                    service.name or service_id, 
                    service.url or "no URL", 
                    service.description or "no description",
                    source_info))
            end
        end
    end
    
    if ssh_services and next(ssh_services) then
        logger.info("SSH Services:")
        for service_id, service in pairs(ssh_services) do
            if service.enabled then
                local source_info = service.source and string.format(" [%s]", service.source) or ""
                logger.info(string.format("  - %s: %s:%d (%s)%s", 
                    service.name or service_id, 
                    service.host or "no host", 
                    service.port or 22, 
                    service.description or "no description",
                    source_info))
            end
        end
    end
end

function _M._log_system_status()
    local config_manager = require "config.manager"
    local summary = config_manager.get_summary()
    local env = config_manager.get_env()
    
    local http_services_manager = require "services.http_services_manager"
    local ssh_services_manager = require "services.ssh_services_manager"
    local http_services = http_services_manager.load_enabled_http_services()
    local ssh_services = ssh_services_manager.load_enabled_ssh_services()
    local http_count = _M._count_enabled_services(http_services)
    local ssh_count = _M._count_enabled_services(ssh_services)
    
    local scheme = (env.https_enabled and env.https_enabled == true) and "https" or "http"
    local external_port = env.port or "unknown"
    
    logger.info(string.format("System ready - Env: %s, Host: %s://%s:%s (external), Auth: %s, OIDC: %s, Services: %d HTTP + %d SSH",
        env.environment or "unknown",
        scheme,
        env.host or "unknown",
        external_port,
        summary.auth_enabled and "enabled" or "disabled",
        summary.oidc_enabled and "enabled" or "disabled",
        http_count, ssh_count))
end

function _M._log_failure_state()
    logger.error("=== Initialization State ===")
    for component, status in pairs(init_state) do
        logger.error(string.format("%s: %s", component, status and "OK" or "FAILED"))
    end
    logger.error("===========================")
end

function _M.get_health_status()
    return {
        system_ready = init_state.system_ready,
        components = init_state,
        config_loaded = init_state.config_manager,
        uptime = ngx.time() - (ngx.shared.startup_time or ngx.time())
    }
end

return _M
