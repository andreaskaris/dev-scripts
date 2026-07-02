#!/bin/bash

# Compact (3-node) Agent-Based Deployment with Linux Bridge
# Feature: 001-sno-agent-bridge-config-firstboot-multinode
#
# Usage:
#   cp config_sno_bridge.sh config.sh
#   export CI_TOKEN='your-ci-token-here'
#   make  (or run agent/ scripts individually)
#
# After agent/05_agent_configure.sh, patch agent-config.yaml
# with the linux bridge override before running
# agent/06_agent_create_cluster.sh.
# See specs/001-sno-agent-bridge-config/quickstart.md for details.

# --- WORKING DIRECTORY ---
export WORKING_DIR="${HOME}/dev-scripts-sno"

# --- CLUSTER IDENTITY ---
export CLUSTER_NAME="sno-lab"
export BASE_DOMAIN="example.com"

# --- AGENT-BASED INSTALLER ---
export AGENT_E2E_TEST_SCENARIO="HA_IPV4V6"
export AGENT_E2E_TEST_BOOT_MODE="APPLIANCE_ISO"
export OPENSHIFT_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.22.3-x86_64"

# --- NETWORKING ---
export IP_STACK="v4v6"
export NETWORK_TYPE="OVNKubernetes"
export OVN_LOCAL_GATEWAY_MODE=true
#export EXTERNAL_SUBNET_V4="10.10.0.0/24"

# Extra NIC for external connectivity (no IP assigned inside the guest).
# The subnet is required by libvirt to create the virtual network.
export EXTRA_NETWORK_NAMES="external"
export EXTERNAL_NETWORK_SUBNET_V4='192.168.150.0/24'

# --- NODES ---
# NUM_WORKERS is set by HA scenario (default: 2)

# --- VM RESOURCES ---
export MASTER_MEMORY=32768
export MASTER_VCPU=8
export MASTER_DISK=100

# --- AUTHENTICATION (runtime-resolved, never hardcoded) ---
export SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)
export PULL_SECRET_FILE="${PWD}/openshift_pull.json"
# CI_TOKEN must be exported in the shell environment before running

# --- CONSOLE ACCESS ---
# Enable console login with password for debugging
# Console login: core / debug123
export IGNITION_EXTRA="${PWD}/ignition-password.ign"

# --- BRIDGE / API ACCESS ---
# Resolve api.CLUSTER_DOMAIN to the bridge IP so it's reachable from VRF context
export OPENPE_BRIDGE_IP="192.168.110.2"

# --- CUSTOM KERNEL (pre-built appliance ISO with patched kernel) ---
# This ISO must be the output of prepare_appliance.sh (fully patched)
export APPLIANCE_ISO_PATH="${PWD}/deploy/appliance/appliance.iso"

# --- OPENPEROUTER (rawconfig mode: ISIS + SRv6) ---
export USE_RAW=1
# Pre-load OpenPERouter container images into the appliance disk
#export APPLIANCE_ADDITIONAL_IMAGES="quay.io/openperouter/router:main"
export APPLIANCE_ADDITIONAL_IMAGES="quay.io/fpaoline/openperouter:latestfix1,quay.io/mavazque/ign-converter:latest"
# OpenPERouter quadlets and configs are embedded directly in the appliance
# ISO ignition, so no extra MachineConfig manifests are needed.
# ENABLE_VIRTUAL_INTERFACES is injected via a systemd unit in the ISO.
