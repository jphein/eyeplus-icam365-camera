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

### 🔴 ANSWERED: it is not durable. Confirmed.

**One clean power cycle. The camera came back in AP mode**, reporting *"camera startup wait for
user config"*. [M]

That is decisive, and it closes the question three ways:

* **The benign explanation is dead.** A multi-flip factory reset cannot explain a deliberate
  single off/on.
* **Cloud *contact* is not enough.** `icam365-02` had exchanged `HelloAck`s with the vendor during
  the WAN window and **still forgot.** A completed *bind* — which
  [never happened](#-the-wan-window-was-run-the-cloud-bind-does-not-complete) — is evidently the
  thing that matters, not reaching the server.
* **Both branches of the flash-commit hypothesis now have evidence.** `icam365-02`: locally
  paired, non-durable. `icam365-01`: app-paired **with cloud** in 2024, surviving power cuts
  since.

### The operational conclusion

> 🔴 **Every one of these cameras needs one supervised, internet-connected app pairing before it
> can live on an isolated VLAN.**
>
> Local `/setwifi` **works**, and it is genuinely useful — but it yields a camera that **forgets
> its WiFi on every power cut**. Fine on a bench. **Unusable on a pole.**

The `icam365-01` half stays **[I] inferred**: nobody is going to power-cycle the production
camera to confirm it, and a negative result would mean having broken it to find out.

> ✅ **This retroactively validates the choice to put `icam365-01` outside.** Had the lab unit
> gone up by the cars instead, the first power blip would have meant a ladder — and the fault
> would have looked like dead hardware rather than a known limitation.

#### One flip, two answers — and the second is still available

A second finding makes a *future* reboot more valuable: **the camera never re-resolves DNS.** It
is still firing at IP addresses cached during the WAN window, so a DNS override cannot redirect a
client that is not querying. [M]

A fake PPPP masterserver and a DNS override are built. Because the camera **must reboot to
re-resolve**, arming them before the next power cycle would test whether a synthesised login-ack
changes its behaviour — the impersonation question — at no extra cost.

**That opportunity was not taken on this flip.** Arm the masterserver and the override *before*
the next one, or it is wasted again.

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
