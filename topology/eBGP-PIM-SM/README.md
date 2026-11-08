# eBGP + PIM Sparse Mode (3-router triangle, FRR)

Three routers, each in its own BGP autonomous system, connected in a triangle. eBGP exchanges the unicast routes, and PIM-SM builds the multicast tree from those routes. One host sends to group `239.1.1.1`, and two hosts behind the other routers receive it.

| Protocol | Job in this lab |
|---|---|
| **eBGP** | Exchanges unicast routes between AS 65001, 65002 and 65003 |
| **PIM-SM** | Builds the multicast distribution tree. Its RPF check uses the unicast routes learned by BGP. |
| **IGMP** | Lets the receivers tell R2 and R3 they want group `239.1.1.1` |
| **RP** | Rendezvous Point `10.255.0.1`, on R1's loopback |

No BGP multicast address family (`ipv4 multicast`, the MP-BGP extension that carries routes just for multicast RPF) is needed. FRR's PIM does its RPF lookups in the normal IPv4 unicast routing table, so it uses BGP routes like any others.

Compared with the [PIM-SM multicast lab](../PIM-SM-Multicast/README.md), this one swaps EIGRP for eBGP and uses a smaller topology, so you can focus on how **BGP route changes move the multicast tree**.

## Topology

![PIM-SM / BGP multicast topology](PIM-SM%20BGP%20Multicast%20Topology.png)

### Interface map

```
                       H1 192.168.10.10 (source → 239.1.1.1)
                        │
                       SW1
                        │ eth2 192.168.10.1/24
                  ┌──── R1 ────┐   AS 65001, RP lo 10.255.0.1/32
       10.0.12.0/30   eth0    eth1   10.0.13.0/30
                  │            │
             eth0 │            │ eth0
   AS 65002      R2 ── eth1 ── eth1 ── R3      AS 65003
                  │   10.0.23.0/30     │
             eth2 │ 192.168.20.1/24    │ eth2 192.168.30.1/24
                 SW2                  SW3
                  │                    │
           H2 192.168.20.10     H3 192.168.30.10
           (receiver)           (receiver)
```

### Nodes

| Node | Role | GNS3 node |
|---|---|---|
| R1 | AS 65001, RP, first-hop router for the source | FRR 8.2.2 (QEMU) |
| R2 | AS 65002, last-hop router for H2 | FRR 8.2.2 |
| R3 | AS 65003, last-hop router for H3 | FRR 8.2.2 |
| SW1, SW2, SW3 | Plain L2 switches (no configuration) | GNS3 built-in Ethernet switch |
| H1 | Multicast source | Linux host (an FRR appliance with all FRR daemons off) |
| H2, H3 | Multicast receivers | Linux host |

VPCS can't send or join multicast, so H1–H3 must be Linux hosts.

### Addressing and AS numbers

| Router | AS | eth0 | eth1 | eth2 (LAN) | lo |
|---|---|---|---|---|---|
| R1 | 65001 | 10.0.12.1/30 → R2 | 10.0.13.1/30 → R3 | 192.168.10.1/24 → SW1 | 10.255.0.1/32 (RP) |
| R2 | 65002 | 10.0.12.2/30 → R1 | 10.0.23.1/30 → R3 | 192.168.20.1/24 → SW2 | — |
| R3 | 65003 | 10.0.13.2/30 → R1 | 10.0.23.2/30 → R2 | 192.168.30.1/24 → SW3 | — |

| Host | eth0 | Default gateway | Role |
|---|---|---|---|
| H1 | 192.168.10.10/24 | 192.168.10.1 | Source, sends to 239.1.1.1 |
| H2 | 192.168.20.10/24 | 192.168.20.1 | Receiver |
| H3 | 192.168.30.10/24 | 192.168.30.1 | Receiver |

### Links

| Link | A | B |
|---|---|---|
| R1 – R2 | R1 eth0 | R2 eth0 |
| R1 – R3 | R1 eth1 | R3 eth0 |
| R2 – R3 | R2 eth1 | R3 eth1 |
| R1 – SW1 | R1 eth2 | SW1 Ethernet0 |
| H1 – SW1 | H1 eth0 | SW1 Ethernet1 |
| R2 – SW2 | R2 eth2 | SW2 Ethernet0 |
| H2 – SW2 | H2 eth0 | SW2 Ethernet1 |
| R3 – SW3 | R3 eth2 | SW3 Ethernet0 |
| H3 – SW3 | H3 eth0 | SW3 Ethernet1 |

---

## 1. Build the topology in GNS3

