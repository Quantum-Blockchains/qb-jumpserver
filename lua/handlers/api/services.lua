-- Services API Handlers

local cjson = require "cjson"
local api_router = require "handlers.api_router"
local web_utils = require "utils.web_utils"
local data_utils = require "utils.data_utils"

local _M = {}

function _M.validate_service_id(service_id, service_name)
    if not service_id or service_id == "" then
        return false, service_name .. " ID is required"
    end
    return true
end

function _M.validate_required_fields(data, required_fields)
    local missing = {}
    for _, field in ipairs(required_fields) do
        if not data[field] or data[field] == "" then
            table.insert(missing, field)
        end
    end
    
    if #missing > 0 then
        return false, "Missing required fields: " .. table.concat(missing, ", ")
    end
    
    return true
end

function _M.validate_enum_field(value, allowed_values, field_name)
    if value and not allowed_values[value] then
        return false, field_name .. " must be one of: " .. table.concat(allowed_values, ", ")
    end
    return true
end

function _M.handle_list(load_function, enabled_only)
    local services = load_function(enabled_only)
    
    local services_array = {}
    for service_id, service in pairs(services or {}) do
        service.id = service_id
        table.insert(services_array, service)
    end
    
    return api_router.send_response(200, true, {
        services = services_array,
        count = #services_array,
        enabled_only = enabled_only
    })
end

function _M.handle_get(get_function, service_id, service_name)
    local valid, error = _M.validate_service_id(service_id, service_name)
    if not valid then
        return api_router.send_response(400, false, nil, error)
    end
    
    local service = get_function(service_id)
    if not service then
        return api_router.send_response(404, false, nil, service_name .. " service not found")
    end
    
    service.id = service_id
    return api_router.send_response(200, true, service)
end

function _M.handle_create(create_function, validate_function, service_name)
    local service_data, err = api_router.parse_json_body()
    if not service_data then
        return api_router.send_response(400, false, nil, err)
    end
    
    local valid, errors = validate_function(service_data)
    if not valid then
        return api_router.send_response(400, false, {validation_errors = errors}, "Validation failed")
    end
    
    local service, create_err = create_function(service_data)
    if not service then
        return api_router.send_response(400, false, nil, create_err or ("Failed to create " .. service_name .. " service"))
    end
    
    return api_router.send_response(201, true, service, service_name .. " service created successfully")
end

function _M.handle_update(update_function, validate_function, service_id, service_name)
    local valid, error = _M.validate_service_id(service_id, service_name)
    if not valid then
        return api_router.send_response(400, false, nil, error)
    end
    
    local service_data, err = api_router.parse_json_body()
    if not service_data then
        return api_router.send_response(400, false, nil, err)
    end
    
    local valid, errors = validate_function(service_data)
    if not valid then
        return api_router.send_response(400, false, {validation_errors = errors}, "Validation failed")
    end
    
    local service, update_err = update_function(service_id, service_data)
    if not service then
        return api_router.send_response(404, false, nil, update_err or (service_name .. " service not found"))
    end
    
    return api_router.send_response(200, true, service, service_name .. " service updated successfully")
end

function _M.handle_delete(delete_function, service_id, service_name)
    local valid, error = _M.validate_service_id(service_id, service_name)
    if not valid then
        return api_router.send_response(400, false, nil, error)
    end
    
    local success, delete_err = delete_function(service_id)
    if not success then
        return api_router.send_response(404, false, nil, delete_err or (service_name .. " service not found"))
    end
    
    return api_router.send_response(200, true, {id = service_id}, service_name .. " service deleted successfully")
end

function _M.handle_toggle(toggle_function, service_id, service_name)
    local valid, error = _M.validate_service_id(service_id, service_name)
    if not valid then
        return api_router.send_response(400, false, nil, error)
    end
    
    local service, toggle_err = toggle_function(service_id)
    if not service then
        return api_router.send_response(404, false, nil, toggle_err or (service_name .. " service not found"))
    end
    
    return api_router.send_response(200, true, service, service_name .. " service status toggled successfully")
