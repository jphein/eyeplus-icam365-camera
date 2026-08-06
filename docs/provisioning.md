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

## ⚠️ Provisioning does not reliably survive a power cycle

**This is the blocker for any outdoor deployment, and it is unresolved.**

A camera that had been provisioned and was working came back **in AP mode** after a power
cycle — broadcasting its `AICAM_*` SSID again, holding no lease, with neither address
answering. The WiFi credentials were simply gone. Re-provisioning worked and it rejoined
normally. [M]

**Every power cut therefore risks re-orphaning the camera, and re-pairing requires physical
proximity to its access point.** For a camera up by the cars, that means a ladder after every
outage.

### Two candidate causes, neither settled

* **[I]** The camera may only commit credentials to flash once the **cloud binding** completes —
  which can never happen with the camera VLAN denied WAN access. If so, this is a permanent
  consequence of the local-only posture rather than a fault.
* **[I]** The power switch may have been flipped more than once, tripping a **3×-power-cycle
  factory reset**.

**Do not treat either as established.** They have very different implications: the first makes
outdoor deployment structurally fragile, the second makes it a non-issue.

### The decisive test is cheap

**One single clean power cycle, nothing else, and see whether it returns on the WiFi network or
in AP mode.**

Worth doing **before anything is mounted outdoors**, because the answer determines whether these
cameras are suitable for a location that is awkward to reach.

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
