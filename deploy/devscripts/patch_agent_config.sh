#!/usr/bin/env bash
set -euxo pipefail

# Patch agent-config.yaml for a cluster with linux bridge configuration.
#
# This script modifies the agent-config.yaml in ocp/${CLUSTER_NAME} to:
#   - Keep each node's baremetal NIC with its existing static IP
#   - Create a standalone linux bridge (br0) on each node with a unique
#     static IP in the 192.168.110.0/24 network
#   - Use the first node's bridge IP as the rendezvousIP
#   - Set the default gateway to 192.168.110.1 via the bridge
#
# For multinode clusters, bridge IPs are assigned sequentially starting
# from the given base IP (e.g., .2, .3, .4 for a 3-node compact cluster).
#
# Usage:
#   ./patch_agent_config.sh [first_bridge_ip]
#
# If first_bridge_ip is not specified, defaults to 192.168.110.2

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

FIRST_BRIDGE_IP="${1:-192.168.110.2}"
BRIDGE_PREFIX="24"
BRIDGE_GW="192.168.110.1"
BRIDGE_NAME="br0"

BRIDGE_V6_SUBNET="fd00:110::/64"
BRIDGE_V6_BASE="fd00:110::"
BRIDGE_V6_PREFIX="64"
BRIDGE_V6_GW="fd00:110::1"

NIC_PREFIX="24"

WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
AGENT_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/agent-config.yaml"
INSTALL_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/install-config.yaml"

NIC_NAME="enp2s0"
PROV_NIC_NAME="enp1s0"
EXTRA_NIC_NAME="enp3s0"

# Extra NIC subnet (from EXTERNAL_NETWORK_SUBNET_V4 in config)
EXTRA_NIC_SUBNET="${EXTERNAL_NETWORK_SUBNET_V4:-192.168.150.0/24}"
EXTRA_NIC_BASE="${EXTRA_NIC_SUBNET%.*}"
EXTRA_NIC_PREFIX="${EXTRA_NIC_SUBNET#*/}"
EXTRA_NIC_START_OCTET="20"

# DNS server: the host's baremetal IP where dnsmasq runs with cluster records
DNS_SERVER="${DNS_SERVER:-192.168.111.1}"

# NTP server reachable during agent discovery phase (host's baremetal IP)
NTP_SERVER="${NTP_SERVER:-10.100.0.1}"

if [ ! -f "${AGENT_CONFIG}" ]; then
  echo "ERROR: ${AGENT_CONFIG} not found. Run agent/05_agent_configure.sh first."
  exit 1
fi

# Compute the bridge network from the first bridge IP
BRIDGE_NETWORK="${FIRST_BRIDGE_IP%.*}.0/${BRIDGE_PREFIX}"
BRIDGE_V6_NETWORK="${BRIDGE_V6_SUBNET}"

# Extract the last octet of the first bridge IP as the starting offset
FIRST_OCTET="${FIRST_BRIDGE_IP##*.}"

# Extract per-host info (MAC, NIC IP) and patch all hosts
python3 -c "
import yaml, sys

with open('${AGENT_CONFIG}') as f:
    cfg = yaml.safe_load(f)

num_hosts = len(cfg.get('hosts', []))
if num_hosts == 0:
    print('ERROR: No hosts found in ${AGENT_CONFIG}', file=sys.stderr)
    sys.exit(1)

bridge_base = '${FIRST_BRIDGE_IP%.*}'
bridge_start_octet = ${FIRST_OCTET}
bridge_v6_base = '${BRIDGE_V6_BASE}'

extra_nic_base = '${EXTRA_NIC_BASE}'
extra_nic_start_octet = ${EXTRA_NIC_START_OCTET}

cfg['additionalNTPSources'] = ['${NTP_SERVER}']

