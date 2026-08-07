#!/usr/bin/env bash
# enroll-camera.sh — take a freshly-activated camera all the way to a working
# Home Assistant tile: DHCP reservation, liveness proof, then a Generic Camera
# entry. Designed for a fleet, not a one-off.
#
# Usage: enroll-camera.sh <name> <mac> [ip]
#        enroll-camera.sh --from-log        enroll everything activate-icam365.sh logged
#
# Why a reservation is step one, not an afterthought:
#   * Most of these cameras LOSE their WiFi config on a power cut and have to be
#     re-provisioned. Without a reservation they come back on whatever address
#     the pool hands out, and every dashboard tile pointing at the old address
#     silently shows nothing.
#   * The real MAC is the ONLY per-unit identity these cameras have. ONVIF's
#     "HwAddress" is a formatted pointer, identical across every unit on the same
#     firmware; the serial and HardwareId are shared placeholders. So the MAC —
#     captured from the setup AP's BSSID at activation time — is what a
#     reservation must key on.
#
# Why Generic Camera and not the ONVIF integration:
#   Adding a second same-firmware camera through ONVIF does not error. It
#   OVERWRITES the first entry's host and credentials, reloads it against the new
#   camera, and reports "already configured" — so the original entity ids end up
#   streaming the wrong camera. Generic Camera keys on a random id and cannot
#   collide at any fleet size. See docs/home-assistant.md.

set -u

GW="${ICAM_GW:-192.168.1.1}"
HA_URL="${HA_URL:-https://homeassistant.local:8123}"
HA_TOKEN="${HA_TOKEN:-}"
LOG="${ICAM_LOG:-$HOME/icam365-provisioned.log}"

say() { printf '\n== %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

[ -n "$HA_TOKEN" ] || die "Set HA_TOKEN (a long-lived access token)."

ha() { # ha <method> <path> [json]
    local m="$1" p="$2" d="${3:-}"
    if [ -n "$d" ]; then
        curl -s -m 30 -X "$m" -H "Authorization: Bearer $HA_TOKEN" \
             -H 'Content-Type: application/json' -d "$d" "$HA_URL$p"
    else
        curl -s -m 30 -X "$m" -H "Authorization: Bearer $HA_TOKEN" "$HA_URL$p"
    fi
}

reserve() { # reserve <name> <mac> <ip>
    ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$GW" "
        if uci show dhcp | grep -q \"'$2'\"; then
            echo '   reservation already exists — leaving it alone'
        else
            uci add dhcp host >/dev/null
            uci set dhcp.@host[-1].name='$1'
            uci set dhcp.@host[-1].mac='$2'
            uci set dhcp.@host[-1].ip='$3'
            uci commit dhcp && /etc/init.d/dnsmasq reload >/dev/null 2>&1
            echo '   reserved $3 -> $1'
        fi"
}

# A still image is what makes a tile work in a browser: these cameras stream
# H.265 only, which Chrome and Firefox cannot decode, so a live tile renders
# black. Not every model serves stills the same way, so probe rather than assume.
find_still() { # find_still <ip> -> prints a working URL, or nothing
    local ip="$1" u
    for u in "http://$ip:8001/snapshot" "http://$ip/onvif/snapshot"; do
        if [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$u")" = "200" ]; then
            echo "$u"; return 0
        fi
    done
    return 1
}

enroll() { # enroll <name> <mac> <ip>
    local name="$1" mac="$2" ip="$3"
    say "$name  ($mac)  ->  $ip"

    reserve "$name" "$mac" "$ip"

    # Verify by EFFECT before telling HA about it. An entity pointed at a camera
    # that is not answering looks identical to a broken entity.
    local still
    if still=$(find_still "$ip"); then
        echo "   still image: $still"
    else
        echo "   ⚠️  no working still-image endpoint — the tile would render black,"
        echo "      because both streams are H.265 and browsers cannot decode it."
        echo "      Skipping. Route this one through go2rtc for a still."
        return 1
    fi

    # Two fetches: a byte-identical pair means a cached or frozen image, which is
    # indistinguishable from a working camera in a single sample.
    local a b
    a=$(curl -s -m 5 "$still" | md5sum | cut -d' ' -f1); sleep 1
    b=$(curl -s -m 5 "$still" | md5sum | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "   ⚠️  two fetches were byte-identical — image may be frozen"

    # ⚠️ The Generic Camera flow is TWO steps, and its `advanced` field is a
    # nested object, not a boolean. Getting either wrong returns a *form* rather
    # than an error — so the call looks like it succeeded, and no entity is ever
    # created. Both were found by running this, not by reading the docs.
    local flow fid
    flow=$(ha POST /api/config/config_entries/flow '{"handler":"generic","show_advanced_options":true}')
    fid=$(printf '%s' "$flow" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("flow_id",""))')
    [ -n "$fid" ] || { echo "   could not start the Generic Camera flow"; return 1; }

    # Step 1 — stream details. The SUBSTREAM deliberately: measured 12.35 fps
    # with zero stalls, against ~9.3 fps and whole dropped GOPs on the
    # mainstream, whose 92-97 KB keyframes do not survive this WiFi.
    ha POST "/api/config/config_entries/flow/$fid" \
      "{\"still_image_url\":\"$still\",\"stream_source\":\"rtsp://$ip:554/0/av1\",\"username\":\"\",\"password\":\"\",\"advanced\":{\"rtsp_transport\":\"tcp\",\"framerate\":2,\"verify_ssl\":false}}" >/dev/null

    # Step 2 — the preview confirmation. Without this, nothing is created.
    local res
    res=$(ha POST "/api/config/config_entries/flow/$fid" '{"confirmed_ok":true}')
    if printf '%s' "$res" | grep -q create_entry; then
        echo "   ✅ Generic Camera entry created"
    else
        echo "   ⚠️  flow did not complete: $(printf '%s' "$res" | head -c 200)"
        return 1
    fi
}

if [ "${1:-}" = "--from-log" ]; then
    [ -f "$LOG" ] || die "No activation log at $LOG"
    n=0
    while IFS=$'\t' read -r _ts ip mac ssid; do
        [ -n "${mac:-}" ] && [ "$mac" != "unknown" ] || continue
        enroll "icam365-$(printf '%s' "$mac" | tr -d ':' | tail -c 5)" "$mac" "$ip" && n=$((n+1))
    done < "$LOG"
    say "enrolled $n camera(s) from $LOG"
else
    [ $# -ge 2 ] || die "Usage: $(basename "$0") <name> <mac> [ip]   |   --from-log"
    enroll "$1" "$2" "${3:-}"
fi
