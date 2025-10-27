-- HTTP Service Access Entrypoint

local service_access_handler = require "handlers.service_access_handler"
local http_services_manager = require "services.http_services_manager"
local logger = require "utils.logger"

-- Handle service access with authentication and authorization
local session, service = service_access_handler.handle_service_access(
    ngx.var.service_id, 
    "http", 
    http_services_manager
)

if not session then
    return
end

ngx.var.service_host = service.host
ngx.var.service_port = tostring(service.port)
ngx.var.service_protocol = service.protocol
ngx.var.service_base_path = service.path or "/"

local base = ngx.var.service_base_path or "/"
local reqp = ngx.var.request_path or ""

if reqp:sub(1, 1) == "/" then
    reqp = reqp:sub(2)
end

if base:sub(1, 1) ~= "/" then
    base = "/" .. base
end

if reqp == "" or reqp == "" then
    ngx.var.final_path = base
elseif base == "/" then
    -- Root base path - just prepend slash to reqp
    ngx.var.final_path = "/" .. reqp
elseif base:sub(-1) == "/" then
    -- Base has trailing slash - append reqp directly
    ngx.var.final_path = base .. reqp
else
    -- Base has no trailing slash - add separator
    ngx.var.final_path = base .. "/" .. reqp
end

logger.debug("Path computation: service_id=" .. (ngx.var.service_id or "nil") .. 
                   ", base=" .. base .. ", reqp=" .. reqp .. ", final=" .. ngx.var.final_path)
