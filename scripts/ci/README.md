# CI: multi-node bring-up on libvirt VMs

Stand up three throwaway Ubuntu VMs on libvirt, provision them with
`setmeup.sh`, and drive a real host-native k3s bring-up
(`freeze -> init -> join -> verify`) — the multi-node path the single-node k3d
tests can't reach. Triggered by GitLab CI; runs on whatever `[kvm]` runner is
free, so it doesn't care which box it lands on.

## Pieces

| File | Role |
|---|---|
| `lib/vm-harness.sh` | boot/destroy VMs on libvirt (`VM_*` env knobs) |
| `cloud-init/user-data.yaml.tpl` | per-VM provisioning: user, SSH key, clone, `setmeup.sh` |
| `cluster-bringup.sh` | `up` = boot + deploy + verify; `destroy` = tear down |
| `../../.gitlab-ci.yml` | the pipeline (meta repo) |

## Manual use (no CI)

On any box with `libvirt`, `virt-install`, `cloud-localds`, `qemu-img`, and an
SSH keypair:

```bash
# from the meta repo root
scripts/ci/cluster-bringup.sh up        # ~20-40 min cold (image build dominates)
# ... inspect ...
scripts/ci/cluster-bringup.sh destroy
```

Useful knobs:

```bash
SKIP_SHELL=1                 # skip the ~4GB shell image (default in CI)
VM_MEM_MB=16384 VM_VCPUS=6   # per-VM size
VM_PREFIX=myrun              # namespace the VMs so parallel runs don't collide
CARBIDE_REPO_URL=... CARBIDE_REPO_REF=<sha>   # what the VMs clone
```

## Hostnames, DNS and DHCP

DNS/DHCP is assumed always up. Each VM gets a **per-run-unique** name so two
concurrent pipelines never collide on a dynamic-DNS record:

```
<VM_PREFIX>-<VM_RUN_ID>-n<i>.<VM_DOMAIN>      e.g. carbide-ci-482-n1.frankd.local
```

- `VM_DOMAIN` (default `frankd.local`) — the fabric domain records land in.
- `VM_RUN_ID` (default `$CI_PIPELINE_ID`, else the shell PID) — uniqueness.
- The guest declares `hostname` + `fqdn` (`prefer_fqdn_over_hostname: true`) so it
  announces itself and the DHCP/DNS server registers the record.
- Address resolution is **DNS-first** (`getent hosts <fqdn>`), falling back to
  scraping the libvirt lease. Set `NODE1_IP` only if the runner can't resolve.
- Node 1's fabric name is the cluster's ingress host (`public.host`), so
  `CONTROL_URL=https://<node1>.<domain>` and nothing needs `--resolve`.

Windows-AD caveat: if the DNS zone allows **secure updates only**, an
un-joined Linux guest cannot authenticate the update. It works when the DHCP
server registers on the client's behalf ("Always dynamically update"). If you
see no record, that setting (or a static A record) is the first thing to check.

### Keeping VMs after a run

`VM_KEEP=1` leaves the VMs up (they stay registered in DNS). Default is to
destroy. To clean up a kept run later:

```bash
VM_RUN_ID=<id> scripts/ci/cluster-bringup.sh destroy
```

## Hosts and storage

- **Hosts** — `VM_HOSTS` is a space list, one entry per VM; blank means all local
  (single-host). For 3 VMs on 3 physical machines:
  ```bash
  VM_HOSTS="carbidium1 carbidium2 carbidium3"   # VM i runs on host i
  ```
  The orchestrator SSHes to each host and runs `virsh`/`virt-install` there, so
  the runner needs SSH to every host (key auth) — not just the local one. VMs on
  different hosts join one k3s cluster only if they share L2 (or L3 routing) on
  the fabric, which the passthrough NICs provide.
