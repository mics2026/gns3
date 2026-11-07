# GNS3 on Windows: Installation, Troubleshooting and Resolution

A full record of installing GNS3 2.2.61 with VirtualBox and the GNS3 VM on Windows 11, and adding an FRR router template. It covers every error hit along the way, its cause and its fix.

## Environment

| Item | Value |
|---|---|
| OS | Windows 11 Home (10.0.26300), 64-bit |
| CPU | AMD Ryzen 5 5500 (6 cores / 12 threads) |
| RAM | 16 GB |
| Motherboard | ASUS PRIME B550-PLUS AC-HES |
| GNS3 | 2.2.61 (all-in-one installer) |
| VirtualBox | 7.2.22 |
| GNS3 VM | 2.2.61, VirtualBox edition |
| FRR appliance | 8.2.2 (`frr-8.2.2.qcow2`) |
| QEMU inside the GNS3 VM | 10.2.1 |

## Architecture

```
Windows host
├── GNS3 GUI  ──►  local GNS3 server / controller (localhost:3080)
│                         │
│                         ▼
└── VirtualBox ──► "GNS3 VM" (Linux) ── GNS3 compute server (192.168.56.101:80)
                          ▲               runs QEMU, Docker, IOU devices
          host-only network 192.168.56.0/24
          (VirtualBox Host-Only Ethernet Adapter, host = 192.168.56.1)
```

QEMU-based appliances such as FRR run inside the GNS3 VM, not on Windows. The VM in turn needs hardware virtualization (AMD-V/SVM or Intel VT-x) enabled in the BIOS.

---

## 1. Install GNS3

winget has no GNS3 package (`winget search GNS3` returns "No package found"), so get the installer from GNS3's official GitHub releases, which is the same file the GNS3 website links to.

### 1.1 Find the latest release

```powershell
$r = Invoke-RestMethod https://api.github.com/repos/GNS3/gns3-gui/releases/latest
$r.tag_name                      # v2.2.61
$r.assets | Select-Object name, browser_download_url
```

The Windows file is `GNS3-<version>-all-in-one.exe`, published next to a `.sha256` file.

### 1.2 Download and verify

```powershell
$d = "$env:USERPROFILE\Downloads\gns3-installer"
New-Item -ItemType Directory -Force $d | Out-Null
$ProgressPreference = 'SilentlyContinue'
$base = 'https://github.com/GNS3/gns3-gui/releases/download/v2.2.61'
Invoke-WebRequest "$base/GNS3-2.2.61-all-in-one.exe"        -OutFile "$d\GNS3-2.2.61-all-in-one.exe"
Invoke-WebRequest "$base/GNS3-2.2.61-all-in-one.exe.sha256" -OutFile "$d\sum.sha256"

Get-Content "$d\sum.sha256"                                       # expected hash
(Get-FileHash "$d\GNS3-2.2.61-all-in-one.exe" -Algorithm SHA256).Hash   # actual hash
Get-AuthenticodeSignature "$d\GNS3-2.2.61-all-in-one.exe" | Format-List Status, SignerCertificate
```

Result:
- SHA-256 `32956FB74B130F709CA09A18D05371CD5F7608215DAA03F63F3BA745C809F765` matched the published value.
- The signature is **Valid**, signed by **SolarWinds Worldwide, LLC** (the company that owns GNS3).

### 1.3 Run the installer

```powershell
Start-Process "$env:USERPROFILE\Downloads\gns3-installer\GNS3-2.2.61-all-in-one.exe"
```

- Accept the UAC prompt. The installer needs admin rights.
- Go through the wizard and keep the default components. Npcap and Wireshark have their own installer screens.
- Default install path: `C:\Program Files\GNS3`.

Check the install:

```powershell
Test-Path "C:\Program Files\GNS3\gns3.exe"   # True
Get-Process gns3server                        # the local server runs when GNS3 is open
```

---

## 2. Install VirtualBox

