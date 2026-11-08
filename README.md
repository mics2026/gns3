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

## Repository layout

```
.
├── OS/
│   ├── Windows/GNS3-Windows-Setup.md          Windows host + GNS3 VM guide
│   └── Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md  Ubuntu 26.04 VM: GNS3 server + FRR
├── projects/frr/       Sample topology: FRR 8.2.2 router, L2 switch, VPCS PC, cloud
├── topology/
│   ├── 802.1Q-Router-On-Stick/   Inter-VLAN routing lab guide + topology screenshot
│   └── PIM-SM-Multicast/         PIM-SM multicast lab guide + FRR configs (R1–R5)
├── configs/            Base startup configs used by GNS3 node templates
├── images/QEMU/        QEMU images and firmware (frr-8.2.2.qcow2, emptyNG.qcow2, OVMF_*.fd)
├── appliances/         Custom appliance (.gns3a) files (empty for now)
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
