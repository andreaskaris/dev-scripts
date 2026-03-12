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
export AGENT_E2E_TEST_SCENARIO="COMPACT_IPV4"
export AGENT_E2E_TEST_BOOT_MODE="APPLIANCE_ISO"
export OPENSHIFT_VERSION=4.20.16
export OPENSHIFT_RELEASE_STREAM=4.20
export OPENSHIFT_RELEASE_TYPE="ga"

# --- NETWORKING ---
export IP_STACK="v4"
export NETWORK_TYPE="OVNKubernetes"
#export EXTERNAL_SUBNET_V4="10.10.0.0/24"

# Extra network for external connectivity (adds a third NIC to the VM)
export EXTRA_NETWORK_NAMES="external"
export EXTERNAL_NETWORK_SUBNET_V4='192.168.150.0/24'

# Allow the bridge subnet to reach the host's chronyd for NTP sync
export CHRONY_EXTRA_ALLOW_SUBNETS="192.168.110.0/24"

# --- VM RESOURCES ---
# Explicit values matching the COMPACT_IPV4 preset to document intent
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

# --- OPENPEROUTER ---
# Pre-load OpenPERouter container images into the appliance disk
#export APPLIANCE_ADDITIONAL_IMAGES="quay.io/openperouter/router:main"
export APPLIANCE_ADDITIONAL_IMAGES="quay.io/fpaoline/router:dev3"
# OpenPERouter quadlets and configs are embedded directly in the appliance
# ISO ignition, so no extra MachineConfig manifests are needed.
# ENABLE_VIRTUAL_INTERFACES is injected via a systemd unit in the ISO.
