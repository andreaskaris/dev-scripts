# SRv6 + ISIS + BGP EVPN Debugging Summary

## Setup

- **3 OpenShift master nodes** (VMs via libvirt): 192.168.150.20/21/22
  - FRR 10.5.1 running in containers (`frr`), each with its own network namespace
  - Underlay NIC (`enp2s0`) moved into the FRR namespace
  - VRF `red` (table 1100) with bridge `br-pe-210` connected via veth to host's `br0`
  - VXLAN VNI 210 for L2 EVPN overlay
- **External FRR** on the hypervisor host: container `externalfrr` with `--network=host`
  - VRF `red` with loopback `lored` (10.10.20.1/32)
  - DNS server for cluster access
- **ISIS** as underlay IGP (level-1, area 49.0001)
- **SRv6 with uSID** for L3VPN data plane (locator per node: `fd00:{node}::/48`)
- **BGP EVPN** (AS 65500, iBGP): master-0 is the route reflector

### Node addressing

| Node | Router ID | Loopback IPv6 | SRv6 Source | SRv6 Locator | br0 IP |
|------|-----------|---------------|-------------|--------------|--------|
| master-0 (RR) | 10.0.0.2 | fc00:0:2::1 | fd00:2::1 | fd00:2::/48 | 192.168.110.2 |
| master-1 | 10.0.0.3 | fc00:0:3::1 | fd00:3::1 | fd00:3::/48 | 192.168.110.3 |
| master-2 | 10.0.0.4 | fc00:0:4::1 | fd00:4::1 | fd00:4::/48 | 192.168.110.4 |
| external FRR | 10.0.0.20 | fc00:0:20::1 | fd00:20::1 | fd00:20::/48 | — |

## Issues found and fixed

### 1. ISIS LSP fragmentation bug — `BUG: could not fragment own LSP`

**Symptom**: All master node LSPs were 27 bytes (empty, header-only). No ISIS routes, no BGP.

**Root cause**: 6 ISIS nodes on the LAN (3 masters + 2 workers + 1 external FRR) = 5 neighbors per node. Each neighbor generated both MPLS Lan-Adjacency-SID sub-TLVs (~13 bytes) and SRv6 End.X SID sub-TLVs (~36 bytes). Total per-neighbor: ~49 bytes × 5 = ~245 bytes, hitting the 255-byte sub-TLV length limit. FRR's fragmentation code failed and produced empty LSPs.

**Fix**:
- Removed `segment-routing on` (MPLS SR) from all FRR configs — only SRv6 is needed. This eliminated the MPLS Lan-Adjacency-SID sub-TLVs, reducing per-neighbor cost to ~36 bytes.
- Added `NUM_WORKERS=0` to `config_fpaoline.sh` to prevent workers from joining ISIS.
- Applied live fix via `fix-isis.sh` (vtysh `no segment-routing on` on all masters).

**Files changed**:
- `extras/rawconfig/openpe_evpn.yaml.template` — removed `segment-routing on`
- `extras/rawconfig/openpe_evpn.yaml_rr.template` — removed `segment-routing on`
- `devscripts/externalfrr/run_frr.sh` — removed `segment-routing on`
- `config_fpaoline.sh` — added `NUM_WORKERS=0`

**Result**: All master LSPs expanded to 437 bytes with full TLVs. ISIS routes populated. BGP between masters established.

### 2. External FRR loopback not advertised in ISIS

**Symptom**: BGP from external FRR to master-0 (RR) stuck at "Active/Connect". Masters couldn't reach `fc00:0:20::1`.

**Root cause**: External FRR's loopback addresses (`fc00:0:20::1`, `fd00:20::1`, `10.0.0.20`) were on the `lo-vtep` dummy interface, but ISIS was only configured on `interface lo` (kernel loopback) and `interface sno-labbm`. The loopback prefixes were never advertised into ISIS.

**Fix**: Added `lo-vtep` (renamed to `lo-und`) as a passive ISIS interface in the FRR config.

**Files changed**:
- `devscripts/externalfrr/run_frr.sh` — added `interface ${VTEP_LO}` with `ip/ipv6 router isis PE` + `isis passive`; renamed `VTEP_LO` from `lo-vtep` to `lo-und`

**Result**: `fc00:0:20::1/128` appeared in ISIS database. BGP session established. VPN routes exchanged (all 4 prefixes visible in BGP IPv4 VPN table).

### 3. VRF strict mode not enabled — End.DT46 seg6local route not installed

**Symptom**: `show segment-routing srv6 sid` showed `fd00:X:0:1:: uDT46 VRF 'red'` allocated, but no corresponding `seg6local End.DT46` route in the kernel.

**Root cause**: `net.vrf.strict_mode=0`. The kernel requires `strict_mode=1` to install SRv6 `End.DT46` seg6local routes. FRR zebra logged: `Strict mode for VRF is disabled` and `Failed to install Nexthop`.

