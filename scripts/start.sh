#!/bin/bash
# QB Jump Server Startup Script
echo "========================================="
echo "    QB Jump Server Initialization"
echo "========================================="

# Print system information
echo "System Information:"
echo "   OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "   Kernel: $(uname -r)"
echo "   Architecture: $(uname -m)"
echo ""

# Print package versions
echo "Package Versions:"

# Nginx version
if command -v nginx >/dev/null 2>&1; then
    NGINX_VERSION=$(nginx -v 2>&1 | grep -o 'nginx/[0-9.]*' | cut -d'/' -f2)
    echo "   Nginx: $NGINX_VERSION"
else
    echo "   Nginx: Not found"
fi

# Lua version
if command -v lua5.1 >/dev/null 2>&1; then
    LUA_VERSION=$(lua5.1 -v 2>&1 | grep -o 'Lua [0-9.]*' | cut -d' ' -f2)
    echo "   Lua: $LUA_VERSION"
elif command -v lua >/dev/null 2>&1; then
    LUA_VERSION=$(lua -v 2>&1 | grep -o 'Lua [0-9.]*' | cut -d' ' -f2)
    echo "   Lua: $LUA_VERSION"
else
    echo "   Lua: Not found"
fi

# cURL version
if command -v curl >/dev/null 2>&1; then
    CURL_VERSION=$(curl --version | head -n1 | grep -o 'curl [0-9.]*' | cut -d' ' -f2)
    echo "   cURL: $CURL_VERSION"
else
    echo "   cURL: Not found"
fi

# Bash version
if command -v bash >/dev/null 2>&1; then
    BASH_VERSION=$(bash --version | head -n1 | grep -o 'version [0-9.]*' | cut -d' ' -f2)
    echo "   Bash: $BASH_VERSION"
else
    echo "   Bash: Not found"
fi

# Ensure log directories exist
echo "Preparing log directories..."
mkdir -p /app/logs
chown -R nginx:nginx /app/logs/

# Ensure ttyd sockets directory exists
echo "Preparing ttyd sockets directory..."
mkdir -p /app/ttyd_sockets
chown -R nginx:nginx /app/ttyd_sockets
chmod 755 /app/ttyd_sockets

# Ensure data directory has proper permissions
echo "Setting up data directory permissions..."
mkdir -p /app/data
chown -R nginx:nginx /app/data
chmod 755 /app/data

# Configure SSL/TLS and nginx listen directive
HTTPS_ENABLED=${HTTPS_ENABLED:-false}

if [ "$HTTPS_ENABLED" = "true" ]; then
    echo "HTTPS mode - configuring SSL/TLS on port 8080"
    # Validate SSL certificates exist
    if [ ! -f "/app/certs/tls.crt" ] || [ ! -f "/app/certs/tls.key" ]; then
        echo "ERROR: HTTPS enabled but SSL certificate files missing!"
        exit 1
    fi
    LISTEN_DIRECTIVE="listen 8080 ssl;"
else
    echo "HTTP mode - plain HTTP on port 8080"
    LISTEN_DIRECTIVE="listen 8080;"
    echo "# SSL disabled" > /app/nginx/ssl.conf
fi

# Update nginx listen directive
sed -i "s|^[[:space:]]*listen[[:space:]]\+8080[^;]*;|    ${LISTEN_DIRECTIVE}|g" /app/nginx/server.conf

# Test nginx configuration
echo "Testing nginx configuration..."
nginx -t

if [ $? -ne 0 ]; then
    echo "ERROR: Nginx configuration test failed!"
    exit 1
fi

exec nginx -g 'daemon off;'