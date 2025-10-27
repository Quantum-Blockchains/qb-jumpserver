-- Sessions Module

local _M = {}
local logger = require "utils.logger"

-- Load session components
local SessionBase = require "sessions.base"
local SessionTypes = require "sessions.session_types"
local SessionManager = require "sessions.session_manager"

-- Initialize sessions module
function _M.init()
    logger.debug("Initializing sessions module")
    
    -- Clean up orphaned ttyd socket files
    SessionTypes.SshProxySession.cleanup_orphaned_sockets()
    
    -- Initialize session manager
    local manager = SessionManager.SessionManager
    local success = manager.init()
    if not success then
        logger.error("Failed to initialize session manager")
        return false
    end
    
    -- Initialize session monitor
    local monitor = SessionManager.SessionMonitor
    success = monitor.init()
    if not success then
        logger.error("Failed to initialize session monitor")
        return false
    end
    
    logger.debug("Sessions module initialized successfully")
    return true
end

-- Export session classes and manager
_M.SessionBase = SessionBase
_M.AuthSession = SessionTypes.AuthSession
_M.HttpProxySession = SessionTypes.HttpProxySession
_M.SshProxySession = SessionTypes.SshProxySession
_M.SessionManager = SessionManager.SessionManager
_M.SessionMonitor = SessionManager.SessionMonitor

return _M 