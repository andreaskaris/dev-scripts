#!/usr/bin/env bash
set -euxo pipefail

# Patch agent-config.yaml for SNO with a linux bridge configuration.
#
# This script modifies the agent-config.yaml in ocp/${CLUSTER_NAME} to:
#   - Create a linux bridge (br0) with a static IP in the 192.168.110.0/24 network
#   - Use the bridge IP as the rendezvousIP
#   - Set the default gateway to 192.168.110.1 via the bridge
#   - Add a systemd unit (openperouter-node-index.service) that extracts the last
#     octet of the bridge IP and writes it as nodeIndex in node_config.yaml,
#     running before the openperouter quadlet pods start
#
# Usage:
#   ./patch_agent_config.sh [bridge_ip]
#
# If bridge_ip is not specified, defaults to 192.168.110.2

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

BRIDGE_IP="${1:-192.168.110.2}"
BRIDGE_PREFIX="24"
BRIDGE_GW="192.168.110.1"
BRIDGE_NAME="br0"

WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
AGENT_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/agent-config.yaml"

if [ ! -f "${AGENT_CONFIG}" ]; then
  echo "ERROR: ${AGENT_CONFIG} not found. Run agent/05_agent_configure.sh first."
  exit 1
fi

# Extract the MAC address from the existing agent-config.yaml
MAC_ADDRESS=$(python3 -c "
import yaml, sys
with open('${AGENT_CONFIG}') as f:
    cfg = yaml.safe_load(f)
print(cfg['hosts'][0]['interfaces'][0]['macAddress'])
")

if [ -z "${MAC_ADDRESS}" ]; then
  echo "ERROR: Could not extract MAC address from ${AGENT_CONFIG}"
  exit 1
fi

echo "Patching ${AGENT_CONFIG}:"
echo "  MAC:           ${MAC_ADDRESS}"
echo "  Bridge IP:     ${BRIDGE_IP}/${BRIDGE_PREFIX}"
echo "  Gateway:       ${BRIDGE_GW}"
echo "  RendezvousIP:  ${BRIDGE_IP}"

# Generate the patched agent-config.yaml
python3 -c "
import yaml, sys

with open('${AGENT_CONFIG}') as f:
    cfg = yaml.safe_load(f)

#cfg['rendezvousIP'] = '${BRIDGE_IP}'

cfg['hosts'][0]['networkConfig'] = {
    'interfaces': [
        {
            'name': '${BRIDGE_NAME}',
            'type': 'linux-bridge',
            'state': 'up',
            'ipv4': {
                'enabled': True,
                'address': [{'ip': '${BRIDGE_IP}', 'prefix-length': ${BRIDGE_PREFIX}}],
                'dhcp': False,
            },
            'bridge': {
                'port': [{'name': 'eth0'}],
            },
        },
        {
            'name': 'eth0',
            'type': 'ethernet',
            'state': 'up',
            'mac-address': '${MAC_ADDRESS}',
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
