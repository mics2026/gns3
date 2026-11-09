# SDN Router-on-a-Stick (ONOS 2.7 + Open vSwitch + FRR, OpenFlow 1.5)

Inter-VLAN routing between VLAN 10, VLAN 20 and VLAN 30. The Layer 2 switch is an Open vSwitch with no local switching logic: the **ONOS 2.7 SDN controller** programs all of its VLAN forwarding over **OpenFlow 1.5** (wire version 0x06, the version used by spec 1.5.1). **FRR** is the router on the stick and routes between the VLANs over one 802.1Q trunk.

The lab runs on the GNS3 server on the Ubuntu VM (`192.168.56.102:3080`, see [../../OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md](../../OS/Ubuntu/GNS3-FRR-Ubuntu-26.04-Setup.md)).

## Who does what

| Component | Role | Plane |
|---|---|---|
| ONOS 2.7.0 | Controller. Its **VPLS** app turns "VLAN 10/20/30" into OpenFlow rules: tag frames from access ports, untag frames going to access ports, and keep each VLAN's broadcasts separate. | Control |
| OVS-1 | OpenFlow 1.5 switch in `secure` fail mode. Without ONOS it forwards nothing. | Data |
| FRR-1 | Router on a stick. `eth0.10`, `eth0.20`, `eth0.30` are the gateways; FRR routes between them. | Routing |
| PC10, PC20, PC30 | VPCS hosts, one per VLAN, untagged. | — |

> **ONOS does not configure FRR.** FRR isn't an OpenFlow device, so ONOS can't push config to it. ONOS controls the switch fabric that FRR's trunk plugs into, and it learns FRR as three hosts (one MAC on VLANs 10, 20 and 30). Routing still happens in FRR.

## Topology

```
                 ┌──────────────┐
                 │  ONOS 2.7.0  │ 10.10.10.1/24
                 └──────┬───────┘
                   eth0 │ out-of-band management (OpenFlow 1.5, TCP 6653)
                   eth0 │ 10.10.10.2/24
                 ┌──────┴───────┐   eth1 (trunk 10,20,30)    ┌────────┐
                 │    OVS-1     ├────────────────────────────┤ FRR-1  │ eth0.10 / .20 / .30
                 │  br0 dpid 1  │                       eth0 └────────┘
                 └─┬─────┬────┬─┘
             eth2  │     │eth3│ eth4      (access, untagged)
               ┌───┴─┐ ┌─┴───┐┌┴────┐
               │PC10 │ │PC20 ││PC30 │
               └─────┘ └─────┘└─────┘
```

| Node | Type | Port | Connects to | ONOS connect point |
|---|---|---|---|---|
| ONOS | Docker, `onosproject/onos:2.7.0` | eth0 | OVS-1 eth0 | — |
| OVS-1 | Docker, GNS3 **Open vSwitch** appliance | eth0 | ONOS eth0 (management, not in `br0`) | — |
| OVS-1 | | eth1 | FRR-1 eth0 (trunk) | `of:0000000000000001/1` |
| OVS-1 | | eth2 | PC10 e0 (VLAN 10) | `of:0000000000000001/2` |
| OVS-1 | | eth3 | PC20 e0 (VLAN 20) | `of:0000000000000001/3` |
| OVS-1 | | eth4 | PC30 e0 (VLAN 30) | `of:0000000000000001/4` |
| FRR-1 | QEMU, `frr-8.2.2.qcow2` | eth0 | OVS-1 eth1 | — |

## Addressing

| VLAN | Subnet | Gateway (FRR-1) | PC |
|---|---|---|---|
| 10 | 192.168.10.0/24 | eth0.10, 192.168.10.1 | PC10, 192.168.10.10 |
| 20 | 192.168.20.0/24 | eth0.20, 192.168.20.1 | PC20, 192.168.20.10 |
| 30 | 192.168.30.0/24 | eth0.30, 192.168.30.1 | PC30, 192.168.30.10 |
| mgmt | 10.10.10.0/24 | — | ONOS 10.10.10.1, OVS-1 10.10.10.2 |

## Requirements

