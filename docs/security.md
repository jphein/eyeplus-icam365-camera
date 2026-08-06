# Security

> 🔴 **These cameras have no authentication worth the name. VLAN isolation is the only control
> protecting them, and it is load-bearing.**

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
> note and is **not independently verified for these cameras**. They are Tange/ThroughTek
> devices; the other P2P camera in this project is a different vendor and stack. The two should
> not be assumed to share a protocol just because both use UDP 32100 — that conflation has
> already cost time once. What *is* measured: these cameras answer a P2P LAN-search probe
> locally and report a `TANGE-…` UID. See [ai-and-events.md](ai-and-events.md#the-p2p-channel--a-local-session-works-with-the-cloud-firewalled).

## See also

* [onvif.md](onvif.md) — the full ONVIF surface, including what it lies about
* [vendor-api.md](vendor-api.md) — the unauthenticated `:8001` endpoints
* [provisioning.md](provisioning.md) — `:20202`, which stays open after pairing
