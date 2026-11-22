#!/usr/bin/env bash
source /opt/provision/lib.sh

BACKUP_DIR=/var/backups/fray
install -d -m 0700 -o root -g root "$BACKUP_DIR"

# ---- Backup script ----
cat > /usr/local/sbin/fray-backup <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DIR=/var/backups/fray
KEEP_DAYS=7
TS=$(date +%Y%m%d-%H%M%S)
umask 077

TMP=$(mktemp "$DIR/.dump.XXXXXX")
trap 'rm -f "$TMP"' EXIT
runuser -u postgres -- pg_dump --format=custom fray > "$TMP"
runuser -u postgres -- pg_restore --list < "$TMP" >/dev/null     # reject a broken dump
mv "$TMP" "$DIR/fray-$TS.dump"
trap - EXIT

# The dump cannot decrypt enrolled authenticators; the MFA key lives in the env file
install -m 0600 /etc/fray/fray.env "$DIR/fray-$TS.env"

find "$DIR" -maxdepth 1 -type f \( -name 'fray-*.dump' -o -name 'fray-*.env' \) \
  -mtime +"$KEEP_DAYS" -delete
echo "Backup written: $DIR/fray-$TS.dump"
SCRIPT
chmod 0750 /usr/local/sbin/fray-backup

# ---- Restore drill: restore the newest dump into a throwaway database ----
cat > /usr/local/sbin/fray-restore-check <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DIR=/var/backups/fray
DB=fray_restore_check
LATEST=$(ls -1t "$DIR"/fray-*.dump 2>/dev/null | head -n1 || true)
[ -n "$LATEST" ] || { echo "No backup found" >&2; exit 1; }

psql_pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -tA "$@"; }
trap 'psql_pg -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true' EXIT

psql_pg -c "DROP DATABASE IF EXISTS $DB" >/dev/null
psql_pg -c "CREATE DATABASE $DB" >/dev/null
runuser -u postgres -- pg_restore --no-owner --no-privileges -d "$DB" < "$LATEST"

TABLES=$(psql_pg -d "$DB" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
MIGS=$(psql_pg -d "$DB" -c "SELECT count(*) FROM django_migrations")
[ "$TABLES" -gt 0 ] && [ "$MIGS" -gt 0 ]
echo "Restore check OK: $LATEST ($TABLES tables, $MIGS migrations)"
SCRIPT
chmod 0750 /usr/local/sbin/fray-restore-check

# ---- Schedule ----
cat > /etc/systemd/system/fray-backup.service <<'EOF'
[Unit]
Description=Fray database backup
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fray-backup
EOF

cat > /etc/systemd/system/fray-backup.timer <<'EOF'
[Unit]
Description=Daily Fray database backup

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now fray-backup.timer

# ---- First backup and restore drill now, so provisioning proves it works ----
if ! ls "$BACKUP_DIR"/fray-*.dump >/dev/null 2>&1; then
  log "Creating first backup"
  /usr/local/sbin/fray-backup
fi
log "Running restore drill"
/usr/local/sbin/fray-restore-check

log "Backup finished"