#!/bin/bash
# generate_config_image.sh - Build the agent config-image ISO.
#
# Compiles MachineConfig manifests from butane sources, then runs
# `openshift-install agent create config-image` to produce the
# config-image ISO that the appliance mounts at first boot.
#
# Usage: generate_config_image.sh [config_image_dir]
#
#   config_image_dir  Working directory for config-image generation
#                     (default: ./configimage)
#
# The ISO is written to <config_image_dir>/agentconfig.noarch.iso
#
# Requires: butane, openshift-install (in PATH)

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

config_image_dir="$(realpath "${1:-${SCRIPTDIR}/configimage}")"

if ! command -v openshift-install &>/dev/null; then
    echo "ERROR: openshift-install not found in PATH"
    exit 1
fi

# ============================================================
# Prepare config-image work directory
# ============================================================
mkdir -p "${config_image_dir}"

# Copy install and agent configs
cp "${SCRIPTDIR}/install-config.yaml" "${config_image_dir}/"
cp "${SCRIPTDIR}/agent-config.yaml" "${config_image_dir}/"

# Remove namespace fields that cause strict diff failures
# in the appliance's load-config-iso.sh
sed -i '/^  namespace:/d' "${config_image_dir}/agent-config.yaml"
sed -i '/^  namespace:/d' "${config_image_dir}/install-config.yaml"

# ============================================================
# Generate MachineConfig manifests from butane sources
# ============================================================
extra_manifests_dir="${config_image_dir}/openshift"

"${SCRIPTDIR}/generate_machineconfigs.sh" "${extra_manifests_dir}"

# ============================================================
# Create the config-image ISO
# ============================================================
echo "==> Creating config-image ISO..."

openshift-install --log-level=debug --dir="${config_image_dir}" agent create config-image

# Copy auth files alongside the ISO for wait-for access
if [[ -d "${config_image_dir}/auth" ]]; then
    echo "  Auth files available at ${config_image_dir}/auth/"
fi

echo "==> Done: ${config_image_dir}/agentconfig.noarch.iso"
