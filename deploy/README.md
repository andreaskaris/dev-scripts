# Openshift with OpenPERouter

## Appliance

Build an OpenShift appliance ISO with OpenPERouter, registry mirrors, and the ignition hack agent embedded.

### Prerequisites

- `podman`, `coreos-installer`, `jq`, `yq`, `butane`
- A pull secret JSON file (download from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

### Build

```bash
# With pull secret only
./deploy/appliance/generate_appliance.sh /path/to/pull-secret.json

# With pull secret and SSH key
./deploy/appliance/generate_appliance.sh /path/to/pull-secret.json ~/.ssh/id_ed25519.pub
```

The script:

1. Generates `appliance-config.yaml` from `appliance-config.yaml.base`, injecting the pull secret and optional SSH key
2. Runs `openshift-appliance clean` + `build live-iso`
3. Patches the ISO via `patch_appliance.sh` (OpenPERouter content, registry mirrors, hack agent)

Output: `deploy/appliance/appliance.iso`

Base appliance-config can be found under `deploy/appliance/appliance-config.yaml.base`.

### Patch an existing ISO

To patch a pre-built appliance ISO without rebuilding:

```bash
./deploy/appliance/patch_appliance.sh <appliance.iso> <ocp_dir>
```

Where `<ocp_dir>` contains `cache/*/cluster-resources` with IDMS/ITMS YAML files.

## Config Image

Generate the agent config-image ISO that the appliance mounts at first boot. It bundles `install-config.yaml`, `agent-config.yaml`, and MachineConfig manifests (OpenPERouter, DNS, registry).

**Requires:** the appliance to be built first -- the script uses the `openshift-install` binary from `deploy/appliance/cache/`.

### Prerequisites

- `butane`

### Build

```bash
# openpeapi mode (default)
./deploy/config-image-openpe/generate_config_image.sh [config_image_dir]

# rawconfig mode
./deploy/config-image-raw/generate_config_image.sh [config_image_dir]
```

`config_image_dir` defaults to `configimage/` inside the chosen folder. The ISO is written to `<config_image_dir>/agentconfig.noarch.iso`.

The script:

1. Copies `install-config.yaml` and `agent-config.yaml` into the work directory
2. Generates MachineConfig manifests from butane sources via `generate_machineconfigs.sh`
3. Runs `openshift-install agent create config-image`

### Generate MachineConfigs standalone

```bash
./deploy/config-image-openpe/generate_machineconfigs.sh <output_dir>
# or, for rawconfig mode:
./deploy/config-image-raw/generate_machineconfigs.sh <output_dir>
```

Compiles butane sources (`openperouter.bu`, `dns.bu`, `registry.bu`) into MachineConfig YAML manifests without building the full config-image ISO.

## Using it locally with dev-scripts

Prepare a full dev-scripts environment for an agent-based deployment with OpenPERouter bridge networking.

```bash
./deploy/devscripts/prepare-env.sh
```

Run from the repo root. The script:

1. Cleans any previous environment (`clean.sh`)
2. Configures the host and prepares the agent release (`02_configure_host.sh`, `agent/03..05`)
3. Patches agent-config for OpenPERouter bridge networking (`openperouter/patch_agent_config.sh`)
4. Generates MachineConfig manifests into `$WORKING_DIR/ocp/$CLUSTER_NAME/openshift/`
5. Starts the external FRR instance for EVPN peering (`externalfrr/run_frr.sh`)
6. Creates the cluster (`agent/06_agent_create_cluster.sh`)

### Cleanup

```bash
./deploy/devscripts/clean.sh
```

Tears down the external FRR container and networking, then runs `make clean` and `host_cleanup.sh`. Errors are ignored so cleanup proceeds as far as possible.

## Interacting with the cluster

Since the VXLAN tunnel terminates in the `red` VRF on the hypervisor, the cluster API is not reachable from the default network namespace. This means `agent/06_agent_create_cluster.sh` will fail when it tries to wait for the installation to complete. This is expected -- use the commands below to monitor progress and interact with the cluster manually.

All cluster traffic must be prefixed with `sudo ip vrf exec red`.

### SSH into nodes

```bash
sudo ip vrf exec red ssh -i ~/.ssh/id_rsa core@192.168.110.3
```

### kubectl commands

```bash
sudo ip vrf exec red /usr/local/bin/kubectl \
    --kubeconfig=ocp/sno-lab/auth/kubeconfig get nodes
```

### Monitor installation progress

```bash
sudo ip vrf exec red ./ocp/sno-lab/openshift-install agent wait-for install-complete \
    --dir ocp/sno-lab/configimage
```
