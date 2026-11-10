#!/usr/bin/env bash
# deploy.sh - build, configure and verify the ONOS + OVS + FRR router-on-a-stick lab
# on a GNS3 2.2 server, end to end. Safe to re-run: every step checks before it changes.
#
#   ./deploy.sh                 # full run: templates, nodes, links, start, configure, verify
#   GNS3=192.168.56.102 ./deploy.sh
#
# Needs: bash with /dev/tcp (Git Bash on Windows or Linux), curl, perl (JSON::PP), timeout.
# The GNS3 server needs Docker (ONOS and Open vSwitch are Docker nodes).

set -uo pipefail
trap '' PIPE   # a console that drops must not kill the script silently

GNS3=${GNS3:-192.168.56.102}
B="http://$GNS3:3080/v2"
PROJECT_NAME=${PROJECT_NAME:-ONOS-OVS-Router-On-Stick}
ONOS_IMAGE=${ONOS_IMAGE:-onosproject/onos:2.7.0}
OVS_IMAGE=${OVS_IMAGE:-gns3/openvswitch:latest}
ONOS_TEMPLATE="ONOS 2.7"
OVS_TEMPLATE="Open vSwitch"
DPID=0000000000000001
ONOS_MGMT=10.10.10.1
OVS_MGMT=10.10.10.2
VLANS=(10 20 30)
# OpenFlow 1.4, not 1.5: in the OF1.5 handshake OVS (2.17) sends a 32-byte meter-features reply
# and ONOS 2.7's OF1.5 decoder requires the 40-byte 1.5.1 layout ("Wrong length: Expected=40,
# got=32"), so ONOS drops the switch in WAIT_METER_FEATURES_REPLY. 1.4 is the highest that works.
OF_PROTO=OpenFlow14
OF_EXPECT=OF_14
# gui2 must be listed: onos-service only activates the GUI by default when ONOS_APPS is unset.
ONOS_ENV="ONOS_APPS=gui2,drivers,openflow,vpls"
# "clean" is passed to Karaf: wipe data/ on every start. Without it, ONOS restarted in the same
# container fails with Atomix "Failed to acquire storage lock" and no core services (GUI 404).
ONOS_START="clean"

