#!/usr/bin/env bash
# wan-window.sh — open a scoped, time-boxed WAN exception for ONE camera,
# capture everything it says, then close the window and PROVE it closed.
#
# Purpose: capture a vendor app pairing and/or an OTA firmware update, which
# are the only routes to the vendor's cloud protocol and to a firmware image.
#
# 🔴 The camera VLAN is default-deny to WAN by deliberate policy — there is no
#    cameras->wan forwarding at all. This script does NOT change that. It adds
#    a single ACCEPT rule for ONE source address, and removes it again.
#
# 🔴 NEVER point this at the production camera, and never widen it to the VLAN.
#    Run it against an expendable bench unit.
#
# Discipline this script enforces, from docs/method.md:
#   * config is not behaviour — after closing, it re-checks by OBSERVING that
#     no further cloud packets flow, not by re-reading the config. A previous
#     revert in this project "read correct" while still being live.
#   * the firewall is backed up before the change, and restored from that
#     backup rather than by hand-undoing.
#
# Usage:  wan-window.sh <camera-ip> [minutes]      (default 15)

set -u

CAM="${1:-}"
MINS="${2:-15}"
GW="${WAN_WINDOW_GW:-192.168.1.1}"        # gateway (stand-in; deploy substitutes)
PROD="${WAN_WINDOW_PROD:-192.168.1.21}"   # production camera — refuse to touch
RULE="icam365-wan-window"
STAMP=$(date +%Y%m%d-%H%M%S)
CAP="/tmp/icam365-wan-$STAMP.pcap"
BAK="/tmp/fw-backup-wanwindow-$STAMP.conf"

say() { printf '\n== %s\n' "$*"; }
gw()  { ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$GW" "$@"; }

if [ -z "$CAM" ]; then
    echo "Usage: $(basename "$0") <camera-ip> [minutes]" >&2; exit 1
fi
if [ "$CAM" = "$PROD" ]; then
    echo "REFUSING: $CAM is the production camera. Use an expendable unit." >&2
    exit 1
fi

say "Backing up the firewall to $BAK on the gateway"
gw "uci export firewall > $BAK && wc -l < $BAK" | xargs echo "   lines:"

say "Starting capture of ALL $CAM traffic -> $CAP"
gw "nohup tcpdump -i any -n -s 0 -w $CAP host $CAM >/dev/null 2>&1 &
    sleep 2; pgrep -f 'tcpdump.*$CAM' >/dev/null && echo '   capture running'"

say "Opening WAN for $CAM only, for $MINS minutes"
gw "uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='$RULE'
    uci set firewall.@rule[-1].src='cameras'
    uci set firewall.@rule[-1].src_ip='$CAM'
    uci set firewall.@rule[-1].dest='wan'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1
    echo '   rule added and firewall reloaded'"

say "Window is OPEN. Pair the camera in the vendor app now, then trigger the"
echo "   firmware update. Closing automatically in $MINS minutes."
echo "   Ctrl-C does NOT close it — re-run with 0 minutes to close early."
sleep $(( MINS * 60 ))

say "Closing the window (restoring the pre-change firewall from backup)"
gw "uci import firewall < $BAK && uci commit firewall &&
    /etc/init.d/firewall reload >/dev/null 2>&1 && echo '   restored'"

say "VERIFYING BEHAVIOURALLY — config is not behaviour"
echo "   Watching 60 s for any further WAN-bound traffic from $CAM..."
LEAK=$(gw "timeout 60 tcpdump -i any -n -c 5 'host $CAM and not net 10.0.0.0/8 and not net 192.168.0.0/16' 2>/dev/null | wc -l")
echo "   packets to non-RFC1918 destinations in 60 s: ${LEAK:-?}"
if [ "${LEAK:-1}" = "0" ]; then
    echo "   ✅ CLOSED and verified by observation."
else
    echo "   🔴 STILL LEAKING — investigate before walking away."
fi

say "Stopping capture and collecting"
# NOTE: `pkill -f tcpdump` would match this very command line and has killed the
# invoking shell in this project before. Match the capture file instead.
gw "pkill -f \"w $CAP\" 2>/dev/null; sleep 1; ls -l $CAP"
mkdir -p ./captures
scp -q "root@$GW:$CAP" ./captures/ && echo "   -> ./captures/$(basename "$CAP")"

say "Quick triage of what was captured"
if command -v tshark >/dev/null; then
    echo "   --- hostnames the camera resolved:"
    tshark -r "./captures/$(basename "$CAP")" -Y 'dns.flags.response==0' \
           -T fields -e dns.qry.name 2>/dev/null | sort -u | head -20
    echo "   --- plaintext HTTP requests (an unencrypted OTA shows up here):"
    tshark -r "./captures/$(basename "$CAP")" -Y 'http.request' \
           -T fields -e http.host -e http.request.uri 2>/dev/null | sort -u | head -20
else
    echo "   tshark not installed locally — analyse ./captures/$(basename "$CAP") elsewhere."
fi
