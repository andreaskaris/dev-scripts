#!/bin/bash
# generate_appliance.sh - Build an OpenShift appliance ISO and embed
# OpenPERouter quadlets, configs, registry mirrors, DNS overrides,
# and the ignition hack agent into it.
#
# Usage: generate_appliance.sh <appliance_config_dir>
#
#   appliance_config_dir  Directory containing appliance-config.yaml and
#                         install-config.yaml (passed to openshift-appliance).
#                         The appliance tool writes its cache (including
#                         cluster-resources) and the output ISO here.
#
# Requires: coreos-installer, jq, yq, butane, podman

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLIANCE_IMAGE="${APPLIANCE_IMAGE:-quay.io/edge-infrastructure/openshift-appliance:latest}"

appliance_config_dir="$1"

# ============================================================
# Step 1: Build the appliance live ISO
# ============================================================
echo "==> Building appliance live ISO from ${appliance_config_dir}..."

asset_dir="$(realpath "${appliance_config_dir}")"

sudo podman run -it --rm --pull newer --privileged --net=host \
    -v "${asset_dir}:/assets:Z" \
    "${APPLIANCE_IMAGE}" build live-iso --log-level=debug

appliance_iso="${asset_dir}/appliance.iso"

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found after build: ${appliance_iso}"
    exit 1
fi

echo "==> Appliance ISO built: ${appliance_iso}"

# ============================================================
# Step 2: Patch the ISO with OpenPERouter content and hack agent
# ============================================================
# The appliance tool writes cache/*/cluster-resources into asset_dir,
# so it serves as both the config dir and the ocp_dir for patching.
"${SCRIPTDIR}/patch_appliance.sh" "${appliance_iso}" "${asset_dir}"