end

-- Common error responses using API response utility
function _M.handle_validation_error(errors, message)
    return api_router.send_response(400, false, {validation_errors = errors}, message or "Validation failed")
end

function _M.handle_not_found(service_name, service_id)
    return api_router.send_response(404, false, nil, service_name .. " service not found: " .. tostring(service_id))
end

function _M.handle_creation_error(error, service_name)
    return api_router.send_response(400, false, nil, error or ("Failed to create " .. service_name .. " service"))
end

function _M.handle_update_error(error, service_name)
    return api_router.send_response(400, false, nil, error or ("Failed to update " .. service_name .. " service"))
end

function _M.handle_deletion_error(error, service_name)
    return api_router.send_response(400, false, nil, error or ("Failed to delete " .. service_name .. " service"))
end

local function ensure_http_services_init()
    local http_services_manager = require("services.http_services_manager")
    http_services_manager.init()
end

function _M.http_services_list()
    ensure_http_services_init()
    
    local enabled_only = ngx.var.arg_enabled == "true"
    local expand_permissions = ngx.var.arg_expand == "permissions" or ngx.var.arg_expand == "true" or ngx.var.arg_expand == "permissions:true" or ngx.var.arg_expand == "permissions=true"
    
    local load_function = function(enabled_only)
        local http_services_manager = require("services.http_services_manager")
        if enabled_only then
            return http_services_manager.load_enabled_http_services(expand_permissions)
        else
            return http_services_manager.load_http_services(expand_permissions)
        end
    end
    
    return _M.handle_list(load_function, enabled_only)
end

function _M.http_services_get(service_id)
    ensure_http_services_init()
    
    local http_services_manager = require("services.http_services_manager")
    return _M.handle_get(
        http_services_manager.get_http_service,
        service_id,
        "HTTP"
    )
end

