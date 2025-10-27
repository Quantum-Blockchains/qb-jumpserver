-- HTTP Services Model

local BaseModel = require("models.base_model")
local db = require("models.init")
local logger = require "utils.logger"

local _M = {}

local base = BaseModel.new("http_services", "id")

_M.create_http_service = function(service_data)
    return base:create(service_data)
end

_M.update_http_service = function(service_id, service_data)
    return base:update(service_id, service_data)
end

_M.delete_http_service = function(service_id)
    return base:delete(service_id)
end

_M.get_http_service = function(service_id)
    local s = base:get(service_id)
    if s then
        s.enabled = (s.enabled == true) or (tonumber(s.enabled) == 1)
    end
    return s
end

_M.get_all_http_services = function()
    local rows = base:get_all("name ASC")
    for _, s in ipairs(rows) do
        s.enabled = (s.enabled == true) or (tonumber(s.enabled) == 1)
    end
    return rows
end

_M.get_enabled_http_services = function()
    local rows = base:get_enabled("name ASC")
    for _, s in ipairs(rows) do
        s.enabled = true
    end
    return rows
end

_M.exists_http_service = function(service_id)
    return base:exists(service_id)
end

_M.count_http_services = function(where_clause, params)
    return base:count(where_clause, params)
end

_M.search_http_services = function(search_term)
    local search_fields = {"name", "description", "host", "url"}
    return base:search(search_term, search_fields, "name ASC")
end

-- HTTP-specific operations
function _M.import_http_services_from_json(import_data)
    if not import_data or not import_data.services then
        return 0, 0, {"No services data provided"}
    end
    
    local imported = 0
    local skipped = 0
    local errors = {}
    
    for _, service_data in ipairs(import_data.services) do
        local valid, error = base:validate_required_fields(service_data, {"id", "name", "host", "port"})
        if not valid then
            table.insert(errors, string.format("Service %s: %s", service_data.id or "unknown", error))
            goto continue
        end
        
        local valid_protocol, protocol_error = base:validate_enum_field(
            service_data.protocol, 
            {"http", "https"}, 
            "protocol"
        )
        if not valid_protocol then
            table.insert(errors, string.format("Service %s: %s", service_data.id, protocol_error))
            goto continue
        end
        
        local valid_port, port_error = base:validate_numeric_range(
            service_data.port, 1, 65535, "port"
        )
        if not valid_port then
            table.insert(errors, string.format("Service %s: %s", service_data.id, port_error))
            goto continue
        end
        
        -- Check if service already exists
        if base:exists(service_data.id) then
            -- Skip existing service to protect user changes in database
            skipped = skipped + 1
            logger.debug(string.format("Skipping service %s - already exists in database (protecting user changes)", service_data.id))
            goto continue
        else
            -- Create new service
            local created, err = base:create(service_data)
            if created then
                imported = imported + 1
            else
                table.insert(errors, string.format("Service %s: Create failed - %s", service_data.id, err))
            end
        end
        
        ::continue::
    end
    
    return imported, skipped, errors
end

function _M.export_http_services_to_json()
    local services = base:get_all("name ASC")
    local count = #services
    
    -- Convert to export format
    local export_data = {
        services = services,
        count = count,
        exported_at = os.date("%Y-%m-%d %H:%M:%S"),
        version = "1.0"
    }
    
    return export_data
end

function _M.toggle_http_service(service_id)
    local service = base:get(service_id)
    if not service then
        return nil, "HTTP service not found"
    end
    
    local toggle_data = {
        enabled = not service.enabled
    }
    
    return base:update(service_id, toggle_data)
end

function _M.get_http_service_stats(service_id)
    local service = base:get(service_id)
    if not service then
        return nil, "HTTP service not found"
    end
    
    -- Get service statistics (can be extended with monitoring data)
    local stats = {
        id = service.id,
        name = service.name,
        status = service.enabled and "enabled" or "disabled",
        last_updated = service.updated_at,
        config_hash = service.config_hash
    }
    
    return stats
end

-- Validation methods
_M.validate_http_service = function(service_data)
    -- Required fields validation
    local required_fields = {"id", "name", "host", "port"}
    local valid, error = base:validate_required_fields(service_data, required_fields)
    if not valid then
            return false, {error}
        end
        
        local valid_protocol, protocol_error = base:validate_enum_field(
        service_data.protocol, 
        {"http", "https"}, 
        "protocol"
    )
    if not valid_protocol then
            return false, {protocol_error}
        end
        
        local valid_port, port_error = base:validate_numeric_range(
        service_data.port, 1, 65535, "port"
    )
    if not valid_port then
            return false, {port_error}
        end
        
        if service_data.host and type(service_data.host) == "string" then
        if service_data.host:match("^[%w%-%.]+$") == nil then
                return false, {"Invalid host format"}
            end
        end
        
        if service_data.url and type(service_data.url) == "string" then
        if not service_data.url:match("^https?://") then
            return false, {"URL must start with http:// or https://"}
        end
    end
    
    return true
end

-- Sanitization
_M.sanitize_http_service = function(service_data)
    local allowed_fields = {
        id = true, name = true, type = true, host = true, port = true,
        protocol = true, url = true, path = true, enabled = true,
        description = true, source = true
    }
    
    return base:sanitize_input(service_data, allowed_fields)
end

return _M 