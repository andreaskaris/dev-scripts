# Implementation Plan: Alternative OpenPERouter Deployment with Raw FRR Config

**Branch**: `002-openpe-rawconfig-deploy` | **Date**: 2026-04-08 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-openpe-rawconfig-deploy/spec.md`

## Summary

Add an alternative deployment mode for OpenPERouter that uses a comprehensive raw FRR configuration with systemd-driven VNI setup (setup-underlay, setup-network, generate-config) instead of the current minimal raw config. Reorganize `deploy/extras/` so that `quadlets/` contains only container/pod/volume quadlet files, with mode-specific assets split into `openpeapi/` (current) and `rawconfig/` (new). Mode selection is via the `USE_RAW` environment variable.

## Technical Context

**Language/Version**: Bash (POSIX-compatible shell scripts), Butane YAML (OpenShift 4.20.0 variant)
**Primary Dependencies**: butane (MachineConfig compiler), podman (container runtime on nodes), FRR container image (`quay.io/fpaoline/router:dev4`)
**Storage**: Filesystem-based (MachineConfig embeds files into CoreOS nodes at `/usr/local/bin/`, `/etc/`, `/var/lib/openperouter/`)
**Testing**: Manual deployment validation (butane compilation, systemd service status, generated config inspection)
**Target Platform**: RHEL CoreOS nodes provisioned via agent-based OpenShift installer
**Project Type**: Infrastructure scripts (shell + YAML config)
**Performance Goals**: N/A (boot-time one-shot services)
**Constraints**: Scripts must run in CoreOS minimal environment; no package installation at runtime
**Scale/Scope**: Single cluster deployment, 1-3 master nodes

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Consumer-Only Posture | PASS | All changes are in `deploy/` (our orchestration layer), not in upstream dev-scripts. The `openperouter/` repo root dir is untouched. |
| II. Reproducible Configuration | PASS | Mode is selected via `USE_RAW` env var in `config.sh`. `vpn-setup.env` is version-controlled with known defaults. |
| III. Minimal Resource Footprint | PASS | No additional VMs or containers. Same quadlet footprint in both modes. |
| IV. Validation Before Iteration | PASS | Butane compilation validates manifest correctness. Systemd services provide runtime validation via exit codes. |
| V. Cleanup Discipline | PASS | No new cleanup requirements. Both modes use the same containers/pods. |

No violations. No complexity justifications needed.

## Project Structure

### Documentation (this feature)

```text
specs/002-openpe-rawconfig-deploy/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── quickstart.md        # Phase 1 output
└── checklists/
    └── requirements.md  # Spec quality checklist
```

### Source Code (repository root)

```text
deploy/
├── config-image-openpe/             # RENAMED from config-image/
│   ├── generate_machineconfigs.sh   # MODIFIED: refs to openpeapi/ + quadlets/
│   ├── openperouter.bu              # MODIFIED: refs to openpeapi/ + quadlets/
│   └── registry.bu                  # unchanged
├── config-image-raw/                # NEW: self-contained rawconfig folder
│   ├── generate_machineconfigs.sh   # DUPLICATED + adapted for rawconfig
│   ├── openperouter-raw.bu          # NEW: rawconfig butane source
│   └── registry.bu                  # DUPLICATED from config-image-openpe/
├── appliance/                       # MODIFIED: patch_appliance.sh updated for new paths
│   ├── appliance-config.yaml.base
│   ├── generate_appliance.sh
│   ├── hackagent.sh
│   └── patch_appliance.sh           # MODIFIED: refs to openpeapi/ + quadlets/
├── appliance/                       # MODIFIED: patch_appliance.sh supports both modes via USE_RAW
├── devscripts/
│   └── prepare-env.sh               # MODIFIED: USE_RAW selects config-image-* folder
└── extras/
    ├── quadlets/                     # CLEANED: only .container/.pod/.volume files
    │   ├── controller.container
    │   ├── controllerpod.pod
    │   ├── frr.container
    │   ├── frr-sockets.volume
    │   ├── reloader.container
    │   └── routerpod.pod
    ├── openpeapi/                    # NEW DIR: current mode assets
    │   ├── openpe_config.yaml        # moved from config/
    │   ├── openperouter-node-index.sh
    │   ├── openperouter-raw-config.sh
    │   └── patch-installer-config.sh # shared by both modes
    ├── rawconfig/                    # NEW DIR: rawconfig mode assets
    │   ├── common.sh
    │   ├── setup-underlay.sh
    │   ├── setup-network.sh
    │   ├── generate-config.sh
    │   ├── openpe_evpn.yaml.template
    │   └── vpn-setup.env
    ├── dns/                          # unchanged
    └── registry/                     # unchanged
