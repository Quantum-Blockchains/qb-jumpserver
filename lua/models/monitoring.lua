-- Monitoring Model

local cjson = require "cjson"
local db = require("models.init")
local data_utils = require("utils.data_utils")
local logger = require "utils.logger"

local _M = {}

-- Delete events older than given number of seconds
function _M.delete_older_than(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds <= 0 then
        return false, "invalid retention seconds"
    end
    -- Calculate cutoff epoch in Lua to avoid SQL time function ambiguities
    local now_epoch = (ngx and ngx.time()) or os.time()
    local cutoff_epoch = now_epoch - seconds
    local sql = [[
        DELETE FROM monitoring_events
        WHERE timestamp < ?
    ]]
    local ok, err = db.execute(sql, { cutoff_epoch })
    if not ok then
        return false, err or "delete failed"
    end
    local rows = db.query("SELECT changes() AS cnt")
    local deleted = 0
    if rows and rows[1] and rows[1].cnt then
        deleted = tonumber(rows[1].cnt) or 0
    end
    return true, deleted
end

function _M.count_deletable(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return 0 end
    local now_epoch = (ngx and ngx.time()) or os.time()
    local cutoff_epoch = now_epoch - seconds
    local sql = [[
        SELECT COUNT(*) AS cnt
        FROM monitoring_events
        WHERE timestamp < ?
    ]]
    local rows, err = db.query(sql, { cutoff_epoch })
    if not rows or not rows[1] then return 0 end
    return tonumber(rows[1].cnt) or 0
end

function _M.insert_event(event)
    local sql = [[
        INSERT INTO monitoring_events (
            timestamp, flow, action, status, user_id, username, ip,
            service_id, service_type, request_method, request_uri,
            session_id, description, metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]

    local metadata_json = nil
    if event.metadata then
        if type(event.metadata) == "table" then
            metadata_json = cjson.encode(event.metadata)
        else
            metadata_json = tostring(event.metadata)
        end
    end

    local params = {
        event.timestamp or (ngx and ngx.time() or os.time()),
        event.flow or "unknown",
        event.action or nil,
        event.status or nil,
        event.user_id or nil,
        event.username or nil,
        event.ip or ngx.var.remote_addr,
        event.service_id or nil,
        event.service_type or nil,
        event.request_method or ngx.req.get_method(),
        event.request_uri or ngx.var.request_uri,
        event.session_id or nil,
        event.description or nil,
        metadata_json
    }

    local success, err = db.execute(sql, params)
    if not success then
        logger.error("Failed to insert monitoring event:", (err or "unknown error"))
        return nil, err
    end
    return db.last_insert_rowid()
end

function _M.list_events(opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 100
    if limit > 1000 then limit = 1000 end
    local offset = tonumber(opts.offset) or 0

    local conditions = {}
    local params = {}
    local q = opts.q
    local q_like
    if q and q ~= "" then
        q = tostring(q)
        q_like = "%" .. q .. "%"
    end

    if opts.flow and opts.flow ~= "" then
        table.insert(conditions, "flow = ?")
        table.insert(params, opts.flow)
    end
    if opts.user_id and opts.user_id ~= "" then
        table.insert(conditions, "user_id = ?")
        table.insert(params, opts.user_id)
    end
    if opts.action and opts.action ~= "" then
        table.insert(conditions, "action = ?")
        table.insert(params, opts.action)
    end
    if opts.session_id and opts.session_id ~= "" then
        table.insert(conditions, "session_id = ?")
        table.insert(params, opts.session_id)
    end
    if opts.status and opts.status ~= "" then
        table.insert(conditions, "status = ?")
        table.insert(params, opts.status)
    end

    if opts.since_epoch and tonumber(opts.since_epoch) then
        table.insert(conditions, "timestamp >= ?")
        table.insert(params, tonumber(opts.since_epoch))
    end
    if opts.until_epoch and tonumber(opts.until_epoch) then
        table.insert(conditions, "timestamp <= ?")
        table.insert(params, tonumber(opts.until_epoch))
    end

    if q_like then
        table.insert(conditions, "(flow LIKE ? OR action LIKE ? OR status LIKE ? OR user_id LIKE ? OR username LIKE ? OR ip LIKE ? OR request_method LIKE ? OR request_uri LIKE ? OR description LIKE ? OR metadata LIKE ? OR session_id LIKE ? OR service_id LIKE ? OR service_type LIKE ?)")
        for _ = 1, 13 do table.insert(params, q_like) end
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = " WHERE " .. table.concat(conditions, " AND ")
    end

    local sql = [[
        SELECT id, timestamp, flow, action, status, user_id, username, ip,
               service_id, service_type, request_method, request_uri, session_id, description, metadata
        FROM monitoring_events
    ]] .. where_clause .. " ORDER BY timestamp DESC LIMIT ? OFFSET ?"

    table.insert(params, limit)
    table.insert(params, offset)

    local rows, err = db.query(sql, params)
    if not rows then
        return nil, err
    end

    for _, row in ipairs(rows) do
        if row.metadata then
            local ok, decoded = pcall(cjson.decode, row.metadata)
            if ok then
                row.metadata = decoded
            end
        end
    end

    return rows
end

function _M.list_events_grouped(opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 100
    if limit > 1000 then limit = 1000 end
    local offset = tonumber(opts.offset) or 0

    local conditions = {}
    local params = {}
    local q = opts.q
    local q_like
    if q and q ~= "" then
        q = tostring(q)
        q_like = "%" .. q .. "%"
    end

    if opts.flow and opts.flow ~= "" then
        table.insert(conditions, "flow = ?")
        table.insert(params, opts.flow)
    end
    if opts.user_id and opts.user_id ~= "" then
        table.insert(conditions, "user_id = ?")
        table.insert(params, opts.user_id)
    end
    if opts.action and opts.action ~= "" then
        table.insert(conditions, "action = ?")
        table.insert(params, opts.action)
    end
    if opts.session_id and opts.session_id ~= "" then
        table.insert(conditions, "session_id = ?")
        table.insert(params, opts.session_id)
    end
    if opts.status and opts.status ~= "" then
        table.insert(conditions, "status = ?")
        table.insert(params, opts.status)
    end
    
    if opts.since_epoch and tonumber(opts.since_epoch) then
        table.insert(conditions, "timestamp >= ?")
        table.insert(params, tonumber(opts.since_epoch))
    end
    if opts.until_epoch and tonumber(opts.until_epoch) then
        table.insert(conditions, "timestamp <= ?")
        table.insert(params, tonumber(opts.until_epoch))
    end
    if q_like then
        table.insert(conditions, "(flow LIKE ? OR action LIKE ? OR status LIKE ? OR user_id LIKE ? OR username LIKE ? OR ip LIKE ? OR request_method LIKE ? OR request_uri LIKE ? OR description LIKE ? OR metadata LIKE ? OR session_id LIKE ? OR service_id LIKE ? OR service_type LIKE ?)")
        for _ = 1, 13 do table.insert(params, q_like) end
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = " WHERE " .. table.concat(conditions, " AND ")
    end

    local count_sql = [[
        SELECT COUNT(*) AS group_count FROM (
            SELECT CASE WHEN session_id IS NULL OR session_id = '' THEN '' ELSE session_id END AS sid
            FROM monitoring_events
    ]] .. where_clause .. [[
            GROUP BY sid
        ) AS grouped
    ]]

    local count_rows, count_err = db.query(count_sql, params)
    if not count_rows then
        return nil, count_err
    end
    local total_groups = 0
    if count_rows[1] and count_rows[1].group_count then
        total_groups = tonumber(count_rows[1].group_count) or 0
    end

    local page_sql = [[
        SELECT sid, MAX(timestamp) AS last_ts, MIN(timestamp) AS first_ts, COUNT(*) AS event_count
        FROM (
            SELECT CASE WHEN session_id IS NULL OR session_id = '' THEN '' ELSE session_id END AS sid, *
            FROM monitoring_events
    ]] .. where_clause .. [[
        ) AS t
        GROUP BY sid
        ORDER BY last_ts DESC
        LIMIT ? OFFSET ?
    ]]

    local page_params = {}
    for i = 1, #params do page_params[i] = params[i] end
    table.insert(page_params, limit)
    table.insert(page_params, offset)

    local group_rows, page_err = db.query(page_sql, page_params)
    if not group_rows then
        return nil, page_err
    end

    local groups = {}
    for _, g in ipairs(group_rows) do
        local sid = g.sid or ""
        local per_params = {}
        for i = 1, #params do per_params[i] = params[i] end
        local per_where = where_clause
        if sid == "" then
            if per_where == "" then per_where = " WHERE (session_id IS NULL OR session_id = '')" else per_where = per_where .. " AND (session_id IS NULL OR session_id = '')" end
        else
            if per_where == "" then per_where = " WHERE session_id = ?" else per_where = per_where .. " AND session_id = ?" end
            table.insert(per_params, sid)
        end

        local events_sql = [[
            SELECT id, timestamp, flow, action, status, user_id, username, ip,
                   service_id, service_type, request_method, request_uri, session_id, description, metadata
            FROM monitoring_events
        ]] .. per_where .. " ORDER BY timestamp DESC"

        local rows, per_err = db.query(events_sql, per_params)
        if not rows then
            return nil, per_err
        end

        for _, row in ipairs(rows) do
            if row.metadata then
                local ok, decoded = pcall(cjson.decode, row.metadata)
                if ok then
                    row.metadata = decoded
                end
            end
        end

        table.insert(groups, {
            session_id = sid ~= "" and sid or nil,
            first_timestamp = g.first_ts,
            last_timestamp = g.last_ts,
            count = tonumber(g.event_count) or #rows,
            events = rows
        })
    end

    return { groups = groups, total_groups = total_groups }
end

return _M


