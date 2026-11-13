#!/usr/bin/env bash
# notes.sh - put a text note next to each node of the FRR-on-Stick project
# (802.1Q router-on-a-stick lab). Re-runnable: notes it added before (tagged
# id='lab-note') are deleted first; hand-made labels in the project are left alone.
# Needs only curl and perl (both in Git Bash on Windows).
set -uo pipefail
GNS3=${GNS3:-192.168.56.102}
B="http://$GNS3:3080/v2"
PROJECT_NAME=${PROJECT_NAME:-FRR-on-Stick}

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
  local svg="<svg width=\"$w\" height=\"$h\"><text id=\"lab-note\" font-family=\"monospace\" font-size=\"10\" font-weight=\"bold\" fill=\"$color\">$text</text></svg>"
  local body; body=$(X=$x Y=$y S="$svg" perl -MJSON::PP -e 'print encode_json({x=>0+$ENV{X}, y=>0+$ENV{Y}, z=>2, svg=>$ENV{S}})')
  curl -s -o /dev/null -w "  note @($x,$y) HTTP %{http_code}\n" -X POST "$B/projects/$P/drawings" -d "$body"
}

# Node icons sit at: FRR-1 (44,-200)  MVL-L2 (46,56)  VLAN10 (363,93)  VLAN20 (-239,104)
note -360 -290 '#c64600' $'FRR-1 - FRR 8.2.2, router on a stick\neth0 = 802.1Q trunk to MVL-L2 port 2\neth0.10 192.168.10.1/24 = VLAN 10 gateway\neth0.20 192.168.20.1/24 = VLAN 20 gateway\nip_forward=1 routes between the VLANs\nsubinterfaces: ip link add link eth0\n  name eth0.10 type vlan id 10 (shell)\nnot persistent: re-run after reboot\ncheck (vtysh): show ip route'
note -480  -60 '#26a269' $'MVL-L2 - GNS3 built-in Ethernet switch\nport 0 access VLAN 20 -> VLAN20 PC\nport 1 access VLAN 10 -> VLAN10 PC\nport 2 dot1q trunk  -> FRR-1 eth0\n  (VLAN 10/20 tagged, native VLAN 1)\nconfigure in the GUI only:\n  delete links, Configure, Apply, relink'
note  300  205 '#1a5fb4' $'VLAN10 - VPCS PC\n192.168.10.10/24, gw 192.168.10.1\nMVL-L2 port 1 (access VLAN 10)\ntest: ping 192.168.20.10\n      trace 192.168.20.10\n      (1st hop 192.168.10.1)'
note -330  215 '#813d9c' $'VLAN20 - VPCS PC\n192.168.20.10/24, gw 192.168.20.1\nMVL-L2 port 0 (access VLAN 20)\ntest: ping 192.168.10.10\n      trace 192.168.10.10\n      (1st hop 192.168.20.1)'
