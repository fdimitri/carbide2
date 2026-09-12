#!/usr/bin/env bash
# vm-harness.sh — boot/tear down throwaway Ubuntu VMs on libvirt, across one or
# more physical hosts (via SSH), on qcow2 files or direct LVs.
#
#   source scripts/ci/lib/vm-harness.sh
#   vm_up 3            # boot 3 VMs (one per VM_HOSTS entry), wait for SSH
#   vm_ips             # list "name ip"
#   vm_destroy         # power off + undefine + remove disks/seeds
#
# Hosts: VM_HOSTS is a space list, one entry per VM, "" => run locally. Empty
# VM_HOSTS means every VM is local (single-host, the previous behaviour):
#   VM_HOSTS="carbidium1 carbidium2 carbidium3"   # VM i on host i
#
# Storage: VM_STORAGE=qcow2 (default, throwaway file) or lv (a direct logical
# volume per VM in VM_VG; the base image is written into the LV once).

set -euo pipefail

VM_PREFIX="${VM_PREFIX:-carbide-ci}"
VM_RUN_ID="${VM_RUN_ID:-${CI_PIPELINE_ID:-$$}}"
VM_MEM_MB="${VM_MEM_MB:-12288}"
VM_VCPUS="${VM_VCPUS:-4}"
VM_DISK_GB="${VM_DISK_GB:-40}"
VM_DOMAIN="${VM_DOMAIN:-frankd.local}"
VM_SSH_USER="${VM_SSH_USER:-carbide}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
VM_BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-300}"
VM_KEEP="${VM_KEEP:-0}"

# One entry per VM; blank list => all local.
VM_HOSTS="${VM_HOSTS:-}"
VM_SSH_OPTS="${VM_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"

# Storage: qcow2 (default) or lv. LV mode needs VM_VG.
VM_STORAGE="${VM_STORAGE:-qcow2}"
VM_VG="${VM_VG:-carbide-vg}"
VM_LV_SIZE="${VM_LV_SIZE:-}"           # default: VM_DISK_GB (GiB)
# LV mode MANAGES logical volumes. It will only ever touch LVs it tagged
# itself (see lv_is_ours); this must be set to 1 to confirm the VG is
# CI-dedicated, so an accidental VM_STORAGE=lv cannot touch your own LVs.
VM_LV_ACK="${VM_LV_ACK:-0}"
VM_IMG_DIR="${VM_IMG_DIR:-/var/lib/libvirt/images}"

# Networking — attach to fabric you already have (never a libvirt NAT net).
#   network  VM_NETWORK=mellanox-p1   (an existing libvirt net; the usual one)
#   bridge   VM_BRIDGE=br0
#   macvtap  VM_MACVTAP_IF=mlx25p1
#   vf       VM_VF_PCI=0000:41:00.1
VM_NET_MODE="${VM_NET_MODE:-network}"
VM_NETWORK="${VM_NETWORK:-mellanox-p1}"
VM_BRIDGE="${VM_BRIDGE:-br0}"
VM_MACVTAP_IF="${VM_MACVTAP_IF:-mlx25p1}"
VM_VF_PCI="${VM_VF_PCI:-}"

# Addressing: DHCP by default; VM_IPS opts into static (routed /31-to-switch L3).
VM_IPS="${VM_IPS:-}"
VM_NET_PREFIX="${VM_NET_PREFIX:-24}"
VM_GATEWAY="${VM_GATEWAY:-}"
VM_DNS="${VM_DNS:-1.1.1.1}"

VM_IMG_URL="${VM_IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
VM_IMG_FILE="$(basename "${VM_IMG_URL:-noble.img}")"
VM_IMG_CACHE="${VM_IMG_CACHE:-${HOME}/.cache/carbide/${VM_IMG_FILE}}"
VM_STATE_DIR="${VM_STATE_DIR:-${PWD}/.vm-state}"

CARBIDE_REPO_URL="${CARBIDE_REPO_URL:-https://github.com/fdimitri/carbide2.git}"
CARBIDE_REPO_REF="${CARBIDE_REPO_REF:-main}"

_ci_dir() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }
_vm_log() { printf '\033[36m[+]\033[0m %s\n' "$*" >&2; }
_vm_die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# vm_name <i> -> per-run-unique short name
vm_name() { printf '%s-%s-n%s' "$VM_PREFIX" "$VM_RUN_ID" "$1"; }
# vm_fqdn <short> -> the name DNS should know it by
vm_fqdn() { printf '%s.%s' "$1" "$VM_DOMAIN"; }

