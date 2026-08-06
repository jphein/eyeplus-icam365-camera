#!/usr/bin/env bash
# view-grid.sh — live substream wall for every camera on the subnet.
#
# Usage: view-grid.sh [ip ...]          no args = auto-discover
#        ICAM_EXCLUDE="a.b.c.d ..."     skip cameras (e.g. one under experiment)
#        ICAM_STREAM=main               use the mainstream instead (not advised)
#
# Why the SUBSTREAM is the default, and not a compromise: measured across three
# 30 s wall-clock captures, the substream ran 12.35 fps with ZERO stalls at
# 213 kbit/s, while the mainstream managed 9.3 fps with multi-second dropouts
# that lost whole GOPs — 92-97 KB I-frames do not survive this WiFi. The docs'
# "~12 fps" for both is nominal. For a wall of cameras the substream is the
# better picture, not the cheaper one.
#
# ⚠️ These cameras die under sustained load. Two were lost in one afternoon to
#    ~1 Hz snapshot polling. RTSP is a single persistent connection and is what
#    the device is built to serve, but do not add snapshot polling on top of a
#    wall that is already streaming, and do not point this at a camera another
#    process is measuring — see ICAM_EXCLUDE.

set -u

SUBNET="${ICAM_SUBNET:-192.168.1}"
EXCLUDE="${ICAM_EXCLUDE:-}"
STREAM="${ICAM_STREAM:-sub}"
COLS_W="${ICAM_SCREEN_W:-1920}"
ROWS_H="${ICAM_SCREEN_H:-1080}"

export DISPLAY="${DISPLAY:-:0}"

# Wayland clients cannot position themselves, so --geometry is silently ignored
# under a Wayland compositor and every window lands stacked on top of the last.
# Forcing mpv onto the X11 backend routes it through XWayland, where X11
# geometry semantics apply and a tiled wall is possible at all.
GPU_CTX="${ICAM_GPU_CTX:-x11egl}"

say() { printf '\n== %s\n' "$*"; }

if [ "$#" -gt 0 ]; then
    CAMS="$*"
else
    say "Discovering cameras on $SUBNET.0/24"
    CAMS=$(seq 1 254 | xargs -P 32 -I{} sh -c '
        ip="'"$SUBNET"'.{}"
        for probe in 8001:/snapshot 80:/onvif/device_service; do
            port=${probe%%:*}; path=${probe#*:}
            c=$(curl -s -m 1 -o /dev/null -w "%{http_code}" "http://$ip:$port$path" 2>/dev/null)
            case "$c" in 200|400|401|405|501) echo "$ip"; exit 0 ;; esac
        done' 2>/dev/null | sort -V | tr '\n' ' ')
fi

# Drop excluded hosts by exact whole-line match. NOT `comm`: it needs
# lexicographic order while addresses get sorted by version, and the two orders
# diverge (x.223 sorts before x.23 lexically, after it by version) — which
# silently mis-reports set membership once you have enough hosts.
if [ -n "$EXCLUDE" ]; then
    KEEP=""
    for c in $CAMS; do
        skip=""
        for e in $EXCLUDE; do [ "$c" = "$e" ] && skip=1; done
        [ -z "$skip" ] && KEEP="$KEEP $c"
    done
    CAMS="$KEEP"
fi

set -- $CAMS
N=$#
if [ "$N" -eq 0 ]; then echo "No cameras found." >&2; exit 1; fi

# Square-ish grid: 1->1x1, 2->2x1, 3-4->2x2, 5-6->3x2, 7-9->3x3
case "$N" in
    1) COLS=1 ;; 2) COLS=2 ;; 3|4) COLS=2 ;; 5|6) COLS=3 ;; *) COLS=3 ;;
esac
ROWS=$(( (N + COLS - 1) / COLS ))
W=$(( COLS_W / COLS ))
H=$(( ROWS_H / ROWS ))

say "$N camera(s) -> ${COLS}x${ROWS} grid, each ${W}x${H}, ${STREAM}stream"

PIDS=""
cleanup() {
    printf '\nClosing the wall...\n'
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    # Do NOT `pkill -f mpv` — an -f pattern can match the process doing the
    # matching, and that has killed the invoking shell in this project before.
    wait 2>/dev/null
    exit 0
}
trap cleanup INT TERM

i=0
for CAM in "$@"; do
    ROW=$(( i / COLS )); COL=$(( i % COLS ))
    X=$(( COL * W )); Y=$(( ROW * H ))

    # `/0/av1` is the substream on the EYEPLUS units. The sibling cloudCam
    # firmware IGNORES the path entirely and serves one 720p stream for every
    # path tried (/0/av0, /0/av1, /1/av1, /2/av0 all identical), so the same URL
    # is correct there too — by accident rather than by agreement.
    AV=av1; [ "$STREAM" = "main" ] && AV=av0
    URL="rtsp://$CAM:554/0/$AV"

    # Each camera gets its own supervised process: one dying must not take the
    # wall down, and these cameras drop off the network regularly.
    (
        while :; do
            mpv --profile=low-latency --vd-lavc-threads=0 --untimed \
                --no-audio --rtsp-transport=tcp \
                --hwdec=no --gpu-hwdec-interop=no --gpu-context="$GPU_CTX" \
                --no-border --ontop=no --keepaspect=yes \
                --geometry="${W}x${H}+${X}+${Y}" --autofit="${W}x${H}" \
                --title="$CAM" --osd-msg1="$CAM" \
                --really-quiet --no-input-terminal \
                "$URL" </dev/null >/dev/null 2>&1
            # mpv exited: camera dropped, or the stream stalled. Back off so a
            # dead camera is not hammered — sustained retries are load too.
            sleep 5
        done
    ) &
    PIDS="$PIDS $!"
    printf '   %-15s %s  @ %dx%d+%d+%d\n' "$CAM" "$URL" "$W" "$H" "$X" "$Y"
    i=$(( i + 1 ))
    sleep 1   # stagger: simultaneous RTSP setups are exactly the concurrent
              # load these cameras handle worst
done

say "Wall is up. Ctrl-C here to close it."
wait
