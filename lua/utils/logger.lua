-- Unified Logger

local cjson_safe = require "cjson.safe"

local _M = {}

-- Configuration (env-overridable)
local LOG_FILE_PATH = (os.getenv("LOG_FILE_PATH") or "/app/logs/jumpserver.log")

-- Per-worker file handle
local file_handle = nil

local LEVELS = {
	ERROR = 1,
	WARN = 2,
	INFO = 3,
	DEBUG = 4
}

local LEVEL_NAMES = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "DEBUG" }

-- Determine current level from env
local function read_env_log_level()
	local env_level = os.getenv("LOG_LEVEL") or "INFO"
	env_level = tostring(env_level):upper()
	
	if env_level == "DEBUG" then
		return LEVELS.DEBUG
	else
		return LEVELS.INFO
	end
end

local current_level = read_env_log_level()


-- Ensure /app/logs exists
local function ensure_log_dir()
    -- Extract directory from path
    local dir = LOG_FILE_PATH:match("^(.+)/[^/]+$") or "/app/logs"
	-- Create directory if missing
	local ok = io.open(LOG_FILE_PATH, "a")
	if ok then
		ok:close()
		return true
	end
	-- Create directory via shell (OpenResty allows os.execute)
	pcall(function()
		os.execute("mkdir -p " .. dir)
	end)
	-- Retry file open
	local f = io.open(LOG_FILE_PATH, "a")
	if f then
		f:close()
		return true
	end
	return false
end

local function open_log_file()
	if file_handle ~= nil then return file_handle end
	if not ensure_log_dir() then return nil end
	local f = io.open(LOG_FILE_PATH, "a")
	if f then
		file_handle = f
		return file_handle
	end
	return nil
end

local function reopen_log_file_on_error()
	if file_handle then
		pcall(function() file_handle:close() end)
		file_handle = nil
	end
	return open_log_file()
end

local function level_to_ngx(level_num)
	if ngx == nil then return nil end
	if level_num == LEVELS.ERROR then return ngx.ERR end
	if level_num == LEVELS.WARN then return ngx.WARN end
	if level_num == LEVELS.INFO then return ngx.INFO end
	if level_num == LEVELS.DEBUG then return ngx.DEBUG end
	return ngx.INFO
end

local function serialize_message(msg)
	local t = type(msg)
	if t == "string" then return msg end
	if t == "table" then
		local encoded = cjson_safe.encode(msg)
		return encoded or tostring(msg)
	end
	return tostring(msg)
end

local function timestamp()
	if ngx and ngx.now then
		-- ISO-like with milliseconds
		local now = ngx.now()
		local sec = math.floor(now)
		local ms = math.floor((now - sec) * 1000)
		return os.date("%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", ms)
	end
	return os.date("%Y-%m-%dT%H:%M:%SZ")
end

local function write_file(line)
	local fh = file_handle or open_log_file()
	if not fh then return end
	local ok = pcall(function()
		fh:write(line .. "\n")
		fh:flush()
	end)
	if not ok then
		fh = reopen_log_file_on_error()
		if fh then
			pcall(function()
				fh:write(line .. "\n")
				fh:flush()
			end)
		end
	end
end

-- Core log function
function _M.log(level_name, ...)
	local level_num = LEVELS[(tostring(level_name) or ""):upper()] or LEVELS.INFO
	
	-- ERROR and WARN are always visible regardless of LOG_LEVEL setting
	if level_num > LEVELS.WARN and level_num > current_level then 
		return 
	end

    local parts = { ... }
	for i = 1, #parts do
		parts[i] = serialize_message(parts[i])
	end
	local msg = table.concat(parts, " ")
    local line = string.format("[%s] %-5s %s", timestamp(), LEVEL_NAMES[level_num] or "INFO", msg)

    -- Always mirror to stderr (Docker console)
	pcall(function()
		io.stderr:write(line .. "\n")
	end)

	-- Always append to project log file
	write_file(line)
end

function _M.error(...)
	_M.log("ERROR", ...)
end

function _M.warn(...)
	_M.log("WARN", ...)
end

function _M.info(...)
	_M.log("INFO", ...)
end

function _M.debug(...)
	_M.log("DEBUG", ...)
end

function _M.set_level(level_name)
	local lvl = LEVELS[(tostring(level_name) or ""):upper()]
	if lvl then current_level = lvl end
end

function _M.get_level()
	return LEVEL_NAMES[current_level] or "INFO"
end

-- Allow runtime reload from env (e.g., after config changes)
function _M.reload_from_env()
	current_level = read_env_log_level()
end

-- Allow manual reopen (e.g., after logrotate)
function _M.reopen()
	reopen_log_file_on_error()
end

return _M