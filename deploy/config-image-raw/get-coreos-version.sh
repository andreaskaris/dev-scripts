#!/bin/bash
set -euo pipefail

RELEASE_IMAGE="${1:?Usage: $0 <release-image> [pull-secret-file]}"
PULL_SECRET="${2:-${PULL_SECRET:-}}"

AUTH_ARGS=()
if [[ -n "${PULL_SECRET}" ]]; then
  AUTH_ARGS=(--authfile "${PULL_SECRET}")
fi

echo "Getting machine-os-images from ${RELEASE_IMAGE}..."
MOS_IMAGE=$(oc adm release info --image-for=machine-os-images "${RELEASE_IMAGE}")

echo "Querying coreos-stream.json from ${MOS_IMAGE}..."
podman run --rm "${AUTH_ARGS[@]}" --entrypoint="" "${MOS_IMAGE}" cat /coreos/coreos-stream.json | \
  jq '{
    stream: .stream,
    release: .architectures.x86_64.artifacts.metal.release,
    iso_location: .architectures.x86_64.artifacts.metal.formats.iso.disk.location,
    iso_sha256: .architectures.x86_64.artifacts.metal.formats.iso.disk.sha256
  }'
