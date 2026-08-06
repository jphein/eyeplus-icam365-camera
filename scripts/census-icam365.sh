#!/usr/bin/env bash
# census-icam365.sh — inventory every camera on the camera subnet, by EFFECT.
#
# Answers the question a 12-unit fleet actually needs: which physical cameras
# are up, at what address, on what firmware — and it does NOT trust the ONVIF
# identity fields to tell them apart, because they cannot:
#
#   * `unique_id` (GetNetworkInterfaces HwAddress) is a formatted POINTER, not
#     a MAC. Two different cameras on the same firmware return byte-identical
#     values. [M] Use it as a FIRMWARE fingerprint, never as a device id.
#   * `SerialNumber` is the placeholder 12345679890 on every unit. [M]
#   * `Model`/`HardwareId` are firmware-family constants. [M]
#
# The only true per-unit identity is the REAL MAC, which the camera never
# reveals over ONVIF — it comes from the gateway's DHCP leases (or, at
# provisioning time, from the setup AP's BSSID; see activate-icam365.sh).
#
# Usage: census-icam365.sh [subnet]        e.g. census-icam365.sh 192.168.1
#        Writes a TSV snapshot to ./captures/census-<stamp>.tsv
#
# Intended use: run it, power-cycle the fleet, run it again, diff. That is the
# durability experiment -- see docs/provisioning.md.

set -u

SUBNET="${1:-${ICAM_SUBNET:-192.168.1}}"
GW="${ICAM_GW:-192.168.1.1}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="./captures/census-$STAMP.tsv"
mkdir -p ./captures

soap() {  # soap <ip> <operation>
    printf '<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
<%s xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body></s:Envelope>' "$2" |
    curl -s -m 8 -H 'Content-Type: application/soap+xml; charset=utf-8' \
         --data-binary @- "http://$1/onvif/device_service" 2>/dev/null
}

# NOTE: the firmware emits `<tt:HwAddress >` — with a space inside the tag.
# A regex for `HwAddress>` silently matches nothing, and a script that then
# reports a change is reporting its own parse failure. Allow the whitespace.
field() { printf '%s' "$1" | grep -oE "<[a-z]+:$2\s*>[^<]*" | head -1 | sed "s/.*$2\s*>//"; }

echo "Sweeping $SUBNET.0/24 for cameras (named ports, connect-confirmed — nmap is"
echo "documented-unreliable against these devices)..."
LIVE=$(seq 1 254 | xargs -P 32 -I{} sh -c '
    ip="'"$SUBNET"'.{}"
    for p in 8001/snapshot 80/onvif/device_service; do
        c=$(curl -s -m 1 -o /dev/null -w "%{http_code}" "http://$ip/$p" 2>/dev/null)
        case "$c" in 200|400|401|405) echo "$ip"; exit 0 ;; esac
    done' 2>/dev/null | sort -V)

if [ -z "$LIVE" ]; then echo "Nothing answered on $SUBNET.0/24."; exit 1; fi

# Real MACs come from the gateway; the cameras cannot be asked.
LEASES=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$GW" \
         'cat /tmp/dhcp.leases 2>/dev/null' 2>/dev/null)

printf 'ip\treal_mac\tfirmware\tmodel\tserial\tfw_fingerprint\tsnapshot\n' > "$OUT"
printf '\n%-15s %-19s %-10s %-14s %-28s %s\n' \
       IP REAL_MAC FIRMWARE MODEL FW_FINGERPRINT SNAP
printf '%.0s-' $(seq 1 108); echo

for ip in $LIVE; do
    INFO=$(soap "$ip" GetDeviceInformation); sleep 0.4
    NET=$(soap "$ip" GetNetworkInterfaces);  sleep 0.4
    FW=$(field "$INFO" FirmwareVersion); MODEL=$(field "$INFO" Model)
    SER=$(field "$INFO" SerialNumber);    HW=$(field "$NET" HwAddress)
    MAC=$(printf '%s\n' "$LEASES" | awk -v i="$ip" '$3==i{print $2; exit}')
    SNAP=$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://$ip:8001/snapshot" 2>/dev/null)
    printf '%-15s %-19s %-10s %-14s %-28s %s\n' \
           "$ip" "${MAC:-unknown}" "${FW:-?}" "${MODEL:-?}" "${HW:-?}" "${SNAP:-000}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$ip" "${MAC:-unknown}" "${FW:-?}" "${MODEL:-?}" "${SER:-?}" "${HW:-?}" "${SNAP:-000}" >> "$OUT"
done

echo
echo "Saved: $OUT"

# Duplicate fingerprints are EXPECTED and are the point: they prove the value
# tracks the build. They also predict a Home Assistant collision -- and an ONVIF
# collision is a SILENT TAKEOVER of the existing entry, not a rejection.
DUPS=$(awk -F'\t' 'NR>1 && $6!="?" {c[$6]++} END{for(k in c) if(c[k]>1) print c[k], k}' "$OUT")
if [ -n "$DUPS" ]; then
    echo
    echo "⚠️  Cameras sharing an ONVIF fingerprint (same firmware = same 'unique_id'):"
    printf '%s\n' "$DUPS" | sed 's/^/    /'
    echo "    🔴 Do NOT add these to Home Assistant via the ONVIF integration."
    echo "       Adding the second one OVERWRITES the first entry's host and"
    echo "       credentials and reloads it against the new camera, while"
    echo "       reporting 'already configured'. See docs/home-assistant.md."
fi
