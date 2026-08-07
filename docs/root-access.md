# Root shell — via an SD card, in one boot

**These cameras run Linux, and they execute a script from a FAT32 SD card as root at
boot.** No soldering, no UART, no exploit, nothing written to the device. **[M] 2026-08-06**

This page supersedes every earlier statement in this repo that these cameras have "no shell".

## The recipe

Put a **FAT32** card (**≥2 GB**, 8–16 GB ideal) in the camera with an executable script at:

```
/debug_cmd.sh          (card root — the firmware mounts the card at /mnt)
```

Power the camera on. The firmware runs it **as `uid=0(root)`** during boot.

| measured | value |
|---|---|
| Hook that fired | **`/mnt/debug_cmd.sh`** |
| Privilege | **`uid=0(root) gid=0(root)`** |
| When | ~6.7 s into boot; the script finished at 8.3 s |
| Card writable from the script | **yes** — so it can write its results straight back |

> 🔴 **`firmware.bin` at the card root triggers a firmware FLASH.** It is a filename, not a
> command, and it is the one thing here that can brick a unit rather than merely inconvenience it.
> **`find` the card and confirm no `firmware.bin`, `*.bin`, `OTA*`, `rootfs_y*` or `home_y*` before
> it goes near a camera.** If the card has ever held camera firmware, reformat rather than delete.

> ⚠️ **A card smaller than 2 GB silently does nothing** on at least one hook in this family — a
> perfect false negative.

**Ten candidate hook names were written in one boot** and the script recorded which one was
invoked, so a single power cycle identifies the mechanism rather than requiring ten. Only
`debug_cmd.sh` fired on this firmware.

**⚠️ Not all cameras are this family.** Verified on an EYEPLUS unit (`57.0.2.0`). A sibling on
different firmware (`cloudCam`, `47.0.2.0`) is a separate question — a negative there would mean
*"that family has no hook"*, not *"the technique failed"*.

## Getting an interactive shell

The payload starts **`busybox telnetd` on port 2323** — deliberately not 23, so it cannot be
confused with a vendor service. **It skips login entirely** (`telnetd -l /bin/sh`), so no
credential is needed and **nothing on the device is modified** — no bind-mounts, no `/etc/passwd`
edits. Pull the card, power-cycle, and the unit is bit-for-bit stock.

⚠️ **Removing the card does not stop a running `telnetd`.** Only a power cycle does.

⚠️ **The camera must be on the network to reach it.** A unit that has lost its WiFi config comes
back in AP mode with no LAN address, so **re-provision first, then insert the card and boot.**

## What the platform actually is

Every one of these was an open question before the card, and several had been guessed at wrongly.

| | |
|---|---|
| Kernel | **Linux 3.18.31**, built 2024-02-28 |
| CPU | **ARMv7 Cortex-A7** (`CPU part 0xc07`), rev 5, NEON + VFPv4 |
| userland | **BusyBox v1.33.0** (2023-02-08) |
| init | BusyBox init → `/etc/inittab` → `/etc/init.d/rcS` |
| `/etc/passwd` | `root:x:0:0:root:/root:/bin/sh` |
| Console | `::respawn:-/bin/login` |
| Serial getty | **present but commented out** — `ttyAS0` |

> ✅ **This settles the VxWorks question definitively.** The `:6670` task table's `tXxx` names and
> single shared pid were briefly read as VxWorks idiom; that was
> [retracted on the argument that a shared pid is *Linux* TGID semantics](vendor-api.md#-retracted-within-the-hour-this-looks-like-vxworks).
> The kernel banner confirms it. **The retraction was right, and the reasoning that produced it —
> asking what the observation would look like under the competing hypothesis — is the transferable
> part.**

### Flash layout — NOR, ~8 MB, with a factory backup partition

```
mtd0  0x040000  "boot"      256 KB
mtd1  0x010000  "bootenv"    64 KB     <- writable bootloader environment
mtd2  0x180000  "linux"     1.5 MB
mtd3  0x140000  "rootfs"   1.25 MB
mtd4  0x060000  "home"      384 KB     <- device parameters live here
mtd5  0x490000  "bak"       4.6 MB     <- factory backup
```

64 KB erase blocks throughout. **This answers the question a flash programmer was going to be
bought to settle** — it is small NOR, dumpable over the shell with no clip and no desoldering, and
there is already a `bak` partition on the device.

🔑 **`bootenv` is a separate writable partition**, which is the usual route to re-enabling the
commented-out serial console permanently.

### `/home` — where the device identity lives

```
/home/devParam.dat        1004 bytes, mode 000, root-owned
/home/devParam.dat_bak    1004 bytes
/home/alarm.wav
```

**[I]** `devParam.dat` is the obvious candidate for the WiFi credentials and the cloud binding —
which makes it the place to look for
[why some units forget their WiFi on a power cut](provisioning.md) and others do not. It is on
`mtd4`, a separate partition from the rootfs. **Not yet read; recorded as the next thing to look
at.**

## Credentials

`/etc/shadow` contains a **root password hash** (MD5-crypt). Per this repo's convention it is
**not recorded here** — see [security.md](security.md). It is worth knowing it exists, because a
cracked or reused hash would give a shell without the card.

## Why this matters more than a shell usually would

Everything this project spent a day failing to reach over open protocols is *present on the
device*:

* **the illuminators, the IR-cut filter, the speaker and motion detection** all run as named
  threads ([`:6670` task table](vendor-api.md)) and none is exposed over ONVIF;
* **the second lens** of the dual-lens unit is invisible to ONVIF and RTSP;
* **the burnt-in `1970` timestamp** cannot be fixed from any network interface.

**A root shell reaches all of it directly** — and, unlike the vendor P2P channel, it does not
depend on a protocol anyone has to reverse-engineer.

⚠️ 🔴 **The one string not to "fix" from a root shell: the codec.** These cameras report `H264`
while streaming H.265, and Home Assistant only builds camera entities for H264 profiles — **the
lie is the only reason the integration works.** It cannot currently be corrected over the network
because `SetVideoEncoderConfiguration` does not exist. **A shell removes that protection.** See
[the README](../README.md#-and-it-already-applies-here-the-codec-lie-is-load-bearing).
