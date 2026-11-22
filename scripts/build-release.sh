#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != --cloud-init ) ]]; then
  echo "Usage: $0 /path/to/fray [--cloud-init]" >&2
  exit 2
fi
APP=$(realpath "$1")
mode=${2:-vagrant}
cd "$(dirname "$0")/.."
OUT=$PWD/artifacts
pub_args=()
flutter_args=(--no-web-resources-cdn)
if [[ "$mode" == --cloud-init ]]; then
  OUT=$PWD/dist/fray-cloud
  pub_args+=(--enforce-lockfile)
  flutter_args+=(--csp --release --no-pub --no-wasm-dry-run)
fi
mkdir -p "$OUT"

if [ -n "$(git -C "$APP" status --porcelain)" ]; then
  echo "App checkout has uncommitted changes; commit or stash first." >&2
  exit 1
fi
VER=$(git -C "$APP" rev-parse --short HEAD)

(
  cd "$APP/apps/fray"
  flutter pub get "${pub_args[@]}"
  flutter build web "${flutter_args[@]}"
)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/backend" "$STAGE/web"
chmod 755 "$STAGE"

if [[ "$mode" == --cloud-init ]]; then
  git -C "$APP" archive HEAD backend | tar -xf - -C "$STAGE"
  cp -R cloud-init/guest "$STAGE/guest"
  cp "$APP/infra/docker/alerts.yml" "$APP/infra/docker/grafana/dashboards/fray.json" "$STAGE/guest/"
else
  rsync -a \
    --exclude '*.sqlite3' --exclude '__pycache__' --exclude '*.pyc' \
    --exclude '.venv' --exclude '.env*' --exclude '.artifacts' \
    "$APP/backend/" "$STAGE/backend/"
fi
cp -r "$APP/apps/fray/build/web/." "$STAGE/web/"
echo "$VER" > "$STAGE/VERSION"

if [[ "$mode" == --cloud-init ]]; then
  chmod -R u+rwX,go=rX "$STAGE/backend" "$STAGE/web" "$STAGE/guest"
  git -C "$APP" rev-parse HEAD > "$STAGE/revision"
  tar -C "$STAGE" -czf "$STAGE/release.tgz" backend web guest revision
  digest=$(sha256sum "$STAGE/release.tgz" | cut -c1-64)
  install -m 0644 "$STAGE/release.tgz" "$OUT/fray-$digest.tgz"
  echo "Release: $OUT/fray-$digest.tgz"
  exit 0
fi
tar -C "$STAGE" -czf "$OUT/fray-$VER.tar.gz" .
( cd "$OUT" && sha256sum "fray-$VER.tar.gz" > "fray-$VER.tar.gz.sha256" )
cp "$OUT/fray-$VER.tar.gz" "$OUT/fray-latest.tar.gz"
( cd "$OUT" && sha256sum fray-latest.tar.gz > fray-latest.tar.gz.sha256 )
echo "Built fray-$VER.tar.gz"
