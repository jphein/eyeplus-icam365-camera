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

## 🔑 SOLVED — the firmware DELETES the WiFi config on purpose

**These cameras are not failing to save their WiFi. `/p2pcam/p2pcam` calls `remove()` on eleven
`/home` paths, including `wpa_supplicant.conf` and *both copies* of `devParam.dat` and
`extraParam.dat`. It wipes the primary store and both backups.** **[M] 2026-08-06**, found by
disassembling the vendor binary and confirmed against the flash.

> ### The single fact that explains two days of confusion
>
> **The wipe runs while the camera is up, with `wpa_supplicant` still holding the credentials in
> RAM. The unit stays online and healthy afterwards.** [M]
>
> **So the power cycle never caused the failure — it only revealed it.** The fault is *latent*,
> not flaky. That is why it was never reproducible, why "this unit survived a reboot today" kept
> seeming to contradict the rule, and why it proves nothing about tomorrow.

### The proof: the flash journal caught it in the act

Parsed at the jffs2 **dirent** level from a full flash dump (metadata only — no file contents
read, no credential touched). jffs2 writes `ino=0` on unlink, so its log is an audit trail: [M]

* **Six creations in one unbroken version run (107–112); six deletions in another (119–124)** —
  two atomic bursts.
* **The deletion order matches the `remove()` call order in the binary exactly**, and the five
  paths that leave *no* record are precisely the ones that did not exist. Consistent including
  the absences.
* **Nothing written afterwards** in that image.

> ⚠️ **RETRACTED to unproven — this page previously said "that unit was running with no WiFi
> config on flash at all."** That was inference stated as measurement, and it was published here.
> `DUMPFLASH` runs from `debug_cmd.sh` at `start.sh:316`, **before `p2pcam` starts at `:593`** — so
> a dump always shows `/home` as the *previous* session left it. The image cannot distinguish
> *"wiped and still serving frames"* from *"wiped, caught early in the next boot."*
>
> **The latency claim itself still stands** — it was demonstrated directly on two units by moving
> the files off live flash and watching the cameras stay online. **But that dump was never its
> proof.** The distinction matters: one is a measurement, the other was a story that fitted it.

Independently confirmed by mounting the image read-only through `mtdram` and letting the kernel
replay the journal. **This rules out every benign explanation**: not garbage collection, not an
uncommitted write buffer, not free-space exhaustion, not a missing `sync`.

### ❌ RETRACTED: "every unit needs one supervised, internet-connected app pairing"