**Fix**: Set `net.vrf.strict_mode=1` via nsenter into FRR container's network namespace, then bounced the `sid vpn per-vrf export auto` config to re-trigger SID installation.

**Files changed**:
- `extras/rawconfig/setup-network.sh` — moved `sysctl -w net.vrf.strict_mode=1` here (after VRF creation, so kernel module is loaded)
- `devscripts/externalfrr/run_frr.sh` — added `sudo sysctl -w net.vrf.strict_mode=1`

**Note**: Originally placed in `setup-underlay.sh` (before VRF creation), which failed with `cannot stat /proc/sys/net/vrf/strict_mode: No such file or directory` because the VRF kernel module isn't loaded until the first VRF device is created.

**Result**: `End.DT46 vrftable 1100` seg6local routes now installed in kernel on all nodes.

### 4. rp_filter dropping decapsulated SRv6 packets

**Symptom**: End.DT46 routes installed, but VRF red pings still fail. No drops incrementing on interfaces. ICMP `InEchos` counter stays at 0 on master-0 despite SRv6 packets arriving on the wire.

**Root cause**: `net.ipv4.conf.red.rp_filter=1` (strict mode). After End.DT46 decapsulates a packet, the kernel sets `skb->dev` to the VRF device `red` (confirmed by nftables counters at priority -400: all decapsulated packets have `iifname "red"`, zero on `enp2s0`/`br-pe-210`/`lo`). The kernel then calls `ip_route_input(skb, iph->daddr, iph->saddr, 0, skb->dev)` where `skb->dev = red`. Strict rp_filter checks the reverse path for the source IP (`10.10.20.1`), which goes via `enp2s0` (SRv6 encap) — not `red`. Interface mismatch → packet dropped silently. rp_filter is IPv4-only (no IPv6 equivalent sysctl).

