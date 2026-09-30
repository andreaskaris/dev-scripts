#!/bin/bash

set -eu
set -o pipefail

OPT_DEVEL="/opt/devel"
OPT_DEVEL_DEVSCRIPTS="${OPT_DEVEL}/dev-scripts"
EXAMPLE_CONFIG_FILE="${OPT_DEVEL_DEVSCRIPTS}/config_example.sh"
PEROUTER_CONFIG_FILE="${OPT_DEVEL_DEVSCRIPTS}/config_perouter.sh"
PULL_SECRET_DESTINATION="${OPT_DEVEL_DEVSCRIPTS}/pull_secret.json"
USER_CONFIG_FILE="${OPT_DEVEL_DEVSCRIPTS}/config_${USER}.sh"
DEV_SCRIPTS_REPOSITORY="https://github.com/andreaskaris/dev-scripts.git"
OPENPEROUTERDAY0_REPOSITORY="https://github.com/openshift-kni/openperouterday0openshift.git"

clone_repositories() {
  if ! command -v git; then
    yum install git -y
  fi

  mkdir -p "${OPT_DEVEL}"
  pushd "${OPT_DEVEL}"

  if ! [ -d dev-scripts ]; then
    git clone "${DEV_SCRIPTS_REPOSITORY}"
  fi
  pushd dev-scripts
  git checkout improvements
  popd

  if ! [ -d openperouterday0openshift ]; then
    git clone "${OPENPEROUTERDAY0_REPOSITORY}"
  fi
  popd

  echo "Repositories created."
  ls -al "${OPT_DEVEL}"
}

prepare_configuration() {
  if [ -f "${USER_CONFIG_FILE}" ]; then
    echo "File ${USER_CONFIG_FILE} already exists. Skipping preparation."
    return
  fi

  local ci_token_file

  echo ""
  echo ""
  echo "Go to https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/"
  echo "Click on your name in the top right, then on 'Copy login command'."
  echo "Extract the token (starting with sha256~...) from the command."
  echo "Paste the token to a file and provide the file's path."
  echo "(If you are using bash, you can \`<CTRL-Z>\`, create the file, and \`fg\` to come back here"
  echo ' Then type the path to the token file)'
  read -r -p "Path to file containing CI_TOKEN: " ci_token_file
  while ! [ -f "${ci_token_file}" ]; do
    read -r -p "File '${ci_token_file}' not found. Path to file containing CI_TOKEN: " ci_token_file
  done

  local token
  token=$(cat "${ci_token_file}" | tr -d '\r' | tr -d '\n')

  cp "${EXAMPLE_CONFIG_FILE}" "${USER_CONFIG_FILE}"
  sed -i "s/^export CI_TOKEN=.*/export CI_TOKEN='${token}'/" "${USER_CONFIG_FILE}"

  grep 'export CI_TOKEN' "${USER_CONFIG_FILE}" | cut -b-25

  cat "${PEROUTER_CONFIG_FILE}" >> "${USER_CONFIG_FILE}"
}

prepare_pull_secret() {
  if [ -f "${PULL_SECRET_DESTINATION}" ]; then
    echo "File ${PULL_SECRET_DESTINATION} already exists. Skipping prepare pull secret step."
    return
  fi

  local pull_secret_file

  echo ""
  echo ""
  echo "Go to https://cloud.redhat.com/openshift/install/pull-secret"
  echo "Copy the pull-secret and write it to a file and provide the file's path."
  echo "If you are using bash, you can \`<CTRL-Z>\`, create the file, and \`fg\` to come back here"
  read -r -p "Path to file containing pull secret: " pull_secret_file
  while ! [ -f "${pull_secret_file}" ]; do
    read -r -p "File '${pull_secret_file}' not found. Path to file containing pull secret: " pull_secret_file
  done

  cp "${pull_secret_file}" "${PULL_SECRET_DESTINATION}"
}

install_prerequisites() {
  pushd "${OPT_DEVEL_DEVSCRIPTS}"
  yum install -y butane coreos-installer tmux podman pip go ansible-core
  ./01_install_requirements.sh
  popd
}

echo "Make sure to update your environment first."
read -r -p "Have you run \`yum update -y && reboot\`? (y/n) " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Please upgrade your system, first."
  exit 1
fi

echo ""
echo ""
echo "## Cloning repositories"
clone_repositories

echo ""
echo ""
echo "## Preparing configuration"
prepare_configuration

echo ""
echo ""
echo "## Preparing pull secret"
prepare_pull_secret

echo ""
echo ""
echo "## Installing prerequisites"
install_prerequisites

echo ""
echo ""
echo "Everything ready for installation."
echo "Start a tmux session and run:"
echo "${OPT_DEVEL_DEVSCRIPTS}/redeploy.sh | tee /tmp/output.log"
