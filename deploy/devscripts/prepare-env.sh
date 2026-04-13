#!/bin/bash
# prepare-env.sh - Clean, configure, and prepare the dev-scripts
# environment for an agent-based deployment with OpenPERouter.
#
# Must be run from the root of the dev-scripts repository.
#
# Usage: ./deploy/devscripts/prepare-env.sh

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$(cd "${SCRIPTDIR}/../.." && pwd)"

cd "${ROOTDIR}"

export WORKING_DIR="${ROOTDIR}"
export CLUSTER_NAME="${CLUSTER_NAME:-sno-lab}"

# ============================================================
# Step 1: Clean previous environment
# ============================================================
"${SCRIPTDIR}/clean.sh"

# ============================================================
# Step 2: Configure host and prepare agent release
# ============================================================
echo "==> Configuring host..."
./02_configure_host.sh

echo "==> Building agent installer..."
agent/03_agent_build_installer.sh

echo "==> Preparing agent release..."
agent/04_agent_prepare_release.sh

echo "==> Configuring agent..."
agent/05_agent_configure.sh

# ============================================================
# Step 3: Patch agent config for OpenPERouter bridge networking
# ============================================================
echo "==> Patching agent config..."
deploy/devscripts/patch_agent_config.sh

# ============================================================
# Step 4: Generate MachineConfig manifests
# ============================================================
MANIFESTS_DIR="${WORKING_DIR}/ocp/${CLUSTER_NAME}/openshift"

if [[ -n "${USE_RAW:-}" ]]; then
    CONFIG_IMAGE_DIR="config-image-raw"
else
    CONFIG_IMAGE_DIR="config-image-openpe"
fi

echo "==> Generating MachineConfig manifests into ${MANIFESTS_DIR} (mode: ${CONFIG_IMAGE_DIR})..."
./deploy/${CONFIG_IMAGE_DIR}/generate_machineconfigs.sh "${MANIFESTS_DIR}"

# ============================================================
# Step 5: Start external FRR for EVPN peering
# ============================================================
echo "==> Starting external FRR..."
"${SCRIPTDIR}/externalfrr/run_frr.sh"

# ============================================================
# Step 6: Create cluster
# ============================================================
echo "==> Creating cluster..."
agent/06_agent_create_cluster.sh

echo "==> Done."
