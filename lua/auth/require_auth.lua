-- Authentication Requirement

local data_utils = require "utils.data_utils"
data_utils.ensure_session_uid()

if ngx.var.auth_skip == "1" then
    return
end

local auth_service = require "auth.auth_service"
local ok = auth_service.require_authentication()
if not ok then
    return
end


