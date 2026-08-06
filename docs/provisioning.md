# Local provisioning — no cloud account needed

These cameras can be joined to WiFi **without the vendor app and without a cloud account**,
which is the reason they are usable at all on a network that denies them WAN access.

The recipe was recovered by decompiling the iCam365 Android app (`com.tange365.icam365`, Tange
Inc.) — specifically `com.tange.module.add.configure.NetworkConfigureWithHTTP`, which turns out
to do nothing more exotic than a single JSON POST to the camera's own access point.

## The recipe

An unprovisioned camera broadcasts an open AP named `AICAM_<12 chars>` and serves an HTTP
endpoint on **port 20202** at its own address:

```
POST http://192.168.200.1:20202/setwifi
Content-Type: application/json

{"ssid":"my-iot-ssid","key":"<PSK>","userid":"0","bind_token":"and_<5 random lowercase>"}

→ HTTP/1.0 200 OK   "OK"
```

**`"userid":"0"` is accepted** — no cloud account is required for the WiFi step. [M]

The camera then reboots into station mode and picks up a DHCP lease. Give it a **DHCP
reservation** before or immediately after, because
[the ONVIF integration cannot be reconfigured in place](home-assistant.md#-the-onvif-integration-cannot-be-reconfigured-in-place)
and the address it is added on is effectively permanent.

`:20202` **stays open after pairing** — see [security.md](security.md).

## 🔴 Provisioning does not survive a power cycle

**This is the blocker for any outdoor deployment. It is confirmed, and its cause is still open.**

A camera that had been provisioned and was working came back **in AP mode** after a power
cycle — broadcasting its `AICAM_*` SSID again, holding no lease, with neither address answering.
The WiFi credentials were simply gone. Re-provisioning worked and it rejoined normally. [M]

**The decisive test has now been run: one single clean off/on, nothing else. It came back in AP
mode.** [M]

> That **eliminates** the benign explanation. An earlier candidate cause was that the switch had
> been flipped several times and tripped a **3×-power-cycle factory reset** — which would have
> made this a non-issue. It did not; one clean cycle is enough to lose the configuration.

**Every power cut therefore re-orphans the camera, and re-pairing requires physical proximity to
its access point.** For a camera up by the cars, that is a ladder after every outage.

### The leading hypothesis, and why it matters so much

**[I]** `/setwifi` may only commit credentials to flash once a **cloud bind** completes — which
can never happen while the camera VLAN is denied WAN access.

If that is right, the consequence is sharp:

> ⚠️ **The WAN deny and durable pairing would be mutually exclusive on this hardware.** Every
> unit would need one supervised, internet-connected pairing before it could live on an isolated
> VLAN — and a factory reset or flash wipe would mean doing it again.

That is a very different proposition from "configure it locally and forget it", and it applies to
any future unit of this family.

### Pending: a scoped WAN window to test it

**Authorised but not yet done.** The plan is a **time-boxed, pairing-only WAN window** for one
camera, to see whether a cloud-completed bind produces a configuration that survives a power
cycle.

The window is also to be used to **capture the entire cloud conversation**, so that the bind can
potentially be **replayed locally** in future — which would remove the need for internet access
at pairing time altogether.

**Documented as pending. Do not read the result into anything until it has been run.**

## ⚠️ A `200` does not mean it worked

`/setwifi` returned `200 OK` for a configuration that **did not persist**. Separately,
`/ptzctrl?act=99` — an invalid action code — also returns `200 OK`.

> **On this firmware family, a `200` means "request parsed", not "request honoured".** Verify the
> effect independently: check for a DHCP lease, fetch a frame, measure the image change. Never
> accept an HTTP status as evidence that something happened.

This is the same discipline that
[proved PTZ actually moves the camera](ptz.md#what-works) rather than merely accepting a 200.

## See also

* [security.md](security.md) — `:20202` is unauthenticated and stays open
* [home-assistant.md](home-assistant.md) — why the address you pair onto matters so much
