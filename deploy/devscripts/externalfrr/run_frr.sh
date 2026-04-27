#!/usr/bin/env bash
set -euo pipefail

# Run an external FRR instance as a remotepe with ISIS + SRv6 + iBGP.
# Peers with master-0 (the EVPN/VPN route reflector) for L3VPN via SRv6.
# No L2 EVPN / VXLAN — this node does L3VPN only.
#
# Creates:
#   - Loopback addresses (Router ID, IPv6, SRv6 source)
#   - VRF "red" with a dummy loopback (lored)
#   - SRv6 sysctls
#   - FRR container with ISIS + BGP + SRv6 config
#   - DNS server in VRF for cluster access
#
# Usage:
#   ./run_frr.sh

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
ISIS_IFACE="${ISIS_IFACE:-sno-labbm}"

BGP_AS="${BGP_AS:-65500}"
RR_LOOPBACK="${RR_LOOPBACK:-fc00:0:2::1}"

# Addressing — fixed IPs for external FRR remotepe
ROUTER_ID="${ROUTER_ID:-10.0.0.20}"
LOOPBACK_V6="${LOOPBACK_V6:-fc00:0:20::1}"
SRV6_SOURCE="${SRV6_SOURCE:-fd00:20::1}"
SRV6_PREFIX="${SRV6_PREFIX:-fd00:20::/48}"
UNDERLAY_V6="${UNDERLAY_V6:-fc00:100::20}"
ISIS_NET="${ISIS_NET:-49.0001.0000.0000.0020.00}"
VRF_LO_V4="${VRF_LO_V4:-10.10.20.1/32}"
VRF_LO_V6="${VRF_LO_V6:-fc00:10:20::1/128}"

VRF_NAME="red"
VRF_TABLE=1100

VTEP_LO="lo-vtep"
LO_NAME="lo-extra"
LO_IP="${LO_IP:-10.100.0.1/32}"
DNS_LISTEN_IP="${DNS_LISTEN_IP:-10.100.0.1}"
CLUSTER_NAME="${CLUSTER_NAME:-sno-lab}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
API_VIP="${API_VIP:-192.168.110.10}"
INGRESS_VIP="${INGRESS_VIP:-192.168.110.11}"
CONTAINER_NAME="externalfrr"
FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.1}"
FRR_CONF_DIR="${SCRIPTDIR}/config"

echo "============================================="
echo "External FRR — RemotePE (ISIS + SRv6)"
echo "============================================="
echo "  ISIS iface:     ${ISIS_IFACE}"
echo "  Router ID:      ${ROUTER_ID}"
echo "  Loopback IPv6:  ${LOOPBACK_V6}"
echo "  SRv6 source:    ${SRV6_SOURCE}"
echo "  SRv6 prefix:    ${SRV6_PREFIX}"
echo "  ISIS NET:       ${ISIS_NET}"
echo "  BGP AS:         ${BGP_AS}"
echo "  RR loopback:    ${RR_LOOPBACK}"
echo "  VRF:            ${VRF_NAME} (table ${VRF_TABLE})"
echo "  FRR image:      ${FRR_IMAGE}"
echo ""

# --- Loopback interface for Router ID + IPv6 ---
echo "Creating loopback ${VTEP_LO}..."
if ip link show "${VTEP_LO}" &>/dev/null; then
    echo "  ${VTEP_LO} already exists, skipping"
else
    sudo ip link add "${VTEP_LO}" type dummy
    sudo ip link set "${VTEP_LO}" up
fi
sudo ip addr add "${ROUTER_ID}/32" dev "${VTEP_LO}" 2>/dev/null || true
sudo ip -6 addr add "${LOOPBACK_V6}/128" dev "${VTEP_LO}" 2>/dev/null || true
sudo ip -6 addr add "${SRV6_SOURCE}/128" dev "${VTEP_LO}" 2>/dev/null || true

# --- Underlay IPv6 on ISIS interface ---
echo "Adding underlay IPv6 ${UNDERLAY_V6}/64 to ${ISIS_IFACE}..."
sudo ip -6 addr add "${UNDERLAY_V6}/64" dev "${ISIS_IFACE}" 2>/dev/null || true

# --- SRv6 sysctls ---
echo "Setting SRv6 sysctls..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sudo sysctl -w net.ipv6.seg6_flowlabel=1 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv6.conf.all.seg6_enabled=1 >/dev/null 2>&1 || true
sudo sysctl -w net.ipv6.conf.default.seg6_enabled=1 >/dev/null 2>&1 || true
sudo sysctl -w "net.ipv6.conf.${ISIS_IFACE}.seg6_enabled=1" >/dev/null 2>&1 || true
sudo sysctl -w net.ipv6.conf.lo.seg6_enabled=1 >/dev/null 2>&1 || true

# --- VRF ---
echo "Creating VRF ${VRF_NAME} (table ${VRF_TABLE})..."
if ip link show "${VRF_NAME}" &>/dev/null; then
    echo "  ${VRF_NAME} already exists, skipping"
else
    sudo ip link add "${VRF_NAME}" type vrf table "${VRF_TABLE}"
    sudo ip link set "${VRF_NAME}" up
    sudo firewall-cmd --zone=trusted --add-interface="${VRF_NAME}" 2>/dev/null || true
