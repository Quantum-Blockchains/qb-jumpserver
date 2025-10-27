/**
 * Proxy URL Interceptor
 * 
 * This script intercepts and rewrites URLs in JavaScript applications to work
 * correctly through the proxy. It handles:
 * - fetch() calls
 * - XMLHttpRequest
 * - WebSocket connections
 * - EventSource (Server-Sent Events)
 * - Dynamic script loading
 * - Relative and absolute URL resolution
 */

(function() {
    'use strict';
    
    // Set up proxy base configuration
    var base = window.__PROXY_BASE__;
    var origin = window.location.origin;
    var svc = base.split("/")[2];
    
    /**
     * Check if a URL should be skipped from rewriting
     * @param {string} url - The URL to check
     * @returns {boolean} - True if the URL should be skipped
     */
    function isSkippable(url) {
        return typeof url !== "string" ||
               url.indexOf("data:") === 0 ||
               url.indexOf("blob:") === 0 ||
               url.indexOf("javascript:") === 0 ||
               url.indexOf("mailto:") === 0 ||
               url.indexOf("tel:") === 0;
    }
    
    /**
     * Collapse duplicate proxy prefixes in paths
     * @param {string} path - The path to collapse
     * @returns {string} - The collapsed path
     */
    function collapseStart(path) {
        for (var i = 0; i < 5; i++) {
            if (path.indexOf("/http/" + svc + "/http/") === 0) {
                path = "/http/" + svc + "/" + path.slice(("/http/" + svc + "/http/").length);
            } else if (path.indexOf("/http/http/") === 0) {
                path = "/http/" + path.slice(("/http/http/").length);
            } else {
                break;
            }
        }
        return path;
    }
    
    /**
     * Ensure the path has the correct service prefix
     * @param {string} path - The path to ensure
     * @returns {string} - The path with correct service prefix
     */
    function ensureService(path) {
        if (path.indexOf("/http/") === 0) {
            var tail = path.slice(6);
            if (tail.indexOf(svc + "/") !== 0) {
                path = "/http/" + svc + "/" + tail.replace(/^http\//, "");
            }
        }
        return path;
    }
    
    /**
     * Convert relative URLs to absolute paths
     * @param {string} url - The URL to convert
     * @returns {string} - The absolute path
     */
    function toAbsolutePath(url) {
        if (url.indexOf("//") === 0) {
            url = window.location.protocol + url;
        }
        if (url.indexOf(origin + "/") === 0) {
            return url.substring(origin.length);
        }
        return url;
    }
    
    /**
     * Normalize a path to work with the proxy
     * @param {string} path - The path to normalize
     * @returns {string} - The normalized path
     */
    function normalizePath(path) {
        if (typeof path !== "string") return path;
        if (path === base || path.indexOf(base + "/") === 0) return path;
        
        var normalizedPath = path;
        
        // Handle absolute URLs
        if (normalizedPath.indexOf("http://") === 0 || 
            normalizedPath.indexOf("https://") === 0 || 
            normalizedPath.indexOf("//") === 0) {
            normalizedPath = toAbsolutePath(normalizedPath);
        }
        
        // Ensure path starts with /
        if (normalizedPath[0] !== "/") {
            normalizedPath = "/" + normalizedPath;
        }
        
        // Collapse duplicate prefixes and ensure service
        normalizedPath = collapseStart(normalizedPath);
        normalizedPath = ensureService(normalizedPath);
        
        // Add proxy base if not already present
        if (normalizedPath.indexOf("/http/") !== 0) {
            normalizedPath = base + normalizedPath;
        }
        
        return normalizedPath;
    }
    
    /**
     * Rewrite a URL to work with the proxy
     * @param {string} url - The URL to rewrite
     * @returns {string} - The rewritten URL
     */
    function rewriteUrl(url) {
        if (isSkippable(url)) return url;
        
        var isAbsolute = (url.indexOf("http://") === 0 || 
                         url.indexOf("https://") === 0 || 
                         url.indexOf("//") === 0);
        
        if (isAbsolute) {
            if (url.indexOf("//") === 0) {
                url = window.location.protocol + url;
            }
            if (url.indexOf(origin + "/") === 0) {
                return origin + normalizePath(url.substring(origin.length));
            }
            return url;
        }
        
        return normalizePath(url);
    }
    
    /**
     * Rewrite WebSocket URLs to work with the proxy
     * @param {string} url - The WebSocket URL to rewrite
     * @returns {string} - The rewritten WebSocket URL
     */
    function rewriteWs(url) {
        if (isSkippable(url)) return url;
        
        var scheme = null;
        if (url.indexOf("ws://") === 0) {
            scheme = "ws";
            url = "http://" + url.slice(5);
        } else if (url.indexOf("wss://") === 0) {
            scheme = "wss";
            url = "https://" + url.slice(6);
        }
        
        var out = rewriteUrl(url);
        
        if (scheme === "ws") {
            return out.replace(/^https?:\/\//, "ws://");
        }
        if (scheme === "wss") {
            return out.replace(/^https?:\/\//, "wss://");
        }
        
        return out;
    }
    
    // Intercept fetch() calls
    if (window.fetch) {
        var originalFetch = window.fetch;
        window.fetch = function(url, options) {
            if (url && typeof url === "object" && "url" in url) {
                return originalFetch.call(this, new Request(rewriteUrl(url.url), url), options);
            }
            return originalFetch.call(this, rewriteUrl(url), options);
        };
    }
    
    // Intercept XMLHttpRequest
    if (window.XMLHttpRequest) {
        var originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            return originalOpen.call(this, method, rewriteUrl(url), Array.prototype.slice.call(arguments, 2));
        };
    }
    
    // Intercept WebSocket
    if (window.WebSocket) {
        var OriginalWebSocket = window.WebSocket;
        var WebSocketWrapper = function(url, protocols) {
            return new OriginalWebSocket(rewriteWs(url), protocols);
        };
        WebSocketWrapper.prototype = OriginalWebSocket.prototype;
        
        try {
            if (Object.setPrototypeOf) {
                Object.setPrototypeOf(WebSocketWrapper, OriginalWebSocket);
            } else {
                WebSocketWrapper.__proto__ = OriginalWebSocket;
            }
        } catch (e) {
            // Fallback for older browsers
        }
        
        window.WebSocket = WebSocketWrapper;
    }
    
    // Intercept EventSource (Server-Sent Events)
    if (window.EventSource) {
        var OriginalEventSource = window.EventSource;
        var EventSourceWrapper = function(url, eventSourceInitDict) {
            return new OriginalEventSource(rewriteUrl(url), eventSourceInitDict);
        };
        EventSourceWrapper.prototype = OriginalEventSource.prototype;
        
        try {
            if (Object.setPrototypeOf) {
                Object.setPrototypeOf(EventSourceWrapper, OriginalEventSource);
            } else {
                EventSourceWrapper.__proto__ = OriginalEventSource;
            }
        } catch (e) {
            // Fallback for older browsers
        }
        
        window.EventSource = EventSourceWrapper;
    }
    
    // Intercept dynamic script creation
    var originalCreateElement = document.createElement;
    document.createElement = function(tagName) {
        var element = originalCreateElement.call(this, tagName);
        
        if (tagName.toLowerCase() === "script") {
            var originalSrcSetter = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, "src") ||
                                   Object.getOwnPropertyDescriptor(HTMLElement.prototype, "src");
            
            if (originalSrcSetter && originalSrcSetter.set) {
                Object.defineProperty(element, "src", {
                    get: originalSrcSetter.get,
                    set: function(value) {
                        originalSrcSetter.set.call(this, rewriteUrl(value));
                    },
                    configurable: true
                });
            }
        }
        
        return element;
    };
    
})();
