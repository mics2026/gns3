# GNS3 Server and FRR on Ubuntu 26.04 (VirtualBox VM)

How GNS3 server 2.2.61 and FRRouting 10.5.1 were installed on an Ubuntu 26.04 LTS Server VM running in VirtualBox on the Windows host described in [../Windows/GNS3-Windows-Setup.md](../Windows/GNS3-Windows-Setup.md). The VM is headless, so it runs the GNS3 **server** (controller and compute), and the Windows GNS3 GUI connects to it over the host-only network. FRR is installed natively on the VM as its routing suite.

## Environment

| Item | Value |
|---|---|
| Host | Windows 11 Home, VirtualBox 7.2.22 |
| VM name | `Ubuntu-26.04-Server` |
| Guest OS | Ubuntu 26.04.1 LTS (Resolute Raccoon), kernel 7.0.0-43-generic |
| VM resources | 2 vCPU, 2 GB RAM, 24 GB disk |
| NIC 1 | NAT (`enp0s3`, 10.0.2.15), internet access |
| NIC 2 | Host-only, "VirtualBox Host-Only Ethernet Adapter" (`enp0s8`, **192.168.56.102**) |
| Login user | `ubuntu` |
| GNS3 server | 2.2.61~resolute1 (GNS3 PPA) |
| Dynamips / uBridge / VPCS | 0.2.25 / 1.0.1 / 0.8.5 (GNS3 PPA) |
| QEMU | 10.2.1 (Ubuntu archive) |
| FRR | 10.5.1-1ubuntu4.1 (Ubuntu archive) |

## Architecture

```
Windows host (192.168.56.1)
├── GNS3 GUI 2.2.61 ──► remote server http://192.168.56.102:3080
└── VirtualBox
    ├── "GNS3 VM"              192.168.56.101  (existing, see Windows guide)
    └── "Ubuntu-26.04-Server"  192.168.56.102
         ├── gns3-server (systemd, user ubuntu, 0.0.0.0:3080)
         │     └── QEMU, Dynamips, VPCS, uBridge, IOU
         └── FRR 10.5.1 (zebra, bgpd, ospfd, ospf6d, ripd, isisd, bfdd, staticd)
```

---

## 1. SSH access from the Windows host

Generate a key on Windows (Git Bash):

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "user@windows-host"
cat ~/.ssh/id_ed25519.pub
```

Then, on the VM console as `ubuntu`, install the key and allow passwordless sudo (needed for remote, non-interactive installs):

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<contents of id_ed25519.pub>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USER && sudo chmod 440 /etc/sudoers.d/90-$USER
```

Find the VM's host-only IP from Windows without logging in, by matching NIC 2's MAC in the ARP table:

```bash
VBoxManage showvminfo Ubuntu-26.04-Server --machinereadable | grep macaddress2   # 08002786F477
arp -a | grep -i 08-00-27-86-f4-77                                                # 192.168.56.102
ssh ubuntu@192.168.56.102
```

To undo passwordless sudo later: `sudo rm /etc/sudoers.d/90-ubuntu`.

## 2. Install GNS3 server and FRR

The official GNS3 PPA publishes builds for `resolute` (26.04), and the versions match the Windows GUI (2.2.61). FRR comes straight from the Ubuntu archive, so no FRR repository is needed.

```bash
sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:gns3/ppa
sudo apt-get update

# Pre-answer the debconf prompts so the install is non-interactive
echo "ubridge ubridge/install-setuid boolean true"                   | sudo debconf-set-selections
echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections

sudo apt-get install -y gns3-server dynamips ubridge vpcs qemu-system-x86 qemu-utils \
                        frr frr-pythontools
```

Check:

```bash
dpkg -l gns3-server dynamips ubridge vpcs qemu-system-x86 frr | grep ^ii
gns3server --version     # 2.2.61
```

> **Note: `sudo -E` is ignored on 26.04.** Ubuntu 26.04 uses `sudo-rs`, which prints
> `preserving the entire environment is not supported, '-E' is ignored`. Use
> `sudo DEBIAN_FRONTEND=noninteractive apt-get ...` if you need to pass an environment variable.

## 3. Run GNS3 server as a service

The PPA package installs `/usr/bin/gns3server` but **no systemd unit**, so add one.

Server config, `/home/ubuntu/.config/GNS3/2.2/gns3_server.conf`:

```ini
[Server]
host = 0.0.0.0
port = 3080
images_path = /home/ubuntu/GNS3/images
projects_path = /home/ubuntu/GNS3/projects
report_errors = False

[Qemu]
enable_hardware_acceleration = False
require_hardware_acceleration = False
```

