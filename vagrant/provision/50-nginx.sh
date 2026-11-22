#!/usr/bin/env bash
source /opt/provision/lib.sh

: "${FRAY_HOSTNAME:?FRAY_HOSTNAME must be set in vagrant/.env}"

# ---- Certificate from the local CA (issued by 40-tls.sh) ----
CERT=/etc/ssl/fray/server.crt
KEY=/etc/ssl/fray/server.key
[ -s "$CERT" ] && [ -s "$KEY" ] || { echo "Certificate missing: run 40-tls first" >&2; exit 1; }
HSTS=''   # no HSTS: a visitor whose browser does not trust the CA could never click through

log "Installing nginx"
apt-get update -qq
apt_install nginx openssl

# ---- Global settings (http context) ----
cat > /etc/nginx/conf.d/fray-global.conf <<'EOF'
server_tokens off;
limit_req_zone $binary_remote_addr zone=fray_api:10m rate=10r/s;
limit_req_status 429;
# ---- gzip on ----
gzip_types text/css application/javascript application/json image/svg+xml application/wasm;
gzip_min_length 1024;
EOF

# ---- Site configuration from a template (placeholders avoid escaping nginx's $vars) ----
cat > /etc/nginx/sites-available/fray <<'EOF'
# Anything that is not our hostname gets no answer
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    ssl_certificate     @CERT@;
    ssl_certificate_key @KEY@;
    server_name _;
    return 444;
}

server {
    listen 80;
    listen [::]:80;
    server_name @HOST@;
    return 301 https://@HOST@$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name @HOST@;

    ssl_certificate     @CERT@;
    ssl_certificate_key @KEY@;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    @HSTS@
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "geolocation=(), camera=(), microphone=()" always;

    root /opt/fray/current/web;
    index index.html;
    client_max_body_size 1m;

    # The Flutter shell must never be cached, or users get stale app versions
    location ~* ^/(index\.html|flutter_service_worker\.js|flutter_bootstrap\.js|version\.json)$ {
        expires -1;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Prometheus metrics are for local scraping only
    location ~ ^/(api/)?metrics/?$ {
        return 404;
    }

    location /api/ {
        limit_req zone=fray_api burst=20 nodelay;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
EOF

sed -i \
  -e "s|@HOST@|$FRAY_HOSTNAME|g" \
  -e "s|@CERT@|$CERT|g" \
  -e "s|@KEY@|$KEY|g" \
  -e "s|@HSTS@|$HSTS|g" \
  /etc/nginx/sites-available/fray

rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/fray-bootstrap
ln -sfn /etc/nginx/sites-available/fray /etc/nginx/sites-enabled/fray

nginx -t
systemctl enable nginx
systemctl restart nginx   # restart (not reload) so certificate changes are always picked up

# ---- fail2ban jails for nginx (log files exist now) ----
log "Adding nginx fail2ban jails"
cat > /etc/fail2ban/jail.d/fray-nginx.local <<'EOF'
[nginx-limit-req]
enabled = true
port    = http,https
logpath = /var/log/nginx/error.log

[nginx-botsearch]
enabled = true
port    = http,https
logpath = /var/log/nginx/access.log
EOF
systemctl restart fail2ban

log "Nginx finished"