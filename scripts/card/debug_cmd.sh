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
# ⚠️ At ~6 s into boot wlan0 does NOT exist yet, so reading it returns nothing
# and every unit files itself as "unknown" — measured. The kernel logs the eFuse
# MAC during early init, so dmesg has it before the interface does.
# ⚠️ Measured: at ~6 s into boot neither wlan0 NOR the efuse dmesg line exists
# yet — the WiFi driver has not initialised. Both sources return empty and every
# unit files itself as "unknown". The identity line is therefore ALSO written
# from a delayed background pass further down, once the interface is up.
MAC=$(dmesg 2>/dev/null | sed -n 's/.*efuse_macaddr:\([0-9a-f:]*\).*/\1/p' | head -1 | tr -d ':')
[ -n "$MAC" ] || MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null | tr -d ':')
[ -n "$MAC" ] || MAC=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*HWaddr *//p' | tr -d ': \n')
[ -n "$MAC" ] || MAC=unknown-$(cut -d' ' -f1 /proc/uptime 2>/dev/null | tr -d '.')
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
    # ⚠️ Reading the marker's MTIME does not work here: this busybox `ls` has no
    # --time-style and there is no `stat`. Measured — it logged exactly that.
    # So the date is carried INSIDE the file instead, which needs no applet at
    # all beyond `cat`.
    # ⚠️ busybox `date -s` rejected the bare digit string (measured). Try the
    # accepted forms in turn rather than assuming one — this is a thin busybox.
    RAW=$(cat "$CARD/SETCLOCK" 2>/dev/null | head -1)
    SET=no
    for FMT in "$RAW" "$(echo "$RAW" | sed 's/^\(....\)\(..\)\(..\)\(..\)\(..\).*/\1-\2-\3 \4:\5:00/')" \
               "$(echo "$RAW" | sed 's/^\(....\)\(..\)\(..\)\(..\)\(..\).*/\2\3\4\5\1/')"; do
        [ -n "$FMT" ] || continue
        if date -s "$FMT" >/dev/null 2>&1; then SET="$FMT"; break; fi
    done
    if [ "$SET" != "no" ]; then log "clock set (format '$SET'): $(date)"
    else log "clock: every date -s format rejected; raw was '$RAW'"; fi
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
# 🔴 NEVER overwrite a file that already exists on the camera, and back up
# anything touched to the CARD before touching it.
#
# Measured the hard way: /home/custom_pre_init.sh is ABSENT on the Augentix units
# and PRESENT (1116 B, vendor) on a sibling platform, where it writes the
# pin-multiplexing registers for PTZ, both IR-cut pins, the alarm light and the
# IR light. Overwriting it would have left every one of those pins unmuxed at the
# next boot. It was recovered only because a flash dump happened to have run
# eight minutes earlier. Do not rely on that again.
backup_to_card() {   # backup_to_card <path>
    [ -f "$1" ] || return 0
    mkdir -p "$OUT/original" 2>/dev/null
    cp "$1" "$OUT/original/$(echo "$1" | tr '/' '_')" 2>/dev/null
    sync
    log "backed up to card: $1"
}

# Install a hook the vendor CALLS but stock units lack. Appends if it already
# exists; never clobbers.
install_hook() {   # install_hook <hook-path> <command-line>
    backup_to_card "$1"
    if [ -f "$1" ]; then
        # ⚠️ Guard on THIS command, not on the string 'fleet card'. This function
        # is called twice with different commands (telnet, then SSH); a generic
        # marker made the second call a no-op, so SSH was silently never
        # installed while the log cheerfully said "already installed".
        if grep -qF "$2" "$1" 2>/dev/null; then
            log "hook: already present in $1 — $2"; return
        fi
        log "hook: $1 EXISTS (vendor file) — appending, not replacing"
        printf '%s\n' "" "# --- fleet card ---" "$2" >> "$1"
    else
        printf '%s\n' '#!/bin/sh' "# --- fleet card --- delete this file to revert" "$2" > "$1"
        chmod 755 "$1" 2>/dev/null
        log "hook: created $1"
    fi
    sh -n "$1" 2>/dev/null || log "hook: SYNTAX CHECK FAILED on $1"
}

