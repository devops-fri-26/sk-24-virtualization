#!/usr/bin/env bash
source /opt/provision/lib.sh

log "Installing Redis"
apt-get update -qq
apt_install redis-server redis-tools

# ---- Password (generated once, kept across reruns) ----
ensure_secret FRAY_REDIS_PASSWORD 40
RPW=$(getv FRAY_REDIS_PASSWORD)

# ---- Our settings live in a separate file, included from redis.conf ----
log "Writing Redis config"
TMP=$(mktemp)
cat > "$TMP" <<EOF
bind 127.0.0.1 -::1
port 6379
protected-mode yes
requirepass $RPW
maxmemory 128mb
maxmemory-policy allkeys-lru
EOF

CHANGED=0
if ! cmp -s "$TMP" /etc/redis/fray.conf 2>/dev/null; then
  # The file holds the password, so only root and the redis user may read it
  install -m 0640 -o root -g redis "$TMP" /etc/redis/fray.conf
  CHANGED=1
fi
rm -f "$TMP"

# Redis applies the LAST value it reads, so the include goes at the end of redis.conf
if ! grep -q '^include /etc/redis/fray.conf' /etc/redis/redis.conf; then
  echo 'include /etc/redis/fray.conf' >> /etc/redis/redis.conf
  CHANGED=1
fi

systemctl enable redis-server
if [ "$CHANGED" = 1 ]; then
  log "Config changed, restarting Redis"
  systemctl restart redis-server
else
  systemctl start redis-server
fi

# Wait until Redis answers (authenticated)
for i in $(seq 1 30); do
  [ "$(REDISCLI_AUTH="$RPW" redis-cli ping 2>/dev/null)" = "PONG" ] && break
  sleep 1
done
[ "$(REDISCLI_AUTH="$RPW" redis-cli ping)" = "PONG" ]

log "Redis finished"