fi

# --- VRF loopback (lored) ---
echo "Creating VRF loopback 'lored'..."
if ip link show "lored" &>/dev/null; then
    echo "  lored already exists, skipping"
else
    sudo ip link add lored type dummy
    sudo ip link set lored master "${VRF_NAME}"
    sudo ip link set lored up
fi
sudo ip addr add "${VRF_LO_V4}" dev lored 2>/dev/null || true
sudo ip -6 addr add "${VRF_LO_V6}" dev lored 2>/dev/null || true

# --- Extra loopback for DNS ---
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
debug bgp zebra
debug bgp updates
debug bgp neighbor-events
!
interface ${ISIS_IFACE}
 ip router isis PE
 ipv6 router isis PE
exit
!
interface lo
 ip router isis PE
 ipv6 router isis PE
exit
!
router bgp ${BGP_AS}
 bgp router-id ${ROUTER_ID}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 no bgp network import-check
 bgp log-neighbor-changes
 !
 neighbor RR peer-group
 neighbor RR remote-as ${BGP_AS}
 neighbor RR update-source ${LOOPBACK_V6}
 neighbor ${RR_LOOPBACK} peer-group RR
 !
 segment-routing srv6
  locator MAIN
 exit
 !
 address-family ipv4 vpn
  neighbor RR activate
 exit-address-family
 !
 address-family ipv6 vpn
  neighbor RR activate
 exit-address-family
exit
!
router bgp ${BGP_AS} vrf ${VRF_NAME}
 bgp router-id ${ROUTER_ID}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 no bgp network import-check
 sid vpn per-vrf export auto
 !
 address-family ipv4 unicast
  network ${VRF_LO_V4}
  rd vpn export ${ROUTER_ID}:2
  rt vpn both ${BGP_AS}:2
  export vpn
  import vpn
 exit-address-family
 !
 address-family ipv6 unicast
  network ${VRF_LO_V6}
  rd vpn export ${ROUTER_ID}:2
  rt vpn both ${BGP_AS}:2
  export vpn
  import vpn
 exit-address-family
exit
!
router isis PE
 is-type level-1
 net ${ISIS_NET}
 topology ipv6-unicast
 lsp-gen-interval 2
 log-adjacency-changes
 log-pdu-drops
 segment-routing on
 segment-routing srv6
  locator MAIN
 exit
exit
!
segment-routing
 srv6
  encapsulation
   source-address ${SRV6_SOURCE}
  exit
  locators
   locator MAIN
    prefix ${SRV6_PREFIX} block-len 32 node-len 16 func-bits 16
    behavior usid
   exit
  exit
 exit
exit
!
end
EOF

cat > "${FRR_CONF_DIR}/daemons" <<EOF
zebra=yes
bgpd=yes
isisd=yes
staticd=yes
bfdd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
fabricd=no
vrrpd=no
pathd=no
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

# --- DNS server in VRF red ---
DNS_PID_FILE="/run/dnsmasq-vrf-${VRF_NAME}.pid"
DNS_CONF="${FRR_CONF_DIR}/dnsmasq.conf"

if [ -n "${API_VIP}" ] && [ -n "${INGRESS_VIP}" ]; then
    echo "Setting up DNS server in VRF ${VRF_NAME} on ${LO_NAME} (${DNS_LISTEN_IP})..."

    for pid in $(pgrep -f "dnsmasq.*${DNS_LISTEN_IP}" 2>/dev/null); do
        echo "  Killing existing dnsmasq (PID ${pid})..."
        sudo kill "${pid}" 2>/dev/null || true
    done
    sudo rm -f "${DNS_PID_FILE}"
    sleep 1

    cat > "${DNS_CONF}" <<DNSEOF
address=/api.${CLUSTER_DOMAIN}/${API_VIP}
address=/api-int.${CLUSTER_DOMAIN}/${API_VIP}
address=/.apps.${CLUSTER_DOMAIN}/${INGRESS_VIP}
DNSEOF

    echo "  DNS config: api.${CLUSTER_DOMAIN} -> ${API_VIP}"
    echo "  DNS config: *.apps.${CLUSTER_DOMAIN} -> ${INGRESS_VIP}"

    sudo ip vrf exec "${VRF_NAME}" dnsmasq \
        --pid-file="${DNS_PID_FILE}" \
        --conf-file="${DNS_CONF}" \
        --no-dhcp-interface="${LO_NAME}" \
        --listen-address="${DNS_LISTEN_IP}" \
        --bind-interfaces \
        --no-resolv \
        --no-hosts

    echo "DNS server running at ${DNS_LISTEN_IP} in VRF ${VRF_NAME}."
else
    echo "Skipping DNS server (set API_VIP and INGRESS_VIP to enable)."
fi

echo ""
echo "FRR is running. Useful commands:"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show isis neighbor'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show bgp summary'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show bgp ipv4 vpn'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh -c 'show segment-routing srv6 locator'"
echo "  sudo podman exec -it ${CONTAINER_NAME} vtysh"
echo ""
echo "L3VPN test (from VRF — ping master-0 br0):"
echo "  sudo ip vrf exec ${VRF_NAME} ping 192.168.110.2"
echo ""
