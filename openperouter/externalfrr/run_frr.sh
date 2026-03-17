#!/usr/bin/env bash
set -euo pipefail

# Run an external FRR instance with podman (host-networked) configured for
# BGP EVPN, peering with the openperouter node over the extra network.
#
# This creates:
#   - A VTEP loopback address (100.64.0.1/32)
#   - A VXLAN interface (vni100) with VNI 100, neighbor suppression enabled
#   - A VRF "red" (table 10)
#   - A linux bridge (br100) with vni100 as a port (VRF red)
#   - A dummy loopback (advertised via redistribute connected)
#   - An FRR container peering BGP EVPN with the node
#
# Usage:
#   ./run_frr.sh [node_ip ...]
#
# node_ip: one or more node IPs on the extra network (default: 192.168.111.80)

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
if [[ $# -gt 0 ]]; then
    NODE_IPS=("$@")
else
    NODE_IPS=("192.168.111.80" "192.168.111.81" "192.168.111.82")
fi
LOCAL_IP="${LOCAL_IP:-192.168.150.1}"
LOCAL_ASN="${LOCAL_ASN:-64512}"
REMOTE_ASN="${REMOTE_ASN:-64514}"
VNI=100
VRF_NAME="red"
VRF_TABLE=10
VTEP_IP="${VTEP_IP:-100.64.0.1}"
VXLAN_IF="vni${VNI}"
BRIDGE_IF="br${VNI}"
VXLAN_PORT=4789
VTEP_LO="lo-vtep"
LO_NAME="lo-extra"
LO_IP="${LO_IP:-10.100.0.1/32}"
CONTAINER_NAME="externalfrr"
FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.1}"
FRR_CONF_DIR="${SCRIPTDIR}/config"

echo "============================================="
echo "External FRR for EVPN peering"
echo "============================================="
echo "  Local IP:       ${LOCAL_IP}"
echo "  VTEP IP:        ${VTEP_IP}/32"
echo "  Node IPs:       ${NODE_IPS[*]}"
echo "  Local ASN:      ${LOCAL_ASN}"
echo "  Remote ASN:     ${REMOTE_ASN}"
echo "  VNI:            ${VNI}"
echo "  VRF:            ${VRF_NAME} (table ${VRF_TABLE})"
echo "  VXLAN iface:    ${VXLAN_IF}"
echo "  Bridge:         ${BRIDGE_IF}"
echo "  Loopback:       ${LO_NAME} (${LO_IP})"
echo "  FRR image:      ${FRR_IMAGE}"
echo ""

# --- VTEP loopback interface ---
echo "Creating loopback ${VTEP_LO} with ${VTEP_IP}/32..."
if ip link show "${VTEP_LO}" &>/dev/null; then
    echo "  ${VTEP_LO} already exists, skipping"
else
    sudo ip link add "${VTEP_LO}" type dummy
    sudo ip addr add "${VTEP_IP}/32" dev "${VTEP_LO}"
    sudo ip link set "${VTEP_LO}" up
fi

# --- VRF ---
echo "Creating VRF ${VRF_NAME} (table ${VRF_TABLE})..."
if ip link show "${VRF_NAME}" &>/dev/null; then
    echo "  ${VRF_NAME} already exists, skipping"
else
    sudo ip link add "${VRF_NAME}" type vrf table "${VRF_TABLE}"
    sudo ip link set "${VRF_NAME}" up
fi

# --- VXLAN interface ---
echo "Creating VXLAN interface ${VXLAN_IF} (VNI ${VNI})..."
if ip link show "${VXLAN_IF}" &>/dev/null; then
    echo "  ${VXLAN_IF} already exists, skipping"
else
    sudo ip link add "${VXLAN_IF}" type vxlan \
        id "${VNI}" \
        local "${VTEP_IP}" \
        dstport "${VXLAN_PORT}" \
        nolearning
    sudo ip link set "${VXLAN_IF}" addrgenmode none
    sudo ip link set "${VXLAN_IF}" up
fi

# --- Bridge ---
echo "Creating bridge ${BRIDGE_IF}..."
if ip link show "${BRIDGE_IF}" &>/dev/null; then
    echo "  ${BRIDGE_IF} already exists, skipping"
else
    sudo ip link add "${BRIDGE_IF}" type bridge
    sudo ip link set "${BRIDGE_IF}" master "${VRF_NAME}"
    sudo ip link set "${BRIDGE_IF}" up
    sudo ip link set "${VXLAN_IF}" master "${BRIDGE_IF}"
    # Enable neighbor suppression on the VXLAN interface
    sudo bridge link set dev "${VXLAN_IF}" neigh_suppress on
fi

# --- Extra loopback interface ---
echo "Creating loopback ${LO_NAME} with ${LO_IP}..."
if ip link show "${LO_NAME}" &>/dev/null; then
    echo "  ${LO_NAME} already exists, skipping"
else
    sudo ip link add "${LO_NAME}" type dummy
    sudo ip link set "${LO_NAME}" master "${VRF_NAME}"
    sudo ip addr add "${LO_IP}" dev "${LO_NAME}"
    sudo ip link set "${LO_NAME}" up
fi

# --- Generate FRR configuration ---
mkdir -p "${FRR_CONF_DIR}"

cat > "${FRR_CONF_DIR}/frr.conf" <<EOF
log file /etc/frr/frr.log debug

debug zebra events
debug zebra vxlan
debug bgp zebra
debug zebra nht
debug zebra kernel
debug zebra rib
debug zebra nexthop
debug bgp neighbor-events
debug bgp updates
debug bgp keepalives
debug bgp nht
!
vrf ${VRF_NAME}
 vni ${VNI}
exit-vrf
!
router bgp ${LOCAL_ASN}
 bgp router-id ${VTEP_IP}
 no bgp ebgp-requires-policy
 no bgp network import-check
 no bgp default ipv4-unicast
$(for node_ip in "${NODE_IPS[@]}"; do
echo " neighbor ${node_ip} remote-as ${REMOTE_ASN}"
done)
 !
 address-family ipv4 unicast
$(for node_ip in "${NODE_IPS[@]}"; do
echo "  neighbor ${node_ip} activate"
done)
  network ${VTEP_IP}/32
  redistribute connected
 exit-address-family
 !
 address-family ipv6 unicast
  redistribute connected
 exit-address-family
 !
 address-family l2vpn evpn
$(for node_ip in "${NODE_IPS[@]}"; do
echo "  neighbor ${node_ip} activate"
done)
  advertise-all-vni
  advertise-svi-ip
  default-originate ipv4
 exit-address-family
exit
!
router bgp ${LOCAL_ASN} vrf ${VRF_NAME}
 !
 address-family ipv4 unicast
  redistribute connected
 exit-address-family
 !
 address-family ipv6 unicast
  redistribute connected
 exit-address-family
 !
 address-family l2vpn evpn
  advertise ipv4 unicast
  advertise ipv6 unicast
 exit-address-family
exit
!
EOF

cat > "${FRR_CONF_DIR}/daemons" <<EOF
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
zebra=yes
EOF

cat > "${FRR_CONF_DIR}/vtysh.conf" <<EOF
service integrated-vtysh-config
EOF

echo "FRR config written to ${FRR_CONF_DIR}/"

# --- Run FRR container ---
echo "Starting FRR container '${CONTAINER_NAME}'..."
if sudo podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Container already exists, removing..."
    sudo podman rm -f "${CONTAINER_NAME}"
fi

sudo podman run -d \
    --name "${CONTAINER_NAME}" \
    --network=host \
    --privileged \
    -v "${FRR_CONF_DIR}/frr.conf:/etc/frr/frr.conf:Z" \
    -v "${FRR_CONF_DIR}/daemons:/etc/frr/daemons:Z" \
    -v "${FRR_CONF_DIR}/vtysh.conf:/etc/frr/vtysh.conf:Z" \
    "${FRR_IMAGE}"

echo ""
echo "FRR is running. Useful commands:"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show bgp summary'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show bgp l2vpn evpn summary'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show evpn vni'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show evpn mac vni ${VNI}'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh"
echo ""
echo "Bridge ${BRIDGE_IF} is ready (VRF ${VRF_NAME})."
echo "Attach VMs or veths to it for L2 connectivity over VNI ${VNI}."
