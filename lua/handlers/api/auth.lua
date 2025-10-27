-- Auth API Handler

local auth_service = require "auth.auth_service"
local api_router = require "handlers.api_router"

local _M = {}

function _M.get_session()
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "No active session")
    end
    
    local session_info = {}
    local auth_session = auth_service.get_current_auth_session()
    if auth_session then
        session_info = {
            session_id = auth_session.session_id,
            created_at = auth_session.created_at and os.date("%Y-%m-%d %H:%M:%S", auth_session.created_at) or nil,
            last_activity = auth_session.last_activity and os.date("%Y-%m-%d %H:%M:%S", auth_session.last_activity) or nil,
            expires_at = auth_session.expires_at and os.date("%Y-%m-%d %H:%M:%S", auth_session.expires_at) or nil
        }
    end
    
    return api_router.send_response(200, true, {
        user = user,
        session = session_info,
        is_admin = auth_service.is_admin(user)
    })
end

function _M.logout()
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(200, true, {message = "No active session to logout"})
    end
    
    local result = auth_service.logout_user()
    if result and result.success then
        return api_router.send_response(200, true, {message = "Logged out successfully"})
    else
        return api_router.send_response(500, false, nil, result and result.error or "Logout failed")
    end
end

-- Get user permissions
function _M.get_permissions()
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    local permissions = auth_service.get_user_permissions(user)
    local roles = auth_service.get_user_roles(user)
    
    return api_router.send_response(200, true, {
        permissions = permissions or {},
        roles = roles or {},
        is_admin = auth_service.is_admin(user)
    })
end

function _M.refresh_user_data()
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    local permissions = auth_service.get_user_permissions(user)
    local roles = auth_service.get_user_roles(user)
    
    return api_router.send_response(200, true, {
        message = "User data retrieved successfully",
        user = user,
        permissions = permissions or {},
        roles = roles or {},
        is_admin = auth_service.is_admin(user)
    })
end

function _M.get_oidc_status()
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    -- Check if user has admin privileges
    if not auth_service.has_permission(user, "jumpserver:admin") then
        return api_router.send_response(403, false, nil, "Admin privileges required")
    end
    
    local config_manager = require "config.manager"
    local oidc_config = config_manager.get_admin_oidc_config()
    
    return api_router.send_response(200, true, {
        oidc_config = oidc_config,
        timestamp = ngx.time()
    })
end

function _M.get_frontend_config()
    local config_manager = require "config.manager"
    
    return api_router.send_response(200, true, {
        title = config_manager.get_env("jump_server_title") or "Jump Server"
    })
end

function _M.get_system_status()
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    -- Check if user has admin privileges
    if not auth_service.has_permission(user, "jumpserver:admin") then
        return api_router.send_response(403, false, nil, "Admin privileges required")
    end
    
    local config_manager = require "config.manager"
    local summary = config_manager.get_summary()
    
    return api_router.send_response(200, true, {
        system_status = summary,
        timestamp = ngx.time()
    })
end

return _M