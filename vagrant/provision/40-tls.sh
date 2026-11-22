#!/usr/bin/env bash
source /opt/provision/lib.sh

: "${FRAY_HOSTNAME:?FRAY_HOSTNAME must be set in vagrant/.env}"

log "Installing TLS tooling"
apt_install openssl ca-certificates

# The CA directory is root-only. The fray service user cannot read the CA key.
install -d -m 0700 /etc/fray-ca
printf 'HOST=%s\nGUEST_IP=%s\n' "$FRAY_HOSTNAME" "${FRAY_GUEST_IP:-192.168.56.10}" \
  > /etc/fray-ca/tls.conf

cat > /usr/local/sbin/fray-cert <<'SCRIPT'
#!/usr/bin/env bash
# Creates the local CA and issues/renews the server certificate. Idempotent.
set -euo pipefail
. /etc/fray-ca/tls.conf            # HOST, GUEST_IP

CA_DIR=/etc/fray-ca
OUT=/etc/ssl/fray
CA_CRT=$CA_DIR/ca.crt
CA_KEY=$CA_DIR/ca.key
SRV_CRT=$OUT/server.crt
SRV_KEY=$OUT/server.key
CHANGED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

install -d -m 0700 "$CA_DIR"
install -d -m 0755 "$OUT"

# Print a certificate extension (empty on failure; avoids SIGPIPE issues with grep -q)
ext() { openssl x509 -in "$1" -noout -ext "$2" 2>/dev/null || true; }

ca_ok() {
  [ -s "$CA_CRT" ] && [ -s "$CA_KEY" ] \
    && openssl x509 -in "$CA_CRT" -noout -checkend 7776000 >/dev/null \
    && [[ "$(ext "$CA_CRT" nameConstraints)" == *"DNS:$HOST"* ]]
}

srv_ok() {
  [ -s "$SRV_CRT" ] && [ -s "$SRV_KEY" ] \
    && openssl x509 -in "$SRV_CRT" -noout -checkend 2592000 >/dev/null \
    && [[ "$(ext "$SRV_CRT" subjectAltName)" == *"DNS:$HOST"* ]] \
    && [[ "$(ext "$SRV_CRT" subjectAltName)" == *"IP Address:$GUEST_IP"* ]] \
    && openssl verify -CAfile "$CA_CRT" "$SRV_CRT" >/dev/null 2>&1
}

# ---- CA (created once; recreated only if it is expiring or the hostname changed) ----
if ! ca_ok; then
  echo "==> Creating local CA for $HOST"
  cat > "$TMP/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = Fray Local CA ($HOST)
O = Fray
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,@nc
[nc]
permitted;DNS.0 = $HOST
permitted;IP.0 = $GUEST_IP/255.255.255.255
EOF
  ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY" )
  openssl req -x509 -new -key "$CA_KEY" -sha256 -days 1825 \
    -config "$TMP/ca.cnf" -out "$CA_CRT"
  chmod 0644 "$CA_CRT"
  rm -f "$SRV_CRT"                 # force a new server certificate
  CHANGED=1
fi

# ---- Server certificate (reissued when missing, wrong name, or < 30 days left) ----
if ! srv_ok; then
  echo "==> Issuing server certificate for $HOST and $GUEST_IP"
  ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$OUT/server.key.new" )
  openssl req -new -key "$OUT/server.key.new" -subj "/CN=$HOST" -out "$TMP/server.csr"
  cat > "$TMP/server.ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:$HOST,IP:$GUEST_IP
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
  openssl x509 -req -in "$TMP/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -set_serial "0x$(openssl rand -hex 15)" -days 365 -sha256 \
    -extfile "$TMP/server.ext" -out "$OUT/server.crt.new"
  mv "$OUT/server.key.new" "$SRV_KEY"
  mv "$OUT/server.crt.new" "$SRV_CRT"
  chmod 0600 "$SRV_KEY"
  chmod 0644 "$SRV_CRT"
  CHANGED=1
fi

# ---- Trust the CA inside the VM too (curl, smoke tests, exporters) ----
if ! cmp -s "$CA_CRT" /usr/local/share/ca-certificates/fray-ca.crt 2>/dev/null; then
  install -m 0644 "$CA_CRT" /usr/local/share/ca-certificates/fray-ca.crt
  update-ca-certificates >/dev/null
fi

if [ "$CHANGED" = 1 ] && systemctl is-active --quiet nginx; then
  systemctl reload nginx
fi

openssl x509 -in "$SRV_CRT" -noout -subject -issuer -enddate
SCRIPT
chmod 0750 /usr/local/sbin/fray-cert

# ---- Daily renewal check ----
cat > /etc/systemd/system/fray-cert.service <<'EOF'
[Unit]
Description=Issue or renew the Fray server certificate

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fray-cert
EOF
cat > /etc/systemd/system/fray-cert.timer <<'EOF'
[Unit]
Description=Daily Fray certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now fray-cert.timer

log "Running fray-cert"
/usr/local/sbin/fray-cert
log "TLS finished"