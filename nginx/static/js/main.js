// Main JavaScript file for Jump Server
// Entry point that loads and initializes all modules

// Module loading utility
function loadModule(src) {
    return new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = src;
        script.onload = resolve;
        script.onerror = reject;
        document.head.appendChild(script);
    });
}

// Application initialization
class JumpServerApp {
    constructor() {
        this.modules = {};
        this.initialized = false;
        this.config = null;
    }

    async init() {
        if (this.initialized) return;
        
        try {
            // Load core modules
            await this.loadCoreModules();
            
            // Load frontend configuration
            await this.loadFrontendConfig();
            
            // Initialize page-specific functionality
            await this.initPageModules();

            // Setup theme sync (auto dark/light)
            this.setupThemeSync();

            // Populate header user and refresh permissions on load
            await this.refreshAuthContext();
            
            // Setup global event listeners
            this.setupGlobalEventListeners();
            
            this.initialized = true;
            console.info('Jump Server App initialized successfully');
        } catch (error) {
            console.error('Failed to initialize app:', error);
            if (window.notifications) {
                notifications.error('Failed to initialize application');
            }
        }
    }

    async loadCoreModules() {
        const coreModules = [
            '/static/js/utils/datetime.js',
            '/static/js/modules/api-client.js',
            '/static/js/modules/notifications.js'
        ];

        for (const module of coreModules) {
            try {
                await loadModule(module);
            } catch (error) {
                console.error(`Failed to load module ${module}:`, error);
            }
        }
    }

    async loadFrontendConfig() {
        try {
            if (!window.apiClient || !window.apiClient.config) return;
            const response = await window.apiClient.config.getFrontend();
            if (response && response.success && response.data) {
                this.config = response.data;
                // Make config available globally
                window.__APP_CONFIG__ = this.config;
                // Emit a global event so components can react deterministically
                document.dispatchEvent(new CustomEvent('app:config-loaded', { detail: { config: this.config } }));
                // Update page title
                this.updatePageTitle();
            }
        } catch (error) {
            console.warn('Failed to load frontend configuration:', error);
            // Set default config
            this.config = { title: 'Jump Server' };
            window.__APP_CONFIG__ = this.config;
            // Emit event even for defaults to unify flow
            document.dispatchEvent(new CustomEvent('app:config-loaded', { detail: { config: this.config } }));
            // Update page title with default
            this.updatePageTitle();
        }
    }

    updatePageTitle() {
        if (this.config && this.config.title) {
            // Update document title
            const currentTitle = document.title;
            const pagePrefix = currentTitle.split(' - ')[0];
            document.title = pagePrefix + ' - ' + this.config.title;
            
            // Also update login title if present
            const loginTitleEl = document.getElementById('login-title');
            if (loginTitleEl) {
                loginTitleEl.textContent = this.config.title;
            }
        }
    }

    async refreshAuthContext() {
        try {
            if (!window.apiClient || !window.apiClient.auth) return;
            const [sessionResp, permsResp] = await Promise.all([
                window.apiClient.auth.getSession().catch(()=>null),
                window.apiClient.auth.getPermissions().catch(()=>null)
            ]);
            if (!sessionResp || !sessionResp.success || !sessionResp.data || !sessionResp.data.user) return;
            const user = sessionResp.data.user;
            const name = user.name || user.email || 'User';
            const avatarEl = document.getElementById('header-user-avatar');
            const nameEl = document.getElementById('header-user-name');
            if (avatarEl) {
                const initial = (name || 'U').toString().trim().charAt(0).toUpperCase();
                avatarEl.textContent = initial || 'U';
            }
            if (nameEl) {
                nameEl.textContent = name;
            }
            // Store admin flag only from server truth
            window.__APP_ROLES__ = (permsResp && permsResp.data && Array.isArray(permsResp.data.roles)) ? permsResp.data.roles : [];
            window.__APP_IS_ADMIN__ = !!(permsResp && permsResp.data && permsResp.data.is_admin === true);
        } catch (_) {}
    }

