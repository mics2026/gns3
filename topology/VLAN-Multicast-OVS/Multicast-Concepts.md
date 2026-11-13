# Multicast Concepts and FRR Checks (VLAN-Multicast-OVS lab)

This page explains the multicast behavior you see in the [VLAN-Multicast-OVS lab](README.md): which device does what, how to read FRR's output, how long entries stay, and which commands to use. The setup steps are in the [lab guide](README.md).

Lab recap: **VLC-Sender** `192.168.20.10` (VLAN 20) streams to group `239.1.1.1:5004`. **IGMP-Receiver** `192.168.10.10` (VLAN 10) joins it. **R1** (FRR) routes between the VLANs over one 802.1Q trunk through **SW1** (Open vSwitch). R1 is the first-hop router, the RP and the last-hop router at the same time.

## Contents

1. [Who does what](#1-who-does-what)
2. [Why the config has an RP (PIM-SM vs static multicast)](#2-why-the-config-has-an-rp-pim-sm-vs-static-multicast)
3. [Reading `show ip mroute`](#3-reading-show-ip-mroute)
4. [How long entries stay](#4-how-long-entries-stay)
5. [The IGMP querier](#5-the-igmp-querier)
6. [IGMP on the router vs IGMP snooping on the switch](#6-igmp-on-the-router-vs-igmp-snooping-on-the-switch)
7. [FRR commands to check multicast](#7-frr-commands-to-check-multicast)
8. [Running the VLC scripts and common mistakes](#8-running-the-vlc-scripts-and-common-mistakes)

---

## 1. Who does what

| Device | Role | Multicast protocol activity |
|---|---|---|
| **VLC-Sender** | Source | Just sends UDP to `239.1.1.1:5004` with TTL 16. A source never joins or speaks IGMP. |
| **SW1** (OVS) | L2 switch | Carries VLANs 10 and 20. **IGMP snooping** listens to joins so it can limit each group to the ports that asked. It never sends queries. |
| **R1** (FRR) | Router-on-a-stick | **IGMP querier** on VLAN 10. **PIM-SM**: the RP for `239.0.0.0/8`, plus first-hop and last-hop router. Routes the stream `eth0.20 → eth0.10`. |
| **IGMP-Receiver** | Receiver | Sends an IGMP **report** (join) when VLC starts, answers R1's queries, and sends a **leave** when VLC stops |

**Why TTL 16?** Linux sends multicast with TTL 1 by default. A router won't forward a packet whose TTL would reach 0, so R1 would drop it. The sender uses TTL 16, and R1 decrements it to 15.

## 2. Why the config has an RP (PIM-SM vs static multicast)

[configs/R1.conf](configs/R1.conf) contains:

```
ip pim rp 192.168.20.1 239.0.0.0/8
```

That's because R1.conf is **dynamic PIM-SM** (the guide's Test B). It isn't static multicast.

### Why PIM-SM needs an RP

For a group like `239.1.1.1` (any-source multicast, ASM), the receiver's join means "send me this group from **any** source". The router doesn't know where the sources are, so PIM-SM uses a meeting point, the **Rendezvous Point (RP)**:

1. The receiver's IGMP join makes R1 build a **(\*,G)** entry that points toward the RP.
2. The source's first packets are **registered** with the RP.
3. The RP joins the two, then the path switches to a direct **(S,G)** shortest-path tree.

Without an RP mapping, step 1 has nowhere to point, and FRR forwards nothing for `239.x.x.x`. In this one-router lab, the RP is R1's own VLAN 20 address. It looks redundant, but pimd still needs it to build the tree.

**SSM is the exception.** `232.0.0.0/8` is the Source-Specific Multicast range, FRR's default. With SSM, the receiver names the source in an IGMPv3 join (`192.168.20.10@232.1.1.1`), so no meeting point is needed and no RP is used.

### Static multicast is different

| | PIM-SM (current `R1.conf`, Test B) | Static (Test A) |
|---|---|---|
| RP | **Required** for `239.0.0.0/8` | Not used |
| Outgoing interface | Learned from IGMP joins | Configured by hand |
| If the receiver leaves | Traffic stops | Traffic keeps flowing |
| Config | `ip pim`, `ip igmp`, `ip pim rp …` | `ip mroute eth0.10 239.1.1.1 192.168.20.10` under `interface eth0.20`, no RP |

In FRR, a static `ip mroute` is still handled by pimd, so `ip pim` stays on the interfaces even for static multicast. Only the RP and the dynamic joins go away. The way to avoid PIM entirely is **SMCRoute**, which writes static multicast routes straight into the Linux kernel.

> Test A has **not been run** in this lab yet, so the `ip mroute` syntax above is unverified.

## 3. Reading `show ip mroute`

Captured on R1 with both scripts running:

```
Source          Group           Flags    Proto  Input            Output            TTL  Uptime
*               239.1.1.1       SC       IGMP   eth0.20          pimreg            1    00:15:38
                                         IGMP                    eth0.10           1
192.168.20.10   239.1.1.1       SFT      STAR   eth0.20          eth0.10           1    00:14:58
```

### The (\*,G) line: "someone wants this group"

`mcast-receiver start` creates it. VLC sends an IGMP join for `239.1.1.1` when it starts.

| Field | Value | Meaning |
|---|---|---|
| Source | `*` | Any source. The receiver didn't name one (ASM). |
| Group | `239.1.1.1` | The group that was joined |
| Flags | `S` | **Sparse mode**: forward only where someone asked |
| | `C` | **Connected**: the receiver is on a network directly attached to R1 |
| Proto | `IGMP` | The outgoing interfaces come from a host's IGMP join. A join from another router would show `PIM`. |
| Input | `eth0.20` | The interface toward the **RP** (`192.168.20.1`). Every (\*,G) points at the RP; that's the shared tree. |
| Output | `eth0.10` | Where the receiver is (VLAN 10) |
| | `pimreg` | pimd's virtual **register** interface, not a real port. It's how the RP takes in source traffic wrapped in PIM Register messages. In a one-router lab it's internal plumbing. |
| TTL | `1` | The minimum TTL a packet needs to go out that interface. It's a threshold, not the packet's TTL. |
| Uptime | `00:15:38` | Time since the receiver joined |

### The (S,G) line: "traffic from this source is flowing"

`mcast-sender start` creates it, when the first packets from `192.168.20.10` arrive on `eth0.20`.

| Flag / field | Meaning |
|---|---|
| `S` | Sparse mode |
| `F` | **Register flag**: R1 is the first-hop router for this source and registered it with the RP (itself) |
| `T` | **SPT bit**: traffic is on the shortest-path tree for this source |
| Proto `STAR` | The outgoing interfaces were inherited from the (\*,G) entry |
| `eth0.20 → eth0.10` | In from the sender's VLAN, out to the receiver's VLAN: inter-VLAN multicast over one trunk |

### Reading the timeline

The uptimes give the order of events. The receiver joined (15:38 ago), the sender started about 40 seconds later (14:58 ago), and both have been running ever since.

| What's running | What `show ip mroute` shows |
|---|---|
| Nothing | Empty |
| Receiver only | (\*,G) line only. R1 knows who wants the group, but no traffic has arrived yet. |
| Receiver + sender | (\*,G) + (S,G) with `SFT` |
| Sender only | Nothing is forwarded into VLAN 10, because nobody joined |

## 4. How long entries stay

An entry in the table **doesn't mean traffic is flowing**. Each entry has its own timer.

| Entry | What keeps it alive | When it disappears |
|---|---|---|
| (S,G) `192.168.20.10, 239.1.1.1` | Traffic from the source. Each packet resets its **Keepalive Timer (KAT)**. | About **210 s** (3½ min) after the sender stops. FRR may use the RP's 185 s timer here, because R1 is the RP. |
| (\*,G) `*, 239.1.1.1` | The receiver's **IGMP membership** (independent of the sender) | About **70 s** after the receiver leaves: 2 × the 30 s query interval + 10 s response time |

So after `mcast-sender stop`, the (S,G) line stays for a few minutes, and the (\*,G) stays as long as the receiver is joined. These are FRR's default timer values. They haven't been measured in this lab.

**Watch the keepalive count down:** run `show ip pim upstream` and look at the **KATimer** column. It's reset continually while traffic flows, and counts down to zero once the sender stops.

**Check whether traffic is really flowing:** run `show ip mroute count` twice, a few seconds apart. If **Packets** for the (S,G) doesn't change, the stream has stopped, even if the entry is still listed. **LastUsed** keeps growing.

**Clear everything at once (lab only):** run `clear ip mroute`. Active joins rebuild their entries within one query interval (30 s).

## 5. The IGMP querier

**R1 is the querier**, on `eth0.10` (VLAN 10), from `192.168.10.1`.

- **Why R1:**
  - `ip igmp` on `eth0.10` makes R1 a querier candidate.
  - When several IGMP routers share a network, the one with the **lowest IP address** wins the querier election. R1 is the only router in VLAN 10, so it wins.
- **VLAN 20 has no querier.** `eth0.20` has no `ip igmp`, because no receivers live there.

```
frr# show ip igmp interface
Interface   State  Address       V  Querier  QuerierIp     Query Timer
eth0.10     up     192.168.10.1  3  local    192.168.10.1  00:00:08
eth0.20     mtrc   192.168.20.1  3  other    192.168.20.1  --:--:--
```

`Querier local` means R1 itself. The Query Timer counts down to the next query. `mtrc` on `eth0.20` is only FRR's multicast-traceroute support.

| Setting | Value | From |
|---|---|---|
| Version | IGMPv3, also accepts v2 reports | `ip igmp version 3` |
| General query | Every **30 s**, sent to `224.0.0.1` (all hosts) | `ip igmp query-interval 30` (the default is 125 s) |
| Max response time | 10 s | Default |
| Membership timeout | About 70 s | 2 × query interval + response time |

The others don't send queries. The receiver sends only **reports** and **leaves**. SW1 (OVS) only listens, because OVS can't act as an IGMP querier. The sender takes no part in IGMP.

**If R1 stopped querying,** the receiver's membership would time out after about 70 s. R1 would drop the (\*,G), and SW1's snooping entry would expire. That's why a network with IGMP snooping needs a querier.

## 6. IGMP on the router vs IGMP snooping on the switch

| | Where | Job | Required? |
|---|---|---|---|
| **IGMP** | R1 (`ip igmp` on `eth0.10`) | Learns which **VLANs** have receivers, so R1 routes the group there. That creates the (\*,G). | **Yes.** Without it, R1 never sends the stream into VLAN 10. |
| **IGMP snooping** | SW1 | Within one VLAN, sends a group only to the **ports** that joined | **No.** It only saves bandwidth. |

**Without snooping,** a switch floods multicast to every port in the VLAN, like broadcast. In this lab each VLAN has one host port plus the trunk, so flooding and snooping send the stream to the same ports. Snooping saves nothing here, and SW1 has it enabled only to show how it works.

**Snooping matters when:**
- a VLAN has many hosts but only a few receivers;
- streams are high-bandwidth (video, IPTV);
- clients are on Wi-Fi, where flooded multicast uses everyone's airtime.

**Snooping can break multicast.** Snooping sends a group only to ports that joined, plus the port where it believes the multicast router is. R1 queries only on VLAN 10, so in VLAN 20 SW1 never learns where the router is, and it would drop the source's stream. The fix in [configs/SW1-ovs.sh](configs/SW1-ovs.sh) is `mcast-snooping-flood=true` on eth0, which marks the trunk as the router port.

**Try it on SW1:**

```sh
ovs-vsctl set bridge br0 mcast_snooping_enable=false   # off: stream still arrives (flooded), mdb/show is empty
ovs-vsctl set bridge br0 mcast_snooping_enable=true    # back on
ovs-appctl mdb/show br0                                # port 3 (eth2), VLAN 10, 239.1.1.1
```

## 7. FRR commands to check multicast

Run these in vtysh on R1. The R1 console opens there, or type `vtysh` from the shell.

### IGMP: did the receiver join?

| Command | Expect |
|---|---|
| `show ip igmp interface` | `eth0.10` up, Querier `local`, version 3 |
| `show ip igmp groups` | `eth0.10  239.1.1.1  EXCL … 3` |
| `show ip igmp sources` | Per-group sources (SSM test: `192.168.20.10` for `232.1.1.1`) |
| `show ip igmp statistics` | Queries sent and reports received, by version |

### PIM: are the RP and the tree in place?

| Command | Expect |
|---|---|
| `show ip pim interface` | `eth0.10` and `eth0.20` PIM-enabled, R1 is the DR |
| `show ip pim rp-info` | `192.168.20.1  239.0.0.0/8 … yes  Static` |
| `show ip pim upstream` | `(192.168.20.10, 239.1.1.1)` state **J** (Joined), plus the KATimer |
| `show ip pim join` / `show ip pim state` | Join state and incoming/outgoing interfaces per entry |
| `show ip pim neighbor` | Empty here, because there's only one router |

### Forwarding: is traffic flowing?

| Command | Expect |
|---|---|
| `show ip mroute` | (\*,G) `SC` and (S,G) `SFT eth0.20 → eth0.10` |
| `show ip mroute count` | **Packets** rising between runs. This is the best single check. |
| `show ip rpf 192.168.20.10` | The reverse path toward the source points out `eth0.20` |
| `show ip multicast` | pimd summary |

On 2026-11-13 the (S,G) forwarded 4,324 packets (5,811,456 bytes) in about 50 s.

### Quick sequence

```
show ip igmp groups
show ip pim upstream
show ip mroute
show ip mroute count
show ip mroute count      ! a few seconds later: Packets must go up
```

### Kernel view (Linux shell, not vtysh)

pimd programs these routes into the kernel, which does the actual forwarding:

```sh
ip mroute show                 # (192.168.20.10,239.1.1.1) Iif: eth0.20 Oifs: eth0.10
cat /proc/net/ip_mr_cache      # per-entry packet and byte counters
```

## 8. Running the VLC scripts and common mistakes

The hosts have helper scripts in `/usr/local/bin` (source: [configs/mcast-receiver](configs/mcast-receiver), [configs/mcast-sender](configs/mcast-sender)). Start the receiver first:

```sh
mcast-receiver start     # IGMP-Receiver: joins 239.1.1.1, saves to /tmp/rx.ts
mcast-sender start       # VLC-Sender: loops the clip to 239.1.1.1:5004, TTL 16
mcast-receiver check     # IGMP-Receiver: "OK: stream is arriving"
mcast-sender stop; mcast-receiver stop
```

The scripts are installed but **don't start at boot**. After a host restarts, nothing is joined or streaming until you run `start` again.

| Symptom | Cause | Fix |
|---|---|---|
| `% Unknown command: mcast-sender` | The console is in FRR's vtysh (prompt `VLC-Sender#`) | Type `exit`. The prompt becomes `VLC-Sender:~#`. |
| `ls` doesn't show the script | `ls` lists `/root`, but the scripts are in `/usr/local/bin` | `which mcast-sender` |
| `sudo: not found` | There's no sudo on these hosts, and you're already root (`#` prompt) | Leave out `sudo` |
| `sh: can't open 'cvlc …': Permission denied` | Typed `su vlc "cvlc …"` without `-c` | `su vlc -c "cvlc …"` |
| VLC doesn't stream | `#std(…)` with parentheses, or no space before `--ttl=16` | `'#std{access=udp,mux=ts,dst=239.1.1.1:5004}' --ttl=16` |
| `su: unknown user vlc` / `cvlc: not found` | VLC isn't installed on that host | [README step 5](README.md#stream-video-with-vlc) |
| `ts demux error: TS discontinuity` in the receiver log | The 10 s clip looping back to the start | Harmless |

**The manual commands** (the scripts run exactly these):

```sh
# IGMP-Receiver
su vlc -c "cvlc -I dummy udp://@239.1.1.1:5004 --sout file/ts:/tmp/rx.ts"
# VLC-Sender
su vlc -c "cvlc -I dummy --loop /home/vlc/bbb.mp4 --sout '#std{access=udp,mux=ts,dst=239.1.1.1:5004}' --ttl=16"
```
