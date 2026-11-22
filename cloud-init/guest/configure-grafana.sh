#!/usr/bin/env bash
set -euo pipefail
domain=$1 private_host=$2 access=$3
cfg=$(cd "$(dirname "$0")" && pwd)
install -d /etc/fray /etc/nginx/snippets /etc/systemd/system/grafana-server.service.d
if [[ ! -e /etc/fray/grafana.env ]]; then
    tmp=$(mktemp /etc/fray/grafana.env.XXXXXX)
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$tmp"
    mv "$tmp" /etc/fray/grafana.env
fi
root_url="https://$private_host/"
snippet=/etc/nginx/snippets/fray-grafana.conf
if [[ "$access" == public ]]; then
    root_url="https://$domain/grafana/"
    install -m 0644 "$cfg/grafana-location.conf" "$snippet"
else
    install -m 0644 /dev/null "$snippet"
fi
cat > /etc/systemd/system/grafana-server.service.d/fray.conf <<UNIT
[Service]
EnvironmentFile=/etc/fray/grafana.env
Environment=GF_SERVER_HTTP_ADDR=127.0.0.1
Environment=GF_SERVER_ROOT_URL=$root_url
Environment=GF_SECURITY_COOKIE_SECURE=true
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_AUTH_ANONYMOUS_ENABLED=false
Environment=GF_PLUGINS_PREINSTALL_DISABLED=true
UNIT
