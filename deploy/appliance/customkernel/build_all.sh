#!/bin/bash
# build_all.sh - Build a custom RHCOS ISO with patched kernel RPMs,
# build the custom rhel-coreos node image, create a custom OCP release
# payload, and copy the ISO into the appliance cache.
#
# Usage: build_all.sh <ocp_version> <pull_secret_file>
#
#   ocp_version       OCP version (e.g. 4.20.12)
#   pull_secret_file  Path to pull secret JSON file
#
# Environment variables:
#   QUAY_USER          Quay.io username (default: fpaoline)
#   KERNEL_TAG         Kernel version tag (default: derived from RPM dir)
#   RPM_DIR            Path to kernel RPM directory (default: auto-detected)
#
# Prerequisites:
#   - Connected to Red Hat VPN
#   - Red Hat internal certificates installed
#   - podman login quay.io
#   - podman login registry.redhat.io
#   - Tools: podman, skopeo, jq, yq, oc

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIANCE_DIR="$(cd "${SCRIPTDIR}/.." && pwd)"

ocp_version="${1:-}"
pull_secret_file="${2:-}"

if [[ -z "${ocp_version}" || -z "${pull_secret_file}" ]]; then
    echo "Usage: build_all.sh <ocp_version> <pull_secret_file>"
    echo "  e.g. build_all.sh 4.20.12 /path/to/pull_secret.json"
    exit 1
fi

if [[ ! -f "${pull_secret_file}" ]]; then
    echo "ERROR: Pull secret file not found: ${pull_secret_file}"
    exit 1
fi

pull_secret_file="$(realpath "${pull_secret_file}")"

QUAY_USER="${QUAY_USER:-fpaoline}"
RPM_DIR="${RPM_DIR:-$(ls -d "${SCRIPTDIR}"/5.14.0-* 2>/dev/null | head -1)}"
KERNEL_TAG="${KERNEL_TAG:-$(basename "${RPM_DIR}" | sed 's/\.el9_6\.x86_64$//')}"

if [[ -z "${RPM_DIR}" || ! -d "${RPM_DIR}" ]]; then
    echo "ERROR: Kernel RPM directory not found. Set RPM_DIR or ensure a 5.14.0-* directory exists."
    exit 1
fi

if [[ -z "${KERNEL_TAG}" ]]; then
    echo "ERROR: Could not determine kernel tag. Set KERNEL_TAG."
    exit 1
fi

arch="x86_64"
cache_dir="${APPLIANCE_DIR}/cache/${ocp_version}-${arch}"

RHEL_VARIANT="rhel-9.6"
RHEL_BRANCH="rhel-9.6"
RHCOS_REPO="https://gitlab.cee.redhat.com/coreos/redhat-coreos.git"
COREOS_CONFIG_REPO="https://github.com/coreos/rhel-coreos-config.git"
BUILD_DIR="${SCRIPTDIR}/rhcos-build"

COREOS_ASSEMBLER_CONTAINER="${COREOS_ASSEMBLER_CONTAINER:-quay.io/coreos-assembler/coreos-assembler:v43.20260202.3.1}"

BASE_RELEASE="quay.io/openshift-release-dev/ocp-release:${ocp_version}-${arch}"
COREOS_IMAGE="quay.io/${QUAY_USER}/rhel-coreos"
RELEASE_IMAGE="quay.io/${QUAY_USER}/ocp-release:${ocp_version}-${arch}-kernel-${KERNEL_TAG}"

echo "============================================================"
echo "Building custom kernel appliance"
echo ""
echo "  OCP version:     ${ocp_version}"
echo "  Kernel tag:      ${KERNEL_TAG}"
echo "  RPM directory:   ${RPM_DIR}"
echo "  Quay user:       ${QUAY_USER}"
echo "  Release image:   ${RELEASE_IMAGE}"
echo "  Cache directory: ${cache_dir}"
echo "============================================================"

