#!/usr/bin/env bash
# activate-icam365.sh — rescue an iCam365 stuck in AP mode ("camera startup
# wait for user config").
#
# Run this ON a machine with WiFi (laptop/tablet) near the camera. It joins
# the camera's AICAM_* setup AP, POSTs the /setwifi recipe from
# docs/provisioning.md, reconnects this machine to its previous WiFi, then
# verifies the EFFECT by fetching a frame from the camera's reserved address.
#
# ⚠️  AP-mode rescue ONLY. The target is 192.168.200.1 — the address a camera
#     gives itself in setup mode — so this script cannot reach a camera that
#     is already on the network. Never adapt it to a LAN address: /setwifi on
#     a cloud-bound camera sends userid:"0" over the binding it depends on.
#
# A locally-provisioned camera (userid "0", never cloud-bound) loses its WiFi
# config on EVERY power cycle — confirmed, docs/provisioning.md. This script
# is the recurring remedy, not a one-time fix: rerun it after every power cut.
#
# Deploying with real values baked in: substitute the defaults ANCHORED to
# their variable names, e.g.
#   sed -e 's/ICAM_SSID:-my-iot-ssid/ICAM_SSID:-<ssid>/' \
#       -e 's/ICAM_KEY:-CHANGE-ME/ICAM_KEY:-<psk>/' \
#       -e 's/ICAM_VERIFY_IP:-192.168.1.23/ICAM_VERIFY_IP:-<camera ip>/'
# A bare global s/CHANGE-ME/<psk>/g once rewrote the guard below into
# [ "$KEY" = "<psk>" ], which then rejected the very value it was given.

set -u

# nmcli's network-control needs polkit authorization that SSH and detached
# sessions lack ("Not authorized to control networking"); a local desktop
# session has it. Re-exec through sudo when that is available untended.
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then
    exec sudo -n "$0" "$@"
fi

SSID="${ICAM_SSID:-my-iot-ssid}"            # the legacy camera SSID
KEY="${ICAM_KEY:-CHANGE-ME}"                # its WPA2 PSK
VERIFY_IP="${ICAM_VERIFY_IP:-192.168.1.23}" # the camera's DHCP reservation
AP_URL="http://192.168.200.1:20202/setwifi" # camera's own AP address — fixed

say() { printf '\n== %s\n' "$*"; }

# Split literal: a deploy-time global sed on the placeholder must not be able
# to rewrite this comparison.
if [ "$KEY" = 'CHANGE''-ME' ]; then
    echo "Set ICAM_KEY (and ICAM_SSID / ICAM_VERIFY_IP) before running." >&2
    exit 1
fi

WIFI_DEV=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1; exit}')
if [ -z "$WIFI_DEV" ]; then
    echo "No WiFi device on this machine." >&2
    exit 1
fi

PREV=$(nmcli -t -f NAME,TYPE connection show --active |
       awk -F: '$2=="802-11-wireless"{print $1; exit}')

say "Scanning for the camera's setup AP (AICAM_*)"
AICAM=$(nmcli -t -f SSID dev wifi list ifname "$WIFI_DEV" --rescan yes |
        grep -m1 '^AICAM_' || true)
if [ -z "$AICAM" ]; then
    echo "No AICAM_* network in range. The camera is not in AP mode, or is too far away."
    echo "Power-cycle it, wait ~60 s for 'waiting for config', then rerun."
    exit 1
fi

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
    exit 1
fi

TOKEN="and_$(tr -dc 'a-z' </dev/urandom | head -c 5)"
say "POST /setwifi  ssid=$SSID  (userid 0 + bind_token — all four fields are mandatory)"
RESP_FILE=$(mktemp)
HTTP=$(curl -sS -m 10 -o "$RESP_FILE" -w '%{http_code}' \
       -H 'Content-Type: application/json' \
       -d "{\"ssid\":\"$SSID\",\"key\":\"$KEY\",\"userid\":\"0\",\"bind_token\":\"$TOKEN\"}" \
       "$AP_URL") || HTTP=000
BODY=$(cat "$RESP_FILE" 2>/dev/null); rm -f "$RESP_FILE"
echo "   HTTP $HTTP  body: ${BODY:-<none>}"
if [ "$HTTP" != "200" ]; then
    echo "Camera rejected the request (400 = a missing/bad field; 000 = no answer)." >&2
    exit 1
fi
echo "   A 200 means PARSED, not honoured. The camera now reboots itself into station mode."

say "Restoring this machine's WiFi (${PREV:-none})"
nmcli connection delete "$AICAM" >/dev/null 2>&1 || true
if [ -n "$PREV" ]; then
    nmcli connection up "$PREV" >/dev/null 2>&1 || true
fi

# A brand-new unit has no DHCP reservation yet, so its address is unknown. Set
# ICAM_VERIFY_IP='' to sweep the camera subnet instead and report what answers.
# The sweep connects to named ports rather than port-scanning: nmap is
# documented-unreliable against these cameras (docs/vendor-api.md).
if [ -z "$VERIFY_IP" ]; then
    SUBNET="${ICAM_SUBNET:-192.168.1}"
    say "Discovering the new camera on $SUBNET.0/24 (up to 3 min)"
    echo "   Known-camera addresses are listed as KNOWN; anything else is your new unit."
    KNOWN="${ICAM_KNOWN:-}"
    for _ in $(seq 1 18); do
        FOUND=""
        for h in $(seq 1 254); do
            IP="$SUBNET.$h"
            # :8001 is the vendor snapshot port; :80 is ONVIF. A different model
            # may serve one and not the other, so accept either.
            for probe in "8001/snapshot" "80/onvif/device_service"; do
                C=$(curl -s -m 1 -o /dev/null -w '%{http_code}' \
                    "http://$IP:${probe}" 2>/dev/null) || C=000
                case "$C" in
                    200|400|401|405)
                        case " $KNOWN " in
                            *" $IP "*) FOUND="$FOUND  $IP (KNOWN)" ;;
                            *)         FOUND="$FOUND  $IP  <-- NEW" ;;
                        esac
                        break ;;
                esac
            done
        done
        if [ -n "$FOUND" ]; then
            say "Cameras answering on $SUBNET.0/24:"
            printf '%s\n' $FOUND | sed 's/^/   /'
            echo
            echo "Give the NEW address a DHCP reservation now — the ONVIF integration"
            echo "cannot be reconfigured in place, so the address you pair on is permanent."
            exit 0
        fi
        sleep 10
    done
    say "Nothing answered on $SUBNET.0/24 after 3 min."
    exit 2
fi

say "Verifying the EFFECT: polling http://$VERIFY_IP:8001/snapshot (up to 3 min)"
for _ in $(seq 1 36); do
    CODE=$(curl -s -m 4 -o /dev/null -w '%{http_code}' \
           "http://$VERIFY_IP:8001/snapshot" 2>/dev/null) || CODE=000
    if [ "$CODE" = "200" ]; then
        say "VERIFIED — camera is back on WiFi and serving frames."
        exit 0
    fi
    sleep 5
done

say "NOT verified after 3 min."
echo "Either the camera did not rejoin (wrong PSK -> it falls back to AP mode; rescan"
echo "for AICAM_*), or this network cannot reach $VERIFY_IP. Check from a host that can:"
echo "  curl -o /tmp/f.jpg http://$VERIFY_IP:8001/snapshot"
exit 2