# vm_host <i> -> the libvirt host for VM i ("" => local)
vm_host() {
  local i="$1" n=0 h
  for h in $VM_HOSTS; do
    n=$((n + 1))
    if [ "$n" = "$i" ]; then printf '%s' "$h"; return; fi
  done
  printf ''
}

# vm_sh <host> <shell-string> -> run on the host (locally when host is "").
vm_sh() {
  local host="$1"; shift
  if [ -z "$host" ]; then bash -c "$*"; else ssh $VM_SSH_OPTS "$host" "$*"; fi
}

# vm_push <host> <local-file> <remote-path> -> copy to the host (no-op if local).
vm_push() {
  local host="$1" src="$2" dst="$3"
  [ -z "$host" ] && return 0
  ssh $VM_SSH_OPTS "$host" "mkdir -p $(dirname "$dst")"
  scp -q $VM_SSH_OPTS "$src" "$host:$dst"
}

# virsh on the owning host. Runs virsh locally there, so no --connect needed.
virsh_on() { local host="$1"; shift; vm_sh "$host" "virsh $*"; }

vm_require_tools() {
  for t in ssh qemu-img cloud-localds; do
    command -v "$t" >/dev/null 2>&1 || _vm_die "missing tool on the runner: $t"
  done
  command -v virsh >/dev/null 2>&1        || _vm_die "missing virsh on the runner (local host)"
  command -v virt-install >/dev/null 2>&1 || _vm_die "missing virt-install on the runner (local host)"
}

# ensure the base image is present on every host that will run a VM.
ensure_base_image() {
  local count="${1:-3}" i host
  for ((i = 1; i <= count; i++)); do
    host="$(vm_host "$i")"
    if [ -z "$host" ]; then
      mkdir -p "$(dirname "$VM_IMG_CACHE")"
      [ -f "$VM_IMG_CACHE" ] || { _vm_log "downloading base image"; curl -fL --retry 3 -o "$VM_IMG_CACHE" "$VM_IMG_URL"; }
    else
      if ! vm_sh "$host" "test -f ${VM_IMG_DIR}/${VM_IMG_FILE}"; then
        _vm_log "syncing base image to $host"
        [ -f "$VM_IMG_CACHE" ] || { mkdir -p "$(dirname "$VM_IMG_CACHE")"; curl -fL --retry 3 -o "$VM_IMG_CACHE" "$VM_IMG_URL"; }
        vm_push "$host" "$VM_IMG_CACHE" "${VM_IMG_DIR}/${VM_IMG_FILE}"
      fi
    fi
  done
}

ensure_network() {
  local count="${1:-3}" i host
  for ((i = 1; i <= count; i++)); do
    host="$(vm_host "$i")"
    case "$VM_NET_MODE" in
      network)
        virsh_on "$host" "net-info $VM_NETWORK" >/dev/null 2>&1 \
          || _vm_die "libvirt network '$VM_NETWORK' not defined on ${host:-localhost}"
        ;;
      bridge)  vm_sh "$host" "ip link show $VM_BRIDGE" >/dev/null 2>&1 || _vm_die "bridge $VM_BRIDGE missing on ${host:-localhost}" ;;
      macvtap) vm_sh "$host" "ip link show $VM_MACVTAP_IF" >/dev/null 2>&1 || _vm_die "iface $VM_MACVTAP_IF missing on ${host:-localhost}" ;;
      vf)      [ -n "$VM_VF_PCI" ] || _vm_die "set VM_VF_PCI for VM_NET_MODE=vf" ;;
      *) _vm_die "unknown VM_NET_MODE=$VM_NET_MODE" ;;
    esac
  done
}

net_is_hostdev() { virsh_on "$1" "net-dumpxml $VM_NETWORK" 2>/dev/null | grep -q "forward mode='hostdev'"; }

network_args() {
  local host="$1"
  case "$VM_NET_MODE" in
    network)
      if net_is_hostdev "$host"; then printf -- '--network network=%s' "$VM_NETWORK"
      else printf -- '--network network=%s,model=virtio' "$VM_NETWORK"; fi ;;
    bridge)  printf -- '--network bridge=%s,model=virtio' "$VM_BRIDGE" ;;
    macvtap) printf -- '--network type=direct,source=%s,source_mode=bridge,model=virtio' "$VM_MACVTAP_IF" ;;
    vf)      printf -- '--hostdev %s,type=pci,managed=yes' "$VM_VF_PCI" ;;
  esac
}

