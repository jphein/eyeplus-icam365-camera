#!/usr/bin/env bash
# activate-icam365.sh — provision an iCam365 from its AP-mode setup network.
#
# Run this ON a machine with WiFi (laptop/tablet) near the camera. It joins the
# camera's AICAM_* setup AP, POSTs the /setwifi recipe from docs/provisioning.md,
# reconnects this machine to its previous WiFi, then identifies the camera by
# EFFECT: it diffs the camera subnet before and after, so the newly-appeared
# address is the unit just provisioned.
#
# Idempotent: with no AICAM_* in range there is nothing to provision, and that
# is reported as success (exit 0), not as a failure. Re-running is safe.
#
# ⚠️  AP-mode rescue ONLY. The target is 192.168.200.1 — the address a camera
#     gives itself in setup mode — so this script cannot reach a camera that is
#     already on the network. Never adapt it to a LAN address: /setwifi on a
#     bound camera sends userid:"0" over the binding it depends on.
#
# A locally-provisioned camera (userid "0", never cloud-bound) may lose its WiFi
# config on a power cycle — see docs/provisioning.md, and note the cause is
# contested (pairing method vs firmware version). Re-run this after an outage.
#
# Deploying with real values baked in: substitute the defaults ANCHORED to their
# variable names, e.g.
#   sed -e 's/ICAM_SSID:-my-iot-ssid/ICAM_SSID:-<ssid>/' \
#       -e 's/ICAM_KEY:-CHANGE-ME/ICAM_KEY:-<psk>/' \
#       -e 's/ICAM_SUBNET:-192.168.1/ICAM_SUBNET:-<subnet>/'
# A bare global s/CHANGE-ME/<psk>/g once rewrote the guard below into
# [ "$KEY" = "<psk>" ], which then rejected the very value it was given.

set -u

SSID="${ICAM_SSID:-my-iot-ssid}"        # the camera SSID to join them to
KEY="${ICAM_KEY:-CHANGE-ME}"            # its WPA2 PSK
SUBNET="${ICAM_SUBNET:-192.168.1}"      # camera subnet, /24, no trailing dot
TARGET="${ICAM_TARGET_BSSID:-}"         # optional: pick one camera by its MAC
LOG="${ICAM_LOG:-$HOME/icam365-provisioned.log}"
AP_URL="http://192.168.200.1:20202/setwifi"   # camera's own AP — fixed

say() { printf '\n== %s\n' "$*"; }

# nmcli's network-control needs polkit authorization that SSH and detached
# sessions lack ("Not authorized to control networking"); a local desktop
# session has it. Re-exec through sudo when that is available untended.
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then
    exec sudo -n "$0" "$@"
fi

# Split literal: a deploy-time global sed on the placeholder must not be able
# to rewrite this comparison.
if [ "$KEY" = 'CHANGE''-ME' ]; then
    echo "Set ICAM_KEY (and ICAM_SSID / ICAM_SUBNET) before running." >&2
    exit 1
fi

WIFI_DEV=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1; exit}')
if [ -z "$WIFI_DEV" ]; then
    echo "No WiFi device on this machine." >&2
    exit 1
fi

# Probe named ports and confirm by connecting — nmap is documented-unreliable
# against these cameras (docs/vendor-api.md). Parallel across DIFFERENT hosts is
# fine; what these cameras cannot take is concurrent connections to ONE of them.
sweep() {
    seq 1 254 | xargs -P 32 -I{} sh -c '
        ip="'"$SUBNET"'.{}"
        for probe in 8001/snapshot 80/onvif/device_service; do
            c=$(curl -s -m 1 -o /dev/null -w "%{http_code}" "http://$ip/$probe" 2>/dev/null)
            case "$c" in 200|400|401|405) echo "$ip"; exit 0 ;; esac
        done' 2>/dev/null | sort -V
}

say "Scanning for camera setup APs (AICAM_*)"
# `--rescan yes` BLOCKS until the scan completes. A bare `nmcli dev wifi rescan`
# plus a sleep returns whatever is in the cache, which lists APs that are no
# longer on the air — a provisioned camera's setup AP lingers there and the
# script then tries to join a network that does not exist.
APS=$(nmcli -t -f SSID,BSSID,SIGNAL dev wifi list ifname "$WIFI_DEV" --rescan yes |
      grep '^AICAM_' | sed 's/\\//g')

if [ -z "$APS" ]; then
    say "No camera is in setup mode — nothing to provision."
    echo "This is the expected result when every camera is already on WiFi."
    echo "If you expected one here: it may be out of range, or still booting"
    echo "(give it ~60 s after power-on), or already provisioned."
    exit 0
fi

echo "$APS" | awk -F: '{printf "   %-22s %s\n", $1, substr($0, index($0,$2))}'
COUNT=$(printf '%s\n' "$APS" | wc -l)

