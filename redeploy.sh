#!/bin/bash

set -eu
set -o pipefail

OPT_DEVEL_DEVSCRIPTS="/opt/devel/dev-scripts"
OPT_DEVSCRIPTS="/opt/dev-scripts"
VAR_LIB_LIBVIRT_IMAGES="/var/lib/libvirt/images/"
OPT_DEVEL_OPENPEROUTERDAY0OPENSHIFT="/opt/devel/openperouterday0openshift"
PULL_SECRET_DESTINATION="${OPT_DEVEL_DEVSCRIPTS}/pull_secret.json"
USER_CONFIG_FILE="${OPT_DEVEL_DEVSCRIPTS}/config_${USER}.sh"
SSH_PUB_KEY_PATH="${HOME}/.ssh/id_rsa.pub"

source "${USER_CONFIG_FILE}"
FLAVOR_DIRECTORY="${OPT_DEVEL_OPENPEROUTERDAY0OPENSHIFT}/${OPENPE_VARIANT}/"
if [ ! -d "${FLAVOR_DIRECTORY}" ]; then
  echo "Could not find directory '${FLAVOR_DIRECTORY}'"
  echo "Is openpe variant '${OPENPE_VARIANT}' correct?"
  exit 1
fi

cleanup_dev_scripts() {
  pushd "${OPT_DEVEL_DEVSCRIPTS}"
  deploy/devscripts/clean.sh
  make registry_cleanup podman_cleanup
  rm -Rf "${OPT_DEVSCRIPTS}"
  rm -f "${VAR_LIB_LIBVIRT_IMAGES}"/*
  rm -f "${OPT_DEVEL_DEVSCRIPTS}"/logs/*
  popd
}

cleanup_appliance_cache() {
  rm -rf "${FLAVOR_DIRECTORY}/appliance/cache"
}

generate_appliance_image() {
  pushd "${FLAVOR_DIRECTORY}"
  SSH_PUB_KEY="$(cat "${SSH_PUB_KEY_PATH}")" appliance/generate_appliance.sh "${PULL_SECRET_DESTINATION}"
  popd
}

prepare_environment() {
  pushd "${OPT_DEVEL_DEVSCRIPTS}"
  deploy/devscripts/prepare-env.sh
  popd
}

echo "# Cleaning up dev scripts"
cleanup_dev_scripts

echo ""
echo ""
echo "# Cleaning up appliance cache"
cleanup_appliance_cache

echo ""
echo ""
echo "# Generating appliance image"
generate_appliance_image

echo ""
echo ""
echo "# Preparing environment"
prepare_environment
