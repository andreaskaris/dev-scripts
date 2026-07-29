Preparation:
==============================

> Note: With regards to dev-scripts, during the installation, you will deal with 2 directories: /opt/dev-scripts which is the working dir for dev-scripts
and is used as a cache. And script_dir which is /opt/devel/dev-scripts and which is the location of the checked out dev-scripts, of config_${USER}.sh
and of pull_secret.json.

i. Install Centos 9 (or RHEL 9) on your server. Centos 10 / RHEL 10 are not compatible with dev-scripts.

ii. Clone the repositories into /opt/devel

```
mkdir /opt/devel && cd /opt/devel
git clone https://github.com/andreaskaris/dev-scripts.git
pushd dev-scripts && git checkout improvements && popd
git clone https://github.com/andreaskaris/openperouterday0openshift.git
pushd openperouterday0openshift && git checkout improvements && popd
```

iii. Follow instructions in https://github.com/openshift-metal3/dev-scripts#preparation about
upgrades, installing dependencies, setting up sudo access (if you aren't running as root), etc.

Then, create your USER config:

```
cd /opt/devel/dev-scripts
cp config_example.sh config_$USER.sh
```

And follow https://github.com/openshift-metal3/dev-scripts#configuration to set up your pull secret.

Store the pull_secret.json in /opt/devel/dev-scripts/pull_secret.json. And your config_$USER.sh should contain
a token starting with sha256:

```
# grep 'export CI_TOKEN' config_root.sh | cut -b-25
export CI_TOKEN='sha256~_
```

> Note: The location of the pull_secret.json can be customized with PERSONAL_PULL_SECRET. Do _not_ set PULL_SECRET_FILE.
It's an internal variable only and is set to $workdir/pull_secret.json by default.

iv. Install further prerequisites as well as tmux:

```
cd /opt/devel/dev-scripts
./01_install_requirements.sh
# install other stuff that might be missing
yum install -y butane coreos-installer tmux podman pip go
python -m pip install 'yq>=3,<4'
```

v. Merge fede's configuration with the user's and edit the config as needed:

```
cd /opt/devel/dev-scripts
cat config_perouter.sh >> "config_${USER}.sh"
vim "config_${USER}.sh"
```

IMPORTANT:
- set WORKING_DIR to /opt/dev-scripts
- Do not use PULL_SECRET_FILE - that var is outdated and will break the installation. Instead, PERSONAL_PULL_SECRET should
  be used if the location of the pull secret is different from /opt/devel/dev-scripts/pull_secret.json
- add OPENPE_VARIANT before the DAY0 line and set it to your variant, e.g. `export OPENPE_VARIANT=srv6fullconfig`
- set OPENPEROTUER_DAY0_OPENSHIFT to "/opt/devel/openperouterday0openshift/${OPENPE_VARIANT:-srv6fullconfig}"

Deploy:
==============================

Build the appliance according to https://github.com/openshift-kni/openperouterday0openshift/blob/main/README.md

```
cd /opt/devel/openperouterday0openshift/srv6fullconfig/
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" appliance/generate_appliance.sh /opt/devel/dev-scripts/pull_secret.json
```

> Note: See `Full cleanup` instructions if you need to change e.g. images.

Start a tmux. Inside the tmux session, run:

```
cd /opt/devel/dev-scripts
deploy/devscripts/prepare-env.sh | tee /tmp/output.log
```

Monitoring / verification:
==============================

The installer is configured to use the VRF for bootstrap-complete and install-complete, so you should be able to follow the install
status without issues.

```
cd /opt/devel/dev-scripts
ip vrf exec red ./ocp/sno-lab/openshift-install agent wait-for install-complete --dir ocp/sno-lab/configimage --log-level=debug
```

Verify the OpenShift cluster status with:

```
export KUBECONFIG=/opt/devel/dev-scripts/ocp/sno-lab/configimage/auth/kubeconfig
ip vrf exec red oc get nodes
ip vrf exec red oc get clusterversion
ip vrf exec red oc get co
```

You can verify the overlay status from the FRR pod:

```
for cmd in "show isis neighbor" "show bgp summary" "show bgp ipv4 vpn" "show segment-routing srv6 locator"; do podman exec -it externalfrr vtysh -c "$cmd"; done
``` 

And on the nodes themselves:

```
ssh core@192.168.150.20 # for master-0
sudo -i
for cmd in "show isis neighbor" "show bgp summary" "show bgp ipv4 vpn" "show segment-routing srv6 locator"; do podman exec -it frr vtysh -c "$cmd"; done
```

Full cleanup:
==============================

To do a full cleanup (contrary to a partial cleanup that still leaves the registry and virtual machines, etc.), run:

```
cd /opt/devel/dev-scripts/
deploy/devscripts/clean.sh
make registry_cleanup podman_cleanup
rm -Rf /opt/dev-scripts/
rm -f /var/lib/libvirt/images/*
rm -f /opt/devel/dev-scripts/logs/*
```

Remove entries from /etc/hosts:

```
vim /etc/hosts
```

In order to clean the appliance image for a full rebuild (e.g. if you change images and need the change
to be reflected in the mirror):

```
rm -rf /opt/devel/openperouterday0openshift/srv6fullconfig/appliance/cache
```
