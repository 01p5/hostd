#!/bin/sh

# Certbot entrypoint that handles certificate generation for multiple domains
# Reads domain configuration and requests certificates for all domains

set -e

DOMAINS_CONF="/etc/nginx/domains.conf"
EMAIL="${CERTBOT_EMAIL:-admin@example.com}"
STAGING="${CERTBOT_STAGING:-0}"
CERT_BASE="/etc/letsencrypt/live"
CERTBOT_WWW="/var/www/certbot"

echo "=== Certbot Multi-Domain Auto-Setup ==="

# Parse domains.conf and return domain names only
parse_domains() {
    if [ ! -f "$DOMAINS_CONF" ]; then
        echo "ERROR: $DOMAINS_CONF not found!" >&2
        exit 1
    fi
    grep -v '^#' "$DOMAINS_CONF" | grep -v '^[[:space:]]*$' | cut -d: -f1 | tr -d ' '
}

# Check if domain has valid SSL certificate
has_valid_cert() {
    local domain="$1"
    [ -d "$CERT_BASE/$domain" ] && \
    [ -f "$CERT_BASE/$domain/fullchain.pem" ] && \
    [ -f "$CERT_BASE/$domain/privkey.pem" ]
}

# Obtain certificate for a single domain
obtain_certificate() {
    local domain="$1"
    
    echo ">>> Requesting certificate for $domain..."
    
    # Staging or production?
    STAGING_ARG=""
    if [ "$STAGING" != "0" ]; then
        STAGING_ARG="--staging"
        echo ">>> Using Let's Encrypt STAGING environment"
    fi
    
    certbot certonly \
        --webroot \
        --webroot-path="$CERTBOT_WWW" \
        $STAGING_ARG \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        -d "$domain"
    
    if [ $? -eq 0 ]; then
        echo ">>> ✓ Certificate obtained successfully for $domain!"
        return 0
    else
        echo ">>> ✗ Failed to obtain certificate for $domain"
        return 1
    fi
}

# Wait for nginx to be ready
echo ">>> Waiting 15 seconds for nginx to start..."
sleep 15

# Check and obtain certificates for all domains
echo ""
echo ">>> Checking certificates for all configured domains..."
echo ""

for domain in $(parse_domains); do
    if has_valid_cert "$domain"; then
        echo ">>> [$domain] Certificate already exists, skipping"
    else
        echo ">>> [$domain] No certificate found, requesting..."
        if obtain_certificate "$domain"; then
            echo ">>> [$domain] Success! Nginx will auto-detect within 30 seconds"
        else
            echo ">>> [$domain] Failed - will retry in next renewal cycle"
        fi
    fi
    echo ""
done

# Start the renewal loop
echo "=== Initial certificate check complete ==="
echo ">>> Starting certificate renewal loop (checks every 12 hours)..."
echo ""

trap exit TERM

while :; do
    sleep 12h &
    wait ${!}
    
    echo ""
    echo "=== Running scheduled certificate renewal check ==="
    
    # First, try to renew existing certificates
    certbot renew
    
    # Then, check for any new domains that might have been added
    echo ">>> Checking for new domains..."
    for domain in $(parse_domains); do
        if ! has_valid_cert "$domain"; then
            echo ">>> [$domain] Missing certificate, attempting to obtain..."
            obtain_certificate "$domain" || true
        fi
    done
    
    echo "=== Renewal check complete ==="
    echo ""
done
