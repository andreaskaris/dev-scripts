#!/bin/bash
# Libvirt forwarding rules (iptables + nftables)

# --- iptables ---

# Create LIBVIRT-FWD chain if it doesn't exist
iptables -N LIBVIRT-FWD 2>/dev/null || iptables -F LIBVIRT-FWD

# Add rules to the LIBVIRT-FWD chain
iptables -A LIBVIRT-FWD -i virbr0 -o virbr0 -j ACCEPT
iptables -A LIBVIRT-FWD -i virbr0 ! -o virbr0 -j ACCEPT
iptables -A LIBVIRT-FWD -o virbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A LIBVIRT-FWD -j RETURN

# Insert jump to LIBVIRT-FWD at the beginning of DOCKER-USER if not already present
if ! iptables -C DOCKER-USER -j LIBVIRT-FWD 2>/dev/null; then
    iptables -I DOCKER-USER 1 -j LIBVIRT-FWD
fi
