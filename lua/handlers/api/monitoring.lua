-- Monitoring API Handler

local api_router = require("handlers.api_router")
local monitoring = require("monitoring.init")

local _M = {}

function _M.list_events()
    local limit = tonumber(ngx.var.arg_limit) or 100
    local offset = tonumber(ngx.var.arg_offset) or 0
    local flow = ngx.var.arg_flow
    local user_id = ngx.var.arg_user_id
    local action = ngx.var.arg_action
    local status = ngx.var.arg_status
    -- Only use epoch timestamps now
    local session_id = ngx.var.arg_session_id
    local grouped = ngx.var.arg_grouped == "true" or ngx.var.arg_grouped == "1"
    local q = ngx.var.arg_q
    -- Accept both snake_case and camelCase for compatibility with any UI
    local since_epoch = tonumber(ngx.var.arg_since_epoch or ngx.var.arg_sinceEpoch)
    local until_epoch = tonumber(ngx.var.arg_until_epoch or ngx.var.arg_untilEpoch)

    local data, err
    if grouped then
        data, err = monitoring.list_grouped({
            limit = limit,
            offset = offset,
            flow = flow,
            user_id = user_id,
            action = action,
            status = status,
            -- No string-based datetime filtering
            session_id = session_id,
            q = q,
            since_epoch = since_epoch,
            until_epoch = until_epoch
        })
    else
        data, err = monitoring.list({
            limit = limit,
            offset = offset,
            flow = flow,
            user_id = user_id,
            action = action,
            status = status,
            -- No string-based datetime filtering
            session_id = session_id,
            q = q,
            since_epoch = since_epoch,
            until_epoch = until_epoch
        })
    end

    if not data then
        return api_router.send_response(500, false, nil, err or "Failed to load monitoring events")
    end

    if grouped then
        return api_router.send_response(200, true, {
            groups = data.groups or {},
            total_groups = data.total_groups or 0,
            limit = limit,
            offset = offset,
            grouped = true
        })
    else
        return api_router.send_response(200, true, {
            events = data,
            count = #data,
            limit = limit,
            offset = offset,
            grouped = false
        })
    end
end

return _M


