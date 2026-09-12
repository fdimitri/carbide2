#cloud-config
# Carbide2 CI node: template expanded by vm-harness.sh (__NAME__ etc).
# Cloud-init only PROVISIONS the box (user, tooling, clone). It deliberately
# does not deploy — the CI cluster job drives freeze/init/join so the same image
# serves role:init and role:join and the sequencing stays in one place.

hostname: __NAME__
fqdn: __FQDN__
prefer_fqdn_over_hostname: true
manage_etc_hosts: true

# Address is DHCP or a static netplan, expanded by vm-harness.sh.
__NETWORK_BLOCK__

users:
  - name: carbide
    groups: [sudo, docker]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - __SSH_PUBKEY__

package_update: true
packages:
  - git
  - curl
  - ca-certificates

write_files:
  - path: /etc/carbide-ci.env
    permissions: '0644'
    content: |
      CARBIDE_CI_ROLE=__ROLE__
      CARBIDE_REPO_URL=__REPO_URL__
      CARBIDE_REPO_REF=__REPO_REF__

runcmd:
  # 1. Clone the meta repo with submodules (needs git + network only).
  - |
    set -euxo pipefail
    runuser -u carbide -- bash -lc '
      set -euo pipefail
      cd "$HOME"
      if [ ! -d carbide2/.git ]; then
        git clone --recurse-submodules "__REPO_URL__" carbide2
      fi
      cd carbide2
      git fetch --all --tags
      git checkout __REPO_REF__
      git submodule update --init --recursive
    '
  # 2. Provision the host (docker/kubectl/helm/rbenv + k3s-or-not). setmeup.sh
  #    is idempotent; --k3s selects host-native k3s and installs no backend
  #    binary (deploy.rb lays k3s down at deploy time). --all enables the
  #    off-by-default extras (node, socat).
  - |
    set -euxo pipefail
    runuser -u carbide -- bash -lc '
      set -euo pipefail
      cd "$HOME/carbide2"
      ./scripts/setmeup.sh --k3s --all > "$HOME/setmeup.log" 2>&1 || {
        tail -n 200 "$HOME/setmeup.log"; exit 1; }
    '
  # 3. Readiness marker: the harness/CI waits on this, not on SSH alone, so a
  #    job never starts before setmeup has finished provisioning.
  - touch /var/lib/carbide-ci-provisioned

final_message: "carbide-ci node __NAME__ (__ROLE__) provisioned in $UPTIME seconds"
