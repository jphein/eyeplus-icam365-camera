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

### 🔑 It is not one vendor's quirk — the hook fires across firmware families

Run on a **second, unrelated** camera: same card, same hook, same result. **[M]**

| | `icam365-wall` (EYEPLUS) | `cloudcam-01` (a different product) |
|---|---|---|
| ONVIF identity | `EYEPLUS` / `EYEPLUS_DEV` / fw `57.0.2.0` | `ONVIF` / `cloudCam` / fw `47.0.2.0` |
| **Hook that fired** | **`/mnt/debug_cmd.sh`** | **`/mnt/debug_cmd.sh`** |
| Kernel | **Linux 3.18.31**, built 2024-02-28 | **Linux 4.9.37**, built 2023-11-14 |
| CPU | ARMv7 Cortex-A7 (`0xc07`) | same |
| Flash | 6 partitions, ~8 MB NOR | **5 partitions**, ~8 MB NOR |
| Partition names | `boot bootenv linux rootfs home bak` | `uboot bootargs kernel rootfs home` |
| telnetd started | ✅ `:2323` | ✅ `:2323` |
| `whoami` | **`uid=0(root)`** | **[?] empty — see below** |

**Different kernels, different build hosts, different partition tables — the same boot hook.**
**[I]** that makes it an **ODM-level convention across this white-label stack**, not a single
vendor's mistake, so it is reasonable to *expect* on units not yet bought — and cheap to test,
since one card and one power cycle settles it.

> ⚠️ **Privilege on `cloudcam-01` is NOT measured.** Its `whoami` line came back **empty** where
> the other unit printed `uid=0(root)`. The script plainly ran, wrote to the card, and read
> root-owned paths — **[I]** a missing `id` applet in a thinner BusyBox is the likely explanation.
> **Do not carry "root" across from the other row**; a table like this invites exactly that.

✅ **A side finding the ONVIF surface flatly denies:** `cloudcam-01` **recorded video to the card**
(`2024-10-03/09/…M.mp4`, stamped with its own stale clock). Every ONVIF storage and recording
operation on these cameras returns `ActionNotSupported`. **The capability is there; the protocol
denies it.** Same shape as everything else in this repo.

## Getting an interactive shell

The payload starts **`busybox telnetd` on port 2323** — deliberately not 23, so it cannot be
confused with a vendor service. **It skips login entirely** (`telnetd -l /bin/sh`), so no
credential is needed and **nothing on the device is modified** — no bind-mounts, no `/etc/passwd`
edits. Pull the card, power-cycle, and the unit is bit-for-bit stock.

⚠️ **Removing the card does not stop a running `telnetd`.** Only a power cycle does.

## 🔴 SSH: four stacked defects, all producing the same symptom

**`dropbear -R` can never work on these cameras**, and it fails in the way this repo keeps
meeting: **the daemon starts, the port listens, `ps` shows it alive, and every login dies before
auth.** Every cheap health check passes. **[M] 2026-08-06**

```
Couldn't create new file /etc/dropbear/dropbear_ecdsa_host_key.tmp2572: No such file or directory
Exit before auth: Couldn't read or generate hostkey /etc/dropbear/dropbear_ecdsa_host_key
```

`-R` means *generate host keys as required* — and it defers that work to **connection time**,
writing to a **compiled-in `/etc/dropbear/`** that does not exist on a **read-only squashfs**
(`/dev/root / squashfs ro`). Nothing is wrong at startup, so nothing looks wrong until a human
tries to log in.

> ⚠️ **The card script recorded `-R` as "Measured".** What was measured was `netstat` showing
> `:2222 LISTEN`. **A listening port is not a working service** — this is the accepted-but-inert
> pattern from [method.md](method.md) applied to our own tooling rather than the vendor's.

**Four defects were stacked, each hidden behind the next, all reporting `Permission denied`:**

| # | defect | why it isn't guessable |
|---|---|---|
| 1 | `-R` cannot write its key (read-only rootfs) | fails at connection time, not startup |
| 2 | **`dropbearkey` is not in this multibinary** | its own usage text says `dropbearmulti <command>` — but the list is only `dropbear`, `dbclient`/`ssh`, `scp` |
| 3 | **`authorized_keys` is found via `getpwnam()`, not `$HOME`** | `HOME=/bak/root` is decorative; `/etc/passwd` says `/root` |
| 4 | **Dropbear 2016.74 predates ed25519 *user* keys** | an `ssh-ed25519` entry is silently unusable |

**Only reading the daemon's own stderr separated them** — `dropbear -F -E -p <spare port>`, then
connect and read the log. Guessing was hopeless: four causes, one message.

