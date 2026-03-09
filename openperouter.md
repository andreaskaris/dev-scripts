# OpenPERouter Integration — Branch `001-sno-agent-bridge-config`

This document lists all changes introduced by the `001-sno-agent-bridge-config` branch compared to `master`. The branch adds OpenPERouter support to dev-scripts, targeting SNO (Single Node OpenShift) deployments using the agent-based appliance installer.

---

## 1. Changes to Existing dev-scripts Files

### 1.1 RHEL 10 and Distro Fixes — `01_install_requirements.sh`

- **Added RHEL 10 support**: `"rhel10"` added to the CentOS 9 / RHEL 9 distro case block so the same package installation logic applies.
- **Removed RHEL 8 legacy handling**: Dropped `"rhel8"` from the distro case and removed the `network-scripts` package install (not available on newer distros).

### 1.2 VXLAN and Docker Compatibility — `02_configure_host.sh`

- **Opened VXLAN port**: Added port `4789` to the `vm_host_ports` list passed to the Ansible firewall playbook. Required for VXLAN tunnels between the node and external FRR peers.
- **Docker FORWARD chain fix**: When Docker is installed it sets the iptables FORWARD policy to DROP, which blocks libvirt VM traffic. The script now inserts ACCEPT rules into the `DOCKER-USER` chain (if it exists) for both inbound and outbound traffic on the baremetal network interface.

### 1.3 Post-Config-Image Hook — `agent/06_agent_create_cluster.sh`

- **New hook point**: After `openshift-install agent create config-image`, the script checks for `$POST_CONFIG_IMAGE_HOOK`. If set and executable, it runs the hook. This allows injecting modifications into the config-image ISO (used by `patch_configimage.sh` to enable virtual interfaces in assisted-service).
- **Minor formatting**: Reformatted the `podman run` command in `create_appliance()`.

### 1.4 Appliance Additional Images — `agent/common.sh`

- **New variable `APPLIANCE_ADDITIONAL_IMAGES`**: Comma-separated list of container images to pre-load into the appliance disk image. Defaults to empty. Used to embed the OpenPERouter container image so it's available at boot without network access.

### 1.5 Appliance Config Template — `agent/roles/manifests/templates/appliance-config_yaml.j2`

- **`stopLocalRegistry: false`**: Keeps the appliance's internal registry running after installation, so pre-loaded images remain accessible.
- **`additionalImages` section**: Renders images from `APPLIANCE_ADDITIONAL_IMAGES` into the appliance config so they are baked into the disk image.

### 1.6 Ansible Variables — `agent/roles/manifests/vars/main.yml`

- Exposes `APPLIANCE_ADDITIONAL_IMAGES` environment variable to Ansible via `appliance_additional_images`.

### 1.7 Cleanup — `host_cleanup.sh`

- Removes the iptables FORWARD and DOCKER-USER rules added by `02_configure_host.sh`, ensuring clean teardown.

### 1.8 `.gitignore`

- Excludes `config_fpaoline.sh` from the ignore pattern (so the personal config is tracked).
- Ignores `.claude/` directory.

---

## 2. New Files — Personal Configuration

### 2.1 `config_fpaoline.sh`

A ready-to-use config for SNO + OpenPERouter deployment:

| Setting | Value |
|---------|-------|
| Scenario | `SNO_IPV4` with appliance disk image (`DISKIMAGE`) |
| OCP version | 4.18 (nightly stream) |
| VM resources | 32 GB RAM, 8 vCPU, 100 GB disk |
| Extra network | `external` at `192.168.150.0/24` (third NIC) |
| Appliance images | `quay.io/fpaoline/router:dev3` pre-loaded |
| Post-config hook | `openperouter/patch_configimage.sh` |
| Extra manifests | Points to `ocp/${CLUSTER_NAME}/openshift` for the MachineConfig |
| Console access | Ignition snippet enabling `core` user password login |

---

## 3. New Files — `openperouter/` Directory

