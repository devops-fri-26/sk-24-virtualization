#!/usr/bin/env bash
source /opt/provision/lib.sh

log "Updating package index"
apt-get update

log "Installing base packages"
apt_install ufw fail2ban unattended-upgrades curl ca-certificates \
  gnupg openssl jq

log "Timezone"
timedatectl set-timezone Europe/Ljubljana

# ---- Config directory and secrets file (created once, never overwritten) ----
log "Preparing /etc/fray"
install -d -m 0750 -o root -g root /etc/fray
[ -f "$FRAY_ENV" ] || install -m 0640 -o root -g root /dev/null "$FRAY_ENV"

# ---- SSH hardening ----
# sshd uses the FIRST value it sees, and cloud images ship files like
# 50-cloud-init.conf that enable passwords. A name starting with 00- is read first.
log "Hardening SSH"
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
EOF
sshd -t
systemctl reload ssh

# ---- Firewall ----
log "Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
ufw allow 80/tcp comment 'http'
ufw allow 443/tcp comment 'https'
ufw --force enable

# ---- fail2ban (SSH only for now; Nginx jails are added in the Nginx step) ----
log "Configuring fail2ban"
cat > /etc/fail2ban/jail.d/fray.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
# Never ban the Vagrant host-only network or the NAT gateway
ignoreip = 127.0.0.1/8 ::1 192.168.56.0/24 10.0.2.0/24

[sshd]
enabled = true
backend = systemd
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---- Persistent logs ----
log "Persistent journald"
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/fray.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=300M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald

# ---- Automatic security updates ----
log "Unattended upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

log "Base setup finished"