FAILS=0
log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    [ OK ] %s\n' "$*"; }
bad()  { printf '    [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------- GNS3 REST + JSON helpers ----------
api() { local m=$1 p=$2; shift 2; curl -sS -m "${API_TIMEOUT:-90}" -X "$m" "$B$p" -H 'Content-Type: application/json' "$@"; }
pj()  { perl -MJSON::PP -0777 -ne 'my $d=eval{decode_json($_)}; exit 2 unless defined $d; '"$1"; }

template_id() { api GET /templates | N="$1" pj 'for(@$d){ print $_->{template_id} if $_->{name} eq $ENV{N} }'; }
node_id()     { api GET "/projects/$P/nodes" | N="$1" pj 'for(@$d){ print $_->{node_id} if $_->{name} eq $ENV{N} }'; }
node_field()  { api GET "/projects/$P/nodes/$1" | F="$2" pj 'print $d->{$ENV{F}} // ""'; }

# ---------- telnet console helpers (fd 3) ----------
BUF=""
con_open()   { exec 3<>"/dev/tcp/$GNS3/$1" || die "cannot open console $GNS3:$1"; BUF=""; }
con_close()  { exec 3<&- 3>&-; }
con_drain()  { timeout "${1:-1}" cat <&3 2>/dev/null | LC_ALL=C tr -cd '\11\12\15\40-\176'; }
con_send()   { printf '%s\r' "$1" >&3; sleep "${2:-0.3}"; }
con_expect() { # regex, timeout-seconds -> 0 if matched; whole output in $BUF
  local pat=$1 end=$((SECONDS + ${2:-30})); BUF=""
  while (( SECONDS < end )); do BUF+=$(con_drain 1); [[ $BUF =~ $pat ]] && return 0; done
  return 1
}
con_sh() { # run one shell command on the open console; returns its exit status
  # The marker is split with '' so the echoed command line can't match it.
  con_send "$1; echo __RC=\$?__E''ND__"
  con_expect '__RC=([0-9]+)__END__' "${2:-60}" || { info "timeout: $1"; return 99; }
  return "${BASH_REMATCH[1]}"
}

# =====================================================================
log "Preflight: GNS3 server $GNS3"
ver=$(api GET /version | pj 'print $d->{version}') || die "GNS3 API not reachable at $B"
ok "GNS3 server $ver"
api GET /computes/local/docker/images | pj 'exit(ref $d eq "ARRAY" ? 0 : 1)' || die "Docker is not available on the GNS3 server.
Run this on the Ubuntu VM, then re-run ./deploy.sh:

    sudo apt-get update && sudo apt-get install -y docker.io
    sudo usermod -aG docker ubuntu
    sudo systemctl restart gns3-server
    docker run --rm hello-world"
ok "Docker available on compute 'local'"

# =====================================================================
log "Templates"
ensure_template() { # name json
  local id; id=$(template_id "$1")
  if [[ -n $id ]]; then ok "$1 exists ($id)"; else
    id=$(api POST /templates -d "$2" | pj 'print $d->{template_id} // ""')
    [[ -n $id ]] || die "could not create template $1"
    ok "$1 created ($id)"
  fi
  printf -v "$3" '%s' "$id"
}
ensure_template "$ONOS_TEMPLATE" "{\"name\":\"$ONOS_TEMPLATE\",\"template_type\":\"docker\",\"compute_id\":\"local\",
  \"image\":\"$ONOS_IMAGE\",\"adapters\":1,\"category\":\"guest\",\"default_name_format\":\"ONOS{0}\",
  \"console_type\":\"http\",\"console_http_port\":8181,\"console_http_path\":\"/onos/ui\",
  \"start_command\":\"$ONOS_START\",\"environment\":\"$ONOS_ENV\"}" T_ONOS
ensure_template "$OVS_TEMPLATE" "{\"name\":\"$OVS_TEMPLATE\",\"template_type\":\"docker\",\"compute_id\":\"local\",
  \"image\":\"$OVS_IMAGE\",\"adapters\":8,\"category\":\"switch\",\"default_name_format\":\"OVS-{0}\",
  \"console_type\":\"telnet\",\"symbol\":\":/symbols/classic/multilayer_switch.svg\"}" T_OVS
T_FRR=$(template_id FRR);  [[ -n $T_FRR ]]  || die "FRR template not found"
T_VPCS=$(template_id VPCS); [[ -n $T_VPCS ]] || die "VPCS template not found"

# =====================================================================
log "Project $PROJECT_NAME"
P=$(api GET /projects | N="$PROJECT_NAME" pj 'for(@$d){ print $_->{project_id} if $_->{name} eq $ENV{N} }')
if [[ -z $P ]]; then
  P=$(api POST /projects -d "{\"name\":\"$PROJECT_NAME\"}" | pj 'print $d->{project_id}') || die "create project failed"
  ok "created $P"
else ok "exists $P"; fi
api POST "/projects/$P/open" >/dev/null

# =====================================================================
log "Nodes (the first ONOS/OVS node pulls its Docker image; ONOS is ~1 GB)"
ensure_node() { # name template x y -> sets global NID
  NID=$(node_id "$1")
  if [[ -z $NID ]]; then
    NID=$(API_TIMEOUT=1800 api POST "/projects/$P/templates/$2" -d "{\"x\":$3,\"y\":$4,\"compute_id\":\"local\"}" | pj 'print $d->{node_id} // ""')
    [[ -n $NID ]] || die "could not create node $1"
    api PUT "/projects/$P/nodes/$NID" -d "{\"name\":\"$1\"}" >/dev/null
    ok "$1 created"
  else
    api PUT "/projects/$P/nodes/$NID" -d "{\"x\":$3,\"y\":$4}" >/dev/null
    ok "$1 exists"
  fi
}
ensure_node ONOS  "$T_ONOS"   -40 -280; N_ONOS=$NID
props=$(api GET "/projects/$P/nodes/$N_ONOS" | pj 'print "$d->{properties}{start_command}|$d->{properties}{environment}"')
if [[ $props != "$ONOS_START|$ONOS_ENV" ]]; then   # node made from an older template: fix it (needs a stop)
  api POST "/projects/$P/nodes/$N_ONOS/stop" >/dev/null
  API_TIMEOUT=300 api PUT "/projects/$P/nodes/$N_ONOS" -d "{\"properties\":{\"start_command\":\"$ONOS_START\",\"environment\":\"$ONOS_ENV\"}}" >/dev/null
  ok "ONOS node: start_command=$ONOS_START, $ONOS_ENV"
fi
ensure_node OVS-1 "$T_OVS"    -40  -40; N_OVS=$NID
ensure_node FRR-1 "$T_FRR"    300  -40; N_FRR=$NID
ensure_node PC10  "$T_VPCS"  -300  220; N_PC10=$NID
ensure_node PC20  "$T_VPCS"   -40  220; N_PC20=$NID
ensure_node PC30  "$T_VPCS"   220  220; N_PC30=$NID

# =====================================================================
log "Links"
ensure_link() { # nodeA adapterA nodeB adapterB label
  local links; links=$(api GET "/projects/$P/links")
  if A="$1" AA="$2" pj 'for my $l(@$d){ for(@{$l->{nodes}}){ exit 0 if $_->{node_id} eq $ENV{A} && $_->{adapter_number}==$ENV{AA} } } exit 1' <<<"$links"; then
    ok "$5 (exists)"; return
  fi
  api POST "/projects/$P/links" -d "{\"nodes\":[{\"node_id\":\"$1\",\"adapter_number\":$2,\"port_number\":0},{\"node_id\":\"$3\",\"adapter_number\":$4,\"port_number\":0}]}" \
    | pj 'exit($d->{link_id} ? 0 : 1)' && ok "$5" || bad "$5"
}
ensure_link "$N_OVS" 0 "$N_ONOS" 0 "OVS-1 eth0 <-> ONOS eth0   (mgmt / OpenFlow)"
ensure_link "$N_OVS" 1 "$N_FRR"  0 "OVS-1 eth1 <-> FRR-1 eth0  (trunk 10,20,30)"
ensure_link "$N_OVS" 2 "$N_PC10" 0 "OVS-1 eth2 <-> PC10        (VLAN 10)"
ensure_link "$N_OVS" 3 "$N_PC20" 0 "OVS-1 eth3 <-> PC20        (VLAN 20)"
ensure_link "$N_OVS" 4 "$N_PC30" 0 "OVS-1 eth4 <-> PC30        (VLAN 30)"

log "Canvas notes"
GNS3=$GNS3 PROJECT_NAME=$PROJECT_NAME "$(dirname "$0")/notes.sh" || bad "notes.sh"

# =====================================================================
log "Starting all nodes"
API_TIMEOUT=600 api POST "/projects/$P/nodes/start" >/dev/null || bad "start nodes"
for n in ONOS OVS-1 FRR-1 PC10 PC20 PC30; do
  id=$(node_id $n); st=$(node_field "$id" status); c=$(node_field "$id" console)
  [[ $st == started ]] && ok "$n started (console $c)" || bad "$n status=$st"
done

# GNS3 writes a sample /etc/network/interfaces on a Docker node's first start, so node files
# are written after starting. A node whose file changed is reloaded once to pick it up.
log "Node files: management IPs and PC addresses"
put_file() { # node path content label
  local cur; cur=$(curl -sS -m 30 "$B/projects/$P/nodes/$1/files/$2")
  if [[ $cur == "${3%$'\n'}" ]]; then ok "$4 (unchanged)"; return; fi
  local code; code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$B/projects/$P/nodes/$1/files/$2" --data-binary "$3")
  [[ $code == 201 ]] || { bad "$4 (HTTP $code)"; return; }
  # stop + start, not reload: a reloaded Docker node comes back with no ethX interfaces on GNS3 2.2.61.
  API_TIMEOUT=300 api POST "/projects/$P/nodes/$1/stop" >/dev/null
  API_TIMEOUT=600 api POST "/projects/$P/nodes/$1/start" >/dev/null && ok "$4 (written, node restarted)" || bad "$4 restart"
}
put_file "$N_ONOS" etc/network/interfaces $'auto eth0\niface eth0 inet static\n    address '"$ONOS_MGMT"$'\n    netmask 255.255.255.0\n' "ONOS eth0 $ONOS_MGMT/24"
put_file "$N_OVS"  etc/network/interfaces $'auto eth0\niface eth0 inet static\n    address '"$OVS_MGMT"$'\n    netmask 255.255.255.0\n' "OVS-1 eth0 $OVS_MGMT/24"
for v in "${VLANS[@]}"; do
  nid_var=N_PC$v
  put_file "${!nid_var}" startup.vpc $'set pcname PC'"$v"$'\nip 192.168.'"$v"'.10/24 192.168.'"$v"$'.1\n' "PC$v 192.168.$v.10/24 gw .1"
done

C_ONOS=$(node_field "$N_ONOS" console)
C_OVS=$(node_field "$N_OVS" console)
C_FRR=$(node_field "$N_FRR" console)

# =====================================================================
log "OVS-1: $OF_PROTO, secure fail mode, controller $ONOS_MGMT"
for i in $(seq 1 30); do   # the console accepts connections before the container shell is ready
  con_open "$C_OVS"; con_send "" 1
  con_sh "ovs-vsctl br-exists br0" 10 && break
  con_close; sleep 3
done
con_sh "ovs-vsctl br-exists br0 || ovs-vsctl add-br br0" || bad "br0 missing"
for p in 0 1 2 3 4 5 6 7; do con_sh "ovs-vsctl --if-exists del-port br0 eth$p" >/dev/null; done
for p in 1 2 3 4; do
  con_sh "ovs-vsctl add-port br0 eth$p -- set interface eth$p ofport_request=$p" || bad "add eth$p to br0"
done
con_sh "ip link set eth0 up; ip addr show eth0 | grep -q $OVS_MGMT/ || ip addr add $OVS_MGMT/24 dev eth0"
con_sh "ovs-vsctl set bridge br0 other-config:datapath-id=$DPID protocols=$OF_PROTO fail-mode=secure" && ok "br0 dpid=$DPID protocols=$OF_PROTO fail-mode=secure" || bad "bridge settings"
con_sh "ovs-vsctl set-controller br0 tcp:$ONOS_MGMT:6653" && ok "controller tcp:$ONOS_MGMT:6653" || bad "set-controller"
con_sh "ping -c 2 -W 2 $ONOS_MGMT >/dev/null" 15 && ok "OVS-1 reaches ONOS on the mgmt link" || bad "OVS-1 cannot ping $ONOS_MGMT"
con_close

# =====================================================================
log "FRR-1: 802.1Q subinterfaces + gateways (waits for boot)"
con_open "$C_FRR"
shell=no
for i in $(seq 1 60); do con_send "" 0.5; con_expect 'login: *$|[#$>] *$' 4 && break; done
for i in 1 2 3 4; do
  if [[ $BUF =~ login:\ *$ ]]; then
    con_send root 1; con_expect 'Password: *$|[#$>] *$' 15
    [[ $BUF =~ Password ]] && { con_send "" 1; con_expect '[#$>] *$' 15; }
  fi
  con_send "echo SH''ELL_\$((40+2))"; if con_expect 'SHELL_42' 6; then shell=yes; break; fi
  con_send "end" 0.5; con_send "exit" 1; con_expect 'login: *$|[#$>] *$' 8   # probably in vtysh: leave it
done
if [[ $shell == yes ]]; then
  ok "logged in to FRR-1 shell"
  con_sh "modprobe 8021q 2>/dev/null; ip link set eth0 up"
  for v in "${VLANS[@]}"; do
    con_sh "ip link show eth0.$v >/dev/null 2>&1 || ip link add link eth0 name eth0.$v type vlan id $v; ip link set eth0.$v up" \
      && ok "eth0.$v up" || bad "eth0.$v"
  done
  con_sh "sysctl -w net.ipv4.ip_forward=1 >/dev/null" && ok "ip_forward=1"
  vty="vtysh -c 'conf t'"
  for v in "${VLANS[@]}"; do vty+=" -c 'interface eth0.$v' -c 'ip address 192.168.$v.1/24' -c 'exit'"; done
  con_sh "$vty -c 'end' -c 'write memory' >/dev/null" 30 && ok "gateways 192.168.{10,20,30}.1/24, saved" || bad "vtysh config"
  # Make the subinterfaces survive a reboot (frr.conf keeps the IPs, not the links).
  con_sh "mkdir -p /etc/local.d && printf '%s\n' '#!/bin/sh' 'modprobe 8021q 2>/dev/null' 'ip link set eth0 up' 'for v in 10 20 30; do ip link add link eth0 name eth0.\$v type vlan id \$v 2>/dev/null; ip link set eth0.\$v up; done' 'sysctl -w net.ipv4.ip_forward=1' > /etc/local.d/vlan.start && chmod +x /etc/local.d/vlan.start && (rc-update add local default >/dev/null 2>&1 || true)" \
    && ok "persisted in /etc/local.d/vlan.start"
  con_sh "vtysh -c 'show ip route connected'" 15; printf '%s\n' "$BUF" | grep -E '^C' | sed 's/^/      /'
else
  bad "could not reach a shell on FRR-1 console $C_FRR (last output: ${BUF: -120})"
fi
con_close

# =====================================================================
ONOS_URL="http://$GNS3:$C_ONOS/onos/v1"
# No Content-Type unless there's a body: ONOS answers 415 to a GET that carries one.
onos() { local m=$1 p=$2; shift 2; curl -sS -m 30 -u onos:rocks -X "$m" "$ONOS_URL$p" "$@"; }

log "ONOS: wait for startup (REST via the GNS3 HTTP console, port $C_ONOS)"
ready=no
for i in $(seq 1 90); do
  st=$(onos GET /applications/org.onosproject.vpls 2>/dev/null | pj 'print $d->{state} // ""' 2>/dev/null)
  [[ $st == ACTIVE ]] && { ready=yes; break; }
  sleep 5
done
[[ $ready == yes ]] && ok "ONOS up, org.onosproject.vpls ACTIVE" || die "ONOS did not come up within 7.5 min (check the ONOS node console / RAM)"
for app in org.onosproject.fwd org.onosproject.proxyarp; do
  st=$(onos GET /applications/$app | pj 'print $d->{state} // ""' 2>/dev/null)
  if [[ $st == ACTIVE ]]; then onos DELETE /applications/$app/active >/dev/null; ok "deactivated $app (would bridge VLANs)"; fi
done

log "ONOS: VPLS interfaces and VLAN10/20/30 (network config)"
NETCFG=$(cat <<EOF
{
  "ports": {
    "of:$DPID/1": { "interfaces": [
      { "name": "frr-v10", "vlan": "10" },
      { "name": "frr-v20", "vlan": "20" },
      { "name": "frr-v30", "vlan": "30" } ] },
    "of:$DPID/2": { "interfaces": [ { "name": "pc10" } ] },
    "of:$DPID/3": { "interfaces": [ { "name": "pc20" } ] },
    "of:$DPID/4": { "interfaces": [ { "name": "pc30" } ] }
  },
  "apps": {
    "org.onosproject.vpls": { "vpls": { "vplsList": [
      { "name": "VLAN10", "interfaces": ["frr-v10", "pc10"] },
      { "name": "VLAN20", "interfaces": ["frr-v20", "pc20"] },
      { "name": "VLAN30", "interfaces": ["frr-v30", "pc30"] } ] } }
  }
}
EOF
)
onos POST /network/configuration -H 'Content-Type: application/json' -d "$NETCFG" -o /dev/null -w '%{http_code}' | grep -q '^20' && ok "netcfg applied" || bad "netcfg POST"

log "ONOS: wait for OVS-1 to connect"
dev=""
for i in $(seq 1 36); do
  dev=$(onos GET "/devices/of:$DPID" | pj 'print(($d->{available} ? "up" : "down")." ".($d->{annotations}{protocol} // "?"))' 2>/dev/null)
  [[ $dev == up* ]] && break; sleep 5
done
case $dev in
  "up $OF_EXPECT") ok "of:$DPID available, protocol $OF_EXPECT" ;;
  up*)        bad "of:$DPID available but protocol is ${dev#up } (expected $OF_EXPECT)" ;;
  *)          bad "of:$DPID not connected ($dev)" ;;
