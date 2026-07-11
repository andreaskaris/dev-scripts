#!/bin/bash
# get_fresh_iso.sh - Build the base appliance live ISO (slow, ~3 min).
# Only needed when the OCP version, pull secret, or base appliance config changes.
# Saves the unpatched result as appliance.iso.base for use by repatch.sh.
#
# Usage: get_fresh_iso.sh <pull_secret_file> [ssh_key_file]

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIANCE_IMAGE="${APPLIANCE_IMAGE:-quay.io/edge-infrastructure/openshift-appliance:latest}"

pull_secret_file="${1:?Usage: $0 <pull_secret_file> [ssh_key_file]}"
ssh_key_file="${2:-}"

if [[ ! -f "${pull_secret_file}" ]]; then
    echo "ERROR: Pull secret file not found: ${pull_secret_file}"
    exit 1
fi

if [[ -n "${ssh_key_file}" && ! -f "${ssh_key_file}" ]]; then
    echo "ERROR: SSH key file not found: ${ssh_key_file}"
    exit 1
fi

# ============================================================
# Step 1: Generate appliance-config.yaml from base template
# ============================================================
echo "==> Generating appliance-config.yaml..."

base_config="${SCRIPTDIR}/appliance-config.yaml.base"
config="${SCRIPTDIR}/appliance-config.yaml"

if [[ ! -f "${base_config}" ]]; then
    echo "ERROR: Base config not found: ${base_config}"
    exit 1
fi

pull_secret="$(jq -c . "${pull_secret_file}")"
yq -y ".pullSecret = $(echo "${pull_secret}" | jq -R .)" "${base_config}" > "${config}"

if [[ -n "${ssh_key_file}" ]]; then
    ssh_key="$(cat "${ssh_key_file}")"
    yq -y ".sshKey = \"${ssh_key}\"" "${config}" > "${config}.tmp" && mv "${config}.tmp" "${config}"
fi

# ============================================================
# Step 2: Build the appliance live ISO
# ============================================================
echo "==> Building appliance live ISO (this takes ~3 minutes)..."

asset_dir="${SCRIPTDIR}"

sudo podman run -it --rm --privileged --net=host \
    -v "${asset_dir}:/assets:Z" \
    "${APPLIANCE_IMAGE}" clean

sudo podman run -it --rm --pull newer --privileged --net=host \
    -v "${asset_dir}:/assets:Z" \
    "${APPLIANCE_IMAGE}" build live-iso --log-level=debug

if [[ ! -f "${asset_dir}/appliance.iso" ]]; then
    echo "ERROR: Appliance ISO not found after build"
    exit 1
fi

# ============================================================
# Save as base (unpatched)
# ============================================================
cp "${asset_dir}/appliance.iso" "${asset_dir}/appliance.iso.base"
echo "==> Base ISO saved: ${asset_dir}/appliance.iso.base"
echo "==> Run repatch.sh to apply OpenPERouter + hackagent on top."
