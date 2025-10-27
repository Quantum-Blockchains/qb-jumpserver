// Notifications Module
// Provides toast notifications and error handling

class NotificationManager {
    constructor() {
        this.container = null;
        this.notifications = new Map();
        this.init();
    }

    init() {
        // Create notification container if it doesn't exist
        this.container = document.getElementById('notification-container');
        if (!this.container) {
            this.container = document.createElement('div');
            this.container.id = 'notification-container';
            this.container.className = 'notification-container';
            document.body.appendChild(this.container);
        }
    }

    // Show a notification
    show(message, type = 'info', options = {}) {
        const id = this.generateId();
        const notification = this.createNotification(id, message, type, options);
        
        this.notifications.set(id, notification);
        this.container.appendChild(notification.element);
        
        // Trigger animation
        requestAnimationFrame(() => {
            notification.element.classList.add('show');
        });
        
        // Auto-dismiss if specified
        if (options.duration !== 0) {
            const duration = options.duration || this.getDefaultDuration(type);
            setTimeout(() => this.dismiss(id), duration);
        }
        
        return id;
    }

    // Dismiss a notification
    dismiss(id) {
        const notification = this.notifications.get(id);
        if (!notification) return;
        
        notification.element.classList.add('dismissing');
        
        setTimeout(() => {
            if (notification.element.parentNode) {
                notification.element.parentNode.removeChild(notification.element);
            }
            this.notifications.delete(id);
        }, 300);
    }

    // Clear all notifications
    clear() {
        this.notifications.forEach((_, id) => this.dismiss(id));
    }

    // Show success notification
    success(message, options = {}) {
        return this.show(message, 'success', options);
    }

    // Show error notification
    error(message, options = {}) {
        return this.show(message, 'error', { duration: 8000, ...options });
    }

    // Show warning notification
    warning(message, options = {}) {
        return this.show(message, 'warning', { duration: 6000, ...options });
    }

    // Show info notification
    info(message, options = {}) {
        return this.show(message, 'info', options);
    }

    // Show loading notification
    loading(message, options = {}) {
        return this.show(message, 'loading', { duration: 0, ...options });
    }

    // Handle API errors
    handleApiError(error, context = '') {
        let message = 'An unexpected error occurred';
        
        if (error instanceof ApiError) {
            if (error.isClientError) {
                message = error.message;
            } else if (error.isServerError) {
                message = 'Server error: ' + error.message;
            } else if (error.isNetworkError) {
                message = 'Network error: Please check your connection';
            }
        } else if (error.message) {
            message = error.message;
        }
        
        if (context) {
            message = `${context}: ${message}`;
        }
        
        return this.error(message);
    }

    // Create notification element
    createNotification(id, message, type, options) {
        const element = document.createElement('div');
        element.className = `notification notification-${type}`;
        element.setAttribute('data-id', id);
        
        const icon = this.getIcon(type);
        const dismissButton = options.dismissible !== false;
        
        element.innerHTML = `
            <div class="notification-content">
                <div class="notification-icon">${icon}</div>
                <div class="notification-message">${this.escapeHtml(message)}</div>
                ${dismissButton ? '<button class="notification-dismiss" aria-label="Dismiss">&times;</button>' : ''}
            </div>
            ${type === 'loading' ? '<div class="notification-progress"></div>' : ''}
        `;
        
        // Add click handlers
        if (dismissButton) {
            const dismissBtn = element.querySelector('.notification-dismiss');
            dismissBtn.addEventListener('click', () => this.dismiss(id));
        }
        
        // Click to dismiss (except for loading)
        if (type !== 'loading' && options.clickToDismiss !== false) {
            element.addEventListener('click', () => this.dismiss(id));
        }
        
        return { element, type, message, options };
    }

    // Get icon for notification type
    getIcon(type) {
        const icons = {
            success: '✓',
            error: '✕',
            warning: '⚠',
            info: 'ℹ',
            loading: '⟳'
        };
        return icons[type] || icons.info;
    }

