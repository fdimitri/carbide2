#!/usr/bin/env bash
# vm-harness.sh — boot/tear down throwaway Ubuntu VMs on libvirt.
#
# Provider-agnostic on purpose: it only needs libvirt + virt-install + a base
# cloud image. It does not care whether it runs on a desktop, an R720, or the
# (future) EPYC box — that is the runner's business, selected by CI tag.
#
#   source scripts/ci/lib/vm-harness.sh
#   vm_up 3            # boot 3 VMs, wait for SSH, print "name ip" lines
#   vm_ips             # list "name ip" for the current prefix
#   vm_destroy         # power off + undefine + remove disks/seeds
#
# All knobs are env-overridable; see defaults below.

set -euo pipefail

VM_PREFIX="${VM_PREFIX:-carbide-ci}"
VM_MEM_MB="${VM_MEM_MB:-12288}"
VM_VCPUS="${VM_VCPUS:-4}"
VM_DISK_GB="${VM_DISK_GB:-40}"
# Networking: attach to fabric you ALREADY have. We do not create a libvirt
# network — a self-made NAT net is host-local and unreachable from anywhere,
# which is useless here.
#   VM_NET_MODE=network  VM_NETWORK=mellanox-p1   (an EXISTING libvirt net) <-- usual
#   VM_NET_MODE=bridge   VM_BRIDGE=br0            (existing Linux bridge)
#   VM_NET_MODE=macvtap  VM_MACVTAP_IF=mlx25p1    (direct on a physical port)
#   VM_NET_MODE=vf       VM_VF_PCI=0000:41:00.1   (SR-IOV VF passthrough)
VM_NET_MODE="${VM_NET_MODE:-network}"
VM_NETWORK="${VM_NETWORK:-mellanox-p1}"
VM_BRIDGE="${VM_BRIDGE:-br0}"
VM_MACVTAP_IF="${VM_MACVTAP_IF:-mlx25p1}"
VM_VF_PCI="${VM_VF_PCI:-}"

# Addressing. Leave VM_IPS empty to use the network's DHCP. Set it (space list,
# one per VM) for a routed /31-to-the-switch fabric where nothing hands out
# leases: the VMs take static addresses and route via VM_GATEWAY (the switch).
VM_IPS="${VM_IPS:-}"
VM_NET_PREFIX="${VM_NET_PREFIX:-24}"
VM_GATEWAY="${VM_GATEWAY:-}"
VM_DNS="${VM_DNS:-1.1.1.1}"
VM_IMG_URL="${VM_IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
VM_IMG_CACHE="${VM_IMG_CACHE:-${HOME}/.cache/carbide/$(basename "${VM_IMG_URL:-noble.img}")}"
VM_STATE_DIR="${VM_STATE_DIR:-${PWD}/.vm-state}"
VM_SSH_USER="${VM_SSH_USER:-carbide}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
VM_BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-300}"

# DNS/DHCP is assumed always up. Each VM gets a per-RUN-unique name so two
# concurrent pipelines never collide on a dynamic-DNS record.
VM_DOMAIN="${VM_DOMAIN:-frankd.local}"
VM_RUN_ID="${VM_RUN_ID:-${CI_PIPELINE_ID:-$$}}"
# Keep VMs after the run instead of destroying them (default: destroy).
VM_KEEP="${VM_KEEP:-0}"

CARBIDE_REPO_URL="${CARBIDE_REPO_URL:-https://github.com/fdimitri/carbide2.git}"
CARBIDE_REPO_REF="${CARBIDE_REPO_REF:-main}"

_ci_dir() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }
_vm_log() { printf '\033[36m[+]\033[0m %s\n' "$*" >&2; }
_vm_die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# vm_name <i> -> per-run-unique short name, e.g. carbide-ci-482-n2
vm_name() { printf '%s-%s-n%s' "$VM_PREFIX" "$VM_RUN_ID" "$1"; }
# vm_fqdn <short> -> the name DNS should know it by
vm_fqdn() { printf '%s.%s' "$1" "$VM_DOMAIN"; }

vm_require_tools() {
  for t in virsh virt-install cloud-localds qemu-img ssh; do
    command -v "$t" >/dev/null 2>&1 || _vm_die "missing tool: $t"
  done
}

ensure_base_image() {
  mkdir -p "$(dirname "$VM_IMG_CACHE")"
  if [[ ! -f "$VM_IMG_CACHE" ]]; then
    _vm_log "downloading base image -> $VM_IMG_CACHE"
    curl -fL --retry 3 -o "$VM_IMG_CACHE" "$VM_IMG_URL"
  fi
  [[ -f "$VM_IMG_CACHE" ]] || _vm_die "base image unavailable"
}

