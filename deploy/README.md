# OpenPERouter on OpenShift — Day-0 Deployment

Day-0 deployment of [OpenPERouter](https://github.com/openshift/openperouter) on
bare-metal OpenShift clusters using the appliance installer. OpenPERouter is
baked into the appliance ISO and configured via MachineConfig, so networking is
ready from first boot — no post-install operators needed.

## Deployments

| Directory | Underlay | Overlay | Config method | Route distribution |
|-----------|----------|---------|---------------|--------------------|
| [`srv6raw/`](srv6raw/) | ISIS | SRv6 + VXLAN | Rawconfig (shell templates) | EVPN route reflector (master-0) |
| [`evpnfullconfig/`](evpnfullconfig/) | eBGP | VXLAN only | Controller (`openpe_config.yaml`) | TOR distributes all routes |

Each directory contains its own [TOPOLOGY.md](srv6raw/TOPOLOGY.md) with full addressing and peering details.

## How it works

1. **`appliance/generate_appliance.sh`** builds a RHCOS appliance ISO with
   OpenPERouter quadlets, registry mirrors, and DNS overrides embedded
2. **`configimage/generate_config_image.sh`** produces a config-image ISO with
   install-config, agent-config, and MachineConfig manifests (rendered from butane)
3. Nodes boot from the appliance ISO, mount the config-image, and install
   OpenShift with OpenPERouter networking active from the start

Both scripts take a pull secret file as the first argument. See each
deployment's README for build commands and configuration details.


## How to deploy

- Choose your variant. It will drive the choice of `openperouterday0openshift/srv6raw` or
`openperouterday0openshift/evpnfullconfig`.
- Build the appliance iso with `SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" ./generate_appliance.sh ~/devel/dev-scripts/openshift_pull.json` locally from the variant of choice
- Get back to the root
- Clean any previous deployment with `deploy/devscripts/clean.sh`
- Redeploy with `deploy/devscripts/prepare-env.sh`

## NOTE

The cluster is accessible from an evpn (or srv6) tunnel from the red vrf on the hypervisor
This means that in order to monitor the deployment, you must run

```bash
sudo ip vrf exec red ./ocp/sno-lab/openshift-install agent wait-for install-complete --dir ocp/sno-lab/configimage
```

Similarly, to access the cluster you must run

```bash
sudo ip vrf exec red /usr/local/bin/kubectl --kubeconfig=/home/fpaoline/devel/dev-scripts/ocp/sno-lab/configimage/auth/kubeconfig get nodes
```


## Checking the nodes

You can ssh in the nodes using the secondary interface, ie

```bash
ssh core@192.168.150.20
```

## Pre requisites

The current version requires:

- disabling selinux on the hypervisor
- running [./libvirt-iptables-rules.sh](iptables-rules.sh) if docker is running on this host
