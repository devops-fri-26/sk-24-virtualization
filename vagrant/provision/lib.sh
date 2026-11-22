# Shared helpers, sourced by every provisioning script.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

FRAY_ENV=/etc/fray/fray.env

log() { echo "==> $*"; }

apt_install() {
  apt-get install -y --no-install-recommends "$@"
}

# Random alphanumeric string of length $1 (default 32)
gen() {
  local n=${1:-32}
  openssl rand -base64 $((n * 2)) | tr -dc 'A-Za-z0-9' | cut -c1-"$n"
}

# Add KEY=<random> to the env file ONLY if KEY is not there yet.
# This is what keeps secrets stable when provisioning is rerun.
ensure_secret() {
  grep -q "^$1=" "$FRAY_ENV" || echo "$1=$(gen "${2:-40}")" >> "$FRAY_ENV"
}

# Set KEY=VALUE (replace if present, append otherwise). For non-secret config.
set_env() {
  local tmp
  tmp=$(mktemp)
  grep -v "^$1=" "$FRAY_ENV" > "$tmp" || true
  echo "$1=$2" >> "$tmp"
  cat "$tmp" > "$FRAY_ENV"        # cat keeps the file's owner and mode
  rm -f "$tmp"
}

# Read a value from the env file (empty if missing)
getv() {
  grep "^$1=" "$FRAY_ENV" | head -n1 | cut -d= -f2- || true
}

ensure_value() {
  grep -q "^$1=" "$FRAY_ENV" || echo "$1=$2" >> "$FRAY_ENV"
}