ensure_network() {
  case "$VM_NET_MODE" in
    network)
      virsh net-info "$VM_NETWORK" >/dev/null 2>&1 || _vm_die "libvirt network '$VM_NETWORK' not defined (VM_NET_MODE=network)"
      # No static/DHCP decision here: libvirt's own dnsmasq is absent on a
      # hostdev pool, but the FABRIC may still serve DHCP to the VF MACs.
      # DHCP is the default; VM_IPS opts into static. See gen_seed.
      ;;
    bridge)
      ip link show "$VM_BRIDGE" >/dev/null 2>&1 || _vm_die "bridge $VM_BRIDGE not found (VM_NET_MODE=bridge)"
      ;;
    macvtap)
      ip link show "$VM_MACVTAP_IF" >/dev/null 2>&1 || _vm_die "interface $VM_MACVTAP_IF not found (VM_NET_MODE=macvtap)"
      ;;
    vf)
      [[ -n "$VM_VF_PCI" ]] || _vm_die "set VM_VF_PCI for VM_NET_MODE=vf"
      ;;
    *) _vm_die "unknown VM_NET_MODE=$VM_NET_MODE (bridge|macvtap|vf)" ;;
  esac
}

# A libvirt network backed by <forward mode='hostdev'> (SR-IOV pool) passes a
# raw VF into the guest. It is NOT a virtio NIC and takes no model=, and it has
# no DHCP — the guest must be addressed statically.
net_is_hostdev() {
  virsh net-dumpxml "$1" 2>/dev/null | grep -q "forward mode='hostdev'"
}

# network_args -> echoes the virt-install --network/--hostdev flags for the mode
network_args() {
  case "$VM_NET_MODE" in
    network)
      if net_is_hostdev "$VM_NETWORK"; then
        printf -- '--network network=%s' "$VM_NETWORK"          # SR-IOV VF passthrough (no model)
      else
        printf -- '--network network=%s,model=virtio' "$VM_NETWORK"
      fi
      ;;
    bridge)  printf -- '--network bridge=%s,model=virtio' "$VM_BRIDGE" ;;
    macvtap) printf -- '--network type=direct,source=%s,source_mode=bridge,model=virtio' "$VM_MACVTAP_IF" ;;
    vf)      printf -- '--hostdev %s,type=pci,managed=yes' "$VM_VF_PCI" ;;
  esac
}

# gen_seed <name> <role> -> echoes path to the NoCloud seed ISO
gen_seed() {
  local name="$1" role="$2" dir seed idx ip netblock
  dir="${VM_STATE_DIR}/${name}"
  mkdir -p "$dir"
  seed="${dir}/seed.iso"

  idx="${name##*-n}"
  ip="$(echo "${VM_IPS:-}" | awk -v n="$idx" '{print $n}')"
  if [[ -n "$ip" ]]; then
    # Static netplan: match the primary en* NIC, no DHCP (routed fabric).
    netblock="$(printf 'network:\n  version: 2\n  ethernets:\n    id0:\n      match:\n        name: "en*"\n      dhcp4: false\n      addresses: [ "%s/%s" ]\n      routes:\n        - to: default\n          via: "%s"\n      nameservers:\n        addresses: [ "%s" ]' \
      "$ip" "$VM_NET_PREFIX" "$VM_GATEWAY" "$VM_DNS")"
  else
    # No VM_IPS: DHCP. Written explicitly (not left to cloud-init defaults) so a
    # passthrough VF on a hostdev net — which has no libvirt dnsmasq — still
    # asks the FABRIC's DHCP for a lease.
    netblock="$(printf 'network:\n  version: 2\n  ethernets:\n    id0:\n      match:\n        name: "en*"\n      dhcp4: true')"
  fi

  # Python (not sed) does the substitution: the netplan block is multi-line and
  # needs its own indentation, which sed line-edits mangle.
  VM_TEMPL="${VM_TEMPL:-$(_ci_dir)/cloud-init/user-data.yaml.tpl}" \
  VM_NAME="$name" VM_ROLE="$role" VM_FQDN="$(vm_fqdn "$name")" \
  VM_PUBKEY="$(cat "${VM_SSH_KEY}.pub")" \
  VM_REPO_URL="$CARBIDE_REPO_URL" VM_REPO_REF="$CARBIDE_REPO_REF" \
  VM_NETBLOCK="$netblock" \
  python3 - "$dir/user-data" <<'PYEOF'
import os, sys
tpl = open(os.environ["VM_TEMPL"]).read()
netblock = os.environ["VM_NETBLOCK"].encode().decode("unicode_escape")
out = (tpl
    .replace("__NAME__", os.environ["VM_NAME"])
    .replace("__FQDN__", os.environ["VM_FQDN"])
    .replace("__ROLE__", os.environ["VM_ROLE"])
    .replace("__SSH_PUBKEY__", os.environ["VM_PUBKEY"])
    .replace("__REPO_URL__", os.environ["VM_REPO_URL"])
    .replace("__REPO_REF__", os.environ["VM_REPO_REF"])
    .replace("__NETWORK_BLOCK__", netblock))
open(sys.argv[1], "w").write(out)
PYEOF

  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" > "${dir}/meta-data"
  cloud-localds "$seed" "${dir}/user-data" "${dir}/meta-data"
  echo "$seed"
}