1. Add 3 FRR nodes named **R1–R3**, 3 more FRR nodes named **H1–H3**, and 3 **Ethernet switch** nodes named **SW1–SW3**. The switches need no configuration: their default ports are all access VLAN 1.
2. Cable everything as in the links table, using the exact `ethX` ports.
3. **Memory:** set each FRR node's RAM to **128 MB** (right-click → **Configure** → **RAM**). Without KVM, each QEMU node uses about 230 MB on the server, so the 6 nodes need about 1.4 GB. On the 1.6 GB Ubuntu VM that needs the 2 GB swapfile from the [PIM-SM lab](../PIM-SM-Multicast/README.md#1-build-the-topology-in-gns3). Stop other labs first.
4. Start all nodes.

## 2. Prepare each router (daemons and interfaces)

The FRR appliance console opens at the `frr#` prompt (vtysh). Type `exit` to get the Linux shell, then:

```sh
sed -i -E 's/^(ospfd|ospf6d|ripd|ripngd|isisd|ldpd|bfdd|eigrpd)=yes/\1=no/; s/^(bgpd|pimd)=no/\1=yes/' /etc/frr/daemons

cat > /etc/local.d/lab.start <<'EOF'
#!/bin/sh
for i in eth0 eth1 eth2; do ip link set $i up; done
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done
sysctl -qw net.ipv4.ip_forward=1
EOF
chmod +x /etc/local.d/lab.start
rc-update add local default
/etc/local.d/lab.start
rc-service frr restart
```

- **Daemons:** the appliance enables `bgpd` and `pimd` already, but also starts several daemons this lab doesn't use. The `sed` line keeps only `bgpd` and `pimd` (`zebra` and `staticd` always run).
- **Interfaces:** every `ethX` starts **down**, and FRR doesn't bring them up. The startup script does it at every boot.
- **`rp_filter = 0`:** stops the kernel's reverse-path filter from dropping multicast that PIM accepts, especially after a reroute.

## 3. Apply the router configs

| Router | Config |
|---|---|
| R1 | [configs/R1.conf](configs/R1.conf) |
| R2 | [configs/R2.conf](configs/R2.conf) |
| R3 | [configs/R3.conf](configs/R3.conf) |

On each router:

```
vtysh
configure terminal
  (paste the contents of Rx.conf)
end
write memory
```

### What the configs do

- **`ip pim` on every interface,** including R1's LAN (so R1 can register the source with the RP) and R1's `lo` (the RP address must be PIM-enabled).
- **`ip igmp` on R2 and R3's LAN interfaces,** where the receivers are.
- **`ip pim rp 10.255.0.1 239.0.0.0/8` on all three routers.** It's a static RP for the 239.0.0.0/8 range, and the RP itself needs it too.
- **Each router advertises its LAN with `network`.** R1 also advertises the RP address `10.255.0.1/32`. The /30 links between routers aren't advertised, because PIM's RPF neighbors are always on directly connected links.
- **`no bgp ebgp-requires-policy`:** FRR doesn't advertise or accept any eBGP routes without route-maps unless this is set. Fine in a lab; a production network should use explicit inbound and outbound policies.
- **`timers bgp 3 9`:** 3-second keepalives and a 9-second hold time. GNS3's **Suspend link** doesn't take the interface down, so BGP only notices a dead neighbor when its hold timer expires. FRR's default is 180 seconds; this lowers it to 9.

### Changes from the original design

| Original line | Used here | Why |
|---|---|---|
| `ip pim sm` | `ip pim` | FRR 8.x syntax. `ip pim sm` is the old, deprecated form. |
| `router pim` + `rp 10.255.0.1 239.0.0.0/8` | `ip pim rp 10.255.0.1 239.0.0.0/8` | `router pim` only exists in FRR 10.x. FRR 8.2.2 needs the global command, which FRR 10.x still accepts. |
| (none) | `timers bgp 3 9` | Makes the failover tests converge in seconds instead of minutes |

## 4. Configure the hosts

On each host, after `exit` to the shell, turn FRR off and set the address. Put the commands in `/etc/local.d/lab.start` (as in step 2) to keep them after a reboot.

**H1** (source):

```sh
sed -i -E 's/^([a-z0-9]+d)=yes/\1=no/' /etc/frr/daemons && rc-service frr restart
ip link set eth0 up
ip addr add 192.168.10.10/24 dev eth0
ip route replace default via 192.168.10.1
```

**H2** (receiver):

```sh
sed -i -E 's/^([a-z0-9]+d)=yes/\1=no/' /etc/frr/daemons && rc-service frr restart
ip link set eth0 up
ip addr add 192.168.20.10/24 dev eth0
ip route replace default via 192.168.20.1
ip addr add 239.1.1.1/32 dev eth0 autojoin          # join the group (sends an IGMP report)
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=0    # reply to pings sent to the group
```