```

**Structure Decision**: Flat layout under `deploy/extras/` with mode-specific subdirectories. No nesting beyond one level. Scripts from upstream openperouter are copied into `rawconfig/` and adapted for dev-scripts defaults.

## Complexity Tracking

No constitution violations to justify.

## Implementation Phases

### Phase A: Directory Reorganization (FR-001, FR-002, FR-008, FR-011, FR-012)

1. Create `deploy/extras/openpeapi/` directory
2. Move files from `deploy/extras/quadlets/` to `deploy/extras/openpeapi/`:
   - `openperouter-node-index.sh`
   - `openperouter-raw-config.sh`
   - `patch-installer-config.sh`
   - `enable-virtual-interfaces.sh` (legacy duplicate, can be removed if unused)
   - `openperouter-node-index.service`
   - `openperouter-raw-config.service`
   - `enable-virtual-interfaces.service`
3. Move `deploy/extras/config/openpe_config.yaml` to `deploy/extras/openpeapi/openpe_config.yaml`
4. Remove `deploy/extras/config/` directory
5. Rename `deploy/config-image/` to `deploy/config-image-openpe/`
6. Update `deploy/config-image-openpe/openperouter.bu` to reference new paths:
   - `openpeapi/openpe_config.yaml` instead of `config/openpe_config.yaml`
   - `openpeapi/openperouter-node-index.sh` instead of `quadlets/openperouter-node-index.sh`
   - `openpeapi/openperouter-raw-config.sh` instead of `quadlets/openperouter-raw-config.sh`
   - `openpeapi/patch-installer-config.sh` instead of `quadlets/patch-installer-config.sh`
7. Update `deploy/config-image-openpe/generate_machineconfigs.sh` paths for renamed directory
8. Update `deploy/devscripts/prepare-env.sh` to reference `deploy/config-image-openpe/` (default) or `deploy/config-image-raw/` when `USE_RAW` is set
9. Update `deploy/appliance/patch_appliance.sh` to reference `openpeapi/` and `quadlets/` paths instead of old `quadlets/` and `config/` paths
10. Verify butane compilation still succeeds with updated paths

### Phase B: Add Rawconfig Assets (FR-003)

1. Create `deploy/extras/rawconfig/` directory
2. Add scripts from upstream openperouter `005-systemd-vni-setup` branch:
   - `common.sh` -- as-is from upstream
   - `setup-underlay.sh` -- as-is from upstream
   - `setup-network.sh` -- as-is from upstream
   - `generate-config.sh` -- as-is from upstream
3. Add config template `openpe_evpn.yaml.template` -- as-is from upstream
4. Add `vpn-setup.env` with dev-scripts defaults:
   - `TOR_IP=192.168.111.1`
   - `TOR_AS=64512`
   - `LOCAL_AS=64514`
   - Other values from upstream defaults (VRF_NAME=red, L2_VNI=210, L3_VNI=100, etc.)

### Phase C: Rawconfig Config-Image and Appliance Folders (FR-004, FR-009, FR-013)

1. Create `deploy/config-image-raw/` directory
2. Duplicate `deploy/config-image-openpe/generate_machineconfigs.sh` to `deploy/config-image-raw/generate_machineconfigs.sh` and adapt it to use `openperouter-raw.bu`
3. Duplicate `deploy/config-image-openpe/registry.bu` to `deploy/config-image-raw/registry.bu`
4. Create `deploy/config-image-raw/openperouter-raw.bu`:
   - Storage section: embed all rawconfig scripts (mode 0755), template + env (mode 0644), common.sh (mode 0755)
   - Storage section: embed all quadlet files (same as openperouter.bu)
   - Storage section: embed `openpeapi/patch-installer-config.sh` (shared, mode 0755)
   - Systemd section: define and enable `setup-underlay.service`, `setup-network.service`, `generate-config.service`
   - Systemd section: enable all quadlet services (same as openperouter.bu)
   - Systemd section: define and enable `enable-virtual-interfaces.service` for installer patching
5. Verify butane compilation of `openperouter-raw.bu` succeeds
6. Update `deploy/appliance/patch_appliance.sh` with a `USE_RAW` conditional: when set, embeds rawconfig assets (setup-underlay.sh, setup-network.sh, generate-config.sh, common.sh, template, env from `rawconfig/`) and their systemd services; when unset, embeds openpeapi scripts and their services

### Phase D: Validation

1. Run `deploy/config-image-openpe/generate_machineconfigs.sh` -- verify existing MachineConfig output unchanged
2. Run `deploy/config-image-raw/generate_machineconfigs.sh` -- verify rawconfig MachineConfig contains all expected files and services
3. Inspect generated YAML for correct file modes, service dependencies, and enabled units
4. Verify `deploy/extras/quadlets/` contains exactly 6 quadlet files
