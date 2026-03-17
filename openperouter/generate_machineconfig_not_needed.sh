#!/usr/bin/env bash
# DEPRECATED: This script is no longer needed. MachineConfigs are now generated
# by prepare_extra_manifests.sh using butane from openperouter-boot2.bu and
# registry-appliance.bu source files.
set -euo pipefail

# Generate the 99-master-openperouter MachineConfig from source files.
#
# Sources:
#   openperouter/quadlets/            - Quadlet unit files
#   openperouter/openpeconfig/        - OpenPERouter configuration files
#
# File mapping:
#   quadlets/controllerpod.pod              -> /etc/containers/systemd/controllerpod.pod
#   quadlets/controller.container            -> /etc/containers/systemd/controller.container
#   quadlets/routerpod.pod                  -> /etc/containers/systemd/routerpod.pod
#   quadlets/frr.container                  -> /etc/containers/systemd/frr.container
#   quadlets/reloader.container             -> /etc/containers/systemd/reloader.container
#   quadlets/frr-sockets.volume             -> /etc/containers/systemd/frr-sockets.volume
#   quadlets/openperouter-node-index.service -> /etc/containers/systemd/openperouter-node-index.service
#   quadlets/openperouter-node-index.sh     -> /usr/local/bin/openperouter-node-index.sh
#   openpeconfig/node-config.yaml           -> /var/lib/openperouter/node-config.yaml
#   openpeconfig/openpe_config.yaml         -> /var/lib/openperouter/configs/openpe_config.yaml
#   openpeconfig/default_bridge               -> /etc/ovnk/default_bridge
#
# Usage:
#   ./generate_machineconfig.sh [output_file]
#
# If output_file is not specified, defaults to 99-master-openperouter.yaml
# in the same directory as this script.

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKING_DIR="${WORKING_DIR:-/opt/dev-scripts}"
CLUSTER_NAME="${CLUSTER_NAME:-ostest}"
OUTPUT="${1:-${WORKING_DIR}/ocp/${CLUSTER_NAME}/openshift/99-master-openperouter.yaml}"

QUADLETS_DIR="${SCRIPTDIR}/quadlets"
CONFIG_DIR="${SCRIPTDIR}/openpeconfig"

# Encode a file as a data: URI with gzip+base64 compression.
# Args: $1 = file path
encode_gzip() {
    local encoded
    encoded=$(gzip -c "$1" | base64 -w0)
    echo "data:;base64,${encoded}"
}

# Encode a file as a plain data: URI (URL-encoded).
# Args: $1 = file path
encode_plain() {
    python3 -c "
import urllib.parse, sys
with open(sys.argv[1], 'rb') as f:
    print('data:,' + urllib.parse.quote(f.read().decode(), safe=''))
" "$1"
}

# Build the file entries array.
# Each entry: source_file dest_path mode encoding
# mode: 420 = 0644, 493 = 0755
declare -a FILES=()

add_file() {
    local src="$1" dest="$2" mode="$3"
    FILES+=("${src}|${dest}|${mode}")
}

# Quadlet files -> /etc/containers/systemd/ (mode 0644)
add_file "${QUADLETS_DIR}/controllerpod.pod"              "/etc/containers/systemd/controllerpod.pod"              420
add_file "${QUADLETS_DIR}/controller.container"            "/etc/containers/systemd/controller.container"           420
add_file "${QUADLETS_DIR}/routerpod.pod"                  "/etc/containers/systemd/routerpod.pod"                  420
add_file "${QUADLETS_DIR}/frr.container"                  "/etc/containers/systemd/frr.container"                  420
add_file "${QUADLETS_DIR}/reloader.container"             "/etc/containers/systemd/reloader.container"             420
add_file "${QUADLETS_DIR}/frr-sockets.volume"             "/etc/containers/systemd/frr-sockets.volume"             420
add_file "${QUADLETS_DIR}/openperouter-node-index.service" "/etc/systemd/system/openperouter-node-index.service" 420
add_file "${QUADLETS_DIR}/openperouter-raw-config.service" "/etc/systemd/system/openperouter-raw-config.service" 420

# Scripts -> /usr/local/bin/ (mode 0755)
add_file "${QUADLETS_DIR}/openperouter-node-index.sh"     "/usr/local/bin/openperouter-node-index.sh"              493
add_file "${QUADLETS_DIR}/openperouter-raw-config.sh"     "/usr/local/bin/openperouter-raw-config.sh"              493

# Config files (mode 0644)
add_file "${CONFIG_DIR}/node-config.yaml"                 "/var/lib/openperouter/node-config.yaml"                 420
add_file "${CONFIG_DIR}/openpe_config.yaml"               "/var/lib/openperouter/configs/openpe_config.yaml"       420

# OVN bridge mapping - tells OVN to use br0 for br-ex
add_file "${CONFIG_DIR}/default_bridge"                     "/etc/ovnk/default_bridge"                                 420

# Generate the MachineConfig YAML
cat > "${OUTPUT}" <<'HEADER'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-openperouter
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
HEADER

for entry in "${FILES[@]}"; do
    IFS='|' read -r src dest mode <<< "${entry}"

    if [ ! -f "${src}" ]; then
        echo "ERROR: ${src} not found" >&2
        exit 1
    fi

    # Use plain encoding for small config files, gzip for larger files
    file_size=$(wc -c < "${src}")
    if [ "${file_size}" -lt 256 ]; then
        source_uri=$(encode_plain "${src}")
        compression='""'
    else
        source_uri=$(encode_gzip "${src}")
        compression="gzip"
    fi

    cat >> "${OUTPUT}" <<EOF
        - contents:
            compression: ${compression}
            source: ${source_uri}
          mode: ${mode}
          path: ${dest}
EOF
done

# Add systemd units section - enable all services
cat >> "${OUTPUT}" <<'UNITS'
    systemd:
      units:
        - enabled: true
          name: controllerpod.service
        - enabled: true
          name: controller.service
        - enabled: true
          name: routerpod.service
        - enabled: true
          name: frr.service
        - enabled: true
          name: reloader.service
        - enabled: true
          name: frr-sockets.service
        - enabled: true
          name: openperouter-node-index.service
        - enabled: true
          name: openperouter-raw-config.service
UNITS

echo "Generated ${OUTPUT}"
