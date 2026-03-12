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

NIC_PREFIX="24"

WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
AGENT_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/agent-config.yaml"
INSTALL_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/install-config.yaml"

NIC_NAME="enp2s0"

# NTP server reachable during agent discovery phase (host's baremetal IP)
NTP_SERVER="${NTP_SERVER:-192.168.111.1}"

if [ ! -f "${AGENT_CONFIG}" ]; then
  echo "ERROR: ${AGENT_CONFIG} not found. Run agent/05_agent_configure.sh first."
  exit 1
fi

# Compute the bridge network from the first bridge IP
BRIDGE_NETWORK="${FIRST_BRIDGE_IP%.*}.0/${BRIDGE_PREFIX}"

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

cfg['additionalNTPSources'] = ['${NTP_SERVER}']

for i, host in enumerate(cfg['hosts']):
    bridge_ip = f'{bridge_base}.{bridge_start_octet + i}'

    # Set rendezvousIP to the first node's bridge IP
    if i == 0:
        cfg['rendezvousIP'] = bridge_ip

    # Extract the existing MAC address
    mac = host['interfaces'][0]['macAddress']

    # Fix NIC name
    host['interfaces'][0]['name'] = '${NIC_NAME}'

    # Extract existing NIC IP from the networkConfig (set by 05_agent_configure.sh)
    nic_ip = None
    if 'networkConfig' in host:
        for iface in host['networkConfig'].get('interfaces', []):
            if iface.get('type') == 'ethernet' and iface.get('ipv4', {}).get('address'):
                nic_ip = iface['ipv4']['address'][0]['ip']
                break
    if nic_ip is None:
        print(f'ERROR: Could not extract NIC IP for host {i}', file=sys.stderr)
        sys.exit(1)

    print(f'  Host {i}: MAC={mac}  NIC_IP={nic_ip}  Bridge_IP={bridge_ip}')

    host['networkConfig'] = {
        'interfaces': [
            {
                'name': '${NIC_NAME}',
                'type': 'ethernet',
                'state': 'up',
                'mac-address': mac,
                'ipv4': {
                    'enabled': True,
                    'address': [{'ip': nic_ip, 'prefix-length': ${NIC_PREFIX}}],
                    'dhcp': False,
                },
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
                'bridge': {
                    'port': [{'name': 'dummy0'}],
                },
            },
        ],
        'dns-resolver': {
            'config': {
                'server': ['${BRIDGE_GW}'],
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

echo "Patching ${INSTALL_CONFIG}:"
echo "  machineNetwork -> ${BRIDGE_NETWORK}"
echo "  apiVIPs        -> ${API_VIP}"
echo "  ingressVIPs    -> ${INGRESS_VIP}"
python3 -c "
import yaml

with open('${INSTALL_CONFIG}') as f:
    cfg = yaml.safe_load(f)

cfg['networking']['machineNetwork'] = [{'cidr': '${BRIDGE_NETWORK}'}]

# For multinode clusters, VIPs must be in the machine network
if 'platform' in cfg and 'baremetal' in cfg['platform']:
    bm = cfg['platform']['baremetal']
    if 'apiVIPs' in bm:
        bm['apiVIPs'] = ['${API_VIP}']
    if 'ingressVIPs' in bm:
        bm['ingressVIPs'] = ['${INGRESS_VIP}']

with open('${INSTALL_CONFIG}', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
"
echo "Patched ${INSTALL_CONFIG} successfully."
