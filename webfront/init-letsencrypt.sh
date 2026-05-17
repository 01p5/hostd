#!/bin/bash

# Initialize Let's Encrypt certificates for multiple domains
# This script is OPTIONAL - you can just run docker-compose up and certs will be auto-generated
# Use this script if you want to manually initialize certificates before starting services

set -e

DOMAINS_CONF="./domains.conf"
CERTBOT_DIR="./certbot"
NGINX_CONF_DIR="./nginx/conf.d"
EMAIL="admin@01p5.com"  # Change this to your email
STAGING=0  # Set to 1 for staging (testing) certificates

echo "=== Multi-Domain Let's Encrypt Initialization ==="

# Parse domains from config file
parse_domains() {
    grep -v '^#' "$DOMAINS_CONF" | grep -v '^[[:space:]]*$' | tr -d ' '
}

if [ ! -f "$DOMAINS_CONF" ]; then
    echo "ERROR: $DOMAINS_CONF not found!"
    echo "Please create domains.conf with your domain:port mappings"
    exit 1
fi

# Get all domains
DOMAINS=$(parse_domains | cut -d: -f1)

if [ -z "$DOMAINS" ]; then
    echo "ERROR: No domains configured in $DOMAINS_CONF"
    exit 1
fi

echo ">>> Configured domains:"
for domain in $DOMAINS; do
    echo "    - $domain"
done
echo ""

# Check for existing certificates
EXISTING_CERTS=""
MISSING_CERTS=""
for domain in $DOMAINS; do
    if [ -d "$CERTBOT_DIR/conf/live/$domain" ] && \
       [ -f "$CERTBOT_DIR/conf/live/$domain/fullchain.pem" ]; then
        EXISTING_CERTS="$EXISTING_CERTS $domain"
    else
        MISSING_CERTS="$MISSING_CERTS $domain"
    fi
done

if [ -n "$EXISTING_CERTS" ]; then
    echo ">>> Existing certificates found for:$EXISTING_CERTS"
fi

if [ -z "$MISSING_CERTS" ]; then
    echo ">>> All domains already have certificates!"
    echo ">>> To force renewal, delete the $CERTBOT_DIR/conf/live/<domain> directories"
    read -p "Do you want to skip certificate generation? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ">>> Skipping certificate generation."
        exit 0
    fi
    MISSING_CERTS=$DOMAINS
fi

echo ""
echo ">>> Domains needing certificates:$MISSING_CERTS"
echo ""

# Prepare directories
echo ">>> Preparing directories..."
mkdir -p "$CERTBOT_DIR/conf"
mkdir -p "$CERTBOT_DIR/www"
mkdir -p "$NGINX_CONF_DIR"

# Create temporary HTTP-only nginx configs for ACME challenge
echo ">>> Creating temporary nginx configs for ACME challenge..."
rm -f "$NGINX_CONF_DIR"/*.conf

for entry in $(parse_domains); do
    domain=$(echo "$entry" | cut -d: -f1)
    port=$(echo "$entry" | cut -d: -f2)
    
    cat > "$NGINX_CONF_DIR/${domain}.conf" << EOF
# Temporary HTTP-only config for Let's Encrypt challenge - $domain
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'Let'"'"'s Encrypt challenge server for $domain';
        add_header Content-Type text/plain;
    }
}
EOF
done

echo ">>> Starting nginx with temporary config..."
docker-compose up -d nginx

echo ">>> Waiting for nginx to start..."
sleep 5

# Staging or production?
STAGING_ARG=""
if [ $STAGING != "0" ]; then
    STAGING_ARG="--staging"
    echo ">>> Using Let's Encrypt STAGING environment (test certificates)"
fi

# Request certificates for each domain
echo ""
for domain in $MISSING_CERTS; do
    echo ">>> Requesting certificate for $domain..."
    
    docker-compose run --rm certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        $STAGING_ARG \
        --email $EMAIL \
        --agree-tos \
        --no-eff-email \
        -d $domain
    
    if [ $? -eq 0 ]; then
        echo ">>> ✓ Certificate obtained for $domain"
    else
        echo ">>> ✗ Failed to obtain certificate for $domain"
    fi
    echo ""
done

echo ">>> Stopping temporary nginx..."
docker-compose down

echo ""
echo "=== Certificate initialization complete! ==="
echo ""
echo ">>> You can now start the full stack with:"
echo ">>>   docker-compose up -d"
echo ""
echo ">>> The system will automatically:"
echo ">>>   - Use HTTPS for domains with certificates"
echo ">>>   - Use HTTP for domains without certificates"
echo ">>>   - Switch to HTTPS when new certificates are obtained"
echo ">>>   - Renew certificates automatically every 12 hours"
echo ""
