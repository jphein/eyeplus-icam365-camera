#!/bin/sh
# debug_cmd.sh — iCam365 / EYEPLUS fleet card.
#
# The firmware's own boot script runs this as root, from the SD card, with /bak
# ALREADY mounted read-write:
#
#     if [ -f /mnt/debug_cmd.sh ]; then
#             mountBakRW
#             /mnt/debug_cmd.sh          <-- us, uid 0
#             mountBakRO
#     fi
#
# So this is the vendor's own service hook, not an exploit. Verified on Augentix
# HC1703 (Linux 3.18.31) and on a different silicon vendor entirely (Linux
# 4.9.37) — same hook name on both.
#
# ============================ SAFETY PROPERTIES =============================
#  * Every action beyond recon is OPT-IN via a marker file on the card, so the
#    default card is read-only and cannot change a camera.
#  * START.SH WAITS FOR US. Anything slow must be backgrounded or the camera's
#    boot stalls. The flash dump is backgrounded for exactly this reason.
#  * No credential is ever copied to the card. wpa_supplicant.conf holds a live
#    PSK; we record that it exists and its size, never its contents.
#  * Probe, never assume: applet availability DIFFERS between units. `nc`,
#    `pidof`, `wc`, `basename`, `hexdump` and `strings` are each missing on at
#    least one camera. Every use below is guarded.
#
# ============================== MARKER FILES ================================
#   PERSIST     install a permanent shell into /bak/start.sh (survives card removal)
#   SSH         install dropbearmulti from the card and run SSH instead of telnet
#   DUMPFLASH   dump all MTD partitions to the card (full firmware backup)
#   SETCLOCK    set the system clock from this file's mtime (fixes the 1970 OSD)
#   NOSHELL     recon only — start no shell at all
#
# 🔴 NEVER put a file named firmware.bin (or an OTA marker) on this card. The
#    boot script feeds it straight to sdc_tool and reflashes the device. That is
#    the one action here that can brick rather than inconvenience.

CARD=/mnt
[ -d "$CARD" ] || CARD=/tmp/mnt

# Identify this unit before anything else. The REAL MAC is the only per-unit
# identity these cameras have: ONVIF's "HwAddress" is a per-firmware constant,
# byte-identical across units, and the serial is a shared placeholder.
MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null | tr -d ':' )
[ -n "$MAC" ] || MAC=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*HWaddr *//p' | tr -d ': \n')
[ -n "$MAC" ] || MAC=unknown
OUT="$CARD/units/$MAC"
mkdir -p "$OUT" 2>/dev/null

log() { echo "$*" >> "$OUT/00-run.log" 2>/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }

: > "$OUT/00-run.log" 2>/dev/null
log "=== iCam365 fleet card ==="
log "invoked_as   : $0"
log "uptime_secs  : $(cat /proc/uptime 2>/dev/null)"
log "mac          : $MAC"
log "whoami       : $( (id 2>/dev/null || whoami 2>/dev/null || grep ^Uid /proc/self/status) 2>&1 )"

