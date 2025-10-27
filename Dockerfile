# =============================================================================
# FRONTEND MINIFICATION STAGE
# =============================================================================
FROM tdewolff/minify:v2.24.3 AS minifier

# Copy frontend files for minification
COPY nginx/static /static

# Minify all frontend files in place
RUN minify --recursive --inplace /static

# =============================================================================
# MAIN APPLICATION STAGE
# =============================================================================
FROM alpine:3.22

# Install dependencies
RUN apk add --no-cache \
    nginx \
    nginx-mod-http-lua \
    lua \
    lua-cjson \
    lua-dev \
    luarocks \
    bash \
    curl \
    expect \
    unzip \
    openssl \
    net-tools \
    iproute2 \
    procps \
    sqlite \
    sqlite-dev \
    gcc \
    build-base \
    openssl-dev \
    pcre-dev \
    zlib-dev \
    ttyd \
    openssh-client

# Install lua-resty dependencies using luarocks-5.1
RUN luarocks-5.1 install lua-resty-string && \
    luarocks-5.1 install lua-resty-http && \
    luarocks-5.1 install lua-resty-session && \
    luarocks-5.1 install lua-resty-openidc && \
    luarocks-5.1 install lsqlite3 && \
    luarocks-5.1 install luacov && \
    luarocks-5.1 install busted && \
    luarocks-5.1 install luassert

# Create app structure
WORKDIR /app
COPY . /app/

# Copy minified frontend files from minifier stage (overwrite the original static files)
COPY --from=minifier /static /app/nginx/static

# Create data directory and set permissions
RUN mkdir -p /app/data && \
    chown -R nginx:nginx /app/data && \
    chmod 755 /app/data

# Configure nginx
RUN rm -f /etc/nginx/nginx.conf && \
    ln -sf /app/nginx/nginx.conf /etc/nginx/nginx.conf

# Create nginx directories
RUN mkdir -p /var/log/nginx && \
    mkdir -p /var/run/nginx && \
    mkdir -p /app/logs

# Set permissions
RUN chown -R nginx:nginx /app && \
    chmod +x /app/scripts/*

# Expose single port (HTTP or HTTPS based on HTTPS_ENABLED env var)
EXPOSE 8080

# Start nginx
CMD ["/app/scripts/start.sh"] 