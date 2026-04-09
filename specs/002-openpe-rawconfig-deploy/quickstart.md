# Quickstart: OpenPERouter Deployment Modes

## Default Mode (OpenPE API)

No changes to existing workflow:

```bash
./deploy/devscripts/prepare-env.sh
```

This uses `deploy/config-image-openpe/` with the controller-driven API mode and a minimal raw FRR config that announces the bridge IP.

## Raw Config Mode

Set `USE_RAW` before running the deployment:

```bash
export USE_RAW=true
./deploy/devscripts/prepare-env.sh
```

This uses `deploy/config-image-raw/` and deploys a comprehensive EVPN/VXLAN configuration with three systemd services that run at boot:

1. **setup-underlay** -- derives VTEP IP from br0, moves underlay NIC to FRR namespace
2. **setup-network** -- creates VRFs, bridges, VXLAN interfaces, veth pairs
3. **generate-config** -- renders full FRR configuration from template

### Customizing Raw Config Defaults

Edit `deploy/extras/rawconfig/vpn-setup.env` before deployment:

```bash
# Key settings (dev-scripts defaults shown)
TOR_IP=192.168.111.1    # External FRR peer address
TOR_AS=64512            # External FRR ASN
LOCAL_AS=64514          # Node BGP ASN
UNDERLAY_NIC=eth1       # NIC moved to FRR namespace
VRF_NAME=red
L2_VNI=210
L3_VNI=100
L2_GATEWAY_IP=192.168.110.1/24
```

### Verifying Raw Config Deployment

After the cluster is up, SSH to a node and check:

```bash
# All three services should be "active (exited)"
systemctl status setup-underlay.service
systemctl status setup-network.service
systemctl status generate-config.service

# Generated config should exist
cat /var/lib/openperouter/configs/openpe_evpn.yaml

# Variables file should exist
cat /var/lib/openperouter/vpn-setup.vars
```

## Directory Layout

```
deploy/
├── config-image-openpe/   # Self-contained openpeapi mode (default)
│   ├── generate_machineconfigs.sh
│   ├── openperouter.bu
│   └── registry.bu
├── config-image-raw/      # Self-contained rawconfig mode
│   ├── generate_machineconfigs.sh
│   ├── openperouter-raw.bu
│   └── registry.bu
└── extras/
    ├── quadlets/          # Container/pod/volume quadlet files (shared)
    ├── openpeapi/         # API-driven mode scripts + config
    ├── rawconfig/         # Raw config mode scripts + template + env
    ├── dns/               # DNS workaround (shared)
    └── registry/          # Local registry scripts (shared)
```

Each `config-image-*` folder is self-contained and independently distributable.
