#!/usr/bin/env bash
# Fetch the signed Ubuntu Noble image and cache it by SHA-256.
set -euo pipefail
out=${1:?Supply a local image cache directory}
mkdir -p "$out"
out=$(realpath "$out")
tmp=$(mktemp -d "$out/.download.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
base=https://cloud-images.ubuntu.com/noble/current
image=noble-server-cloudimg-amd64.img
signer=D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81
curl -fsSL --retry 3 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$signer" -o signer.asc
gpg --batch --no-autostart --no-default-keyring --homedir "$tmp" --keyring "$tmp/keys.gpg" --import signer.asc >&2
gpg --batch --no-autostart --homedir "$tmp" --no-default-keyring --keyring "$tmp/keys.gpg" --export "$signer" > trusted.gpg
test -s trusted.gpg
curl -fsSLO --retry 3 "$base/SHA256SUMS"
curl -fsSLO --retry 3 "$base/SHA256SUMS.gpg"
gpgv --keyring "$tmp/trusted.gpg" SHA256SUMS.gpg SHA256SUMS >&2
sha=$(awk -v f="$image" '$2==f || $2=="*"f {print $1}' SHA256SUMS)
[[ "$sha" =~ ^[a-f0-9]{64}$ ]]
dest="$out/noble-$sha.img"
if [[ ! -f "$dest" ]]; then
    curl -fL --retry 3 "$base/$image" -o "$image"
    echo "$sha  $image" | sha256sum --check --status
    mv "$image" "$dest"
else
    echo "$sha  $dest" | sha256sum --check --status
fi
echo "$dest"
