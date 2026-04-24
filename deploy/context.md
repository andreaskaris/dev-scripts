## Current status

Under extras/rawconfig you can find:

## FRR configuration

openpe_evpn.yaml.template + vpn-setup.env 

This is an frr configuration that gets added to openperouter via a systemd unit

## Host configuratoins

setup-network.sh and setup-underlay.sh
required to setup the underlay network and the evpn overlays.


## The ask 

Read them and note I want to switch to a dual stack setup based on
https://github.com/fedepaol/srv6lab/tree/srv6evpn

where one master is the route reflector PE and the other two masters will act as other
route reflectors.

You can then adjust the configuration in devscripts/externalfrr to implement isis and srv6
looking at https://github.com/fedepaol/srv6lab/tree/srv6evpn/remotepe and
https://github.com/fedepaol/srv6lab/tree/srv6evpn/tor (in this case we have a single external router to
test with)
