-- HTTP Proxy Header Filter

local service_id = ngx.var.service_id
if not service_id then
    return
end

local headers = ngx.header
local proxy_prefix = "/http/" .. service_id
local is_upstream_response = tostring(ngx.var.upstream_status or "") ~= ""

-- Clear Content-Length for JavaScript/CSS responses so body filter can modify them
if is_upstream_response then
    local content_type = headers["Content-Type"] or ""
    local is_js = content_type:match("javascript") or 
                  content_type:match("application/json") or
                  content_type:match("text/css")
    if is_js then
        headers["Content-Length"] = nil
    end
end

-- Rewrite Location header for redirects coming from upstream only
if is_upstream_response and headers["Location"] then
    local location = headers["Location"]
    local logger = require "utils.logger"
    
    local service_host = ngx.var.service_host or ""
    local service_port = ngx.var.service_port or ""
    local service_protocol = ngx.var.service_protocol or "http"
    
    local backend_url_patterns = {}
    if service_host ~= "" and service_port ~= "" then
        table.insert(backend_url_patterns, "^http://" .. service_host:gsub("%.", "%%.") .. ":" .. service_port .. "(/.*)")
        table.insert(backend_url_patterns, "^https://" .. service_host:gsub("%.", "%%.") .. ":" .. service_port .. "(/.*)")
        if service_port == "80" then
            table.insert(backend_url_patterns, "^http://" .. service_host:gsub("%.", "%%.") .. "(/.*)")
        elseif service_port == "443" then
            table.insert(backend_url_patterns, "^https://" .. service_host:gsub("%.", "%%.") .. "(/.*)")
        end
    end
    
    local rewritten = false
    
    for _, pattern in ipairs(backend_url_patterns) do
        local path = location:match(pattern)
        if path then
            headers["Location"] = proxy_prefix .. path
            logger.info("Rewrote absolute Location: " .. location .. " -> " .. headers["Location"])
            rewritten = true
            break
        end
    end
    
    if not rewritten and location:sub(1, 1) == "/" then
        headers["Location"] = proxy_prefix .. location
        logger.debug("Rewrote relative Location: " .. location .. " -> " .. headers["Location"])
    end
end

-- Rewrite Set-Cookie Path attribute for upstream responses only
local set_cookie = headers["Set-Cookie"]
if is_upstream_response and set_cookie and type(set_cookie) == "string" then
    local function rewrite_cookie(cookie)
        if not cookie:match("[Pp]ath=") then
            return cookie .. "; Path=" .. proxy_prefix .. "/"
        end
        return cookie:gsub("([Pp]ath=)([^;]+)", function(p, path)
            if path == "/" then
                return p .. proxy_prefix .. "/"
            end
            return p .. proxy_prefix .. path
        end)
    end
    
    headers["Set-Cookie"] = rewrite_cookie(set_cookie)
elseif is_upstream_response and set_cookie and type(set_cookie) == "table" then
    local rewritten = {}
    for i, cookie in ipairs(set_cookie) do
        if type(cookie) == "string" then
            if not cookie:match("[Pp]ath=") then
                rewritten[i] = cookie .. "; Path=" .. proxy_prefix .. "/"
            else
                rewritten[i] = cookie:gsub("([Pp]ath=)([^;]+)", function(p, path)
                    if path == "/" then
                        return p .. proxy_prefix .. "/"
                    end
                    return p .. proxy_prefix .. path
                end)
            end
        else
            rewritten[i] = cookie
        end
    end
    headers["Set-Cookie"] = rewritten
end

