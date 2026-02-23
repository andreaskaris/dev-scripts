#!/usr/bin/env bash
set -euxo pipefail

# Single entry point to configure SNO with a linux bridge and deploy
# openperouter quadlets with dynamic nodeIndex.
#
# This script:
#   1. Patches agent-config.yaml with a linux bridge (br0) configuration
#   2. Generates MachineConfig manifests with quadlet files and a systemd
#      unit that derives nodeIndex from the bridge IP's last octet
#
# Run AFTER agent/05_agent_configure.sh and BEFORE agent/06_agent_create_cluster.sh.
#
# Usage:
#   ./setup_sno_bridge.sh [bridge_ip]
#
# If bridge_ip is not specified, defaults to 192.168.110.2

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

BRIDGE_IP="${1:-192.168.110.2}"

# Step 1: Patch agent-config.yaml with bridge network configuration
"${SCRIPTDIR}/patch_agent_config.sh" "${BRIDGE_IP}"

# Step 2: Generate MachineConfig manifests with quadlets and node-index unit
"${SCRIPTDIR}/create_quadlets_mc.sh"