if [ -n "$TARGET" ]; then
    LINE=$(printf '%s\n' "$APS" | grep -i "$TARGET" | head -1)
    if [ -z "$LINE" ]; then
        echo "No setup AP matching ICAM_TARGET_BSSID=$TARGET is in range." >&2
        exit 1
    fi
elif [ "$COUNT" -gt 1 ]; then
    # With a bag of cameras, several may be in setup mode at once. Picking
    # silently would provision an arbitrary unit and misreport which.
    LINE=$(printf '%s\n' "$APS" | sort -t: -k3 -rn | head -1)
    say "⚠️  $COUNT cameras are in setup mode. Choosing the STRONGEST signal."
    echo "   To pick a specific one, set ICAM_TARGET_BSSID to its MAC and re-run."
else
    LINE=$(printf '%s\n' "$APS")
fi

AICAM=$(printf '%s' "$LINE" | cut -d: -f1)
# The setup AP's BSSID *is* the camera's real MAC — and provisioning is the only
# moment a camera reveals a true per-unit identity. ONVIF will not: unique_id is
# a per-firmware constant and the serial is a shared placeholder.
CAM_MAC=$(printf '%s' "$LINE" | sed -n 's/^[^:]*:\(\([0-9A-Fa-f]\{2\}:\)\{5\}[0-9A-Fa-f]\{2\}\).*/\1/p')
echo "   selected: $AICAM  (camera MAC ${CAM_MAC:-unknown})"

PREV=$(nmcli -t -f NAME,TYPE connection show --active |
       awk -F: '$2=="802-11-wireless"{print $1; exit}')

say "Recording which cameras already answer on $SUBNET.0/24"
BEFORE=$(sweep)
printf '%s\n' "$BEFORE" | sed 's/^/   /'

say "Joining $AICAM"
if ! nmcli dev wifi connect "$AICAM" ifname "$WIFI_DEV" >/dev/null; then
    echo "Could not associate with $AICAM." >&2
    exit 1
fi
for _ in $(seq 1 15); do
    ip -4 addr show dev "$WIFI_DEV" | grep -q 'inet 192\.168\.200\.' && break
    sleep 1
done
if ! ip -4 addr show dev "$WIFI_DEV" | grep -q 'inet 192\.168\.200\.'; then
    echo "Associated but no 192.168.200.x lease arrived." >&2
    nmcli connection delete "$AICAM" >/dev/null 2>&1 || true
    [ -n "$PREV" ] && nmcli connection up "$PREV" >/dev/null 2>&1
    exit 1
fi

TOKEN="and_$(tr -dc 'a-z' </dev/urandom | head -c 5)"
say "POST /setwifi  ssid=$SSID  (userid 0 + bind_token — all four are mandatory)"
RESP=$(mktemp)
HTTP=$(curl -sS -m 10 -o "$RESP" -w '%{http_code}' \
       -H 'Content-Type: application/json' \
       -d "{\"ssid\":\"$SSID\",\"key\":\"$KEY\",\"userid\":\"0\",\"bind_token\":\"$TOKEN\"}" \
       "$AP_URL") || HTTP=000
BODY=$(cat "$RESP" 2>/dev/null); rm -f "$RESP"
echo "   HTTP $HTTP  body: ${BODY:-<none>}"

say "Restoring this machine's WiFi (${PREV:-none})"
nmcli connection delete "$AICAM" >/dev/null 2>&1 || true
[ -n "$PREV" ] && nmcli connection up "$PREV" >/dev/null 2>&1

if [ "$HTTP" != "200" ]; then
    echo "Camera rejected the request (400 = missing/bad field; 000 = no answer)." >&2
    exit 1
fi
echo "   A 200 means PARSED, not honoured. Verifying by effect below."

say "Waiting for a NEW camera to appear on $SUBNET.0/24 (up to 3 min)"
for _ in $(seq 1 18); do
    sleep 10
    NEW=$(comm -13 <(printf '%s\n' "$BEFORE") <(sweep))
    if [ -n "$NEW" ]; then
        say "VERIFIED — provisioned and answering:"
        for ip in $NEW; do
            echo "   $ip   camera MAC ${CAM_MAC:-unknown}   (was $AICAM)"
            printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$ip" "${CAM_MAC:-unknown}" "$AICAM" >> "$LOG"
        done
        echo
        echo "Logged to $LOG"
        echo "⚠️  Give that address a DHCP reservation keyed to the MAC above."
        echo "    The ONVIF integration cannot be reconfigured in place, so the"
        echo "    address you pair on is effectively permanent."
        exit 0
    fi
done

say "No new address appeared after 3 min."
echo "The camera did not join (a wrong PSK sends it back to AP mode — rescan for"
echo "AICAM_*), or it took an address this host cannot reach."
exit 2
