# Research: Alternative OpenPERouter Deployment with Raw FRR Config

**Date**: 2026-04-08

## R1: Upstream Script Compatibility with MachineConfig/Butane Embedding

**Decision**: Use upstream scripts as-is from `005-systemd-vni-setup` branch.

**Rationale**: The scripts are self-contained bash with no external dependencies beyond `podman`, `ip`, `nsenter`, and `sed` -- all available on CoreOS. They use `SCRIPT_DIR` for sourcing `common.sh`, which resolves correctly when all scripts are placed in `/usr/local/bin/`. The systemd service definitions use `EnvironmentFile=-` (optional) so missing env files don't block startup.

**Alternatives considered**:
- Rewriting scripts for butane inline: Rejected -- adds maintenance burden and diverges from upstream.
- Packaging as RPM: Rejected -- unnecessary complexity for dev-scripts context.

## R2: vpn-setup.env Defaults for Dev-Scripts Environment

**Decision**: Ship `vpn-setup.env` with dev-scripts-specific defaults (TOR_IP=192.168.111.1, TOR_AS=64512, LOCAL_AS=64514).

**Rationale**: The external FRR container started by `deploy/devscripts/externalfrr/run_frr.sh` listens on 192.168.111.1 with ASN 64512. Matching these defaults ensures the rawconfig mode works out of the box without manual editing. Other values (VRF_NAME=red, L2_VNI=210, L3_VNI=100, VXLAN_PORT=4789, L2_GATEWAY_IP=192.168.110.1/24) match the existing `openpe_config.yaml`.

**Alternatives considered**:
- Keep upstream defaults (TOR_IP=10.1.1.254): Rejected -- would fail on first deployment.

## R3: Two Self-Contained config-image Folders

**Decision**: Create separate `deploy/config-image-openpe/` and `deploy/config-image-raw/` folders, each with its own `generate_machineconfigs.sh`, butane file, and `registry.bu`. Both use `EXTRASDIR` (pointing to `deploy/extras/`) as the butane `--files-dir`.

**Rationale**: Self-contained folders make distribution easier -- you can ship either folder independently without worrying about shared script state or env-var switches. The duplication of `generate_machineconfigs.sh` and `registry.bu` is minimal and worth the simplicity.

**Alternatives considered**:
- Single `config-image/` with `USE_RAW` switch: Rejected -- user preference for independent distribution.
- Separate `--files-dir` per butane file: Not needed -- both butane files reference subdirs under `deploy/extras/`.

## R4: Service Ordering in Rawconfig Mode

**Decision**: Use explicit systemd `After=` and `Requires=` dependencies matching upstream service definitions.

**Rationale**: The upstream service files define a clear dependency chain: `setup-underlay.service` depends on `routerpod-pod.service` and `frr.service`; `setup-network.service` depends on `setup-underlay.service`; `generate-config.service` depends on `setup-underlay.service`. This ensures FRR is ready before underlay setup, and VTEP IP is derived before network creation or config generation.

**Alternatives considered**:
- Single combined script: Rejected -- loses restart granularity and makes debugging harder.

## R5: Shared patch-installer-config.sh

**Decision**: Keep `patch-installer-config.sh` in `openpeapi/` and reference it from both butane files via `local: openpeapi/patch-installer-config.sh`.

**Rationale**: The script is needed by both modes (it patches assisted-service.env for bridge IP validation). Keeping a single copy avoids duplication. Since both butane files use the same `--files-dir`, the cross-directory reference works naturally.

**Alternatives considered**:
- Move to a shared `deploy/extras/common/` directory: Rejected -- adds another directory for a single file.
- Duplicate in `rawconfig/`: Rejected -- maintenance burden.