GNS3 on Windows can't run QEMU appliances well by itself. It needs the GNS3 VM, which runs in VirtualBox (or VMware).

```powershell
winget install --id Oracle.VirtualBox -e --accept-source-agreements --accept-package-agreements
```

winget pulled in the `Microsoft.VCRedist.2015+.x64` dependency, verified the installer hash, and installed VirtualBox 7.2.22 to `C:\Program Files\Oracle\VirtualBox`.

---

## 3. Install the GNS3 VM in VirtualBox

> The GNS3 VM version **must match** the GNS3 GUI version (2.2.61 here).

### 3.1 Download and verify (about 855 MB)

```powershell
$d = "$env:USERPROFILE\Downloads\gns3-installer"
$base = 'https://github.com/GNS3/gns3-gui/releases/download/v2.2.61'
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest "$base/GNS3.VM.VirtualBox.2.2.61.zip" -OutFile "$d\GNS3.VM.VirtualBox.2.2.61.zip"
Invoke-WebRequest "$base/GNS3.VM.checksums.sha256"      -OutFile "$d\vm.sha256"
Select-String "VirtualBox" "$d\vm.sha256"
(Get-FileHash "$d\GNS3.VM.VirtualBox.2.2.61.zip").Hash
```

Result: SHA-256 `7D21999CBD85AC27B30036DE03598AE24AEFA71DBEF2F27CB9A1BD21A7F74E55` matched.

### 3.2 Extract and import

```powershell
$vbm = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
Expand-Archive "$d\GNS3.VM.VirtualBox.2.2.61.zip" "$d\vm" -Force
& $vbm import "$d\vm\GNS3 VM.ova"
& $vbm list vms        # "GNS3 VM" {d8aee8c7-...}
```