gen_seed() {
  local name="$1" role="$2" dir seed idx ip netblock
  dir="${VM_STATE_DIR}/${name}"; mkdir -p "$dir"; seed="${dir}/seed.iso"
  idx="${name##*-n}"
  ip="$(echo "${VM_IPS:-}" | awk -v n="$idx" '{print $n}')"
  if [ -n "$ip" ]; then
    netblock="$(printf 'network:\n  version: 2\n  ethernets:\n    id0:\n      match:\n        name: "en*"\n      dhcp4: false\n      addresses: [ "%s/%s" ]\n      routes:\n        - to: default\n          via: "%s"\n      nameservers:\n        addresses: [ "%s" ]' \
      "$ip" "$VM_NET_PREFIX" "$VM_GATEWAY" "$VM_DNS")"
  else
    netblock="$(printf 'network:\n  version: 2\n  ethernets:\n    id0:\n      match:\n        name: "en*"\n      dhcp4: true')"
  fi
  VM_TEMPL="${VM_TEMPL:-$(_ci_dir)/cloud-init/user-data.yaml.tpl}" \
  VM_NAME="$name" VM_ROLE="$role" VM_FQDN="$(vm_fqdn "$name")" \
  VM_PUBKEY="$(cat "${VM_SSH_KEY}.pub")" \
  VM_REPO_URL="$CARBIDE_REPO_URL" VM_REPO_REF="$CARBIDE_REPO_REF" \
  VM_NETBLOCK="$netblock" \
  python3 - "$dir/user-data" <<'PYEOF'
import os, sys
tpl = open(os.environ["VM_TEMPL"]).read()
nb = os.environ["VM_NETBLOCK"].encode().decode("unicode_escape")
out = (tpl.replace("__NAME__", os.environ["VM_NAME"])
          .replace("__FQDN__", os.environ["VM_FQDN"])
          .replace("__ROLE__", os.environ["VM_ROLE"])
          .replace("__SSH_PUBKEY__", os.environ["VM_PUBKEY"])
          .replace("__REPO_URL__", os.environ["VM_REPO_URL"])
          .replace("__REPO_REF__", os.environ["VM_REPO_REF"])
          .replace("__NETWORK_BLOCK__", nb))
open(sys.argv[1], "w").write(out)
PYEOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" > "${dir}/meta-data"
  cloud-localds "$seed" "${dir}/user-data" "${dir}/meta-data"
  echo "$seed"
}

# Safety: an LV is OURS only if it carries our tag. We never remove (or reuse)
# any LV that lacks it — that is how this harness avoids touching the user's own
# volumes in a shared VG.
LV_TAG="carbide-ci"
lv_is_ours() {
  vm_sh "$1" "lvs --noheadings -o lv_tags /dev/${VM_VG}/$2 2>/dev/null" | grep -q "$LV_TAG"
}

# prepare_disk <host> <name> -> echoes "disk-ref format"
prepare_disk() {
  local host="$1" name="$2" size
  size="${VM_LV_SIZE:-${VM_DISK_GB}G}"
  if [ "$VM_STORAGE" = "lv" ]; then
    [ "$VM_LV_ACK" = "1" ] || _vm_die       "VM_STORAGE=lv creates/removes LVs in VG '${VM_VG}'. Set VM_LV_ACK=1 to confirm this VG is CI-dedicated (or use VM_STORAGE=qcow2)."
    local lv="/dev/${VM_VG}/${name}"
    if vm_sh "$host" "lvs ${lv} >/dev/null 2>&1"; then
      # An LV with this name already exists. Only remove it if it is one we
      # made (tagged). Never -f an untagged LV: it may be yours.
      if lv_is_ours "$host" "$name"; then
        vm_sh "$host" "lvremove -f ${lv}"
      else
        _vm_die "LV ${VM_VG}/${name} exists but is not tagged '${LV_TAG}'; refusing to remove it. Pick another VM_PREFIX/VM_VG."
      fi
    fi
    vm_sh "$host" "lvcreate -y -L ${size} -n ${name} --addtag ${LV_TAG} ${VM_VG}"
    vm_sh "$host" "qemu-img convert -O raw ${VM_IMG_DIR}/${VM_IMG_FILE} ${lv}"
    printf '%s %s' "$lv" "raw"
  else
    local disk="${VM_IMG_DIR}/${name}.qcow2"
    vm_sh "$host" "qemu-img create -q -f qcow2 -F qcow2 -b ${VM_IMG_DIR}/${VM_IMG_FILE} -o size=${size} ${disk}"
    printf '%s %s' "$disk" "qcow2"
  fi
}