### 3.1 `README.md`

Comprehensive documentation covering quick start, deployment workflow, customization, verification, and troubleshooting for the OpenPERouter + appliance integration.

### 3.2 `appliance-config.yaml`

Sample appliance build configuration specifying OCP version, disk size, pull secret, and additional images.

### 3.3 `generate_machineconfig.sh`

Generates `99-master-openperouter.yaml` (a MachineConfig) from source files. It:

- Reads all quadlet files from `quadlets/` and config files from `openpeconfig/`.
- Encodes small files as plain `data:` URIs and larger files with gzip+base64.
- Produces a complete MachineConfig with `storage.files` and `systemd.units` sections.
- Outputs to `$WORKING_DIR/ocp/$CLUSTER_NAME/openshift/` so it's picked up as an extra manifest.

**File mapping:**

| Source | Destination on Node | Mode |
|--------|-------------------|------|
| `quadlets/controllerpod.pod` | `/etc/containers/systemd/controllerpod.pod` | 0644 |
| `quadlets/controller.container` | `/etc/containers/systemd/controller.container` | 0644 |
| `quadlets/routerpod.pod` | `/etc/containers/systemd/routerpod.pod` | 0644 |
| `quadlets/frr.container` | `/etc/containers/systemd/frr.container` | 0644 |
| `quadlets/reloader.container` | `/etc/containers/systemd/reloader.container` | 0644 |
| `quadlets/frr-sockets.volume` | `/etc/containers/systemd/frr-sockets.volume` | 0644 |
| `quadlets/openperouter-node-index.service` | `/etc/containers/systemd/openperouter-node-index.service` | 0644 |
| `quadlets/openperouter-node-index.sh` | `/usr/local/bin/openperouter-node-index.sh` | 0755 |
| `openpeconfig/node-config.yaml` | `/var/lib/openperouter/node-config.yaml` | 0644 |
| `openpeconfig/openpe_config.yaml` | `/var/lib/openperouter/configs/openpe_config.yaml` | 0644 |
| `openpeconfig/default_bridge` | `/etc/ovnk/default_bridge` | 0644 |

### 3.4 `99-master-openperouter.yaml`

Pre-generated MachineConfig (output of `generate_machineconfig.sh`). Deploys all OpenPERouter quadlets, configs, and systemd units onto master nodes.

### 3.5 `patch_agent_config.sh`

Patches `agent-config.yaml` and `install-config.yaml` after `agent/05_agent_configure.sh`:

- **Network configuration**: Replaces the default single-NIC config with:
  - `enp2s0` — ethernet NIC with static IP `192.168.111.80/24`
  - `dummy0` — dummy interface (bridge port)
  - `br0` — linux bridge with a configurable IP (default `192.168.110.2/24`), default gateway via `192.168.110.1`
- **Rendezvous IP**: Set to the bridge IP so the node is reachable on the bridge network.
- **Machine network**: Patches `install-config.yaml` `machineNetwork` to the bridge subnet (`192.168.110.0/24`), making kubelet pick the bridge IP as the node address.

### 3.6 `patch_configimage.sh`

Post-config-image hook (invoked via `$POST_CONFIG_IMAGE_HOOK`). After `openshift-install agent create config-image`:

1. Extracts the `CONFIG.GZ` cpio archive from the config-image ISO.
2. Injects `ENABLE_VIRTUAL_INTERFACES=true` into `assisted-service.env` — this tells assisted-service to include virtual interfaces (bridges) in its inventory, which is required for the bridge IP to pass the `belongs-to-machine-cidr` validation.
3. Rebuilds the cpio archive (using a chroot for correct absolute paths) and re-creates the ISO.

---

## 4. New Files — OpenPERouter Configuration (`openpeconfig/`)

### 4.1 `node-config.yaml`

```yaml
nodeIndex: 1
logLevel: debug
```

Template node config. At boot, `openperouter-node-index.sh` overwrites `nodeIndex` with the last octet of the bridge IP.

