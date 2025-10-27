-- Database Models Initialization

local sqlite3 = require "lsqlite3"
local cjson = require "cjson"
local logger = require "utils.logger"

local _M = {}

local db_connection = nil

function _M.init_db()
    if db_connection then
        return true
    end
    
    local db_path = "/app/data/jump_server.db"
    
    logger.debug("Initializing database at: " .. db_path)
    
    os.execute("mkdir -p /app/data")
    
    local db, err = sqlite3.open(db_path)
    if not db then
        logger.error("Failed to open SQLite database at " .. db_path .. ": " .. (err or "unknown error"))
        return false
    end
    
    local pragmas = {
        "PRAGMA foreign_keys = ON",
        "PRAGMA journal_mode = WAL",
        "PRAGMA synchronous = NORMAL",
        "PRAGMA busy_timeout = 30000",
        "PRAGMA wal_autocheckpoint = 1000",
        "PRAGMA cache_size = 10000",
        "PRAGMA temp_store = MEMORY"
    }
    
    for _, pragma in ipairs(pragmas) do
        local result = db:exec(pragma)
        if result ~= sqlite3.OK then
            logger.warn("Failed to execute " .. pragma .. ": " .. db:errmsg())
        else
            logger.debug("Executed: " .. pragma)
        end
    end
    
    local test_query = "SELECT 1"
    local stmt = db:prepare(test_query)
    if not stmt then
        logger.error("Failed to prepare test query: " .. db:errmsg())
        db:close()
        return false
    end
    stmt:finalize()
    
    db_connection = db
    logger.debug("SQLite database connection established")
    
    local tables_result = _M.create_tables()
    if not tables_result then
        logger.error("Failed to create database tables")
        return false
    end
    
    local function ensure_column(table_name, column_def)
        local db = db_connection
        local col_name = column_def:match("^(%w+)")
        local pragma_sql = string.format("PRAGMA table_info(%s)", table_name)
        local exists = false
        for row in db:nrows(pragma_sql) do
            if row and row.name == col_name then
                exists = true
                break
            end
        end
        if exists then return end
        local alter_sql = string.format("ALTER TABLE %s ADD COLUMN %s", table_name, column_def)
        local res = db:exec(alter_sql)
        if res ~= sqlite3.OK then
            local err = db:errmsg() or "unknown error"
            if err:lower():find("duplicate column name") then
                -- Column already exists (race condition between master/worker initializations)
                logger.debug("Column " .. col_name .. " already exists on " .. table_name .. ", skipping")
                return
            end
            -- Double-check after error if column now exists (race condition)
            for row in db:nrows(pragma_sql) do
                if row and row.name == col_name then
                    logger.debug("Column " .. col_name .. " appeared after error on " .. table_name .. ", skipping")
                    return
                end
            end
            logger.error("Failed to add column " .. column_def .. " to " .. table_name .. ": " .. err)
        else
            logger.info("Added column " .. column_def .. " to " .. table_name)
        end
    end
    
    ensure_column("http_services", "custom_rules TEXT")
    
    logger.debug("Database initialized successfully")
    return true
end

function _M.get_db()
    if not db_connection then
        local init_success = _M.init_db()
        if not init_success then
            logger.error("Failed to initialize database connection")
            return nil
        end
    end
    
    if db_connection then
        local test_stmt = db_connection:prepare("SELECT 1")
        if not test_stmt then
            logger.warn("Database connection lost, reinitializing...")
            db_connection:close()
            db_connection = nil
            local init_success = _M.init_db()
            if not init_success then
                logger.error("Failed to reinitialize database connection")
                return nil
            end
        else
            test_stmt:finalize()
        end
    end
    
    return db_connection
end

