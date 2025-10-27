-- Health Check API Handlers

local cjson = require "cjson"
local api_router = require "handlers.api_router"
local http = require "resty.http"
local logger = require "utils.logger"

local _M = {}

local function check_websocket_support(res)
    if not res or not res.headers then
        return { supported = false, reason = "No response headers" }
    end
    
    local upgrade = res.headers["Upgrade"] or res.headers["upgrade"]
    local connection = res.headers["Connection"] or res.headers["connection"]
    
    local has_upgrade = upgrade and (upgrade:lower():match("websocket") ~= nil)
    local has_connection = connection and (connection:lower():match("upgrade") ~= nil)
    
    return {
        supported = has_upgrade or has_connection,
        headers_present = has_upgrade and has_connection,
        reason = (has_upgrade or has_connection) and "Backend supports WebSocket" or "No WebSocket headers detected"
    }
end

local function scan_response_body(body, service_host, service_port, scheme, proxy_host, proxy_port)
    local issues = {}
    local warnings = {}
    local js_url_issues = {}
    
    if not body or body == "" then
        return { scanned = false, reason = "Empty body" }
    end
    
    -- Limit scan to first 100KB to avoid performance issues
    local scan_body = body:sub(1, 102400)
    
    -- Check for hardcoded backend URLs
    local backend_patterns = {
        "http://" .. service_host .. ":" .. service_port,
        "https://" .. service_host .. ":" .. service_port,
        "http://" .. service_host .. "/",
        "https://" .. service_host .. "/"
    }
    
    for _, pattern in ipairs(backend_patterns) do
        if scan_body:find(pattern, 1, true) then
            table.insert(issues, "Hardcoded backend URL detected: " .. pattern)
            break
        end
    end
    
    -- Check for JavaScript fetch() calls with absolute URLs
    local fetch_patterns = {
        'fetch%s*%(%s*["\']https?://([^"\']+)',
        '%.get%s*%(%s*["\']https?://([^"\']+)',
        '%.post%s*%(%s*["\']https?://([^"\']+)',
        'XMLHttpRequest[^;]+open%s*%([^,]+,%s*["\']https?://([^"\']+)',
        'axios%.get%s*%(%s*["\']https?://([^"\']+)',
        'axios%.post%s*%(%s*["\']https?://([^"\']+)',
        '%.ajax%s*%([^}]*url%s*:%s*["\']https?://([^"\']+)'
    }
    
    local js_absolute_urls = {}
    for _, pattern in ipairs(fetch_patterns) do
        for url in scan_body:gmatch(pattern) do
            -- Check if this URL is pointing outside the proxy
            local full_url = "http://" .. url
            if not url:match("^127%.0%.0%.1") and not url:match("^localhost") then
                -- This is an absolute URL not going through localhost proxy
                table.insert(js_absolute_urls, url)
            end
        end
    end
    
    -- Check if proxy host/port appears in URLs (indicates broken proxy)
    if proxy_host and proxy_port then
        -- Look for any fetch/XHR calls to the proxy server IP:port
        -- This indicates JavaScript is trying to call the proxy directly instead of using relative URLs
        local proxy_host_escaped = proxy_host:gsub("%.", "%%.")
        local fetch_to_proxy_patterns = {
            'fetch%s*%(%s*["\']https?://' .. proxy_host_escaped .. ':' .. proxy_port,
            'XMLHttpRequest[^;]+open%s*%([^,]+,%s*["\']https?://' .. proxy_host_escaped .. ':' .. proxy_port,
            '%.get%s*%(%s*["\']https?://' .. proxy_host_escaped .. ':' .. proxy_port,
            '%.ajax%s*%([^}]*url%s*:%s*["\']https?://' .. proxy_host_escaped .. ':' .. proxy_port
        }
        
        for _, pattern in ipairs(fetch_to_proxy_patterns) do
            if scan_body:find(pattern) then
                table.insert(js_url_issues, "JavaScript fetch() to proxy address detected: " .. proxy_host .. ":" .. proxy_port)
                break
            end
        end
    end
    
    if #js_absolute_urls > 0 then
        -- Report unique absolute URLs
        local unique_urls = {}
        for _, url in ipairs(js_absolute_urls) do
            unique_urls[url] = true
        end
        local count = 0
        for _ in pairs(unique_urls) do count = count + 1 end
        
        if count > 0 then
            table.insert(issues, string.format("%d JavaScript fetch()/XHR with absolute URLs (URL rewriting may be broken)", count))
            -- Show first few examples
            local examples = {}
            local shown = 0
            for url in pairs(unique_urls) do
                if shown < 3 then
                    table.insert(examples, url)
                    shown = shown + 1
                end
            end
            if #examples > 0 then
                table.insert(js_url_issues, "Examples: " .. table.concat(examples, ", "))
            end
        end
    end
    
    -- Check for absolute URLs in src/href attributes
    local absolute_url_count = 0
    for _ in scan_body:gmatch('[href|src]%s*=%s*["\']https?://') do
        absolute_url_count = absolute_url_count + 1
    end
    
    if absolute_url_count > 5 then
        table.insert(warnings, string.format("%d absolute URLs in attributes (may cause issues)", absolute_url_count))
    end
    
    -- Check for mixed content (http resources in https page)
    if scheme == "https" then
        local mixed_content = scan_body:match('[href|src]%s*=%s*["\']http://[^"\']+')
        if mixed_content then
            table.insert(issues, "Mixed content detected (HTTP resources in HTTPS page)")
        end
    end
    
    -- Check for common SPA frameworks (indication of complex JS)
    local spa_indicators = {
        { pattern = "react", name = "React" },
        { pattern = "angular", name = "Angular" },
        { pattern = "vue", name = "Vue.js" },
        { pattern = "ember", name = "Ember" }
    }
    
    local spa_detected = {}
    for _, indicator in ipairs(spa_indicators) do
        if scan_body:lower():find(indicator.pattern, 1, true) then
            table.insert(spa_detected, indicator.name)
        end
    end
    
    if #spa_detected > 0 then
        table.insert(warnings, "SPA framework detected (" .. table.concat(spa_detected, ", ") .. ") - may have proxy issues")
    end
    
    -- Merge JS URL issues into main issues
    for _, js_issue in ipairs(js_url_issues) do
        table.insert(issues, js_issue)
    end
    
    return {
        scanned = true,
        body_size_kb = math.floor(#body / 1024),
        issues = issues,
        warnings = warnings,
        spa_frameworks = spa_detected,
        absolute_url_count = absolute_url_count,
        js_absolute_url_count = #js_absolute_urls
    }
end


local function check_response_characteristics(res, response_time)
    if not res then
        return { checked = false }
    end
    
    local body_size = res.body and #res.body or 0
    local body_size_kb = math.floor(body_size / 1024)
    local body_size_mb = body_size_kb / 1024
    
    local issues = {}
    
    -- Check for large responses
    if body_size_mb > 10 then
        table.insert(issues, string.format("Large response (%.1fMB) may cause timeout issues", body_size_mb))
    end
    
    -- Check for slow responses
    if response_time > 5000 then
        table.insert(issues, string.format("Slow response (%dms) may indicate backend issues", response_time))
    elseif response_time > 2000 then
        table.insert(issues, string.format("Response time (%dms) higher than recommended", response_time))
    end
    
    -- Check content type
    local content_type = res.headers["Content-Type"] or res.headers["content-type"] or "unknown"
    
    return {
        checked = true,
        body_size_kb = body_size_kb,
        body_size_mb = body_size_mb,
        response_time_ms = response_time,
        content_type = content_type,
        issues = issues
    }
end

function _M.http_target_health(service_id)
    local http_services_manager = require("services.http_services_manager")
    local service = http_services_manager.get_http_service(service_id)
    
    if not service then
        return api_router.send_response(404, false, nil, "HTTP service not found")
    end
    
    -- Build target URL
    local url = string.format("%s://%s:%d%s", 
        service.protocol or "http",
        service.host,
        service.port,
        service.path or "/"
    )
    
    local start_time = ngx.now()
    local httpc = http.new()
    httpc:set_timeout(5000) -- 5 second timeout
    
    local res, err = httpc:request_uri(url, {
        method = "HEAD",
        ssl_verify = false, -- Allow self-signed certificates
        headers = {
            ["User-Agent"] = "JumpServer-HealthCheck/1.0"
        }
    })
    
    local response_time = math.floor((ngx.now() - start_time) * 1000) -- Convert to ms
    
    if not res then
        return api_router.send_response(200, true, {
            service_id = service_id,
            status = "unreachable",
            reachable = false,
            error = err or "Connection failed",
            response_time_ms = response_time,
            checked_at = os.time()
        })
    end
    
    local status = "healthy"
    if res.status >= 500 then
        status = "error"
    elseif res.status >= 400 and res.status < 500 then
        status = "degraded"
    elseif res.status >= 200 and res.status < 400 then
        status = "healthy"
    end
    
    return api_router.send_response(200, true, {
        service_id = service_id,
        status = status,
        reachable = true,
        http_status = res.status,
        response_time_ms = response_time,
        checked_at = os.time()
    })
end

local function follow_redirects_with_details(httpc, initial_url, headers, max_redirects)
    max_redirects = max_redirects or 5
    local redirect_chain = {}
    local current_url = initial_url
    local redirect_count = 0
    local final_res, final_err
    
    while redirect_count < max_redirects do
        local res, err = httpc:request_uri(current_url, {
            method = "HEAD",
            headers = headers,
            ssl_verify = false
        })
        
        if not res then
            return nil, err, redirect_chain
        end
        
        -- Record this step in the chain
        table.insert(redirect_chain, {
            url = current_url,
            status = res.status,
            headers = res.headers or {},
            step = redirect_count + 1
        })
        
        -- Check if this is a redirect
        if res.status >= 300 and res.status < 400 then
            local location = res.headers["Location"] or res.headers["location"]
            if location then
                -- Resolve relative URLs
                if location:match("^https?://") then
                    current_url = location
                elseif location:match("^//") then
                    local protocol = current_url:match("^(https?)://") or "http"
                    current_url = protocol .. ":" .. location
                elseif location:match("^/") then
                    local base = current_url:match("^(https?://[^/]+)")
                    current_url = base .. location
                else
                    local base = current_url:match("^(https?://[^/]+/)")
                    current_url = (base or current_url) .. location
                end
                redirect_count = redirect_count + 1
            else
                -- Redirect without Location header
                final_res = res
                break
            end
        else
            -- Not a redirect, we have our final response
            final_res = res
            break
        end
    end
    
    if redirect_count >= max_redirects then
        return nil, "Too many redirects (>" .. max_redirects .. ")", redirect_chain
    end
    
    return final_res, nil, redirect_chain
end

function _M.http_proxy_health(service_id)
    local http_services_manager = require("services.http_services_manager")
    local service = http_services_manager.get_http_service(service_id)
    
    if not service then
        return api_router.send_response(404, false, nil, "HTTP service not found")
    end
    
    -- Build proxy URL through jump server
    local proxy_path = http_services_manager.get_proxy_path(service_id)
    local proxy_url = "http://127.0.0.1:" .. (ngx.var.server_port or "80") .. proxy_path
    
    local start_time = ngx.now()
    local httpc = http.new()
    httpc:set_timeout(5000)
    
    -- Copy current request cookies to maintain session
    local cookie_header = ngx.var.http_cookie
    local headers = {
        ["User-Agent"] = "JumpServer-ProxyHealthCheck/1.0",
        ["X-Health-Check"] = "true"
    }
    if cookie_header then
        headers["Cookie"] = cookie_header
    end
    
    -- Follow redirects and collect details
    local res, err, redirect_chain = follow_redirects_with_details(httpc, proxy_url, headers, 10)
    
    local response_time = math.floor((ngx.now() - start_time) * 1000)
    
    -- Build detailed logs
    local logs = {}
    table.insert(logs, string.format("[%s] Proxy health check started", os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(logs, string.format("Initial URL: %s", proxy_url))
    
    if #redirect_chain > 0 then
        table.insert(logs, string.format("Redirect chain (%d steps):", #redirect_chain))
        for i, step in ipairs(redirect_chain) do
            table.insert(logs, string.format("  Step %d: %d -> %s", i, step.status, step.url))
            -- Log important headers
            if step.headers["Location"] or step.headers["location"] then
                table.insert(logs, string.format("    Location: %s", step.headers["Location"] or step.headers["location"]))
            end
        end
    end
    
    if not res then
        table.insert(logs, string.format("ERROR: %s", err or "Unknown error"))
        table.insert(logs, string.format("Response time: %dms", response_time))
        
        return api_router.send_response(200, true, {
            service_id = service_id,
            status = "proxy_error",
            proxy_working = false,
            error = err or "Proxy connection failed",
            response_time_ms = response_time,
            redirect_count = #redirect_chain,
            redirect_chain = redirect_chain,
            logs = logs,
            checked_at = os.time()
        })
    end
    
    table.insert(logs, string.format("Final status: %d", res.status))
    table.insert(logs, string.format("Response time: %dms", response_time))
    
    -- Verify proxy is actually working properly
    -- Check if any redirects broke out of the proxy path (leaked internal URLs)
    local proxy_path_prefix = "/http/" .. service_id .. "/"
    local redirects_stayed_internal = true
    local leaked_urls = {}
    
    for _, step in ipairs(redirect_chain) do
        local url = step.url
        -- Check if URL is a localhost/127.0.0.1 proxy URL
        local is_proxy_url = url:match("^https?://127%.0%.0%.1:") or url:match("^https?://localhost:")
        
        if is_proxy_url then
            -- This is good - still going through the proxy
            local path = url:match("^https?://[^/]+(.*)$")
            if path and not path:match("^" .. proxy_path_prefix:gsub("%-", "%%-")) then
                -- Proxy URL but wrong path - potential issue
                table.insert(logs, string.format("WARNING: Redirect to proxy but wrong path: %s", url))
            end
        else
            -- This is BAD - redirect leaked to actual backend service
            redirects_stayed_internal = false
            table.insert(leaked_urls, url)
            table.insert(logs, string.format("ERROR: Redirect leaked to backend: %s", url))
        end
    end
    
    -- Check if Set-Cookie paths are correct
    local cookie_path_correct = true
    if res.headers["Set-Cookie"] then
        local cookies = res.headers["Set-Cookie"]
        if type(cookies) == "string" then
            cookies = {cookies}
        end
        for _, cookie in ipairs(cookies) do
            local path = cookie:match("Path=([^;]+)")
            if path then
                if not path:match("^" .. proxy_path_prefix:gsub("%-", "%%-")) then
                    cookie_path_correct = false
                    table.insert(logs, string.format("WARNING: Cookie path incorrect: %s", path))
                end
            end
        end
    end
    
    -- Verify proxy functionality
    local proxy_verification = {
        redirects_followed = #redirect_chain > 0,
        redirect_count = #redirect_chain,
        final_url_reachable = res.status < 500,
        redirects_stayed_internal = redirects_stayed_internal,
        leaked_urls = leaked_urls,
        cookie_paths_correct = cookie_path_correct,
        url_rewriting_working = redirects_stayed_internal and cookie_path_correct
    }
    
    if not redirects_stayed_internal then
        table.insert(logs, string.format("CRITICAL: Proxy URL rewriting is BROKEN - %d redirect(s) leaked to backend", #leaked_urls))
    end
    
    if not cookie_path_correct then
        table.insert(logs, "WARNING: Cookie paths not properly rewritten")
    end
    
    local proxy_status = "proxy_healthy"
    local proxy_issues = {}
    
    -- First check for URL rewriting issues - these are critical
    if not redirects_stayed_internal then
        proxy_status = "proxy_rewrite_broken"
        table.insert(proxy_issues, "URL rewriting broken - redirects leak to backend")
        table.insert(logs, "Status: PROXY_REWRITE_BROKEN (redirects leak to backend)")
    elseif not cookie_path_correct then
        proxy_status = "proxy_degraded"
        table.insert(proxy_issues, "Cookie paths not properly rewritten")
        table.insert(logs, "Status: DEGRADED (cookie path issues)")
    -- Then check HTTP status
    elseif res.status >= 500 then
        proxy_status = "proxy_error"
        table.insert(proxy_issues, "Target returned 5xx error")
        table.insert(logs, "Status: PROXY_ERROR (5xx from target)")
    elseif res.status >= 400 and res.status < 500 then
        -- 401/403 might be expected if health check doesn't have auth
        if res.status == 401 or res.status == 403 then
            proxy_status = "proxy_auth_required"
            table.insert(logs, "Status: AUTH_REQUIRED (expected)")
        else
            proxy_status = "proxy_degraded"
            table.insert(proxy_issues, string.format("Target returned %d status", res.status))
            table.insert(logs, string.format("Status: DEGRADED (4xx: %d)", res.status))
        end
    elseif res.status >= 200 and res.status < 400 then
        proxy_status = "proxy_healthy"
        table.insert(logs, "Status: HEALTHY")
    end
    
    return api_router.send_response(200, true, {
        service_id = service_id,
        status = proxy_status,
        proxy_working = true,
        http_status = res.status,
        response_time_ms = response_time,
        redirect_count = #redirect_chain,
        redirect_chain = redirect_chain,
        proxy_verification = proxy_verification,
        proxy_issues = proxy_issues,
        logs = logs,
        checked_at = os.time()
    })
end

function _M.http_combined_health(service_id)
    local http_services_manager = require("services.http_services_manager")
    local service = http_services_manager.get_http_service(service_id)
    
    if not service then
        return api_router.send_response(404, false, nil, "HTTP service not found")
    end
    
    -- Check target health
    local target_url = string.format("%s://%s:%d%s", 
        service.protocol or "http",
        service.host,
        service.port,
        service.path or "/"
    )
    
    local target_start = ngx.now()
    local target_httpc = http.new()
    target_httpc:set_timeout(5000)
    
    local target_res, target_err = target_httpc:request_uri(target_url, {
        method = "HEAD",
        ssl_verify = false,
        headers = {
            ["User-Agent"] = "JumpServer-HealthCheck/1.0"
        }
    })
    
    local target_response_time = math.floor((ngx.now() - target_start) * 1000)
    
    local target_health = {
        reachable = target_res ~= nil,
        status = target_res and "healthy" or "unreachable",
        response_time_ms = target_response_time
    }
    
    if target_res then
        target_health.http_status = target_res.status
        if target_res.status >= 500 then
            target_health.status = "error"
        elseif target_res.status >= 400 then
            target_health.status = "degraded"
        end
    else
        target_health.error = target_err
    end
    
    -- Check proxy health with detailed redirect tracking
    local proxy_path = http_services_manager.get_proxy_path(service_id)
    local proxy_url = "http://127.0.0.1:" .. (ngx.var.server_port or "80") .. proxy_path
    
    local proxy_start = ngx.now()
    local proxy_httpc = http.new()
    proxy_httpc:set_timeout(5000)
    
    local cookie_header = ngx.var.http_cookie
    local proxy_headers = {
        ["User-Agent"] = "JumpServer-ProxyHealthCheck/1.0",
        ["X-Health-Check"] = "true"
    }
    if cookie_header then
        proxy_headers["Cookie"] = cookie_header
    end
    
    -- Follow redirects and collect details
    local proxy_res, proxy_err, redirect_chain = follow_redirects_with_details(proxy_httpc, proxy_url, proxy_headers, 10)
    
    local proxy_response_time = math.floor((ngx.now() - proxy_start) * 1000)
    
    -- Build detailed logs for proxy
    local proxy_logs = {}
    table.insert(proxy_logs, string.format("[%s] Proxy health check started", os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(proxy_logs, string.format("Initial URL: %s", proxy_url))
    
    if #redirect_chain > 0 then
        table.insert(proxy_logs, string.format("Redirect chain (%d steps):", #redirect_chain))
        for i, step in ipairs(redirect_chain) do
            table.insert(proxy_logs, string.format("  Step %d: %d -> %s", i, step.status, step.url))
            if step.headers["Location"] or step.headers["location"] then
                table.insert(proxy_logs, string.format("    Location: %s", step.headers["Location"] or step.headers["location"]))
            end
        end
    end
    
    local proxy_health = {
        working = proxy_res ~= nil,
        status = proxy_res and "proxy_healthy" or "proxy_error",
        response_time_ms = proxy_response_time,
        redirect_count = #redirect_chain,
        redirect_chain = redirect_chain,
        logs = proxy_logs
    }
    
    if proxy_res then
        proxy_health.http_status = proxy_res.status
        table.insert(proxy_logs, string.format("Final status: %d", proxy_res.status))
        table.insert(proxy_logs, string.format("Response time: %dms", proxy_response_time))
        
        -- Verify proxy is actually working properly
        local proxy_path_prefix = "/http/" .. service_id .. "/"
        local redirects_stayed_internal = true
        local leaked_urls = {}
        
        for _, step in ipairs(redirect_chain) do
            local url = step.url
            local is_proxy_url = url:match("^https?://127%.0%.0%.1:") or url:match("^https?://localhost:")
            
            if is_proxy_url then
                local path = url:match("^https?://[^/]+(.*)$")
                if path and not path:match("^" .. proxy_path_prefix:gsub("%-", "%%-")) then
                    table.insert(proxy_logs, string.format("WARNING: Redirect to proxy but wrong path: %s", url))
                end
            else
                redirects_stayed_internal = false
                table.insert(leaked_urls, url)
                table.insert(proxy_logs, string.format("ERROR: Redirect leaked to backend: %s", url))
            end
        end
        
        local cookie_path_correct = true
        if proxy_res.headers["Set-Cookie"] then
            local cookies = proxy_res.headers["Set-Cookie"]
            if type(cookies) == "string" then
                cookies = {cookies}
            end
            for _, cookie in ipairs(cookies) do
                local path = cookie:match("Path=([^;]+)")
                if path then
                    if not path:match("^" .. proxy_path_prefix:gsub("%-", "%%-")) then
                        cookie_path_correct = false
                        table.insert(proxy_logs, string.format("WARNING: Cookie path incorrect: %s", path))
                    end
                end
            end
        end
        
        proxy_health.proxy_verification = {
            redirects_followed = #redirect_chain > 0,
            redirect_count = #redirect_chain,
            final_url_reachable = proxy_res.status < 500,
            redirects_stayed_internal = redirects_stayed_internal,
            leaked_urls = leaked_urls,
            cookie_paths_correct = cookie_path_correct,
            url_rewriting_working = redirects_stayed_internal and cookie_path_correct
        }
        
        if not redirects_stayed_internal then
            table.insert(proxy_logs, string.format("CRITICAL: Proxy URL rewriting is BROKEN - %d redirect(s) leaked to backend", #leaked_urls))
        end
        
        if not cookie_path_correct then
            table.insert(proxy_logs, "WARNING: Cookie paths not properly rewritten")
        end
        
        local proxy_issues = {}
        
        if not redirects_stayed_internal then
            proxy_health.status = "proxy_rewrite_broken"
            table.insert(proxy_issues, "URL rewriting broken - redirects leak to backend")
            table.insert(proxy_logs, "Status: PROXY_REWRITE_BROKEN")
        elseif not cookie_path_correct then
            proxy_health.status = "proxy_degraded"
            table.insert(proxy_issues, "Cookie paths not properly rewritten")
            table.insert(proxy_logs, "Status: DEGRADED (cookie path issues)")
        elseif proxy_res.status >= 500 then
            proxy_health.status = "proxy_error"
            table.insert(proxy_issues, "Target returned 5xx error")
            table.insert(proxy_logs, "Status: PROXY_ERROR (5xx from target)")
        elseif proxy_res.status == 401 or proxy_res.status == 403 then
            proxy_health.status = "proxy_auth_required"
            table.insert(proxy_logs, "Status: AUTH_REQUIRED (expected)")
        elseif proxy_res.status >= 400 then
            proxy_health.status = "proxy_degraded"
            table.insert(proxy_issues, string.format("Target returned %d status", proxy_res.status))
            table.insert(proxy_logs, string.format("Status: DEGRADED (4xx: %d)", proxy_res.status))
        else
            table.insert(proxy_logs, "Status: HEALTHY")
        end
        
        proxy_health.proxy_issues = proxy_issues
    else
        proxy_health.error = proxy_err
        table.insert(proxy_logs, string.format("ERROR: %s", proxy_err or "Unknown error"))
        table.insert(proxy_logs, string.format("Response time: %dms", proxy_response_time))
    end
    
    -- ========================================================================
    -- ADVANCED CHECKS (Run after basic health checks)
    -- ========================================================================
    
    local advanced_checks = {}
    
    -- WebSocket Support Detection
    advanced_checks.websocket = check_websocket_support(proxy_res)
    
    -- 3. Get response body for analysis (GET instead of HEAD)
    local body_check = { scanned = false, reason = "Body not fetched" }
    local response_check = { checked = false }
    
    if proxy_res and proxy_res.status and proxy_res.status < 400 then
        -- Get the final URL from the redirect chain
        local final_url = proxy_url
        if #redirect_chain > 0 then
            final_url = redirect_chain[#redirect_chain].url
        end
        
        -- Make one more request to get the body for scanning (to the final URL)
        local body_httpc = http.new()
        body_httpc:set_timeout(10000)  -- Longer timeout for body fetch
        
        local body_start = ngx.now()
        local body_res, body_err = body_httpc:request_uri(final_url, {
            method = "GET",
            headers = proxy_headers,
            ssl_verify = false
        })
        local body_response_time = math.floor((ngx.now() - body_start) * 1000)
        
        if body_res and body_res.body then
            -- Get proxy server info from ngx variables
            local proxy_host = ngx.var.server_addr or ngx.var.host or "unknown"
            local proxy_port = ngx.var.server_port or "443"
            
            -- Scan body for issues
            body_check = scan_response_body(
                body_res.body,
                service.host,
                service.port,
                ngx.var.scheme or "https",
                proxy_host,
                proxy_port
            )
            
            -- Check response characteristics
            response_check = check_response_characteristics(body_res, body_response_time)
        elseif body_err then
            body_check = { scanned = false, reason = "Failed to fetch body: " .. body_err }
        end
    end
    
    advanced_checks.content_scan = body_check
    advanced_checks.response = response_check
    
    -- Add content scan results to proxy logs
    if body_check.scanned then
        table.insert(proxy_logs, "")
        table.insert(proxy_logs, "Content Scan Results:")
        if #redirect_chain > 0 then
            table.insert(proxy_logs, string.format("  Fetched body from final URL: %s", redirect_chain[#redirect_chain].url))
        end
        table.insert(proxy_logs, string.format("  Body size: %d KB", body_check.body_size_kb or 0))
        table.insert(proxy_logs, string.format("  Absolute URLs in HTML: %d", body_check.absolute_url_count or 0))
        table.insert(proxy_logs, string.format("  JavaScript absolute URLs: %d", body_check.js_absolute_url_count or 0))
        
        if body_check.issues and #body_check.issues > 0 then
            table.insert(proxy_logs, "  Issues found:")
            for _, issue in ipairs(body_check.issues) do
                table.insert(proxy_logs, "    - " .. issue)
            end
        end
        
        if body_check.warnings and #body_check.warnings > 0 then
            table.insert(proxy_logs, "  Warnings:")
            for _, warning in ipairs(body_check.warnings) do
                table.insert(proxy_logs, "    - " .. warning)
            end
        end
        
        if body_check.spa_frameworks and #body_check.spa_frameworks > 0 then
            table.insert(proxy_logs, "  SPA Frameworks: " .. table.concat(body_check.spa_frameworks, ", "))
        end
    else
        table.insert(proxy_logs, "")
        table.insert(proxy_logs, "Content Scan: " .. (body_check.reason or "Not performed"))
    end
    
    -- Collect all issues and warnings from advanced checks
    local all_issues = {}
    local all_warnings = {}
    
    -- Content scan issues
    if body_check.scanned then
        for _, issue in ipairs(body_check.issues or {}) do
            table.insert(all_issues, issue)
        end
        for _, warning in ipairs(body_check.warnings or {}) do
            table.insert(all_warnings, warning)
        end
    end
    
    -- Response characteristic issues
    if response_check.checked then
        for _, issue in ipairs(response_check.issues or {}) do
            table.insert(all_warnings, issue)
        end
    end
    
    -- WebSocket support info
    if advanced_checks.websocket.supported then
        table.insert(all_warnings, "Backend supports WebSocket")
    end
    
    -- ========================================================================
    -- DETERMINE OVERALL STATUS
    -- ========================================================================
    
    local overall_status = "healthy"
    if not target_health.reachable then
        overall_status = "unreachable"
    elseif not proxy_health.working then
        overall_status = "proxy_error"
    elseif proxy_health.status == "proxy_rewrite_broken" then
        overall_status = "proxy_rewrite_broken"  -- Critical proxy issue
    elseif target_health.status == "error" or proxy_health.status == "proxy_error" then
        overall_status = "error"
    elseif target_health.status == "degraded" or proxy_health.status == "proxy_degraded" then
        overall_status = "degraded"
    elseif proxy_health.status == "proxy_auth_required" then
        overall_status = "healthy" -- Auth required is expected
    end
    
    -- If there are any content issues or warnings, set status to degraded
    if overall_status == "healthy" then
        if #all_issues > 0 or #all_warnings > 0 then
            overall_status = "degraded"
        end
    end
    
    return api_router.send_response(200, true, {
        service_id = service_id,
        overall_status = overall_status,
        target = target_health,
        proxy = proxy_health,
        advanced_checks = advanced_checks,
        issues = all_issues,
        warnings = all_warnings,
        checked_at = os.time()
    })
end

local FAVICON_CACHE_DIR = "/tmp/jumpserver_favicons"

local function ensure_cache_dir()
    os.execute("mkdir -p " .. FAVICON_CACHE_DIR)
end

local function extract_favicon_from_html(html, base_url)
    if not html then return nil end
    
    -- Find favicon link tags in order of preference
    -- Use case-insensitive matching by checking both cases
    local patterns = {
        -- Standard icon - href first, then rel
        'href%s*=%s*["\']([^"\']+)["\'][^>]*rel%s*=%s*["\']icon["\']',
        -- Standard icon - rel first, then href
        'rel%s*=%s*["\']icon["\'][^>]*href%s*=%s*["\']([^"\']+)["\']',
        -- Shortcut icon - href first
        'href%s*=%s*["\']([^"\']+)["\'][^>]*rel%s*=%s*["\']shortcut%s+icon["\']',
        -- Shortcut icon - rel first
        'rel%s*=%s*["\']shortcut%s+icon["\'][^>]*href%s*=%s*["\']([^"\']+)["\']',
        -- SVG icon type
        'type%s*=%s*["\']image/svg%+xml["\'][^>]*href%s*=%s*["\']([^"\']+)["\']',
        'href%s*=%s*["\']([^"\']+)["\'][^>]*type%s*=%s*["\']image/svg%+xml["\']',
        -- Apple touch icon
        'rel%s*=%s*["\']apple%-touch%-icon[^"\']*["\'][^>]*href%s*=%s*["\']([^"\']+)["\']',
        'href%s*=%s*["\']([^"\']+)["\'][^>]*rel%s*=%s*["\']apple%-touch%-icon[^"\']*["\']',
    }
    
    -- Check patterns on both original and lowercased HTML
    for _, pattern in ipairs(patterns) do
        -- Case-insensitive match
        local favicon_path = html:match(pattern)
        if not favicon_path then
            -- Check lowercase version
            favicon_path = html:lower():match(pattern:lower())
        end
        
        if favicon_path then
            -- Clean up the path (remove any HTML entities or extra spaces)
            favicon_path = favicon_path:gsub("^%s+", ""):gsub("%s+$", "")
            
            -- Resolve relative URLs
            if favicon_path:match("^https?://") then
                return favicon_path
            elseif favicon_path:match("^//") then
                local protocol = base_url:match("^(https?)://") or "https"
                return protocol .. ":" .. favicon_path
            elseif favicon_path:match("^/") then
                return base_url .. favicon_path
            else
                return base_url .. "/" .. favicon_path
            end
        end
    end
    
    return nil
end

local function try_fetch_favicon(httpc, url)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["User-Agent"] = "JumpServer-FaviconFetch/1.0",
            ["Accept"] = "image/*,*/*"
        }
    })
    
    if res and res.status == 200 and res.body and #res.body > 0 then
        local content_type = res.headers["Content-Type"] or res.headers["content-type"] or "image/x-icon"
        
        -- Validate it's an image (not HTML or error page)
        local is_image = content_type:match("^image/") ~= nil
        local is_html = content_type:match("text/html") or 
                       res.body:match("^%s*<!") or 
                       res.body:match("^%s*<html") or
                       res.body:match("^%s*<HTML")
        
        -- Accept if it's an image, not HTML, and reasonable size
        if is_image and not is_html and #res.body < 500000 then
            return res.body, content_type
        end
    end
    
    return nil, nil
end

function _M.http_favicon(service_id)
    local http_services_manager = require("services.http_services_manager")
    local service = http_services_manager.get_http_service(service_id)
    
    if not service then
        return api_router.send_response(404, false, nil, "HTTP service not found")
    end
    
    ensure_cache_dir()
    
    -- Check if we have a cached favicon
    local cache_file = FAVICON_CACHE_DIR .. "/" .. service_id .. ".cache"
    local cache_meta = FAVICON_CACHE_DIR .. "/" .. service_id .. ".meta"
    
    -- Serve from cache (cache for 1 hour)
    local cache_file_handle = io.open(cache_file, "rb")
    if cache_file_handle then
        local meta_handle = io.open(cache_meta, "r")
        if meta_handle then
            local meta = meta_handle:read("*all")
            meta_handle:close()
            
            local content_type = meta:match("content%-type: ([^\n]+)")
            local cached_time = tonumber(meta:match("cached%-at: (%d+)"))
            
            -- Cache valid for 1 hour
            if cached_time and (os.time() - cached_time) < 3600 then
                local favicon_data = cache_file_handle:read("*all")
                cache_file_handle:close()
                
                ngx.header.content_type = content_type or "image/x-icon"
                ngx.header["Cache-Control"] = "public, max-age=3600"
                ngx.say(favicon_data)
                return ngx.exit(200)
            end
        end
        cache_file_handle:close()
    end
    
    -- Build base URL
    local base_url = string.format("%s://%s:%d", 
        service.protocol or "http",
        service.host,
        service.port
    )
    
    local httpc = http.new()
    httpc:set_timeout(5000)
    
    local favicon_body = nil
    local favicon_content_type = nil
    local favicon_source = nil
    
    -- Step 1: Fetch the service HTML to extract favicon path (follow redirects)
    local current_url = base_url .. "/"
    local html_res, html_err = nil, nil
    local redirect_count = 0
    local max_redirects = 5
    
    -- Follow redirects manually
    while redirect_count < max_redirects do
        html_res, html_err = httpc:request_uri(current_url, {
            method = "GET",
            ssl_verify = false,
            headers = {
                ["User-Agent"] = "JumpServer-FaviconFetch/1.0",
                ["Accept"] = "text/html"
            }
        })
        
        if not html_res then
            break
        end
        
        -- Check for redirect
        if html_res.status >= 300 and html_res.status < 400 then
            local location = html_res.headers["Location"] or html_res.headers["location"]
            if location then
                -- Resolve relative redirect URLs
                if location:match("^https?://") then
                    current_url = location
                elseif location:match("^//") then
                    local protocol = base_url:match("^(https?)://") or "https"
                    current_url = protocol .. ":" .. location
                elseif location:match("^/") then
                    current_url = base_url .. location
                else
                    current_url = base_url .. "/" .. location
                end
                redirect_count = redirect_count + 1
            else
                break
            end
        else
            -- Not a redirect, we have our final response
            break
        end
    end
    
    -- Extract favicon from HTML
    local favicon_url = nil
    local final_base_url = base_url
    
    -- If we followed redirects, use the final URL as base for relative paths
    if html_res and html_res.status == 200 then
        if current_url ~= (base_url .. "/") then
            -- Extract base URL from final redirected URL
            final_base_url = current_url:match("^(https?://[^/]+)") or base_url
        end
    end
    
    if html_res and html_res.status == 200 and html_res.body then
        favicon_url = extract_favicon_from_html(html_res.body, final_base_url)
        
        if favicon_url then
            logger.debug("Extracted favicon URL for " .. service_id .. ": " .. favicon_url)
            favicon_body, favicon_content_type = try_fetch_favicon(httpc, favicon_url)
            if favicon_body then
                favicon_source = "html"
                logger.debug("Successfully fetched favicon from HTML for " .. service_id)
            else
                logger.debug("Failed to fetch favicon from HTML URL: " .. favicon_url)
            end
        else
            logger.debug("Could not extract favicon URL from HTML for " .. service_id)
        end
    end
    
    -- Check common fallback paths if not found in HTML
    if not favicon_body then
        logger.debug("Trying fallback paths for " .. service_id)
        local fallback_paths = {
            "/favicon.ico",
            "/favicon.png",
            "/favicon.svg",
            "/apple-touch-icon.png",
            "/apple-touch-icon-precomposed.png",
            "/static/favicon.ico",
            "/assets/favicon.ico",
            "/images/favicon.ico",
            "/img/favicon.ico"
        }
        
        for _, path in ipairs(fallback_paths) do
            local test_url = base_url .. path
            favicon_body, favicon_content_type = try_fetch_favicon(httpc, test_url)
            if favicon_body then
                favicon_source = "fallback:" .. path
                logger.debug("Found favicon at fallback path for " .. service_id .. ": " .. path)
                break
            end
        end
        
        if not favicon_body then
            logger.debug("No favicon found in fallback paths for " .. service_id)
        end
    end
    
    -- Step 4: If we found a favicon, cache and serve it
    if favicon_body and favicon_content_type then
        -- Cache the favicon
        local cache_fh = io.open(cache_file, "wb")
        if cache_fh then
            cache_fh:write(favicon_body)
            cache_fh:close()
            
            -- Write metadata
            local meta_fh = io.open(cache_meta, "w")
            if meta_fh then
                meta_fh:write("content-type: " .. favicon_content_type .. "\n")
                meta_fh:write("cached-at: " .. os.time() .. "\n")
                meta_fh:write("source: " .. (favicon_source or "unknown") .. "\n")
                meta_fh:close()
            end
        end
        
        -- Serve the favicon
        ngx.header.content_type = favicon_content_type
        ngx.header["Cache-Control"] = "public, max-age=3600"
        ngx.say(favicon_body)
        return ngx.exit(200)
    end
    
    -- No favicon found, return 404
    return api_router.send_response(404, false, nil, "Favicon not found")
end

function _M.ssh_status(service_id)
    local ssh_services_manager = require("services.ssh_services_manager")
    local service = ssh_services_manager.get_ssh_service(service_id)
    
    if not service then
        return api_router.send_response(404, false, nil, "SSH service not found")
    end
    
    -- For SSH, we can check if the port is open using TCP socket
    local sock = ngx.socket.tcp()
    sock:settimeout(3000) -- 3 second timeout
    
    local start_time = ngx.now()
    local ok, err = sock:connect(service.host, service.port)
    local response_time = math.floor((ngx.now() - start_time) * 1000)
    
    if not ok then
        sock:close()
        return api_router.send_response(200, true, {
            service_id = service_id,
            status = "unreachable",
            reachable = false,
            error = err or "Connection failed",
            response_time_ms = response_time,
            checked_at = os.time()
        })
    end
    
    -- Read SSH banner
    local banner, read_err = sock:receive("*l")
    sock:close()
    
    local status = "healthy"
    if banner and banner:match("^SSH") then
        status = "healthy"
    elseif banner then
        status = "degraded" -- Port open but no SSH banner
    else
        status = "degraded" -- Connected but couldn't read banner
    end
    
    return api_router.send_response(200, true, {
        service_id = service_id,
        status = status,
        reachable = true,
        banner = banner,
        response_time_ms = response_time,
        checked_at = os.time()
    })
end

return _M

