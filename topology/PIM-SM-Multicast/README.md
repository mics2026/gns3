# PIM Sparse-Mode Multicast (FRR)

A multicast source sends to group `239.1.1.10`, and a receiver two router hops away joins that group. PIM Sparse Mode builds the delivery tree through a static Rendezvous Point (RP), then switches to the shortest path. EIGRP provides the unicast routing that PIM uses for its RPF (reverse-path forwarding) checks.

## Credit

This lab is adapted from **[Multicast-Routing](https://github.com/NGMunia/Multicast-Routing) by [NGMunia](https://github.com/NGMunia)**, which builds the same topology on Cisco IOU routers (IOS 15.7, EIGRP named mode, `ip pim sparse-mode`).

What this version changes:
- All router configs are converted from Cisco IOS to **FRR** (`zebra` + `pimd` + `eigrpd`).
- Verification uses the FRR equivalents of the IOS `show` commands.
- The Server and Receiver are configured as Linux hosts.

The original repo has no license file, so this page doesn't copy its text, configs or image. The guide and configs here are a rewrite, and the diagram below is loaded directly from the original repo. All credit for the lab design goes to the original author.

## Topology

![PIM-SM multicast topology (image from NGMunia/Multicast-Routing)](https://raw.githubusercontent.com/NGMunia/Multicast-Routing/main/Topology/Multicast.PNG)

*Diagram: [NGMunia/Multicast-Routing](https://github.com/NGMunia/Multicast-Routing/blob/main/Topology/Multicast.PNG).*

```
Server ── eth0 R1 eth2 ──10.0.0.0/30── eth0 R2 eth1 ──10.0.0.8/30── eth0 R4
172.19.0.100   eth3                 lo 192.168.0.1 (RP)               eth1
(source)        │                                                      │
           10.0.0.4/30                                           10.0.0.12/30
                │                                                      │
                └──────────────── eth0 R3 eth1 ────────────────────────┘
                                     eth2
                                      │ 10.0.0.16/30
                                     eth0
                                      R5  (last-hop router, IGMP)
                                     eth1 172.19.1.1/24
                                      │
                              Receiver 172.19.1.100
                              (joins 239.1.1.10)
```

### Nodes

| Node | Role | GNS3 node |
|---|---|---|
| R1 | First-hop router (FHR) for the source | FRR 8.2.2 (QEMU) |
| R2 | Rendezvous Point, `lo` 192.168.0.1/32 | FRR 8.2.2 |
| R3 | Transit | FRR 8.2.2 |
| R4 | Transit | FRR 8.2.2 |
| R5 | Last-hop router (LHR), runs IGMP toward the receiver | FRR 8.2.2 |
| Server | Multicast source | Any Linux host. A spare FRR appliance works, since it's Alpine Linux. |
| Receiver | Multicast receiver | Any Linux host |

VPCS can't send or join multicast, so use Linux hosts for Server and Receiver.

### Links and addressing

The interface numbers match the original lab: Cisco IOU `Ethernet0/X` becomes FRR `ethX`.

| Link | Subnet | Side A | Side B |
|---|---|---|---|
| R1 – Server | 172.19.0.0/24 | R1 eth0 `.1` | Server eth0 `.100` |
| R1 – R2 | 10.0.0.0/30 | R1 eth2 `.1` | R2 eth0 `.2` |
| R1 – R3 | 10.0.0.4/30 | R1 eth3 `.5` | R3 eth0 `.6` |
| R2 – R4 | 10.0.0.8/30 | R2 eth1 `.9` | R4 eth0 `.10` |
| R4 – R3 | 10.0.0.12/30 | R4 eth1 `.13` | R3 eth1 `.14` |
| R3 – R5 | 10.0.0.16/30 | R3 eth2 `.17` | R5 eth0 `.18` |
| R5 – Receiver | 172.19.1.0/24 | R5 eth1 `.1` | Receiver eth0 `.100` |

Differences from the diagram:
- **R4's `172.19.2.0/24` LAN** appears in the diagram but isn't configured in the original lab. It's included as an optional, commented-out block in [configs/R4.conf](configs/R4.conf).
- **R1's `Ethernet0/1`** used DHCP for internet access in the original. It isn't needed for the lab, so it's left out.

---

## 1. Build the topology in GNS3

1. Add 5 **FRR** nodes named R1–R5, plus 2 Linux hosts named **Server** and **Receiver**.
2. Cable them as in the links table above, using the exact `ethX` ports.
3. Start all nodes.

**Memory:** the GNS3 FRR appliance defaults to 256 MB per node. In this lab each node was set to **128 MB**, which is enough for FRR. Without KVM, each QEMU process still uses about 230 MB on the server, so 7 nodes need about 1.6 GB. On the 1.6 GB Ubuntu VM, the lab only ran after adding a 2 GB swapfile:

```sh
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 2. Prepare each router (daemons and interfaces)

The FRR appliance console opens at the `frr#` prompt (vtysh). Type `exit` to get the Linux shell. Then make three changes:

1. **Daemons:** the appliance already enables `pimd` and `eigrpd`, but it also starts `bgpd`, `ospfd`, `ripd` and several others, which waste memory in a 128 MB VM. Turn off everything this lab doesn't use.
2. **Interfaces:** all `ethX` interfaces start **down**, and FRR doesn't bring them up. Without this step, no neighbors form.
3. **`rp_filter`:** set it to `0` so the kernel's reverse-path filter doesn't drop multicast that PIM accepts.

On R1 (list each router's own interfaces in the `for` line):

```sh
sed -i -E 's/^(bgpd|ospfd|ospf6d|ripd|ripngd|isisd|ldpd|bfdd)=yes/\1=no/; s/^(pimd|eigrpd)=no/\1=yes/' /etc/frr/daemons

cat > /etc/local.d/lab.start <<'EOF'
#!/bin/sh
for i in eth0 eth2 eth3; do ip link set $i up; done
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done
sysctl -qw net.ipv4.ip_forward=1
EOF
chmod +x /etc/local.d/lab.start
rc-update add local default        # run it at every boot
/etc/local.d/lab.start             # and run it now
```

| Router | Interfaces to bring up |
|---|---|
| R1 | eth0 eth2 eth3 |
| R2 | eth0 eth1 |
| R3 | eth0 eth1 eth2 |
| R4 | eth0 eth1 |
| R5 | eth0 eth1 |

## 3. Apply the router configs

There's one file per router in [configs/](configs/):

| Router | Config |
|---|---|
| R1 | [configs/R1.conf](configs/R1.conf) |
| R2 | [configs/R2.conf](configs/R2.conf) |
| R3 | [configs/R3.conf](configs/R3.conf) |
| R4 | [configs/R4.conf](configs/R4.conf) |
| R5 | [configs/R5.conf](configs/R5.conf) |

On each router:

```
vtysh
configure terminal
  (paste the contents of Rx.conf)
end
write memory
```

Or, from the Linux shell, write the file as `/etc/frr/frr.conf` (add `service integrated-vtysh-config` at the end), run `chown frr:frr /etc/frr/frr.conf`, then `rc-service frr restart`. That also restarts FRR with the trimmed daemon list from step 2.

### How the IOS commands map to FRR

| Cisco IOS (original) | FRR (this lab) | Notes |
|---|---|---|
| `ip multicast-routing` | — | Not needed. Running `pimd` enables multicast routing in the Linux kernel. |
| `ip pim sparse-mode` (interface) | `ip pim` | FRR's PIM is sparse mode only. |
| `ip pim rp-address 192.168.0.1` | `ip pim rp 192.168.0.1 224.0.0.0/4` | Configure it on every router, including the RP itself. |
| `interface Loopback0` | `interface lo` | Linux loopback. Add `ip pim` so the RP address is PIM-enabled. |
| `ip igmp version 2` | `ip igmp` + `ip igmp version 2` | FRR also needs `ip igmp` to turn IGMP on. |
| `ip igmp join-group 239.1.1.10` | `ip igmp join 239.1.1.10` (FRR 8.x)<br>`ip igmp join-group 239.1.1.10` (FRR 10.x) | Optional in this lab, because the Receiver host joins instead. See the note in step 5. |
| `router eigrp EIGRP` + `address-family ipv4 unicast autonomous-system 100` | `router eigrp 100` | FRR supports classic-mode EIGRP only. |
| `network 10.0.0.0 0.0.0.3` | `network 10.0.0.0/30` | Prefix length instead of a wildcard mask. |
| `af-interface Ethernet0/0` + `passive-interface` | `passive-interface eth0` | |
| `af-interface default` + `bandwidth-percent 25` | — | Not supported in FRR. Dropped. |
| `ip address dhcp` (R1 e0/1) | — | Internet uplink, not part of the lab. Dropped. |

## 4. Configure the hosts

**Server** (the source):

```sh
ip link set eth0 up
ip addr add 172.19.0.100/24 dev eth0
ip route add default via 172.19.0.1
```

**Receiver**:

```sh
ip link set eth0 up
ip addr add 172.19.1.100/24 dev eth0
ip route add default via 172.19.1.1
ip addr add 239.1.1.10/32 dev eth0 autojoin         # join the group (sends an IGMP report)
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=0    # reply to pings sent to the group
```

In this lab, Server and Receiver are FRR appliance nodes with every FRR daemon set to `no`. To keep these settings after a reboot, put the commands in `/etc/local.d/lab.start`, as in step 2.

`autojoin` makes the kernel join `239.1.1.10` on `eth0`, so R5 sees an IGMP membership report, just as it would from a real streaming client. It needs the full `iproute2` package. On a minimal BusyBox host, install it first (`apk add iproute2` on Alpine).

## 5. Verify

Check in this order. Each step depends on the one before it.

### Unicast routing (EIGRP)

PIM relies on the unicast table for RPF checks, so this must work first.

```
show ip eigrp neighbor        # R3 should list R1, R4 and R5
show ip route eigrp           # every router should reach 192.168.0.1/32, 172.19.0.0/24 and 172.19.1.0/24
show ip rpf 172.19.0.100      # R5: RPF neighbor toward the source (10.0.0.17 via eth0)
```

### PIM neighbors and RP

```
show ip pim neighbor          # one neighbor per router-to-router link
show ip pim interface
show ip pim rp-info           # RP 192.168.0.1 for 224.0.0.0/4 on every router
```

### IGMP on the last-hop router (R5)

```
show ip igmp interface
show ip igmp groups           # 239.1.1.10 on eth1, reporter 172.19.1.100
```

### Send traffic

On the **Server**, ping the group with a TTL higher than the number of router hops. Linux sends multicast with TTL 1 by default, so without `-t` the first router drops it.

```sh
ping -t 16 -c 100 239.1.1.10
```

Replies come back as unicast from `172.19.1.100`.

### Multicast routing state

On R5, and then on R1 and R2:

```
show ip mroute                # (*,239.1.1.10) and (172.19.0.100,239.1.1.10)
show ip pim state
show ip pim upstream          # shows when R5 switches from the RP tree to the SPT
show ip mroute count          # packet counters; FRR's stand-in for "show ip mfib active"
```

### Tested result

This output is from the lab built on the Ubuntu GNS3 server (FRR 8.2.2, 128 MB per node).

```
Server:~# ping -t 16 -c 15 239.1.1.10
64 bytes from 172.19.1.100: seq=1 ttl=61 time=75.324 ms
64 bytes from 172.19.1.100: seq=2 ttl=61 time=7.076 ms
...
15 packets transmitted, 14 packets received, 6% packet loss

R5# show ip mroute
Source          Group           Flags    Proto  Input            Output
*               239.1.1.10      SC       IGMP   eth0             pimreg / eth1
172.19.0.100    239.1.1.10      ST       STAR   eth0             eth1

R1# show ip mroute
*               239.1.1.10      S        PIM    eth2             eth3
172.19.0.100    239.1.1.10      SF       STAR   eth0             eth3

R2# show ip mroute          (the RP)
*               239.1.1.10      S        PIM    lo               eth0
172.19.0.100    239.1.1.10      SRP      none   eth0             none
```

- **The first packet is lost.** It goes to the RP inside a PIM Register message while the tree is being built.
- **R5's `(S,G)` has the `T` (SPT) flag.** R1 forwards the stream straight out `eth3` to R3, which is the shortest path.
- **The RP's `(S,G)` is `SRP` (pruned).** Once the shortest-path tree is up, traffic no longer passes through R2.

### What to expect

- **R5 joins the shared tree toward the RP (R2) first.** After the first packets arrive, it switches to the shortest-path tree toward `172.19.0.100` (R5 → R3 → R1). FRR switches to the SPT immediately by default. To keep traffic on the shared tree for comparison, configure `ip pim spt-switchover infinity-and-beyond` on R5.
- **R2 (the RP) stops seeing the (S,G) traffic once the SPT is up.** Watch its `show ip mroute count` stop increasing.

**About the original's router-only test:** the original lab tested by pinging from R1 while R5 itself was joined with `ip igmp join-group`. On Linux and FRR, a router joined on `eth1` doesn't answer multicast pings that arrive on `eth0`, so this version uses a real Receiver host. R5's own join is left as an optional line in [configs/R5.conf](configs/R5.conf).

## About EIGRP

EIGRP (Enhanced Interior Gateway Routing Protocol) provides the unicast routes in this lab. PIM depends on those routes: every multicast forwarding decision starts with an RPF check against the unicast table.

EIGRP was created by Cisco and published as an informational RFC in 2016 ([RFC 7868](https://www.rfc-editor.org/rfc/rfc7868)). It's an **advanced distance-vector** protocol: each router knows only what its neighbors report, unlike OSPF, where every router keeps a map of the whole network.

### How it works

1. **Neighbors.** Routers send **Hello** packets to `224.0.0.10` (IP protocol 88) every 5 seconds. A neighbor is declared down after a 15-second **hold time**. Routers become neighbors only if their AS numbers match (`100` here), they share a subnet, and their K-values (metric weights) match.
2. **Updates.** Neighbors exchange full tables when they first meet. After that they send only changes, never periodic full updates, delivered reliably by RTP (EIGRP's Reliable Transport Protocol).
3. **Metric.** By default it uses the slowest bandwidth and the total delay along the path: `256 × (10^7 / min-bandwidth-kbps + total-delay / 10)`. R5's `show ip route` shows `[90/28160]` for its connected networks, `30720` one hop away and `33280` two hops away. The `90` is the administrative distance for internal EIGRP routes (OSPF's is 110).
4. **DUAL** (Diffusing Update Algorithm) picks the best next hop, called the **successor**, and pre-computes a loop-free backup, the **feasible successor**. A neighbor qualifies as a backup only if its own reported distance is lower than this router's best metric (the *feasibility condition*). If the successor fails, the router switches to the backup immediately. Without a backup, the route goes **Active** and the router sends **Queries** to its neighbors.

   In this lab, R5 has a single neighbor and so no backup path. R3 can reach the RP through R1 or R4. Check with `show ip eigrp topology`.

### Pros and cons

| Pros | Cons |
|---|---|
| Very fast convergence: the pre-computed feasible successor takes over immediately | Effectively Cisco-only; few other vendors implement it |
| Simple configuration: no areas to design | FRR's `eigrpd` is basic: classic mode only, no named mode, no `bandwidth-percent`, no authentication |
| Low overhead: partial updates on change only, no periodic flooding | **Stuck-in-Active**: in large networks without summarization or stub routers, Queries spread widely and neighbors can be reset |
| Metric based on bandwidth and delay, not hop count | Each router sees less of the network than with OSPF's link-state database, which makes troubleshooting harder |
| Unequal-cost load balancing (`variance`) | No traffic engineering (MPLS-TE or Segment Routing) |
| Loop-free by design (DUAL) | Mismatched K-values or changed `bandwidth`/`delay` settings cause surprises |

### EIGRP vs OSPF

| | EIGRP | OSPF |
|---|---|---|
| Type | Advanced distance-vector | Link-state |
| Standard | Cisco; published as RFC 7868 | Open standard (RFC 2328) |
| Metric | Bandwidth + delay | Cost (from bandwidth) |
| Convergence | Very fast with a feasible successor | Fast; reruns the SPF calculation |
| Design | Flat, simple | Areas, more planning |
| Unequal-cost load balancing | Yes | No |
| Multi-vendor / FRR support | Limited | Universal, mature |
| Administrative distance | 90 internal, 170 external | 110 |

This lab keeps EIGRP to match the original Cisco design. On FRR in production, OSPF is the safer choice, as shown in the next section. PIM works the same with either protocol.

```
show ip eigrp neighbor
show ip eigrp topology        # successors, feasible distances, feasible successors
show ip eigrp interface
show ip route eigrp
```

## Alternative: OSPF instead of EIGRP

FRR's `eigrpd` is less mature than its OSPF daemon. If EIGRP neighbors don't come up, use OSPF instead: set `ospfd=yes` in `/etc/frr/daemons`, remove `router eigrp 100`, and add the following (shown here for R1). PIM works the same over any unicast routing protocol.

```
router ospf
 ospf router-id 1.1.1.1
 network 10.0.0.0/30 area 0
 network 10.0.0.4/30 area 0
 network 172.19.0.0/24 area 0
 passive-interface eth0
```

For the other routers, use the same `network` statements as their EIGRP config, each with `area 0`. Then check with `show ip ospf neighbor`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `% Unknown command` for `ip pim` or `router eigrp` | `pimd` or `eigrpd` isn't running. Enable it in `/etc/frr/daemons` and restart FRR (step 2). Check with `show daemons` in vtysh, if your FRR version has it. |
| No EIGRP or PIM neighbors | Check `ip -br link`. The appliance's `ethX` interfaces start **down**, so run the `ip link set ... up` lines from step 2. Then check the cabling against the links table. Fall back to OSPF if needed. |
| GNS3 server restarts and all nodes stop | The VM ran out of memory. Check `sudo dmesg | grep -i "killed process"`. Lower node RAM to 128 MB, add swap, or give the VM more RAM (step 1). |
| `show ip pim rp-info` shows the RP as unreachable | The router has no route to `192.168.0.1/32`. Fix unicast routing first, and check that R2 advertises `network 192.168.0.1/32`. |
| No IGMP group on R5 | The Receiver didn't join. Check that `ip addr show eth0` on the Receiver lists `239.1.1.10`, and that R5 eth1 has `ip igmp`. |
| Server pings get no reply | Use `-t 16` on the ping. Set `icmp_echo_ignore_broadcasts=0` on the Receiver. Check that R1 eth0 has `ip pim` so R1 registers the source with the RP. |
| `(S,G)` stays on the RP path | That's expected right after the first packet. Check `show ip pim upstream` a few seconds later. If `spt-switchover infinity-and-beyond` is set, it never switches. |