# ============================================================
# cosa wrapper
# ============================================================
cosa() {
    env | grep COREOS_ASSEMBLER || true
    local -r COREOS_ASSEMBLER_CONTAINER_LATEST="quay.io/coreos-assembler/coreos-assembler:latest"
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
# Phase 1: Build custom RHCOS ISO
# ============================================================
echo ""
echo "============================================================"
echo "Phase 1: Building custom RHCOS ISO"
echo "============================================================"

_host_auth="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
if [[ ! -f "${_host_auth}" ]]; then
    _host_auth="${HOME}/.docker/config.json"
fi
if [[ ! -f "${_host_auth}" ]]; then
    echo "ERROR: No registry auth file found. Run: podman login registry.redhat.io"
    exit 1
fi

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -d src/config ]]; then
    echo "==> Initializing cosa workspace..."
    cosa init --yumrepos "${RHCOS_REPO}" --variant "${RHEL_VARIANT}" --branch "${RHEL_BRANCH}" "${COREOS_CONFIG_REPO}"
else
    echo "==> Reusing existing cosa workspace"
fi

echo "==> Copying kernel RPMs to overrides/rpm/..."
mkdir -p overrides/rpm
cp "${RPM_DIR}"/*.rpm overrides/rpm/

echo "==> Running cosa fetch..."
cosa fetch

echo "==> Running cosa build..."
cosa build --version "$(date +%Y%m%d).custom"

echo "==> Building live ISO..."
cosa osbuild live

iso_path="$(find builds/ -name "*.iso" -print -quit)"
if [[ -z "${iso_path}" ]]; then
    echo "ERROR: No ISO found under builds/ after cosa osbuild live"
    exit 1
fi
echo "==> Custom RHCOS ISO built: ${iso_path}"

sudo mkdir -p "${cache_dir}"
sudo cp "${iso_path}" "${cache_dir}/coreos-x86_64.iso"
echo "==> Copied ISO to ${cache_dir}/coreos-x86_64.iso"

# ============================================================
# Phase 2: Build custom rhel-coreos node image + OCP release
# ============================================================
echo ""
echo "============================================================"
echo "Phase 2: Building custom OCP release payload"
echo "============================================================"

ociarchive="$(find "${BUILD_DIR}/builds/" -name "*.ociarchive" -print -quit 2>/dev/null || true)"
if [[ -z "${ociarchive}" ]]; then
    echo "ERROR: No .ociarchive found under ${BUILD_DIR}/builds/"
    exit 1
fi

cosa_build_id="$(basename "$(dirname "$(dirname "${ociarchive}")")")"
echo "==> Found ociarchive: ${ociarchive} (build: ${cosa_build_id})"

COREOS_TAG="${cosa_build_id}-kernel-${KERNEL_TAG}"
COREOS_FULL="${COREOS_IMAGE}:${COREOS_TAG}"

echo "==> Finding rhel-coreos commit for ${ocp_version}..."
os_commit="$(oc adm release info "${BASE_RELEASE}" --commits -a "${pull_secret_file}" \
    | awk '$1 == "rhel-coreos" {print $NF}')"

if [[ -z "${os_commit}" ]]; then
    echo "ERROR: Could not find rhel-coreos commit for ${BASE_RELEASE}"
    exit 1
fi
echo "==> rhel-coreos commit: ${os_commit}"

os_dir="${SCRIPTDIR}/os"
if [[ ! -d "${os_dir}" ]]; then
    echo "==> Cloning openshift/os..."
    git clone https://github.com/openshift/os.git "${os_dir}"
fi

cd "${os_dir}"
git fetch origin
git checkout "${os_commit}"

echo "==> Preparing yum repos..."
cat "${BUILD_DIR}"/src/yumrepos/*.repo > all.repo

echo "==> Building rhel-coreos node image: ${COREOS_FULL}"
sudo podman build \
    --from "oci-archive:${ociarchive}" \
    --secret id=yumrepos,src=all.repo \
    -v /etc/pki/ca-trust:/etc/pki/ca-trust:ro \
    --security-opt label=disable \
    --authfile "${pull_secret_file}" \
    -t "${COREOS_FULL}" .

# Fix machine-os version label for semver compliance
raw_versions="$(sudo podman inspect --format '{{index .Config.Labels "io.openshift.build.versions"}}' "${COREOS_FULL}" 2>/dev/null || true)"
if [[ -n "${raw_versions}" ]]; then
    fixed_versions="$(echo "${raw_versions}" | sed -E 's/machine-os=([0-9]+)\.([^,]*)/machine-os=\1.0.0-\2/')"
    if [[ "${fixed_versions}" != "${raw_versions}" ]]; then
        echo "==> Fixing machine-os version label for semver compliance"
        fix_containerfile="$(mktemp)"
        cat > "${fix_containerfile}" <<EOF
FROM ${COREOS_FULL}
LABEL io.openshift.build.versions="${fixed_versions}"
EOF
        sudo podman build -t "${COREOS_FULL}" -f "${fix_containerfile}" .
        rm -f "${fix_containerfile}"
    fi
fi

# ============================================================
# Phase 3: Prepare merged auth and push
# ============================================================
echo ""
echo "============================================================"
echo "Phase 3: Pushing image and building release"
echo "============================================================"

merged_auth="$(mktemp)"
trap "rm -f '${merged_auth}'" EXIT

cp "${pull_secret_file}" "${merged_auth}"

quay_creds=""
for auth_file in \
    "${HOME}/.docker/config.json" \
    "${HOME}/.config/containers/auth.json" \
    "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"; do
    if [[ -f "${auth_file}" ]]; then
        _creds="$(jq -r '.auths["quay.io"] // empty' "${auth_file}")"
        if [[ -n "${_creds}" ]]; then
            quay_creds="${_creds}"
            break
        fi
    fi
done

if [[ -n "${quay_creds}" ]]; then
    jq --argjson creds "${quay_creds}" \
       --arg key "quay.io/${QUAY_USER}" \
       '.auths[$key] = $creds' "${merged_auth}" > "${merged_auth}.tmp" \
        && mv "${merged_auth}.tmp" "${merged_auth}"
fi

echo "==> Pushing ${COREOS_FULL}..."
sudo podman push --authfile "${merged_auth}" "${COREOS_FULL}"

echo "==> Getting image digest..."
DIGEST="$(skopeo inspect --authfile "${merged_auth}" "docker://${COREOS_FULL}" | jq -r .Digest)"
echo "==> Digest: ${DIGEST}"

echo "==> Building custom OCP release: ${RELEASE_IMAGE}"
oc adm release new \
    --from-release="${BASE_RELEASE}" \
    --to-image="${RELEASE_IMAGE}" \
    "rhel-coreos=${COREOS_IMAGE}@${DIGEST}" \
    -a "${merged_auth}"

# ============================================================
# Phase 4: Update appliance config
# ============================================================
base_config="${APPLIANCE_DIR}/appliance-config.yaml.base"
if [[ -f "${base_config}" ]]; then
    yq -y ".ocpRelease.url = \"${RELEASE_IMAGE}\"" "${base_config}" > "${base_config}.tmp" \
        && mv "${base_config}.tmp" "${base_config}"
    echo "==> Updated ${base_config} with ocpRelease.url: ${RELEASE_IMAGE}"
fi

echo ""
echo "============================================================"
echo "Done!"
echo ""
echo "  RHCOS ISO:        ${cache_dir}/coreos-x86_64.iso"
echo "  rhel-coreos:      ${COREOS_FULL}"
echo "  rhel-coreos digest: ${DIGEST}"
echo "  OCP release:      ${RELEASE_IMAGE}"
echo ""
echo "Next steps:"
echo "  1. Update config_fpaoline.sh OPENSHIFT_RELEASE_IMAGE with:"
echo "     skopeo inspect docker://${RELEASE_IMAGE} | jq -r .Digest"
echo "  2. cd ${APPLIANCE_DIR} && USE_RAW=1 ./generate_appliance.sh ${pull_secret_file}"
echo "============================================================"