The imported VM has:
- NIC 1: **Host-only**
- NIC 2: **NAT** (internet access for the VM)
- 1 vCPU and 2048 MB RAM by default
- Location: `C:\Users\<user>\VirtualBox VMs\GNS3 VM\`

### 3.3 Fix the host-only adapter name (Windows-specific)

**Problem:** The OVA sets NIC 1 to `vboxnet0`, which is the Linux/macOS adapter name. On Windows the adapter is called **"VirtualBox Host-Only Ethernet Adapter"**, so NIC 1 would point at an adapter that doesn't exist.

Check:

```powershell
& $vbm list hostonlyifs | Select-String "Name|IPAddress"
#   Name:      VirtualBox Host-Only Ethernet Adapter
#   IPAddress: 192.168.56.1
& $vbm showvminfo "GNS3 VM" --machinereadable | Select-String "hostonlyadapter1|nic1"
#   hostonlyadapter1="vboxnet0"   <-- wrong on Windows
```

Fix:

```powershell
& $vbm modifyvm "GNS3 VM" --hostonlyadapter1 "VirtualBox Host-Only Ethernet Adapter"
```

---

## 4. Problem 1: GNS3 VM won't start (AMD-V disabled)

### Symptom

After enabling the GNS3 VM in **Edit → Preferences → GNS3 VM** and clicking **OK**:

```
Error while saving settings: GNS3VM: Error while executing VBoxManage command:
VirtualBox has returned an error: VBoxManage.exe: error: Not in a hypervisor partition (HVP=0) (VERR_NEM_NOT_AVAILABLE).
VBoxManage.exe: error: AMD-V is disabled in the BIOS (or by the host OS) (VERR_SVM_DISABLED)
VBoxManage.exe: error: Details: code E_FAIL (0x80004005), component ConsoleWrap, interface IConsole
```

### Diagnosis

```powershell
Get-CimInstance Win32_Processor | Select-Object Name, VirtualizationFirmwareEnabled
#   AMD Ryzen 5 5500   VirtualizationFirmwareEnabled = False   <-- off in the BIOS
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
#   False   <-- Hyper-V isn't running, so Windows isn't blocking it either
Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product
#   ASUSTeK COMPUTER INC.  PRIME B550-PLUS AC-HES
```

| Error part | Meaning |
|---|---|
| `VERR_SVM_DISABLED` | AMD-V (SVM) is turned off in the UEFI/BIOS |
| `VERR_NEM_NOT_AVAILABLE` / `HVP=0` | VirtualBox's fallback path through the Windows Hypervisor Platform isn't available either, because Hyper-V isn't running |

**Root cause:** hardware virtualization was disabled in the motherboard firmware. The CPU supports it.

### Resolution: enable SVM in the BIOS (ASUS B550)

1. Save your work, then restart into the firmware. Either press **Del** or **F2** repeatedly during boot, or run:
   ```powershell
   shutdown /r /fw /t 0
   ```
2. Press **F7** for **Advanced Mode**.
3. Go to **Advanced → CPU Configuration → SVM Mode** and set it to **Enabled**.
4. Press **F10** to save and exit.

> On Intel systems the setting is usually called **Intel Virtualization Technology (VT-x)**. Other vendors put it under *Advanced*, *CPU Features* or *Security*.

### Verification

```powershell
(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled   # True
```

### Resource tuning (optional, for a 16 GB host)

```powershell
& $vbm modifyvm "GNS3 VM" --cpus 4 --memory 4096 --nested-hw-virt on
```

Nested virtualization lets QEMU inside the VM use KVM acceleration, which makes devices much faster.

> GNS3 applies the **vCPUs** and **RAM** values from *Preferences → GNS3 VM* every time it starts the VM (`allocate_vcpus_ram: true`). Set the numbers you want there, or GNS3 will override the VirtualBox settings.

### Test the VM boots and its GNS3 server responds

The VM has no VirtualBox guest additions, so `VBoxManage guestproperty` can't report its IP. Probe the host-only DHCP range instead:

```powershell
foreach ($n in 101..105) {
  $ip = "192.168.56.$n"
  try { $v = Invoke-RestMethod "http://$ip/v2/version" -TimeoutSec 3; "$ip -> GNS3 server $($v.version)"; break }
  catch { "$ip no response" }
}
#   192.168.56.101 -> GNS3 server 2.2.61
```

---

## 5. Connect the GNS3 GUI to the GNS3 VM

In GNS3, go to **Edit → Preferences → GNS3 VM**:

| Setting | Value |
|---|---|
| Enable the GNS3 VM | ☑ |
| Virtualization engine | VirtualBox |
| VM name | GNS3 VM |
| Run the VM in headless mode | optional |
| vCPUs / RAM | e.g. 2 to 4 vCPUs / 4096 MB |
| Action when closing GNS3 | stop the VM |

Click **OK**. In the **Servers Summary** panel, **GNS3 VM** should turn green.

> **Let GNS3 start and stop the VM.** Don't start it yourself from VirtualBox or `VBoxManage startvm` while GNS3 is managing it. See Problem 2.

---

## 6. Problem 2: VM lock conflict and "No compatible Qemu binary selected"

### Symptom

While installing the **FRR** appliance (**File → New template → Install an appliance from the GNS3 server → FRR**), choosing to install on the GNS3 VM produced:

```
=> Timeout after 120 seconds for request GET 'http://admin@localhost:3080/v2/computes/vm/qemu/binaries'.
   Please check the connection is not blocked by a firewall or an anti-virus.
Operation timeout
No compatible Qemu binary selected
```

### Diagnosis

1. **Ask the VM directly.** QEMU was there:
   ```powershell
   Invoke-RestMethod http://192.168.56.101/v2/compute/qemu/binaries
   #   /usr/bin/qemu-system-x86_64   10.2.1   (and others)
   ```
2. **Ask the local controller for its compute list.** The local server's credentials are in `%APPDATA%\GNS3\2.2\gns3_server.ini` (`user` and `password` under `[Server]`):
   ```powershell
   $ini = Get-Content "$env:APPDATA\GNS3\2.2\gns3_server.ini" -Raw
   $u = [regex]::Match($ini,'(?m)^user\s*=\s*(.*)$').Groups[1].Value.Trim()
   $p = [regex]::Match($ini,'(?m)^password\s*=\s*(.*)$').Groups[1].Value.Trim()
   $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${u}:${p}")) }

   (Invoke-WebRequest http://localhost:3080/v2/computes -Headers $h -UseBasicParsing).Content
   #   compute "local" connected: true
   #   compute "vm" (192.168.56.101:80) connected: true
   Invoke-RestMethod http://localhost:3080/v2/computes/vm/qemu/binaries -Headers $h
   #   returned in 0.18 s
   ```
3. **Check the server log** at `%APPDATA%\GNS3\2.2\gns3_server.log`:
   ```
   ERROR Cannot start the GNS3 VM: GNS3VM: Error while executing VBoxManage command:
   VBoxManage.exe: error: An unexpected process (PID=0x00003E0C) has tried to lock the machine 'GNS3 VM',
   while only the process started by LaunchVMProcess (PID=0x00001918) is allowed
   Details: code E_ACCESSDENIED (0x80070005), component MachineWrap, interface IMachine
   ...
   INFO "GET /v2/computes/vm/qemu/binaries HTTP/1.1" 200   (request at 14:03:11, logged at 14:06:17, about 3 min)
   ```

### Root cause

The GNS3 VM had been started by hand (`VBoxManage startvm --type headless`) to test it. When the GNS3 VM settings were saved, GNS3 also tried to start and lock the same VM. VirtualBox refused (`E_ACCESSDENIED`), and the controller took several minutes to recover and connect to the VM compute. The FRR wizard's QEMU binary request was made during that window. It took about 3 minutes, past the GUI's 120-second limit, so the wizard had no binary list to offer.

It was **not** a firewall or antivirus problem, despite what the message suggests.

### Resolution

- Wait until **GNS3 VM** is green in Servers Summary, then start the appliance wizard again. The request now returns in under a second.
- From then on, only GNS3 starts and stops the VM.
- If the VM is stuck in a bad state, close GNS3, run `& $vbm controlvm "GNS3 VM" poweroff`, and reopen GNS3.

---

## 7. Install the FRR appliance template

### 7.1 Wizard steps

1. Go to **File → New template → Install an appliance from the GNS3 server**, find **FRR**, and click **Install**.
2. Choose **Install the appliance on the GNS3 VM**.
3. QEMU binary: **/usr/bin/qemu-system-x86_64 (v10.2.1)**.
4. Required files: every version shows **Missing files** until you provide the image (see 7.2).

### 7.2 Get the image (`frr-8.2.2.qcow2`)

The download URL and checksum are in the appliance definition that ships with GNS3:

```powershell
$j = Get-Content "C:\Program Files\GNS3\appliances\frr.gns3a" -Raw | ConvertFrom-Json
$j.images | Where-Object filename -eq "frr-8.2.2.qcow2" |
  Format-List filename, md5sum, filesize, direct_download_url
#   md5sum              : 45cda6b991a1b9e8205a3a0ecc953640
#   filesize            : 56609280
#   direct_download_url : http://downloads.sourceforge.net/project/gns-3/Qemu%20Appliances/frr-8.2.2.qcow2
```

Download it to `Downloads`, which the wizard searches by default, and verify:

```powershell
$out = "$env:USERPROFILE\Downloads\frr-8.2.2.qcow2"
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest "https://downloads.sourceforge.net/project/gns-3/Qemu%20Appliances/frr-8.2.2.qcow2" `
  -OutFile $out -UserAgent "Wget/1.21" -MaximumRedirection 10
(Get-Item $out).Length                              # 56609280
(Get-FileHash $out -Algorithm MD5).Hash             # 45CDA6B991A1B9E8205A3A0ECC953640
```

> SourceForge serves an HTML page to browser user agents. A `Wget` user agent gets the binary file directly.

Size and MD5 both matched.

### 7.3 Finish the wizard

1. Click **Refresh**. **FRR version 8.2.2** shows **Ready to install**. If it doesn't, select the file, click **Import**, and browse to it.
2. Select **FRR version 8.2.2**, click **Next**, and confirm with **Yes**.
3. Click **Finish**. The image is uploaded to the GNS3 VM.

### 7.4 Use it

- FRR appears under **Routers** in the device list.
- Drag it into a project and click **Start ▶**.
- Right-click the router, choose **Console**, then run `vtysh` for the FRR CLI.

---

## 8. Quick troubleshooting reference

| Symptom | Cause | Fix |
|---|---|---|
| `winget search GNS3`: no package | GNS3 isn't in winget | Download from GitHub releases (§1) |
| VM NIC 1 points at `vboxnet0` | OVA built for Linux/macOS adapter names | `modifyvm --hostonlyadapter1 "VirtualBox Host-Only Ethernet Adapter"` (§3.3) |
| `VERR_SVM_DISABLED` / `AMD-V is disabled in the BIOS` | SVM is off in the firmware | Enable **SVM Mode** in the BIOS (§4) |
| `VERR_VMX_DISABLED` (Intel) | VT-x is off in the firmware | Enable **Intel Virtualization Technology** in the BIOS |
| `VERR_NEM_NOT_AVAILABLE` / `HVP=0` | No hardware virtualization path at all | Same BIOS fix. If Hyper-V/WSL2 is on, VirtualBox has to go through it (slower) |
| `VirtualizationFirmwareEnabled = False` | Firmware setting is off | BIOS fix, then re-check |
| `E_ACCESSDENIED ... tried to lock the machine 'GNS3 VM'` | VM was started outside GNS3 | Let GNS3 own the VM. Power it off and restart GNS3 (§6) |
| `Timeout ... /v2/computes/vm/qemu/binaries` / `No compatible Qemu binary selected` | VM compute not ready yet (or lock conflict) | Wait for the VM to turn green and rerun the wizard (§6) |
| Appliance shows `Missing files` | Image not downloaded yet | Download, check the MD5 from the `.gns3a` file, then **Refresh** or **Import** (§7.2) |
| Can't find the VM's IP | No guest additions | Probe `192.168.56.101+` on `/v2/version`, or read the VM console |

## 9. Useful paths

| Item | Path |
|---|---|
| GNS3 program | `C:\Program Files\GNS3\` |
| Bundled appliance definitions | `C:\Program Files\GNS3\appliances\*.gns3a` |
| GNS3 config and logs | `%APPDATA%\GNS3\2.2\` (`gns3_server.ini`, `gns3_gui.ini`, `gns3_controller.ini`, `gns3_server.log`, `gns3_gui.log`) |
| GNS3 user data (projects, images) | `%USERPROFILE%\GNS3\` |
| VirtualBox | `C:\Program Files\Oracle\VirtualBox\` (`VBoxManage.exe`) |
| GNS3 VM files | `%USERPROFILE%\VirtualBox VMs\GNS3 VM\` |
| Downloaded installers | `%USERPROFILE%\Downloads\gns3-installer\` (about 2 GB, safe to delete after setup) |

## 10. Useful endpoints

| Endpoint | Purpose |
|---|---|
| `http://localhost:3080/v2/version` | Local server version (needs Basic auth) |
| `http://localhost:3080/v2/computes` | Connected computes (local and VM) |
| `http://localhost:3080/v2/gns3vm` | GNS3 VM settings as GNS3 sees them |
| `http://localhost:3080/v2/computes/vm/qemu/binaries` | QEMU binaries on the VM, through the controller |
| `http://192.168.56.101/v2/version` | GNS3 VM compute server (no auth) |
| `http://192.168.56.101/v2/compute/qemu/binaries` | QEMU binaries, asked of the VM directly |
