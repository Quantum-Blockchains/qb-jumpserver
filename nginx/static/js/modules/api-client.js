// API Client Module
// Centralized API communication with consistent error handling

class ApiClient {
    constructor() {
        this.baseUrl = '/api/v1';
        this.defaultHeaders = {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        };
    }

    // Generic API request method
    async request(endpoint, options = {}) {
        const url = `${this.baseUrl}${endpoint}`;
        const config = {
            headers: { ...this.defaultHeaders, ...options.headers },
            credentials: 'same-origin',
            ...options
        };

        try {
            const response = await fetch(url, config);
            let data;
            const ct = response.headers && response.headers.get ? response.headers.get('content-type') : null;
            const isJson = ct && ct.includes('application/json');
            if (isJson) {
                data = await response.json();
            } else {
                const text = await response.text();
                try { data = JSON.parse(text); } catch (_) { data = { success: response.ok, status: response.status, error: text }; }
            }

            if (!response.ok) {
                throw new ApiError(
                    data.error || 'Request failed',
                    response.status,
                    data
                );
            }

            return data;
        } catch (error) {
            if (error instanceof ApiError) {
                throw error;
            }
            throw new ApiError('Network error: ' + error.message, 0, error);
        }
    }

    // HTTP Services API
    services = {
        http: {
            list: (enabledOnly = false, { expandPermissions = false } = {}) => {
                const params = new URLSearchParams();
                if (enabledOnly) params.set('enabled', 'true');
                if (expandPermissions) params.set('expand', 'permissions');
                const qs = params.toString();
                return this.request(`/services/http${qs ? `?${qs}` : ''}`);
            },
            available: () => this.request('/services/http/available'),
            
            get: (id) => 
                this.request(`/services/http/${id}`),
            
            create: (serviceData) => 
                this.request('/services/http', {
                    method: 'POST',
                    body: JSON.stringify(serviceData)
                }),
            
            update: (id, serviceData) => 
                this.request(`/services/http/${id}`, {
                    method: 'PUT',
                    body: JSON.stringify(serviceData)
                }),
            
            delete: (id) => 
                this.request(`/services/http/${id}`, { method: 'DELETE' }),
            
            toggle: (id) => 
                this.request(`/services/http/${id}/toggle`, { method: 'POST' }),
            
            stats: () => 
                this.request('/services/http/stats'),
            
            // Health check endpoints
            getHealth: (id) => 
                this.request(`/services/http/${id}/health`),
            
            getTargetHealth: (id) => 
                this.request(`/services/http/${id}/health/target`),
            
            getProxyHealth: (id) => 
                this.request(`/services/http/${id}/health/proxy`),
            
            getFavicon: (id) => 
                this.request(`/services/http/${id}/favicon`)
        },

        ssh: {
            list: (enabledOnly = false, { expandPermissions = false } = {}) => {
                const params = new URLSearchParams();
                if (enabledOnly) params.set('enabled', 'true');
                if (expandPermissions) params.set('expand', 'permissions');
                const qs = params.toString();
                return this.request(`/services/ssh${qs ? `?${qs}` : ''}`);
            },
            available: () => this.request('/services/ssh/available'),
            
            get: (id) => 
                this.request(`/services/ssh/${id}`),
            
            create: (serviceData) => 
                this.request('/services/ssh', {
                    method: 'POST',
                    body: JSON.stringify(serviceData)
                }),
            
            update: (id, serviceData) => 
                this.request(`/services/ssh/${id}`, {
                    method: 'PUT',
                    body: JSON.stringify(serviceData)
                }),
            
            delete: (id) => 
                this.request(`/services/ssh/${id}`, { method: 'DELETE' }),
            
            toggle: (id) => 
                this.request(`/services/ssh/${id}/toggle`, { method: 'POST' }),
            
            // Status check endpoint
            getStatus: (id) => 
                this.request(`/services/ssh/${id}/status`)
        }
    };

    // Authentication API
    auth = {
        getSession: () => 
            this.request('/auth/session'),
        
        logout: () => 
            this.request('/auth/session', { method: 'DELETE' }),
        
        getPermissions: () => 
            this.request('/auth/permissions')
    };

    // Admin API
    admin = {
        // getStats not used; health endpoint provides sufficient status
        getHealth: () => 
            this.request('/admin/system/health'),
        
        getLogs: (level = 'all', limit = 100) => 
            this.request(`/admin/system/logs?level=${level}&limit=${limit}`),
        
        exportConfig: () => 
            this.request('/admin/config/export'),
        
        getDiagnostics: () => 
            this.request('/admin/diagnostics'),
        
        maintenance: (operation) => 
            this.request('/admin/system/maintenance', {
                method: 'POST',
                body: JSON.stringify({ operation })
            }),

        getOIDCConfig: () => this.request('/admin/oidc/config'),
        updateOIDCConfig: (payload) => this.request('/admin/oidc/config', { method: 'PUT', body: JSON.stringify(payload) }),
        testOIDC: () => this.request('/admin/oidc/test', { method: 'POST' })
    };

    // Monitoring API
    monitoring = {
        listEvents: ({ limit = 100, offset = 0, flow, user_id, session_id, status, action, since_epoch, until_epoch, grouped = false, q } = {}) => {
            const params = new URLSearchParams();
            params.set('limit', String(limit));
            params.set('offset', String(offset));
            if (flow) params.set('flow', flow);
            if (user_id) params.set('user_id', user_id);
            if (session_id) params.set('session_id', session_id);
            if (status) params.set('status', status);
            if (action) params.set('action', action);
            // Only use epoch timestamps now
            if (since_epoch) params.set('since_epoch', String(since_epoch));
            if (until_epoch) params.set('until_epoch', String(until_epoch));
            if (grouped) params.set('grouped', 'true');
            if (q) params.set('q', q);
            return this.request(`/admin/monitoring/events?${params.toString()}`);
        }
    }

    // User API
    user = {
        getProfile: () => 
            this.request('/user/profile'),
        
        updateProfile: (profileData) => 
            this.request('/user/profile', {
                method: 'PUT',
                body: JSON.stringify(profileData)
            })
    };

    // Roles API (for dynamic role selectors)
    roles = {
        list: () => this.request('/admin/roles'),
        get: (id) => this.request(`/admin/roles/${id}`),
        create: (role) => this.request('/admin/roles', { method: 'POST', body: JSON.stringify(role) }),
        update: (id, role) => this.request(`/admin/roles/${id}`, { method: 'PUT', body: JSON.stringify(role) }),
        delete: (id) => this.request(`/admin/roles/${id}`, { method: 'DELETE' }),
    };

    // Config API
    config = {
        getFrontend: () => this.request('/config/frontend')
    };
}

// Custom error class for API errors
class ApiError extends Error {
    constructor(message, status, response) {
        super(message);
        this.name = 'ApiError';
        this.status = status;
        this.response = response;
    }

    get isClientError() {
        return this.status >= 400 && this.status < 500;
    }

    get isServerError() {
        return this.status >= 500;
    }

    get isNetworkError() {
        return this.status === 0;
    }
}

// Create and export singleton instance
const apiClient = new ApiClient();

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { apiClient, ApiError };
} else {
    window.apiClient = apiClient;
    window.ApiError = ApiError;
} 