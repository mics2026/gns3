# GNS3 Lab

GNS3 lab workspace: setup guides, a sample FRR project, and the GNS3 working folders (configs, images, appliances, symbols).

## Where to find things

| I want to… | Go to |
|---|---|
| Install GNS3 on Windows, set up the GNS3 VM in VirtualBox, fix VM startup / QEMU errors, add the FRR appliance | [OS/Windows/GNS3-Windows-Setup.md](OS/Windows/GNS3-Windows-Setup.md) |
| Install GNS3 server and FRR on an Ubuntu 26.04 VM, run GNS3 as a service, connect the Windows GUI to it | [OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md](OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md) |
| See which GNS3 nodes are running on the Ubuntu VM (processes, memory, console ports; why `virsh` shows nothing) | [OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md § 7](OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md#7-check-running-nodes-on-the-vm) |
| Open the sample FRR topology | [projects/frr/frr.gns3](projects/frr/frr.gns3) |
| Get base startup configs for IOS, IOU and VPCS | [configs/](configs/) |
| Find QEMU disk images (FRR 8.2.2, empty qcow2 disks, OVMF UEFI firmware) | [images/QEMU/](images/QEMU/) |
| Build a lab topology for a specific use case | [Topology use cases](#topology-use-cases) |

## Topology use cases

Step-by-step labs, each in its own folder under [topology/](topology/) with a guide and a topology screenshot.

| Use case | What it covers | Nodes | Guide |
|---|---|---|---|
| 802.1Q router-on-a-stick | Inter-VLAN routing between VLAN 10 and VLAN 20 over a single 802.1Q trunk | FRR 8.2.2 router, GNS3 built-in switch, 2 × VPCS | [topology/802.1Q-Router-On-Stick/](topology/802.1Q-Router-On-Stick/README.md) |
| PIM-SM multicast | PIM Sparse Mode with a static RP, IGMP on the last hop, EIGRP unicast; converted to FRR from [NGMunia/Multicast-Routing](https://github.com/NGMunia/Multicast-Routing) | 5 × FRR 8.2.2 routers, 2 × Linux hosts | [topology/PIM-SM-Multicast/](topology/PIM-SM-Multicast/README.md) |
| eBGP + PIM-SM | Three eBGP autonomous systems in a triangle carrying a PIM-SM multicast stream to two receivers; failover tests show BGP path changes moving the multicast tree | 3 × FRR 8.2.2 routers, 3 × GNS3 built-in switch, 3 × Linux hosts | [topology/eBGP-PIM-SM/](topology/eBGP-PIM-SM/README.md) |
| Inter-VLAN multicast on a stick (IOSvL2) | PIM-SM, RP and IGMP querier on a router-on-a-stick; multicast routed VLAN 20 → VLAN 10 over one trunk through a Cisco IOSvL2 with IGMP snooping; SSM and static-mroute tests | FRR 8.2.2 router, Cisco IOSvL2 switch, 2 × Linux hosts (VLC) | [topology/VLAN-Multicast-IOSvL2/](topology/VLAN-Multicast-IOSvL2/README.md) |
| SDN router-on-a-stick | Inter-VLAN routing for VLAN 10/20/30: ONOS 2.7 programs an Open vSwitch over OpenFlow 1.4 (VPLS app; 1.5 is incompatible with OVS), FRR routes over one 802.1Q trunk | ONOS 2.7.0 (Docker), Open vSwitch (Docker), FRR 8.2.2 router, 3 × VPCS | [topology/ONOS-OVS-Router-On-Stick/](topology/ONOS-OVS-Router-On-Stick/README.md) |

## Repository layout

```
.
├── OS/
│   ├── Windows/GNS3-Windows-Setup.md          Windows host + GNS3 VM guide
│   └── Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md  Ubuntu 26.04 VM: GNS3 server + FRR
├── projects/frr/       Sample topology: FRR 8.2.2 router, L2 switch, VPCS PC, cloud
├── topology/
│   ├── 802.1Q-Router-On-Stick/   Inter-VLAN routing lab guide + topology screenshot
│   ├── PIM-SM-Multicast/         PIM-SM multicast lab guide + FRR configs (R1–R5)
│   ├── eBGP-PIM-SM/              eBGP + PIM-SM triangle lab guide + FRR configs (R1–R3)
│   ├── ONOS-OVS-Router-On-Stick/ SDN inter-VLAN lab: ONOS 2.7 + OVS (OpenFlow 1.4) + FRR + deploy.sh
│   └── VLAN-Multicast-IOSvL2/    Inter-VLAN multicast lab: FRR (PIM-SM, IGMP) + Cisco IOSvL2 configs
├── configs/            Base startup configs used by GNS3 node templates
├── images/QEMU/        QEMU images and firmware (frr-8.2.2.qcow2, emptyNG.qcow2, OVMF_*.fd)
├── appliances/         GNS3 marketplace appliance (.gns3a) files from gns3-registry (227)
└── symbols/            Custom node symbols (empty for now)
```

## Lab at a glance

| Component | Version | Address |
|---|---|---|
| Windows host (GNS3 GUI) | GNS3 2.2.61, VirtualBox 7.2.22 | 192.168.56.1 |
| GNS3 VM (VirtualBox) | 2.2.61 | 192.168.56.101:80 |
| Ubuntu-26.04-Server VM (GNS3 server + FRR) | GNS3 2.2.61, FRR 10.5.1 | 192.168.56.102:3080 |
| FRR appliance in projects | 8.2.2 (QEMU) | — |

All VMs sit on the VirtualBox host-only network `192.168.56.0/24`.

## Quick start

1. Set up the host by following the [Windows guide](OS/Windows/GNS3-Windows-Setup.md).
2. Optionally, set up the Ubuntu VM by following the [Ubuntu guide](OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md).
3. In GNS3, go to **File → Open project** and choose `projects/frr/frr.gns3`.

For troubleshooting, see the reference tables at the end of each guide.

## Licenses

### This repository

The guides, lab configs and project files written for this repo don't have a license yet. There's no `LICENSE` file, so by default all rights are reserved by the author.

### Third-party files included in this repo

| Path | Component | License |
|---|---|---|
| `images/QEMU/frr-8.2.2.qcow2` | GNS3 FRR appliance image: Alpine Linux with FRRouting 8.2.2 | FRR: GPL-2.0-or-later. Linux kernel: GPL-2.0. Other Alpine packages: their own licenses. |
| `images/QEMU/OVMF_*.fd` | OVMF UEFI firmware (TianoCore EDK II) | BSD-2-Clause-Patent |
| `images/QEMU/empty*.qcow2` | Blank disk images from the GNS3 registry (no content) | Distributed with GNS3 (GPL-3.0) |
| `configs/*.txt` | GNS3 default startup configs for IOS, IOU and VPCS nodes | Distributed with GNS3 (GPL-3.0) |

### Software used by the labs (not included)

| Software | License |
|---|---|
| [GNS3](https://github.com/GNS3) server and GUI 2.2.61 | GPL-3.0 |
| [uBridge](https://github.com/GNS3/ubridge) | GPL-3.0 |
| [Dynamips](https://github.com/GNS3/dynamips) | GPL-2.0 |
| [VPCS](https://github.com/GNS3/vpcs) | BSD-2-Clause |
| [QEMU](https://www.qemu.org/) | GPL-2.0 |
| [FRRouting](https://frrouting.org/) 8.2.2 / 10.5.1 | GPL-2.0-or-later (some parts ISC or LGPL) |
| [Oracle VirtualBox](https://www.virtualbox.org/) 7.2 | GPL-3.0 (base package); the Extension Pack has a separate proprietary license |
| Ubuntu 26.04 LTS | Free and open-source packages, each under its own license |
| Cisco IOS / IOU images | Proprietary to Cisco and **not included**. You need your own licensed images. |

### Adapted work

| Lab | Source | License |
|---|---|---|
| [PIM-SM multicast](topology/PIM-SM-Multicast/README.md) | [NGMunia/Multicast-Routing](https://github.com/NGMunia/Multicast-Routing) by NGMunia | **None stated.** The guide and FRR configs here were rewritten rather than copied, and the topology image is linked from the original repo, not stored here. Credit is given in the lab guide. |

This table summarizes licenses; it isn't legal advice. Check each project's own license file for the full terms.