for i, host in enumerate(cfg['hosts']):
    bridge_ip = f'{bridge_base}.{bridge_start_octet + i}'
    bridge_ip_v6 = f'{bridge_v6_base}{bridge_start_octet + i}'
    extra_nic_ip = f'{extra_nic_base}.{extra_nic_start_octet + i}'

    # Set rendezvousIP to the first node's bridge IP
    if i == 0:
        cfg['rendezvousIP'] = bridge_ip

    # Extract the existing MAC address
    mac = host['interfaces'][0]['macAddress']

    # Fix NIC name
    host['interfaces'][0]['name'] = '${NIC_NAME}'

    # Extract existing NIC IPs from the networkConfig (set by 05_agent_configure.sh)
    nic_ip = None
    nic_ip_v6 = None
    nic_prefix_v6 = 120
    if 'networkConfig' in host:
        for iface in host['networkConfig'].get('interfaces', []):
            if iface.get('type') == 'ethernet' and iface.get('ipv4', {}).get('address'):
                nic_ip = iface['ipv4']['address'][0]['ip']
                v6_addrs = iface.get('ipv6', {}).get('address', [])
                if v6_addrs:
                    nic_ip_v6 = v6_addrs[0]['ip']
                    nic_prefix_v6 = v6_addrs[0].get('prefix-length', 120)
                break
    if nic_ip is None:
        print(f'ERROR: Could not extract NIC IP for host {i}', file=sys.stderr)
        sys.exit(1)

    print(f'  Host {i}: MAC={mac}  NIC_IP={nic_ip}  NIC_IPv6={nic_ip_v6}  Bridge_IP={bridge_ip}  Bridge_IPv6={bridge_ip_v6}  Extra_NIC_IP={extra_nic_ip}')

    nic_entry = {
        'name': '${NIC_NAME}',
        'type': 'ethernet',
        'state': 'up',
        'mac-address': mac,
        'ipv4': {
            'enabled': True,
            'address': [{'ip': nic_ip, 'prefix-length': ${NIC_PREFIX}}],
            'dhcp': False,
        },
    }
    if nic_ip_v6:
        nic_entry['ipv6'] = {
            'enabled': True,
            'address': [{'ip': nic_ip_v6, 'prefix-length': nic_prefix_v6}],
            'dhcp': False,
        }

    host['networkConfig'] = {
        'interfaces': [
            nic_entry,
            {
                'name': '${PROV_NIC_NAME}',
                'type': 'ethernet',
                'state': 'up',
                'ipv4': {'enabled': False},
                'ipv6': {'enabled': False},
            },
            {
                'name': '${EXTRA_NIC_NAME}',
                'type': 'ethernet',
                'state': 'up',
                'ipv4': {
                    'enabled': True,
                    'address': [{'ip': extra_nic_ip, 'prefix-length': ${EXTRA_NIC_PREFIX}}],
                    'dhcp': False,
                },
                'ipv6': {'enabled': False},
            },
            {
                'name': 'dummy0',
                'type': 'dummy',
                'state': 'up',
                'ipv4': {'enabled': False},
                'ipv6': {'enabled': False},
            },
            {
                'name': '${BRIDGE_NAME}',
                'type': 'linux-bridge',
                'state': 'up',
                'ipv4': {
                    'enabled': True,
                    'address': [{'ip': bridge_ip, 'prefix-length': ${BRIDGE_PREFIX}}],
                    'dhcp': False,
                },
                'ipv6': {
                    'enabled': True,
                    'address': [{'ip': bridge_ip_v6, 'prefix-length': ${BRIDGE_V6_PREFIX}}],
                    'dhcp': False,
                },
                'bridge': {
                    'port': [{'name': 'dummy0'}],
                },
            },
        ],
        'dns-resolver': {
            'config': {
                'server': ['${BRIDGE_GW}', '${BRIDGE_V6_GW}'],
            },
        },
        'routes': {
            'config': [
                {
                    'destination': '0.0.0.0/0',
                    'next-hop-address': '${BRIDGE_GW}',
                    'next-hop-interface': '${BRIDGE_NAME}',
                    'table-id': 254,
                },
                {
                    'destination': '::/0',
                    'next-hop-address': '${BRIDGE_V6_GW}',
                    'next-hop-interface': '${BRIDGE_NAME}',
                    'table-id': 254,
                },
            ],
        },
    }

with open('${AGENT_CONFIG}', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
"

echo "Patched ${AGENT_CONFIG} successfully."

# Patch machineNetwork and VIPs in install-config.yaml to the bridge subnet.
# This makes kubelet pick the bridge IP as the node IP.
# VIPs must also be in the machine network for validation to pass.
BRIDGE_SUBNET="${FIRST_BRIDGE_IP%.*}"
API_VIP="${API_VIP:-${BRIDGE_SUBNET}.10}"
INGRESS_VIP="${INGRESS_VIP:-${BRIDGE_SUBNET}.11}"
API_VIP_V6="${API_VIP_V6:-${BRIDGE_V6_BASE}10}"
INGRESS_VIP_V6="${INGRESS_VIP_V6:-${BRIDGE_V6_BASE}11}"

echo "Patching ${INSTALL_CONFIG}:"
echo "  machineNetwork -> ${BRIDGE_NETWORK}, ${BRIDGE_V6_NETWORK}"
echo "  apiVIPs        -> ${API_VIP}, ${API_VIP_V6}"
echo "  ingressVIPs    -> ${INGRESS_VIP}, ${INGRESS_VIP_V6}"
python3 -c "
import yaml

with open('${INSTALL_CONFIG}') as f:
    cfg = yaml.safe_load(f)

cfg['networking']['machineNetwork'] = [{'cidr': '${BRIDGE_NETWORK}'}, {'cidr': '${BRIDGE_V6_NETWORK}'}]

# For multinode clusters, VIPs must be in the machine network
if 'platform' in cfg and 'baremetal' in cfg['platform']:
    bm = cfg['platform']['baremetal']
    if 'apiVIPs' in bm:
        bm['apiVIPs'] = ['${API_VIP}', '${API_VIP_V6}']
    if 'ingressVIPs' in bm:
        bm['ingressVIPs'] = ['${INGRESS_VIP}', '${INGRESS_VIP_V6}']

with open('${INSTALL_CONFIG}', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
"
echo "Patched ${INSTALL_CONFIG} successfully."

# Update host dnsmasq to resolve api/apps to the bridge VIPs
CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN:-example.com}"
DNSMASQ_CONF="/etc/NetworkManager/dnsmasq.d/openshift-${CLUSTER_NAME}.conf"
echo "Updating dnsmasq: ${DNSMASQ_CONF}"
echo "  api.${CLUSTER_DOMAIN}  -> ${API_VIP}"
echo "  *.apps.${CLUSTER_DOMAIN} -> ${INGRESS_VIP}"
sudo tee "${DNSMASQ_CONF}" > /dev/null <<EOF
address=/api.${CLUSTER_DOMAIN}/${API_VIP}
address=/.apps.${CLUSTER_DOMAIN}/${INGRESS_VIP}
listen-address=::1
cache-size=0
EOF
sudo systemctl reload NetworkManager
echo "Reloaded NetworkManager dnsmasq."