function _M.http_services_available()
    local auth_service = require "auth.auth_service"
    local http_services_manager = require("services.http_services_manager")
    
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    local ids = auth_service.get_accessible_services(user, "http") or {}
    local map = {}
    for _, id in ipairs(ids) do
        local svc = http_services_manager.get_http_service(id)
        if svc and svc.enabled then
            map[id] = {
                id = svc.id,
                name = svc.name,
                type = "http",
                host = svc.host,
                port = svc.port,
                protocol = svc.protocol,
                url = svc.url,
                path = svc.path,
                enabled = true,
                description = svc.description
            }
        end
    end
    
    local list = {}
    for sid, s in pairs(map) do
        s.id = sid
        table.insert(list, s)
    end
    return api_router.send_response(200, true, { services = list, count = #list })
end

function _M.http_services_create()
    ensure_http_services_init()
    
    local http_services_manager = require("services.http_services_manager")
    return _M.handle_create(
        http_services_manager.create_http_service,
        http_services_manager.validate_http_service,
        "HTTP"
    )
end

function _M.http_services_update(service_id)
    ensure_http_services_init()
    
    local http_services_manager = require("services.http_services_manager")
    return _M.handle_update(
        http_services_manager.update_http_service,
        http_services_manager.validate_http_service,
        service_id,
        "HTTP"
    )
end

function _M.http_services_delete(service_id)
    ensure_http_services_init()
    
    local http_services_manager = require("services.http_services_manager")
    return _M.handle_delete(
        http_services_manager.delete_http_service,
        service_id,
        "HTTP"
    )
end

function _M.http_services_toggle(service_id)
    ensure_http_services_init()
    
    local http_services_manager = require("services.http_services_manager")
    return _M.handle_toggle(
        http_services_manager.toggle_http_service,
        service_id,
        "HTTP"
    )
end

function _M.http_services_import()
    ensure_http_services_init()
    
    local import_data, err = api_router.parse_json_body()
    if not import_data then
        return _M.handle_validation_error(nil, err)
    end
    
    local http_services_manager = require("services.http_services_manager")
    local imported, skipped, import_errors = http_services_manager.import_http_services_from_json(import_data)
    
    local response_data = {
        imported = imported,
        skipped = skipped or 0,
        errors = import_errors
    }
    
    if #import_errors > 0 then
        response_data.message = string.format("Import completed with %d imported, %d skipped, %d errors", 
            imported, skipped or 0, #import_errors)
        return _M.handle_validation_error(import_errors, response_data.message)
    end
    
    response_data.message = string.format("Successfully imported %d HTTP services", imported)
    if skipped and skipped > 0 then
        response_data.message = response_data.message .. string.format(" (%d skipped - existing in DB)", skipped)
    end
    
    return api_router.send_response(200, true, response_data)
end

function _M.http_services_export()
    ensure_http_services_init()
    
    local http_services_manager = require("services.http_services_manager")
    local export_data, export_err = http_services_manager.export_http_services_to_json()
    if not export_data then
        return api_router.send_response(500, false, nil, export_err or "Export failed")
    end
    
    return api_router.send_response(200, true, {
        services = export_data.services,
        count = export_data.count,
        exported_at = os.date("%Y-%m-%d %H:%M:%S"),
        message = "Successfully exported " .. export_data.count .. " HTTP services"
    })
end

function _M.ssh_services_list()
    local enabled_only = ngx.var.arg_enabled == "true"
    local expand_permissions = ngx.var.arg_expand == "permissions" or ngx.var.arg_expand == "true" or ngx.var.arg_expand == "permissions:true" or ngx.var.arg_expand == "permissions=true"
    
    local load_function = function(enabled_only)
        local ssh_services_manager = require("services.ssh_services_manager")
        if enabled_only then
            return ssh_services_manager.load_enabled_ssh_services(expand_permissions)
        else
            return ssh_services_manager.load_ssh_services(expand_permissions)
        end
    end
    
    return _M.handle_list(load_function, enabled_only)
end

function _M.ssh_services_get(service_id)
    local ssh_services_manager = require("services.ssh_services_manager")
    return _M.handle_get(
        ssh_services_manager.get_ssh_service,
        service_id,
        "SSH"
    )
end

function _M.ssh_services_create()
    local ssh_services_manager = require("services.ssh_services_manager")
    return _M.handle_create(
        ssh_services_manager.create_ssh_service,
        ssh_services_manager.validate_ssh_service,
        "SSH"
    )
end

function _M.ssh_services_update(service_id)
    local ssh_services_manager = require("services.ssh_services_manager")
    return _M.handle_update(
        ssh_services_manager.update_ssh_service,
        ssh_services_manager.validate_ssh_service,
        service_id,
        "SSH"
    )
end

function _M.ssh_services_delete(service_id)
    local ssh_services_manager = require("services.ssh_services_manager")
    return _M.handle_delete(
        ssh_services_manager.delete_ssh_service,
        service_id,
        "SSH"
    )
end

function _M.ssh_services_toggle(service_id)
    local ssh_services_manager = require("services.ssh_services_manager")
    return _M.handle_toggle(
        ssh_services_manager.toggle_ssh_service,
        service_id,
        "SSH"
    )
end

function _M.ssh_services_available()
    local auth_service = require "auth.auth_service"
    local ssh_services_manager = require("services.ssh_services_manager")
    
    local user = auth_service.get_current_user()
    if not user then
        return api_router.send_response(401, false, nil, "Authentication required")
    end
    
    local ids = auth_service.get_accessible_services(user, "ssh") or {}
    local map = {}
    for _, id in ipairs(ids) do
        local svc = ssh_services_manager.get_ssh_service(id)
        if svc and svc.enabled then
            map[id] = {
                id = svc.id,
                name = svc.name,
                type = "ssh",
                host = svc.host,
                port = svc.port,
                enabled = true,
                description = svc.description
            }
        end
    end
    
    local list = {}
    for sid, s in pairs(map) do
        s.id = sid
        table.insert(list, s)
    end
    return api_router.send_response(200, true, { services = list, count = #list })
end

return _M
