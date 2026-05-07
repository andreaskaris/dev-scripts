#!/bin/bash
# build_custom_iso.sh - Build a custom RHCOS live ISO with patched kernel RPMs
# using CoreOS Assembler (cosa).
#
# Usage: build_custom_iso.sh [ocp_version]
#
#   ocp_version  OCP version for cache directory naming (e.g. 4.20.12).
#                Optional — if omitted, the ISO is placed in appliance/cache/.
#
# Prerequisites:
#   - Connected to Red Hat VPN
#   - Red Hat internal certificates installed
#   - podman, jq, yq available
#
# The script builds the RHCOS ISO under customkernel/rhcos-build/ (persistent
# for caching) and copies the result to appliance/cache/coreos-x86_64.iso.
# The ociarchive produced by cosa build is then consumed by
# build_custom_release.sh to create the custom release payload.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIANCE_DIR="$(cd "${SCRIPTDIR}/.." && pwd)"

RHEL_VARIANT="rhel-9.6"
RHEL_BRANCH="rhel-9.6"
RHCOS_REPO="https://gitlab.cee.redhat.com/coreos/redhat-coreos.git"
COREOS_CONFIG_REPO="https://github.com/coreos/rhel-coreos-config.git"
RPM_DIR="${SCRIPTDIR}/5.14.0-570.76.1.5114_2224397254.el9_6.x86_64"
BUILD_DIR="${SCRIPTDIR}/rhcos-build"

ocp_version="${1:-}"

if [[ ! -d "${RPM_DIR}" ]]; then
    echo "ERROR: Kernel RPM directory not found: ${RPM_DIR}"
    exit 1
fi

# ============================================================
# cosa wrapper function
# ============================================================
COREOS_ASSEMBLER_CONTAINER="${COREOS_ASSEMBLER_CONTAINER:-quay.io/coreos-assembler/coreos-assembler:v43.20260202.3.1}"

cosa() {
    env | grep COREOS_ASSEMBLER || true
    local -r COREOS_ASSEMBLER_CONTAINER_LATEST="quay.io/coreos-assembler/coreos-assembler:latest"
    if [[ -z ${COREOS_ASSEMBLER_CONTAINER:-} ]] && podman image exists "${COREOS_ASSEMBLER_CONTAINER_LATEST}"; then
        local -r cosa_build_date_str="$(podman inspect -f "{{.Created}}" "${COREOS_ASSEMBLER_CONTAINER_LATEST}" | awk '{print $1}')"
        local -r cosa_build_date="$(date -d "${cosa_build_date_str}" +%s)"
        if [[ $(date +%s) -ge $((cosa_build_date + 60*60*24*7)) ]]; then
            echo -e "\e[0;33m----" >&2
            echo "The COSA container image is more than a week old and likely outdated." >&2
            echo "You should pull the latest version with:" >&2
            echo "podman pull ${COREOS_ASSEMBLER_CONTAINER_LATEST}" >&2
            echo -e "----\e[0m" >&2
            sleep 10
        fi
    fi
    set -x
    local -r _host_auth="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
    local _auth_mount=""
    if [[ -f "${_host_auth}" ]]; then
        _auth_mount="-v=${_host_auth}:/home/builder/.docker/config.json:ro"
    fi
    podman run --rm -ti --security-opt=label=disable --privileged \
        --userns=keep-id:uid=1000,gid=1000 \
        -v="${PWD}:/srv/" --device=/dev/kvm --device=/dev/fuse \
        --tmpfs=/tmp -v=/var/tmp:/var/tmp --name=cosa \
        ${_auth_mount} \
        ${COREOS_ASSEMBLER_CONFIG_GIT:+-v="$COREOS_ASSEMBLER_CONFIG_GIT:/srv/src/config/:ro"} \
        ${COREOS_ASSEMBLER_GIT:+-v="$COREOS_ASSEMBLER_GIT/src/:/usr/lib/coreos-assembler/:ro"} \
        ${COREOS_ASSEMBLER_ADD_CERTS:+-v=/etc/pki/ca-trust:/etc/pki/ca-trust:ro} \
        ${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS:-} \
        "${COREOS_ASSEMBLER_CONTAINER:-$COREOS_ASSEMBLER_CONTAINER_LATEST}" "$@"
    rc=$?; set +x; return $rc
}

export COREOS_ASSEMBLER_ADD_CERTS='y'

# ============================================================
# Prepare registry auth for cosa
# ============================================================
_host_auth="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
if [[ ! -f "${_host_auth}" ]]; then
    _host_auth="${HOME}/.docker/config.json"
fi
if [[ ! -f "${_host_auth}" ]]; then
    echo "ERROR: No registry auth file found. Run: podman login registry.redhat.io"
    exit 1
fi

# ============================================================
# Step 1: Initialize cosa build directory
# ============================================================
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -d src/config ]]; then
    echo "==> Initializing cosa workspace..."
    cosa init --yumrepos "${RHCOS_REPO}" --variant "${RHEL_VARIANT}" --branch "${RHEL_BRANCH}" "${COREOS_CONFIG_REPO}"
else
    echo "==> Reusing existing cosa workspace"
fi

# ============================================================
# Step 2: Copy kernel RPMs to overrides
# ============================================================
echo "==> Copying kernel RPMs to overrides/rpm/..."
mkdir -p overrides/rpm
cp "${RPM_DIR}"/*.rpm overrides/rpm/

# ============================================================
# Step 3: Build custom RHCOS
# ============================================================
echo "==> Running cosa fetch..."
cosa fetch

echo "==> Running cosa build..."
cosa build --version "$(date +%Y%m%d).0.custom"

echo "==> Building live ISO..."
cosa osbuild live

# ============================================================
# Step 4: Copy ISO to appliance cache
# ============================================================
iso_path="$(find builds/ -name "*.iso" -print -quit)"

if [[ -z "${iso_path}" ]]; then
    echo "ERROR: No ISO found under builds/ after cosa osbuild live"
    exit 1
fi

echo "==> Custom RHCOS ISO built: ${iso_path}"

arch="x86_64"
if [[ -n "${ocp_version}" ]]; then
    cache_dir="${APPLIANCE_DIR}/cache/${ocp_version}-${arch}"
else
    cache_dir="${APPLIANCE_DIR}/cache"
fi
sudo mkdir -p "${cache_dir}"
sudo cp "${iso_path}" "${cache_dir}/coreos-x86_64.iso"

echo "==> Copied ISO to ${cache_dir}/coreos-x86_64.iso"
echo "==> Done! Run build_custom_release.sh next to build the custom OCP release payload."
