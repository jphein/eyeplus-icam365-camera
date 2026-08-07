# Security

> 🔴 **These cameras have no authentication worth the name. VLAN isolation is the only control
> protecting them, and it is load-bearing.**

## 🔴 One root hash for the entire fleet, and it cannot be changed

`/etc/shadow` is **mode 0775, 48 bytes, MD5-crypt (`$1$`), inside the read-only squashfs
rootfs.** **[M]**

Four properties compound:

* **Identical on every unit of this build** — it ships in the image, so it is not per-device.
* **World-readable** by any process on the camera.
* **Unchangeable in place** — `/etc` is read-only squashfs; `passwd` cannot persist a new hash.
* **MD5-crypt** — fast to attack and long obsolete.

> **Crack it once and you own every camera of this firmware, permanently.** There is no
> remediation short of replacing the image.

⚠️ **And there is already a login prompt on the serial port.** `inittab` runs
`::respawn:-/bin/login` on `/dev/console` = `ttyAS0`. So **UART access plus one cracked hash is
permanent fleet root** — no network involved.

What still holds it back: the read-only rootfs, no stock network login service, and the VLAN.
**This is a third independent reason the VLAN isolation is load-bearing rather than
precautionary.** The hash value is deliberately recorded nowhere.

## 🔴 Port 6670 is an unauthenticated debug console

**This outranks the credential disclosure in kind.** A leaked password exposes *data*; an open
diagnostic console exposes the *machine*. **Measured 2026-08-06. [M]**

No authentication, no challenge, nothing. Frame it as `[u32 BE total length][u32 BE command id]`
plus **at least four payload bytes** (a header-only message is answered with a TCP reset — which
is why an earlier sweep concluded the whole command range was dead):

| command | what it returns |
|---|---|
| `id=2` | the **full task table** — every thread name in the firmware |
| `id=3` | **semaphore dump, including live kernel addresses** |
| `id=5` | `redirectionOutput` — a console-output redirect |
| `id=6`–`14` | recognised; return empty pending arguments |

**Anything that can open a TCP connection to the camera VLAN can read the device's internal
state.** VLAN isolation remains the only control, exactly as for the credential leak, and this is
a second independent reason the isolation is load-bearing rather than belt-and-braces.

⚠️ **`id=5` is not to be actuated casually.** If an output redirect can be made to succeed it
plausibly yields an interactive console on a device otherwise documented as having no shell —
which is a capability, and a liability, on an unauthenticated port.

## Unauthenticated credential disclosure

**A single unauthenticated ONVIF request returns the administrator password in cleartext.**

```
POST /onvif/device_service      <tds:GetUsers/>

  <tt:Username>admin</tt:Username>
  <tt:Password>*****</tt:Password>          <- the actual password, in the clear
  <tt:UserLevel>Administrator</tt:UserLevel>
```

*(The password value is deliberately not reproduced in this repo. It is a short numeric vendor
default.)*

**Verified on both cameras**, which were checked separately rather than one being assumed from
the other — so this is a **firmware-family flaw, not a single bad unit**.

> ⚠️ **Changing the password does not help.** The same unauthenticated call returns whatever the
> current password is. There is no configuration that closes this.

## Everything else is unauthenticated too

| Surface | Auth |
|---|---|
| ONVIF, all operations | **none** |
| `:8001/snapshot` | **none** |
| `:8001/ptzctrl` | **none** |
| RTSP | **none** |
| `:20202/setwifi` | **none** (open even after pairing) |

