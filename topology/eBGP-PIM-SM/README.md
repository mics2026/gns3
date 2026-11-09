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
3. **Memory:** set R1–R3 to **128 MB** and H1–H3 to **256 MB** (right-click → **Configure** → **RAM**). The hosts need the extra memory to install and run VLC (step 7); 128 MB is enough if you only use `ping`. Without KVM, each QEMU node uses about 230 MB or more on the server, so the 6 nodes need about 1.6 GB. On the 1.6 GB Ubuntu VM that needs the 2 GB swapfile from the [PIM-SM lab](../PIM-SM-Multicast/README.md#1-build-the-topology-in-gns3). Stop other labs first.
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

## 7. Stream video with VLC

Pings prove the multicast tree works. A video stream shows the same tree carrying real traffic. Here, H1 streams a video file to `239.1.1.1` with VLC, and H2 and H3 receive it with VLC.

This section records how VLC was installed on H1–H3 in the `PIM-SM-BGP` GNS3 project on 2026-11-08, and how to use it.

### What gets installed

| Item | Value |
|---|---|
| Host OS | Alpine Linux 3.16.3 (the GNS3 FRR 8.2.2 appliance) |
| Package | `vlc` 3.0.17.3-r5 from the Alpine v3.16 `community` repo |
| Dependencies | 156 packages in total, including FFmpeg 4, GTK 3, Mesa, PulseAudio, x264/x265, libsmbclient and fonts |
| Disk used | About 190 MB (root filesystem went from 69 MB to 262 MB used; 121 MB left on each host) |
| Memory needed | 256 MB guest RAM. **At 128 MB, `apk` was killed by the out-of-memory killer** (`APK_RC=137`, `Out of memory: Killed process (apk)`) partway through the install. |
| Runs as | A normal user, `vlc`. VLC refuses to run as root (`VLC is not supposed to be run as root. Sorry.`). |
| Test video | `/home/vlc/bbb.mp4` on H1: *Big Buck Bunny*, a 10-second 640×360 H.264 clip (991 KB), © Blender Foundation, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), downloaded from test-videos.co.uk |

The hosts only have the lab network, which has no internet. So the install uses a **temporary GNS3 NAT node**. GNS3's NAT node on the Ubuntu server connects to libvirt's `virbr0` bridge (`192.168.122.0/24`), whose DHCP server hands out addresses and NATs traffic out through the VM's own internet connection.

### 7.1 Give H1–H3 256 MB of RAM

Stop H1–H3. Right-click each one and choose **Configure** → set **RAM** to **256 MB**. Then start them again.

### 7.2 Add a temporary internet connection

1. Add a **NAT** node (GNS3 names it `NAT1`) and an **Ethernet switch** named `SW-NET`.
2. Cable them:

   | Link | A | B |
   |---|---|---|
   | NAT – SW-NET | NAT1 nat0 | SW-NET Ethernet0 |
   | H1 – SW-NET | H1 **eth1** | SW-NET Ethernet1 |
   | H2 – SW-NET | H2 **eth1** | SW-NET Ethernet2 |
   | H3 – SW-NET | H3 **eth1** | SW-NET Ethernet3 |

   This uses each host's spare `eth1`, so the lab cabling on `eth0` stays untouched.
3. Start NAT1 and SW-NET.

### 7.3 Install VLC on each host

On each host's console (type `exit` if it opens at `frr#`):

```sh
# Turn FRR off on the host. It isn't needed and frees memory for apk.
sed -i -E 's/^([a-z0-9]+d)=yes/\1=no/' /etc/frr/daemons && rc-service frr restart

# Get an address from the NAT node's DHCP server (192.168.122.x).
ip link set eth1 up
udhcpc -i eth1 -n -q
ip -br addr show eth1          # e.g. eth1 UP 192.168.122.6/24
ping -c 2 dl-cdn.alpinelinux.org

# Install VLC. /etc/apk/repositories already lists v3.16 main and community.
apk update
apk add vlc                    # 156 packages; takes several minutes under emulation
cvlc --version 2>&1 | head -1  # prints the "don't run as root" message, which is expected

# Create the user that will run VLC.
adduser -D -s /bin/sh vlc
```

`udhcpc` also adds a default route through `192.168.122.1`, which is what gives the host internet access. The next step removes it.

**On H1 only,** download the test video while the internet link is up:

```sh
wget -O /home/vlc/bbb.mp4 https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4
chown vlc:vlc /home/vlc/bbb.mp4
```

You can run the installs on all three hosts at the same time, for example by running `apk add vlc > /tmp/vlc-install.log 2>&1 &` on each and checking the log later.

### 7.4 Remove the internet connection

On each host, take `eth1` down and restore the lab addressing:

```sh
ip addr flush dev eth1
ip link set eth1 down
/etc/local.d/lab.start      # re-applies the eth0 address and the lab default route
```

Then delete **NAT1** and **SW-NET** in GNS3. Deleting a node also deletes its links. The project is back to the 9 lab links.

To keep `eth1` down after a reboot, put the two `eth1` lines at the top of each host's `/etc/local.d/lab.start`. On H1, for example:

```sh
#!/bin/sh
ip addr flush dev eth1 2>/dev/null
ip link set eth1 down
ip link set eth0 up
ip addr add 192.168.10.10/24 dev eth0 2>/dev/null
ip route replace default via 192.168.10.1
sysctl -qw net.ipv4.ip_forward=0
```

H2 and H3 use their own addresses (step 4) and also keep the `autojoin` and `icmp_echo_ignore_broadcasts` lines.

### 7.5 Stream

Start the receivers first. On **H2** and **H3**:

```sh
su vlc -c "cvlc -I dummy udp://@239.1.1.1:5004 --sout file/ts:/tmp/rx.ts"
```

Then on **H1**:

```sh
su vlc -c "cvlc -I dummy --loop /home/vlc/bbb.mp4 --sout '#std{access=udp,mux=ts,dst=239.1.1.1:5004}' --ttl=16"
```

| Option | Meaning |
|---|---|
| `-I dummy` | No user interface (the hosts have no display) |
| `udp://@239.1.1.1:5004` | Receive: join group `239.1.1.1` (VLC sends the IGMP join) and listen on UDP port 5004 |
| `--sout file/ts:/tmp/rx.ts` | Receive: save the incoming stream to a file instead of playing it |
| `--loop` | Send: repeat the 10-second clip |
| `--sout '#std{access=udp,mux=ts,dst=239.1.1.1:5004}'` | Send: wrap the video in MPEG-TS and send it as UDP to the group |
| `--ttl=16` | Send: multicast TTL. The default of 1 would stop at R1. |

Stop VLC with **Ctrl+C**. Check the result on the receivers with `ls -la /tmp/rx.ts`. The file grows while the stream runs.

While H1 streams, check the routers:

```
show ip mroute                    # R1: (192.168.10.10, 239.1.1.1) with flags SFT
show ip mroute count              # packet counters increase
```

To watch the stream move during a failover, suspend the R1–R2 link while H1 streams (step 6, test 5). H2's file stops growing for about the BGP hold time, then grows again once traffic flows through R3.

### Tested result

```
H1:~# ping -t 16 -c 6 239.1.1.1
64 bytes from 192.168.30.10: seq=1 ttl=62 time=50.345 ms
64 bytes from 192.168.20.10: seq=1 ttl=62 time=51.238 ms (DUP!)
...
6 packets transmitted, 5 packets received, 5 duplicates, 16% packet loss

R1# show ip mroute
Source          Group           Flags    Proto  Input            Output
*               239.1.1.1       S        PIM    lo               eth0
192.168.10.10   239.1.1.1       SFT      STAR   eth2             eth0 / eth1

After H1 streamed for 20 seconds:
H2:~# ls -la /tmp/rx.ts
-rw-r--r--    1 vlc      vlc        1654400 Nov  9 00:46 /tmp/rx.ts
H3:~# ls -la /tmp/rx.ts
-rw-r--r--    1 vlc      vlc        1651016 Nov  9 00:46 /tmp/rx.ts
```

Both receivers saved about 1.65 MB of MPEG-TS, which is about two loops of the 10-second clip.

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
| `apk add vlc` stops with `Killed` (exit code 137) | The host ran out of memory. Give it 256 MB of RAM (step 7.1) and run `apk add vlc` again; it continues where it stopped. |
| `udhcpc` gets no lease on `eth1` | NAT1 isn't started, or `eth1` isn't cabled to SW-NET. On the Ubuntu VM, libvirt's `virbr0` network must exist (`ip -br addr show virbr0` → `192.168.122.1/24`). |
| `VLC is not supposed to be run as root. Sorry.` | Run VLC as the `vlc` user: `su vlc -c "cvlc ..."` |
| Receivers' `/tmp/rx.ts` stays empty | The sender needs `--ttl=16`. Check that `show ip igmp groups` on R2 and R3 lists `239.1.1.1`, and that the ping test works first. |
| Traffic doesn't move after failover | Check `show ip rpf 192.168.10.10` on the router that lost its link. If RPF moved but `show ip mroute` didn't, wait for the next PIM join (up to 60 s) or check `rp_filter` is `0`. |

## References

- [FRRouting – PIM Sparse Mode and IGMP](https://docs.frrouting.org/en/latest/pim.html)
- [FRRouting – BGP](https://docs.frrouting.org/en/latest/bgp.html)
- [GNS3 documentation](https://docs.gns3.com/)
