# VRouter sysctl tuning: candidates and measurement plan

Status of this document: **groundwork only. Every proposed value below is UNTESTED.**
The "Current" column holds values observed once on an idle stock router (section 1.1);
no proposed value has been tested. Nothing here is adopted, nothing in the appliance
code was changed. A setting may
only move from `UNTESTED` to `ADOPT` after the A/B procedure in section 3.1 has been
run on a live router and the result is recorded in sections 3.4 and 5.

Target design: router VM with
1 vCPU, 512 MB RAM, up to six NICs (virtio), VRRP pair (keepalived), optional FRR
(BGP/OSPF/BFD, ECMP), NAT4 (iptables), optional LVS (IPVS) load balancing.

## 1. Baseline from code: what the image sets today

### 1.1 Observed on a live router (stock image, idle)

Collected on 2026-10-20 on a test host: stock `master` image, Alpine 3.21.8,
`6.12.111-0-virt`, 1 vCPU, 512 MB, six virtio NICs, Router4 and NAT4 on, idle, 2.5 minutes
after boot. The report came from the first version of `collect-router-baseline.sh`.
Corrections to the values assumed earlier: `rp_filter` is strict (1) everywhere (set by
Alpine's `/usr/lib/sysctl.d/00-alpine.conf`); `nf_conntrack_max` is 4096 (equal to the
4096 buckets / `hashsize`, not about 16384); `netdev_budget_usecs` is 20000;
`tcp_max_syn_backlog` is 128; `icmp_ratelimit` is 1000 ms with `icmp_ratemask` 6168, and
`icmp_msgs_per_sec` 1000 / `icmp_msgs_burst` 50 are separate global limits; `default_qdisc`
is `pfifo_fast`; neighbour `gc_thresh1/2/3` are 128 / 512 / 1024. `conntrack-tools` and
`nft` are not installed. All six NICs: virtio_net, one combined queue, 256-entry rings,
GRO/GSO/TSO on, LRO off [fixed], txqueuelen 1000, RPS off, qdisc `pfifo_fast`, no softnet
drops at idle.

Caveat on the IPVS values: `ip_vs` was **not loaded** at boot, but the first version of
the baseline script ran `ipvsadm`, which loads it. The `net.ipv4.vs.*` values, the
IPVS timeouts and the table size (`ipvsadm` reported `size=4096`, that is 2^12 buckets)
below therefore come from a run in which the script itself had loaded `ip_vs`: they are
the module's defaults right after load, not the state of the stock router. The script
now skips the IPVS tools while `ip_vs` is not loaded. The same goes for any tool that
autoloads a module (see the script header). No `sysctl -w` was run anywhere.

Base: Alpine Linux, `packer-alpine321` (Alpine 3.21 cloud image, then `apk upgrade`
in `packer/alpine/10-upgrade-distro.sh`), service image built by
`packer/service_VRouter/`. Alpine 3.21 `linux-lts` is 6.12.x (aports 3.21-stable
`main/linux-lts/APKBUILD`: `pkgver=6.12.113` at the time of writing). The stock image
built on 2026-10-20 runs `6.12.111-0-virt` on Alpine 3.21.8 (observed, see section 1.1). Relevant kernel config of that package (`virt.x86_64.config`):
`nf_conntrack`, `ip_vs`, `tcp_bbr` and `fq_codel` are **modules**, so the
`net.netfilter.*` and `net.ipv4.vs.*` sysctls only exist after the module is loaded
(iptables NAT / ipvsadm). A `sysctl.d` file loaded at boot before the module is
present will fail for those keys. Any future implementation has to order itself
after module load, or load the module explicitly.

Packages (`packer/service_VRouter/10-update.sh` and per-module `install`):
`ethtool`, `iproute2`, `iptables`, `tcpdump`, `jq`, `ruby`, `go` (image);
`procps` (Router4), `iptables-openrc` (NAT4, SDNAT4), `ipvsadm` (LVS),
`keepalived`, `haproxy`, `unbound`, `wireguard-tools-wg-quick`. `iperf3` is in the
base Alpine image. **Not installed:** `conntrack-tools` (`conntrack`, `conntrackd`),
`irqbalance`, `tuned`. The baseline script therefore falls back to `/proc`.

Everything the repository sets (searched all of `appliances/VRouter`,
`packer/service_VRouter`, `packer/alpine` for sysctl, conntrack, ethtool, irq, rps,
queue, `/proc/sys`, `net.core`, `net.ipv4`, `net.netfilter`, `ip_vs`):

