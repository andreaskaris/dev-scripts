# Tasks: Alternative OpenPERouter Deployment with Raw FRR Config

**Input**: Design documents from `/specs/002-openpe-rawconfig-deploy/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: Not requested. No test tasks included.

**Organization**: Tasks are grouped by user story. US1 is foundational and must complete before US2/US3.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: User Story 1 - Reorganize deploy/extras/, Rename config-image, Update appliance (Priority: P1)

**Goal**: Clean separation of quadlet files from mode-specific scripts. Create `openpeapi/` and `rawconfig/` directories under `deploy/extras/`. Rename `deploy/config-image/` to `deploy/config-image-openpe/`. Update `deploy/appliance/patch_appliance.sh` for new paths. Only `.container`, `.pod`, `.volume` files remain in `quadlets/`.

**Independent Test**: Run `butane --files-dir=deploy/extras deploy/config-image-openpe/openperouter.bu` and verify it compiles successfully with the new paths. Verify `deploy/extras/quadlets/` contains exactly 6 files. Verify `deploy/appliance/patch_appliance.sh` references correct paths.

### Implementation for User Story 1

- [ ] T001 [US1] Create directory deploy/extras/openpeapi/
- [ ] T002 [P] [US1] Move deploy/extras/quadlets/openperouter-node-index.sh to deploy/extras/openpeapi/openperouter-node-index.sh
- [ ] T003 [P] [US1] Move deploy/extras/quadlets/openperouter-raw-config.sh to deploy/extras/openpeapi/openperouter-raw-config.sh
- [ ] T004 [P] [US1] Move deploy/extras/quadlets/patch-installer-config.sh to deploy/extras/openpeapi/patch-installer-config.sh
- [ ] T005 [P] [US1] Move deploy/extras/config/openpe_config.yaml to deploy/extras/openpeapi/openpe_config.yaml
- [ ] T006 [P] [US1] Remove deploy/extras/quadlets/enable-virtual-interfaces.sh (legacy duplicate of patch-installer-config.sh)
- [ ] T007 [P] [US1] Remove deploy/extras/quadlets/openperouter-node-index.service (service defined inline in butane)
- [ ] T008 [P] [US1] Remove deploy/extras/quadlets/openperouter-raw-config.service (service defined inline in butane)
- [ ] T009 [P] [US1] Remove deploy/extras/quadlets/enable-virtual-interfaces.service (service defined inline in butane)
- [ ] T010 [US1] Remove deploy/extras/config/ directory after moving openpe_config.yaml
- [ ] T011 [US1] Rename deploy/config-image/ to deploy/config-image-openpe/
- [ ] T012 [US1] Update deploy/config-image-openpe/openperouter.bu to reference openpeapi/ paths instead of config/ and quadlets/ for scripts and config files
- [ ] T013 [US1] Update deploy/config-image-openpe/generate_machineconfigs.sh to fix SCRIPTDIR path after rename (SCRIPTDIR now points to config-image-openpe/)
- [ ] T014 [US1] Update deploy/devscripts/prepare-env.sh to reference deploy/config-image-openpe/generate_machineconfigs.sh by default, or deploy/config-image-raw/generate_machineconfigs.sh when USE_RAW is set
- [ ] T015 [US1] Update deploy/appliance/patch_appliance.sh to reference openpeapi/ paths for scripts (openperouter-node-index.sh, openperouter-raw-config.sh, patch-installer-config.sh) and openpeapi/openpe_config.yaml instead of old config/ and quadlets/ paths

**Checkpoint**: `deploy/extras/quadlets/` contains only 6 quadlet files. `openperouter.bu` compiles with `butane --files-dir=deploy/extras`. `prepare-env.sh` calls the correct config-image folder. `patch_appliance.sh` uses correct paths. Existing deployment flow unchanged.

---

## Phase 2: User Story 2 - Add Rawconfig Assets (Priority: P2)

**Goal**: Populate `deploy/extras/rawconfig/` with upstream scripts from openperouter `005-systemd-vni-setup` branch and a dev-scripts-specific environment file.

**Independent Test**: All files exist in `deploy/extras/rawconfig/` with correct content. Scripts are executable.

### Implementation for User Story 2

- [ ] T016 [US2] Create directory deploy/extras/rawconfig/
- [ ] T017 [P] [US2] Add deploy/extras/rawconfig/common.sh from upstream openperouter 005-systemd-vni-setup branch (usr/local/bin/common.sh)
- [ ] T018 [P] [US2] Add deploy/extras/rawconfig/setup-underlay.sh from upstream openperouter 005-systemd-vni-setup branch (usr/local/bin/setup-underlay.sh)
- [ ] T019 [P] [US2] Add deploy/extras/rawconfig/setup-network.sh from upstream openperouter 005-systemd-vni-setup branch (usr/local/bin/setup-network.sh)
- [ ] T020 [P] [US2] Add deploy/extras/rawconfig/generate-config.sh from upstream openperouter 005-systemd-vni-setup branch (usr/local/bin/generate-config.sh)
- [ ] T021 [P] [US2] Add deploy/extras/rawconfig/openpe_evpn.yaml.template from upstream openperouter 005-systemd-vni-setup branch (etc/openperouter/templates/openpe_evpn.yaml.template)
- [ ] T022 [US2] Create deploy/extras/rawconfig/vpn-setup.env with dev-scripts defaults (TOR_IP=192.168.111.1, TOR_AS=64512, LOCAL_AS=64514, UNDERLAY_NIC=eth1, VRF_NAME=red, L2_VNI=210, L3_VNI=100, VXLAN_PORT=4789, L2_GATEWAY_IP=192.168.110.1/24)

**Checkpoint**: All rawconfig assets present in `deploy/extras/rawconfig/`. Scripts match upstream content.

---

## Phase 3: User Story 3 - Create config-image-raw Folder and Update appliance/ (Priority: P2)

**Goal**: Create a self-contained `deploy/config-image-raw/` folder with its own duplicated scripts adapted for rawconfig mode. Update the single `deploy/appliance/patch_appliance.sh` with a `USE_RAW` conditional instead of creating a separate `appliance-raw/` folder.

**Independent Test**: Run `butane --files-dir=deploy/extras deploy/config-image-raw/openperouter-raw.bu` and verify it compiles. Run `deploy/config-image-raw/generate_machineconfigs.sh` and verify it produces correct output. Verify `deploy/appliance/patch_appliance.sh` embeds rawconfig assets when `USE_RAW` is set and openpeapi assets otherwise.

### Implementation for User Story 3

- [ ] T023 [US3] Create directory deploy/config-image-raw/
- [ ] T024 [P] [US3] Duplicate deploy/config-image-openpe/registry.bu to deploy/config-image-raw/registry.bu
- [ ] T025 [P] [US3] Duplicate deploy/config-image-openpe/generate_machineconfigs.sh to deploy/config-image-raw/generate_machineconfigs.sh and update it to use openperouter-raw.bu instead of openperouter.bu
- [ ] T026 [US3] Create deploy/config-image-raw/openperouter-raw.bu with storage section embedding rawconfig scripts (mode 0755), template + env (mode 0644), common.sh (mode 0755), all quadlet files from quadlets/, and openpeapi/patch-installer-config.sh (shared); systemd section defining setup-underlay.service, setup-network.service, generate-config.service with correct dependency chain, enabling all quadlet services, and defining enable-virtual-interfaces.service for installer patching
- [ ] T027 [US3] Update deploy/appliance/patch_appliance.sh with a USE_RAW conditional: when set, stage and embed rawconfig assets (common.sh, setup-underlay.sh, setup-network.sh, generate-config.sh from rawconfig/, openpe_evpn.yaml.template and vpn-setup.env from rawconfig/, patch-installer-config.sh from openpeapi/) and their systemd services (setup-underlay.service, setup-network.service, generate-config.service); when unset, embed openpeapi scripts and their services

**Checkpoint**: Both config-image folders compile independently. `prepare-env.sh` with `USE_RAW` calls `config-image-raw/generate_machineconfigs.sh`. `appliance/patch_appliance.sh` embeds rawconfig assets when `USE_RAW` is set, openpeapi assets otherwise.

---

## Phase 4: Validation & Polish

**Purpose**: End-to-end verification of both deployment modes

- [ ] T029 Verify deploy/extras/quadlets/ contains exactly 6 files (controller.container, controllerpod.pod, frr.container, frr-sockets.volume, reloader.container, routerpod.pod)
- [ ] T030 [P] Run deploy/config-image-openpe/generate_machineconfigs.sh and verify 99-master-openperouter.yaml output is functionally unchanged
- [ ] T031 [P] Run deploy/config-image-raw/generate_machineconfigs.sh and verify 99-master-openperouter.yaml contains all rawconfig scripts, template, env, quadlets, and systemd services
- [ ] T032 Inspect generated rawconfig MachineConfig YAML for correct file modes (0755 for scripts, 0644 for configs) and service dependencies (setup-underlay After routerpod/frr, setup-network After setup-underlay, generate-config After setup-underlay)

---

## Dependencies & Execution Order

### Phase Dependencies

- **User Story 1 (Phase 1)**: No dependencies - start immediately. BLOCKS US2 and US3.
- **User Story 2 (Phase 2)**: Depends on US1 completion (needs `rawconfig/` directory created).
- **User Story 3 (Phase 3)**: Depends on US1 and US2 completion (butane file references files from both `openpeapi/` and `rawconfig/`, and duplicates from `config-image-openpe/` and `appliance/`).
- **Validation (Phase 4)**: Depends on all user stories being complete.

### User Story Dependencies

- **User Story 1 (P1)**: Foundational - no dependencies, blocks everything else
- **User Story 2 (P2)**: Depends on US1 (directory exists). Independent of US3.
- **User Story 3 (P2)**: Depends on US1 + US2 (references files from both new directories, duplicates from config-image-openpe/ and appliance/)

### Within Each User Story

- Directory creation before file moves/additions
- File moves before butane path updates
- Rename before butane/script path fixes
- All file operations before butane compilation verification

### Parallel Opportunities

Within US1: T002-T009 can all run in parallel (independent file moves/deletes)
Within US2: T017-T021 can all run in parallel (independent file additions)
Within US3: T024-T025 can run in parallel (independent file duplications)
Within Validation: T030-T031 can run in parallel (independent compilation tests)

---

## Parallel Example: User Story 1

```bash
# After T001 (create openpeapi/ dir), launch all file moves in parallel:
Task: "Move openperouter-node-index.sh to deploy/extras/openpeapi/"
Task: "Move openperouter-raw-config.sh to deploy/extras/openpeapi/"
Task: "Move patch-installer-config.sh to deploy/extras/openpeapi/"
Task: "Move openpe_config.yaml to deploy/extras/openpeapi/"
Task: "Remove enable-virtual-interfaces.sh from quadlets/"
Task: "Remove .service files from quadlets/"
```

## Parallel Example: User Story 2

```bash
# After T016 (create rawconfig/ dir), launch all file additions in parallel:
Task: "Add common.sh to deploy/extras/rawconfig/"
Task: "Add setup-underlay.sh to deploy/extras/rawconfig/"
Task: "Add setup-network.sh to deploy/extras/rawconfig/"
Task: "Add generate-config.sh to deploy/extras/rawconfig/"
Task: "Add openpe_evpn.yaml.template to deploy/extras/rawconfig/"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: US1 - Directory Reorganization + config-image rename + appliance path fix
2. **STOP and VALIDATE**: Verify butane compilation, quadlets/ has 6 files, prepare-env.sh references correct folder, appliance/patch_appliance.sh uses correct paths
3. Existing deployment still works with reorganized paths

### Incremental Delivery

1. US1 → Reorganized directory structure + config-image-openpe/ + appliance path fix → Validate existing mode works
2. US2 → Rawconfig assets in place → Validate files present
3. US3 → config-image-raw/ folder complete + appliance/patch_appliance.sh updated with USE_RAW conditional → Validate butane compilation
4. Validation → End-to-end check of both modes

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- US1 is the MVP - delivers clean directory structure with no behavioral change
- US2 + US3 together deliver the rawconfig mode
- Each config-image-* and appliance-* folder is self-contained and independently distributable
- registry.bu is duplicated in both config-image folders for distribution independence
- A single `deploy/appliance/` folder serves both modes; no `appliance-raw/` duplication
- Commit after each phase completion
- All upstream scripts from openperouter 005-systemd-vni-setup are used as-is (research decision R1)
- vpn-setup.env uses dev-scripts defaults, not upstream defaults (research decision R2)