function _M.create_tables()
    if not db_connection then
        logger.error("Database connection not available")
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS http_services (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'http',
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            protocol TEXT NOT NULL DEFAULT 'http',
            url TEXT,
            path TEXT DEFAULT '/',
            enabled BOOLEAN NOT NULL DEFAULT 1,
            valid BOOLEAN NOT NULL DEFAULT 1,
            description TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            source TEXT DEFAULT 'database',
            config_hash TEXT
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create http_services table: " .. db_connection:errmsg())
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action TEXT NOT NULL,
            table_name TEXT NOT NULL,
            record_id TEXT,
            old_values TEXT,
            new_values TEXT,
            user_id TEXT,
            ip_address TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create audit_log table: " .. db_connection:errmsg())
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS ssh_services (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'ssh',
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            enabled BOOLEAN NOT NULL DEFAULT 1,
            description TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            source TEXT DEFAULT 'database',
            config_hash TEXT
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create ssh_services table: " .. db_connection:errmsg())
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS roles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            description TEXT,
            permissions TEXT,
            enabled BOOLEAN NOT NULL DEFAULT 1,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create roles table: " .. db_connection:errmsg())
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS monitoring_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp INTEGER DEFAULT (strftime('%s', 'now')),
            flow TEXT NOT NULL,
            action TEXT,
            status TEXT,
            user_id TEXT,
            username TEXT,
            ip TEXT,
            service_id TEXT,
            service_type TEXT,
            request_method TEXT,
            request_uri TEXT,
            session_id TEXT,
            description TEXT,
            metadata TEXT
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create monitoring_events table: " .. db_connection:errmsg())
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS service_permissions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            service_id TEXT NOT NULL,
            service_type TEXT NOT NULL DEFAULT 'http',
            role_id TEXT,
            group_name TEXT,
            permission_type TEXT NOT NULL DEFAULT 'allow',
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT chk_permission_target CHECK (role_id IS NOT NULL OR group_name IS NOT NULL),
            CONSTRAINT chk_permission_type CHECK (permission_type IN ('allow', 'deny'))
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create service_permissions table: " .. db_connection:errmsg())
        return false
    end
    
    local sql = [[
        CREATE TABLE IF NOT EXISTS user_role_overrides (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            service_id TEXT NOT NULL,
            service_type TEXT NOT NULL DEFAULT 'http',
            permission_type TEXT NOT NULL DEFAULT 'allow',
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(user_id, service_id, service_type)
        )
    ]]
    
    local result = db_connection:exec(sql)
    if result ~= sqlite3.OK then
        logger.error("Failed to create user_role_overrides table: " .. db_connection:errmsg())
        return false
    end

    local indexes = {
        "CREATE INDEX IF NOT EXISTS idx_http_services_enabled ON http_services(enabled)",
        "CREATE INDEX IF NOT EXISTS idx_http_services_source ON http_services(source)",
        "CREATE INDEX IF NOT EXISTS idx_ssh_services_enabled ON ssh_services(enabled)",
        "CREATE INDEX IF NOT EXISTS idx_ssh_services_source ON ssh_services(source)",
        "CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at)",
        "CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action)",
        "CREATE INDEX IF NOT EXISTS idx_audit_log_table_name ON audit_log(table_name)",
        "CREATE INDEX IF NOT EXISTS idx_roles_enabled ON roles(enabled)",
        "CREATE INDEX IF NOT EXISTS idx_roles_name ON roles(name)",
        "CREATE INDEX IF NOT EXISTS idx_service_permissions_service_id ON service_permissions(service_id)",
        "CREATE INDEX IF NOT EXISTS idx_service_permissions_role_id ON service_permissions(role_id)",
        "CREATE INDEX IF NOT EXISTS idx_service_permissions_group_name ON service_permissions(group_name)",
        "CREATE INDEX IF NOT EXISTS idx_service_permissions_service_type ON service_permissions(service_type)",
        "CREATE INDEX IF NOT EXISTS idx_user_role_overrides_user_id ON user_role_overrides(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_user_role_overrides_service_id ON user_role_overrides(service_id)",
        "CREATE INDEX IF NOT EXISTS idx_user_role_overrides_service_type ON user_role_overrides(service_type)",
        "CREATE INDEX IF NOT EXISTS idx_monitoring_events_timestamp ON monitoring_events(timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_monitoring_events_user_id ON monitoring_events(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_monitoring_events_flow ON monitoring_events(flow)",
        "CREATE INDEX IF NOT EXISTS idx_monitoring_events_session_id ON monitoring_events(session_id)",
        "CREATE INDEX IF NOT EXISTS idx_monitoring_events_service_id ON monitoring_events(service_id)"
    }
    
    for _, index_sql in ipairs(indexes) do
        local result = db_connection:exec(index_sql)
        if result ~= sqlite3.OK then
            logger.warn("Failed to create index: " .. db_connection:errmsg())
        end
    end
    
    _M._create_default_roles()
    
    logger.info("Database tables created successfully")
    return true
end

function _M.query(sql, params)
    local db = _M.get_db()
    if not db then
        logger.error("Database connection not available")
        return nil, "Database not initialized"
    end
    
    local max_retries = 3
    local retry_delay = 0.1
    
    for attempt = 1, max_retries do
        local stmt = db:prepare(sql)
        if not stmt then
            logger.error("Failed to prepare statement: " .. db:errmsg())
            return nil, "Failed to prepare statement: " .. (db:errmsg() or "unknown error")
        end
        
        if params then
            local _, placeholder_count = string.gsub(sql, "%?", "")
            for i = 1, placeholder_count do
                stmt:bind(i, params[i])
            end
        end
        
        local results = {}
        local success = true
        
        for row in stmt:nrows() do
            table.insert(results, row)
        end
        
        stmt:finalize()
        
        -- Check if we encountered BUSY during iteration
        if db:errcode() == sqlite3.BUSY then
            if attempt < max_retries then
                logger.warn("Database busy during query, retrying... (attempt " .. attempt .. "/" .. max_retries .. ")")
                ngx.sleep(retry_delay)
                retry_delay = retry_delay * 2  -- Exponential backoff
            else
                logger.error("Database busy after " .. max_retries .. " query attempts")
                return nil, "Database busy"
            end
        else
            return results
        end
    end
    
    return nil, "Max retries exceeded"
end

function _M.execute(sql, params)
    local db = _M.get_db()
    if not db then
        logger.error("Database connection not available")
        return false, "Database not initialized"
    end
    
    local max_retries = 3
    local retry_delay = 0.1
    
    for attempt = 1, max_retries do
        local stmt = db:prepare(sql)
        if not stmt then
            logger.error("Failed to prepare statement: " .. db:errmsg())
            return false, "Failed to prepare statement"
        end
        
        if params then
            local _, placeholder_count = string.gsub(sql, "%?", "")
            for i = 1, placeholder_count do
                stmt:bind(i, params[i])
            end
        end
        
        local result = stmt:step()
        stmt:finalize()
        
        if result == sqlite3.DONE then
            return true
        elseif result == sqlite3.BUSY then
            if attempt < max_retries then
                logger.warn("Database busy, retrying... (attempt " .. attempt .. "/" .. max_retries .. ")")
                ngx.sleep(retry_delay)
                retry_delay = retry_delay * 2  -- Exponential backoff
            else
                logger.error("Database busy after " .. max_retries .. " attempts")
                return false, "Database busy"
            end
        else
            logger.error("Failed to execute statement: " .. db:errmsg())
            return false, (db:errmsg() or "Failed to execute statement")
        end
    end
    
    return false, "Max retries exceeded"
end

function _M.last_insert_rowid()
    local db = _M.get_db()
    if not db then
        return nil
    end
    return db:last_insert_rowid()
end

function _M.close_db()
    if db_connection then
        db_connection:close()
        db_connection = nil
    end
end

function _M._create_default_roles()
    local db = _M.get_db()
    if not db then
        return false
    end
    
    local default_roles = {
        {
            id = "admin",
            name = "admin", 
            description = "Full system access and administration privileges",
            permissions = cjson.encode({"admin", "user", "developer"})
        },
        {
            id = "developer",
            name = "developer",
            description = "Development access with elevated privileges", 
            permissions = cjson.encode({"user", "developer"})
        },
        {
            id = "user",
            name = "user",
            description = "Standard user access to approved services",
            permissions = cjson.encode({"user"})
        }
    }
    
    for _, role in ipairs(default_roles) do
        local check_sql = "SELECT COUNT(*) as count FROM roles WHERE id = ?"
        local stmt = db:prepare(check_sql)
        if stmt then
            stmt:bind(1, role.id)
            local exists = false
            for row in stmt:nrows() do
                exists = row.count > 0
                break
            end
            stmt:finalize()
            
            if not exists then
                local insert_sql = [[
                    INSERT INTO roles (id, name, description, permissions, enabled)
                    VALUES (?, ?, ?, ?, 1)
                ]]
                local insert_stmt = db:prepare(insert_sql)
                if insert_stmt then
                    insert_stmt:bind(1, role.id)
                    insert_stmt:bind(2, role.name)
                    insert_stmt:bind(3, role.description)
                    insert_stmt:bind(4, role.permissions)
                    local result = insert_stmt:step()
                    insert_stmt:finalize()
                    
                    if result == sqlite3.DONE then
                        logger.info("Created default role: " .. role.name)
                    else
                        logger.error("Failed to create default role " .. role.name .. ": " .. db:errmsg())
                    end
                end
            end
        end
    end
    
    
    logger.debug("Default roles created successfully")
    
    return true
end

function _M.init_models()
    logger.debug("Initializing models (creating default roles)...")
    local success = _M._create_default_roles()
    if success then
        logger.debug("Models initialization completed successfully - roles created")
    else
        logger.error("Models initialization failed - could not create roles")
    end
    return success
end

return _M 