| Where | What |
|---|---|
| `appliances/VRouter/Router4/main.rb` | `/etc/sysctl.d/98-Router4.conf`: `net.ipv4.ip_forward=0`, `net.ipv4.conf.{all,default}.forwarding=0`, then `net.ipv4.conf.<nic>.forwarding=1` or `0` per NIC (by routing config); `sysctl --system` on apply. Cleanup sets all to 0. |
| `appliances/VRouter/WireGuard/main.rb` | `echo 1 > /proc/sys/net/ipv4/conf/<wg dev>/forwarding` for the WireGuard device. |
| `packer/alpine/11-update-boot.sh` | Kernel command line only: removes `console=ttyS*`, rewrites `console=ttyAMA*`; extlinux timeout 1. No tuning. |

That is all. **No** conntrack, neighbour, multipath, rp_filter, backlog, buffer,
ICMP, IPVS, ethtool/offload, queue, RPS/XPS or IRQ setting is set by any appliance
code. Everything else is whatever the Alpine kernel and Alpine's own packaged
defaults give. Alpine's `/usr/lib/sysctl.d/00-alpine.conf` was read in the baseline: it
sets `tcp_syncookies=1`, `rp_filter=1` (`all`, `default`), `accept_redirects=0` and
`accept_source_route=0` (`all`), `tcp_rfc1337=1`, `kernel.panic=120` and a few
hardening keys. IPv6 forwarding is not touched either; observed 0.

Caveat: a deployed router image may carry additions that are not in `master` (for
example FRR or a management VRF). The "current value" column below is therefore the
stock `master` image as measured; values on another image may differ and must be
re-collected with `collect-router-baseline.sh`.

## 2. Candidates

Column notes:

- **Current**: value observed in the stock-router baseline of section 1.1 (idle, 1 vCPU,
  512 MB). "unknown" = the baseline did not cover it; nothing is assumed for those.
- **VyOS**: value from vyos-1x `rolling` @ `040fab5100ac07a00246ee6cbe5440a8e52a19e7`
  (2026-10-19) and vyos-build `rolling` @ `94192fd1290ed0146e824c4d009bc2b29d3d176e`
  (2026-10-17). This is a development branch, not a release tag (latest tags are
  `1.4.0`/`1.3.8`, older). Re-pin to a release before citing in the PR. Used only as a
  source of candidates; VyOS runs a Debian kernel on bare metal and larger VMs, and
  most values below are not sized for 512 MB. Source files (all under
  `https://github.com/vyos/vyos-1x/blob/040fab5100ac07a00246ee6cbe5440a8e52a19e7/`):
  - `[S]` `src/etc/sysctl.d/30-vyos-router.conf`
  - `[CT]` `data/templates/conntrack/sysctl.conf.j2` with defaults in `interface-definitions/system_conntrack.xml.in`
  - `[FW]` `data/templates/firewall/sysctl-firewall.conf.j2` with defaults in `interface-definitions/include/firewall/timeout-common-protocols.xml.i`
  - `[IP]` `src/conf_mode/system_ip.py` (lines 69-86), `[IP6]` `src/conf_mode/system_ipv6.py`, ARP table size default in `interface-definitions/include/arp-ndp-table-size.xml.i`
- **Test value**: what to try in the A/B run. These are starting points for
  measurement, never recommendations. Where a range is given, test each point.
- Memory costs are rough estimates from typical struct sizes and must be confirmed
  with `slabtop` / `free` (the plan captures both).

### 2.1 Conntrack / NAT

