#!/usr/bin/env bash
source /opt/provision/lib.sh

: "${FRAY_HOSTNAME:?FRAY_HOSTNAME must be set in vagrant/.env}"

GENV=/etc/grafana/grafana.env
val_from() { grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

# ---- Grafana from the official signed apt repository ----
log "Adding the Grafana apt repository"
apt_install gpg curl ca-certificates
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt_install grafana

# ---- Read-only PostgreSQL role for Grafana ----
log "Creating read-only database role for Grafana"
DBPW=$(val_from "$GENV" GRAFANA_DB_PASSWORD); [ -n "$DBPW" ] || DBPW=$(gen 32)
sudo -u postgres psql -v ON_ERROR_STOP=1 -v pw="$DBPW" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    CREATE ROLE grafana_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;
ALTER ROLE grafana_ro PASSWORD :'pw';
ALTER ROLE grafana_ro SET default_transaction_read_only = on;
GRANT pg_monitor TO grafana_ro;
GRANT CONNECT ON DATABASE fray TO grafana_ro;
SQL

# ---- Grafana settings (environment file; secrets are kept across reruns) ----
log "Configuring Grafana"
ADMINPW=$(val_from "$GENV" GF_SECURITY_ADMIN_PASSWORD); [ -n "$ADMINPW" ] || ADMINPW=$(gen 24)
SECRETKEY=$(val_from "$GENV" GF_SECURITY_SECRET_KEY);   [ -n "$SECRETKEY" ] || SECRETKEY=$(gen 32)

install -d -m 0755 /etc/grafana
( umask 077
  cat > "$GENV" <<EOF
GF_SERVER_HTTP_ADDR=127.0.0.1
GF_SERVER_HTTP_PORT=3000
GF_SERVER_DOMAIN=$FRAY_HOSTNAME
GF_SERVER_ROOT_URL=https://$FRAY_HOSTNAME/grafana/
GF_SERVER_SERVE_FROM_SUB_PATH=true
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$ADMINPW
GF_SECURITY_SECRET_KEY=$SECRETKEY
GF_SECURITY_COOKIE_SECURE=true
GF_SECURITY_DISABLE_GRAVATAR=true
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GRAFANA_DB_PASSWORD=$DBPW
EOF
)
chmod 0600 "$GENV"

install -d /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/fray.conf <<EOF
[Service]
EnvironmentFile=$GENV
EOF

# ---- Provisioned data source (no clicking in the UI) ----
install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/datasources/fray.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Fray PostgreSQL
    uid: fray-postgres
    type: postgres
    access: proxy
    url: 127.0.0.1:5432
    user: grafana_ro
    isDefault: true
    editable: false
    jsonData:
      database: fray
      sslmode: disable
      postgresVersion: 1600
      maxOpenConns: 5
    secureJsonData:
      password: $GRAFANA_DB_PASSWORD
EOF

cat > /etc/grafana/provisioning/dashboards/fray.yaml <<'EOF'
apiVersion: 1
providers:
  - name: fray
    folder: Fray
    type: file
    disableDeletion: true
    allowUiUpdates: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

# ---- Provisioned dashboard ----
install -d -o grafana -g grafana /var/lib/grafana/dashboards
cat > /var/lib/grafana/dashboards/fray-postgres.json <<'EOF'
{
  "uid": "fray-pg",
  "title": "Fray - PostgreSQL overview",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    { "id": 1, "type": "stat", "title": "Database size", "gridPos": { "h": 4, "w": 4, "x": 0, "y": 0 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false } },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT pg_database_size('fray') AS size" } ] },
    { "id": 2, "type": "stat", "title": "Active connections", "gridPos": { "h": 4, "w": 4, "x": 4, "y": 0 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": { "unit": "none" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false } },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = 'fray'" } ] },
    { "id": 3, "type": "stat", "title": "Cache hit ratio", "gridPos": { "h": 4, "w": 4, "x": 8, "y": 0 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": { "unit": "percent" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false } },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS ratio FROM pg_stat_database WHERE datname = 'fray'" } ] },
    { "id": 4, "type": "stat", "title": "PostgreSQL uptime", "gridPos": { "h": 4, "w": 4, "x": 12, "y": 0 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false } },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT extract(epoch FROM now() - pg_postmaster_start_time()) AS uptime" } ] },
    { "id": 5, "type": "stat", "title": "Commits", "gridPos": { "h": 4, "w": 4, "x": 16, "y": 0 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": { "unit": "none" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false } },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT xact_commit AS commits FROM pg_stat_database WHERE datname = 'fray'" } ] },
    { "id": 6, "type": "stat", "title": "Rollbacks", "gridPos": { "h": 4, "w": 4, "x": 20, "y": 0 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": { "unit": "none" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false } },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT xact_rollback AS rollbacks FROM pg_stat_database WHERE datname = 'fray'" } ] },
    { "id": 7, "type": "table", "title": "Largest tables", "gridPos": { "h": 9, "w": 12, "x": 0, "y": 4 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": {}, "overrides": [
        { "matcher": { "id": "byName", "options": "size_bytes" }, "properties": [ { "id": "unit", "value": "bytes" } ] } ] },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT relname AS table_name, n_live_tup AS live_rows, pg_total_relation_size(relid) AS size_bytes FROM pg_stat_user_tables ORDER BY size_bytes DESC LIMIT 10" } ] },
    { "id": 8, "type": "table", "title": "Sessions by state", "gridPos": { "h": 9, "w": 12, "x": 12, "y": 4 },
      "datasource": { "uid": "fray-postgres" },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "targets": [ { "refId": "A", "datasource": { "uid": "fray-postgres" }, "editorMode": "code", "format": "table", "rawQuery": true,
        "rawSql": "SELECT state, count(*) AS sessions FROM pg_stat_activity WHERE datname = 'fray' GROUP BY state ORDER BY sessions DESC" } ] }
  ]
}
EOF
python3 -m json.tool /var/lib/grafana/dashboards/fray-postgres.json >/dev/null  # sanity check
chown -R grafana:grafana /var/lib/grafana/dashboards

# ---- Start ----
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server

log "Waiting for Grafana"
curl -fsS --retry 40 --retry-connrefused --retry-delay 1 \
  http://127.0.0.1:3000/grafana/api/health
echo
log "Monitoring finished"