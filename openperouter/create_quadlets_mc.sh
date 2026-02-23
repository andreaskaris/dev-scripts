#!/usr/bin/env bash
set -euxo pipefail

# Generate MachineConfig manifests that deploy quadlet files to cluster nodes.
# Run this AFTER agent/05_agent_configure.sh and BEFORE agent/06_agent_create_cluster.sh.
#
# Usage:
#   ./create_quadlets_mc.sh [quadlets_dir] [manifests_dir]
#
# If quadlets_dir is not specified, defaults to ./quadlets
# If manifests_dir is not specified, defaults to EXTRA_MANIFESTS_PATH or
# ${WORKING_DIR}/ocp/${CLUSTER_NAME}/openshift

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

QUADLETS_DIR="${1:-${SCRIPTDIR}/quadlets}"

if [ ! -d "${QUADLETS_DIR}" ] || [ -z "$(ls -A "${QUADLETS_DIR}" 2>/dev/null)" ]; then
  echo "No quadlet files found in ${QUADLETS_DIR}, skipping"
  exit 0
fi

WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
MANIFESTS_DIR="${2:-${EXTRA_MANIFESTS_PATH:-${WORKING_DIR}/ocp/${CLUSTER_NAME}/openshift}}"
mkdir -p "${MANIFESTS_DIR}"

for role in master worker; do
  mc_file="${MANIFESTS_DIR}/99-${role}-quadlets.yaml"

  cat > "${mc_file}" <<HEADER
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: 99-${role}-quadlets
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
HEADER

  # Node index helper script - extracts last octet from bridge IP as nodeIndex
  node_index_script="${QUADLETS_DIR}/openperouter-node-index.sh"
  if [ -f "${node_index_script}" ]; then
    encoded_script=$(base64 -w0 < "${node_index_script}")
    cat >> "${mc_file}" <<FILE
      - contents:
          source: data:text/plain;charset=utf-8;base64,${encoded_script}
        mode: 0755
        overwrite: true
        path: /usr/local/bin/openperouter-node-index.sh
FILE
  fi

  # Node index systemd unit - runs before openperouter quadlets
  node_index_unit="${QUADLETS_DIR}/openperouter-node-index.service"
  if [ -f "${node_index_unit}" ]; then
    encoded_unit=$(base64 -w0 < "${node_index_unit}")
    cat >> "${mc_file}" <<FILE
      - contents:
          source: data:text/plain;charset=utf-8;base64,${encoded_unit}
        mode: 0644
        overwrite: true
        path: /etc/systemd/system/openperouter-node-index.service
FILE

  else
    # Fallback: static node config when no systemd unit is available
    node_config="nodeIndex: 1
logLevel: debug"
    node_config_encoded=$(echo -n "${node_config}" | base64 -w0)
    cat >> "${mc_file}" <<FILE
      - contents:
          source: data:text/plain;charset=utf-8;base64,${node_config_encoded}
        mode: 0644
        overwrite: true
        path: /var/lib/openperouter/node-config.yaml
FILE
  fi

  # Quadlet files
  for quadlet_file in "${QUADLETS_DIR}"/*; do
    [ -f "${quadlet_file}" ] || continue
    filename=$(basename "${quadlet_file}")
    # Skip the node-index helper files (already handled above)
    [[ "${filename}" == openperouter-node-index.* ]] && continue

    # Use CRI-O variant of controller if available
    if [ "${filename}" == "controller.container" ] && [ -f "${QUADLETS_DIR}/crio/${filename}" ]; then
      encoded=$(base64 -w0 < "${QUADLETS_DIR}/crio/${filename}")
    else
      encoded=$(base64 -w0 < "${quadlet_file}")
    fi

    cat >> "${mc_file}" <<FILE
      - contents:
          source: data:text/plain;charset=utf-8;base64,${encoded}
        mode: 0644
        overwrite: true
        path: /etc/containers/systemd/${filename}
FILE
  done

  # Enable the node-index systemd unit if present
  if [ -f "${QUADLETS_DIR}/openperouter-node-index.service" ]; then
    cat >> "${mc_file}" <<UNITS
    systemd:
      units:
      - enabled: true
        name: openperouter-node-index.service
UNITS
  fi

  echo "Generated ${mc_file}"
done
