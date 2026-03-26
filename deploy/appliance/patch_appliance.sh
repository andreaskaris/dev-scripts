#!/bin/bash
# patch_appliance.sh - Patch an existing appliance ISO by embedding
# OpenPERouter quadlets, configs, registry mirrors, DNS overrides,
# and the ignition hack agent into it.
#
# Usage: patch_appliance.sh <appliance_iso> <ocp_dir>
#
#   appliance_iso         Path to the appliance ISO to patch
#   ocp_dir               OCP working directory containing cache/*/cluster-resources
#
# Requires: coreos-installer, jq, yq, butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

appliance_iso="$1"
ocp_dir="$2"

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found: ${appliance_iso}"
    exit 1
fi

# ============================================================
# Step 1: Embed OpenPERouter content into the ISO ignition
# ============================================================
echo "==> Patching appliance ISO with OpenPERouter content..."

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

staging="${tmpdir}/staging"
mkdir -p "${staging}"

# --- Generate registries.conf drop-in ---
# Converts IDMS/ITMS yaml files from the appliance cache into a
# registries.conf drop-in so mirror redirects work on first boot.
registries_conf="${staging}/appliance-mirrors.conf"
cluster_resources="${ocp_dir}/cache/"*"/cluster-resources"
{
    for yaml_file in ${cluster_resources}/idms-oc-mirror.yaml ${cluster_resources}/itms-oc-mirror.yaml; do
        if [[ ! -f "${yaml_file}" ]]; then
            continue
        fi
        if [[ "${yaml_file}" == *idms* ]]; then
            digest_only="true"
        else
            digest_only="false"
        fi
        yq -r '.spec.imageDigestMirrors // .spec.imageTagMirrors // [] | .[] | .source as $src | .mirrors[] | [$src, .] | @tsv' "${yaml_file}" | \
        while IFS=$'\t' read -r source mirror; do
            cat <<TOML

[[registry]]
  prefix = ""
  location = "${source}"
  mirror-by-digest-only = ${digest_only}

  [[registry.mirror]]
    location = "${mirror}"
    insecure = true
TOML
        done
    done
} > "${registries_conf}"

# --- Build butane YAML ---
bu="${tmpdir}/appliance.bu"
bu_files=""
bu_units=""

# Registry mirrors
if [[ -s "${registries_conf}" ]]; then
    bu_files+="    - path: /etc/containers/registries.conf.d/appliance-mirrors.conf
      mode: 0644
      overwrite: true
      contents:
        local: appliance-mirrors.conf
"
fi

# Quadlet files and configs
if [[ -d "${EXTRASDIR}/quadlets" ]]; then
    # Stage all source files into the butane files-dir
    for f in controllerpod.pod controller.container routerpod.pod frr.container \
             reloader.container frr-sockets.volume openperouter-node-index.sh \
             openperouter-raw-config.sh patch-installer-config.sh \
             openperouter-node-index.service openperouter-raw-config.service \
             enable-virtual-interfaces.service; do
        cp "${EXTRASDIR}/quadlets/${f}" "${staging}/"
    done
    cp "${EXTRASDIR}/config/openpe_config.yaml" "${staging}/"

    # Quadlet files -> /etc/containers/systemd/
    for f in controllerpod.pod controller.container routerpod.pod frr.container \
             reloader.container frr-sockets.volume; do
        bu_files+="    - path: /etc/containers/systemd/${f}
      mode: 0644
      overwrite: true
      contents:
        local: ${f}
"
    done

    # Scripts -> /usr/local/bin/ (executable)
    for f in openperouter-node-index.sh openperouter-raw-config.sh patch-installer-config.sh; do
        bu_files+="    - path: /usr/local/bin/${f}
      mode: 0755
      overwrite: true
      contents:
        local: ${f}
"
    done

    # Config files -> /var/lib/openperouter/
    bu_files+="    - path: /var/lib/openperouter/configs/openpe_config.yaml
      mode: 0644
      overwrite: true
      contents:
        local: openpe_config.yaml
"

    # Systemd units (using contents_local so butane reads from files-dir)
    for f in openperouter-node-index.service openperouter-raw-config.service \
             enable-virtual-interfaces.service; do
        bu_units+="    - name: ${f}
      enabled: true
      contents_local: ${f}
"
    done
fi

# DNS config files from dns.bu
if [[ -f "${EXTRASDIR}/dns/dns.bu" ]]; then
    while IFS=$'\t' read -r fpath contents; do
        local_file="$(basename "${fpath}")"
        printf '%b\n' "${contents}" > "${staging}/${local_file}"
        bu_files+="    - path: ${fpath}
      mode: 0644
      overwrite: true
      contents:
        local: ${local_file}
"
    done < <(yq -r '.storage.files[] | [.path, .contents.inline] | @tsv' "${EXTRASDIR}/dns/dns.bu")

    bu_units+="    - name: on-prem-resolv-prepender.service
      mask: true
      enabled: false