vm_up() {
  local count="${1:-3}" i name disk seed
  vm_require_tools
  ensure_base_image
  ensure_network
  mkdir -p "$VM_STATE_DIR"

  for ((i = 1; i <= count; i++)); do
    name="$(vm_name "$i")"
    if virsh dominfo "$name" >/dev/null 2>&1; then
      _vm_log "$name already defined — skipping (destroy first to rebuild)"
      continue
    fi
    disk="${VM_STATE_DIR}/${name}.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$VM_IMG_CACHE" -o size="${VM_DISK_GB}G" "$disk"
    if (( i == 1 )); then seed="$(gen_seed "$name" init)"; else seed="$(gen_seed "$name" join)"; fi

    _vm_log "booting $name (${VM_VCPUS} vCPU / ${VM_MEM_MB} MiB)"
    virt-install --quiet --noautoconsole \
      --name "$name" \
      --memory "$VM_MEM_MB" --vcpus "$VM_VCPUS" \
      --cpu host-passthrough \
      --disk "path=${disk},format=qcow2,bus=virtio" \
      --disk "path=${seed},device=cdrom,readonly=on" \
      $(network_args) \
      --os-variant ubuntu24.04 \
      --cloud-init disabled \
      --import
  done

  vm_wait_ssh "$count"
  vm_ips
}

vm_ip() {
  local name="$1" idx ip
  # Static fabric: the address is configured, not leased.
  if [[ -n "$VM_IPS" ]]; then
    idx="${name##*-n}"
    echo "${VM_IPS}" | awk -v n="$idx" '{print $n}'
    return
  fi
  # DNS first — DHCP/DNS is assumed always up and the guest announces its name,
  # so the fabric resolves it. Fall back to scraping the lease if it does not.
  ip="$(getent hosts "$(vm_fqdn "$name")" 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$ip" ]] || ip="$(virsh domifaddr "$name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  [[ -n "$ip" ]] || ip="$(virsh domifaddr "$name" --source arp 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  echo "$ip"
}

vm_ips() {
  local i name ip
  for ((i = 1; ; i++)); do
    name="$(vm_name "$i")"
    virsh dominfo "$name" >/dev/null 2>&1 || break
    ip="$(vm_ip "$name")"
    echo "${name} ${ip:-pending}"
  done
}

vm_wait_ssh() {
  local count="${1:-3}" i name ip waited
  for ((i = 1; i <= count; i++)); do
    name="$(vm_name "$i")"
    waited=0
    while :; do
      ip="$(vm_ip "$name")"
      if [[ -n "$ip" ]] && ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 -i "$VM_SSH_KEY" "${VM_SSH_USER}@${ip}" true 2>/dev/null; then
        _vm_log "$name reachable at $ip"
        break
      fi
      waited=$((waited + 5))
      (( waited < VM_BOOT_TIMEOUT )) || _vm_die "$name not reachable within ${VM_BOOT_TIMEOUT}s"
      sleep 5
    done
  done
}

# vm_ssh <name|ip> <command...>
vm_ssh() {
  local target="$1"; shift
  local ip; ip="$(vm_ip "$target")"; [[ -n "$ip" ]] || ip="$target"
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$VM_SSH_KEY" "${VM_SSH_USER}@${ip}" "$@"
}

vm_destroy() {
  local i name
  if [[ "${VM_KEEP:-0}" == "1" ]]; then
    _vm_log "VM_KEEP=1 — leaving VMs in place. Destroy with: VM_RUN_ID=${VM_RUN_ID} ${BASH_SOURCE[0]} ... (or: virsh destroy/undefine <name>)"
    return 0
  fi
  for ((i = 1; ; i++)); do
    name="$(vm_name "$i")"
    virsh dominfo "$name" >/dev/null 2>&1 || break
    _vm_log "destroying $name"
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" --remove-all-storage --nvram >/dev/null 2>&1 || true
  done
  rm -rf "$VM_STATE_DIR"
}
