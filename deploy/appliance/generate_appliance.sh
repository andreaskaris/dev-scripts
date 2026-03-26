#!/bin/bash
# generate_appliance.sh - Build an OpenShift appliance ISO and embed
# OpenPERouter quadlets, configs, registry mirrors, DNS overrides,
# and the ignition hack agent into it.
#
# Usage: generate_appliance.sh <appliance_config_dir> <appliance_iso> <ocp_dir>
#
#   appliance_config_dir  Directory containing appliance-config.yaml and
#                         install-config.yaml (passed to openshift-appliance)
#   appliance_iso         Path to the appliance ISO to patch (output of the build)
#   ocp_dir               OCP working directory containing cache/*/cluster-resources
#
# Requires: coreos-installer, jq, yq, butane, podman

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLIANCE_IMAGE="${APPLIANCE_IMAGE:-quay.io/edge-infrastructure/openshift-appliance:latest}"

appliance_config_dir="$1"
appliance_iso="$2"
ocp_dir="$3"

# ============================================================
# Step 1: Build the appliance live ISO
# ============================================================
echo "==> Building appliance live ISO from ${appliance_config_dir}..."

asset_dir="$(realpath "${appliance_config_dir}")"

sudo podman run -it --rm --pull newer --privileged --net=host \
    -v "${asset_dir}:/assets:Z" \
    "${APPLIANCE_IMAGE}" build live-iso --log-level=debug

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found after build: ${appliance_iso}"
    exit 1
fi

echo "==> Appliance ISO built: ${appliance_iso}"

# ============================================================
# Step 2: Patch the ISO with OpenPERouter content and hack agent
# ============================================================
"${SCRIPTDIR}/patch_appliance.sh" "${appliance_iso}" "${ocp_dir}"
