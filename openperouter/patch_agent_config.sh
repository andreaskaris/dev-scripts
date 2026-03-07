#!/usr/bin/env bash
set -euxo pipefail

# Patch agent-config.yaml for SNO with a linux bridge configuration.
#
# This script modifies the agent-config.yaml in ocp/${CLUSTER_NAME} to:
#   - Keep the baremetal NIC with a static IP (192.168.111.80)
#   - Create a standalone linux bridge (br0) with a static IP in the 192.168.110.0/24 network
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

NIC_IP="192.168.111.80"
NIC_PREFIX="24"

BRIDGE_NETWORK="${BRIDGE_IP%.*}.0/${BRIDGE_PREFIX}"

WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
AGENT_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/agent-config.yaml"
INSTALL_CONFIG="${WORKING_DIR}/ocp/${CLUSTER_NAME}/install-config.yaml"

NIC_NAME="enp2s0"

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
echo "  NIC:           ${NIC_NAME}"
echo "  MAC:           ${MAC_ADDRESS}"
echo "  NIC IP:        ${NIC_IP}/${NIC_PREFIX}"
echo "  Bridge IP:     ${BRIDGE_IP}/${BRIDGE_PREFIX}"
echo "  Gateway:       ${BRIDGE_GW} (via ${BRIDGE_NAME})"
echo "  RendezvousIP:  ${BRIDGE_IP}"

# Generate the patched agent-config.yaml
python3 -c "
import yaml, sys

with open('${AGENT_CONFIG}') as f:
    cfg = yaml.safe_load(f)

cfg['rendezvousIP'] = '${BRIDGE_IP}'

# Fix the interface name from the template's hardcoded 'eth0' to the actual NIC name
cfg['hosts'][0]['interfaces'][0]['name'] = '${NIC_NAME}'

cfg['hosts'][0]['networkConfig'] = {
    'interfaces': [
        {
            'name': '${NIC_NAME}',
            'type': 'ethernet',
            'state': 'up',
            'mac-address': '${MAC_ADDRESS}',
            'ipv4': {
                'enabled': True,
                'address': [{'ip': '${NIC_IP}', 'prefix-length': ${NIC_PREFIX}}],
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
                'address': [{'ip': '${BRIDGE_IP}', 'prefix-length': ${BRIDGE_PREFIX}}],
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

# Patch machineNetwork in install-config.yaml to the bridge subnet.
# This makes kubelet pick the bridge IP as the node IP.
# The assisted-service normally filters out virtual interfaces (bridges) from its
# inventory, which would cause the belongs-to-machine-cidr validation to fail.
# To work around this, generate_machineconfig.sh includes a systemd unit that
# sets ENABLE_VIRTUAL_INTERFACES=true in the assisted-service env before it starts.
echo "Patching ${INSTALL_CONFIG}: machineNetwork -> ${BRIDGE_NETWORK}"
python3 -c "
import yaml

with open('${INSTALL_CONFIG}') as f:
    cfg = yaml.safe_load(f)

cfg['networking']['machineNetwork'] = [{'cidr': '${BRIDGE_NETWORK}'}]

with open('${INSTALL_CONFIG}', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
"
echo "Patched ${INSTALL_CONFIG} successfully."
