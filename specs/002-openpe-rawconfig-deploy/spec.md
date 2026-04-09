# Feature Specification: Alternative OpenPERouter Deployment with Raw FRR Config

**Feature Branch**: `002-openpe-rawconfig-deploy`  
**Created**: 2026-04-08  
**Status**: Draft  
**Input**: User description: "Define an alternative deployment via prepare-env.sh that uses the systemd VNI setup from openperouter (setup_underlay, setup_network, generate-config), deploying a comprehensive raw FRR configuration. Reorganize deploy/extras/ to separate quadlets from config and scripts."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Reorganize deploy/extras/ Directory Structure (Priority: P1)

An operator working on the dev-scripts deployment wants a clean separation between container quadlet files and application-level configuration/scripts. Currently, `deploy/extras/quadlets/` contains a mix of quadlet definitions (.container, .pod, .volume) and shell scripts (.sh) plus service units (.service) that are not quadlets. The operator needs two new directories--`deploy/extras/openpeapi/` and `deploy/extras/rawconfig/`--so that each deployment mode has its own clearly scoped assets, while `deploy/extras/quadlets/` contains only actual container/pod/volume quadlet files.

**Why this priority**: This is the foundational reorganization that both deployment modes depend on. Without clean directory boundaries, the alternative deployment cannot be added without creating confusion about which files belong to which mode.

**Independent Test**: After reorganization, the existing deployment (`prepare-env.sh`) continues to work identically. The `deploy/extras/quadlets/` directory contains only `.container`, `.pod`, and `.volume` files. Non-quadlet scripts and services have been moved to the appropriate new directory.

**Acceptance Scenarios**:

1. **Given** the current `deploy/extras/` directory layout, **When** the reorganization is applied, **Then** `deploy/extras/quadlets/` contains only quadlet files: `controller.container`, `controllerpod.pod`, `frr.container`, `frr-sockets.volume`, `reloader.container`, `routerpod.pod`.
2. **Given** the reorganization is complete, **When** an operator runs the existing `prepare-env.sh`, **Then** the deployment succeeds exactly as before (the butane file references the new file locations correctly).
3. **Given** the reorganization is complete, **When** an operator inspects `deploy/extras/openpeapi/`, **Then** it contains the files used by the current API-driven deployment mode (the openpe_config.yaml, openperouter-node-index.sh, openperouter-raw-config.sh, and their service definitions).
4. **Given** the reorganization is complete, **When** an operator inspects `deploy/extras/rawconfig/`, **Then** it contains the files used by the new raw-config deployment mode (setup-underlay.sh, setup-network.sh, generate-config.sh, common.sh, the YAML template, the env file, and their service definitions).

---

### User Story 2 - Alternative Raw FRR Config Deployment Mode (Priority: P2)

An operator wants to deploy OpenPERouter using a comprehensive raw FRR configuration that includes full EVPN/VXLAN setup (underlay BGP, L3VNI, L2VNI, and overlay) instead of the current minimal raw config that only announces the bridge IP. This mode uses three systemd services that run at boot:

1. **setup-underlay** -- waits for the FRR container, derives the VTEP IP from br0, moves the underlay NIC into the FRR namespace, and saves computed variables.
2. **setup-network** -- creates VRFs, bridges, VXLAN interfaces, and veth pairs inside the FRR namespace.
3. **generate-config** -- renders a YAML configuration template with node-specific values (including a full rawfrrconfigs block) for the controller to consume.

The operator selects this mode by pointing `prepare-env.sh` at the `deploy/config-image-raw/` folder (which has its own `generate_machineconfigs.sh` and butane file) instead of `deploy/config-image-openpe/`. Each folder is self-contained and independently distributable.

**Why this priority**: This is the core new functionality. It enables a self-contained, systemd-driven VPN setup that replaces the simpler bridge-IP-only raw config with a complete EVPN topology.

**Independent Test**: Deploy a cluster using the alternative mode. After boot, verify that the three systemd services ran successfully, the FRR namespace contains VRFs/bridges/VXLAN interfaces, and the generated YAML config includes full rawfrrconfigs with BGP/EVPN configuration.

**Acceptance Scenarios**:

1. **Given** the operator uses `deploy/config-image-raw/`, **When** `prepare-env.sh` generates MachineConfig manifests, **Then** the generated manifest includes the setup-underlay, setup-network, generate-config scripts and their systemd service units, plus the YAML template and environment file.
2. **Given** a node boots with the rawconfig MachineConfig applied, **When** the FRR container becomes ready, **Then** `setup-underlay.service` runs, derives VTEP IP from br0, moves the underlay NIC to the FRR namespace, and writes variables to `/var/lib/openperouter/vpn-setup.vars`.
3. **Given** `setup-underlay.service` has completed, **When** `setup-network.service` runs, **Then** VRFs, L3/L2 bridges, VXLAN interfaces, and veth pairs are created in the FRR namespace with the host-side veth attached to br0.
4. **Given** `setup-underlay.service` has completed, **When** `generate-config.service` runs, **Then** a YAML configuration file is generated from the template at `/var/lib/openperouter/configs/openpe_evpn.yaml` containing correct underlays, l3vnis, l2vnis, and rawfrrconfigs sections.
5. **Given** the rawconfig mode is deployed, **When** the operator inspects the quadlet files on the node, **Then** the same container quadlets (FRR, controller, reloader) are present as in the API-driven mode.

---

### User Story 3 - Butane/MachineConfig Generation for Raw Config Mode (Priority: P2)

The `generate_machineconfigs.sh` script needs to support generating a MachineConfig for the rawconfig deployment mode. A new butane source file references files from `deploy/extras/rawconfig/` and defines the systemd services for setup-underlay, setup-network, and generate-config.

**Why this priority**: Without this, the rawconfig files cannot be delivered to nodes via the agent-based installation flow.

**Independent Test**: Run `generate_machineconfigs.sh` with the rawconfig butane file and verify it produces a valid MachineConfig YAML that includes all expected scripts, the template, the env file, and enabled systemd units.

**Acceptance Scenarios**:

1. **Given** the `deploy/config-image-raw/` folder exists, **When** its `generate_machineconfigs.sh` runs, **Then** a `99-master-openperouter.yaml` MachineConfig is produced containing all rawconfig assets.
2. **Given** the generated MachineConfig, **When** inspected, **Then** all scripts have mode 0755, config files have mode 0644, and all three services plus the quadlet services are enabled.

---

### Edge Cases

- What happens when `br0` does not have an IP address when setup-underlay runs? The script retries for up to 60 seconds before failing with a clear error message.
- What happens when the FRR container is not ready? setup-underlay waits up to the configured timeout (default 60s) and exits with code 124 on timeout.
- What happens when the underlay NIC does not exist? setup-underlay fails with a diagnostic listing of available NICs.
- What happens when the operator switches between deployment modes? The operator points `prepare-env.sh` at either `deploy/config-image-openpe/` or `deploy/config-image-raw/`. Both folders are self-contained; both modes use the same quadlet containers.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The `deploy/extras/quadlets/` directory MUST contain only container/pod/volume quadlet files (`.container`, `.pod`, `.volume`).
- **FR-002**: A `deploy/extras/openpeapi/` directory MUST be created containing the scripts, config, and service definitions used by the current API-driven deployment mode (`openpe_config.yaml`, `openperouter-node-index.sh`, `openperouter-raw-config.sh`, `patch-installer-config.sh`).
- **FR-003**: A `deploy/extras/rawconfig/` directory MUST be created containing the scripts, config template, environment file, and service definitions used by the new rawconfig deployment mode (`setup-underlay.sh`, `setup-network.sh`, `generate-config.sh`, `common.sh`, `openpe_evpn.yaml.template`, `vpn-setup.env`).
- **FR-004**: The rawconfig mode MUST deploy three systemd services (`setup-underlay.service`, `setup-network.service`, `generate-config.service`) that run in sequence after the FRR container is ready.
- **FR-005**: The `setup-underlay` script MUST derive the VTEP IP from the br0 bridge IP and move the underlay NIC into the FRR container's network namespace.
- **FR-006**: The `setup-network` script MUST create VRFs, L3/L2 bridges, VXLAN interfaces, and veth pairs in the FRR namespace, attaching the host-side veth to br0.
- **FR-007**: The `generate-config` script MUST render the YAML template with node-specific values and write the result to `/var/lib/openperouter/configs/openpe_evpn.yaml`.
- **FR-008**: The existing `deploy/config-image/` MUST be renamed to `deploy/config-image-openpe/` and its butane file and `generate_machineconfigs.sh` updated to reference `deploy/extras/openpeapi/` and `deploy/extras/quadlets/`.
- **FR-009**: A new `deploy/config-image-raw/` folder MUST be created containing its own `generate_machineconfigs.sh` (duplicated from `config-image-openpe/`) and a rawconfig butane file that references files from `deploy/extras/rawconfig/`, `deploy/extras/quadlets/`, and `deploy/extras/openpeapi/patch-installer-config.sh` (shared installer patching).
- **FR-010**: `prepare-env.sh` MUST select between `deploy/config-image-openpe/` and `deploy/config-image-raw/` based on the `USE_RAW` environment variable.
- **FR-011**: The `deploy/extras/config/` directory MUST be removed after its content is moved to `deploy/extras/openpeapi/`.
- **FR-012**: The existing `deploy/appliance/` MUST be updated so that `patch_appliance.sh` references the new `deploy/extras/openpeapi/` and `deploy/extras/quadlets/` paths instead of the old `quadlets/` and `config/` paths.
- **FR-013**: `deploy/appliance/patch_appliance.sh` MUST support both modes via the `USE_RAW` environment variable: when set, it embeds rawconfig assets (setup-underlay.sh, setup-network.sh, generate-config.sh, common.sh, template, env) and their systemd services; when unset, it embeds openpeapi scripts and their services. No separate `appliance-raw/` folder is created.