| Setting | Current | VyOS | Test value | Affects | Risk / memory cost | How to measure | Status |
|---|---|---|---|---|---|---|---|
| `net.netfilter.nf_conntrack_max` | 4096 (observed on the stock image, 512 MB: equal to the 4096 buckets, no 4x factor) | 262144 [CT] (`system_conntrack.xml.in`) | 32768, 65536, 131072 | Max tracked flows; when full, new flows are dropped ("nf_conntrack: table full, dropping packet") | ~0.3 KB/entry (check `slabtop` `nf_conntrack`): 65536 is about 20 MB worst case, VyOS's 262144 is about 80 MB, 15% of a 512 MB VM, and unsafe with FRR/HAProxy/OOM headroom | T3 (conntrack stress): max sustainable CPS, `drop`/`early_drop`/`insert_failed`, dmesg table-full, MemAvailable at full table | UNTESTED |
| `nf_conntrack` `hashsize` (module param; `net.netfilter.nf_conntrack_buckets` is read-only) | 4096 (observed; `hashsize` = `nf_conntrack_buckets` = 4096) | 65536 [CT] | max/4 and max/8 for each max above (for example 16384 for max 65536) | Hash chain length = lookup CPU per packet at high flow counts | 8 bytes/bucket: 16384 is 128 KB; 65536 is 512 KB. Change via `/sys/module/nf_conntrack/parameters/hashsize` (runtime) or modprobe option | T3 plus T2: PPS at 1 vCPU with table 80% full (T2 while T3 table is pre-filled) | UNTESTED |
| `net.netfilter.nf_conntrack_tcp_timeout_established` | 432000 s (observed) | 432000 [FW] (same as kernel) | 86400, 7200 | How long idle established flows stay in the table; dominant for table occupancy with many idle clients | Shorter value silently kills idle long-lived sessions (SSH, DB pools, VRRP-failover-unsynced flows) unless keepalives are shorter | T3 occupancy vs time after load stops; T6 idle-session survival test | UNTESTED |
| `nf_conntrack_tcp_timeout_{time_wait,close_wait,fin_wait,last_ack,syn_sent,syn_recv,close}` | 120/60/120/30/120/60/10 (observed) | 120/60/120/30/120/60/10 [FW] (equal to my recollection of kernel defaults) | time_wait 30 or 60; others unchanged | Faster expiry of closed flows under short-connection load | Too short time_wait can break reuse of 4-tuples with late packets | T3 peak `nf_conntrack_count` | UNTESTED |
| `nf_conntrack_udp_timeout` / `_udp_timeout_stream` | 30 / 120 (observed) | 30 / 180 [FW] | 30 / 120, and 15 / 60 for DNS-heavy | UDP flow lifetime (DNS, WireGuard, QUIC) | Short stream timeout drops idle UDP sessions (VoIP, VPN keepalive > timeout) | T3 UDP variant; WireGuard keepalive survival | UNTESTED |
| `nf_conntrack_icmp_timeout`, `nf_conntrack_generic_timeout` | 30 / 600 (observed) | 30 / 600 [FW] | leave | Occupancy by ICMP/other protocols | none expected | T3 with ping flood | UNTESTED |
| `nf_conntrack_tcp_loose` | 1 (observed) | 1 [CT] (default `enable`) | keep 1; test 0 only for security reasons | Pick-up of mid-stream TCP after VRRP failover or asymmetric routing | 0 breaks established flows after failover, but blocks ACK-scan pollution | T6 failover with a long TCP stream | UNTESTED |
| `nf_conntrack_tcp_max_retrans` | 3 (observed) | 3 [CT] | leave | Retransmit tolerance before flow marked | none | n/a | UNTESTED |
| `nf_conntrack_checksum` | 1 (observed) | not set | 0 | Skips conntrack's checksum verification (CPU per packet) | Accepts packets with bad checksums into tracking; virtio often has offloaded checksums so effect may be zero | T2 PPS A/B | UNTESTED |
| `nf_conntrack_acct`, `nf_conntrack_timestamp` | 0 / 0 (observed) | 0 [CT] | leave 0 | Per-flow accounting costs memory (+16 B/entry for acct) | Only costs when enabled | n/a | UNTESTED |
| `nf_conntrack_expect_max` | 64 (observed) | 2048 [CT] | leave | ALG helper expectations (FTP, SIP...) | negligible | n/a | UNTESTED |
| `net.ipv4.ip_local_port_range` | 32768 60999 (observed) | not set (only read by nat64) | leave; verify it does not matter | Only local sockets (HAProxy, DNS, router's own connections). My understanding is that masquerade/SNAT port allocation uses its own 1024-65535 ranges, not this sysctl, so this is probably **irrelevant to NAT capacity**; must be confirmed, not assumed | none | T3: count distinct NAT source ports used with default vs widened range (needs `conntrack-tools`: this kernel has no `/proc/net/nf_conntrack`) | UNTESTED |

### 2.2 Routing, ECMP, neighbours

| Setting | Current | VyOS | Test value | Affects | Risk / memory cost | How to measure | Status |
|---|---|---|---|---|---|---|---|
| `net.ipv4.fib_multipath_hash_policy` | 0 = L3 src/dst only (observed; `fib_multipath_hash_fields` 7) | 0, or 1 when `layer4-hashing` configured [IP] | 1 (L4 5-tuple) | ECMP flow spread. With 0, one client-server pair always uses one path; with 1, parallel flows spread | Reordering risk per-flow is unchanged (flows stay on one path); slightly more hash work | T4: nexthop distribution (`ip route get ... ipproto tcp sport N`) and per-link byte share under `iperf3 -P 32` | UNTESTED |
| `net.ipv6.fib_multipath_hash_policy` | 0 (observed) | 0 / 1 [IP6] | 1, only if IPv6 ECMP is used | same, IPv6 | same | T4 with IPv6 | UNTESTED |
| `net.ipv4.fib_multipath_use_neigh` | 0 (observed) | 0, or 1 with `ignore-unreachable-nexthops` [IP] | 1 | Skip nexthops without valid neighbour entry; faster ECMP failover without waiting for routing protocol | Interplay with FRR/BFD; could skip a nexthop whose ARP just aged | T4 failover: time to move traffic after a nexthop dies | UNTESTED |
| `net.ipv4.conf.{all,default}.ignore_routes_with_linkdown` | 0 on `all`, `default`, `eth0` (observed) | 1 [S] | 1 | Routes via a link-down NIC are ignored for lookup (multipath failover) | Behaviour change only on link-down | T4 failover with `ip link set dev X down` equivalent (virtual NIC detach) | UNTESTED |
| `net.ipv4.conf.{all,default}.rp_filter` | 1 = strict on `all`, `default` and `eth0` (observed; `all` and `default` set by Alpine's `/usr/lib/sysctl.d/00-alpine.conf`; the effective value is the maximum of `all` and the NIC value) | 0 [S] | 0 vs 2 (loose) vs 1 (strict) | Reverse-path source validation per packet; strict mode drops asymmetric or ECMP-return traffic | 1 can silently black-hole valid asymmetric traffic; 0 removes anti-spoof; 2 is the middle | T4/T6 with asymmetric return path: delivery yes/no; `IPReversePathFilter` in `/proc/net/netstat` | UNTESTED |
| `net.ipv4.neigh.default.gc_thresh1/2/3` | 128 / 512 / 1024 (observed) | 1024 / 4096 / 8192 [IP] (table size 8192; thresh2 = size/2, thresh1 = size/8) | 1024 / 4096 / 8192 | "neighbour table overflow" with many L2 neighbours across 6 segments; ARP storm/ drops | ~0.25 KB x entries: 8192 is about 2 MB worst case. Large tables slow `ip neigh` and ARP scans | Fill with `arping`/ping sweep across /22 segments; count neighbour entries (`ip neigh`, line count), dmesg "neighbour: arp_cache: neighbor table overflow!", `/proc/net/stat/arp_cache` `table_fulls` | UNTESTED |
| `net.ipv6.neigh.default.gc_thresh1/2/3` | 128 / 512 / 1024 (observed) | same as IPv4 [IP6] | same | same, IPv6 | same | same | UNTESTED |
| `net.ipv4.conf.all.arp_announce` / `arp_ignore` / `arp_filter` | 0 / 0 / 0 (observed, `all`) | 2 / 0 / 0 [S] | 2 (announce) | Source address chosen in ARP requests: avoids announcing addresses on the wrong subnet with multiple NICs and VIPs | Interacts with VRRP VIPs and LVS-DR real servers (which need arp_ignore=1, arp_announce=2 on **real servers**, not on the director) | VRRP failover time and gratuitous ARP visibility (tcpdump) | UNTESTED |
| `net.ipv4.conf.all.send_redirects` / `accept_redirects` / `accept_source_route` | `all`: send_redirects 1, accept_redirects 0, accept_source_route 0 (observed; `default` and `eth0` have accept_redirects 1, accept_source_route 1, send_redirects 1) | 1 / 0 / 0 [S] | accept_redirects 0, accept_source_route 0 | Security hardening, not performance | Router may generate ICMP redirect packets when it forwards out the ingress NIC | T2 + `IcmpOutRedirects` counter | UNTESTED |
| `net.ipv6.conf.all.forwarding` | 0 (observed; Router4 only manages IPv4) | 1 [S] | not a tuning item; flagged because the image only handles IPv4 forwarding | Whether IPv6 traffic is routed | Behaviour change | `sysctl net.ipv6.conf.all.forwarding` in baseline | UNTESTED |
| `net.ipv4.conf.all.log_martians` | 0 (observed) | 1 [S] | leave 0 | Kernel log volume | Log flood on 512 MB console/syslog under spoof load | n/a | UNTESTED |

### 2.3 Packet path, queues, buffers

| Setting | Current | VyOS | Test value | Affects | Risk / memory cost | How to measure | Status |
|---|---|---|---|---|---|---|---|
| `net.core.netdev_max_backlog` | 1000 (observed) | not set | 2000, 4096 | Per-CPU input queue before softirq processing; drops show up in `/proc/net/softnet_stat` column 2 | Up to N skbs (about 2 KB each) per CPU held under overload: 4096 is about 8 MB worst case; more latency (bufferbloat) | T2 UDP PPS at and above line capacity: softnet drops, loss %, latency | UNTESTED |
| `net.core.netdev_budget`, `netdev_budget_usecs` | 300 / 20000 (observed) | not set | 600 / 4000 | Softirq work per poll cycle; `time_squeeze` (softnet column 3) means the budget ran out | On 1 vCPU a larger budget starves userland (FRR, keepalived hello) | T2 plus keepalived/BFD hello jitter during load | UNTESTED |
| `net.core.default_qdisc` (+ `tc` per NIC) | `pfifo_fast` (observed: sysctl and `tc -s qdisc` on all six NICs) | `fq_codel` [S] | `fq_codel` | Queueing and bufferbloat on egress of forwarded traffic | Negligible memory; fq_codel can drop under sustained overload by design | T1/T2 latency under load (ping during iperf3) and throughput | UNTESTED |
| `net.ipv4.tcp_congestion_control` | cubic (observed) | `bbr` [S] | **no test planned** | Affects only TCP sockets terminating on the router, not forwarded flows | n/a | n/a: listed so nobody assumes it speeds up forwarding | UNTESTED (expected no effect) |
| `net.core.rmem_max` | 212992 (observed) | 2097152 [S] (comment: netlink buffer) | 2097152 | Netlink socket receive buffer for FRR/zebra route and neighbour events (ENOBUFS on large tables or route flaps) | Only used if sockets request it; no forwarding effect | Churn test: inject N routes, watch zebra for netlink overruns | UNTESTED |
| `net.core.rmem_default/wmem_default/wmem_max`, `net.ipv4.tcp_rmem/wmem` | `rmem_default`/`wmem_default`/`wmem_max` 212992; `tcp_rmem` 4096 131072 3704896; `tcp_wmem` 4096 16384 3704896 (observed) | not set | leave | Local sockets only (HAProxy, DNS); no forwarded-traffic effect | Memory per socket | HAProxy throughput if relevant | UNTESTED (expected no effect on forwarding) |
| `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog` | `somaxconn` 4096, `tcp_max_syn_backlog` 128 (observed) | `tcp_max_syn_backlog` = 512 from conntrack config [CT] | leave | Listen queue of local services only (HAProxy, SSH) | none for forwarding | HAProxy accept-queue overflow counters (`ListenOverflows`) | UNTESTED |
| `net.core.rps_sock_flow_entries` and per-queue `rps_cpus`/`xps_cpus`; `irqbalance` | `rps_sock_flow_entries` 0, `rps_cpus` 0 on all six `rx-0` queues (observed); irqbalance not installed | `rps_sock_flow_entries`=32768 [S] | **no test on 1 vCPU** | Multi-queue steering; meaningless with one CPU | none | Only revisit if the router is sized to more than 1 vCPU | UNTESTED (n/a at 1 vCPU) |
| NIC offloads: `ethtool -K <nic> gro/gso/tso/lro` | GRO on, GSO on, TSO on, LRO off [fixed] on all six NICs (observed, `ethtool -k`) | not set by sysctl (VyOS sets per interface) | compare GRO on/off; LRO must be off on a router | Per-packet CPU on virtio (GRO then GSO resegmentation on the forwarding path) | LRO on a forwarder breaks forwarding; changing offloads may drop link briefly | T1/T2 CPU per Gbit | UNTESTED |
| NIC queue length: `ip link set <nic> txqueuelen` | 1000 on all six NICs (observed) | not set | 1000 vs 256 | Egress queue depth | Memory per NIC; latency | T1/T2 latency under load | UNTESTED |
| `net.ipv4.icmp_ratelimit`, `icmp_ratemask`, `icmp_msgs_per_sec`, `icmp_msgs_burst` | 1000 ms / 6168 / `icmp_msgs_per_sec` 1000 / `icmp_msgs_burst` 50 (observed) | not set | leave | Rate of ICMP errors sent by the router (TTL exceeded, unreachable, frag-needed for PMTUD) | Raising limit helps traceroute/PMTUD under load but lets the router be an ICMP amplifier and costs CPU | traceroute completeness and `IcmpOutRateLimitGlobal` (nstat/netstat) under T2 load | UNTESTED |
| `net.ipv4.icmp_echo_ignore_broadcasts`, `icmp_ignore_bogus_error_responses`, `icmp_errors_use_inbound_ifaddr` | 1 / 1 / 0 (observed) | 1 / 1 / 1 [S] | `icmp_errors_use_inbound_ifaddr`=1 | Source address of ICMP errors (so traceroute shows the ingress interface address in multi-NIC topologies) | none performance-wise | traceroute through router shows ingress IP | UNTESTED |
| `net.ipv4.tcp_syncookies` | 1 (observed) | 1 [S] | leave | Local listeners only | none | n/a | UNTESTED |
| `net.ipv4.igmp_max_memberships` | 20 (observed) | 512 [S] | leave unless multicast/OSPF with many VRRP groups | Max multicast group joins per socket | none | only if memberships error appears in logs | UNTESTED |

### 2.4 IPVS / LVS (load balancer role)

VyOS does not set any `net.ipv4.vs.*` key (no match in `src/`, `data/`, `python/`
of vyos-1x at the pinned commit), so there is no VyOS value; the candidates come from
the kernel IPVS documentation (`Documentation/networking/ipvs-sysctl.rst`). The
"Current" values were read after the first baseline script run had itself loaded
`ip_vs` through `ipvsadm`; they are module defaults right after load, not the state of
the stock router (see section 1.1).

| Setting | Current | VyOS | Test value | Affects | Risk / memory cost | How to measure | Status |
|---|---|---|---|---|---|---|---|
| `net.ipv4.vs.conntrack` | 0 (observed after the script loaded `ip_vs`) | not set | keep 0 unless the VIP is behind stateful iptables rules | If 1, every IPVS connection also gets an nf_conntrack entry | Doubles per-flow memory; interacts with `nf_conntrack_max` | T5 with conntrack count A/B | UNTESTED |
| `net.ipv4.vs.expire_nodest_conn` | 0 (observed after the script loaded `ip_vs`) | not set | 1 | Immediately expire connections whose real server was removed or is down, so clients reconnect | Resets in-flight connections to a removed backend (intended) | T5 kill-a-backend: client error duration | UNTESTED |
| `net.ipv4.vs.expire_quiescent_template` | 0 (observed after the script loaded `ip_vs`) | not set | 1 (only with persistence) | Persistence templates for weight-0 backends | Changes persistence semantics | T5 persistence test | UNTESTED |
| `net.ipv4.vs.conn_reuse_mode` | 1 (observed after the script loaded `ip_vs`) | not set | 0 / 1 / 2 | Handling of reused 4-tuples in TIME_WAIT: balancing imbalance vs connection stalls | Documented trade-offs in kernel docs; mode 0 can stall reused ports | T5 many short connections: distribution evenness, error rate | UNTESTED |
| `net.ipv4.vs.sync_threshold` (threshold period), `sync_refresh_period`, `sync_retries`, `sync_qlen_max`, `sync_sock_size`, `sync_ports` | `3 50`, 0, 0, 3722, 0, 1 (observed after the script loaded `ip_vs`; `sync_qlen_max` is memory-derived) | not set | `sync_threshold` 3 50 vs 10 100 | Cost and freshness of connection sync to the VRRP backup (when keepalived runs the sync daemon) | `sync_qlen_max` is bounded by RAM share; larger queues use memory | T5 failover with sync: share of surviving connections; sync CPU in T2 | UNTESTED |
| `net.ipv4.vs.schedule_icmp`, `ignore_tunneled`, `nat_icmp_send`, `snat_reroute`, `sloppy_tcp/sctp`, `drop_entry/drop_packet/secure_tcp/amemthresh` | `schedule_icmp`, `ignore_tunneled`, `nat_icmp_send`, `sloppy_tcp`, `sloppy_sctp`, `drop_entry`, `drop_packet`, `secure_tcp` all 0; `snat_reroute` 1; `amemthresh` 1024 (observed after the script loaded `ip_vs`) | not set | leave | Edge behaviours (ICMP scheduling, tunnel loops, defence strategies) | Defence strategies (`drop_entry`, `drop_packet`) drop legitimate traffic under memory pressure | not planned | UNTESTED |
| `ip_vs` module parameter `conn_tab_bits` (modprobe option) | 12 = 4096 buckets (derived from `ipvsadm` reporting `size=4096`, observed after the script loaded `ip_vs`; the module parameter itself was not read) | not set | 12 vs 14 vs 16 | IPVS connection hash table length | 4 KB x 2^(bits-12) of buckets plus ~0.3 KB per connection; set at module load only | T5 with 50k+ connections: lookup CPU in T2 while table full | UNTESTED |
| IPVS timeouts: `ipvsadm --set tcp tcpfin udp` | 900 120 300 (observed after the script loaded `ip_vs`) | not set | 900 120 300 vs 300 30 60 | IPVS connection lifetime (table occupancy for short connections) | Short TCP timeout drops idle established sessions | T5 occupancy and idle-session survival | UNTESTED |

Out of scope on purpose: security hardening that has no performance effect
(`kernel.panic*`, `printk`, `bridge-nf-call-*`, VRF strict mode, IPv6 segment
routing), and VyOS's `tuned` performance profiles (the profile contents were not
fetched; they target physical NICs and many cores).

## 3. Measurement plan

### 3.1 Prerequisites and discipline

- Topology: `client VM -> router (system under test) -> server VM`, all three on the
  same hypervisor host, on dedicated networks, router sized exactly like production
  (1 vCPU / 512 MB / same NIC count and model). A second topology with two ECMP
  paths and a third with an LVS VIP and 2-3 backends is needed for T4 and T5.
- Quiesce: no other VM load on the host if possible; record host CPU model and
  whether vCPUs are pinned. Do not use a tool on the router itself for load; the
  router only forwards.
- One variable at a time. Apply with `sysctl -w` (runtime only, reverts on reboot),
  never by editing files, so a reboot is a guaranteed rollback. For `hashsize` and
  `conn_tab_bits` use the runtime/`/sys/module` knob or reload the module.
- Order: A (baseline) - B (candidate) - A again, to expose drift. At least 5 runs
  per state, 60 s each, 10 s warm-up discarded. Report median and standard
  deviation. A setting counts as having an effect only if |B - A| is larger than
  twice the standard deviation of the A runs and the second A matches the first.
- Memory is a first-class metric: record `MemAvailable` and the relevant slab sizes
  before and after, and the low-water mark during the run.
- A setting is `ADOPT` only with: measured benefit on its target metric, no
  regression on the others, memory cost within budget, and the failure mode
  understood. Otherwise `REJECT` or `INCONCLUSIVE`. No setting is adopted because
  VyOS or a guide uses it.

### 3.2 Baseline capture on the live router

Preferred (one command, read-only, includes everything below):

```sh
sh collect-router-baseline.sh -l baseline            # text report
sh collect-router-baseline.sh -j -l baseline         # same as JSON
```

The script gathers, per section: `uname -a`, `/etc/os-release`, `/proc/cmdline`,
`nproc`, CPU flags, `free -m`, `/proc/meminfo`, `slabtop`, relevant `/proc/slabinfo`
lines, `sysctl -a`, all `sysctl.d` files, `ip -s link` and `ip -d -s -s link`,
addresses, routes (all tables), rules, neighbour count and stats, `/proc/net/dev`,
`/proc/net/softnet_stat`, `/proc/net/snmp`, `/proc/net/netstat`, `/proc/interrupts`,
`/proc/softirqs`, IRQ affinities, `tc -s qdisc`, for each NIC `ethtool -i`, plain,
`-k`, `-l`, `-g`, `-c`, `-S` plus sysfs queue/RPS/XPS/MTU values, conntrack counters
(`nf_conntrack_count/max/buckets`, `hashsize`, `/proc/net/stat/nf_conntrack`,
`conntrack -S` if installed; the Alpine virt kernel has no `/proc/net/stat/nf_conntrack` and no `/proc/net/nf_conntrack`, so these two need `conntrack-tools`), `iptables-save -c`, `nft list
ruleset`, and IPVS (`ipvsadm -Ln`, `--stats`, `--timeout`, `--daemon`,
`net.ipv4.vs.*`, `/proc/net/ip_vs_stats`, connection count).

Equivalent manual commands (if the script cannot be used):

```sh
uname -a; cat /etc/os-release; nproc; free -m
sysctl -a > sysctl-all.txt
for n in $(ls /sys/class/net | grep -v '^lo$'); do
  ethtool -i $n; ethtool -k $n; ethtool -l $n; ethtool -g $n; ethtool -S $n
done
cat /proc/net/softnet_stat
cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max
cat /sys/module/nf_conntrack/parameters/hashsize
conntrack -S                          # needs conntrack-tools; the Alpine virt kernel has no /proc/net/stat/nf_conntrack
ip -s link; ip -s neigh; slabtop -o -s c | head -20
```

Caveats: `ethtool -S`, `slabtop`, `/proc/slabinfo` and `conntrack -S` need root. The
script marks absent tools as `(not installed: X)`. `conntrack-tools` is not in the
image today; installing it is a prerequisite for the conntrack counters and
the per-protocol entry counts, because this kernel does not provide them under `/proc`.

Run the script: (a) idle after boot, (b) at the end of each test run (label the
setting, for example `-l T3-max65536`), and diff the sysctl sections between
reports.

### 3.3 Test cases

Router-side counters sampled around every run: `/proc/stat` first line (CPU
user/system/softirq/idle jiffies), `/proc/net/softnet_stat`, `ip -s link` per NIC,
`nf_conntrack_count`, `MemAvailable`. A minimal sampler (run on the router, one
invocation before and one after the load, diff the outputs):

```sh
{ date +%s; head -1 /proc/stat; cat /proc/net/softnet_stat; ip -s -s link;
  cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null;
  grep -E 'MemAvailable|MemFree' /proc/meminfo; } > sample-$(date +%s).txt
```

Softnet column meaning (hex, one line per CPU): 1 processed, 2 dropped (backlog full),
3 time_squeeze (budget exhausted).

**T1 TCP throughput through the router.** Server: `iperf3 -s`. Client:
`iperf3 -c SERVER -t 60 -O 10 -P 1`, then `-P 8`, then `-R` (reverse). Record Gbit/s,
retransmits, router CPU (softirq share from `/proc/stat` delta), softnet drops.
Optionally run `ping -i 0.2 SERVER` in parallel for loaded latency.

**T2 UDP throughput and PPS.** `iperf3 -c SERVER -u -b 0 -l 64 -t 60 -O 10 -P 4`
(small packets, PPS bound) and `-l 1400` (bandwidth bound). PPS = packets received at
the server / duration; cross-check with router `ip -s link` RX/TX packet deltas, since
the client may be the bottleneck. Record loss %, softnet drops, `time_squeeze`.
A pure packet generator (`pktgen`, `trafgen`) would be better and is not available in
the image; use it on the client VM if you can install it.

**T3 many short connections / conntrack stress (with NAT4 active).**
(a) Short TCP: server runs nginx or any HTTP server; client
`ab -n 500000 -c 256 http://SERVER/` (no keep-alive) or `wrk -t1 -c256 -d60s -H
'Connection: close' http://SERVER/`. Record connections per second, failures, and
on the router `nf_conntrack_count` peak, `conntrack -S` (needs conntrack-tools; `drop`, `early_drop`,
`insert_failed`, `search_restart`), `dmesg | grep conntrack`, MemAvailable low-water mark.
(b) Table fill with UDP flows (each distinct source port is one entry); untested
helper using only the Python standard library:

```python
import socket, sys
dst, n = sys.argv[1], int(sys.argv[2])     # e.g. 10.0.0.9 70000
socks = []
for i in range(n):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(b"x", (dst, 9 + (i % 50)))    # vary dst port: more distinct 5-tuples
    socks.append(s)                        # keep sockets open: unique source ports
print("sent", n)
```

Run on the client with `ulimit -n` raised, then watch `nf_conntrack_count` approach
`nf_conntrack_max` and record what is dropped and the memory at full table. Repeat
with the table pre-filled to 80% while running T2 to see the per-packet cost of long
hash chains.

**T4 ECMP flow spread.** Topology with two equal-cost next-hops (static or FRR).
(a) Deterministic, no traffic: on the router, for each source port
`ip route get DST from SRC iif <ingress-nic> ipproto tcp sport $p dport 443` for
p in 20000..20199 (and varying SRC if the client has several addresses); count how
many resolve to each nexthop. Expected with policy 0: all flows of one SRC/DST pair on
one path; with policy 1: roughly 50/50. (b) With traffic: `iperf3 -c DST -P 32`; compute
byte share per nexthop NIC from `ip -s link` deltas. (c) Failover: take one nexthop
down and measure time to full recovery (continuous ping, count lost replies), with and
without `fib_multipath_use_neigh` and `ignore_routes_with_linkdown`.

**T5 LVS connection test.** Router with VIP and 2-3 real servers (NAT or DR mode as
deployed). (a) Distribution: `ab -n 200000 -c 128 http://VIP/`, then `ipvsadm -Ln --stats
--rate`: connections per real server (expected near-even for rr/wlc). (b) Occupancy:
idle connections (`wrk` with keep-alive, 20000 connections) and `wc -l
/proc/net/ip_vs_conn`, MemAvailable. (c) Backend failure: stop one backend during
load; measure error duration with `expire_nodest_conn` 0 vs 1. (d) VRRP failover with
sync daemon: long-lived TCP stream through the VIP, fail over, record whether the
stream survives.

**T6 failover and idle sessions (for the timeout settings).** Open a TCP session
through NAT, idle it for 2x the candidate `tcp_timeout_established`, then send data;
repeat after a VRRP switch-over. Record survives yes/no.

### 3.4 Results template (one block per setting and test)

```
Setting:            net.netfilter.nf_conntrack_max
Candidate value:    65536            Baseline value (A): <read from live router>
Kernel / image:     <uname -r>, <image build id>      Router: 1 vCPU / 512 MB, <n> NICs
Host:               <hypervisor CPU, load, pinned? y/n>   Date: <date>   Operator: <name>
Revert:             sysctl -w ... (runtime only)  Reboot between states: y/n
Test case:          T3a  (ab -n 500000 -c 256)

| Metric                         | A run1..5 (median, sd) | B run1..5 (median, sd) | A again (median) | Delta B-A | > 2 sd? |
|--------------------------------|------------------------|------------------------|------------------|-----------|---------|
| Primary: conn/s                |                        |                        |                  |           |         |
| Failed connections             |                        |                        |                  |           |         |
| nf_conntrack_count peak        |                        |                        |                  |           |         |
| conntrack drop / early_drop    |                        |                        |                  |           |         |
| softnet dropped / squeeze      |                        |                        |                  |           |         |
| Router CPU (softirq %, idle %) |                        |                        |                  |           |         |
| MemAvailable low-water (MB)    |                        |                        |                  |           |         |
| Slab growth (nf_conntrack, MB) |                        |                        |                  |           |         |
| Side effects observed          |                        |                        |                  |           |         |

Raw reports:        collect-router-baseline output files for A, B, A2
Verdict:            ADOPT / REJECT / INCONCLUSIVE    Reason:
```

## 4. Open items

- The "Current" values come from one idle run on one stock router; re-collect on the
  deployed image and under load before relying on them. Rows still marked "unknown"
  were not covered by that run.
- The IPVS values were read after the first script version had loaded `ip_vs` itself;
  re-collect them with the hardened script after loading the module deliberately.
- Conntrack counters, per-protocol entries and `conntrack -S` need `conntrack-tools`
  (this kernel has neither `/proc/net/stat/nf_conntrack` nor `/proc/net/nf_conntrack`).
  The hardened script runs `conntrack` only when `nf_conntrack_netlink` is already loaded.
- The memory estimates are approximate; verify with `slabtop`.
- VyOS values are from a development branch commit; re-pin to a release tag
  (`1.4.0` is the newest tag fetched) before quoting them externally.
- The helper snippets and test commands in section 3.3 are untested.

## 5. Results log

None yet. No setting has been measured.
