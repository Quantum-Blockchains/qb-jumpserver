-- Service Access Base Handler

local auth_service = require "auth.auth_service"
local web_utils = require "utils.web_utils"
local logger = require "utils.logger"

local _M = {}

function _M.handle_service_access(service_id, service_type, service_manager)
    local ok = auth_service.require_service_access(service_id, service_type)
    if not ok then
        return nil
    end
    
    local user = auth_service.get_current_user()
    if not user then
        return web_utils.handle_auth_error()
    end
    
    local service
    if service_type == "http" then
        service = service_manager.get_http_service(service_id)
    elseif service_type == "ssh" then
        service = service_manager.get_ssh_service(service_id)
    else
        logger.error("Unknown service type: " .. tostring(service_type))
        return web_utils.handle_error_response(500, "Invalid service type")
    end
    
    if not service or not service.enabled then
        return web_utils.handle_service_not_found()
    end
    
    local session, err
    if service_type == "http" then
        session, err = service_manager.get_or_create_http_proxy_session(user.user_id, service_id)
    elseif service_type == "ssh" then
        -- Prefer reusing an existing session for the same user+service to avoid duplicate state logs
        if service_manager.get_or_create_ssh_proxy_session then
            session, err = service_manager.get_or_create_ssh_proxy_session(user.user_id, service_id)
        else
            session, err = service_manager.create_new_ssh_proxy_session(user.user_id, service_id)
        end
    end
    
    if not session then
        logger.error("Failed to get/create proxy session: " .. (err or "unknown error"))
        
        -- Log service access failure
        pcall(function()
            local monitoring = require "monitoring.init"
            if monitoring and monitoring.record then
                monitoring.record({
                    flow = service_type,
                    action = "access",
                    status = "failed",
                    service_id = service_id,
                    service_type = service_type,
                    description = "Failed to create proxy session",
                    metadata = {
                        error = err or "unknown error",
                        user_id = user.user_id
                    }
                })
            end
        end)
        
        return web_utils.handle_session_error()
    end
    
    pcall(function()
        local monitoring = require "monitoring.init"
        if monitoring and monitoring.record then
            monitoring.record({
                flow = service_type,
                action = "access",
                status = "success",
                service_id = service_id,
                service_type = service_type,
                description = "Service access granted",
                metadata = {
                    session_id = session.session_id,
                    user_id = user.user_id,
                    service_name = service.name
                }
            })
        end
    end)
    
    return session, service
end

function _M.validate_service(service_id, service_type, service_manager)
    local service
    if service_type == "http" then
        service = service_manager.get_http_service(service_id)
    elseif service_type == "ssh" then
        service = service_manager.get_ssh_service(service_id)
    end
    
    if not service or not service.enabled then
        return nil, "Service not found or disabled"
    end
    return service
end

function _M.get_or_create_session(user_id, service_id, service_type, service_manager)
    local session, err
    if service_type == "http" then
        session, err = service_manager.get_or_create_http_proxy_session(user_id, service_id)
    elseif service_type == "ssh" then
        session, err = service_manager.create_new_ssh_proxy_session(user_id, service_id)
    end
    
    if not session then
        logger.error("Failed to get/create proxy session: " .. (err or "unknown error"))
        return nil, err
    end
    return session
end

return _M
