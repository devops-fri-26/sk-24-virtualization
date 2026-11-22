#!/usr/bin/env bash
# QEMU user networking works on Wi-Fi. Docker supplies the host-side QEMU binaries.
set -euo pipefail
if [[ $# != 3 ]]; then
    echo "Usage: $0 KIT_DIR LAPTOP_LAN_IPV4 VM_STATE_DIR" >&2
    exit 2
fi
kit=$(realpath -e "$1")
lan_ip=$2
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$lan_ip"
ip -o -4 addr show | awk -v ip="$lan_ip" '{split($4,a,"/"); if(a[1]==ip) found=1} END {exit !found}' || {
    echo "The laptop does not currently own $lan_ip." >&2; exit 1; }
mkdir -p -m 0700 "$3"
state=$(realpath "$3")
exec 9>"$state/.launch.lock"
flock -n 9 || { echo "Another launch is using this state directory." >&2; exit 1; }
seed="$kit/cidata.iso"
app=()
for file in "$kit"/*.iso; do
    if [[ "$file" != "$seed" ]]; then app+=("$file"); fi
done
[[ -f "$seed" && ${#app[@]} == 1 && -f "${app[0]}" ]]
infra=$(cd "$(dirname "$0")/.." && pwd)
image=fray-laptop-qemu:noble
name=fray-laptop
if docker container inspect "$name" >/dev/null 2>&1; then
    echo "Container $name exists. Use docker start $name to resume the same VM." >&2
    exit 1
fi
docker build -q -f "$infra/laptop/Dockerfile" -t "$image" "$infra" >/dev/null
base_args=(--user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges --mount "type=bind,src=$state,dst=/vm")
docker run --rm "${base_args[@]}" "$image" bash -ec '
    if [[ ! -e disk.qcow2 ]]; then
        base=$(fray-fetch-ubuntu /vm/images)
        qemu-img create -f qcow2 -F qcow2 -b "$base" disk.qcow2.new 32G
        mv disk.qcow2.new disk.qcow2
    fi'
docker run -dit --name "$name" --network host --device /dev/kvm --group-add "$(stat -c %g /dev/kvm)" \
    "${base_args[@]}" --mount "type=bind,src=$kit,dst=/kit,readonly" "$image" \
    qemu-system-x86_64 -machine accel=kvm -cpu host -smp 2 -m 4096 -display none -serial stdio -monitor none \
    -drive file=/vm/disk.qcow2,if=virtio,format=qcow2 \
    -drive file=/kit/cidata.iso,media=cdrom,format=raw,readonly=on \
    -drive "file=/kit/$(basename "${app[0]}"),media=cdrom,format=raw,readonly=on" \
    -device virtio-serial -chardev socket,path=/vm/agent.sock,server=on,wait=off,id=agent \
    -device virtserialport,chardev=agent,name=org.qemu.guest_agent.0 \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:$lan_ip:18080-:80,hostfwd=tcp:$lan_ip:18443-:443,hostfwd=tcp:127.0.0.1:18444-:8443"
echo "Guest console: docker attach $name (detach with Ctrl-P then Ctrl-Q)"
