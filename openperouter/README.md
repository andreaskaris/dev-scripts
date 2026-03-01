# OpenPERouter + OpenShift Appliance

Deploy OpenShift Single Node OpenShift (SNO) with OpenPERouter pre-installed using appliance disk images.

## Quick Start

### Option 1: Complete Automated Deployment (Easiest)

```bash
# 1. Build appliance image (one time, ~60 minutes)
./build-image.sh

# 2. Deploy with dev-scripts (uses the appliance)
./deploy-with-appliance.sh sno-router
```

That's it! Wait ~30-40 minutes for installation to complete.

### Option 2: Manual Control

```bash
# 1. Build appliance image
./build-image.sh

# 2. Run dev-scripts steps manually
cd ../agent
./01_agent_requirements.sh
./02_configure_host.sh

# 3. Replace VM disk with appliance
cd ..
./openperouter/use-appliance-image.sh sno-router openperouter/output/appliance-image.raw

# 4. Continue deployment
cd agent
./03_agent_build_installer.sh
./04_agent_prepare_release.sh
./05_agent_configure.sh
./06_agent_create_cluster.sh
```

## What Gets Deployed

After deployment, your OpenShift node includes:

- ✅ **OpenPERouter Controller** - Manages routing configuration
- ✅ **FRR Routing Daemon** - BGP/EVPN routing
- ✅ **Configuration Reloader** - Hot-reload FRR config without restarts
- ✅ **Node Configuration** - Located at `/var/lib/openperouter/node-config.yaml` with `nodeIndex: 1`
- ✅ **All Container Images** - Pre-loaded (no download needed)

**Systemd Services:**
- `controllerpod.service` - Controller pod
- `routerpod.service` - Router pod
- `frr.service` - FRR daemon
- `reloader.service` - Config reloader

## Scripts

| Script | Purpose |
|--------|---------|
| `build-image.sh` | Build appliance disk image (uses container) |
| `deploy-with-appliance.sh` | Complete deployment workflow |
| `use-appliance-image.sh` | Replace VM disk with appliance |
| `build-appliance.sh` | Generate OpenPERouter MachineConfig |

## Prerequisites

```bash
# Install tools
sudo dnf install podman butane libvirt qemu-kvm virt-install

# Get pull secret
# Download from: https://console.redhat.com/openshift/install/pull-secret
# Save to: ../openshift_pull.json
```

## How It Works

### Building the Appliance

`build-image.sh` uses a containerized builder to create a disk image containing:

1. **CoreOS** - Base operating system
2. **Container Registry** - Internal registry with all OCP images (~20GB)
3. **OpenPERouter Image** - Pre-loaded `quay.io/openperouter/router:main`
4. **MachineConfig** - Systemd quadlets and configuration

**Build time**: 30-60 minutes (first time), 15-30 minutes (subsequent)
**Output**: `output/appliance-image.raw` (~40-50GB)

### Deploying with dev-scripts

The appliance integrates with dev-scripts by replacing the VM disk:

```
dev-scripts creates VM with empty disk
         ↓
use-appliance-image.sh replaces disk with appliance
         ↓
VM boots from appliance (all images pre-loaded)
         ↓
Config ISO customizes the installation
         ↓
OpenShift + OpenPERouter ready!
```

## Deployment Workflow

```
┌─────────────────────────┐
│  build-image.sh         │  ← Run once
│  • Pulls container      │
│  • Downloads OCP images │
│  • Creates disk image   │
└───────────┬─────────────┘
            │
            │ output/appliance-image.raw
            ↓
┌─────────────────────────────────┐
│  deploy-with-appliance.sh       │  ← Deploy many times
│                                 │
│  Steps executed:                │
│  1. Install requirements        │
│  2. Configure host              │
│  3. 🎯 Replace disk             │
│  4. Build installer             │
│  5. Configure cluster           │
│  6. Create cluster              │
└───────────┬─────────────────────┘
            │
            ↓
┌─────────────────────────┐
│  OpenShift + OpenPERouter│
│  Ready in ~30-40 min    │
└─────────────────────────┘
```

## Customization

### Change Node Index

Edit `openperouter-appliance.bu` before building:

```yaml
# Change this line:
nodeIndex: 1

# To:
nodeIndex: 5
```

Then rebuild:
```bash
./build-appliance.sh  # Regenerate MachineConfig
./build-image.sh      # Rebuild appliance
```

### Change OpenShift Version

Edit `appliance-config.yaml`:

```yaml
ocpRelease:
  version: 4.18  # Change version here
  channel: stable
```

Then rebuild:
```bash
./build-image.sh
```

### Add More Container Images

Edit `appliance-config.yaml`:

```yaml
additionalImages:
  - name: quay.io/openperouter/router:main
  - name: quay.io/myorg/myimage:latest  # Add more here
```

## Verification

After deployment completes:

```bash
# Set kubeconfig
export KUBECONFIG=../ocp/sno-router/auth/kubeconfig

# Check cluster
oc get nodes
oc get co

# SSH to node
NODE_IP=$(oc get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
ssh core@${NODE_IP}

# Check OpenPERouter services
sudo systemctl status controllerpod.service
sudo systemctl status routerpod.service
sudo podman ps

# View configuration
cat /var/lib/openperouter/node-config.yaml

# Check logs
sudo journalctl -u controller.service -f
```

## Multiple Deployments

Reuse the same appliance image for multiple clusters:

```bash
# Deploy cluster 1
./deploy-with-appliance.sh site-1

# Deploy cluster 2 (reuses same image!)
./deploy-with-appliance.sh site-2

# Deploy cluster 3
./deploy-with-appliance.sh site-3
```

## Why Use Appliances?

**Advantages:**
- ✅ **Offline capable** - All images pre-loaded
- ✅ **Faster deployments** - No image downloads (~20GB saved)
- ✅ **Reproducible** - Same image = identical deployments
- ✅ **Edge-friendly** - Minimal bandwidth needed
- ✅ **Build once, deploy many** - Reuse the same image

**Best for:**
- Edge deployments
- Air-gapped environments
- Multiple site deployments
- Bandwidth-constrained locations

## Troubleshooting

### Build Issues

**Problem**: Out of disk space

```bash
# Check space
df -h

# Clean up
podman system prune -a

# Build to different location
OUTPUT_DIR=/mnt/large-disk/output ./build-image.sh
```

**Problem**: Container pull fails

```bash
# Check podman
podman --version

# Pull manually
podman pull quay.io/edge-infrastructure/openshift-appliance:latest
```

### Deployment Issues

**Problem**: Can't find appliance image

```bash
# Check it exists
ls -lh openperouter/output/appliance-image.raw

# Use absolute path
./deploy-with-appliance.sh sno-router $(pwd)/openperouter/output/appliance-image.raw
```

**Problem**: VM won't start

```bash
# Check VM status
sudo virsh list --all

# Check logs
sudo journalctl -u libvirtd -f

# Verify disk was replaced
qemu-img info /opt/dev-scripts/pool/sno-router_master_0.qcow2
```

**Problem**: Installation hangs

```bash
# Check bootstrap progress
ssh core@192.168.111.10
sudo journalctl -u bootkube.service -f

# Check for failed services
sudo systemctl --failed
```

## File Structure

```
openperouter/
├── README.md                      # This file
├── build-image.sh                 # Build appliance (containerized)
├── deploy-with-appliance.sh       # Complete deployment workflow
├── use-appliance-image.sh         # Replace VM disk with appliance
├── build-appliance.sh             # Generate MachineConfig
│
├── appliance-config.yaml          # Appliance build configuration
├── openperouter-appliance.bu      # Butane config (human-readable)
├── 99-master-openperouter.yaml    # Generated MachineConfig
│
├── quadlets/                      # Systemd quadlet definitions
│   ├── controllerpod.pod
│   ├── controller.container
│   ├── routerpod.pod
│   ├── frr.container
│   ├── reloader.container
│   └── frr-sockets.volume
│
├── examples/                      # Example configs
│   ├── install-config-sno.yaml
│   └── agent-config-sno.yaml
│
└── output/                        # Build output (created by build-image.sh)
    └── appliance-image.raw
```

## Cleanup

```bash
# Remove cluster
sudo virsh destroy sno-router_master_0
sudo virsh undefine sno-router_master_0 --nvram

# Remove disk
rm /opt/dev-scripts/pool/sno-router_master_0.qcow2

# Or use dev-scripts cleanup
cd /path/to/dev-scripts
make clean
```

## Configuration Files

### appliance-config.yaml
Defines the appliance build:
- OpenShift version
- Disk size
- Container images to pre-load

### openperouter-appliance.bu
Butane configuration with:
- OpenPERouter quadlet files
- Node configuration file
- Required directories
- Service enablement

Converted to MachineConfig by `build-appliance.sh`.

## Time Estimates

| Task | Duration |
|------|----------|
| Build appliance (first time) | 30-60 min |
| Build appliance (subsequent) | 15-30 min |
| Deploy with dev-scripts | 30-40 min |
| **Total (first deployment)** | **~90 min** |
| **Total (subsequent)** | **~45 min** |

## Resources

- **OpenShift Appliance**: https://github.com/openshift/appliance
- **dev-scripts**: https://github.com/openshift-metal3/dev-scripts
- **OpenPERouter**: https://github.com/openperouter
- **Agent-based Installer**: https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/

## Support

For issues:
- dev-scripts: https://github.com/openshift-metal3/dev-scripts/issues
- OpenPERouter: https://github.com/openperouter/issues
- OpenShift Appliance: https://github.com/openshift/appliance/issues

---

**Quick Reference:**

```bash
# Build once
./build-image.sh

# Deploy many times
./deploy-with-appliance.sh sno-router

# Access cluster
export KUBECONFIG=../ocp/sno-router/auth/kubeconfig
oc get nodes
```

🚀 Happy deploying!
