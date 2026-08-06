#!/usr/bin/env bash
# view-icam365.sh — live viewer for an iCam365 camera.
#
# Usage: view-icam365.sh [ip] [main|sub|snap]
#   main  RTSP main stream,  HEVC 1920x1080 ~12 fps  (mpv, software decode)
#   sub   RTSP sub stream,   HEVC  640x360  ~12 fps  (mpv, cheaper)
#   snap  poll /snapshot JPEGs at ~2 fps — no video codec involved at all
#
# These cameras emit H.265 ONLY (docs/onvif.md: the ONVIF profile says H264;
# that is the load-bearing lie — believe the SDP, not the profile). Linux
# browsers cannot decode HEVC, so viewing is either a native player (mpv) or
# the /snapshot endpoint, which sidesteps codecs entirely at ~25 KB and
# 54-90 ms per frame (docs/vendor-api.md). No auth on either — VLAN is the
# only control.
#
# Deploying: substitute the default ANCHORED to its context, e.g.
#   sed -e 's/{1:-192.168.1.23}/{1:-<camera ip>}/'

set -u

IP="${1:-192.168.1.23}"     # default camera (deploy bakes in the real one)
MODE="${2:-main}"

# GUI apps need a display; make bare ssh runs land on the tablet's own seat.
export DISPLAY="${DISPLAY:-:0}"

case "$MODE" in
main|sub)
    AV=av0
    if [ "$MODE" = sub ]; then AV=av1; fi
    exec mpv --profile=low-latency --no-audio --rtsp-transport=tcp \
         --title="icam365 $IP $MODE" "rtsp://$IP:554/0/$AV"
    ;;
snap)
    T=$(mktemp --suffix=.jpg)
    if ! curl -s -m 4 -o "$T" "http://$IP:8001/snapshot"; then
        echo "No frame from http://$IP:8001/snapshot — is the camera up?" >&2
        rm -f "$T"
        exit 1
    fi
    ( while :; do
          curl -s -m 3 -o "$T.new" "http://$IP:8001/snapshot" && mv -f "$T.new" "$T"
          sleep 0.5
      done ) &
    POLLER=$!
    trap 'kill "$POLLER" 2>/dev/null; rm -f "$T" "$T.new"' EXIT
    feh --reload 0.5 --title "icam365 $IP snapshot" "$T"
    ;;
*)
    echo "Usage: $(basename "$0") [ip] [main|sub|snap]" >&2
    exit 1
    ;;
esac
