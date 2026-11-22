#!/usr/bin/env bash
source /opt/provision/lib.sh

log "Installing PostgreSQL"
apt-get update -qq
apt_install postgresql postgresql-contrib

PGVER=$(ls /etc/postgresql | sort -V | tail -n1)
CONF_DIR=/etc/postgresql/$PGVER/main/conf.d
install -d -o postgres -g postgres "$CONF_DIR"

# ---- Server configuration (drop-in, so the packaged postgresql.conf stays untouched) ----
log "Writing PostgreSQL drop-in config"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
listen_addresses = '127.0.0.1'
password_encryption = 'scram-sha-256'
max_connections = 50
shared_buffers = 256MB
log_connections = on
log_disconnections = on
log_min_duration_statement = 500
log_line_prefix = '%m [%p] %q%u@%d '
EOF
if ! cmp -s "$TMP" "$CONF_DIR/fray.conf"; then
  install -m 0644 -o postgres -g postgres "$TMP" "$CONF_DIR/fray.conf"
  CHANGED=1
fi
rm -f "$TMP"

systemctl enable postgresql
if [ "${CHANGED:-0}" = 1 ]; then
  log "Config changed, restarting PostgreSQL"
  systemctl restart postgresql
else
  systemctl start postgresql
fi

# Wait until the server accepts connections
for i in $(seq 1 30); do
  sudo -u postgres pg_isready -q && break
  sleep 1
done
sudo -u postgres pg_isready

# ---- Application role and database ----
log "Creating application role and database"
ensure_secret FRAY_DB_PASSWORD 32
DBPW=$(getv FRAY_DB_PASSWORD)

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='fray'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE fray LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
fi

# The password is passed as a psql variable, so it is quoted safely by psql.
# (:'pw' is only substituted when the SQL comes from stdin, hence the heredoc.)
sudo -u postgres psql -v ON_ERROR_STOP=1 -v pw="$DBPW" <<'SQL'
ALTER ROLE fray PASSWORD :'pw';
SQL

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='fray'" | grep -q 1; then
  sudo -u postgres createdb --owner=fray --encoding=UTF8 fray
fi

# Nobody except the owner may connect to this database
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "REVOKE ALL ON DATABASE fray FROM PUBLIC"

log "PostgreSQL finished"