**Verified by kernel source**: In [`net/ipv6/seg6_local.c`](https://github.com/torvalds/linux/blob/master/net/ipv6/seg6_local.c), `input_action_end_dt4()` calls `end_dt_vrf_core()` → `end_dt_vrf_rcv()` → `vrf->l3mdev_ops->l3mdev_l3_rcv()`, which sets `skb->dev` to the VRF device. The subsequent `ip_route_input()` call runs `fib_validate_source()` (rp_filter) against this device.

**Verified empirically**: With `rp_filter=0`, ping works. Setting `rp_filter=1` on just the `red` device immediately breaks ping, even though nftables counters (at raw priority, before rp_filter) confirm packets still arrive. Restoring `rp_filter=0` restores ping.

**Key subtlety**: Setting `all=0` and `default=0` is not sufficient. The effective rp_filter value is `MAX(all, per-device)`. New VRF devices inherit `rp_filter=1` at creation time regardless of the `default` setting if `default` was set after the device was created, or if the device was created before `default` was changed. The per-device value must be explicitly set to 0.

**Fix**: Disabled rp_filter on `all`, `default`, AND the per-VRF-device in both external FRR and master nodes.

**Files changed**:
- `extras/rawconfig/setup-network.sh` — added `infrr sysctl -w net.ipv4.conf.all.rp_filter=0`, `net.ipv4.conf.default.rp_filter=0`, and `net.ipv4.conf.${VRF_NAME}.rp_filter=0` (after VRF creation)
- `devscripts/externalfrr/run_frr.sh` — added per-VRF-device `sysctl -w net.ipv4.conf.${VRF_NAME}.rp_filter=0`

**Result**: rp_filter fixed, but ping still failing on external FRR — packets being dropped by firewalld (see issue #5). Master nodes don't have this issue (no nftables in FRR namespace).

### 5. firewalld conntrack dropping SRv6-decapsulated packets (`ct state invalid`)

**Symptom**: SRv6 data plane fully working end-to-end (confirmed by tcpdump: encapped request leaves host, arrives at master-0, reply encapped back, arrives at external FRR, End.DT46 decaps into VRF red, tcpdump on `red` shows ICMP echo replies) — but `ping` reports 100% loss. ICMP `InEchoReps` counter never increments.

**Root cause**: firewalld's `filter_INPUT` chain (nftables, `table inet firewalld`, priority `filter+10`) contains:
```
ct state { established, related } accept
ct status dnat accept
iifname "lo" accept
ct state invalid drop          ← THIS DROPS THE PACKETS
jump filter_INPUT_POLICIES     ← trusted zone for "red" is here, never reached
```
SRv6-decapsulated ICMP replies enter VRF `red` without a matching conntrack entry — the outgoing ping created conntrack for the outer IPv6/SRv6 flow, not the inner IPv4 ICMP. Conntrack marks the inner packets as `invalid`, and firewalld drops them before the trusted zone policy can accept them.

**Key debugging insight**: nftables `accept` in one chain does NOT skip other chains at the same hook. An `accept` at priority `filter+5` still allows firewalld's `ct state invalid drop` at `filter+10` to fire. The fix required bypassing conntrack entirely.

**Fix**: Add a `notrack` rule at `raw` priority for all traffic on the VRF device. This prevents conntrack from tracking VRF red packets, so they appear as `ct state untracked` (not `invalid`) and pass through firewalld's rules.

```nft
table inet srv6-vrf-notrack {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        iifname "red" notrack
    }
    chain output {
        type filter hook output priority raw; policy accept;
        oifname "red" notrack
    }
}
```

**Files changed**:
- `devscripts/externalfrr/run_frr.sh` — added nftables `srv6-vrf-notrack` table creation after VRF setup

**Result**: `sudo ip vrf exec red ping 192.168.110.2` works — full SRv6 L3VPN connectivity confirmed.

### 6. DNS/NTP server IP not advertised into BGP — nodes can't reach `10.100.0.1`

**Symptom**: Nodes configured with `10.100.0.1` as DNS/NTP server, but `ping 10.100.0.1` from master-0 fails (100% loss). chronyd shows `Reach=0` for `10.100.0.1`. NTP validation fails during agent discovery, blocking cluster installation.

**Root cause**: The DNS (dnsmasq) and NTP (chronyd) servers on the external FRR hypervisor both listen on `10.100.0.1`, which is assigned to the `lo-extra` dummy interface in VRF red. However, only `10.10.20.1/32` (on `lored`) was announced into BGP L3VPN — `10.100.0.1/32` was never advertised. Nodes had no route to it via the SRv6 overlay.

**Fix**: Added `network 10.100.0.1/32` (via `${LO_IP}`) to the external FRR's `router bgp 65500 vrf red` → `address-family ipv4 unicast` config, so the prefix is advertised as a VPN route and reachable via SRv6 from all nodes.

**Files changed**:
- `devscripts/externalfrr/run_frr.sh` — added `network ${LO_IP}` in BGP VRF red address-family ipv4 unicast; also added chronyd NTP server in VRF red (same listen address as DNS)
- `devscripts/patch_agent_config.sh` — changed `NTP_SERVER` default from `192.168.111.1` to `10.100.0.1`

**Result**: `10.100.0.1` appears in BGP IPv4 VPN table on all nodes. DNS resolution (`dig api.sno-lab.example.com @10.100.0.1`) and NTP sync (`chronyc sources` shows `^* 10.100.0.1` stratum 3) both work over the SRv6 overlay.

**Note**: On nodes where chronyd had been failing for a long time, the poll interval backs off to 1024 seconds. A `chronyc burst 4/4 10.100.0.1` forces immediate retries. Fresh deployments won't have this issue.

## Current state

### What works
- ISIS fully converged: all master LSPs ~437 bytes, external FRR ~470 bytes
- IPv6 underlay connectivity: all loopbacks reachable (fc00:0:X::1 ↔ ping OK)
- BGP established: master-0 (RR) ↔ master-1, master-2, external FRR — all sessions up
- VPN routes exchanged: all 4 nodes' prefixes visible in BGP IPv4/IPv6 VPN tables (including `10.100.0.1/32`)
- SRv6 SIDs allocated: uDT46 for VRF red, uN for node, uA (End.X) for neighbors
- End.DT46 seg6local routes installed in kernel on all nodes
- **VRF red ping from external FRR to master-0 works** (`sudo ip vrf exec red ping 192.168.110.2`)
- **All fixes baked into appliance image** — survives full rebuild/redeploy (verified with `dev6` image)
- **tcpdump available in FRR container** (added in `dev6` image)
- **DNS over SRv6**: nodes resolve cluster names via `10.100.0.1` (dnsmasq in VRF red on hypervisor)
- **NTP over SRv6**: nodes sync time via `10.100.0.1` (chronyd in VRF red on hypervisor, stratum 3 local clock)

### Not yet verified
- Master-to-master VRF ping via SRv6
- Master-to-external-FRR VRF ping
- Full cluster installation completing with NTP sync passing on fresh deploy

## Live fix scripts created

| Script | Purpose |
|--------|---------|
| `fix-isis.sh` | Remove `segment-routing on` from masters via vtysh |
| `fix-external-frr.sh` | Add `lo-und` to ISIS on external FRR |
| `fix-vrf-strict.sh` | Enable VRF strict mode + re-trigger SID allocation |
| `fix-rpfilter.sh` | Disable rp_filter in FRR namespace on all masters |
| `fix-firewall-vrf.sh` | Add nftables notrack for VRF red (conntrack/firewalld fix) |
| `diag.sh` | Collect ISIS/BGP/route/ping diagnostics from all nodes |
| `diag-external.sh` | Collect diagnostics from external FRR |
| `test-srv6-ping.sh` | Ping test with tcpdump capture |
| `test-srv6-ping2.sh` | Deeper ping test with counters and firewall check |
| `test-srv6-counters.sh` | Compare IPv6 counters before/after ping |