So anyone who can reach the camera VLAN can **watch the camera, aim it, read its admin
credentials, and re-point its WiFi**. Aiming matters more than it sounds: there is
[no absolute positioning](ptz.md#no-position-feedback-no-presets-no-home), so an attacker who
moves a camera has permanently destroyed its framing until someone re-aims it by hand.

The only surface that *does* demand credentials is the ISAPI-shaped one on port 80, and it is
[unusable in both directions](onvif.md#the-isapi-surface-on-port-80-is-a-dead-end) — it 401s
everything and drops the connection on any `Authorization:` header.

## 🔴 A single stray byte to a vendor port takes a camera off the network

This one was found by causing it. **[M]**

> ## 🚫 Flat rule: `echo > /dev/tcp/host/port` is a port **write**, not a port scan
>
> It connects **and sends a newline**. It reads as read-only and is not.
>
> **Use instead:** `timeout 3 bash -c "exec 3<>/dev/tcp/host/port"` (connect, write nothing), or
> `nc -z`. One port at a time — a rapid six-port connect sweep alone was enough to make these
> cameras' HTTP servers stop answering for tens of seconds.
>
> This is a **rule, not a caution**, because two different operators ran the identical construct
> against these cameras on the same day — one of them also against a device this project already
> documents as being killed by a bare connect, noting *"I got lucky"* at the time without
> generalising it. Something that must be re-derived by each person who touches it is not a
> caution; it is an accident waiting for a turn.

```bash
# DO NOT DO THIS. `echo >` connects *and writes a newline*.
for p in 80 554 6670 8001 20202 3576; do echo > /dev/tcp/<camera>/$p; done
```

Three minutes after that ran against the lab camera, it stopped answering HTTP, then vanished
from the router's ARP table, then reappeared broadcasting its setup AP and asking to be
configured. **No power cycle, no reboot command, nothing else touched it.** It had been fully
healthy immediately before — snapshot 200, all six ports open, online in Home Assistant.

The suspect is **`:20202`**, the provisioning endpoint, which
[stays open after pairing](provisioning.md) and takes no authentication. A newline is not a
valid request to it.

> **What is measured and what is not.** Measured: the sequence above, and the camera dropping
> to AP mode without any power event. **Not** measured: which of the six ports did it. The
> camera afterwards entered a repeating join-then-revert cycle, which muddies attribution.
> **Three candidates remain open** — the stray byte corrupted stored config; the camera gives up
> on a cloud bind it can never complete; or a stale local DNS override was feeding it a dead
> masterserver address throughout. Do not write this up as "`:20202` de-provisions the camera"
> until someone probes that port alone.

**One free narrowing, from the same mistake made independently.** The other operator's probe hit
only ports **80, 554 and 8001**, on the *other* camera — **which did not revert.** So if a write
caused this, the suspect set is **{6670, 20202, 3576}**, and the unauthenticated provisioning
endpoint is the obvious candidate. Treat this as **suggestive, not clean**: the two units run
different firmware, and only one of them holds a completed cloud bind.

**Consequences that do not depend on which port it was:**

* An unauthenticated client on the camera VLAN can plausibly **take these cameras off the
  network** — not merely watch or aim them. For anything mounted outdoors, recovery means
  physical proximity to the camera's own AP.
* **Probing these cameras is an intervention, not an observation.** This is the third distinct
  way scanning has misled here: an `nmap -p-` sweep reported ports closed that were in use
  minutes earlier; an AP-mode sweep missed `:20202` entirely; and now a hand-rolled probe broke
  the device.
* To test a port, **connect without writing**: `timeout 3 bash -c "exec 3<>/dev/tcp/h/p"`, or
  `nc -z`. Even then, keep it to one port at a time — a rapid six-port connect sweep was enough
  to make the HTTP servers stop answering for tens of seconds.

## 🔴 A hardcoded credential shared across *silicon vendors* — not just this fleet

**`p2pcam` carries a hardcoded `UID,SECRET` literal at a fixed offset in the executable.** One
occurrence, inside the binary. **[M] 2026-08-06**

**Per this repo's convention, the value is not recorded here, and it has not been written to any
file, scratch note or message.** What follows is the mechanism only.

| | |
|---|---|
| shape | a PPCS UID, a comma, then a **6-character uppercase secret** |
| where | a compile-time string literal in the P2P daemon — **not** flash, **not** per-device |
| **scope** | 🔴 **byte-identical in a binary from a DIFFERENT silicon vendor** |

**The cross-vendor check is what makes this serious.** The same literal was found in `p2pcam`
(Augentix HC1703, manufacturer `AJ`, fw `57.0.2.0`) **and** in `ipc` (a different SoC,
manufacturer `RS`, fw `47.0.2.0`) — **compared by hash, never by value.** Two silicon vendors, two
manufacturers, two firmware majors, one literal.

> **That makes it an SDK-level credential, not a vendor's.** The exposure is a **class of
> white-label devices**, not twelve cameras on one network. **It cannot be fixed by changing a
> password on a camera**, and it cannot be fixed by any single vendor's update.

⚠️ **[M] vs [I], stated precisely because the gap matters:** that the literal is present and
identical in both binaries is **measured**. That it is an *authentication* key is **inferred** —
from its position beside the UID and the `UID,SECRET` format the P2P layer uses. **Nobody has
tested whether it authenticates anything.** Testing it would require the vendor cloud, which is
exactly the thing not to do unilaterally, so it stays inferred.

🔑 **Why this is worse than the LAN-only issues above.** Everything else on this page needs an
attacker already on the camera VLAN. **A PPCS UID plus its key reaches a camera through the vendor
cloud from anywhere on the internet** — if the inference holds. **The WAN default-deny is what
makes that unreachable here**, which promotes it from a policy preference to a control.

**Also relevant, and independently measured:** the *UID* is likewise a hardcoded literal, which is
why three cameras across two product families report a byte-identical UID. **Every identity field
these devices offer is a shared constant** — serial, `HwAddress`, `HardwareId`, and now the UID.
Identity comes from the DHCP reservation or `fleet.yaml`, full stop.

## What actually protects these

**The camera VLAN's isolation, and the default-deny to WAN.** That is the whole control set.

This reframes the network posture: the WAN deny was adopted to stop cloud chatter, but it is
also — along with VLAN segregation — the only thing standing between an unauthenticated
credential leak and anything that can route to it. **Keep both.** Do not put these cameras on a
flat network, a guest network, or anywhere untrusted clients live, and never port-forward them.

## Cloud posture

Before being blocked, the cameras held live P2P sessions on **UDP 32100** to cloud endpoints.
The camera VLAN is now default-deny to WAN, with DNS, DHCP and NTP to the router still
permitted. Local ONVIF and RTSP are unaffected; anything depending on the vendor cloud does not
work, which is the intended trade.

> **One caveat on the protocol name.** The "PPPP on UDP 32100" description came from an earlier
> note and is **not independently verified for these cameras**. ⚠️ **Vendor corrected 2026-08-06:
> the app links `libPPCS_API.so` (CS2 Network PPCS, the PPPP family), not TUTK/ThroughTek** — so
> any claim inherited from ThroughTek advisories does not apply by that route. They are Tange
> devices; the other P2P camera in this project is a different vendor and stack. The two should
> not be assumed to share a protocol just because both use UDP 32100 — that conflation has
> already cost time once. What *is* measured: these cameras answer a P2P LAN-search probe
> locally and report a `TANGE-…` UID. See [ai-and-events.md](ai-and-events.md#the-p2p-channel--a-local-session-works-with-the-cloud-firewalled).

## See also

* [method.md](method.md) — the safe way to probe a port, and other checks that lie
* [onvif.md](onvif.md) — the full ONVIF surface, including what it lies about
* [vendor-api.md](vendor-api.md) — the unauthenticated `:8001` endpoints
* [provisioning.md](provisioning.md) — `:20202`, which stays open after pairing