Unit file, `/etc/systemd/system/gns3-server.service`:

```ini
[Unit]
Description=GNS3 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
ExecStart=/usr/bin/gns3server
Restart=on-failure
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
```

```bash
mkdir -p ~/GNS3/{projects,images}
sudo systemctl daemon-reload
sudo systemctl enable --now gns3-server
curl -s http://127.0.0.1:3080/v2/version     # {"local": false, "version": "2.2.61"}
```

The install adds `ubuntu` to the `ubridge` group, which uBridge needs to create links.

A startup log line `Cannot connect to compute 'local' ... 127.0.0.1:3080` is harmless. The controller tries to reach compute a moment before the web server is listening, then connects.

### Why hardware acceleration is off

The VM has no `/dev/kvm` (`egrep -c '(vmx|svm)' /proc/cpuinfo` returns `0`) because VirtualBox nested virtualization is disabled for it. QEMU nodes therefore run under TCG software emulation, which is slow but works. To enable KVM inside the VM, power it off and run this on Windows:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm "Ubuntu-26.04-Server" --nested-hw-virt on
```

Then set both `[Qemu]` options above to `True` and restart `gns3-server`.

## 4. Configure FRR

Enable the routing daemons in `/etc/frr/daemons` (zebra, staticd and mgmtd always run):

```bash
sudo sed -i -E 's/^(bgpd|ospfd|ospf6d|ripd|isisd|bfdd|staticd)=no/\1=yes/' /etc/frr/daemons
sudo systemctl restart frr
sudo usermod -aG frrvty,frr ubuntu       # vtysh without sudo (after re-login)
```

Running daemons: `bfdd bgpd isisd mgmtd ospf6d ospfd ripd staticd watchfrr zebra`.

Use it:

```bash
sudo vtysh -c "show version"           # FRRouting 10.5.1
sudo vtysh                             # interactive, Cisco-like CLI
#   conf t
#   router ospf
#    ospf router-id 2.2.2.2
#    network 192.168.56.0/24 area 0
#   end
#   write memory                        # saved to /etc/frr/frr.conf
```

A test config like the one above was written and survived `systemctl restart frr`, then was removed. FRR is left with no routing config.

## 5. Connect the Windows GNS3 GUI

In the GNS3 GUI: **Edit → Preferences → Server**

- Untick **Enable local server**, or keep it and add this VM as a remote compute.
- Host: `192.168.56.102`, Port: `3080`, no authentication.

Check from Windows:

```bash
curl http://192.168.56.102:3080/v2/version
```

The server has no authentication and listens on every interface. That's acceptable here because the only inbound path is the host-only network (UFW is inactive, and NAT allows no inbound traffic). Set `auth = True`, `user` and `password` under `[Server]` if the VM is ever bridged onto a real LAN.

## 6. Verification performed

| Check | Result |
|---|---|
| `systemctl is-active gns3-server frr` | `active` / `active` |
| `GET http://192.168.56.102:3080/v2/version` from Windows | `2.2.61` |
| Compute `local` | connected; node types: qemu, dynamips, vpcs, iou, docker, ethernet_switch, nat, cloud, … |
| API smoke test: project with 2 VPCS nodes, linked, started | both `started`; project then deleted |
| FRR config persistence across `systemctl restart frr` | OK |

## 7. Check running nodes on the VM

Every running GNS3 node is an ordinary Linux process on the VM, started directly by `gns3server`. Log in first:

```bash
ssh ubuntu@192.168.56.102
```

### List running nodes

QEMU nodes (FRR and other appliances) are `qemu-system-x86_64` processes. The node name is in the `-name` option:

```bash
pgrep -a qemu-system | grep -oE -- '-name [^ ]+'                 # node names
ps -o pid,rss,etime,args -p $(pgrep -d, qemu-system) | cut -c1-150   # PID, memory (KB), uptime
```

For a node named `R1`, the full command line looks like this:

```
/usr/bin/qemu-system-x86_64 -name R1 -m 128M -smp cpus=1 ...
  -drive file=/home/ubuntu/GNS3/projects/<project-id>/project-files/qemu/<node-id>/hda_disk.qcow2
  -serial telnet:127.0.0.1:5005,server,nowait
  -monitor tcp:127.0.0.1:<port>
```

