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

## Troubleshooting notes

| Symptom | Cause | Fix |
|---|---|---|
| `ssh ubuntu@192.168.56.102` → `Permission denied (publickey,password)` | No key installed | Section 1 |
| `sudo: preserving the entire environment is not supported, '-E' is ignored` | `sudo-rs` on 26.04 | Pass variables explicitly: `sudo VAR=x cmd` |
| `cat /etc/frr/daemons: Permission denied` | File is `frr:frr 640` | Use `sudo`, or join group `frr` |
| `systemctl status gns3-server` → unit not found | PPA ships no unit | Section 3 |
| QEMU nodes very slow | No KVM in the VM | Enable nested virtualization (Section 3) |
| Docker nodes fail | Docker not installed | `sudo apt-get install -y docker.io && sudo usermod -aG docker ubuntu` |