install_line() {   # install_line <marker-comment> <command-line>
    # The sibling platform has no /bak; its start.sh lives in /home.
    ST=/bak/start.sh; [ -f "$ST" ] || ST=/home/start.sh
    [ -f "$ST" ] || { log "persist: no start.sh to edit"; return; }
    backup_to_card "$ST"
    [ -f "$ST.orig" ] || cp "$ST" "$ST.orig"
    if grep -q "$1" "$ST" 2>/dev/null; then
        log "persist: already installed ($1)"; return
    fi
    printf '%s\n' "" "# $1" "$2" >> "$ST"
    # Verify before trusting: a broken start.sh means a camera that will not boot.
    if sh -n /bak/start.sh 2>/dev/null; then
        log "persist: installed ($1); start.sh syntax OK"
    else
        cp /bak/start.sh.orig /bak/start.sh
        log "persist: SYNTAX CHECK FAILED — reverted to original"
    fi
}

SHELL_CMD="busybox telnetd -l /bin/sh -p 2323 2>/dev/null &"

# Which partition can we actually write to? Augentix units have a 4.6 MB /bak;
# the sibling platform has NO /bak whatsoever and only /home (~3.8 MB jffs2) is
# writable. Hardcoding /bak silently disabled SSH on that platform: every mkdir
# and cp failed into /dev/null and the daemon simply never started.
RW=/home
if [ -d /bak ] && mkdir -p /bak/.wtest 2>/dev/null; then RW=/bak; rmdir /bak/.wtest 2>/dev/null; fi
log "writable base: $RW"

if [ -f "$CARD/SSH" ] && [ -f "$CARD/dropbearmulti" ]; then
    # Statically linked ARM binary; ARMv7 runs ARMv5 code, so one build serves
    # both silicon families measured so far.
    mkdir -p $RW/sbin 2>/dev/null
    cp "$CARD/dropbearmulti" $RW/sbin/dropbearmulti 2>/dev/null
    chmod 755 $RW/sbin/dropbearmulti 2>/dev/null
    ln -sf $RW/sbin/dropbearmulti $RW/sbin/dropbear 2>/dev/null
    
    mkdir -p $RW/etc/dropbear 2>/dev/null
    # ⚠️ FOUR measured traps here, each of which silently produced NO SSH while
    # every cheap check passed. Verified fixed on a live unit: SSH_LOGIN_OK,
    # uid=0(root). See docs/root-access.md for the full write-up.
    #
    #  1. There is NO dropbearkey. This build ships only dropbear/dbclient/scp,
    #     and neither the symlink nor `dropbearmulti dropbearkey` dispatches it.
    #     ⚠️ Its own usage text says "run 'dropbearmulti <command>'" — that text
    #     is not a capability list. Reading a tool's docs is not running it.
    #
    #  2. 🔴 `-R` CANNOT WORK HERE, and the previous note calling it "measured
    #     working: the port came up" was measuring the wrong thing. `-R` defers
    #     keygen to CONNECTION time and writes to a compiled-in /etc/dropbear on
    #     a READ-ONLY squashfs. The daemon starts, netstat shows LISTEN, ps shows
    #     it alive — and every login dies with "Exit before auth". A listening
    #     port is not a working service.
    #     Fix: ship pre-generated keys on the card and use -r (read-only), which
    #     is also why /bak may stay mounted ro and this survives a reboot.
    #
    #  3. dropbear finds authorized_keys via getpwnam(), NOT $HOME — /etc/passwd
    #     says /root, so HOME=/bak/root was decorative. /root must be bind-
    #     mounted over. That mount is emitted into SSH_CMD so it also runs at
    #     every boot, not just this one.
    #
    #  4. dropbear 2016.74 predates ed25519 USER keys. Put an ssh-rsa key in
    #     authorized_keys, and connect with -o PubkeyAcceptedAlgorithms=+ssh-rsa
    #     (modern OpenSSH disables SHA-1 RSA signatures by default).
    if [ -f "$CARD/authorized_keys" ]; then
        mkdir -p $RW/root/.ssh 2>/dev/null
        cp "$CARD/authorized_keys" $RW/root/.ssh/authorized_keys 2>/dev/null
        chmod 700 $RW/root/.ssh 2>/dev/null
        chmod 600 $RW/root/.ssh/authorized_keys 2>/dev/null
        log "ssh: authorized_keys -> $RW/root/.ssh/"
        grep -q 'ssh-rsa' $RW/root/.ssh/authorized_keys 2>/dev/null \
            || log "ssh: WARNING no ssh-rsa key present — 2016.74 cannot use ed25519 user keys"
    fi
    # Host keys come from the card. Generate them on a workstation with
    # `dropbearkey -t ecdsa -f dropbear_ecdsa_host_key` (apt install dropbear-bin);
    # the format is architecture-independent. Without them, SSH cannot work.
    HOSTKEYS=""
    for k in ecdsa rsa; do
        if [ -f "$CARD/dropbear_${k}_host_key" ]; then
            cp "$CARD/dropbear_${k}_host_key" "$RW/etc/dropbear/dropbear_${k}_host_key" 2>/dev/null
            chmod 600 "$RW/etc/dropbear/dropbear_${k}_host_key" 2>/dev/null
        fi
        [ -f "$RW/etc/dropbear/dropbear_${k}_host_key" ] && \
            HOSTKEYS="$HOSTKEYS -r $RW/etc/dropbear/dropbear_${k}_host_key"
    done
    if [ -n "$HOSTKEYS" ]; then
        SSH_CMD="mount -o bind $RW/root /root 2>/dev/null; $RW/sbin/dropbearmulti dropbear$HOSTKEYS -p 2222 2>/dev/null &"
        log "ssh: dropbear staged at $RW/sbin, host keys:$HOSTKEYS"
    else
        SSH_CMD=""
        log "ssh: NO host key on card or $RW — SSH DISABLED (dropbear -R cannot"
        log "ssh: generate one on a read-only rootfs). Telnet on 2323 is unaffected."
    fi