vm_up() {
  local count="${1:-3}" i name host disk fmt seed
  vm_require_tools
  mkdir -p "$VM_STATE_DIR"
  ensure_base_image "$count"
  ensure_network "$count"

  for ((i = 1; i <= count; i++)); do
    name="$(vm_name "$i")"; host="$(vm_host "$i")"
    if virsh_on "$host" "dominfo $name" >/dev/null 2>&1; then
      _vm_log "$name already defined on ${host:-localhost} — skipping"
      continue
    fi
    read -r disk fmt < <(prepare_disk "$host" "$name")
    seed="$(gen_seed "$name" "$([ "$i" = 1 ] && echo init || echo join)")"
    vm_push "$host" "$seed" "${VM_IMG_DIR}/${name}-seed.iso"

    _vm_log "booting $name on ${host:-localhost} (${VM_STORAGE}, ${VM_VCPUS} vCPU / ${VM_MEM_MB} MiB)"
    vm_sh "$host" "virt-install --quiet --noautoconsole \
      --name ${name} \
      --memory ${VM_MEM_MB} --vcpus ${VM_VCPUS} \
      --cpu host-passthrough \
      --disk path=${disk},format=${fmt},bus=virtio \
      --disk path=${VM_IMG_DIR}/${name}-seed.iso,device=cdrom,readonly=on \
      $(network_args "$host") \
      --os-variant ubuntu24.04 --cloud-init disabled --import"
  done

  vm_wait_ssh "$count"
  vm_ips
}

vm_ip() {
  local name="$1" i host ip
  if [ -n "$VM_IPS" ]; then
    i="${name##*-n}"; echo "$VM_IPS" | awk -v n="$i" '{print $n}'; return
  fi
  i="${name##*-n}"; host="$(vm_host "$i")"
  ip="$(getent hosts "$(vm_fqdn "$name")" 2>/dev/null | awk '{print $1; exit}')"
  [ -n "$ip" ] || ip="$(virsh_on "$host" "domifaddr $name --source lease" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$ip" ] || ip="$(virsh_on "$host" "domifaddr $name --source arp"   2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  echo "$ip"
}

vm_ips() {
  local i name ip
  for ((i = 1; ; i++)); do
    name="$(vm_name "$i")"
    vm_host "$i" >/dev/null 2>&1
    virsh_on "$(vm_host "$i")" "dominfo $name" >/dev/null 2>&1 || break
    ip="$(vm_ip "$name")"
    echo "${name} ${ip:-pending}"
  done
}

vm_wait_ssh() {
  local count="${1:-3}" i name ip waited
  for ((i = 1; i <= count; i++)); do
    name="$(vm_name "$i")"; waited=0
    while :; do
      ip="$(vm_ip "$name")"
      if [ -n "$ip" ] && ssh $VM_SSH_OPTS -o ConnectTimeout=5 -i "$VM_SSH_KEY" "${VM_SSH_USER}@${ip}" true 2>/dev/null; then
        _vm_log "$name reachable at $ip"; break
      fi
      waited=$((waited + 5))
      [ "$waited" -lt "$VM_BOOT_TIMEOUT" ] || _vm_die "$name not reachable within ${VM_BOOT_TIMEOUT}s"
      sleep 5
    done
  done
}

# vm_ssh <name|ip> <command...>
vm_ssh() {
  local target="$1"; shift
  local ip; ip="$(vm_ip "$target")"; [ -n "$ip" ] || ip="$target"
  ssh $VM_SSH_OPTS -i "$VM_SSH_KEY" "${VM_SSH_USER}@${ip}" "$@"
}

vm_destroy() {
  local i name host
  if [ "${VM_KEEP:-0}" = "1" ]; then
    _vm_log "VM_KEEP=1 — leaving VMs up (VM_RUN_ID=${VM_RUN_ID})"
    return 0
  fi
  for ((i = 1; ; i++)); do
    name="$(vm_name "$i")"; host="$(vm_host "$i")"
    virsh_on "$host" "dominfo $name" >/dev/null 2>&1 || break
    _vm_log "destroying $name on ${host:-localhost}"
    virsh_on "$host" "destroy $name"  >/dev/null 2>&1 || true
    virsh_on "$host" "undefine $name --nvram" >/dev/null 2>&1 || true
    if [ "$VM_STORAGE" = "lv" ]; then
      # Remove only if it is tagged ours. An untagged LV is left alone.
      if lv_is_ours "$host" "$name"; then
        vm_sh "$host" "lvremove -f /dev/${VM_VG}/${name}"
      else
        _vm_log "leaving ${VM_VG}/${name}: not tagged '${LV_TAG}' (not ours)"
      fi
    else
      vm_sh "$host" "rm -f ${VM_IMG_DIR}/${name}.qcow2"
    fi
    vm_sh "$host" "rm -f ${VM_IMG_DIR}/${name}-seed.iso"
  done
  rm -rf "$VM_STATE_DIR"
}
