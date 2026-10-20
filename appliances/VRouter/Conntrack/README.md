# Connection tracking synchronisation (conntrackd) for the VRouter appliance

## What it does

This module runs `conntrackd` (conntrack-tools) on both nodes of a VRRP router pair and replicates the kernel connection tracking table of the MASTER to the BACKUP. After a failover the new MASTER loads the replicated entries into its kernel table, so established flows that are tracked by netfilter (TCP, UDP, and the NAT translations stored in the same entries, for example SNAT) keep working instead of being reset. It is off by default; nothing changes for an image that does not set `ONEAPP_VNF_CONNTRACK_SYNC_ENABLED`.

Both nodes need the same configuration (the same VM context for the Virtual Router template); each node derives its own addresses.

## Enabling

```
ONEAPP_VNF_CONNTRACK_SYNC_ENABLED = "YES"
```

Everything else has a default. For NAT4 sessions to survive a failover the translated source address must be the same on both nodes, that is a virtual IP, not the address of the node: with the stock `MASQUERADE` each node translates to its own interface address and the backup cannot continue the flow. Use the NAT4 options `ONEAPP_VNF_NAT4_SNAT_TO_VIP` or `ONEAPP_VNF_NAT4_SNAT_ADDRESS` (SNAT to the VIP or to a given address) together with this module.

## Attributes

All attributes start with `ONEAPP_VNF_CONNTRACK_SYNC_`. Blank and whitespace-only values are treated as unset. An invalid value, or any unexpected error while configuring, is logged as an error (with the error class) and the synchronisation stays off; the rest of the appliance is configured normally. `ENABLED` follows the other modules: only `YES` or `1` (any case) enable it, anything else means off. Spellings other than `YES`, `NO`, `1`, `0` (for example `true`) are logged as a warning and treated as `NO`.

| Name (after prefix) | Default | Meaning | Example |
|---|---|---|---|
| `ENABLED` | `NO` | Turns the module on. | `YES` |
| `INTERFACE` | first interface of `ONEAPP_VNF_KEEPALIVED_INTERFACES` (all NICs if unset) that is not a management NIC and has an `ETH<n>_IP`, which is the NIC the VRRP traffic uses | NIC that carries the synchronisation traffic. A management NIC is used only if set here. | `eth1` |
| `PEER` | none | IPv4 unicast address of the other node on that NIC (not loopback, `0.0.0.0`, broadcast, multicast or the own address of this node). If set, unicast UDP is used. If not set, multicast is used and no address is needed. Keepalived in this appliance uses multicast VRRP, so there is no peer address to derive from it. | `10.2.12.68` |
| `MODE` | `FTFW` | `FTFW` (reliable, with acknowledgements and retransmission) or `NOTRACK` (best effort, no acknowledgements). | `FTFW` |
| `PORT` | `3780` | UDP port (unicast) or multicast group port. | `3780` |
| `MCAST_GROUP` | `225.0.0.50` | Multicast group, used only without `PEER`. Give each router pair on the same network segment its own group or port. | `225.0.0.60` |
| `PROTOCOLS` | `TCP UDP` | Space or comma separated: `TCP`, `UDP`, `ICMP`. Only these protocols are replicated. | `TCP UDP ICMP` |
| `HASH_LIMIT` | `65536` | Maximum entries in each of the two caches, 1024..1000000 (see "Memory"). `HashSize` is one eighth of it. | `32768` |
| `IGNORE` | empty | Space or comma separated IPv4 addresses or CIDRs whose flows are not replicated. | `10.9.9.0/24` |

Always ignored: `127.0.0.1`, the IPv4 subnets of the management NICs, and the synchronisation endpoint itself (the multicast group, or the peer), so the synchronisation traffic is not replicated. The addresses of the nodes and the virtual IPs are not ignored on purpose: flows translated to a virtual IP are exactly what has to be replicated.

The rendered configuration is `/etc/conntrackd/conntrackd.conf`. It is rewritten at every boot and re-contexting; do not edit it.

Re-contexting does not empty the standby cache: `conntrackd` is restarted only when the rendered configuration changed (otherwise it is only started if it is not running), because a restart empties the caches and a BACKUP would lose all replicated flows. After a restart on a node whose last saved VRRP role (`/run/one-failover.state`) is BACKUP, the module requests a full resync from the peer (`conntrackd -n`); on a MASTER it rebuilds the internal cache and sends a bulk update (`-R`, `-B`). If the role is not known yet (boot), the `down`/`up` hook does this when the first VRRP event arrives.

When the module is disabled (or its configuration is invalid) the service is stopped and disabled, and, if `/etc/sysctl.d/97-conntrack-sync.conf` is the file this module wrote, it is removed and `nf_conntrack_tcp_be_liberal` is reset to the kernel default `0`. A sysctl file with other content is left alone. The entries in `/etc/modules` stay (loading these modules is harmless).

