Preparation:
==============================

> Note: With regards to dev-scripts, during the installation, you will deal with 2 directories: `/opt/dev-scripts` which is the working dir for dev-scripts
and is used as a cache. And `script_dir` which is `/opt/devel/dev-scripts` and which is the location of the checked out dev-scripts, of `config_${USER}.sh`
and of `pull_secret.json`.

> Note: We run everything as `root`. Additional steps are needed if you are using a local user.

i. Install CentOS 9 (or RHEL 9) on your server. CentOS 10 / RHEL 10 are not compatible with dev-scripts. Select
`Virtualization Host` under `Software Selection` during the installation process. Register the system during or after
installation. The partition holding `/opt` will need a lot of disk space (minimum for the dev-scripts is 80 GB, plus
additional space for the appliance image, etc.), so aim for 500 GB to 1 TB. Update the system after installation.

```
yum update -y
reboot
```

ii. Clone the repositories into `/opt/devel`

```
yum install git -y
mkdir /opt/devel && cd /opt/devel
git clone https://github.com/andreaskaris/dev-scripts.git
pushd dev-scripts && git checkout improvements && popd
git clone https://github.com/openshift-kni/openperouterday0openshift.git
```

iii. Create the USER config (`config_root.sh`):

```
cd /opt/devel/dev-scripts
cp config_example.sh config_$USER.sh
```

Go to https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/, click on your name in the top right, copy the login command, extract the token from the command and use it to set `CI_TOKEN` in `config_$USER.sh`.

Verify:

```
# grep 'export CI_TOKEN' config_${USER}.sh | cut -b-25
export CI_TOKEN='sha256~_
```

Merge `config_perouter.sh` configuration with the user's config:

```
cd /opt/devel/dev-scripts
cat config_perouter.sh >> "config_${USER}.sh"
```

Edit the config if needed:

```
# vim "config_${USER}.sh"
```

The configuration should work _as is_. However, you can modify specific variables if needed. Keep in mind that:

- the default `WORKING_DIR` is `/opt/dev-scripts` - this is another directory than the location of the dev-scripts (`/opt/devel/dev-scripts`)
  and the working directory and actual script directory are 2 entities that should be kept separate.
- Do not use `PULL_SECRET_FILE` if you need to change the location of the pull secret. That var is outdated and will break
  the installation. Instead, `PERSONAL_PULL_SECRET` should be used if the location of the pull secret is different from
 `/opt/devel/dev-scripts/pull_secret.json`
- set `OPENPE_VARIANT` if you are not using `srv6fullconfig`, e.g. `export OPENPE_VARIANT=srv6raw`.
  The variant refers to the folder under https://github.com/openshift-kni/openperouterday0openshift/tree/main. The
  only tested variant that will work without any changes is `srv6fullconfig`, the other variants potentially require various
  tweaks to the dev-scripts.

Save the secret obtained from https://cloud.redhat.com/openshift/install/pull-secret to `/opt/devel/dev-scripts/pull_secret.json`.

> Note: The location of the `pull_secret.json` can be customized with `PERSONAL_PULL_SECRET`. Do _not_ set `PULL_SECRET_FILE`.
It's an internal variable only and is set to `$workdir/pull_secret.json` by default.

iv. Install tools and prerequisites:

```
cd /opt/devel/dev-scripts
yum install -y butane coreos-installer tmux podman pip go ansible-core
./01_install_requirements.sh
```

Deploy:
==============================

Start a `tmux`. Inside the `tmux` session, run the following steps or run `redeploy.sh` (see below).

Build the appliance according to https://github.com/openshift-kni/openperouterday0openshift/blob/main/README.md:

```
cd /opt/devel/openperouterday0openshift/srv6fullconfig/
SSH_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)" appliance/generate_appliance.sh /opt/devel/dev-scripts/pull_secret.json
```

> Note: See `Full cleanup` for cleanup instructions.

Deploy the virtual environment:

```
cd /opt/devel/dev-scripts
deploy/devscripts/prepare-env.sh | tee /tmp/output.log
```

You can also use the following all-in-one script that does a full cleanup (including caches) plus redeployment:

```
./redeploy.sh | tee /tmp/output.log
```

Monitoring / verification:
==============================

The installer is configured to use the VRF for bootstrap-complete and install-complete, so you should be able to follow the install
status without issues.

In case you need to trigger the `wait-for` command manually, you can run:

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

You can verify the overlay status from the `FRR` pod:

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

Remove entries from `/etc/hosts`:

```
vim /etc/hosts
```

In order to clean the appliance image for a full rebuild (e.g. if you change images and need the change
to be reflected in the mirror):

```
rm -rf /opt/devel/openperouterday0openshift/srv6fullconfig/appliance/cache
```