### 4.2 `openpe_config.yaml`

Defines the OpenPERouter routing topology:

- **L3 VNI**: VRF `red`, VNI 100, VXLAN port 4789
- **L2 VNI**: VNI 210 in VRF `red`, L2 gateway IP `192.168.110.1/24`, host master bridge `br0`
- **Underlay**: ASN 64514, VTEP CIDR `100.65.0.0/24`, NIC `enp2s0`, BGP neighbor at `192.168.111.1` (ASN 64512)
- **Raw FRR config**: Advertises `192.168.110.2/32` in VRF `red` (ipv4 unicast)

### 4.3 `default_bridge`

Contains `br0` — tells OVN-Kubernetes to use `br0` as the external bridge instead of the default `br-ex`.

---

## 5. New Files — Quadlet Definitions (`quadlets/`)

Systemd quadlet files that define how OpenPERouter containers run on the node:

| File | Type | Description |
|------|------|-------------|
| `controllerpod.pod` | Pod | Pod grouping for the controller container. Requires `openperouter-node-index.service`. |
| `controller.container` | Container | OpenPERouter controller. Mounts node-config, openpe-config, and FRR sockets. Runs in `controllerpod`. |
| `routerpod.pod` | Pod | Pod grouping for FRR and reloader containers. Host-networked, privileged. |
| `frr.container` | Container | FRR routing daemon. Runs in `routerpod` with shared FRR sockets volume. |
| `reloader.container` | Container | Config reloader sidecar. Watches for config changes and hot-reloads FRR. Runs in `routerpod`. |
| `frr-sockets.volume` | Volume | Named volume for FRR unix sockets shared between controller and FRR containers. |
| `openperouter-node-index.service` | Service | Oneshot unit that runs before the controller pod. Executes `openperouter-node-index.sh`. |
| `openperouter-node-index.sh` | Script | Reads the bridge IP, extracts the last octet, writes it as `nodeIndex` in `node-config.yaml`. |
| `crio/controller.container` | Container | Alternative controller container definition for CRI-O runtime. |

---

## 6. New Files — External FRR Test Peer (`externalfrr/`)

Scripts and configs for running an FRR router on the hypervisor host to peer with OpenPERouter via BGP EVPN:

### 6.1 `run_frr.sh`

Sets up a complete EVPN test environment on the host:

1. Creates a VTEP loopback (`lo-vtep`) with IP `100.64.0.1/32`.
2. Creates VRF `red` (table 1100).
3. Creates VXLAN interface `vni100` (VNI 100, local VTEP IP, no-learning).
4. Creates bridge `br100` in VRF `red` with `vni100` as a port, neighbor suppression enabled.
5. Creates a VRF loopback (`lo-vrf-red`) with IP `10.100.0.1/32` for route advertisement.
6. Generates FRR config with BGP EVPN peering (local ASN 64512, remote ASN 64514).
7. Runs FRR in a podman container (`quay.io/frrouting/frr:10.5.1`) with host networking.

### 6.2 `cleanup.sh`

Tears down everything created by `run_frr.sh`: stops the FRR container, removes the VRF loopback, bridge, VXLAN interface, VRF, and VTEP loopback.

### 6.3 `config/`

Directory containing FRR configuration files (`frr.conf`, `daemons`, `vtysh.conf`). Generated by `run_frr.sh` but also committed as reference.

---

## 7. Summary of Extension Points

The branch introduces three general-purpose mechanisms that could be reused beyond OpenPERouter:

| Mechanism | Variable / File | Purpose |
|-----------|----------------|---------|
| Post-config-image hook | `POST_CONFIG_IMAGE_HOOK` | Run arbitrary script after config-image ISO creation |
| Appliance additional images | `APPLIANCE_ADDITIONAL_IMAGES` | Pre-load extra container images into the appliance |
| Appliance local registry | `stopLocalRegistry: false` in template | Keep the appliance registry running post-install |
