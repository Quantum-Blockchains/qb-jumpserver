-- HTTP Proxy Body Filter

local service_id = ngx.var.service_id
if not service_id then
    return
end

local proxy_prefix = "/http/" .. service_id
local content_type = ngx.header["Content-Type"] or ""
local is_upstream_response = tostring(ngx.var.upstream_status or "") ~= ""

if not is_upstream_response then
    return
end

local is_js = content_type:match("javascript") or 
              content_type:match("application/json") or
              content_type:match("text/css")

if not is_js then
    return
end

local ctx = ngx.ctx
if not ctx.body_buffer then
    ctx.body_buffer = {}
end

local chunk = ngx.arg[1]
local eof = ngx.arg[2]

if chunk and chunk ~= "" then
    table.insert(ctx.body_buffer, chunk)
end

if not eof then
    ngx.arg[1] = nil
    return
end

if eof then
    local body = table.concat(ctx.body_buffer)
    
    if #body > 2097152 then
        ngx.arg[1] = body
        return
    end
    
    if #body == 0 then
        return
    end
    
    local modified = false
    local original_body = body
    
    -- Pattern 1: ES6 dynamic imports - import("path")
    -- Match import("/path") and import('/path')
    local import_pattern_count = 0
    body, import_pattern_count = body:gsub('import%s*%(%s*["\']%s*(/[^"\']+)["\']%s*%)', function(path)
        if path:match("^/http/" .. service_id) then
            return 'import("' .. path .. '")'
        end
        modified = true
        return 'import("' .. proxy_prefix .. path .. '")'
    end)
    
    -- Pattern 2: import statements with from keyword
    -- import something from "path"
    local from_pattern_count = 0
    body, from_pattern_count = body:gsub('from%s+["\']%s*(/[^"\']+)["\']', function(path)
        if path:match("^/http/" .. service_id) then
            return 'from "' .. path .. '"'
        end
        modified = true
        return 'from "' .. proxy_prefix .. path .. '"'
    end)
    
    -- Pattern 3: export from statements
    -- export {something} from "path"
    local export_pattern_count = 0
    body, export_pattern_count = body:gsub('(export%s+%{[^}]+%}%s+from%s+)["\']%s*(/[^"\']+)["\']', function(prefix, path)
        if path:match("^/http/" .. service_id) then
            return prefix .. '"' .. path .. '"'
        end
        modified = true
        return prefix .. '"' .. proxy_prefix .. path .. '"'
    end)
    
    -- Pattern 4: fetch() calls with absolute paths
    -- fetch("/path")
    local fetch_pattern_count = 0
    body, fetch_pattern_count = body:gsub('fetch%s*%(%s*["\']%s*(/[^"\']+)["\']', function(path)
        if path:match("^/http/" .. service_id) or 
           path:match("^data:") or 
           path:match("^blob:") then
            return 'fetch("' .. path .. '"'
        end
        modified = true
        return 'fetch("' .. proxy_prefix .. path .. '"'
    end)
    
    -- Pattern 5: XMLHttpRequest open calls
    -- xhr.open("GET", "/path")
    local xhr_pattern_count = 0
    body, xhr_pattern_count = body:gsub('%.open%s*%(%s*["\'][^"\']+["\']%s*,%s*["\']%s*(/[^"\']+)["\']', function(path)
        if path:match("^/http/" .. service_id) then
            return '.open("GET","' .. path .. '"'
        end
        modified = true
        return '.open("GET","' .. proxy_prefix .. path .. '"'
    end)
    
    -- Pattern 6: String literals with absolute paths in common patterns
    -- url:"/path", src:"/path", href:"/path"
    local property_pattern_count = 0
    body, property_pattern_count = body:gsub('([:%s,%(])(["\'])(/[^"\']+)(["\'])', function(pre, quote, path, close_quote)
        if path:match("^/http/") or 
           path:match("^//") or
           path:match("^data:") or 
           path:match("^blob:") or
           path:match("^javascript:") or
           path:match("^mailto:") then
            return pre .. quote .. path .. close_quote
        end
        
        if path:match("%.[a-zA-Z0-9]+$") or 
           path:match("/resources/") or 
           path:match("/assets/") or
           path:match("/static/") or
           path:match("/js/") or
           path:match("/css/") or
           path:match("/img/") or
           path:match("/api/") then
            modified = true
            return pre .. quote .. proxy_prefix .. path .. close_quote
        end
        
        return pre .. quote .. path .. close_quote
    end)
    
    -- Pattern 7: new URL() constructor
    -- new URL("/path", ...)
    local url_pattern_count = 0
    body, url_pattern_count = body:gsub('new%s+URL%s*%(%s*["\']%s*(/[^"\']+)["\']', function(path)
        if path:match("^/http/" .. service_id) then
            return 'new URL("' .. path .. '"'
        end
        modified = true
        return 'new URL("' .. proxy_prefix .. path .. '"'
    end)
    
    -- Log if we made modifications
    if modified then
        local logger = require "utils.logger"
        local total_replacements = import_pattern_count + from_pattern_count + 
                                   export_pattern_count + fetch_pattern_count + 
                                   xhr_pattern_count + property_pattern_count + 
                                   url_pattern_count
        
        logger.debug("Rewrote " .. total_replacements .. " URLs in " .. content_type .. 
                    " response for service " .. service_id .. 
                    " (imports:" .. import_pattern_count .. 
                    ", from:" .. from_pattern_count .. 
                    ", exports:" .. export_pattern_count ..
                    ", fetch:" .. fetch_pattern_count ..
                    ", xhr:" .. xhr_pattern_count ..
                    ", props:" .. property_pattern_count ..
                    ", URL:" .. url_pattern_count .. ")")
    end
    
    ngx.arg[1] = body
end

