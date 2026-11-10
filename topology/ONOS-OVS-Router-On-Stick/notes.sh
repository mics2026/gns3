#!/usr/bin/env bash
# notes.sh - put a text note next to each node of the ONOS-OVS-Router-On-Stick project.
# Re-runnable: notes it added before (tagged id='lab-note') are deleted first.
set -uo pipefail
GNS3=${GNS3:-192.168.56.102}
B="http://$GNS3:3080/v2"
PROJECT_NAME=${PROJECT_NAME:-ONOS-OVS-Router-On-Stick}

pj() { perl -MJSON::PP -0777 -ne 'my $d=decode_json($_); '"$1"; }
P=$(curl -s "$B/projects" | N="$PROJECT_NAME" pj 'for(@$d){ print $_->{project_id} if $_->{name} eq $ENV{N} }')
[[ -n $P ]] || { echo "project $PROJECT_NAME not found" >&2; exit 1; }

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

# Node icons sit at: ONOS (-40,-280)  OVS-1 (-40,-40)  FRR-1 (300,-40)  PC10 (-300,220)  PC20 (-40,220)  PC30 (220,220)
note   40 -300 '#1a5fb4' $'ONOS 2.7.0 - SDN controller\neth0 10.10.10.1/24 (mgmt)\nOpenFlow 1.4 listener tcp/6653\nApps: gui2, drivers, openflow, vpls\nVPLS: VLAN10 / VLAN20 / VLAN30\nGUI: HTTP console /onos/ui (onos/rocks)\nREST: /onos/v1 via the same port'
note -400  -90 '#26a269' $'OVS-1 - Open vSwitch br0\ndpid of:0000000000000001\nOpenFlow14 only, fail-mode secure\ncontroller tcp:10.10.10.1:6653\neth0 10.10.10.2/24 mgmt (not in br0)\neth1 port 1 trunk 10,20,30 -> FRR-1\neth2/3/4 ports 2/3/4 -> PC10/20/30'
note  380  -60 '#c64600' $'FRR-1 - router on a stick\neth0 = 802.1Q trunk to OVS-1 eth1\neth0.10 192.168.10.1/24\neth0.20 192.168.20.1/24\neth0.30 192.168.30.1/24\nip_forward=1, /etc/local.d/vlan.start'
note -330  290 '#813d9c' $'PC10 - VLAN 10\n192.168.10.10/24\ngw 192.168.10.1\nOVS-1 eth2 (port 2)'
note  -70  290 '#813d9c' $'PC20 - VLAN 20\n192.168.20.10/24\ngw 192.168.20.1\nOVS-1 eth3 (port 3)'
note  190  290 '#813d9c' $'PC30 - VLAN 30\n192.168.30.10/24\ngw 192.168.30.1\nOVS-1 eth4 (port 4)'
