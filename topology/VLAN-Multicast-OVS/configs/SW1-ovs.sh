#!/bin/sh
# SW1 - GNS3 "Open vSwitch" Docker appliance, run in the node's console (root shell).
# eth0 = e0 trunk to R1 eth0, eth1 = e1 VLC Sender (VLAN 20), eth2 = e2 IGMP Receiver (VLAN 10)
# The settings are stored in the container's OVS database and survive a node restart.

# Only the three lab ports stay in the bridge.
for p in eth3 eth4 eth5 eth6 eth7; do ovs-vsctl --if-exists del-port br0 $p; done

# 802.1Q trunk to R1 (VLANs 10 and 20, tagged) and the two access ports.
ovs-vsctl set port eth0 vlan_mode=trunk trunks=10,20
ovs-vsctl set port eth1 vlan_mode=access tag=20
ovs-vsctl set port eth2 vlan_mode=access tag=10

# Plain learning switch, no OpenFlow controller.
ovs-vsctl set-fail-mode br0 standalone

# IGMP snooping: send a group only to ports that joined it.
ovs-vsctl set bridge br0 mcast_snooping_enable=true \
  other_config:mcast-snooping-disable-flood-unregistered=true \
  other_config:mcast-snooping-aging-time=300

# eth0 is the multicast router port: it gets all multicast and all IGMP reports.
# Without this, the source's traffic in VLAN 20 has no listener there and is dropped,
# because R1 sends IGMP queries only on VLAN 10.
ovs-vsctl set port eth0 other_config:mcast-snooping-flood=true \
  other_config:mcast-snooping-flood-reports=true

# Check
ovs-vsctl --columns=name,tag,trunks,vlan_mode list port eth0 eth1 eth2
ovs-appctl mdb/show br0
