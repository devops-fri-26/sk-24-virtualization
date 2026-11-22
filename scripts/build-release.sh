#!/usr/bin/env bash
set -euo pipefail

APP=$(realpath "${1:?usage: build-release.sh /path/to/fray}")
cd "$(dirname "$0")/.."
OUT=$PWD/artifacts
mkdir -p "$OUT"

if [ -n "$(git -C "$APP" status --porcelain)" ]; then
  echo "App checkout has uncommitted changes; commit or stash first." >&2
  exit 1
fi
VER=$(git -C "$APP" rev-parse --short HEAD)

( cd "$APP/apps/fray" && flutter pub get && flutter build web --no-web-resources-cdn )

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/backend" "$STAGE/web"
chmod 755 "$STAGE"

rsync -a \
  --exclude '*.sqlite3' --exclude '__pycache__' --exclude '*.pyc' \
  --exclude '.venv' --exclude '.env*' --exclude '.artifacts' \
  "$APP/backend/" "$STAGE/backend/"
cp -r "$APP/apps/fray/build/web/." "$STAGE/web/"
echo "$VER" > "$STAGE/VERSION"

tar -C "$STAGE" -czf "$OUT/fray-$VER.tar.gz" .
( cd "$OUT" && sha256sum "fray-$VER.tar.gz" > "fray-$VER.tar.gz.sha256" )
cp "$OUT/fray-$VER.tar.gz" "$OUT/fray-latest.tar.gz"
( cd "$OUT" && sha256sum fray-latest.tar.gz > fray-latest.tar.gz.sha256 )
echo "Built fray-$VER.tar.gz"