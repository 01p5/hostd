#!/bin/sh

# Nginx entrypoint that handles SSL certificates for multiple domains
# Reads domain configuration and dynamically generates nginx configs

set -e

DOMAINS_CONF="/etc/nginx/domains.conf"
CONF_DIR="/etc/nginx/conf.d"
CERT_BASE="/etc/letsencrypt/live"
CERTBOT_WWW="/var/www/certbot"
EMAIL="${CERTBOT_EMAIL:-admin@example.com}"

echo "=== Nginx Multi-Domain Smart Startup ==="

# Parse domains.conf and return domain:port pairs
parse_domains() {
    if [ ! -f "$DOMAINS_CONF" ]; then
        echo "ERROR: $DOMAINS_CONF not found!" >&2
        exit 1
    fi
    grep -v '^#' "$DOMAINS_CONF" | grep -v '^[[:space:]]*$' | tr -d ' '
}

# Generate HTTP-only config for a domain (for ACME challenge + optional proxy)
generate_http_config() {
    local domain="$1"
    local port="$2"
    
    cat << EOF
# HTTP config for $domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    # Let's Encrypt challenge location
    location /.well-known/acme-challenge/ {
        root $CERTBOT_WWW;
    }

    # Proxy to backend (HTTP mode while waiting for cert)
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
}

# Generate HTTPS config for a domain
generate_https_config() {
    local domain="$1"
    local port="$2"
    
    cat << EOF
# HTTP - redirect to HTTPS for $domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    # Let's Encrypt challenge location
    location /.well-known/acme-challenge/ {
        root $CERTBOT_WWW;
    }

    # Redirect all other HTTP traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS config for $domain
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;

    # SSL certificates
    ssl_certificate $CERT_BASE/$domain/fullchain.pem;
    ssl_certificate_key $CERT_BASE/$domain/privkey.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Disable body size limit for docker push
    client_max_body_size 0;
    
    # Increase timeouts for large uploads
    proxy_read_timeout 900;
    proxy_send_timeout 900;
    send_timeout 900;

    # Proxy to backend
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
	proxy_set_header Authorization \$http_authorization;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

	# for docker
	proxy_buffering off;
        proxy_request_buffering off;
        chunked_transfer_encoding on;

        # Timeouts for large pushes
        proxy_read_timeout 900;
        proxy_send_timeout 900;

        # Timeouts
        proxy_connect_timeout 60s;
    }
}
EOF
}

# Check if domain has valid SSL certificate
has_valid_cert() {
    local domain="$1"
    [ -f "$CERT_BASE/$domain/fullchain.pem" ] && [ -f "$CERT_BASE/$domain/privkey.pem" ]
}

# Generate all nginx configs based on certificate availability
generate_all_configs() {
    echo ">>> Generating nginx configurations..."
    
    # Clear existing domain configs
    rm -f "$CONF_DIR"/*.conf
    
    local domains_with_ssl=""
    local domains_without_ssl=""
    
    for entry in $(parse_domains); do
        domain=$(echo "$entry" | cut -d: -f1)
        port=$(echo "$entry" | cut -d: -f2)
        
        if has_valid_cert "$domain"; then
            echo ">>> [$domain:$port] SSL certificate found - enabling HTTPS"
            generate_https_config "$domain" "$port" > "$CONF_DIR/${domain}.conf"
            domains_with_ssl="$domains_with_ssl $domain"
        else
            echo ">>> [$domain:$port] No SSL certificate - HTTP only mode"
            generate_http_config "$domain" "$port" > "$CONF_DIR/${domain}.conf"
            domains_without_ssl="$domains_without_ssl $domain"
        fi
    done
    
    echo ""
    if [ -n "$domains_with_ssl" ]; then
        echo ">>> Domains with HTTPS:$domains_with_ssl"
    fi
    if [ -n "$domains_without_ssl" ]; then
        echo ">>> Domains pending SSL:$domains_without_ssl"
    fi
    echo ""
}

# Check if any domain needs SSL upgrade
check_for_new_certs() {
    for entry in $(parse_domains); do
        domain=$(echo "$entry" | cut -d: -f1)
        
        # Check if domain config exists but doesn't have HTTPS
        if [ -f "$CONF_DIR/${domain}.conf" ]; then
            if ! grep -q "listen 443" "$CONF_DIR/${domain}.conf" 2>/dev/null; then
                if has_valid_cert "$domain"; then
                    return 0  # Found a domain that needs upgrade
                fi
            fi
        fi
    done
    return 1  # No upgrades needed
}

# Initial config generation
generate_all_configs

# Test configuration
echo ">>> Testing nginx configuration..."
nginx -t

# Start nginx in background
echo ">>> Starting nginx..."
nginx -g "daemon off;" &
NGINX_PID=$!

# Monitor for certificate availability and reload when needed
echo ">>> Starting certificate monitor (checks every 30 seconds)..."
while kill -0 $NGINX_PID 2>/dev/null; do
    sleep 30
    
    # Check if any domain got new certificates
    if check_for_new_certs; then
        echo ""
        echo ">>> New certificates detected! Regenerating configurations..."
        generate_all_configs
        
        echo ">>> Testing new configuration..."
        if nginx -t 2>/dev/null; then
            echo ">>> Reloading nginx..."
            nginx -s reload
            echo ">>> Nginx reloaded with new SSL certificates! 🔒"
        else
            echo ">>> Configuration test failed, keeping current config"
        fi
        echo ""
    fi
done

echo ">>> nginx stopped"
wait $NGINX_PID