- **Storage** — `VM_STORAGE=qcow2` (default: a throwaway qcow2 per VM) or
  `VM_STORAGE=lv` with `VM_VG=<vg>`: a direct logical volume per VM, created on
  the owning host and written from the base image once. `VM_LV_SIZE` defaults to
  `VM_DISK_GB` (GiB). LV mode needs `lvcreate`/`lvremove` on each host.

Where to define these: the pipeline sets defaults under `cluster:bringup.variables`
in `.gitlab-ci.yml`; override per project in **Settings → CI/CD → Variables**, or
export them when running `cluster-bringup.sh` by hand.

## Runner setup (GitLab)

Runners are matched by **capability tag**, never by hostname:

- `build-fast` — `docker buildx` host (desktop / EPYC).
- `kvm` — libvirt host. Shell executor, `gitlab-runner` user in the `libvirt`
  and `kvm` groups and able to reach the libvirt socket. Set the runner's
  `concurrent = 1` and rely on `resource_group: carbide-ci-kvm` so only one
  bring-up runs per host.
- `gpu` — local-model host for agent-loop tests (see `test:agent-local`).
- `m75-live` — the real bare-metal cluster, for the redeploy/release-gate path.

The runner needs: `libvirt-daemon-system`, `virtinst`, `qemu-utils`,
`cloud-image-utils`, `ssh`, `kubectl`, and a base-image cache directory it can
write (`~/.cache/carbide`).

## Notes / gotchas

- **Base image** is cached at `~/.cache/carbide/` and downloaded once.
- **Networking**: VMs attach to fabric you already have — we never create a
  libvirt NAT network (a self-made NAT net is host-local and unreachable from
  anywhere else). Modes:
  - `VM_NET_MODE=network VM_NETWORK=mellanox-p1` — an existing libvirt network. **Default.**
    If that network is an SR-IOV pool (`<forward mode='hostdev'>`, e.g. your
    `mellanox-p1` over PF `mlx25p1`), the harness passes a **raw VF** into the
    guest (no `model=virtio`, no DHCP) and **requires** `VM_IPS` — see below.
  - `VM_NET_MODE=bridge VM_BRIDGE=br0` — an existing Linux bridge.
  - `VM_NET_MODE=macvtap VM_MACVTAP_IF=mlx25p0` — direct on a physical port.
  - `VM_NET_MODE=vf VM_VF_PCI=0000:41:00.1` — SR-IOV VF passthrough.

  **Addressing.** Leave `VM_IPS` unset for DHCP (only valid on a bridge-type
  network with a libvirt `<dhcp>` range; the harness refuses an SR-IOV hostdev
  pool without `VM_IPS`, since it has no DHCP).
  For the 25GbE **L3** case — a routed `/31` to the switch, where nothing hands
  out leases — set static addressing and the harness writes a netplan instead of
  relying on DHCP:
  ```bash
  VM_IPS="10.60.0.2 10.60.0.3 10.60.0.4"
  VM_NET_PREFIX=24 VM_GATEWAY=10.60.0.1 VM_DNS=1.1.1.1
  ```
  The `/31` to the switch is configured on the host port / the libvirt network;
  the VMs sit on a routed block behind it and route via `VM_GATEWAY`.

  If the KVM host is not on the fabric the tests run from, stretch the VM L2 with
  a single VXLAN interface rather than DNAT/port-forwarding.
- **Registry**: node 1 serves it (`registry.serve`) and the joiners pull SHA
  tags; `Carbide::Node` installs the CA trust on init and join.
- **Freshness**: VMs are destroyed after every run, so `setmeup.sh` and the k3s
  `server --server` join are genuinely exercised on a clean host each time.
- **cloud-init provisions only** — it never deploys. The freeze/init/join order
  lives in `cluster-bringup.sh`, so the same VM image serves both roles.
- **Windows/corp hosts**: `--cpu host-passthrough` needs nested virt; on a host
  without it, swap to `--cpu max` or `qemu64`.
