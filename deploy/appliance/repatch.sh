#!/bin/bash
# repatch.sh - Fast-patch: restore the base ISO then apply OpenPERouter + hackagent.
# Use this instead of generate_appliance.sh when iterating on hackagent or
# openperouter configs — skips the slow appliance build (~3 min).
#
# Usage: ./repatch.sh
# The SSH key must be embedded in the base ISO via get_fresh_iso.sh's ssh_key_file arg.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${SCRIPTDIR}/appliance.iso.base"
ISO="${SCRIPTDIR}/appliance.iso"

if [[ ! -f "${BASE}" ]]; then
    echo "ERROR: No base ISO found at ${BASE}"
    echo "       Run get_fresh_iso.sh first to build it."
    exit 1
fi

echo "==> Restoring base ISO..."
sudo cp "${BASE}" "${ISO}"
sudo chown "$(id -u):$(id -g)" "${ISO}"

echo "==> Patching with OpenPERouter + hackagent..."
"${SCRIPTDIR}/patch_appliance.sh" "${ISO}" "${SCRIPTDIR}"
