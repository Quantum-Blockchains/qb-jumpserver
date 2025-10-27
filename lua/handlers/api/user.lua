-- User API Handlers

local cjson = require "cjson"
local api_router = require "handlers.api_router"
local web_utils = require "utils.web_utils"
local data_utils = require "utils.data_utils"

local _M = {}

function _M.user_get_profile()
    local auth_service = require "auth.auth_service"
    
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    local profile = {
        user_id = user.user_id,
        email = user.email,
        name = user.name,
        created_at = user.created_at and os.date("%Y-%m-%d %H:%M:%S", user.created_at) or nil,
        last_login = user.last_login and os.date("%Y-%m-%d %H:%M:%S", user.last_login) or nil,
        preferences = user.preferences or {}
    }
    
    return api_router.send_response(200, true, profile)
end

function _M.user_update_profile()
    local auth_service = require "auth.auth_service"
    
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    local profile_data, err = api_router.parse_json_body()
    if not profile_data then
        return api_router.send_response(400, false, nil, err)
    end
    
    local allowed_fields = {
        name = true,
        preferences = true
    }
    
    local updated_profile = {}
    for field, value in pairs(profile_data) do
        if allowed_fields[field] then
            updated_profile[field] = value
        end
    end
    
    if next(updated_profile) == nil then
        return api_router.send_response(400, false, nil, "No valid fields to update")
    end
    
    local profile = {
        user_id = user.user_id,
        email = user.email,
        name = updated_profile.name or user.name,
        preferences = updated_profile.preferences or user.preferences or {},
        updated_at = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    return api_router.send_response(200, true, profile, "Profile updated successfully")
end

return _M
