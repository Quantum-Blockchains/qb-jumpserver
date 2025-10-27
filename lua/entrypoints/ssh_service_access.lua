-- SSH Service Access Entrypoint

local service_access_handler = require "handlers.service_access_handler"
local ssh_services_manager = require "services.ssh_services_manager"

-- Handle service access with authentication and authorization
local session, service = service_access_handler.handle_service_access(
    ngx.var.service_id, 
    "ssh", 
    ssh_services_manager
)

if not session then
    return
end

ngx.var.ttyd_socket_path = session:get_socket_path()