**H3** (receiver): the same as H2, with `192.168.30.10/24` and gateway `192.168.30.1`.

## 5. Verify

Run these in `vtysh` on the routers.

### BGP

```
show bgp ipv4 unicast summary     # 2 established sessions on each router
show ip route bgp                 # R2 and R3: 192.168.10.0/24 and 10.255.0.1/32 via R1
show bgp ipv4 unicast 192.168.10.0/24   # R2: best path AS 65001 direct, backup 65003 65001
```

### PIM and IGMP

```
show ip pim neighbor              # 2 neighbors on each router
show ip pim rp-info               # RP 10.255.0.1 for 239.0.0.0/8
show ip rpf 192.168.10.10         # R2 and R3: RPF neighbor is R1
show ip igmp groups               # R2 and R3: 239.1.1.1 on eth2
```

### Send traffic

On **H1**:

```sh
ping -t 16 -c 20 239.1.1.1
```

Linux sends multicast with TTL 1 by default, so `-t 16` is needed. Replies arrive from **both** receivers, `192.168.20.10` and `192.168.30.10`. One of each pair is marked `(DUP!)`, because one request produces two replies.

```
show ip mroute                    # R1: (S,G) in eth2, out eth0 and eth1
show ip pim state
show ip pim upstream
show ip mroute count
```

## 6. Failover tests

Keep a ping running on H1 (`ping -t 16 239.1.1.1`) while you test. To cut a link, right-click it in GNS3 and choose **Suspend**. Choose **Resume** to restore it.

| Test | Action | Expected behavior |
|---|---|---|
| 1 | Start all routers | 3 eBGP sessions established, one per side of the triangle |
| 2 | Check RP reachability | R2 and R3 have `10.255.0.1/32` via BGP |
| 3 | Receivers join | `show ip igmp groups` on R2 and R3 lists `239.1.1.1` |
| 4 | Send multicast from H1 | H2 and H3 both reply |
| 5 | Suspend **R1–R2** | After about 9 s (the BGP hold time), R2 learns `192.168.10.0/24` and `10.255.0.1/32` via R3 (AS path `65003 65001`). Its RPF interface moves to `eth1`, and traffic to H2 flows **R1 → R3 → R2**. |
| 6 | Resume R1–R2 | BGP re-forms, the shorter path `65001` wins again, and traffic returns to R1 → R2 |
| 7 | Suspend **R1–R3** | H3 receives through R2 instead: **R1 → R2 → R3** |

What to watch on R2 during test 5:

```
show bgp ipv4 unicast summary     # R1's session goes from Established to Active/Connect
show ip route 192.168.10.10       # next hop changes from 10.0.12.1 to 10.0.23.2
show ip rpf 192.168.10.10         # RPF interface changes from eth0 to eth1
show ip mroute                    # (S,G) input interface changes to eth1
```

How it works: **BGP changes the unicast path → PIM's RPF check picks the new upstream interface → PIM sends a Join out that interface → the multicast tree moves.** Pings stop for roughly the hold time plus a few seconds, then resume.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| BGP sessions stuck in `Active` or `Connect` | Interfaces down: check `ip -br link` and run step 2. Check the cabling and that each `neighbor` address matches the peer's IP. |
| Sessions up but `(Policy)` shown and no routes | `no bgp ebgp-requires-policy` is missing on that router |
| `show ip route bgp` is missing a LAN | The `network` statement must exactly match a connected prefix, such as `192.168.20.0/24` |
| `% Unknown command: router pim` | You're on FRR 8.x. Use the global `ip pim rp ...` command instead. |
| No IGMP group on R2 or R3 | Check that the receiver ran the `autojoin` line (`ip addr show eth0` lists `239.1.1.1`), and that eth2 has `ip igmp` |
| H1 gets no replies | Use `ping -t 16`. Set `icmp_echo_ignore_broadcasts=0` on the receivers. Check that R1 eth2 has `ip pim`. |
| Failover takes about 3 minutes | `timers bgp 3 9` is missing, so FRR uses its 180 s default hold time |
| Traffic doesn't move after failover | Check `show ip rpf 192.168.10.10` on the router that lost its link. If RPF moved but `show ip mroute` didn't, wait for the next PIM join (up to 60 s) or check `rp_filter` is `0`. |

## References

- [FRRouting – PIM Sparse Mode and IGMP](https://docs.frrouting.org/en/latest/pim.html)
- [FRRouting – BGP](https://docs.frrouting.org/en/latest/bgp.html)
- [GNS3 documentation](https://docs.gns3.com/)