"
fi

# --- Assemble and compile butane ---
if [[ -z "${bu_files}" && -z "${bu_units}" ]]; then
    echo "Nothing to embed into appliance ISO"
else
    {
        echo "variant: fcos"
        echo "version: 1.5.0"
        if [[ -n "${bu_files}" ]]; then
            echo "storage:"
            echo "  files:"
            printf '%s' "${bu_files}"
        fi
        if [[ -n "${bu_units}" ]]; then
            echo "systemd:"
            echo "  units:"
            printf '%s' "${bu_units}"
        fi
    } > "${bu}"

    # Compile butane -> ignition (butane handles base64 encoding, etc.)
    butane --raw --strict -d "${staging}" "${bu}" > "${tmpdir}/additions.ign"

    # Extract existing ISO ignition
    sudo coreos-installer iso ignition show "${appliance_iso}" > "${tmpdir}/original.ign" 2>/dev/null \
        || echo '{"ignition":{"version":"3.4.0"}}' > "${tmpdir}/original.ign"

    # Merge our additions with the original ignition
    jq -s '
        .[0] as $orig | .[1] as $new |
        $orig |
        .storage = (.storage // {}) |
        .storage.files = ((.storage.files // []) + ($new.storage.files // [])) |
        if ($new.systemd.units // [] | length) > 0 then
            .systemd = (.systemd // {}) |
            .systemd.units = ((.systemd.units // []) + ($new.systemd.units // []))
        else . end
    ' "${tmpdir}/original.ign" "${tmpdir}/additions.ign" > "${tmpdir}/merged.ign"

    # Embed merged ignition into ISO (force overwrite)
    sudo coreos-installer iso ignition embed -f -i "${tmpdir}/merged.ign" "${appliance_iso}"

    echo "==> Embedded OpenPERouter ignition into appliance ISO"
fi

# ============================================================
# Step 2: Embed ignition hack agent
# ============================================================
echo "==> Embedding ignition hack agent..."

HACK_WORK_DIR=$(mktemp -d)
EXTRACTED_IGN="$HACK_WORK_DIR/extracted.ign"
MODIFIED_IGN="$HACK_WORK_DIR/modified.ign"
HACK_SCRIPT_FILE="$HACK_WORK_DIR/hack-script.sh"

hack_cleanup() {
    rm -rf "$HACK_WORK_DIR"
}

if sudo coreos-installer iso ignition show "$appliance_iso" > "$EXTRACTED_IGN" 2>/dev/null && [ -s "$EXTRACTED_IGN" ]; then
    echo "Extracted existing ignition configuration"
else
    echo "No existing ignition found. Aborting hack agent embedding"
    hack_cleanup
    exit 1
fi

# Write the hack script to a file
cat > "$HACK_SCRIPT_FILE" << 'HACKSCRIPT_EOF'
#!/bin/bash

LOG_FILE="/tmp/ignition-hack.log"
URL="https://192.168.110.2:22623/config/master"
IGN_FILE="/tmp/master-mcs-server.ign"
LOCAL_IGN_DIR="/opt/install-dir"
CONVERTER_IMAGE="quay.io/mavazque/ign-converter:latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting ignition hack script"

# Pull the ignition converter image
log "Pulling ignition converter image: $CONVERTER_IMAGE"
if podman pull "$CONVERTER_IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    log "Successfully pulled converter image"
else
    log "ERROR: Failed to pull converter image"
    exit 1
fi

# Wait for the local master ignition file to be created
log "Waiting for local master ignition file in $LOCAL_IGN_DIR..."
while true; do
    LOCAL_IGN_FILE=$(find "$LOCAL_IGN_DIR" -maxdepth 1 -name 'master-*.ign' -type f 2>/dev/null | head -1)

    if [ -n "$LOCAL_IGN_FILE" ]; then
        log "Found local ignition file: $LOCAL_IGN_FILE"
        break
    fi

    sleep 1
done

# Extract ignition version from local file
IGN_VERSION=$(jq -r '.ignition.version' "$LOCAL_IGN_FILE")
if [ -z "$IGN_VERSION" ] || [ "$IGN_VERSION" = "null" ]; then
    log "ERROR: Could not extract ignition version from $LOCAL_IGN_FILE"
    exit 1
fi
log "Ignition version from local file: $IGN_VERSION"

# Extract hostname file config from local ignition
HOSTNAME_CONFIG=$(jq '.storage.files[] | select(.path == "/etc/hostname")' "$LOCAL_IGN_FILE" 2>/dev/null)
if [ -z "$HOSTNAME_CONFIG" ] || [ "$HOSTNAME_CONFIG" = "null" ]; then
    log "WARNING: No /etc/hostname configuration found in local ignition file"
    HOSTNAME_CONFIG=""
else
    log "Found hostname configuration in local ignition file"
fi

# Poll URL until MCS is accessible
log "Waiting for $URL to become accessible..."
while true; do
    if curl -k -s --connect-timeout 1 --max-time 5 -o "$IGN_FILE" "$URL"; then
        log "URL is accessible, saved ignition file to $IGN_FILE"
        break
    fi
    sleep 1
done

# Convert downloaded ignition from v2 to v3
log "Converting downloaded ignition file to spec v3..."
if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "/tmp/master-mcs-server.ign" -output "/tmp/master-mcs-server-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
    mv /tmp/master-mcs-server-v3.ign /tmp/master-mcs-server.ign
    log "Successfully converted ignition to v3"
else
    log "ERROR: Failed to convert ignition file to v3"
    exit 1
fi

# Merge the hostname config and update version in downloaded ignition
log "Merging hostname config and updating ignition version..."
if [ -n "$HOSTNAME_CONFIG" ]; then
    jq --argjson hostname "$HOSTNAME_CONFIG" --arg version "$IGN_VERSION" '
        .ignition.version = $version |
        .storage.files = (
            [.storage.files[]? | select(.path != "/etc/hostname")] + [$hostname]
        )
    ' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
else
    jq --arg version "$IGN_VERSION" '.ignition.version = $version' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
fi

if [ $? -ne 0 ]; then
    log "ERROR: Failed to merge ignition configurations"
    exit 1
fi
log "Successfully merged ignition configuration"

# Extract arguments from journalctl, retry every 5 seconds until found
log "Extracting coreos-installer arguments from journalctl..."
while true; do
    ARGS=$(journalctl -b | grep 'Writing image and ignition to disk with arguments' | tail -1 | grep -oP 'Writing image and ignition to disk with arguments: \[\K[^\]]+')

    if [ -n "$ARGS" ]; then
        log "Found installer arguments"
        break
    fi

    log "Log line not found, retrying in 5 seconds..."
    sleep 5
done

log "Original arguments: $ARGS"

DISK=$(echo "$ARGS" | grep -oP '/dev/\S+')
log "Target disk: $DISK"

TRANSFORMED_ARGS=$(echo "$ARGS" | sed 's|-i [^ ]*|-i /tmp/master-mcs-server.ign|')
TRANSFORMED_ARGS=$(echo "$TRANSFORMED_ARGS" | sed 's/^install //')

COREOS_CMD="coreos-installer install $TRANSFORMED_ARGS"
log "Transformed command: $COREOS_CMD"

log "Backing up /etc/resolv.conf to /tmp/resolv.conf.bk"
cp /etc/resolv.conf /tmp/resolv.conf.bk

log "Writing nameserver to /etc/resolv.conf"
echo 'nameserver 169.254.0.1' > /etc/resolv.conf

log "Wiping filesystem signatures from $DISK"
wipefs -a "$DISK" -f 2>&1 | tee -a "$LOG_FILE"

log "Running: $COREOS_CMD"
$COREOS_CMD 2>&1 | tee -a "$LOG_FILE"
RESULT=${PIPESTATUS[0]}

log "Restoring /etc/resolv.conf from backup"
cp /tmp/resolv.conf.bk /etc/resolv.conf

if [ $RESULT -eq 0 ]; then
    log "coreos-installer completed successfully"
else
    log "ERROR: coreos-installer failed with exit code $RESULT"
    exit $RESULT
fi

log "Ignition hack script completed"
HACKSCRIPT_EOF

# Base64 encode the script
SCRIPT_B64=$(base64 -w0 < "$HACK_SCRIPT_FILE")

# Systemd unit file
SYSTEMD_UNIT='[Unit]
Description=Ignition Hack Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ignition-hack.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'

# Merge into existing ignition
echo "Merging hack agent script and systemd unit into ignition..."
jq --arg script_b64 "$SCRIPT_B64" --arg unit "$SYSTEMD_UNIT" '
    .storage = (.storage // {}) |
    .storage.files = ((.storage.files // []) + [{
        "group": {},
        "overwrite": true,
        "path": "/usr/local/bin/ignition-hack.sh",
        "user": {
          "name": "root"
        },
        "mode": 365,
        "contents": {
            "source": ("data:text/plain;charset=utf-8;base64," + $script_b64),
            "verification": {}
        }
    }]) |
    .systemd = (.systemd // {}) |
    .systemd.units = ((.systemd.units // []) + [{
        "name": "ignition-hack.service",
        "enabled": true,
        "contents": $unit
    }])
' "$EXTRACTED_IGN" > "$MODIFIED_IGN"

echo "Removing any existing embedded ignition..."
sudo coreos-installer iso ignition remove "$appliance_iso" 2>/dev/null || true

echo "Embedding final ignition into ISO..."
sudo coreos-installer iso ignition embed -i "$MODIFIED_IGN" "$appliance_iso"

hack_cleanup

echo "==> Done! Appliance ISO patched: ${appliance_iso}"
