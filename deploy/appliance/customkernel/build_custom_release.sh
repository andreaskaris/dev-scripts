#!/bin/bash
# build_custom_release.sh - Build a custom rhel-coreos image from the cosa
# ociarchive and create a custom OCP release payload containing it.
#
# This replaces the manual procedure from instructions.md (lines 103-122)
# and removes the dependency on external pre-built images.
#
# Usage: build_custom_release.sh <ocp_version> <pull_secret_file>
#
#   ocp_version       The OCP version to base the release on (e.g. 4.20.12)
#   pull_secret_file   Path to the pull secret JSON file
#
# Environment variables:
#   QUAY_USER          Quay.io username (default: fpaoline)
#   KERNEL_TAG         Kernel version tag for image naming
#                      (default: derived from RPM_DIR basename)
#   COSA_BUILD_DIR     Path to the cosa build directory
#                      (default: <scriptdir>/rhcos-build)
#
# Prerequisites:
#   - cosa build completed (build_custom_iso.sh already run)
#   - Logged in to quay.io: podman login quay.io
#   - Logged in to Red Hat registry: podman login registry.redhat.io
#   - Connected to Red Hat VPN
#   - Tools: podman, skopeo, jq, oc

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ocp_version="${1:-}"
pull_secret_file="${2:-}"

if [[ -z "${ocp_version}" || -z "${pull_secret_file}" ]]; then
    echo "Usage: build_custom_release.sh <ocp_version> <pull_secret_file>"
    echo "  e.g. build_custom_release.sh 4.20.12 /path/to/pull_secret.json"
    exit 1
fi

if [[ ! -f "${pull_secret_file}" ]]; then
    echo "ERROR: Pull secret file not found: ${pull_secret_file}"
    exit 1
fi

pull_secret_file="$(realpath "${pull_secret_file}")"

QUAY_USER="${QUAY_USER:-fpaoline}"
COSA_BUILD_DIR="${COSA_BUILD_DIR:-${SCRIPTDIR}/rhcos-build}"
KERNEL_TAG="${KERNEL_TAG:-$(basename "$(ls -d "${SCRIPTDIR}"/5.14.0-* 2>/dev/null | head -1)" | sed 's/\.el9_6\.x86_64$//')}"

if [[ -z "${KERNEL_TAG}" ]]; then
    echo "ERROR: Could not determine kernel tag. Set KERNEL_TAG or ensure a 5.14.0-* directory exists."
    exit 1
fi

BASE_RELEASE="quay.io/openshift-release-dev/ocp-release:${ocp_version}-x86_64"
COREOS_IMAGE="quay.io/${QUAY_USER}/rhel-coreos"
RELEASE_IMAGE="quay.io/${QUAY_USER}/ocp-release:${ocp_version}-x86_64-kernel-${KERNEL_TAG}"

# ============================================================
# Step 1: Find the ociarchive from the cosa build
# ============================================================
echo "==> Looking for ociarchive in ${COSA_BUILD_DIR}..."

ociarchive="$(find "${COSA_BUILD_DIR}/builds/" -name "*.ociarchive" -print -quit 2>/dev/null || true)"

if [[ -z "${ociarchive}" ]]; then
    echo "ERROR: No .ociarchive found under ${COSA_BUILD_DIR}/builds/"
    echo "Run build_custom_iso.sh first to create the cosa build."
    exit 1
fi

cosa_build_id="$(basename "$(dirname "$(dirname "${ociarchive}")")")"
echo "==> Found ociarchive: ${ociarchive} (build: ${cosa_build_id})"

COREOS_TAG="${cosa_build_id}-kernel-${KERNEL_TAG}"
COREOS_FULL="${COREOS_IMAGE}:${COREOS_TAG}"

# ============================================================
# Step 2: Clone openshift/os at the correct commit
# ============================================================
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

# ============================================================
# Step 3: Prepare yum repos
# ============================================================
echo "==> Preparing yum repos..."
cat "${COSA_BUILD_DIR}"/src/yumrepos/*.repo > all.repo

# ============================================================
# Step 4: Build the rhel-coreos node image
# ============================================================
echo "==> Building rhel-coreos node image: ${COREOS_FULL}"
echo "    from ociarchive: ${ociarchive}"

sudo podman build \
    --from "oci-archive:${ociarchive}" \
    --secret id=yumrepos,src=all.repo \
    -v /etc/pki/ca-trust:/etc/pki/ca-trust:ro \
    --security-opt label=disable \
    --authfile "${pull_secret_file}" \
    -t "${COREOS_FULL}" .

# oc adm release new requires io.openshift.build.versions machine-os value to
# be valid semver. The cosa build may produce versions like "20260428.custom"
# which lack a patch component. Fix the label if needed.
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
# Step 5: Prepare merged auth file
# ============================================================
# Multiple commands need auth for both Red Hat registries (pull secret) and
# quay.io/fpaoline (personal creds). The pull secret already has a "quay.io"
# key for openshift-release-dev, so we add personal creds under a scoped key
# "quay.io/<user>" which takes precedence for that namespace only.
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

# ============================================================
# Step 6: Push the image
# ============================================================
echo "==> Pushing ${COREOS_FULL}..."
sudo podman push --authfile "${merged_auth}" "${COREOS_FULL}"

# ============================================================
# Step 7: Get the digest
# ============================================================
echo "==> Getting image digest..."
DIGEST="$(skopeo inspect --authfile "${merged_auth}" "docker://${COREOS_FULL}" | jq -r .Digest)"
echo "==> Digest: ${DIGEST}"

# ============================================================
# Step 8: Build the custom OCP release
# ============================================================
echo "==> Building custom OCP release: ${RELEASE_IMAGE}"

oc adm release new \
    --from-release="${BASE_RELEASE}" \
    --to-image="${RELEASE_IMAGE}" \
    "rhel-coreos=${COREOS_IMAGE}@${DIGEST}" \
    -a "${merged_auth}"

# ============================================================
# Step 9: Update appliance config with custom release image
# ============================================================
APPLIANCE_DIR="$(cd "${SCRIPTDIR}/.." && pwd)"
base_config="${APPLIANCE_DIR}/appliance-config.yaml.base"

if [[ -f "${base_config}" ]]; then
    yq -y ".ocpRelease.url = \"${RELEASE_IMAGE}\"" "${base_config}" > "${base_config}.tmp" \
        && mv "${base_config}.tmp" "${base_config}"
    echo "==> Updated ${base_config} with ocpRelease.url: ${RELEASE_IMAGE}"
fi

echo ""
echo "============================================================"
echo "Custom release built successfully!"
echo ""
echo "  rhel-coreos image: ${COREOS_FULL}"
echo "  rhel-coreos digest: ${DIGEST}"
echo "  OCP release image: ${RELEASE_IMAGE}"
echo ""
echo "Next steps:"
echo "  cd .. && ./generate_appliance.sh /path/to/pull_secret.json"
echo "============================================================"