    // Get default duration for notification type
    getDefaultDuration(type) {
        const durations = {
            success: 4000,
            error: 8000,
            warning: 6000,
            info: 5000,
            loading: 0
        };
        return durations[type] || 5000;
    }

    // Generate unique ID
    generateId() {
        return 'notification_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
    }

    // Escape HTML to prevent XSS
    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}

// Progress notification for long operations
class ProgressNotification {
    constructor(message, options = {}) {
        this.manager = notifications;
        this.id = this.manager.loading(message, { 
            dismissible: false, 
            clickToDismiss: false,
            ...options 
        });
        this.element = this.manager.notifications.get(this.id).element;
        this.progressBar = this.element.querySelector('.notification-progress');
    }

    // Update progress (0-100)
    updateProgress(percent, message = null) {
        if (this.progressBar) {
            this.progressBar.style.width = `${Math.max(0, Math.min(100, percent))}%`;
        }
        
        if (message) {
            const messageEl = this.element.querySelector('.notification-message');
            if (messageEl) {
                messageEl.textContent = message;
            }
        }
    }

    // Complete the progress and show success
    complete(message = 'Operation completed successfully') {
        this.manager.dismiss(this.id);
        return this.manager.success(message);
    }

    // Fail the progress and show error
    fail(message = 'Operation failed') {
        this.manager.dismiss(this.id);
        return this.manager.error(message);
    }

    // Dismiss the progress notification
    dismiss() {
        this.manager.dismiss(this.id);
    }
}

// Create and export singleton instance
const notifications = new NotificationManager();

// Add CSS if not already present
function addNotificationStyles() {
    if (document.getElementById('notification-styles')) return;
    
    const styles = document.createElement('style');
    styles.id = 'notification-styles';
    styles.textContent = `
        .notification-container {
            position: fixed;
            top: 20px;
            right: 20px;
            z-index: 10000;
            pointer-events: none;
        }
        
        .notification {
            background: white;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
            margin-bottom: 12px;
            min-width: 300px;
            max-width: 400px;
            opacity: 0;
            transform: translateX(100%);
            transition: all 0.3s ease;
            pointer-events: auto;
            border-left: 4px solid #007bff;
        }
        
        .notification.show {
            opacity: 1;
            transform: translateX(0);
        }
        
        .notification.dismissing {
            opacity: 0;
            transform: translateX(100%);
        }
        
        .notification-success { border-left-color: #28a745; }
        .notification-error { border-left-color: #dc3545; }
        .notification-warning { border-left-color: #ffc107; }
        .notification-info { border-left-color: #17a2b8; }
        .notification-loading { border-left-color: #6c757d; }
        
        .notification-content {
            display: flex;
            align-items: flex-start;
            padding: 16px;
            position: relative;
        }
        
        .notification-icon {
            font-size: 18px;
            font-weight: bold;
            margin-right: 12px;
            margin-top: 2px;
            flex-shrink: 0;
        }
        
        .notification-message {
            flex: 1;
            font-size: 14px;
            line-height: 1.4;
            color: #333;
        }
        
        .notification-dismiss {
            background: none;
            border: none;
            font-size: 18px;
            color: #999;
            cursor: pointer;
            padding: 0;
            margin-left: 12px;
            line-height: 1;
        }
        
        .notification-dismiss:hover {
            color: #666;
        }
        
        .notification-progress {
            height: 3px;
            background: #007bff;
            width: 0%;
            transition: width 0.3s ease;
        }
        
        .notification-loading .notification-icon {
            animation: spin 1s linear infinite;
        }
        
        @keyframes spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
        }
        
        .notification:hover {
            box-shadow: 0 6px 16px rgba(0, 0, 0, 0.2);
        }
    `;
    document.head.appendChild(styles);
}

// Initialize styles when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addNotificationStyles);
} else {
    addNotificationStyles();
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { notifications, ProgressNotification };
} else {
    window.notifications = notifications;
    window.ProgressNotification = ProgressNotification;
} 