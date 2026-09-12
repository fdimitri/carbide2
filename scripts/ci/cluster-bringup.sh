#!/usr/bin/env bash
# cluster-bringup.sh — end-to-end multi-node bring-up on throwaway libvirt VMs.
#
# Runs on a [kvm]-tagged CI runner (any box with libvirt). Boots 3 fresh Ubuntu
# VMs, provisions them with setmeup.sh (via cloud-init), then drives the
# freeze -> init -> join -> verify sequence against real host-native k3s — the
# step no single-node k3d test can exercise.
#
#   scripts/ci/cluster-bringup.sh up        # boot + deploy + verify
#   scripts/ci/cluster-bringup.sh destroy   # tear everything down
#
# Env knobs: VM_* and CARBIDE_* are read by the harness; also:
#   SKIP_SHELL=1     skip building the (~4GB) shell image (faster runs)
#   CARBIDE_REPO_URL/REF  what the VMs clone
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-harness.sh
source "${HERE}/lib/vm-harness.sh"
# shellcheck source=lib/control.sh
source "${HERE}/lib/control.sh"

STATE="${VM_STATE_DIR:-$PWD/.vm-state}"
CLUSTER_YAML="${STATE}/cluster.yaml"
# Ingress is host-routed; this is the name the cluster is addressed by. With
# DNS/DHCP always up it defaults to node 1's fabric name (resolved after boot).
CONTROL_HOST="${CONTROL_HOST:-}"
ENV_OUT="${STATE}/env"

wait_provisioned() {
  local name="$1" i
  for i in $(seq 1 120); do
    if vm_ssh "$name" 'test -f /var/lib/carbide-ci-provisioned' 2>/dev/null; then
      _vm_log "$name provisioned"; return 0
    fi
    sleep 10
  done
  _vm_die "$name was never provisioned (see ~/setmeup.log inside it)"
}

deploy_args() {
  local a=""
  [[ "${SKIP_SHELL:-0}" == "1" ]] && a+=" --no-images.shell"
  echo "$a"
}

do_up() {
  command -v kubectl >/dev/null 2>&1 || _vm_die "runner needs kubectl on PATH"

  vm_up 3
  local n1 n2 n3 ip1 ip2 ip3
  n1="$(vm_name 1)"; n2="$(vm_name 2)"; n3="$(vm_name 3)"
  : "${CONTROL_HOST:=$(vm_fqdn "$n1")}"
  export CONTROL_HOST
  ip1="$(vm_ip "$n1")"; ip2="$(vm_ip "$n2")"; ip3="$(vm_ip "$n3")"
  [[ -n "$ip1" && -n "$ip2" && -n "$ip3" ]] || _vm_die "could not resolve all VM IPs"

  wait_provisioned "$n1"; wait_provisioned "$n2"; wait_provisioned "$n3"

  _vm_log "freezing config on $n1 (mints the k3s token)"
  vm_ssh "$n1" "cd ~/carbide2 && ./scripts/deploy.rb \
    --config scripts/examples/k3s-multinode-longhorn.yaml \
    --cluster.server-url https://$(vm_fqdn "$n1"):6443 \
    --registry.host $(vm_fqdn "$n1") --public.host ${CONTROL_HOST} \
    --yaml-out cluster.yaml $(deploy_args)"

  # Pull the frozen config back so the runner can fan it out and archive it.
  mkdir -p "$STATE"
  scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$VM_SSH_KEY" "${VM_SSH_USER}@${ip1}:~/carbide2/cluster.yaml" "$CLUSTER_YAML"

  _vm_log "deploying node 1 (init: k3s --cluster-init, registry, control plane)"
  vm_ssh "$n1" "cd ~/carbide2 && ./scripts/deploy.rb --config cluster.yaml $(deploy_args)"

  _vm_log "joining nodes 2 and 3"
  local n
  for n in "$n2" "$n3"; do
    local ip; ip="$(vm_ip "$n")"
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$VM_SSH_KEY" "$CLUSTER_YAML" "${VM_SSH_USER}@${ip}:~/carbide2/cluster.yaml"
    vm_ssh "$n" "cd ~/carbide2 && ./scripts/deploy.rb --config cluster.yaml \
      --node.role join --no-images.build --no-images.push --no-registry.serve"
  done

  _vm_log "verifying cluster membership"
  vm_ssh "$n1" 'kubectl get nodes -o wide'
  local ready
  ready="$(vm_ssh "$n1" "kubectl get nodes --no-headers | grep -c ' Ready '")"
  [[ "$ready" -ge 3 ]] || _vm_die "expected 3 Ready nodes, saw ${ready}"

  # No seeded workspace: create one through the control API and wait for it.
  # The control plane is served by the ingress on node 1.
  export CONTROL_URL="https://${CONTROL_HOST}"
  export CONTROL_HOST
  _vm_log "logging in to control at $CONTROL_URL"
  local token; token="$(control_login)"
  [[ -n "$token" ]] || _vm_die "control login failed (admin creds / reachability)"

  _vm_log "creating workspace via control API"
  local ws_id; ws_id="$(create_workspace "$token" "ci-${CI_PIPELINE_ID:-local}")"
  [[ "$ws_id" -gt 0 ]] || _vm_die "workspace create failed"

  _vm_log "waiting for workspace ${ws_id} (ws-${ws_id}) to become ready"
  wait_workspace_ready "$token" "$ws_id"

  {
    printf 'NODE1_NAME=%s\n' "$n1"
    printf 'CONTROL_URL=%s\n' "$CONTROL_URL"
    printf 'CONTROL_HOST=%s\n' "$CONTROL_HOST"
    printf 'VM_RUN_ID=%s\n' "$VM_RUN_ID"
    printf 'WS_ID=%s\n' "$ws_id"
    printf 'NAMESPACE=ws-%s\n' "$ws_id"
    printf 'WS_NAMESPACE=ws-%s\n' "$ws_id"
    printf 'BASE_URL=%s/w/%s\n' "$CONTROL_URL" "$ws_id"
    printf 'CARBIDE_WS_URL=%s/w/%s\n' "$CONTROL_URL" "$ws_id"
  } > "$ENV_OUT"
  _vm_log "cluster + workspace ready — env written to $ENV_OUT"
}

do_destroy() { vm_destroy; }

case "${1:-up}" in
  up)      do_up ;;
  destroy) do_destroy ;;
  *) _vm_die "usage: $0 [up|destroy]" ;;
esac