esac

# =====================================================================
log "Verify from the PCs"
vpcs_ping() { # console pcname target -> 0 if replies; prints the ttl seen
  con_open "$1"; con_send "" 0.5; con_expect "$2> *\$" 5
  local r=1
  for try in 1 2 3; do
    con_send "ping $3 -c 3"; con_expect "$2> *\$" 20
    if [[ $BUF =~ bytes\ from.*ttl=([0-9]+) ]]; then TTL=${BASH_REMATCH[1]}; r=0; break; fi
    sleep 2
  done
  con_close; return $r
}
for v in "${VLANS[@]}"; do
  c=$(node_field "$(node_id PC$v)" console)
  vpcs_ping "$c" "PC$v" "192.168.$v.1" && ok "PC$v -> gateway 192.168.$v.1" || bad "PC$v -> gateway 192.168.$v.1"
done
for pair in "10 20" "10 30" "20 30"; do
  set -- $pair; c=$(node_field "$(node_id PC$1)" console)
  if vpcs_ping "$c" "PC$1" "192.168.$2.10"; then
    [[ $TTL == 63 ]] && ok "PC$1 -> PC$2 routed through FRR-1 (ttl=63)" || ok "PC$1 -> PC$2 (ttl=$TTL)"
  else bad "PC$1 -> PC$2 (192.168.$2.10)"; fi
done

log "ONOS view"
onos GET /hosts | pj 'printf "    host %-17s vlan %-4s %s/%s %s\n", $_->{mac}, $_->{vlan}, $_->{locations}[0]{elementId}, $_->{locations}[0]{port}, join(",",@{$_->{ipAddresses}}) for sort { $a->{locations}[0]{port} <=> $b->{locations}[0]{port} } @{$d->{hosts}}'
onos GET "/flows/of:$DPID" | pj 'printf "    %d flow rules on of:'"$DPID"'\n", scalar @{$d->{flows}}'
onos GET /intents | pj 'printf "    %d intents\n", scalar @{$d->{intents}}'

log "Done"
info "Project : http://$GNS3:3080/static/web-ui/server/1/project/$P"
info "ONOS GUI: http://$GNS3:$C_ONOS/onos/ui   (onos / rocks)"
info "ONOS API: $ONOS_URL"
info "Consoles: OVS-1 telnet $GNS3 $C_OVS, FRR-1 telnet $GNS3 $C_FRR"
if (( FAILS )); then printf '\n%d check(s) failed - see [FAIL] lines above.\n' "$FAILS"; exit 1; fi
printf '\nAll checks passed.\n'