- **Docker on the GNS3 server.** Both ONOS and OVS are Docker nodes. On the Ubuntu VM, `docker info` must work for the user the GNS3 server runs as.
- **Internet on the Ubuntu VM** the first time, so it can pull `onosproject/onos:2.7.0` (about 1 GB) and `gns3/openvswitch`.
- **RAM.** ONOS (Java/Karaf) needs about 2 GB. Give the Ubuntu VM at least 6 GB.

ONOS 2.7.0 is the last ONOS release line. If Docker Hub has a newer 2.7 patch tag for `onosproject/onos`, you can use it instead; the steps are the same.

---

## 1. Create the node templates

### ONOS

In GNS3: **Edit → Preferences → Docker → Docker containers → New**.

1. Server: the Ubuntu VM. Image: **New image** → `onosproject/onos:2.7.0`.
2. Name: `ONOS`. Network adapters: **1**.
3. Start command: leave empty.
4. Console type: **http**. HTTP port in the container: **8181**. HTTP path: `/onos/ui`.
5. Environment variables:

   ```
   ONOS_APPS=drivers,openflow,vpls
   ```

   `openflow` also pulls in the OpenFlow provider, host provider and LLDP provider. `vpls` is the app that builds the VLANs.

6. Finish. Right-click the template → **Configure** → **Auxiliary console type: telnet** (this is the shell you'll use for the ONOS CLI).

### Open vSwitch

**File → New template → Install an appliance from the GNS3 server → Switches → Open vSwitch → Install.** Give it at least **5** adapters (eth0–eth4).

## 2. Build the topology

Drag in ONOS, OVS-1, FRR-1 and three VPCS (PC10, PC20, PC30). Cable them exactly as the topology table says. **Don't start anything yet.**

**Set the management IPs.** Right-click the node → **Edit config** (Docker nodes call it *Network configuration*). Uncomment/replace with:

ONOS:

```
auto eth0
iface eth0 inet static
    address 10.10.10.1
    netmask 255.255.255.0
```

OVS-1:

```
auto eth0
iface eth0 inet static
    address 10.10.10.2
    netmask 255.255.255.0
```

## 3. Start ONOS and check it

Start **ONOS** only. It takes 1–2 minutes to come up.

- **GUI:** right-click ONOS → **Web console** (it opens `/onos/ui` through GNS3). Log in as `onos` / `rocks`.
- **CLI:** right-click ONOS → **Auxiliary console**, then:

  ```sh
  ls -d /root/onos/apache-karaf-*          # find the Karaf folder name
  /root/onos/apache-karaf-*/bin/client     # ONOS CLI; password/user if asked: karaf / karaf
  ```

In the ONOS CLI, confirm the apps are active and nothing else is fighting VPLS for the switch:

```
apps -a -s
```

You should see `org.onosproject.openflow`, `org.onosproject.vpls` and their dependencies. **`org.onosproject.fwd` (reactive forwarding) and `org.onosproject.proxyarp` must not be active**: they would flood between VLANs and break the separation. If either is listed, run `app deactivate org.onosproject.fwd` (or `proxyarp`).

## 4. Configure OVS-1 for ONOS and OpenFlow 1.5

Start **OVS-1** and open its console.

**1. Look at the default bridges.** The GNS3 Open vSwitch image creates `br0` and puts every `ethX` in it, including eth0.

```sh
ovs-vsctl show
```

**2. Take eth0 out of the data plane** (it's the management link to ONOS) and check it reaches ONOS:

```sh
ovs-vsctl del-port br0 eth0
ip addr show eth0                 # should show 10.10.10.2/24
ping -c 3 10.10.10.1
```

**3. Pin the port numbers** so they match the connect points in the topology table:

```sh
ovs-vsctl set interface eth1 ofport_request=1
ovs-vsctl set interface eth2 ofport_request=2
ovs-vsctl set interface eth3 ofport_request=3
ovs-vsctl set interface eth4 ofport_request=4
```

**4. Set a fixed datapath ID, OpenFlow 1.5, secure fail mode, and the controller:**

```sh
ovs-vsctl set bridge br0 other-config:datapath-id=0000000000000001
ovs-vsctl set bridge br0 protocols=OpenFlow15
ovs-vsctl set-fail-mode br0 secure
ovs-vsctl set-controller br0 tcp:10.10.10.1:6653
```

- `protocols=OpenFlow15` only, so the switch can't negotiate down to 1.3 and you know the session is really 1.5.
- `secure` fail mode means OVS never falls back to acting as a normal learning switch. If ONOS is down, nothing forwards, which proves ONOS is doing the work.

**5. Check the result:**

```sh
ovs-vsctl show                         # Controller "tcp:10.10.10.1:6653" with is_connected: true
ovs-ofctl -O OpenFlow15 show br0       # ports 1(eth1) 2(eth2) 3(eth3) 4(eth4)
```

In the ONOS CLI:

```
devices
ports of:0000000000000001
```

`devices` should show `of:0000000000000001 ... available=true ... protocol=OF_15`.

## 5. Define the VLANs in ONOS (VPLS)

All of this is in the ONOS CLI. First declare **interfaces**: a connect point plus an optional VLAN. The trunk port gets three tagged interfaces; the PC ports are untagged.

```
interface-add -v 10 of:0000000000000001/1 frr-v10
interface-add -v 20 of:0000000000000001/1 frr-v20
interface-add -v 30 of:0000000000000001/1 frr-v30
interface-add of:0000000000000001/2 pc10
interface-add of:0000000000000001/3 pc20
interface-add of:0000000000000001/4 pc30
interfaces
```

Then build one VPLS (a Layer 2 broadcast domain) per VLAN:

```
vpls create VLAN10
vpls add-if VLAN10 frr-v10
vpls add-if VLAN10 pc10

vpls create VLAN20
vpls add-if VLAN20 frr-v20
vpls add-if VLAN20 pc20

vpls create VLAN30
vpls add-if VLAN30 frr-v30
vpls add-if VLAN30 pc30

vpls list
vpls show
```

Each VPLS mixes one tagged interface (trunk) and one untagged interface (access port). VPLS handles the difference: frames from PC10 get VLAN 10 pushed on the way to FRR, and frames from FRR tagged 10 have the tag popped on the way to PC10. That is the access/trunk behaviour a normal switch has, but done by ONOS rules.

**Save it across ONOS restarts.** `interface-add` and `vpls` changes are stored in ONOS's network config. To keep a copy you can re-apply, dump it with `netcfg` in the CLI. The equivalent JSON (POST to `http://<onos>:8181/onos/v1/network/configuration` as `onos:rocks`) is:

```json
{
  "ports": {
    "of:0000000000000001/1": { "interfaces": [
      { "name": "frr-v10", "vlan": "10" },
      { "name": "frr-v20", "vlan": "20" },
      { "name": "frr-v30", "vlan": "30" } ] },
    "of:0000000000000001/2": { "interfaces": [ { "name": "pc10" } ] },
    "of:0000000000000001/3": { "interfaces": [ { "name": "pc20" } ] },
    "of:0000000000000001/4": { "interfaces": [ { "name": "pc30" } ] }
  },
  "apps": {
    "org.onosproject.vpls": { "vpls": { "vplsList": [
      { "name": "VLAN10", "interfaces": ["frr-v10", "pc10"] },
      { "name": "VLAN20", "interfaces": ["frr-v20", "pc20"] },
      { "name": "VLAN30", "interfaces": ["frr-v30", "pc30"] } ] } }
  }
}
```

## 6. Configure router-on-a-stick on FRR-1

Start **FRR-1** and log in as `root`. If the console opens at `frr#` (vtysh), type `exit` to get a Linux shell.

**Create the 802.1Q subinterfaces in the Linux shell.** vtysh can't create them.

```sh
modprobe 8021q            # an error here is fine if VLAN support is built in
ip link set eth0 up
ip link add link eth0 name eth0.10 type vlan id 10
ip link add link eth0 name eth0.20 type vlan id 20
ip link add link eth0 name eth0.30 type vlan id 30
ip link set eth0.10 up
ip link set eth0.20 up
ip link set eth0.30 up
sysctl -w net.ipv4.ip_forward=1
```

**Assign the gateway addresses in vtysh:**

```
vtysh
conf t
 interface eth0.10
  ip address 192.168.10.1/24
 exit
 interface eth0.20
  ip address 192.168.20.1/24
 exit
 interface eth0.30
  ip address 192.168.30.1/24
 exit
end
write memory
show ip route connected
```

You should see `192.168.10.0/24`, `192.168.20.0/24` and `192.168.30.0/24` as connected (`C`).

**After a reboot** the subinterfaces are lost (the IPs are saved). Re-run the shell commands, or put them in `/etc/local.d/vlan.start` (make it executable) and run `rc-update add local default`.

## 7. Configure the PCs

Start the PCs.

```
PC10> ip 192.168.10.10/24 192.168.10.1
PC20> ip 192.168.20.10/24 192.168.20.1
PC30> ip 192.168.30.10/24 192.168.30.1
```

Run `save` on each.

## 8. Verify

**From each PC, ping its own gateway first** (this also lets ONOS learn the hosts):

```
PC10> ping 192.168.10.1
PC20> ping 192.168.20.1
PC30> ping 192.168.30.1
```

**Then inter-VLAN, routed through FRR:**

```
PC10> ping 192.168.20.10
PC10> ping 192.168.30.10
PC20> ping 192.168.30.10
PC10> trace 192.168.30.10        # first hop 192.168.10.1
```

**In ONOS, see what the controller built:**

```
hosts            # FRR's MAC 3 times on of:...01/1 with vlan 10, 20, 30; PCs on /2 /3 /4 with vlan None
intents          # VPLS broadcast (single-point-to-multi-point) and unicast intents, all INSTALLED
flows -s added of:0000000000000001
```

In the GUI, the Topology view shows the switch and the hosts; press **H** to toggle host display.

**On OVS-1, see the OpenFlow 1.5 rules ONOS installed:**

```sh
ovs-ofctl -O OpenFlow15 dump-flows br0
```

Look for `push_vlan` / `set_field:...->vlan_vid` on rules matching `in_port=2,3,4`, and `pop_vlan` (or `strip_vlan`) on rules sending to ports 2, 3 and 4.

**Prove ONOS is in control.** Stop the ONOS node and keep a ping running from PC10 to PC20. After the flows time out or are removed, traffic stops, because OVS is in `secure` mode and has no rules of its own. Start ONOS again; once the device reconnects and VPLS reinstalls its intents, the ping resumes.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `is_connected` never becomes `true` | Check `ping 10.10.10.1` from OVS-1. In ONOS, check `apps -a -s` includes `org.onosproject.openflow`. ONOS listens on 6653 only after it has fully started (1–2 min). |
| Device connects with `protocol=OF_13`, not `OF_15` | `protocols` on `br0` still allows 1.3. Set it to exactly `OpenFlow15` and run `ovs-vsctl del-controller br0` then `set-controller` again. |
| Device won't connect at all with OpenFlow15 only | Try `protocols=OpenFlow13,OpenFlow15` to see if the session comes up; then check `ovs-vsctl list controller` for `status` errors and ONOS `log:tail` for handshake errors. |
| ONOS port numbers don't match the table | `ofport_request` was set after the ports were numbered. Check `ovs-ofctl -O OpenFlow15 show br0` and either use the real numbers in `interface-add`, or `ovs-vsctl del-port br0 ethX` / `add-port br0 ethX -- set interface ethX ofport_request=N`. |
| PC can't ping its gateway | `vpls show` must list both interfaces for that VLAN. `hosts` must show FRR on `/1` with that VLAN. On FRR-1, check `ip -d link show eth0.10`. |
| PCs in different VLANs ping each other **without** going through FRR, or `trace` shows no gateway hop | Something is flooding across VLANs. Deactivate `org.onosproject.fwd` and `org.onosproject.proxyarp`, and check `ovs-vsctl get-fail-mode br0` is `secure`. |
| Intents stuck in `FAILED` / `WITHDRAWN` | Run `intents -s`. Usually a wrong connect point in `interface-add`. Remove with `vpls rem-if` / `interface-remove` and re-add. |
| PC reaches its gateway but not the other VLAN | On FRR-1, `sysctl net.ipv4.ip_forward` must be `1` and `show ip route` must list all three subnets. Check each PC has a gateway (`show ip`). |
| Everything stops after FRR-1 restarts | Subinterfaces aren't persistent. Re-run the `ip link` commands (section 6). |
