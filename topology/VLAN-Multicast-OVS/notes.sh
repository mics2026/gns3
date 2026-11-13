#!/usr/bin/env bash
# notes.sh - put a text note next to each node of the VLAN-Multicast-OVS project.
# Re-runnable: notes it added before (tagged id='lab-note') are deleted first.
# Needs only curl and perl (both in Git Bash on Windows).
set -uo pipefail
GNS3=${GNS3:-192.168.56.102}
B="http://$GNS3:3080/v2"
PROJECT_NAME=${PROJECT_NAME:-VLAN-Multicast-OVS}

pj() { perl -MJSON::PP -0777 -ne 'my $d=decode_json($_); '"$1"; }
P=$(curl -s "$B/projects" | N="$PROJECT_NAME" pj 'for(@$d){ print $_->{project_id} if $_->{name} eq $ENV{N} }')
[[ -n $P ]] || { echo "project $PROJECT_NAME not found" >&2; exit 1; }
curl -s -o /dev/null -X POST "$B/projects/$P/open"

# Remove our old notes.
for id in $(curl -s "$B/projects/$P/drawings" | pj 'for(@$d){ print "$_->{drawing_id}\n" if $_->{svg} =~ /lab-note/ }'); do
  curl -s -X DELETE "$B/projects/$P/drawings/$id" >/dev/null
done

note() { # x y color text(\n-separated)
  local x=$1 y=$2 color=$3 text=$4 lines h w
  lines=$(printf '%s\n' "$text" | wc -l)
  w=$(printf '%s\n' "$text" | awk '{ if (length > m) m = length } END { print m * 7 + 10 }')
  h=$((lines * 15 + 6))
  # One SVG <text> with newlines; GNS3 renders each line. Body is JSON-encoded by perl.
  local svg="<svg width=\"$w\" height=\"$h\"><text id=\"lab-note\" font-family=\"monospace\" font-size=\"10\" font-weight=\"bold\" fill=\"$color\">$text</text></svg>"
  local body; body=$(X=$x Y=$y S="$svg" perl -MJSON::PP -e 'print encode_json({x=>0+$ENV{X}, y=>0+$ENV{Y}, z=>2, svg=>$ENV{S}})')
  curl -s -o /dev/null -w "  note @($x,$y) HTTP %{http_code}\n" -X POST "$B/projects/$P/drawings" -d "$body"
}

# Node icons sit at: R1 (0,-250)  SW1 (0,0)  VLC-Sender (-250,200)  IGMP-Receiver (250,200)
note   90 -300 '#c64600' $'R1 - FRR 8.2.2, router on a stick\neth0 = 802.1Q trunk to SW1 eth0\neth0.10 192.168.10.1/24 (VLAN 10)\n  ip pim, ip igmp v3, query-interval 30\n  IGMP querier for the receiver\neth0.20 192.168.20.1/24 (VLAN 20)\n  ip pim, first-hop router\nRP 192.168.20.1 for 239.0.0.0/8\nSSM range 232.0.0.0/8 (no RP)\nrp_filter=0, ip_forward=1\n/etc/local.d/lab.start rebuilds eth0.10/.20'
note -400  -60 '#26a269' $'SW1 - Open vSwitch br0 (standalone)\neth0 trunk 10,20  -> R1 eth0\n  mcast-snooping-flood (mrouter port)\neth1 access VLAN 20 -> VLC-Sender\neth2 access VLAN 10 -> IGMP-Receiver\nIGMP snooping on,\n  unregistered groups not flooded\ncheck: ovs-appctl mdb/show br0'
note -420  260 '#1a5fb4' $'VLC-Sender - multicast source\neth0 192.168.20.10/24 (VLAN 20)\ngw 192.168.20.1\nsends UDP to 239.1.1.1:5004, TTL 16\ntest: ping -t 16 -I eth0 239.1.1.1\nVLC: cvlc ... dst=239.1.1.1:5004 --ttl=16'
note  170  260 '#813d9c' $'IGMP-Receiver - multicast receiver\neth0 192.168.10.10/24 (VLAN 10)\ngw 192.168.10.1\njoin: ip addr add 239.1.1.1/32\n      dev eth0 autojoin\nIGMP v3 default; v2: sysctl -w\n  net.ipv4.conf.eth0.force_igmp_version=2\nVLC: cvlc udp://@239.1.1.1:5004'