fi

# ⚠️ SSH SUPPLEMENTS telnet, it never replaces it.
#
# The first version of this script made SHELL_CMD *become* the dropbear line, so
# a dropbear that failed to start left the camera with NO shell at all — worse
# than the card that had no SSH feature. An optional enhancement must not be
# able to remove the capability it is enhancing. Measured the hard way: a unit
# came back on WiFi with neither 2222 nor 2323 open.
if [ -f "$CARD/PERSIST" ]; then
    # Prefer the vendor's own hook over editing start.sh: the CALL lives in
    # vendor start.sh, so a firmware update that restores start.sh keeps calling
    # our hook — whereas an edit TO start.sh is exactly what such an update
    # erases. Platform differs: Augentix units keep it in /bak, the sibling in
    # /home, and only one of the two has a /bak at all.
    HOOK=""
    [ -f /bak/start.sh ] && HOOK=/bak/custom_pre_init.sh
    [ -f /home/start.sh ] && HOOK=/home/custom_pre_init.sh
    if [ -n "$HOOK" ]; then
        install_hook "$HOOK" "$SHELL_CMD"
        [ -n "${SSH_CMD:-}" ] && install_hook "$HOOK" "$SSH_CMD"
    else
        log "persist: no start.sh found in /bak or /home — nothing to hook"
    fi
    install_line "--- persistent debug shell (fleet card) ---" "$SHELL_CMD"
    [ -n "${SSH_CMD:-}" ] && install_line "--- persistent ssh (fleet card) ---" "$SSH_CMD"
fi

# ---------------------------------------------------------------- run now ---
# Start a shell for THIS boot too, so the unit is reachable without waiting for
# the next power cycle. Telnet first and unconditionally: it uses the on-device
# busybox and cannot fail for want of a copied binary.
if [ ! -f "$CARD/NOSHELL" ]; then
    eval "$SHELL_CMD"
    log "telnet started this boot: $SHELL_CMD"
    if [ -n "${SSH_CMD:-}" ]; then
        eval "$SSH_CMD"
        log "ssh started this boot: $SSH_CMD"
        # Record whether the binary actually runs on this silicon, since the
        # dropbear build is ARMv5 and these units are ARMv7.
        log "dropbear runs here: $($RW/sbin/dropbearmulti 2>&1 | head -1)"
    fi
fi

# --------------------------------------------------- delayed identity pass ---
# The MAC is not available this early. Re-run the identity capture in the
# background once the WiFi driver has come up, so FLEET-INVENTORY.tsv gets a
# real per-unit key rather than "unknown".
(
    sleep 45
    M=$(cat /sys/class/net/wlan0/address 2>/dev/null | tr -d ':')
    [ -n "$M" ] || M=$(dmesg 2>/dev/null | sed -n 's/.*efuse_macaddr:\([0-9a-f:]*\).*/\1/p' | head -1 | tr -d ':')
    if [ -n "$M" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$M" "${CHIP:-?}" "${RSC:-?}" "${MODEL:-?}" "${KVER:-?}" \
            >> "$CARD/FLEET-INVENTORY.tsv" 2>/dev/null
        [ -d "$OUT" ] && mv "$OUT" "$CARD/units/$M" 2>/dev/null
        sync
    fi
) &

log "finished_uptime: $(cat /proc/uptime 2>/dev/null)"
sync
exit 0
