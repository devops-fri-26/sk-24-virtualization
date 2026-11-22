#!/usr/bin/env bash
# Invoked by fray-provision as root on a dedicated Ubuntu 24.04 cloud VM.
set -euo pipefail
release=$1 domain=$2 admin_net=$4 ssh_mode=$5
grafana_access=${8:-private}
cfg=$release/guest
export DEBIAN_FRONTEND=noninteractive
source /etc/os-release
[[ "$ID:$VERSION_ID" == ubuntu:24.04 ]]

ufw default deny incoming
if [[ "$ssh_mode" == key ]]; then
    ufw allow from "$admin_net" to any port 22 proto tcp
else
    systemctl disable --now ssh.socket ssh.service
fi
ufw allow from "$admin_net" to any port 8443 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/fray-grafana.asc
chmod 0644 /etc/apt/keyrings/fray-grafana.asc
echo 'deb [signed-by=/etc/apt/keyrings/fray-grafana.asc] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/fray-grafana.list
apt-get update
bash "$cfg/configure-grafana.sh" "$domain" localhost:18444 "$grafana_access"
apt-get install -y --no-install-recommends nginx postgresql redis-server python3-venv \
    prometheus prometheus-node-exporter grafana loki alloy

id fray &>/dev/null || useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin fray
usermod -aG redis fray
usermod -aG systemd-journal alloy
systemctl enable --now postgresql
# Local peer auth maps the service's OS identity to this unprivileged database role.
if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='fray'" | grep -qx 1; then
    runuser -u postgres -- createuser --no-superuser --no-createdb --no-createrole fray
fi
if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname='fray'" | grep -qx 1; then
    runuser -u postgres -- createdb -O fray fray
fi
cat > /etc/redis/fray.conf <<'REDIS'
port 0
unixsocket /run/redis/redis-server.sock
unixsocketperm 770
REDIS
grep -qxF 'include /etc/redis/fray.conf' /etc/redis/redis.conf || echo 'include /etc/redis/fray.conf' >> /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server

# Generate once. Re-running the installer must preserve MFA enrollments and passwords.
if [[ ! -e /etc/fray/app.env ]]; then
    tmp=$(mktemp /etc/fray/app.env.XXXXXX)
    python3 - <<'PY' > "$tmp"
import base64, secrets
print("FRAY_SECRET_KEY=" + secrets.token_hex(48))
print("FRAY_MFA_KEY=" + base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())
print("FRAY_DB_NAME=fray\nFRAY_DB_USER=fray\nFRAY_DB_PASSWORD=\nFRAY_DB_HOST=/var/run/postgresql")
print("FRAY_REDIS_URL=unix:///run/redis/redis-server.sock?db=0")
print("FRAY_SIGNUP_ENABLED=0")
PY
    mv "$tmp" /etc/fray/app.env
fi
printf 'FRAY_HOSTS=%s,localhost,127.0.0.1\nFRAY_ORIGINS=https://%s\n' "$domain" "$domain" > /etc/fray/site.env
python3 -m venv "$release/venv"
"$release/venv/bin/pip" install --disable-pip-version-check -r "$release/backend/requirements.txt"
ln -sfnT "$release" /opt/fray/current.next
mv -Tf /opt/fray/current.next /opt/fray/current
install -m 0644 "$cfg/fray.service" /etc/systemd/system/fray.service
install -m 0755 "$cfg/fray-manage" /usr/local/sbin/fray-manage
if [[ ! -e /etc/fray/web-tls.conf ]]; then
    printf 'ssl_certificate /etc/fray/origin.crt;\nssl_certificate_key /etc/fray/origin.key;\n' > /etc/fray/web-tls.conf
fi
apt-get install -y --no-install-recommends certbot
install -d -m 0755 /var/www/fray-acme/.well-known/acme-challenge /etc/letsencrypt/renewal-hooks/deploy
printf 'Fray HTTP-01 ready for %s\n' "$domain" > /var/www/fray-acme/.well-known/acme-challenge/fray-ready
printf '%s\n' "$domain" > /etc/fray/acme-domain
install -m 0755 "$cfg/fray-acme" /usr/local/sbin/fray-acme
printf '#!/bin/sh\nset -eu\nnginx -t\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/50-fray-nginx
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/50-fray-nginx
sed "s/@DOMAIN@/$domain/g" "$cfg/http01.conf" > /etc/nginx/sites-available/fray-http01
ln -sfn /etc/nginx/sites-available/fray-http01 /etc/nginx/sites-enabled/fray-http01
sed "s/@DOMAIN@/$domain/g" "$cfg/nginx.conf" > /etc/nginx/sites-available/fray
ln -sfn /etc/nginx/sites-available/fray /etc/nginx/sites-enabled/fray
unlink /etc/nginx/sites-enabled/default 2>/dev/null || true

install -m 0644 "$cfg/prometheus.yml" /etc/prometheus/prometheus.yml
install -m 0644 "$cfg/alerts.yml" /etc/prometheus/fray-alerts.yml
echo 'ARGS="--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=15d"' > /etc/default/prometheus
echo 'ARGS="--web.listen-address=127.0.0.1:9100"' > /etc/default/prometheus-node-exporter
install -d -o loki -m 0750 /var/lib/loki
install -m 0644 "$cfg/loki.yml" /etc/loki/config.yml
install -m 0644 "$cfg/config.alloy" /etc/alloy/config.alloy
install -d /etc/systemd/system/loki.service.d /var/lib/grafana/fray-dashboards
printf '[Service]\nWorkingDirectory=/var/lib/loki\n' > /etc/systemd/system/loki.service.d/fray.conf
install -m 0644 "$cfg/datasources.yaml" /etc/grafana/provisioning/datasources/fray.yaml
install -m 0644 "$cfg/dashboards.yaml" /etc/grafana/provisioning/dashboards/fray.yaml
install -m 0644 "$cfg/fray.json" /var/lib/grafana/fray-dashboards/fray.json
nginx -t
promtool check config /etc/prometheus/prometheus.yml
alloy validate /etc/alloy/config.alloy
systemctl daemon-reload
units=(fray nginx prometheus-node-exporter prometheus loki alloy grafana-server)
systemctl enable "${units[@]}"
systemctl restart "${units[@]}"
# The laptop launcher provides the virtio guest-agent channel.
if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then systemctl start qemu-guest-agent; fi
curl -fsS --retry 30 --retry-all-errors --retry-delay 2 --cacert /etc/fray/origin-ca.crt --capath /etc/ssl/certs \
    --resolve "$domain:443:127.0.0.1" "https://$domain/api/health"
for url in http://127.0.0.1:3100/ready http://127.0.0.1:9090/-/ready http://127.0.0.1:3000/api/health; do
    curl -fsS --retry 45 --retry-all-errors --retry-delay 2 "$url"
done
# A live Loki endpoint alone cannot tell us whether Alloy delivered an access log.
python3 - <<'CHECK_LOGS'
import json
import time
from urllib.parse import urlencode
from urllib.request import urlopen

query = urlencode({"query": '{service="nginx"} |= "/api/health"', "limit": 1})
for attempt in range(30):
    with urlopen("http://127.0.0.1:3100/loki/api/v1/query_range?" + query, timeout=5) as response:
        if json.load(response)["data"]["result"]:
            print("Verified Nginx access logs in Loki")
            break
    time.sleep(2)
else:
    raise SystemExit("Missing Nginx access log in Loki; inspect journalctl -u nginx -u alloy -u loki")
CHECK_LOGS
echo "Fray is ready at https://$domain"