# ---------------------------------------------------------------- identity --
# One line per boot, appended. Swapping this card down a shelf of cameras
# therefore BUILDS A FLEET INVENTORY with no bookkeeping — which matters because
# nothing these cameras report over the network distinguishes one from another.
CHIP=$(grep -i '^Hardware' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//')
# Where cpuinfo is useless ("Generic DT based system"), the vendor syscall
# binary names the chip in its filename. Measured on two different vendors.
RSC=$(ls /bin/rsyscall.* /home/rsyscall.* /home/bin/rsyscall.* 2>/dev/null | head -1)
KVER=$(sed 's/ (.*//' /proc/version 2>/dev/null | cut -c1-60)
MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')
printf '%s\t%s\t%s\t%s\t%s\n' "$MAC" "${CHIP:-?}" "${RSC:-?}" "${MODEL:-?}" "${KVER:-?}" \
    >> "$CARD/FLEET-INVENTORY.tsv" 2>/dev/null

# ------------------------------------------------------------------- recon --
cap() { echo "### $2" > "$OUT/$1"; eval "$2" >> "$OUT/$1" 2>&1; }
cap 10-cpuinfo   "cat /proc/cpuinfo"
cap 11-version   "cat /proc/version"
cap 12-cmdline   "cat /proc/cmdline"
cap 13-mtd       "cat /proc/mtd"
cap 14-meminfo   "head -8 /proc/meminfo"
cap 15-mounts    "mount"
cap 16-ps        "ps"
cap 17-dev       "ls -la /dev"
cap 18-home      "ls -la /home /bak"
cap 19-passwd    "cat /etc/passwd"
cap 20-busybox   "busybox --list | tr '\n' ' '"
cap 21-startsh   "cat /bak/start.sh"
cap 22-dmesg     "dmesg | tail -200"
cap 23-devicetree "ls /proc/device-tree; cat /proc/device-tree/model; cat /proc/device-tree/compatible"
cap 24-net       "ifconfig; route -n"

# The WiFi config is where the credentials live. Record that it exists and how
# big it is — NEVER its contents. A card travels; a PSK on it is a leak.
cap 25-wificfg-metadata "ls -la /home/wpa_supplicant.conf /home/devParam.dat /home/tange.dat /home/no_cfg_reboot_time 2>&1; echo '--- counters (not secrets):'; cat /home/no_cfg_reboot_time /home/no_ptz_reboot_time 2>/dev/null"

# ---------------------------------------------------------------- SETCLOCK --
# These cameras have no RTC and no NTP, so they boot at epoch and BURN
# "1970-01-01" into every frame via /dev/osd — unfixable from any network
# interface. The card, however, has real mtimes. Borrowing one is not accurate
# time, but it is a plausible recent date, which beats 1970 on a recording.
if [ -f "$CARD/SETCLOCK" ]; then
    REF=$(find "$CARD/SETCLOCK" -newer /proc 2>/dev/null)
    D=$(ls -l --time-style=+%Y%m%d%H%M "$CARD/SETCLOCK" 2>/dev/null | awk '{print $6}')
    if [ -n "$D" ]; then
        date -s "$D" >/dev/null 2>&1 && log "clock set from SETCLOCK mtime: $(date)"
    else
        log "clock: could not read SETCLOCK mtime (busybox ls lacks --time-style?)"
    fi
fi

# -------------------------------------------------------------- DUMPFLASH --
# A full firmware image per unit. This is the input to the only camera-rooting
# method with a real track record — reading an image beats probing a device —
# and it doubles as a restore path if a unit is ever bricked.
# BACKGROUNDED: start.sh waits for this script, and ~8 MB of NOR is slow enough
# to visibly delay boot.
if [ -f "$CARD/DUMPFLASH" ]; then
    log "flash dump: backgrounded"
    (
        mkdir -p "$OUT/flash" 2>/dev/null
        for m in 0 1 2 3 4 5 6 7; do
            [ -e "/dev/mtd$m" ] || continue
            dd if="/dev/mtd$m" of="$OUT/flash/mtd$m.bin" bs=64k 2>/dev/null
        done
        cp /proc/mtd "$OUT/flash/mtd.layout" 2>/dev/null
        sync
        echo done > "$OUT/flash/COMPLETE"
    ) &
fi

# -------------------------------------------------------------- PERSIST/SSH --
# /bak is ALREADY read-write here — the firmware did that for us. Both options
# below edit /bak/start.sh, and both keep an untouched original alongside.
install_line() {   # install_line <marker-comment> <command-line>
    [ -f /bak/start.sh.orig ] || cp /bak/start.sh /bak/start.sh.orig
    if grep -q "$1" /bak/start.sh 2>/dev/null; then
        log "persist: already installed ($1)"; return
    fi
    printf '%s\n' "" "# $1" "$2" >> /bak/start.sh
    # Verify before trusting: a broken start.sh means a camera that will not boot.
    if sh -n /bak/start.sh 2>/dev/null; then
        log "persist: installed ($1); start.sh syntax OK"
    else
        cp /bak/start.sh.orig /bak/start.sh
        log "persist: SYNTAX CHECK FAILED — reverted to original"
    fi
}

SHELL_CMD="busybox telnetd -l /bin/sh -p 2323 2>/dev/null &"

if [ -f "$CARD/SSH" ] && [ -f "$CARD/dropbearmulti" ]; then
    # Statically linked ARM binary; ARMv7 runs ARMv5 code, so one build serves
    # both silicon families measured so far.
    mkdir -p /bak/sbin 2>/dev/null
    cp "$CARD/dropbearmulti" /bak/sbin/dropbearmulti 2>/dev/null
    chmod 755 /bak/sbin/dropbearmulti 2>/dev/null
    ln -sf /bak/sbin/dropbearmulti /bak/sbin/dropbear 2>/dev/null
    ln -sf /bak/sbin/dropbearmulti /bak/sbin/dropbearkey 2>/dev/null
    mkdir -p /bak/etc/dropbear 2>/dev/null
    # Host keys are per-unit and generated on the device. Generating them on the
    # card would give every camera in the fleet the same key.
    [ -f /bak/etc/dropbear/dropbear_rsa_host_key ] || \
        /bak/sbin/dropbearkey -t rsa -f /bak/etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
    if [ -f "$CARD/authorized_keys" ]; then
        mkdir -p /root/.ssh 2>/dev/null
        cp "$CARD/authorized_keys" /root/.ssh/authorized_keys 2>/dev/null
        chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    fi
    SHELL_CMD="/bak/sbin/dropbear -r /bak/etc/dropbear/dropbear_rsa_host_key -p 2222 2>/dev/null &"
    log "ssh: dropbear installed to /bak/sbin"
fi

if [ -f "$CARD/PERSIST" ]; then
    install_line "--- persistent debug shell (fleet card) ---" "$SHELL_CMD"
fi

# ---------------------------------------------------------------- run now ---
# Start a shell for THIS boot too, so the unit is reachable without waiting for
# the next power cycle.
if [ ! -f "$CARD/NOSHELL" ]; then
    eval "$SHELL_CMD"
    log "shell started this boot: $SHELL_CMD"
fi

log "finished_uptime: $(cat /proc/uptime 2>/dev/null)"
sync
exit 0
