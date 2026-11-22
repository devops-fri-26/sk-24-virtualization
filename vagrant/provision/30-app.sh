#!/usr/bin/env bash
source /opt/provision/lib.sh

: "${FRAY_HOSTNAME:?FRAY_HOSTNAME must be set in vagrant/.env}"

WSGI_APP="fray.wsgi:application"

APP_DIR=/opt/fray
VENV=$APP_DIR/venv

# ---- Packages and service user ----
log "Installing Python packages"
apt-get update -qq
apt_install python3 python3-venv python3-pip curl

id fray >/dev/null 2>&1 || useradd --system --home-dir "$APP_DIR" \
  --shell /usr/sbin/nologin fray
install -d -m 0755 -o root -g root "$APP_DIR" "$APP_DIR/releases"

# fray must be able to enter /etc/fray to read its env file
chgrp fray /etc/fray
chmod 0750 /etc/fray

# ---- Verify and unpack the release ----
log "Verifying release artifact"
cd /opt/artifacts
EXPECTED=$(cut -d' ' -f1 fray-latest.tar.gz.sha256)
ACTUAL=$(sha256sum fray-latest.tar.gz | cut -d' ' -f1)
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Checksum mismatch" >&2; exit 1; }

VER=$(tar -xzOf fray-latest.tar.gz ./VERSION | tr -d '[:space:]')
REL=$APP_DIR/releases/$VER
if [ ! -d "$REL" ]; then
  log "Unpacking release $VER"
  mkdir -p "$REL.tmp"
  tar -xzf fray-latest.tar.gz -C "$REL.tmp"
  mv "$REL.tmp" "$REL"
fi
chown -R root:root "$REL"
chmod -R u=rwX,go=rX "$REL"     # root writes; everyone else reads and enters, never writes
ln -sfn "$REL" "$APP_DIR/current"

# ---- Virtualenv and dependencies ----
log "Creating virtualenv"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
REQ=$APP_DIR/current/backend/requirements.txt

if ! grep -qiE 'psycopg2?[-\[ ]*binary' "$REQ"; then
  apt_install build-essential python3-dev libpq-dev
fi

"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REQ"
if [ ! -x "$VENV/bin/gunicorn" ]; then
  echo "WARNING: gunicorn is not in requirements.txt, installing unpinned" >&2
  "$VENV/bin/pip" install --quiet gunicorn
fi

# ---- Environment file ----
log "Writing environment file"

# Secrets: written once, never regenerated.
# FRAY_MFA_KEY protects enrolled authenticator seeds; losing it locks users out.
ensure_value FRAY_SECRET_KEY "$(openssl rand -hex 48)"
ensure_value FRAY_MFA_KEY \
  "$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"

# Derived settings: rewritten every run so they always match known values.
set_env FRAY_HOSTS   "$FRAY_HOSTNAME"
set_env FRAY_ORIGINS "https://$FRAY_HOSTNAME"
set_env FRAY_DB_HOST 127.0.0.1
set_env FRAY_DB_PORT 5432
set_env FRAY_DB_NAME fray
set_env FRAY_DB_USER fray
set_env FRAY_DB_PASSWORD "$(getv FRAY_DB_PASSWORD)"
set_env FRAY_REDIS_URL "redis://:$(getv FRAY_REDIS_PASSWORD)@127.0.0.1:6379/0"
# FRAY_DEBUG is deliberately NOT set: settings.py only enables debug when it is "1".

# Optional pass-through from vagrant/.env (email for signup, limits)
for v in FRAY_SIGNUP_ENABLED FRAY_SIGNUP_EMAIL_LIMIT FRAY_EMAIL_HOST \
         FRAY_EMAIL_PORT FRAY_EMAIL_USER FRAY_EMAIL_PASSWORD FRAY_EMAIL_FROM \
         FRAY_EMAIL_USE_TLS FRAY_EMAIL_USE_SSL; do
  if [ -n "${!v:-}" ]; then set_env "$v" "${!v}"; fi
done

chown root:fray "$FRAY_ENV"
chmod 0640 "$FRAY_ENV"

# ---- Run management commands the same way the service will run ----
run_app() {
  systemd-run --quiet --wait --collect --pipe \
    -p User=fray -p Group=fray -p EnvironmentFile="$FRAY_ENV" \
    -p WorkingDirectory="$APP_DIR/current/backend" \
    "$VENV/bin/python" manage.py "$@"
}

log "Running Django checks and migrations"
run_app check --deploy || echo "WARNING: 'check --deploy' reported issues (see above)" >&2
run_app migrate --noinput

# ---- Gunicorn service ----
log "Installing systemd units"
cat > /etc/systemd/system/fray-api.service <<EOF
[Unit]
Description=Fray Django API (Gunicorn)
After=network.target postgresql.service redis-server.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
User=fray
Group=fray
WorkingDirectory=$APP_DIR/current/backend
EnvironmentFile=$FRAY_ENV
ExecStart=$VENV/bin/gunicorn $WSGI_APP \\
  --bind 127.0.0.1:8000 --workers 2 --threads 4 --timeout 60 \\
  --worker-tmp-dir /tmp --access-logfile - --error-logfile -
Restart=always
RestartSec=3

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

# Daily cleanup of expired sessions and short-lived signup data
cat > /etc/systemd/system/fray-cleanup.service <<EOF
[Unit]
Description=Fray expired session and challenge cleanup
After=postgresql.service redis-server.service

[Service]
Type=oneshot
User=fray
Group=fray
WorkingDirectory=$APP_DIR/current/backend
EnvironmentFile=$FRAY_ENV
ExecStart=$VENV/bin/python manage.py clearsessions
ExecStart=$VENV/bin/python manage.py clear_auth_challenges
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
EOF

cat > /etc/systemd/system/fray-cleanup.timer <<'EOF'
[Unit]
Description=Daily Fray cleanup

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable fray-api fray-cleanup.timer
systemctl restart fray-api        # picks up new release and env on every run
systemctl start fray-cleanup.timer

# ---- Wait for the API ----
log "Waiting for the API health endpoint"
curl -fsS --retry 30 --retry-connrefused --retry-delay 1 \
  -H "Host: $FRAY_HOSTNAME" -H "X-Forwarded-Proto: https" \
  http://127.0.0.1:8000/api/health
echo
log "App finished"