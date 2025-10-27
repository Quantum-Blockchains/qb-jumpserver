// Simple DateTime Utility - Unix timestamp based
class DateTimeUtil {
    /**
     * Format Unix timestamp for display
     * @param {number} unixTimestamp - Unix timestamp (seconds since epoch)
     * @returns {string} Formatted timestamp in user's timezone
     */
    static formatForDisplay(unixTimestamp) {
        if (!unixTimestamp || !Number.isFinite(Number(unixTimestamp))) return '';
        
        try {
            // Convert to milliseconds and create Date
            const date = new Date(Number(unixTimestamp) * 1000);
            if (isNaN(date.getTime())) return unixTimestamp.toString();
            
            // Format in user's local timezone
            return date.toLocaleString(undefined, {
                year: 'numeric',
                month: '2-digit',
                day: '2-digit',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                hour12: false,
                timeZoneName: 'short'
            });
        } catch (error) {
            console.warn('Failed to format timestamp:', unixTimestamp, error);
            return unixTimestamp.toString();
        }
    }

    /**
     * Convert datetime-local input value to Unix epoch
     * @param {string} localDateTimeStr - Local datetime string from datetime-local input
     * @returns {number|null} Unix epoch timestamp or null if invalid
     */
    static localDateTimeToEpoch(localDateTimeStr) {
        if (!localDateTimeStr) return null;
        
        try {
            // datetime-local gives us "2025-09-29T11:00" in local time
            const localDate = new Date(localDateTimeStr);
            if (isNaN(localDate.getTime())) return null;
            
            return Math.floor(localDate.getTime() / 1000);
        } catch (error) {
            console.warn('Failed to convert local datetime to epoch:', localDateTimeStr, error);
            return null;
        }
    }

    /**
     * Get current Unix timestamp
     * @returns {number} Current Unix timestamp
     */
    static now() {
        return Math.floor(Date.now() / 1000);
    }
}

// Make it available globally
window.DateTimeUtil = DateTimeUtil;