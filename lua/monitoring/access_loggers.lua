-- Access Loggers

local _M = {}

-- Base class
local BaseLogger = {}
BaseLogger.__index = BaseLogger

function BaseLogger:new(opts)
	local o = setmetatable({}, self)
	o.name = (opts and opts.name) or "base"
	o.flow = (opts and opts.flow) or "access"
	return o
end

function BaseLogger:matches(uri)
	return true
end

-- In basic mode, we log Jumpserver paths only; override in subclasses to filter

function BaseLogger:should_log(uri)
	return true
end

function BaseLogger:build_metadata(uri)
	return {
		path = ngx.var.uri or ngx.var.request_uri,
	}
end

function BaseLogger:build_event(uri)
    local status_code = tonumber(ngx.status) or 0
    local md = self:build_metadata(uri) or {}
    if md.status == nil then md.status = status_code end
    if md.bytes_sent == nil then md.bytes_sent = tonumber(ngx.var.bytes_sent) end
    if md.request_time == nil then md.request_time = tonumber(ngx.var.request_time) end
    if md.referer == nil then md.referer = ngx.var.http_referer end
    return {
        flow = self.flow,
        action = "request",
        status = (status_code >= 400) and "failure" or "success",
        request_method = ngx.req.get_method(),
        request_uri = ngx.var.request_uri,
        description = nil,
        metadata = md
    }
end

-- HTTP proxied services logger
local HttpLogger = {}
HttpLogger.__index = HttpLogger

function HttpLogger:new()
	local instance = BaseLogger:new({ name = "http", flow = "http" })
	-- Override specific methods
	instance.matches = function(_, uri)
		return uri and uri:sub(1, 6) == "/http/"
	end
	instance.build_metadata = function(_, uri)
		local md = BaseLogger.build_metadata(instance, uri)
		local svc_id = ngx.var.service_id
		if not svc_id then
			local m = ngx.re.match(ngx.var.uri or "", [[^/http/([^/]+)]], "jo")
			svc_id = m and m[1] or nil
		end
		md.service_id = svc_id
		md.service_type = "http"
		md.proxy_host = ngx.var.service_host
		md.proxy_port = ngx.var.service_port
		md.proxy_protocol = ngx.var.service_protocol
		md.service_path = ngx.var.final_path or ngx.var.request_path
		return md
	end
	return instance
end

-- SSH proxied services logger
local SshLogger = {}
SshLogger.__index = SshLogger

function SshLogger:new()
	local instance = BaseLogger:new({ name = "ssh", flow = "ssh" })
	-- Override specific methods
	instance.matches = function(_, uri)
		return uri and uri:sub(1, 5) == "/ssh/"
	end
	instance.build_metadata = function(_, uri)
		local md = BaseLogger.build_metadata(instance, uri)
		md.service_id = ngx.var.service_id
		md.service_type = "ssh"
		md.socket_path = ngx.var.ttyd_socket_path
		return md
	end
	return instance
end

-- Authentication endpoints logger
local AuthLogger = {}
AuthLogger.__index = AuthLogger

function AuthLogger:new()
	local instance = BaseLogger:new({ name = "auth", flow = "auth" })
	-- Override specific methods
	instance.matches = function(_, uri)
		return uri and uri:sub(1, 6) == "/auth/"
	end
	return instance
end

-- Administration and admin API logger
local AdminLogger = {}
AdminLogger.__index = AdminLogger

function AdminLogger:new()
	local instance = BaseLogger:new({ name = "admin", flow = "admin" })
	-- Override specific methods
	instance.matches = function(_, uri)
		if not uri then return false end
		return uri:sub(1, 14) == "/administration" or uri:find("^/api/v1/admin/") ~= nil
	end
	return instance
end

-- General API logger (non-admin)
local ApiLogger = {}
ApiLogger.__index = ApiLogger

function ApiLogger:new()
	local instance = BaseLogger:new({ name = "api", flow = "api" })
	-- Override specific methods
	instance.matches = function(_, uri)
		if not uri then return false end
		return uri:sub(1, 5) == "/api/"
	end
	return instance
end

-- Fallback logger (dashboard, login, static etc.)
local DefaultLogger = {}
DefaultLogger.__index = DefaultLogger

function DefaultLogger:new()
	return BaseLogger:new({ name = "default", flow = "access" })
end


-- Logger registry
local registry = {
	HttpLogger:new(),
	SshLogger:new(),
	AdminLogger:new(),
	AuthLogger:new(),
	ApiLogger:new(),
	DefaultLogger:new(),
}

function _M.pick_logger(uri)
	for _, logger in ipairs(registry) do
		if logger:matches(uri) then
			return logger
		end
	end
	return DefaultLogger:new()
end

return _M