### Key Entities

- **Deployment Mode**: Either "openpeapi" (current, API-driven with minimal raw config) or "rawconfig" (new, full EVPN raw config with systemd setup scripts). Selected at build time via `USE_RAW` env var, which determines which `config-image-*` folder is used.
- **MachineConfig Manifest**: YAML file generated by butane, embedding scripts, configs, and systemd units that are applied to nodes at first boot.
- **VPN Setup Variables**: Runtime state file (`vpn-setup.vars`) generated by setup-underlay and consumed by setup-network and generate-config.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After reorganization, the existing deployment flow (`prepare-env.sh` with openpeapi mode) completes successfully with no behavioral changes.
- **SC-002**: The rawconfig deployment mode produces a valid MachineConfig that passes butane compilation without errors.
- **SC-003**: On a deployed node using rawconfig mode, all three setup systemd services reach "active (exited)" state within 3 minutes of the FRR container becoming ready.
- **SC-004**: On a deployed node using rawconfig mode, the generated configuration file contains all required sections (underlays, l3vnis, l2vnis, rawfrrconfigs) with node-specific values correctly substituted.
- **SC-005**: `deploy/extras/quadlets/` contains exactly 6 files (the quadlet definitions), with no shell scripts or service unit files.
- **SC-006**: The appliance ISO flow (`deploy/appliance/patch_appliance.sh`) works with the reorganized extras paths in both modes: without `USE_RAW` (openpeapi) and with `USE_RAW` set (rawconfig).

## Clarifications

### Session 2026-04-08

- Q: Does the rawconfig deployment mode also need the installer patching service (patch-installer-config.sh)? → A: Yes, both modes need it. The rawconfig butane file includes patch-installer-config.sh from openpeapi/ as a shared asset.
- Q: Should vpn-setup.env defaults match the dev-scripts environment or upstream? → A: Use dev-scripts defaults (TOR_IP=192.168.111.1, TOR_AS=64512, LOCAL_AS=64514) so it works out of the box.

## Assumptions

- The scripts from the upstream openperouter repository (`005-systemd-vni-setup` branch) are used as-is or with minimal adaptation for the MachineConfig/butane embedding context.
- The `common.sh` utility functions are deployed alongside the setup scripts to `/usr/local/bin/`.
- The `vpn-setup.env` file ships with dev-scripts environment defaults: `TOR_IP=192.168.111.1`, `TOR_AS=64512`, `LOCAL_AS=64514`.
- The `patch-installer-config.sh` functionality is common to both deployment modes. It remains in `deploy/extras/openpeapi/` and is referenced by both the openpeapi and rawconfig butane files as a shared asset.
- The `openperouter/` directory at the repo root is not modified as specified by the user.
