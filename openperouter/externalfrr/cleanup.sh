#!/usr/bin/env bash
set -euo pipefail

# Clean up the external FRR container, VXLAN, bridge, and VTEP address.
#
# Usage:
#   ./cleanup.sh

CONTAINER_NAME="externalfrr"
VNI=100
VXLAN_IF="vni${VNI}"
BRIDGE_IF="br${VNI}"
VTEP_LO="lo-vtep"
LO_NAME="lo-extra"

echo "Cleaning up external FRR..."

# Stop and remove FRR container
if sudo podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Stopping container '${CONTAINER_NAME}'..."
    sudo podman rm -f "${CONTAINER_NAME}"
else
    echo "  Container '${CONTAINER_NAME}' not found, skipping"
fi

# Remove extra loopback
if ip link show "${LO_NAME}" &>/dev/null; then
    echo "  Removing loopback ${LO_NAME}..."
    sudo ip link set "${LO_NAME}" down
    sudo ip link del "${LO_NAME}"
else
    echo "  Loopback ${LO_NAME} not found, skipping"
fi

# Remove VXLAN from bridge
if ip link show "${VXLAN_IF}" &>/dev/null; then
    sudo ip link set "${VXLAN_IF}" nomaster 2>/dev/null || true
fi

# Remove bridge
if ip link show "${BRIDGE_IF}" &>/dev/null; then
    echo "  Removing bridge ${BRIDGE_IF}..."
    sudo ip link set "${BRIDGE_IF}" down
    sudo ip link del "${BRIDGE_IF}"
else
    echo "  Bridge ${BRIDGE_IF} not found, skipping"
fi

# Remove VXLAN interface
if ip link show "${VXLAN_IF}" &>/dev/null; then
    echo "  Removing VXLAN ${VXLAN_IF}..."
    sudo ip link set "${VXLAN_IF}" down
    sudo ip link del "${VXLAN_IF}"
else
    echo "  VXLAN ${VXLAN_IF} not found, skipping"
fi

# Remove VTEP loopback interface
if ip link show "${VTEP_LO}" &>/dev/null; then
    echo "  Removing VTEP loopback ${VTEP_LO}..."
    sudo ip link set "${VTEP_LO}" down
    sudo ip link del "${VTEP_LO}"
else
    echo "  VTEP loopback ${VTEP_LO} not found, skipping"
fi

echo "Done."