**The rule this project was organised around is not supported.** It rested on a
[flash-commit hypothesis](#the-leading-hypothesis-and-why-it-matters-so-much) — that credentials
are only written once a cloud bind completes. **That is disproved: they are written to flash
immediately and correctly, and deleted later.** [M]

**There are at least seven call sites into the wipe. Only one involves an account.** Two are
counter-driven (`counter > 5`) and need **neither a human nor the cloud**, and `doDevRebootReset`
wipes on *both* branches — its argument does not gate it. **A cloud binding cannot protect against
the six non-account paths.**

⚠️ This also **defuses the firmware confound** that blocked the durability question all day: the
difference between two units may simply be **whether the wipe has fired yet**.

### ❌ RETRACTED: `no_cfg_reboot_time` is a red herring

It looked like the mechanism — a counter, two bytes, sitting beside the WiFi config, on a device
documented to revert to AP mode. **It is written only by `/bak/factory_tool.sh`** and counts boots
where the SD card carried no `*-hwcfg.ini`; after five it deletes `/home/hwcfg_bak.ini`. It is one
of four identical counters. **`cfg` means `hwcfg.ini`, not "configuration".** [M]

> **The name matched the hypothesis and the code did not.** Same shape as
> [a matching symptom is not a confirmed mechanism](../README.md#the-sibling-rule-learned-on-the-anyka-camera-a-broken-thing-may-be-load-bearing).

### 🔴 ROLLOUT BLOCKER: a camera can silently ignore the card entirely

`start.sh:275`: **[M]**

```sh
if [ -f /home/SD_CHECK -o -f /home/SD_NOMOUNT ]; then
        ...                    # the SD card is NEVER mounted
else
        mount ... /mnt         # only here does /mnt/debug_cmd.sh run
fi
```

**Both flags are written by `p2pcam`, live in `/home`, and are *not* on the wipe list — so they
persist.** A unit holding either **never mounts the card, never runs the hook, and reports
nothing.** The card simply appears to do nothing, with no error anywhere.

> 🔴 **This is a chicken-and-egg trap aimed precisely at the units that need help most.** A camera
> that has lost its config *and* holds `SD_NOMOUNT` cannot be rescued by the card at all. The fix
> has to arrive over the network instead (`:2323` / `:2222`) — which is how both bench units were
> done. `custom_pre_init.sh` runs at `:67`, *before* that branch, so an **already-installed** hook
> can clear the flags; a hook that was never installed cannot.

**Check before trusting a card run:** `ls /home/SD_CHECK /home/SD_NOMOUNT`. Neither bench unit
currently holds either. **[M]**

### ❓ UNTESTED, and it should be tested before fourteen units: does booting from the card provoke the reset?

The wall unit's dirent log shows **`SD_NOMOUNT` created and deleted three times (v113–118)
immediately before the six-file wipe (v119–124)**. **[I] That is a correlation in a log and
nothing more** — but note what it would mean if causal:

> **We have been booting these cameras from the fleet card all day.** If SD-card booting itself
> provokes the factory reset, the tool built to *diagnose* the wipe would be *causing* it — and
> the evidence would look exactly like what we have.

**It is cheap to instrument now and expensive to discover after fourteen units.** The test is a
control: boot a unit with the card, and an identical unit without, and compare the `/home` dirent
log across both.

### ✅ The fix — survive the wipe rather than prevent it

The wipe removes eleven **specific paths**. It never does `rm -rf /home`, and **never touches
`/bak`**. And the vendor's own boot script calls a hook that does not exist:

```
start.sh:65   /bak/custom_init.sh        <- exists. 🔴 DO NOT TOUCH: drives the WiFi power GPIO
start.sh:67   /bak/custom_pre_init.sh    <- DOES NOT EXIST on stock units. A free hook.
```

`custom_pre_init.sh` runs **before the WiFi driver loads** and long before `p2pcam` starts. A
script there keeps a copy of the six files under a name the wipe does not know
(`/home/.wifikeep`) and restores them at boot. **No vendor file is modified.**

🔴 **Note which hook was NOT used.** `custom_init.sh` is the obvious place and it drives the
**WiFi power GPIO** — editing it is this repo's signature hazard sitting directly beside the
correct answer.

**Verified on live flash, not simulated:** [M] all six files moved away on a real `/home` — the
camera **stayed online**, demonstrating the finding itself — then restored **6/6 byte-identical**,
modes preserved, idempotent on a second run. Free space went *up* (`132 KB` → `156 KB`), jffs2
having compacted the mostly-zero blobs.

⚠️ **The backup is per-unit, not fleet-wide** — `devParam.dat` carries device identity.

❓ **One link is inference, not measurement:** whether `p2pcam` accepts a restored `devParam.dat`
across a real reboot. The bytes are provably identical before `p2pcam` starts and its checksum is
in-file, so the risk is low — but **one reboot would settle it.**

🔑 **Fleet consequence:** the same restore in the SD-card payload lets a card **self-heal a camera
that has already lost its config** — recovering an orphaned unit at boot, with no ladder and no
AP-mode re-provisioning.

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
  paired, non-durable. `icam365-01`: durable across a confirmed mains cut.
  ⚠️ **This bullet used to read "`icam365-01`: app-paired with cloud in 2024" — that pairing
  attribution is [retracted to unproven](../README.md#-retracted-2026-08-06-icam365-01-was-app-paired-in-2024-with-cloud).**
  The *durability* is measured; the *reason* is not, and the firmware version is an untested
  alternative explanation.

### The operational conclusion

> 🔴 **Every one of these cameras needs one supervised, internet-connected app pairing before it
> can live on an isolated VLAN.**
>
> Local `/setwifi` **works**, and it is genuinely useful — but it yields a camera that **forgets
> its WiFi on every power cut**. Fine on a bench. **Unusable on a pole.**

The `icam365-01` half was **[I] inferred** for exactly one day, on the grounds that nobody would
power-cycle the production camera to confirm it and a negative result would mean having broken it
to find out. **It is no longer inferred — see immediately below.**

### ✅ CONFIRMED [M]: a camera *does* survive a power cycle

**The experiment this project refused to run ran itself, 2026-08-06.** `icam365-01` — outdoors,
production — went off-network unexpectedly and JP re-plugged it. The event was instrumented
entirely from the infrastructure side, at zero risk to the camera, because the risky part had
already happened.

> ⚠️ **This section previously said "app-paired with cloud in 2024" here.** That attribution is
> **[retracted to unproven](../README.md#-retracted-2026-08-06-icam365-01-was-app-paired-in-2024-with-cloud)**
> — HA's own device registry dates the 2024 record to the *other* identifier. The **outcome**
> below is measured and unaffected; only the explanation for it was unsourced.

| time | observation | source |
|---|---|---|
| 14:31:17 | `AP-STA-DISCONNECTED` … `disassociated due to inactivity` — it went **silent**, no clean deauth | AP `logread` |
| 14:31–15:12 | absent from **every AP on the property**; no ARP entry; `:8001` timing out | assoclist sweep, gateway `ip neigh` |
| 15:12:01 | `authenticated` → `associated` → `EAPOL-4WAY-HS-COMPLETED` on the **same SSID**, unattended | AP `logread` |
| 15:12:xx | **fresh DHCP lease issued** (the previous lease had been issued ~230 min earlier) | gateway leases |
| 15:12:45 | `/snapshot` → `200`, 41 KB, 73 ms | measured |

Evidence was copied out of the AP's rotating `logread` buffer, which is volatile.

**Measured [M]:** the camera left the network for ~41 minutes, returned on the **same SSID by
itself**, with a fresh 802.11 authentication *and* a fresh DHCP lease — a cold network stack, not
a re-association — and resumed serving frames. **It did not come back in AP mode. Its WiFi
configuration survived.**

**Also measured [M]: it was a genuine mains power cut.** JP confirmed the **outlet was off** and
the camera was unpowered for the whole ~41-minute gap. This is not "it rebooted somehow" — it is
mains removed and restored, with nothing else touching the device.

### 🔬 That makes it a controlled comparison, not just an anecdote

The lab unit's decisive test was *"one single clean off/on, nothing else"*. **This was the same
test, on the other unit, with the opposite result** — and the two units differ in exactly one
known respect:

| | `icam365-01` | `icam365-02` |
|---|---|---|
| the test | mains off ~41 min, then on [M] | one clean off/on [M] |
| **came back as** | **station mode, same SSID, unattended** [M] | **AP mode, config gone** [M] |
| paired how | 2024 phone app, **with cloud access** | locally, `/setwifi`, `userid:"0"`, **never bound** |
| firmware | `57.0.8.0` | `57.0.2.0` |

> ⚠️ **Two variables differ, not one — and the second is easy to miss.** The pairing method is the
> hypothesis, but **the firmware versions are also different**, and nothing yet rules out a
> persistence bug fixed between `57.0.2.0` and `57.0.8.0`. A fleet of 12 makes that separable:
> pair two units *identically* and differ only in firmware, or flash-match two units and differ
> only in pairing. **Until then the cause is still [I], however satisfying the story is.**

**Still inferred [I]**, and not to be quietly promoted:

* **That the 2024 cloud pairing is the cause.** This is now a strong controlled contrast rather
  than a single observation — but it confirms an **effect**, not a mechanism, and the firmware
  confound above is live. A completed bind remains the leading explanation and is still untested.

> ⚠️ **Do not read this as "the durability problem is solved."** It confirms only that *this*
> app-paired unit tolerated *this* outage. The locally-provisioned failure is unchanged and still
> [confirmed on a single clean flip](#-answered-it-is-not-durable-confirmed). The operational rule
> — *pair once with internet, then isolate forever* — is **strengthened, not replaced**.

**The transferable lesson is about instrumentation, not cameras.** The decisive test had been
ruled out as too costly, so it was never designed — and it then happened by accident, where it
would have been lost had nobody been watching the right log. **An experiment you have declined to
run can still run itself. Decide in advance what would count as its result, and keep a cheap
instrument pointed at it** — here an AP association log and a DHCP lease timestamp, neither of
which touches the device at all.

> ✅ **This retroactively validates the choice to put `icam365-01` outside.** Had the lab unit
> gone up by the cars instead, the first power blip would have meant a ladder — and the fault
> would have looked like dead hardware rather than a known limitation.

### It gets worse than "loses config on a power cut" — and still does not threaten the outdoor unit

**Measured: the lab camera reverted to AP mode twice with no power event at all**, roughly two
minutes after rejoining, with nothing touching it in between. So the failure is not necessarily
tied to power loss; it can be time- or failure-triggered.

> ✅ **Read this next part before concluding the outdoor plan is unsafe.**
>
> **`icam365-01` has never done this.** It has sat on this same cloud-blocked VLAN all day, and
> for weeks before, and has never dropped to AP mode. The measured difference between the two
> units is exactly the one that matters: `icam365-01` completed a **real app pairing with cloud
> access**; `icam365-02` was provisioned locally with `userid:"0"` and has **never completed a
> bind**.
>
> **[I], and consistent with every observation across both units:** a camera holding a completed
> bind is stable indefinitely with the cloud firewalled, while one that has never bound keeps
> retrying and eventually gives up back to AP.
>
> So the operational conclusion **sharpens rather than collapses**: *pair once with internet,
> then isolate forever.*

Three candidate causes for the lab unit's reverts remain open, and **none has been chosen**:
a stray byte written to a vendor port corrupting stored config; the camera giving up on a bind
it can never complete; and — self-inflicted — a stale DNS override that was feeding it a dead
masterserver address every six seconds while all of this was observed. The third has now been
removed, which makes any future revert a materially cleaner experiment than the ones already run.

#### ❌ RETRACTED: "the camera never re-resolves DNS"

This section used to read *"the camera never re-resolves DNS … a DNS override cannot redirect a
client that is not querying"*, and concluded that impersonation needed a reboot to be armed
against, or a DNAT fallback.

**Measured on a freshly-provisioned camera: it re-resolves `p2p-002` and `p2p-003` every
~6 seconds** — 36 queries each in a 222-second capture. [M]

The original observation was of a camera that had been running for hours. **The retraction is
about generality, not accuracy:** a settled camera stops asking; a fresh one asks constantly. So
**local cloud impersonation failed for a timing reason, not a structural one** — the fake
masterserver simply has to be listening while the camera is fresh. The DNAT fallback is not
needed.

#### What the camera does continuously, while apparently healthy [M]

| observation | count / cadence |
|---|---|
| PPPP `MSG_HELLO` (`f1000000`) → cloud UDP 32100 | **~5 per second, non-stop** |
| ICMP type 3 code 3 (port unreachable) from the router | continuous |
| `0xF1F9` device login (84-byte body, differing each time) | every **~60 s** |
| **inbound** from the cloud | **zero — nothing is ever answered** |
| a previously unrecorded hostname, `ep.tange365.com` | resolved once, to real public IPs |

> ⚠️ **This breaks an obvious-looking diagnostic.** "Did a failed cloud attempt precede the
> fault?" cannot discriminate anything here — a failed attempt precedes *every* event, five
> times a second. Only a **change** in the pattern is evidence: the login cadence breaking, a
> new message type, or the retry loop stopping.

#### ⚠️ Clean up interception overrides by *resolving the name*, not by grepping

A DNS override pointing the vendor's masterserver names at a local address was recorded as
"reverted and verified". **It was still live**, on all three names, pointing at an address where
nothing was listening — so every cloud lookup the camera made for an entire day was answered
with a dead host. It was found in a packet capture, not by re-reading the config. [M]

**Verify a revert behaviourally: resolve the name and look at the answer.** A grep for what you
believe you deleted will agree with you.

## 🔴 `/setwifi` cannot be called without the binding fields

Found while trying to change a camera's SSID **without** disturbing its cloud binding. Four
payload variants, measured against the lab camera: [M]

| payload | result |
|---|---|
| `{ssid, key}` | **400 Bad Request** (×3, consistent) |
| `{ssid, key, userid}` | **400 Bad Request** |
| `{ssid, key, bind_token}` | **400 Bad Request** |
| `{ssid, key, userid, bind_token}` | **200 OK** |

**Both `userid` and `bind_token` are mandatory.** There is no minimal form.

> ⚠️ **So any SSID change necessarily sends `userid:"0"` — "no account owns this device" — plus a
> freshly minted `bind_token`, over whatever binding the camera currently holds.**
>
> On a camera whose durability depends on a completed app pairing, that is the single most
> plausible way to destroy the property you are relying on. And **it is not rehearsable**: a
> locally-provisioned lab unit has no binding to lose, so testing there proves nothing about a
> properly-paired one.

**There is no alternative route.** ONVIF `GetDot11Capabilities` and `GetDot11Status` are both
`ter:ActionNotSupported`, so the ONVIF wireless-configuration path does not exist on this
firmware. `:20202/setwifi` is the only mechanism. [M]

## ⚠️ `/setwifi` means different things in AP mode and station mode

The same request, accepted with the same `200 OK`, does two entirely different things:

| mode | behaviour |
|---|---|
| **AP mode** (camera unconfigured, serving its own SSID) | accepted, and the camera **reboots itself** into station mode. **This self-reboot is the only reason `/setwifi` appears to "just work".** |
| **station mode** (camera already on WiFi) | accepted with `200`, and **nothing observable happens** — no reboot, no re-association, still on the old network minutes later [M] |

**[I]** the setting is written to flash and read only at boot; the camera's flash cannot be read
to confirm.

> **Consequence: an already-networked camera cannot be moved to a different SSID without a
> reboot — and [the only reboot on this firmware is a power cycle](#-a-200-does-not-mean-it-worked).**

### Why that combination is disqualifying for a production camera

Stack the three findings and the operation becomes one you should not attempt at all:

1. the SSID change **must** send `userid:"0"` over the existing binding;
2. applying it **requires a power cycle**;
3. **the power cycle is also the only test of whether the binding survived.**

> **The test and the risk are the same action, with no way to back out.** And the failure is
> delayed and silent — a camera that looks healthy for weeks and then reverts to AP mode on some
> later power cut, presenting as dead hardware, from a ladder.

**This is a different situation from "do it carefully".** Every other hazard on these cameras can
be rehearsed on an expendable unit first. This one cannot, because the expendable unit lacks the
very thing being risked.

> ✅ **The safe way to move a bound camera to a new SSID is to re-pair it with the phone app on
> the new network** — a supervised, internet-connected pairing *replaces* the binding rather than
> blanking it. Otherwise, leave the old SSID broadcasting and leave the camera on it.

### 💣 A latent surprise worth knowing about

A camera that received a station-mode `/setwifi` for a different SSID is holding an **unapplied
network change**. It runs indefinitely on the old network — and then joins the *new* one the
next time it is power-cycled, possibly months later.

**If a camera comes back on an unexpected SSID after a power cut, check whether someone sent it a
`/setwifi` that never appeared to do anything.** It is not a fault.

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