    async initPageModules() { return; }

    async loadPageModule(src) {
        try {
            await loadModule(src);
        } catch (error) {
            // Page modules are optional
            console.warn(`Optional page module not found: ${src}`);
        }
    }

    setupGlobalEventListeners() {
        // Global error handler
        window.addEventListener('error', (event) => {
            console.error('Global error:', event.error);
            if (window.notifications) {
                notifications.error('An unexpected error occurred');
            }
        });

        // Unhandled promise rejection handler
        window.addEventListener('unhandledrejection', (event) => {
            console.error('Unhandled promise rejection:', event.reason);
            if (window.notifications) {
                notifications.error('An unexpected error occurred');
            }
        });
    }

    // Sync theme with system preference (no toggle rendered)
    setupThemeSync() {
        const root = document.documentElement;
        const mql = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
        const apply = () => {
            if (mql && mql.matches) {
                root.classList.add('dark-theme');
                root.classList.remove('light-theme');
            } else {
                root.classList.remove('dark-theme');
                root.classList.add('light-theme');
            }
        };
        apply();
        if (mql && typeof mql.addEventListener === 'function') {
            mql.addEventListener('change', apply);
        } else if (mql && typeof mql.addListener === 'function') {
            mql.addListener(apply);
        }
    }
}

// Load core modules and initialize app
document.addEventListener('DOMContentLoaded', async function() {
    const app = new JumpServerApp();
    await app.init();
    
    // Store app instance globally for debugging
    window.app = app;
    
    
});

// Utility function to show flash messages
function showFlashMessage(message, type = 'info') {
    const flashContainer = document.createElement('div');
    flashContainer.className = `flash-message ${type}`;
    flashContainer.textContent = message;
    
    document.body.appendChild(flashContainer);
    
    // Trigger animation
    setTimeout(() => flashContainer.classList.add('show'), 10);
    
    // Auto-hide after 5 seconds
    setTimeout(function() {
        flashContainer.classList.remove('show');
        setTimeout(function() {
            flashContainer.remove();
        }, 300);
    }, 5000);
}

// Utility function to make API calls
async function apiCall(url, options = {}) {
    const defaultOptions = {
        headers: {
            'Content-Type': 'application/json',
        },
    };
    
    const finalOptions = { ...defaultOptions, ...options };
    
    try {
        const response = await fetch(url, finalOptions);
        const data = await response.json();
        
        if (!response.ok) {
            throw new Error(data.error || 'API request failed');
        }
        
        return data;
    } catch (error) {
        console.error('API call failed:', error);
        throw error;
    }
}

// Copy service URL to clipboard
function copyServiceUrl(url) {
    if (navigator.clipboard && window.isSecureContext) {
        // Use modern clipboard API
        navigator.clipboard.writeText(url).then(function() {
            if (window.notifications) {
                notifications.success('URL copied to clipboard!');
            }
        }).catch(function(err) {
            console.error('Failed to copy: ', err);
            fallbackCopyTextToClipboard(url);
        });
    } else {
        // Fallback for older browsers
        fallbackCopyTextToClipboard(url);
    }
}

// Fallback copy function for older browsers
function fallbackCopyTextToClipboard(text) {
    const textArea = document.createElement('textarea');
    textArea.value = text;
    textArea.style.top = '0';
    textArea.style.left = '0';
    textArea.style.position = 'fixed';
    textArea.style.opacity = '0';
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    
    try {
        const successful = document.execCommand('copy');
        if (successful && window.notifications) {
            notifications.success('URL copied to clipboard!');
        } else if (window.notifications) {
            notifications.error('Failed to copy URL');
        }
    } catch (err) {
        console.error('Fallback copy failed: ', err);
        if (window.notifications) {
            notifications.error('Failed to copy URL');
        }
    }
    
    document.body.removeChild(textArea);
} 