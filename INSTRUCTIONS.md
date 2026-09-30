## Instructions

These are the short instructions for setting up a RHEL 9 system as a hypervisor of the virtual environment. For
more details, see INSTRUCTIONS_MANUAL.md.

i. Install CentOS 9 (or RHEL 9) on your server. CentOS 10 / RHEL 10 are not compatible with dev-scripts. Select
`Virtualization Host` under `Software Selection` during the installation process. Register the system during or after
installation. The partition holding `/opt` will need a lot of disk space (minimum for the dev-scripts is 80 GB, plus
additional space for the appliance image, etc.), so aim for 500 GB to 1 TB. Update the system after installation.

```
yum update -y
reboot
```

ii. Download the prepare.sh script and run it **as user root**:

```
curl -O https://raw.githubusercontent.com/andreaskaris/dev-scripts/refs/heads/improvements/prepare.sh
chmod +x prepare.sh
./prepare.sh
```

Follow the instructions.

iii. Deploy the virtual environment (ideally inside a tmux session as this will take a while) **as user root**:

```
cd /opt/devel/dev-scripts
./redeploy.sh | tee /tmp/output.log
```

iv. Verify the OpenShift cluster status with:

```
export KUBECONFIG=/opt/devel/dev-scripts/ocp/sno-lab/configimage/auth/kubeconfig
ip vrf exec red oc get nodes
ip vrf exec red oc get clusterversion
ip vrf exec red oc get co
```

See [INSTRUCTIONS_MANUAL.md](INSTRUCTIONS_MANUAL.md) for further verification commands.