> 🔑 **On #2 — reading a tool's documentation is not running it.** The usage text was taken as
> proof the subcommand existed; it does not. This is [`which` lying about BusyBox
> applets](method.md) one layer up, and **worse, because usage text feels authoritative.**

### The recipe that works

1. **Generate host keys off-device** (`dropbearkey` on a workstation — `apt install dropbear-bin`).
   The format is architecture-independent.
2. **Carry them in and verify by checksum.** With no `base64`/`wget` on some units, octal-escaped
   `printf` in ≤128-byte chunks works; **compare `md5sum` at both ends** — see the pty corruption
   hazards in [method.md](method.md).
3. **Use `-r`, never `-R`**, pointing at the keys on writable flash:
   `dropbear -r /bak/etc/dropbear/dropbear_ecdsa_host_key -r …_rsa_host_key -p 2222`
   ✅ `-r` only **reads**, so `/bak` may stay mounted **ro** — which is why this survives boot.
4. **Bind-mount the escrow onto the passwd home**: `mount -o bind /bak/root /root`.
   **This must be in the boot hook**, before dropbear starts, or SSH breaks on the next reboot.
5. **Put an `ssh-rsa` key in `authorized_keys`** and connect with
   `-o PubkeyAcceptedAlgorithms=+ssh-rsa` — modern OpenSSH disables SHA-1 RSA signatures by
   default, which this 2016 server is the only thing that speaks.

**Verified by effect on a live unit: `SSH_LOGIN_OK`, `uid=0(root)`, and two `ssh-keyscan`s
returning identical fingerprints** — a stable host identity, where `-R` would have produced a
fresh key per connection even had it worked.

🔴 **`scripts/card/debug_cmd.sh` still ships the `-R` form and needs this fix**, or SSH is dead on
every unit the card touches. Telnet on `:2323` is unaffected and remains the reliable path.

⚠️ **The camera must be on the network to reach it.** A unit that has lost its WiFi config comes
back in AP mode with no LAN address, so **re-provision first, then insert the card and boot.**

## What the platform actually is

Every one of these was an open question before the card, and several had been guessed at wrongly.

| | |
|---|---|
| **SoC** | 🔑 **`Augentix HC1703_1723_1753_1783s family`** — from `/proc/cpuinfo` `Hardware:` |
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

### 🔑 The SoC is Augentix — and every external guess was wrong

```
Hardware : Augentix HC1703_1723_1753_1783s family
```

**[M]**, read from `/proc/cpuinfo` on a live shell. Corroborated on the same box by a vendor
binary named **`rsyscall.hc1703`**.

**This closes a question that weeks of external research could not.** Prior art on the
`TAS-Tech`/`Ginatex` firmware strings pointed at a **Goke GK7102** lineage, and the candidate list
that had been reasoned toward was Goke / HiSilicon / SigmaStar / Ingenic. **It is none of them.**
Augentix is a Taiwanese ISP-SoC vendor that never appeared in any of the research.

> **The transferable point is about method, not silicon.** The platform was inferred for a long
> time from *vendor strings in HTTP headers* — the most visible evidence available, and the most
> derivative. **One `cat` of `/proc/cpuinfo` settled it.** Where an identification rests on
> fingerprints of fingerprints, the cheap direct read is worth more than any amount of
> triangulation — and here it was one boot away the whole time.

⚠️ **Consequence for tooling:** anything written for Goke/HiSilicon boards — GPIO numbers, flash
recipes, published `gio` values — **does not transfer.** Enumerate on the device.

### Vendor tooling on the box

Alongside BusyBox, the rootfs carries the vendor's own binaries. **[M]**

| binary | what it is |
|---|---|
| **`gio`** | GPIO tool — opens `/dev/gio` (`/dev/gio open suc`). **[I]** the documented route to **IR-cut and IR LED** control on this family. ⚠️ **Segfaults with no arguments and with `-g`** — it wants a specific form, and published GPIO numbers are board-specific. **Enumerate before actuating.** |
| **`ptz_test`** | vendor PTZ utility — of interest given there is *no* position feedback over any network protocol |
| **`debugTool`** | unexamined; the name is self-recommending |
| 🔴 **`sdc_tool`** | **the SD-card firmware flasher.** This is the binary behind the `firmware.bin` brick hazard at the top of this page |
| `httpclt`, `tees` | vendor HTTP client / tee |
| `wpa_supplicant`, `wpa_cli`, `hostapd` | stock WiFi stack — consistent with the credentials being a plain `wpa_supplicant.conf` |

⚠️ **Applet availability differs between units, which matters when writing scripts for the fleet.**
This unit has `hexdump`, `hd`, `nc` and `id`; the wall unit had none of `strings`, `od`,
`hexdump`, `base64` or `nc`, and lacked `basename`. **Probe, do not assume** — a script that works
on one camera can silently do nothing on another.

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
