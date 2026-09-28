#!/bin/bash

cd /opt/devel/dev-scripts/
deploy/devscripts/clean.sh
make registry_cleanup podman_cleanup
rm -Rf /opt/dev-scripts/
rm -f /var/lib/libvirt/images/*
rm -f /opt/devel/dev-scripts/logs/*

# Comment this if you do not want a full rebuild of the appliance image.
rm -rf /opt/devel/openperouterday0openshift/srv6fullconfig/appliance/cache

cd /opt/devel/openperouterday0openshift/srv6fullconfig/
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" appliance/generate_appliance.sh /opt/devel/dev-scripts/pull_secret.json

cd /opt/devel/dev-scripts
deploy/devscripts/prepare-env.sh