## How failover works

`conntrackd` runs on both nodes all the time (OpenRC service `conntrackd`). The module installs the hook `/etc/one-appliance/ha-hooks.d/20-conntrack`, which the Failover service calls with `up` or `down` when the VRRP role changes (the hook mechanism of PR #405). The hook follows the `primary-backup.sh` script of conntrack-tools:

- `up` (became MASTER): `conntrackd -s` checks that the daemon runs (it is started if not), `-c` commits the replicated entries (the external cache) into the kernel, `-f` flushes the caches, `-R` resynchronises the internal cache with the kernel table and `-B` sends a bulk update to the peer.
- `down` (became BACKUP): `conntrackd -s` checks that the daemon runs (it is started if not), `-t` shortens the timers of the kernel entries that are left over from being MASTER and `-n` requests a full resynchronisation from the peer.

The hook runs after the stock services have been restarted on `up` and before they are stopped on `down`, so on `down` its duration delays the stop of the services. Failover kills a hook after 30 seconds, so the hook is bounded much lower:

- every call runs under `timeout -k 1 N` (TERM after N seconds, KILL one second later), N is at most 3 seconds (8 for the daemon start);
- no step is started once the budget of 18 seconds is used up (the budget is measured from the start of the Ruby code and includes the shell start-up of each call), and a step is given only the time that is left, so all steps end after 19 seconds at the latest (18 + 1 s kill grace);
- the whole hook process, Ruby start-up included, runs under `timeout -k 1 21`, so the worst case is 22 seconds, 8 seconds inside the limit of 30.

A failing step (including a failed daemon start) is logged and makes the hook return a non-zero status, the hook continues with the next step, and it never blocks or aborts a failover. When the module is off, or its configuration is invalid, the hook does nothing. The context is read by the Ruby code of the hook (Failover loads it only on `up`); it is not sourced by a shell.

On `up` there is a short window between the start of forwarding by the stock services and the commit of the entries. Packets of a replicated flow that arrive in that window create a new entry, which is then not overwritten by the commit.

## Requirements

- Packages (installed at image build): `conntrack-tools` and `conntrack-tools-openrc` (Alpine 3.21: 1.4.8; the init script is in the `-openrc` package), `ruby`.
- Kernel modules `nf_conntrack`, `nfnetlink` and `nf_conntrack_netlink`. They are modules in Alpine `linux-virt`, and `nf_conntrack_netlink` is not loaded at boot on the stock image. The module loads them with `modprobe` when it is configured and appends them to `/etc/modules` so they are loaded at boot.
- `net.netfilter.nf_conntrack_tcp_be_liberal = 1` (written to `/etc/sysctl.d/97-conntrack-sync.conf` and set at configuration). The Alpine init script of conntrackd refuses to start without it (the conntrack-tools documentation asks for it with old kernels). It makes the TCP window checks of the router less strict.
- A stateful forwarding setup. Without iptables/nftables rules that use connection tracking (NAT4 has them) the kernel has no entries to replicate.

## Firewall and security groups

The module adds no firewall rules: the appliance does not install a restrictive `INPUT` policy. The synchronisation traffic is UDP on `PORT` between the two nodes on `INTERFACE` (to the multicast group without `PEER`). A security group on that NIC in OpenNebula must allow UDP `PORT` between the two nodes (and multicast, if used).

The synchronisation traffic is neither authenticated nor encrypted. conntrack-tools recommends a dedicated link; at least use a network that only the two routers can reach.

## Limits and costs

- Memory: the memory of a cache entry was not measured; with the default `HASH_LIMIT` of 65536 and two caches (internal and external) expect an order of tens of MB at most (an estimate). The stock image has 512 MB and `nf_conntrack_max` of 4096, so the default is far above what the kernel table can hold; lower `HASH_LIMIT` on small VMs.
- CPU: one vCPU runs both the forwarding and conntrackd. The daemon is mostly idle, but a high rate of new connections costs CPU for the events and the synchronisation messages. `MODE=NOTRACK` is cheaper but loses messages without recovering them.
- The external cache is not flushed by `conntrackd -f` right after `-c` ("ignoring flush command, commit still in progress" in `/var/log/one-appliance/conntrackd.log`); this is the behaviour of the conntrack-tools sequence the hook follows.
- Only connections tracked by netfilter are replicated. IPVS (LVS) connections are not covered by conntrackd. IPVS has its own synchronisation daemon (`ipvsadm --start-daemon master|backup --mcast-interface ...`); it is not implemented here and is a follow-up.
- IPv4 only.

## Tests

`tests.rb` (RSpec) covers the attribute parsing and validation, the rendered configuration, the installed files and the hook logic.
