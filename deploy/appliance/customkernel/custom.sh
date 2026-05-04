#!/bin/bash

DIGEST=$(skopeo inspect docker://quay.io/mavazque/rhel-coreos:9.6.20260306-0-kernel-5.14.0-570.76.1.5114_2224397254 | jq -r .Digest)
# Build a custom release with this rhel-coreos image
oc adm release new --from-release=quay.io/openshift-release-dev/ocp-release:4.20.12-x86_64 --to-image=quay.io/mavazque/ocp-release:4.20.12-x86_64-kernel-5.14.0-570.76.1.5114_2224397254 rhel-coreos=quay.io/mavazque/rhel-coreos@${DIGEST} -a ../../../pull_secret.json

