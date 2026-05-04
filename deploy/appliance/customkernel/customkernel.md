# Custom Kernel RHCOS ISO for OpenShift Appliance

## Problem

The seg6 route kernel module is buggy in the stock RHCOS kernel (causes kernel panic).
Verizon requires a patched kernel (`5.14.0-570.76.1.5114_2224397254.el9_6`) that fixes this issue.
The patched kernel must be present both in the live ISO (boot phase) and in the installed OS (ostree written to disk).

## Overview

Two artifacts are needed:

1. **Custom RHCOS live ISO** — built via CoreOS Assembler (cosa) with patched kernel RPMs, used as the boot ISO.
2. **Custom OCP release payload** — built via `oc adm release new` with a custom `rhel-coreos` container image containing the patched kernel, so the installed OS also has it.

## Prerequisites

- Connected to Red Hat VPN
- Red Hat internal CA certificates installed:
  ```bash
  sudo curl -o /etc/pki/ca-trust/source/anchors/2022-IT-Root-CA.pem https://certs.corp.redhat.com/certs/2022-IT-Root-CA.pem
  sudo curl -o /etc/pki/ca-trust/source/anchors/2015-IT-Root-CA.pem https://certs.corp.redhat.com/certs/2015-IT-Root-CA.pem
  sudo update-ca-trust
  ```
- Logged in to Red Hat registry: `podman login registry.redhat.io`
- Tools: podman, jq, yq, butane, coreos-installer, skopeo

## Step 1: Build the custom rhel-coreos container image

This is handled by `custom.sh` (or manually). It builds a node image from the cosa
`.ociarchive` using the `openshift/os` repo's Containerfile, pushes it, and creates
a custom release payload with `oc adm release new`.

See `instructions.md` for the full procedure (cosa build → openshift/os build → oc adm release new).

The output is a custom release image, e.g.:
```
quay.io/mavazque/ocp-release:4.20.12-x86_64-kernel-5.14.0-570.76.1.5114_2224397254
```

## Step 2: Build the custom RHCOS live ISO

```bash
cd deploy/appliance/customkernel/
./build_custom_iso.sh quay.io/mavazque/ocp-release:4.20.12-x86_64-kernel-5.14.0-570.76.1.5114_2224397254
```

This script:
1. Initializes a cosa workspace in `customkernel/rhcos-build/` (persistent, reusable)
2. Copies kernel RPMs from `5.14.0-570.76.1.5114_2224397254.el9_6.x86_64/` into `overrides/rpm/`
3. Runs `cosa fetch` → `cosa build` → `cosa osbuild live`
4. Copies the resulting ISO to `appliance/cache/<version>-x86_64/coreos-x86_64.iso`
5. Updates `appliance-config.yaml.base` to point `ocpRelease.url` at the custom release

### Key details

- cosa is pinned to `v43.20260202.3.1` to avoid incompatibilities with the `rhel-9.6`
  config branch (newer cosa versions expect a `versionary` script and use an incompatible
  `rpm-ostree compose rootfs` flow).
- Registry auth is mounted from the host into the cosa container at
  `/home/builder/.docker/config.json`.
- The build directory `rhcos-build/` is persistent so subsequent runs reuse the cache.
- The ISO must be placed in `cache/<ocp-version>-x86_64/coreos-x86_64.iso` (not the
  cache root) for the appliance builder to find it. When it works, the appliance builder
  logs: `Reusing base CoreOS ISO from cache`.

## Step 3: Build the appliance ISO

```bash
cd deploy/appliance/
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" ./generate_appliance.sh /path/to/pull_secret.json
```

This builds the appliance ISO using the custom RHCOS from cache and the custom release
from the config, then patches it with OpenPERouter content and the SSH key via
`patch_appliance.sh`.

Output: `deploy/appliance/appliance.iso`

## Step 4: Consume from devscripts

In `config_fpaoline.sh`:
```bash
export APPLIANCE_ISO_PATH="${PWD}/deploy/appliance/appliance.iso"
export OPENSHIFT_RELEASE_IMAGE="quay.io/mavazque/ocp-release@sha256:<digest>"
```

- `APPLIANCE_ISO_PATH` — tells devscripts to use the pre-built ISO instead of building one.
  When set, devscripts skips both `create_appliance_liveiso()` and `patch_appliance.sh`
  (the ISO is assumed to be fully patched).
- `OPENSHIFT_RELEASE_IMAGE` — pins devscripts to the same custom release payload the
  appliance was built with. This is critical: the appliance's `load-config-iso.sh` does a
  strict diff on `cluster-image-set.yaml` and rejects mismatches.

## Verification

After the VM boots:
```bash
ssh core@<node-ip> uname -r
# Expected: 5.14.0-570.76.1.5114_2224397254.el9_6.x86_64
```

## File inventory

```
customkernel/
├── build_custom_iso.sh                              # Builds custom RHCOS ISO via cosa
├── custom.sh                                        # Builds custom release payload
├── customkernel.md                                  # This file
├── instructions.md                                  # Original manual procedure
├── 5.14.0-570.76.1.5114_2224397254.el9_6.x86_64/   # Patched kernel RPMs
└── rhcos-build/                                     # cosa workspace (persistent)
```
