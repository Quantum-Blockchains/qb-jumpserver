-- Web Utilities

local cjson = require "cjson"
local _M = {}

-- Standard API response format
function _M.format_response(success, data, error, status)
    local response = {
        success = success,
        timestamp = os.time(),
        status = status or (success and 200 or 400)
    }
    
    if success then
        response.data = data
    else
        response.error = error or "Unknown error"
    end
    
    return response
end

-- Common response patterns
function _M.success(data, message, status)
    return _M.format_response(true, data, nil, status or 200)
end

function _M.error(error, message, status)
    return _M.format_response(false, nil, error, status or 400)
end

function _M.validation_error(errors, message)
    return _M.format_response(false, {validation_errors = errors}, message or "Validation failed", 400)
end

function _M.not_found(resource, identifier)
    return _M.format_response(false, nil, resource .. " not found: " .. tostring(identifier), 404)
end

function _M.unauthorized(message)
    return _M.format_response(false, nil, message or "Authentication required", 401)
end

function _M.forbidden(message)
    return _M.format_response(false, nil, message or "Access denied", 403)
end

function _M.bad_request(message)
    return _M.format_response(false, nil, message or "Bad request", 400)
end

function _M.internal_error(message)
    return _M.format_response(false, nil, message or "Internal server error", 500)
end

-- List response
function _M.list_response(items, count, metadata)
    local response = {
        items = items or {},
        count = count or #(items or {}),
        metadata = metadata or {}
    }
    
    return _M.success(response)
end

-- Pagination response
function _M.paginated_response(items, page, per_page, total)
    local response = {
        items = items or {},
        pagination = {
            page = page or 1,
            per_page = per_page or 20,
            total = total or #(items or {}),
            pages = math.ceil((total or #(items or {})) / (per_page or 20))
        }
    }
    
    return _M.success(response)
end

-- Health check response
function _M.health_response(status, checks, metadata)
    local response = {
        status = status or "healthy",
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        checks = checks or {},
        metadata = metadata or {}
    }
    
    return _M.success(response)
end

-- Export response
function _M.export_response(data, count, format, metadata)
    local response = {
        data = data,
        count = count or #(data or {}),
        format = format or "json",
        exported_at = os.date("%Y-%m-%d %H:%M:%S"),
        metadata = metadata or {}
    }
    
    return _M.success(response)
end

-- Import response
function _M.import_response(imported, errors, metadata)
    local response = {
        imported = imported or 0,
        errors = errors or {},
        success_count = imported or 0,
        error_count = #(errors or {}),
        metadata = metadata or {}
    }
    
    return _M.success(response)
end

-- Detect if the current request is from a browser
function _M.is_browser_request()
    local headers = ngx.req.get_headers()
    local accept = (headers["accept"] or headers["Accept"] or "")
    local user_agent = (headers["user-agent"] or headers["User-Agent"] or "")
    
    return accept:find("text/html", 1, true) ~= nil or 
           user_agent:find("Mozilla", 1, true) ~= nil
end

-- Handle error responses consistently for both browser and API clients
function _M.handle_error_response(status_code, error_message)
    if _M.is_browser_request() then
        ngx.status = status_code
        return ngx.exec("/_error/" .. status_code)
    else
        return ngx.exit(status_code)
    end
end

-- Handle authentication errors
function _M.handle_auth_error()
    return _M.handle_error_response(401, "Authentication required")
end

-- Handle service not found errors
function _M.handle_service_not_found()
    return _M.handle_error_response(404, "Service not found")
end

-- Handle session creation errors
function _M.handle_session_error()
    return _M.handle_error_response(500, "Session creation failed")
end

-- Parse a URL string into its components
function _M.parse_url(url)
    if not url or url == "" then
        return nil, "URL is required"
    end
    
    -- Default to http if no protocol specified
    if not url:match("^%w+://") then
        url = "http://" .. url
    end
    
    -- Extract protocol
    local protocol = url:match("^(%w+)://")
    if not protocol then
        return nil, "Invalid URL format: missing protocol"
    end
    
    -- Remove protocol from URL for further parsing
    local url_without_protocol = url:sub(#protocol + 4)
    
    -- Extract host and port
    local host_port, path = url_without_protocol:match("^([^/]+)(.*)")
    if not host_port then
        return nil, "Invalid URL format: missing host"
    end
    
    -- Extract port from host:port
    local host, port_str = host_port:match("^([^:]+):?(%d*)$")
    if not host then
        return nil, "Invalid URL format: invalid host"
    end
    
    -- Set default ports based on protocol
    local port = 80
    if protocol == "https" then
        port = 443
    end
    
    -- Override with explicit port if provided
    if port_str and port_str ~= "" then
        port = tonumber(port_str)
        if not port or port < 1 or port > 65535 then
            return nil, "Invalid port number: " .. port_str
        end
    end
    
    -- Normalize path (ensure it starts with /)
    if not path or path == "" then
        path = "/"
    elseif not path:match("^/") then
        path = "/" .. path
    end
    
    return {
        protocol = protocol,
        host = host,
        port = port,
        path = path,
        original_url = url
    }
end

-- Build a URL from components
function _M.build_url(components)
    if not components or not components.host then
        return nil, "Host is required"
    end
    
    local protocol = components.protocol or "http"
    local port = components.port or (protocol == "https" and 443 or 80)
    local path = components.path or "/"
    
    -- Don't include default ports in URL
    local port_str = ""
    if (protocol == "http" and port ~= 80) or (protocol == "https" and port ~= 443) then
        port_str = ":" .. port
    end
    
    return protocol .. "://" .. components.host .. port_str .. path
end

-- Validate a URL string
function _M.validate_url(url)
    local parsed, err = _M.parse_url(url)
    return parsed ~= nil, err
end

-- Get the base URL (without path) from a full URL
function _M.get_base_url(url)
    local parsed, err = _M.parse_url(url)
    if not parsed then
        return nil, err
    end
    
    return _M.build_url({
        protocol = parsed.protocol,
        host = parsed.host,
        port = parsed.port,
        path = "/"
    })
end

return _M
