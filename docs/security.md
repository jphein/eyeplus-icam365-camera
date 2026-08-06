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
> locally and report a `TANGE-…` UID. See [ai-and-events.md](ai-and-events.md#the-p2p-channel).

## See also

* [onvif.md](onvif.md) — the full ONVIF surface, including what it lies about
* [vendor-api.md](vendor-api.md) — the unauthenticated `:8001` endpoints
* [provisioning.md](provisioning.md) — `:20202`, which stays open after pairing