| Option | Meaning |
|---|---|
| `-name R1` | The node name shown in GNS3 |
| `-m 128M` | Guest RAM (the node's **RAM** setting) |
| `-drive .../hda_disk.qcow2` | The node's own disk: a small overlay on the base image in `~/GNS3/images/QEMU/` that holds only this node's changes |
| `-serial telnet:127.0.0.1:5005` | QEMU's internal serial console, reachable only from the VM itself |
| `-monitor tcp:127.0.0.1:...` | The control channel GNS3 uses to start, stop and suspend the node |

### Other GNS3 processes

| Command | Shows |
|---|---|
| `systemctl status gns3-server` | The server that starts and stops every node |
| `pgrep -a ubridge` | One uBridge per node. It carries traffic between nodes, so each GNS3 link runs through it. |
| `pgrep -a vpcs` | VPCS nodes |
| `sudo ss -ltnp \| grep gns3server` | Public console ports (5000, 5002, …) |

The console port you telnet to (for example `5004`) belongs to `gns3server`, which forwards it to QEMU's internal serial port (for example `127.0.0.1:5005`).

### CPU, memory and swap

```bash
top -c -p $(pgrep -d, qemu-system)     # live CPU and memory for the nodes only; press q to quit
free -m                                # RAM and swap for the whole VM
```

Without KVM, each FRR node uses about 230 MB of VM memory even with a 128 MB guest, because software emulation adds overhead. The VM has 1.6 GB of RAM, so a **2 GB swapfile** (`/swapfile`, listed in `/etc/fstab`) was added on 2026-11-08 to run the 7-node [PIM-SM lab](../../topology/PIM-SM-Multicast/README.md). To remove it: `sudo swapoff /swapfile && sudo rm /swapfile`, then delete its line from `/etc/fstab`.

### Node and project files

```bash
ls ~/GNS3/projects/                                       # one folder per project (by project ID)
ls ~/GNS3/projects/<project-id>/project-files/qemu/       # one folder per QEMU node (by node ID)
grep '"name"' ~/GNS3/projects/<project-id>/*.gns3         # node names in the project file
```

### From Windows, without SSH

The GNS3 API returns the same information:

```powershell
$S = 'http://192.168.56.102:3080/v2'
Invoke-RestMethod "$S/projects" | Select-Object name, status, project_id
Invoke-RestMethod "$S/projects/<project-id>/nodes" | Select-Object name, status, console, node_type
```

### Why `virsh` shows nothing

`virsh` lists only VMs that **libvirt** created. GNS3 doesn't use libvirt: `gns3server` runs `qemu-system-x86_64` itself and tracks nodes in its own project files. So `virsh list --all` is empty, and libvirt usually isn't installed on this VM at all.

| Instead of | Use |
|---|---|
| `virsh list` | `pgrep -a qemu-system \| grep -oE -- '-name [^ ]+'` |
| `virsh dominfo R1` | `ps -o pid,rss,etime,args -p $(pgrep -f '^/usr/bin/qemu-system.* -name R1 ')` |
| `virsh console R1` | `telnet 192.168.56.102 <console port>` |
| `virsh start` / `shutdown` | The GNS3 web UI, or the API (`POST .../nodes/<node-id>/start` or `/stop`) |

Start and stop nodes through GNS3, not with `kill`. If a QEMU process is killed outside GNS3, the server still shows the node as running until it notices the process is gone.

## Troubleshooting notes

| Symptom | Cause | Fix |
|---|---|---|
| `ssh ubuntu@192.168.56.102` → `Permission denied (publickey,password)` | No key installed | Section 1 |
| `sudo: preserving the entire environment is not supported, '-E' is ignored` | `sudo-rs` on 26.04 | Pass variables explicitly: `sudo VAR=x cmd` |
| `cat /etc/frr/daemons: Permission denied` | File is `frr:frr 640` | Use `sudo`, or join group `frr` |
| `systemctl status gns3-server` → unit not found | PPA ships no unit | Section 3 |
| QEMU nodes very slow | No KVM in the VM | Enable nested virtualization (Section 3) |
| Docker nodes fail | Docker not installed | `sudo apt-get install -y docker.io && sudo usermod -aG docker ubuntu` |
| All nodes stop at once and projects close | The VM ran out of memory and the kernel killed a QEMU process, which restarted `gns3-server`. Check with `sudo dmesg -T \| grep -i "killed process"` and `systemctl show gns3-server -p NRestarts`. | Lower node RAM, add swap, or give the VM more RAM (Section 7) |
| `virsh list` shows no nodes | GNS3 doesn't use libvirt | Use `pgrep -a qemu-system` (Section 7) |
