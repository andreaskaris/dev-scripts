#!/usr/bin/env bash
set -euxo pipefail

# Hook script for APPLIANCE_IGNITION_HOOK.
#
# Called by create_appliance() in 06_agent_create_cluster.sh after the
# appliance raw disk is built. It merges a custom ignition config into
# the disk's boot partition at /boot/ignition/config.ign.
#
# The custom ignition creates a systemd unit that sets
# ENABLE_VIRTUAL_INTERFACES=true for the assisted-service agent,
# so virtual interfaces (bridges) are included in the host inventory.
#
# Usage (called automatically by the hook):
#   ./embed_appliance_ignition.sh <appliance.raw>

APPLIANCE_RAW="${1:?Usage: $0 <appliance.raw>}"

TMPDIR=$(mktemp -d)
cleanup() {
    if mountpoint -q "${TMPDIR}/boot" 2>/dev/null; then
        sudo umount "${TMPDIR}/boot"
    fi
    if [ -n "${LOOP:-}" ]; then
        sudo losetup -d "${LOOP}" 2>/dev/null || true
    fi
    rm -rf "${TMPDIR}"
}
trap cleanup EXIT

# ── Generate the custom ignition config ──────────────────────────────────────

cat > "${TMPDIR}/set-assisted-env.sh" <<'ENVSCRIPT'
#!/bin/bash
# Inject ENABLE_VIRTUAL_INTERFACES=true so the assisted-service agent
# includes virtual interfaces (bridges) in its host inventory.
ENV_FILE="/usr/local/share/assisted-service/assisted-service.env"
mkdir -p "$(dirname "${ENV_FILE}")"
if [ -f "${ENV_FILE}" ]; then
    grep -q "^ENABLE_VIRTUAL_INTERFACES=" "${ENV_FILE}" || \
        echo "ENABLE_VIRTUAL_INTERFACES=true" >> "${ENV_FILE}"
else
    echo "ENABLE_VIRTUAL_INTERFACES=true" > "${ENV_FILE}"
fi
ENVSCRIPT

SCRIPT_B64=$(base64 -w0 < "${TMPDIR}/set-assisted-env.sh")

cat > "${TMPDIR}/custom.ign" <<EOF
{
  "ignition": { "version": "3.4.0" },
  "storage": {
    "files": [
      {
        "path": "/usr/local/bin/set-assisted-env.sh",
        "mode": 493,
        "overwrite": true,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,${SCRIPT_B64}"
        }
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "set-assisted-env.service",
        "enabled": true,
        "contents": "[Unit]\nDescription=Set assisted-service environment overrides\nBefore=agent.service assisted-service.service\nAfter=local-fs.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/set-assisted-env.sh\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n"
      }
    ]
  }
}
EOF

# ── Mount the boot partition from the raw disk ───────────────────────────────

LOOP=$(sudo losetup --find --show --partscan "${APPLIANCE_RAW}")
echo "Loop device: ${LOOP}"

# Find the boot partition (labeled "boot" in CoreOS disk layout)
BOOT_PART=""
for part in "${LOOP}"p*; do
    label=$(sudo blkid -s LABEL -o value "${part}" 2>/dev/null || true)
    if [ "${label}" = "boot" ]; then
        BOOT_PART="${part}"
        break
    fi
done

if [ -z "${BOOT_PART}" ]; then
    echo "ERROR: Could not find boot partition (label=boot) in ${APPLIANCE_RAW}"
    sudo fdisk -l "${LOOP}" || true
    exit 1
fi

echo "Boot partition: ${BOOT_PART}"
mkdir -p "${TMPDIR}/boot"
sudo mount "${BOOT_PART}" "${TMPDIR}/boot"

# ── Merge ignition configs ───────────────────────────────────────────────────

IGN_FILE="${TMPDIR}/boot/ignition.firstboot"
MERGED_IGN="${TMPDIR}/merged.ign"

if [ -f "${IGN_FILE}" ]; then
    echo "Found existing ignition at ${IGN_FILE}, merging..."
    sudo cat "${IGN_FILE}" > "${TMPDIR}/existing.ign"
    jq -s '
      .[0] as $base | .[1] as $custom |
      $base |
      .storage.files = ((.storage.files // []) + ($custom.storage.files // [])) |
      .systemd.units = ((.systemd.units // []) + ($custom.systemd.units // []))
    ' "${TMPDIR}/existing.ign" "${TMPDIR}/custom.ign" > "${MERGED_IGN}"
else
    echo "No existing ignition found, creating new"
    cp "${TMPDIR}/custom.ign" "${MERGED_IGN}"
fi

sudo cp "${MERGED_IGN}" "${IGN_FILE}"

echo "Ignition merged into ${APPLIANCE_RAW} boot partition"
