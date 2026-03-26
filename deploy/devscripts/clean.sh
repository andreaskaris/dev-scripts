#!/bin/bash
# clean.sh - Clean previous dev-scripts environment, ignoring errors.
#
# Usage: ./deploy/devscripts/clean.sh

set -uo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$(cd "${SCRIPTDIR}/../.." && pwd)"

cd "${ROOTDIR}"

echo "==> Cleaning previous environment..."
make clean || true
./host_cleanup.sh || true
