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

# Quadlet files and mode-specific assets
if [[ -d "${EXTRASDIR}/quadlets" ]]; then
    # Stage quadlet files (shared by both modes)
    for f in controllerpod.pod controller.container routerpod.pod frr.container \
             reloader.container frr-sockets.volume; do
        cp "${EXTRASDIR}/quadlets/${f}" "${staging}/"
    done

    if [[ -n "${USE_RAW:-}" ]]; then
        # Stage rawconfig scripts
        for f in openperouter-common.sh setup-underlay.sh setup-network.sh generate-config.sh; do
            cp "${EXTRASDIR}/rawconfig/${f}" "${staging}/"
        done
        # Stage rawconfig template and env
        cp "${EXTRASDIR}/rawconfig/openpe_evpn.yaml.template" "${staging}/"
        cp "${EXTRASDIR}/rawconfig/vpn-setup.env" "${staging}/"
        # Stage node-index and shared installer patching scripts
        cp "${EXTRASDIR}/common/openperouter-node-index.sh" "${staging}/"
        cp "${EXTRASDIR}/common/patch-installer-config.sh" "${staging}/"
    else
        # Stage common and openpeapi scripts and config
        cp "${EXTRASDIR}/common/openperouter-node-index.sh" "${staging}/"
        cp "${EXTRASDIR}/common/patch-installer-config.sh" "${staging}/"
        cp "${EXTRASDIR}/openpeapi/openperouter-raw-config.sh" "${staging}/"
        cp "${EXTRASDIR}/openpeapi/openpe_config.yaml" "${staging}/"
    fi

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

    if [[ -n "${USE_RAW:-}" ]]; then
        # Rawconfig scripts -> /usr/local/bin/ (executable)
        for f in openperouter-common.sh setup-underlay.sh setup-network.sh generate-config.sh \
                 openperouter-node-index.sh patch-installer-config.sh; do
            bu_files+="    - path: /usr/local/bin/${f}
      mode: 0755
      overwrite: true
      contents:
        local: ${f}
"
        done

        # Rawconfig template -> /etc/openperouter/templates/
        bu_files+="    - path: /etc/openperouter/templates/openpe_evpn.yaml.template
      mode: 0644
      overwrite: true
      contents:
        local: openpe_evpn.yaml.template
"

        # Rawconfig env -> /etc/openperouter/
        bu_files+="    - path: /etc/openperouter/vpn-setup.env
      mode: 0644
      overwrite: true
      contents:
        local: vpn-setup.env
"

        # Empty openpe_config.yaml (controller needs it to exist)
        touch "${staging}/openpe_config_empty.yaml"
        bu_files+="    - path: /var/lib/openperouter/configs/openpe_config.yaml
      mode: 0644
      overwrite: true
      contents:
        local: openpe_config_empty.yaml
"

        # Systemd units for rawconfig services
        bu_units+="    - name: setup-underlay.service
      enabled: true
      contents: |
        [Unit]
        Description=OpenPERouter Underlay Setup
        After=network-online.target routerpod-pod.service frr.service
        Requires=routerpod-pod.service
        Wants=network-online.target
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        EnvironmentFile=-/etc/openperouter/vpn-setup.env
        ExecStart=/usr/local/bin/setup-underlay.sh
        TimeoutStartSec=180
        [Install]
        WantedBy=multi-user.target
"
        bu_units+="    - name: setup-network.service
      enabled: true
      contents: |
        [Unit]
        Description=OpenPERouter Network Infrastructure Setup
        After=setup-underlay.service
        Requires=setup-underlay.service
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        EnvironmentFile=-/etc/openperouter/vpn-setup.env
        ExecStart=/usr/local/bin/setup-network.sh
        TimeoutStartSec=120
        [Install]
        WantedBy=multi-user.target
"
        bu_units+="    - name: generate-config.service
      enabled: true
      contents: |
        [Unit]
        Description=OpenPERouter Configuration Generator
        After=setup-underlay.service
        Requires=setup-underlay.service
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        EnvironmentFile=-/etc/openperouter/vpn-setup.env
        ExecStart=/usr/local/bin/generate-config.sh
        TimeoutStartSec=60
        [Install]
        WantedBy=multi-user.target
"
        bu_units+="    - name: openperouter-node-index.service
      enabled: true
      contents: |
        [Unit]
        Description=Set OpenPERouter nodeIndex from bridge IP
        After=network-online.target
        Before=controllerpod.service routerpod.service
        Wants=network-online.target
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/openperouter-node-index.sh
        RemainAfterExit=yes
        [Install]
        WantedBy=multi-user.target
"
    else
        # Openpeapi scripts -> /usr/local/bin/ (executable)
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

        # Systemd units for openpeapi services
        bu_units+="    - name: openperouter-node-index.service
      enabled: true
      contents: |
        [Unit]
        Description=Set OpenPERouter nodeIndex from bridge IP
        After=network-online.target
        Before=controllerpod.service routerpod.service
        Wants=network-online.target
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/openperouter-node-index.sh
        RemainAfterExit=yes
        [Install]
        WantedBy=multi-user.target
"
        bu_units+="    - name: openperouter-raw-config.service
      enabled: true
      contents: |
        [Unit]
        Description=Generate OpenPERouter raw FRR config from bridge IP
        After=network-online.target
        Before=controllerpod.service routerpod.service
        Wants=network-online.target
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/openperouter-raw-config.sh
        RemainAfterExit=yes
        [Install]
        WantedBy=multi-user.target
"
    fi

    # Shared installer patching service (both modes)
    bu_units+="    - name: enable-virtual-interfaces.service
      enabled: true
      contents: |
        [Unit]
        Description=Patch Assisted Service installer config for openperouter
        Before=assisted-service-pod.service
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/patch-installer-config.sh
        Restart=on-failure
        RestartSec=2
        RemainAfterExit=yes
        [Install]
        WantedBy=assisted-service-pod.service
"
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
if [[ -x "${SCRIPTDIR}/hackagent.sh" ]]; then
    "${SCRIPTDIR}/hackagent.sh" "${appliance_iso}"
fi

echo "==> Done! Appliance ISO patched: ${appliance_iso}"
