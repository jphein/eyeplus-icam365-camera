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

### ❌ The WAN window was run: the cloud bind does not complete

**A time-boxed, pairing-only WAN window was opened for the lab camera. The bind failed — and it
failed at the application layer, not the network.** [M]

```
camera -> p2p-00{1,2,3}.host.tange365.com:32100/udp
            f1 00 00 00                MSG_HELLO
cloud  -> camera
            f1 01 00 10 …              MSG_HELLO_ACK
            decodes to family=2, port=25192, ip=<the device's public IP>
            i.e. a STUN-style reflection of its own external address
camera -> cloud
            f1 f9 00 54 …              device login (0xF1F9), 84-byte body
cloud  -> camera
            *** nothing ***
```

Over roughly **7 minutes with WAN open**, inbound cloud traffic was **exactly two frames, both
`HelloAck`**. The device login went out repeatedly and was ignored every time.

> **The `HelloAck` is what makes this conclusive, and it is worth stating explicitly.** It proves
> packets crossed the firewall and NAT **in both directions**. Without that observation, "the
> bind didn't complete" would be indistinguishable from "the firewall rule didn't work" — and
> someone would eventually re-run the whole exercise to find out which.

**Most likely cause — [I], untested:** `userid:"0"`. No real account owns the device, so the
masterserver has nothing to bind it *to*. A genuine app pairing supplies a real account id, and
the local shortcut cannot.

### Three things that follow

1. **Capture-and-replay has nothing to replay.** The original hope was to record a successful
   bind and reproduce it locally, removing the need for internet access at pairing time. The
   capture contains the *request* and **no acceptance was ever observed**, so there is no
   exchange to replay. That plan cannot be built from this data.
2. **The local-impersonation idea is withdrawn** — recorded rather than deleted, because the
   reasoning matters. It was approved on the basis of "answer the hello and we're done".
   Answering the hello is easy; **synthesising a `DEV_LGN_ACK` nobody has ever observed, for a
   login we cannot parse, is a much larger problem.**
3. **The flash-commit hypothesis is untestable by this route**, because no successful bind can be
   produced to test it with.

> ⚠️ **A capture trap, found the hard way.** `pkill -f "ssh.*tcpdump"` **matched its own command
> line** and killed the invoking shell mid-command, silently losing a file append. It was caught
> only by checking the file afterwards rather than assuming the write had landed.
>
> Two general lessons: **`pkill -f` can match the process running it**, and **verify the artefact,
> not the exit code** — which is the same discipline this whole page is built on.

### ❓ Still open, and it is one clean test

**Does `icam365-02` survive a power cycle now?** It has had *real cloud contact* — the
`HelloAck` — even though the login was refused. That is more than it had before.

| If it… | Then |
|---|---|
| **survives** | Config persists after all. The earlier loss was something else — most plausibly a multi-flip factory reset — and **these cameras are cleared for outdoor use.** |
| **is lost again** | Non-durability is confirmed and the outdoor limitation is real. |

The answer decides whether this page's outdoor guidance is a **warning** or a **footnote**.

#### One flip now answers *two* questions

A second finding makes the same reboot more valuable: **the camera never re-resolves DNS.** It is
still firing at IP addresses cached during the WAN window, so a DNS override cannot redirect a
client that is not querying. [M]

A fake PPPP masterserver and a DNS override are built and can be armed beforehand — and **the
camera must reboot to re-resolve**, which is exactly what this test does anyway. So one power
cycle yields:

1. **Durability** — does it come back on WiFi, or in AP mode having forgotten?
2. **Impersonation** — on boot it re-resolves, lands on the fake masterserver, and we learn
   whether a synthesised login-ack changes its behaviour.

**Arm the masterserver and the override before flipping**, or the second answer is wasted and the
camera has to be rebooted again to get it.

> ⚠️ **Run it on `icam365-02` only. Never on `icam365-01`.** The production camera's 2024
> app-pairing history is the *only* evidence that app-paired units are durable. Power-cycling it
> would destroy that evidence and the production camera in the same move. See the
> [operational rules](../README.md#-operational-rules--icam365-01-is-production).

**Suggestive, but not a measurement:** `icam365-01` was paired in 2024 through the phone app
**with cloud access**, and has survived power cuts since. `icam365-02` was paired locally with no
cloud bind and lost its config on the first one. That natural experiment points the same way as
the hypothesis above — and it stays **inferred**, for the reason in the warning.

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
