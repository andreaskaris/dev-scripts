#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# butane sources (openperouter-raw, dns, registry).
#
# Usage: generate_machineconfigs.sh <output_dir>
#
#   output_dir  Directory where the MachineConfig YAML files are written
#
# Requires: butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

output_dir="$1"
mkdir -p "${output_dir}"

if ! command -v butane &>/dev/null; then
    echo "ERROR: butane is required but not found. Install with: sudo dnf install butane"
    exit 1
fi

echo "==> Generating MachineConfig manifests into ${output_dir}..."

if [[ -f "${SCRIPTDIR}/openperouter-raw.bu" ]]; then
    echo "  openperouter-raw.bu -> 99-master-openperouter.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/openperouter-raw.bu" \
        -o "${output_dir}/99-master-openperouter.yaml"
fi

if [[ -f "${SCRIPTDIR}/registry.bu" ]]; then
    echo "  registry.bu -> 01-master-registry.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/registry.bu" \
        -o "${output_dir}/01-master-registry.yaml"
fi

echo "==> MachineConfig manifests generated."
