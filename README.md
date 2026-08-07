# EYEPLUS / iCam365 ONVIF camera

Notes on cheap white-label ONVIF pan/tilt cameras, run locally in Home Assistant with their
cloud blocked. First set up **2024-09-22**; revived, reverse-engineered and documented across
**2026-08-05/06**.

"iCam365" is the name on the box and the app; the hardware identifies itself as **EYEPLUS**.

> 🔴 **These cameras leak their administrator password to anyone who asks, unauthenticated.**
> VLAN isolation is the only thing protecting them. **[Read security.md first.](docs/security.md)**

## The one thing to know

> ### On this firmware family a `200` means "request parsed", not "request honoured."
>
> **Nothing this device says about itself can be trusted without independent verification.**

Six independent confirmations, all measured:

| What it said | What was true |
|---|---|
| `POST /setwifi` → `200 OK` | Config **lost at the next power cycle** — the camera returned to AP mode |
| `POST /setwifi` → `200 OK` **to a camera already on WiFi** | **Nothing happened at all** — no reboot, no re-association, still on the old network minutes later. [The same request is honoured in AP mode and ignored in station mode.](docs/provisioning.md#-setwifi-means-different-things-in-ap-mode-and-station-mode) |
| `SystemReboot` → `Rebooting in 90 seconds` | **Never rebooted.** Served snapshots for 5.5 min; DHCP lease timestamp unchanged |
| `/ptzctrl?act=99` → `200 OK` | `99` is **not a valid action code** |
| ONVIF `GetProfiles` → `H264` | Both streams are **H.265** (`ffprobe`, and the SDP says `H265/90000`) |
| SDP → `framesize 1280-720` | `ffprobe` measures **1920×1080** |

Note the last two disagree *with each other* as well as with reality — ONVIF is right about the
resolution and wrong about the codec, the SDP the other way round. **There is no single field you
can trust by association with another.**

The rule extends past HTTP. At the P2P layer, **`DrwAck` means "frame accepted", not "command
understood"** — see [ai-and-events.md](docs/ai-and-events.md#the-p2p-channel--a-local-session-works-with-the-cloud-firewalled).

**Practically:** verify effects, never statuses. PTZ was only believed after measuring image
change against a noise floor; provisioning was only disbelieved after a power cycle.

### The same rule one level up: config is not behaviour

A firewall rule that *reads* correct is not a firewall rule that *behaves* correctly. When the
WAN window was closed again it was verified three ways — absent from `uci show firewall`, absent
from the live `nft list ruleset`, **and behaviourally: zero new inbound cloud packets in the
following 60 seconds.**

**The third check is the one that counts.** The first two are the device telling you about
itself, which is precisely what this page says not to trust.

It cuts the other way too, and that is what made the cloud result usable: a `HelloAck` arriving
from the vendor's server proved packets crossed the firewall **in both directions**, so
[the bind failure](docs/provisioning.md#-the-wan-window-was-run-the-cloud-bind-does-not-complete)
could be pinned to the application layer rather than the network. Without that, "no bind" and
"the rule didn't work" would have been indistinguishable.

### The sibling rule, learned on the Anyka camera: a broken thing may be load-bearing

> **A string that looks broken may be a dead path whose failure is load-bearing.**

Cheap camera firmware is full of code that fails silently — wrong sysfs paths, unhandled branches,
features half-ported from a sibling product. It reads as an obvious backlog of one-line fixes.

**On the [Anyka camera](../anyka3918-gc1084-camera/), one of those was fixed and it broke the
IR-cut filter.** The driver `stat()`s *two* sysfs node names to choose its mode: **neither**
present → stay disabled; **one** → write-and-hold; **both** → emit a 10 ms pulse for a latching
solenoid. Both names were wrong on that kernel, so the driver had been sitting in *disabled* since
the day the firmware shipped. Correcting **both** strings tipped it straight into *pulse* mode —
and that camera's filter is hold-to-engage, so every command released the pin and parked the image
in magenta.

**Fixing one of the two strings would have worked. Fixing both broke it.**

**Before repairing a wrong-looking path, establish what currently depends on it failing.**

Three corollaries, all of which apply directly to these cameras:

* **Thoroughness is not automatically safety.** "I found two instances of the bug and fixed both"
  is what a careful person does, and here it was the harmful choice. When a component's behaviour
  depends on *how many* things it can reach, fixing more of them is not a superset of fixing one.
* **"Never observed" is only evidence while the conditions that prevented it hold.** Behaviour
  nobody has seen from a disabled component is not evidence about the enabled one — and if you are
  about to enable it, your entire observational record expires at that moment.
* **A matching symptom is not a confirmed mechanism.** A prediction of this failure existed, the
  reported symptom matched it word for word, and **the predicted cause was still wrong** — two
  different mechanisms produced the same sentence. That match sent the investigation to the wrong
  binary for hours.

This is the same family as the rule above. *"200 means parsed, not honoured"* says do not trust a
device's account of what it did. This one says do not trust your own account of what it does not
do.

### 🔴 And it already applies here: the codec lie is load-bearing

**This is not an analogy. It is live on these cameras, and it is an operational risk.**

Home Assistant's ONVIF integration **only builds camera entities for profiles reporting
`Encoding == "H264"`.** These cameras stream **H.265** and
[report `H264` anyway](#the-one-thing-to-know).

> **If the firmware ever told the truth about its codec, HA would create no camera entities at
> all.** No cameras, no PTZ, nothing — and **nothing in any log would explain it.**

So the single most-cited example of these cameras lying about themselves is **the only reason the
integration works.** A vendor firmware update that *fixed* the codec string would silently empty
the dashboard.

**Note the direction of travel, because it is the mirror image of the Anyka case:**

| | Anyka | Here |
|---|---|---|
| What is wrong | a **broken path** | a **false self-report** |
| What depends on it | manual IR-cut control | the entire HA integration |
| What breaks it | fixing the path | fixing the string |

**Two different devices, one week, same shape.** A defect can be the load-bearing member — whether
the defect is something failing or something lying. **"This is obviously wrong" is a statement
about the code. It is not a statement about what happens if you correct it.**

⚠️ **Practical consequence:** if these cameras vanish from Home Assistant after a firmware update,
**check the ONVIF codec string before anything else.** The symptom is total and silent, and the
cause looks like an improvement.

## What works

| | |
|---|---|
| ✅ Video | RTSP, no auth — **H.265 only**, 1080p main / 640×360 sub + PCM A-law. ⚠️ **Use the substream**: 12.35 fps clean vs the mainstream's ~9.3 fps with dropped GOPs — [measured](#specifications) |
| ✅ Snapshots | [`:8001/snapshot`](docs/vendor-api.md#snapshot-is-the-most-useful-thing-on-these-cameras) — 640×360 JPEG, ~70 ms, no auth. **The best thing on these cameras.** |
| ✅ PTZ | ONVIF `ContinuousMove` and HA's `onvif.ptz`. No presets, but the mechanical limits are repeatable, so **a "go to a known corner" macro exists** — aim is recoverable, not irreversible |
| ✅ Local provisioning | [No cloud account needed](docs/provisioning.md) |
| ✅ **Day/night (IR-cut)** | **Vendor channel only** — `SET_DAYNIGHT`, [measured by the image going monochrome and back](#specifications). ONVIF cannot: the imaging operations do not exist |
| ✅ **Two-way audio** | **Vendor channel only** — `818` + G.711A on channel 5, [confirmed by ear at the device](#specifications). ONVIF has no backchannel at all |
| ✅ Availability monitoring | HA binary sensor + health sensor |
| ⚠️ WiFi persistence | **Depends entirely on how the unit was paired.** App-paired with cloud → [survives a power cycle, measured](docs/provisioning.md#-confirmed-m-a-camera-does-survive-a-power-cycle). Locally provisioned with `userid:"0"` → [loses its config on a single clean flip](docs/provisioning.md#-answered-it-is-not-durable-confirmed), measured. ⚠️ **The instruction that used to sit here — *"every camera needs one supervised app pairing before isolation"* — is withdrawn as premature.** It was derived from a cause that is [retracted to unproven](#-retracted-2026-08-06-icam365-01-was-app-paired-in-2024-with-cloud); the two units differ in **firmware** as well as pairing. If firmware is the real variable the correct instruction is *"run `57.0.8.0`"*, which is far cheaper. **Settle it on one spare before pairing twelve.** |
| ❌ Position feedback / presets / home | Not implemented. **No way to restore a framing in software.** |
| ❌ Motion events | [Structurally impossible over ONVIF](docs/ai-and-events.md) — though a **`tMotDet` thread runs on the device** |
| ❌ AI detection / auto-tracking | Exists in hardware, [reachable only over the vendor P2P channel](docs/ai-and-events.md#where-the-features-actually-live) |
| ❌ Reboot | ONVIF `SystemReboot` is a **no-op** — but a `tReboot` thread exists, so it is a wiring gap, not a missing capability |
| ✅ **Root shell** | 🔑 **[SD card, one boot, no soldering](docs/root-access.md)** — the firmware execs `/mnt/debug_cmd.sh` as **uid=0** at boot. Linux 3.18.31, ARMv7 Cortex-A7, BusyBox 1.33 |
| ❌ Authentication | On anything. See [security.md](docs/security.md) |

## The two cameras

| | `icam365-01` | `icam365-02` |
|---|---|---|
| Address | `192.168.1.21` | `192.168.1.23` (reservation) |
| MAC | `AA:BB:CC:DD:EE:01` | `AA:BB:CC:DD:EE:02` |
| ONVIF `unique_id` | `3a80ec:…:3a80f1` | `3ab284:…:3ab289` |
| Firmware | `57.0.8.0` | `57.0.2.0` — **older** |
| Paired | ⚠️ **unproven** — see the retraction below | **local `/setwifi`, `userid:"0"`** [M] |
| **Role** | 🔴 **production — going outside, by the cars** | 🧪 **lab — expendable** |
| Extra open port | — | `3576`, purpose unknown |
| Aim | untouched — **PTZ allowed, but deliberate** ([why](docs/ptz.md#ptz-on-icam365-01-allowed-deliberately-jp-2026-08-06)) | ⚠️ needs physical re-aiming after PTZ testing |

> ### ❌ RETRACTED 2026-08-06: "identify these cameras by `unique_id`"
>
> This page used to say the `unique_id` was the one stable handle. **That advice is withdrawn,
> and it may be actively dangerous at fleet scale.**
>
> **The `unique_id` is not a MAC address and probably not a device identity. [M]** Decode either
> value and it is **six consecutive integers, every one of them larger than `0xff`**:
>
> ```
> 3a80ec 3a80ed 3a80ee 3a80ef 3a80f0 3a80f1     <- deltas of exactly 1
> 3ab284 3ab285 3ab286 3ab287 3ab288 3ab289
> ```
>
> MAC octets cannot exceed `0xff`. These are **addresses**: the firmware formats
> `&mac[0], &mac[1], …` — the locations of the buffer's bytes — instead of the bytes. The two
> bases differ by `0x3198`.
>
> ### 🔴 CONFIRMED [M] — it is a firmware fingerprint. Two cameras, one identity.
>
> The discriminator was run on 2026-08-06, the first time a **third** unit existed. A physically
> different camera (`icam365-wall`, its own real MAC, provisioned from its own setup AP) was asked
> for its `HwAddress`:
>
> | unit | real MAC (from DHCP) | firmware | ONVIF `unique_id` |
> |---|---|---|---|
> | `icam365-02` | `…:f7:bf:6d` | `57.0.2.0` | `3ab284:…:3ab289` |
> | `icam365-wall` | `…:df:ac:2e` | `57.0.2.0` | **`3ab284:…:3ab289` — identical** |
> | `icam365-01` | `…:df:d6:3f` | `57.0.8.0` | `3a80ec:…:3a80f1` |
>
> **Two distinct physical cameras with different MACs return byte-identical `unique_id`s, and the
> only unit that differs is the one on different firmware.** The value tracks the build, not the
> device. It is also **stable across a genuine cold boot** — `icam365-01` returned the identical
> string after a confirmed mains cut — so it is deterministic, not per-boot noise.
>
> 🔴 **Consequence for a 12-camera fleet: they do not have 12 identities. They have one per
> firmware version.** Home Assistant's ONVIF integration keys devices on this value, so adding a
> second camera on the same firmware is expected to be **rejected as already-configured** —
> silently, and looking like nothing happened.
>
> ⚠️ **And it retroactively disarms the 2024 evidence.** A 2024 HA record carrying `3ab284:…`
> identifies *a unit running `57.0.2.0`*. It **cannot name a physical camera**, so it can neither
> confirm nor refute which unit was paired then. See the pairing retraction below.
>
> ⚠️ **Until that is settled, treat `unique_id` as a firmware fingerprint.** The dependable handle
> is the **real MAC from the DHCP reservation or the AP association list** — which is knowable
> from the network side and is genuinely per-unit. The serial is useless (**both units report the
> same placeholder** `12345679890`), and the informal "cam #N" numbering is **inconsistent across
> the source notes** — the same physical camera has been called "cam #1" and "cam #2" in
> different sessions.
>
> **A parsing note that cost time:** the firmware emits `<tt:HwAddress >` — with a space inside
> the tag. A regex for `HwAddress>` silently matches nothing, and a script that then reports
> "changed" is reporting its own parse failure. Verify the artefact, not the exit code.

### 🔴 Operational rules — `icam365-01` is production

**`icam365-01` is the camera going outside, up by the cars.** `icam365-02` is the lab unit.
That division was ambiguous in the source notes and has been settled explicitly, because it
decides which unit the destructive findings apply to.

Four rules follow, and a future reader will otherwise violate all of them:

* **PTZ on `icam365-01`: deliberate, never casual.** The aim cannot be restored to a *chosen* framing, though [a known corner is reachable](docs/ptz.md), and
  the camera will be up a ladder. The controls **are** present in HA — JP restored them on
  2026-08-06 after they had been removed, on the grounds that a missing control reads as
  *broken*, not as *protected*. Caution, not prohibition; rehearse on `icam365-02` first.
* **No power-cycle testing on `icam365-01`.**
* **No write-probing `icam365-01`'s vendor ports** — a single stray byte to `:20202` is
  [enough to knock a camera off the network](docs/security.md).
* **Any WAN pairing window is scoped to `icam365-02`'s address only** — never the whole camera
  VLAN, and never `icam365-01`.

Do destructive work on `icam365-02`. That is what it is for.

#### Why that split, and why it turned out to matter

A natural experiment, now half-measured:

| | Paired how | Survives a power cycle? |
|---|---|---|
| `icam365-01` | ⚠️ **unproven** (see below) | **Yes** — [confirmed 2026-08-06, unattended](docs/provisioning.md#-confirmed-m-a-camera-does-survive-a-power-cycle). **[M]** |
| `icam365-02` | locally, **no cloud bind** [M] | **No** — [confirmed on a single clean flip](docs/provisioning.md#-answered-it-is-not-durable-confirmed). **[M]** |

> ### ❌ RETRACTED 2026-08-06: "`icam365-01` was app-paired in 2024 with cloud"
>
> **The outcomes above are measured. The explanation for them is not, and the pairing attribution
> that carried it has no source.**
>
> Home Assistant's own storage was read directly. **[M]**
>
> | HA device record | identifier | firmware | created |
> |---|---|---|---|
> | `icam365-02` | `3ab284:…` | `57.0.2.0` | **2024-09-22** — the original setup date |
> | `icam365-01` | `3a80ec:…` | `57.0.8.0` | **2026-08-06** — today |
>
> **The only 2024-dated record carries the identifier `icam365-02` reports today**, and
> `icam365-01` has no HA history before today at all. Nothing in this repo, or in HA, records
> `icam365-01` being paired in 2024. The claim appears to have propagated from session notes.
>
> **This is not a correction to "it was actually `icam365-02`."** Because
> [the identifier may be a firmware fingerprint](#-retracted-2026-08-06-identify-these-cameras-by-unique_id),
> a 2024 record showing `3ab284:…` may mean only *"a unit running `57.0.2.0` was paired in 2024"*
> — which does not name a physical camera at all. **Retracted to unproven, not to false.**
>
> ⚠️ **What this does to the durability story:** the cloud-bind hypothesis was the whole reason
> for the rule *pair once with internet, then isolate*. It now rests on **zero measured positives**
> — and the one unit we can date to a 2024 pairing is, on the most literal reading of the record,
> the unit that **forgets**. The competing explanation (a persistence bug fixed between `57.0.2.0`
> and `57.0.8.0`) is untested and explains every observation equally well.
>
> **Keep following the rule operationally** — it is cheap and the downside is a ladder — but stop
> citing it as established. The experiment that settles it is [described here](docs/provisioning.md#-confirmed-m-a-camera-does-survive-a-power-cycle).

So the constraint is real, and it has a usable shape:

> **These cameras need one supervised, internet-connected app pairing before they can live on an
> isolated VLAN.** Local `/setwifi` works, but produces a camera that forgets on every power cut.

> ✅ **This retroactively validates sending `icam365-01` outside.** Had the lab unit gone up by
> the cars, the first power blip would have orphaned it — at the top of a ladder, looking like
> dead hardware.

> ✅ **The `icam365-01` row was upgraded from inferred to measured on 2026-08-06 — for free.**
> Nobody was ever going to power-cycle the production camera to confirm it. Then **its outlet went
> off** (confirmed by JP — a genuine mains cut, unpowered ~41 min), and it came back **unattended,
> on the same SSID, with a fresh 802.11 auth and a fresh DHCP lease.**
>
> That is the *same test* that stripped the lab unit's config — so the two rows above are now a
> **controlled comparison**, not two anecdotes.
> [Full evidence, and the confound it exposes, here.](docs/provisioning.md#-confirmed-m-a-camera-does-survive-a-power-cycle)
>
> ⚠️ **What it still does *not* establish: the cause.** The units differ in pairing method **and in
> firmware** (`57.0.8.0` vs `57.0.2.0`). A persistence bug fixed between those releases would
> explain the result just as well. Twelve units make that separable; until then the mechanism is
> **[I]**.
>
> **Worth keeping:** the decisive experiment had been ruled out as too expensive, so it was never
> designed — and it then ran itself. It was caught only because a cheap instrument that touches no
> device (an AP association log, a lease timestamp) happened to be pointed at it.

## Hardware, confirmed by looking at it

**Physically verified on the units in hand, 2026-08-06. [M]** This matters more than it looks:
every one of these is a capability the **network cannot see**, and in three cases the network
negative had already been recorded and would have read as "the feature does not exist".

| | present | reachable over any open protocol |
|---|---|---|
| **Microphone** | ✅ all units | ✅ yes — PCM A-law in the RTSP stream |
| **Speaker** | ✅ **all units** | ❌ **no** — [no ONVIF backchannel, ten operations absent, SDP `recvonly`](docs/onvif.md) |
| **IR LEDs** | ✅ **all units** | ❌ **no** — no auxiliary commands, no imaging extension |
| **IR-cut filter** | ✅ (implied by IR LEDs + day/night) | ❌ **no** — `Get/SetImagingSettings` are **HTTP 400, absent** |
| **SD card slot** | ✅ **all units** | ❌ **no** — `GetStorageConfigurations`, `GetRecordings` → `ActionNotSupported` |
| PTZ motors | ✅ pan + tilt | ✅ yes — `ContinuousMove`, and the vendor `ptzctrl` endpoint |

> ### 🔑 The lesson is about what a negative result means
>
> Before this inspection, the speaker, the IR LEDs and the storage were all recorded as *not
> found over the network*, and the honest write-up said so — "consistent with 'no speaker' **and**
> with 'speaker exists, vendor-protocol only'". **The hardware inspection collapses that
> ambiguity in one direction: the hardware is all there.**
>
> So these are not missing features. They are **features whose control surface is not exposed by
> any open protocol** — which is a completely different problem with a completely different fix.
> The first says buy different cameras; the second says finish the vendor-protocol work.
>
> **Where a device's self-report is systematically unreliable, the cheapest reliable instrument
> may be a person looking at the thing.** On this hardware the label and the case have
> outperformed ONVIF at least twice — see also
> [the identity retraction](#-retracted-2026-08-06-identify-these-cameras-by-unique_id), where the
> serial, the model, the hardware id and the pseudo-MAC are all shared constants and the sticker
> is the *more* trustworthy source.

⚠️ **The IR-LED network negative was already flagged as weak by the agent that measured it** — the
sweep ran in daylight, and firmwares commonly refuse to light an IR lamp while the ambient sensor
reads "day", so daylight makes that test *harder*, not easier. The hardware confirmation makes a
post-dusk re-test worthwhile rather than academic.

## Specifications

Measured on the units in hand across 2026-08-05/06. Every row is **[M] measured** or
**[I] inferred**; a row marked **[?]** is *unknown*, not *absent* — those are in
[§ What is still unmeasured](#what-is-still-unmeasured).

> ### 🔑 Read the whole sheet through one lens
>
> **On these cameras, "the hardware has it" and "you can reach it" are different columns**, and the
> gap between them is the entire story of this repo. The
> [hardware inspection](#hardware-confirmed-by-looking-at-it) found a speaker, IR LEDs, an IR-cut
> filter and an SD slot in **every** unit — all of which the network reports as absent. So a `❌` below
> almost never means *"this camera cannot"*. It means **"no open protocol exposes it."**
>
> The `:6670` task table settles that in the firmware's own words: `tSpeaker`, `tIcrCtrlThread`
> (ICR = IR-Cut Removable), `sddetectTask` and `tMotDet` are all **running threads**. **[M]**

### Video

| | | |
|---|---|---|
| Codec | **H.265 / HEVC, Main profile** — on both streams | **[M]** |
| 🔴 Reported codec | **`H264`** — wrong, on every ONVIF path, and **not correctable** (see below) | **[M]** |
| Main stream | `rtsp://<cam>:554/0/av0` — **1920×1080** (coded 1920×1088), level 120 | **[M]** |
| Sub stream | `rtsp://<cam>:554/0/av1` — **640×360** (coded 640×368), level 63 | **[M]** |
| Pixel format | `yuvj420p` (full range) | **[M]** |
| 🔴 **Sub-stream rate** | **12.35 fps delivered** against 12.5 nominal — **zero stalls in 30 s**, keyframes every 2.00 s across 14 consecutive intervals with no deviation | **[M]** |
| 🔴 **Main-stream rate** | **~9.3 fps delivered** against 12.5 nominal — **loses ~¼ of its frames and periodically drops whole GOPs** (10.0 s and 6.0 s keyframe gaps = four consecutive GOPs vanished). Reproduced twice at 9.29 / 9.26 fps | **[M]** |
| Bitrate | sub **213 kbit/s** · main **821–827 kbit/s** | **[M]** |
| Frame size | sub 2.2 KB mean / 10.9 KB max · main **11.0 KB mean / 92–97 KB max** | **[M]** |
| Cause of main-stream loss | the 92–97 KB keyframe burst over WiFi; the substream's largest frame is 10.9 KB and it never stalls | **[I]** |
| Keyframe interval | **2.00 s** (= 25 frames) — ONVIF reports `GovLength 100`, which is wrong | **[M]** |
| Encoder configuration | ❌ **not settable by any route.** `SetVideoEncoderConfiguration` → HTTP 400, unknown to the dispatcher. Verified by effect: keyframe interval never moved off 2.00 s | **[M]** |
| Resolution / bitrate / fps control | ❌ none. Encoder "options" echo the current setting back in menu shape | **[M]** |
| RTSP authentication | ❌ none | **[M]** |

> ### 🔑 Use `/0/av1`. The substream is not a degraded fallback — it is the reliable stream.
>
> It delivers what it promises, never stalls, and costs a quarter of the bandwidth. **The main
> stream is the one that drops frames.** For recording, motion detection or Frigate on twelve units,
> that is the whole decision.

> #### 🔴 The codec lie is now *unfixable*, which is better news than "inadvisable"
>
> `README.md` warns that correcting the `H264` string would silently empty Home Assistant. **That
> risk is now bounded: there is no local way to correct it.** `SetVideoEncoderConfiguration` does not
> exist on this firmware, and `H265` is not offered anywhere in the encoder options. **No operator
> can trip this by hand. [M]**
>
> ⚠️ **The remaining exposure is a vendor firmware update** — and the lie is present across at least
> three firmware majors on unrelated owners' units **[R]**, so that is unlikely. If cameras ever
> vanish from HA after an update, still check the codec string first.

### Stills

| | | |
|---|---|---|
| ✅ Working snapshot | **`http://<cam>:8001/snapshot`** — JPEG, **640×360**, no auth, ~54–90 ms | **[M]** |
| Snapshot size | **9.8 KB – 56.8 KB**, scene-dependent. **Do not budget bandwidth from one sample** | **[M]** |
| 🔴 ONVIF snapshot URI | advertised as `http://<cam>/onvif/snapshot` and **dead** — empty reply, connection closed, tried twice | **[M]** |
| Full-resolution still | ❌ **none by any route.** The only still available is substream resolution | **[M]** |

**[I]** The dead ONVIF URI is very likely why HA's ONVIF camera entity produces no still on these
units, and why this project had to find `:8001` by hand.

### Audio

| | | |
|---|---|---|
| Microphone | ✅ present, all units — **PCM A-law, 8 kHz, mono, 64 kbit/s**, 40 ms ptime, always on | **[M]** |
| Speaker hardware | ✅ **present in every unit** (physical inspection), and the firmware runs a **`tSpeaker`** thread | **[M]** |
| Audio **out** / two-way talk | ✅ **WORKS. [M]** `818 startSpeaking` + raw G.711A on **channel 5**, 8 kHz mono, 40 ms frames with a 16-byte `SFrameInfo` header. Firmware returns status `0` = accepted (refusals return `3`), and **JP confirmed with his ear at the unit that the sound came from the camera.** ❌ Not reachable over ONVIF/RTSP: ten audio-output operations decline, SDP is `recvonly`, and the backchannel `Require` header is **answered `200` and silently ignored** where RFC 2326 mandates `551` | **[M]** |
| Advertised `AudioOutputs` | **`1`** — advertised and unreachable; joins the list of fields that are simply wrong | **[M]** |
| Audio codec over ONVIF | ❌ unavailable — the audio encoder configuration is an **empty stub** (blank token, blank encoding, zero rates). The SDP is the only source | **[M]** |
| Microphone mute | **[?]** not tested | |

> #### ✅ Confirmed on the third attempt — and what the first two were missing
>
> **Claim 1** attributed a reported sound to a test believed not to have run. Withdrawn.
>
> **Claim 2** looked airtight: JP reported **a spoken phrase containing his own name**, which had
> never been described to him — apparently the ideal unleakable evidence. **It was withdrawn too,
> because the transmitter had sent no speech.** Only **three 1 kHz beeps and one 440 Hz tone** ever
> went to the camera. JP reported *three* sounds — music, tones, and speech — and **we emitted one**.
>
> 🔴 **So an unattributed audio source was active on the bench**, and once that is true, the *tones*
> cannot be attributed either — the same unknown source explains all three.
>
> **The protocol worked; the operator did not.** The rule "have them report the pattern, not yes/no"
> exists to make false attribution *detectable*, and it fired: JP volunteered the word **"music"**
> before any briefing, and nobody hearing three beeps and a tone calls that music. The mismatch was
> visible in his own words. **A yes/no question would have returned "yes" and it would have been
> banked.**
>
> 🔑 **Unleaked content is necessary but not sufficient.** Evidence has to be tied to the
> *transmitter* as well as the receiver: what was sent, and when. The fix is a **time anchor** — the
> camera's monotonic uptime counter places transmission to the second, so the next run asks JP to
> say *"now"* on hearing it, turning "I heard beeps" into "I heard beeps inside the 40-second window
> in which beeps were transmitted."
>
> **Two false confirmations of the same capability inside one hour, by the person enforcing the
> rule on everyone else.** Nobody is careful enough to catch this reliably. The guard has to be
> procedural.
>
> ### ✅ What actually settled it
>
> **JP put his ear to the unit and reported the sound came from the camera.** That is the
> attribution question, and it is the one all three earlier attempts skipped while arguing about
> content. Combined with `818` returning **accepted** and frames transmitted in a known window, the
> capability is confirmed.
>
> ⚠️ **Recorded honestly: the listener's vocabulary was leaked** — he had been briefed to expect
> "beeps and a tone" — so the *pattern* match is weak evidence. **The source attribution is the
> strong part**, and it is what was missing.
>
> 🔑 **And a closing lesson in the other direction, which cost as much time as the false positives
> did:** after being wrong twice, the verification demands escalated past usefulness — a fourth
> and fifth round of questioning were queued for a claim that a person standing next to the device
> had already answered. **Over-correction is also a failure mode.** Calibration means updating in
> both directions; the point of a guard is to catch errors, not to make evidence unacceptable.

### Pan / tilt

| | | |
|---|---|---|
| Axes | ✅ **pan + tilt.** No zoom — fixed lens | **[M]** |
| ONVIF | ✅ `ContinuousMove` works, and HA's `onvif.ptz` works — capability arrives via `GetProfiles`, not `GetNodes` | **[M]** |
| Vendor endpoint | `http://<cam>:8001/ptzctrl?act=<n>`, no auth | **[M]** |
| **Movers** | **`1, 3, 5, 7, 9, 10, 11`** — 7 codes | **[M]** |
| **Non-movers** | **`0, 2, 4, 6, 8`** — each tested from **two opposite corners** | **[M]** |
| Pan axis | `act=1` ↔ `act=3` are **opposites** (net 4.3 after two ~49 moves) | **[M]** |
| Tilt axis | `act=7` ↔ `act=9` are **opposites** | **[M]** |
| Absolute direction (which is "left") | **[?]** — deliberately unpublished. It rests on the firmware honouring the ONVIF sign convention, on a device that misreports codec, MAC, gateway, GOP, framesize, serial and profile count. **One human eyeball closes it** | |
| 🔴 Travel per command | **a single `act` drives the full range to a hard mechanical stop.** Pan ~5.2 s, tilt ~13.0 s. There is no partial step | **[M]** |
| Repeatability | pan **5.1 / 5.2 / 5.2 / 5.3 s**; tilt **13.0 / 13.0 / 13.0 / 13.3 s** | **[M]** |
| At the limit | ✅ **stops dead and stays there.** Repeat commands do nothing — no grind, no creep, no drift | **[M]** |
| Position feedback | ❌ none. `GetStatus` → `ActionNotSupported` | **[M]** |
| Presets / home | ❌ not implemented | **[M]** |
| `Stop` | ❌ `ActionNotSupported`. The ONVIF `<Timeout>` is **ignored** | **[M]** |

> ### ✅ You *can* return to a known position — the limits are the reference
>
> Timed software presets are **not** feasible: every command runs to a stop, so there is no partial
> move to count. **But the mechanical limits are repeatable and commandable.** `act=1` always ends at
> the same pan extreme, `act=3` at the other, `act=7`/`act=9` at the tilt extremes.
>
> **So a "go to a known corner" macro exists today** — `act=3` then `act=9`. It does not restore
> *your* framing, but it converts aim from **irreversible** to **repeatable**, which is the
> difference between a ladder and a command. **[M]** for the limits; **[I]** that a corner-to-corner
> home is the full capability.

### Storage and recording

| | | |
|---|---|---|
| microSD slot | ✅ **present in every unit** (physical inspection); vendor manual says **up to 128 GB, no hot-swap** | **[M]** / **[R]** |
| Firmware SD support | ✅ **`sddetectTask` runs** — the firmware does look at the card | **[M]** |
| ONVIF storage / recording | ❌ `GetStorageConfigurations`, `GetRecordings` → `ActionNotSupported` | **[M]** |
| Local playback / export | ❌ none found | **[M]** |
| Card format the firmware wants | **[?]** — FAT32 is the family convention **[R]**; unverified here | |

### Events, motion and analytics

| | | |
|---|---|---|
| On-device motion detection | ✅ **runs** — `tMotDet` thread | **[M]** |
| ONVIF events | ❌ **no transport of any kind.** `GetEventProperties`, `CreatePullPointSubscription` and `Subscribe` are all HTTP 400 — three independent negatives | **[M]** |
| 🔴 Advertised event support | `WSPullPointSupport="true"`, `MaxPullPoints="10"` — **a lie.** A client that trusts it builds a path that cannot work | **[M]** |
| ONVIF analytics | ❌ five operations decline; `GetMetadataConfigurations` self-reports `Analytics=false` | **[M]** |
| Metadata/analytics RTSP track | ❌ absent from the SDP | **[M]** |
| **Consequence** | **Home Assistant will never show a motion sensor for these cameras.** Structural, not a misconfiguration — no YAML fixes it | **[M]** camera side, **[I]** the HA code path |
| AI detection / auto-tracking | exists in the vendor app's vocabulary (`AiDetect`, `MotionTrack`); ❌ not reachable locally | **[M]** |

### Imaging

| | | |
|---|---|---|
| Brightness / contrast / saturation / exposure / focus / white balance | ❌ **no imaging control at all.** `GetImagingSettings` and `SetImagingSettings` are **HTTP 400 — absent**, despite the Imaging service being advertised with its own XAddr | **[M]** |
| IR-cut filter | ✅ hardware present, **`tIcrCtrlThread` runs**; ❌ no ONVIF control — ✅ **controllable over the vendor channel**, below | **[M]** |
| **Illuminators** | ✅ **an IR array AND a white floodlight.** ❌ no ONVIF control — ✅ **`SET_DOUBLELIGHT` (32788) drives them**, below | **[M]** |
| Day/night switching | ✅ **controllable — measured** (vendor channel, below) | **[M]** |
| OSD / text overlay | ❌ `GetOSDs`, `SetOSD`, `CreateOSD`, `DeleteOSD` all decline | **[M]** |

> ### ✅ SOLVED 2026-08-06 — day/night IS controllable, over the vendor channel
>
> **The first capability this project has *restored* rather than documented as absent.** [M]
>
> ONVIF cannot do it — `Get/SetImagingSettings` are HTTP 400, the Imaging service is empty. The
> **authenticated PPCS control channel** can:
>
> | | |
> |---|---|
> | Command | `SET_DAYNIGHT` **32792**, mode in the request at word[1] |
> | Response | `32793`, and `GET_DAYNIGHT` **32790** reports the mode at **word[2]** |
> | Mode `0` | colour / day — saturation ≈ **50.8** |
> | Mode `1` | accepted and round-trips, **no visible change in daylight** — consistent with a "force day" interlock, **[I]**, untested |
> | Mode `2` | **night — IR-cut removed, saturation `0.000`, R = G = B exactly** |
> | Mode `3` | rejected: acked, but `GET` still reports `2`. Not a valid mode |
>
> **`|dsat| = 50.83` against an idle floor of 0.46 — a ~110× margin.** Restored to mode `0` and the
> **restore verified by image comparison, not by re-reading state**, then independently
> re-measured from a second host: RGB spread 5.37, saturation 51.4. No magenta.
>
> ⚠️ **Note the request and response layouts differ** — the mode is written at offset 4 and
> reported at offset 8. A field meaning taken from a single plausible-looking read would have been
> wrong; it was settled by watching which word moved under a `SET`.
>
> 🔑 **And the instrument mattered more than the command.** The earlier ONVIF-lane IR sweep used a
> **greyscale** metric — and the entire effect here *is the loss of colour*. **That instrument
> could not have detected this even if pointed straight at it.** Saturation was the right measure.

> ### ✅ SOLVED — the illuminators are controllable, and there are two of them
>
> **`SET_DOUBLELIGHT` (32788) drives a visible white floodlight, with the IR-cut filter left IN
> (`DAYNIGHT` = 0). [M]** So illumination is **independently controllable and night mode is not a
> precondition** — you can flash a light without switching the camera to monochrome.
>
> **How it was established**, because whole-frame statistics could not do it: the command was
> cycled **three times in a known window**, with a *second* candidate command (`LED_STATUS`) run in
> a **separate, non-overlapping block**, so the observer's timing alone names which one fired. JP
> reported *"it blinked like 3 times a minute or so ago"* — landing 1.3 min after the
> `DOUBLELIGHT` block and 2.5 min after the `LED_STATUS` block. **Block B. Unambiguous.**
>
> ⚠️ **Despite the name, `DOUBLELIGHT` does not appear to mean "both lights at once."** JP, who was
> briefed only about infrared, spontaneously reported **white** light — and then, unprompted, that
> it was *"just white lights not white and ir"*. Combined with an **infrared** sighting during an
> earlier sweep at `DAYNIGHT` mode 2, the evidence reads as a **selector over which illuminator is
> active**, not a combined mode. **[I]** on the exact enum; `2` is the units' original value.
>
> **Add it to the list of names that mislead**, next to the codec that reports `H264` while
> streaming H.265 and the "MAC address" that is a formatted pointer.
>
> | command | result |
> |---|---|
> | **`SET_DOUBLELIGHT` 32788** | ✅ **drives a visible white illuminator** — filter in, day mode |
> | `SET_LED_STATUS` 1058 | ⚠️ **accepted but inert** — status `0` every time, no observed effect in either block. *Accepted is not honoured*, one layer deeper again |
> | `SET_ALARMLIGHT` 1090 | ❌ **no ack at all**, on a demonstrably live session with commands either side acking normally. **Unproven for `1090` specifically** — not a session failure |
>
> **A refuted prediction, recorded because it was staked in advance.** Before the observer spoke,
> the hypothesis on record was that IR would prove to be a *side-effect* of night mode rather than
> an independent control. **The timing refuted it.** A prediction offered before the evidence and
> then overturned by it is worth more to a reader than one that survived.

⚠️ **The IR-LED negative is weak by its own author's admission** — the sweep ran in daylight, and
firmwares commonly refuse to light an IR lamp while the ambient sensor reads "day". A post-dusk
re-test is worthwhile.

### Platform internals — read off a live root shell

**Everything here was unknown until an SD card produced a root shell. [M]** Full detail and the
method in [docs/root-access.md](docs/root-access.md).

| | |
|---|---|
| **SoC** | 🔑 **Augentix HC1703L** on the EYEPLUS units — family `hc1703_1723_1753_1783s`. **Not** any of the Goke / HiSilicon / SigmaStar / Ingenic candidates the external research pointed at. ⚠️ **A sibling model runs different silicon entirely — see below** |
| **Board** | **`HC1703L-TB008-NOR-8MB`** — from the device tree `model` |
| **CPU** | **1 core**, ARM **Cortex-A7** (ARMv7l, `0xc07` rev 5). BogoMIPS **20160** |
| CPU features | `neon vfpv3 vfpv4 vfpd32 idiva idivt lpae thumb edsp evtstrm` |
| Clock speed | **[?]** — no `cpufreq` sysfs, nothing in the boot log |
| **RAM** | **61,968 kB total** (~60.5 MiB usable of a 64 MB part). ~1.6 MB free at rest |
| **Flash** | **8 MB NOR**, 64 KB erase blocks, 6 MTD partitions |
| Removable storage | **microSD** — `mmcblk0`, and the camera records video to it |
| Kernel | **Linux 3.18.31** (built 2024-02-28) |
| Userland | **BusyBox v1.33.0** |
| MAC address | burned into **eFuse** (`efuse_macaddr` at boot) — so the *real* MAC is per-unit hardware |
| init | BusyBox init → `/etc/inittab` → `/etc/init.d/rcS` |
| Root filesystem | **squashfs, read-only, 1.3 MB, 100 % full** |
| Flash | **~8 MB NOR**, 64 KB erase blocks, 6 MTD partitions |
| Serial console | present in `inittab` but **commented out** (`ttyAS0`) |
| A sibling model | **Linux 4.9.37**, 5 partitions — [same boot hook](docs/root-access.md) |

> ### 🔴 These cameras are not one platform — they are at least two silicon vendors
>
> **[M]** on two EYEPLUS units, **[I]** on the sibling:
>
> | unit | `/proc/cpuinfo` `Hardware:` | vendor syscall binary | SoC |
> |---|---|---|---|
> | `icam365-02` | `Augentix HC1703_1723_1753_1783s family` | `/bin/rsyscall.hc1703` | **Augentix HC1703** **[M]** |
> | `icam365-wall` | same | same | **Augentix HC1703** **[M]** |
> | `cloudcam-01` | 🔴 **`Generic DT based system`** — useless | **`/home/rsyscall.xm7205v500`** | **[I] `xm7205v500`** |
>
> ⚠️ **The chip name is inferred from a filename, not read from a register.** `/home/CHIP_NAME` on
> that unit is 11 bytes, which fits `xm7205v500` plus a newline — but it equally fits
> `gk7205v300`, so **the byte count corroborates nothing.** One `cat` closes it and it has not
> been run.
>
> 🔑 **This makes the SD-card root result stronger, not weaker.** The same
> [`/mnt/debug_cmd.sh` hook](docs/root-access.md) fires across **different silicon vendors**, not
> merely different products from one house — which is the best possible basis for expecting it on
> units bought later, from another seller, carrying another chip.
>
> ✅ **A free SoC fingerprint for any newly-rooted unit**, and it works where the obvious method
> fails — `cloudcam-01`'s `Hardware:` line is the useless `Generic DT based system`, yet its
> `rsyscall` filename names the chip anyway:
>
> ```sh
> grep Hardware /proc/cpuinfo; ls /bin /home /home/bin 2>/dev/null | grep -i rsyscall; cat /home/CHIP_NAME 2>/dev/null
> ```

#### On-chip hardware blocks — what the silicon actually provides

Enumerated from `/dev` on a live shell. **[M]** These are the capabilities the SoC exposes; how
much of each reaches the network is a separate question, and mostly the answer is "none".

| device | block | reachable over the network? |
|---|---|---|
| `isp`, `is`, `senif` | image signal processor + sensor interface | ❌ no imaging control exists over ONVIF |
| `enc` | **video encoder** (H.265) | ⚠️ read-only — `SetVideoEncoderConfiguration` does not exist |
| `osd` | **on-screen display** | ❌ — this is what burns the `1970` timestamp into every frame |
| `ptz` | **PTZ controller** | ✅ partially, via `ContinuousMove`; no position feedback |
| `gio` | **GPIO** | ❌ — the likely route to IR-cut and the illuminators |
| `i2c-0`, `i2c-1` | two I²C buses | ❌ — sensor and peripheral control |
| `snd` | **audio** in *and* out | ⚠️ mic only over RTSP; speaker needs the vendor channel |
| `iio:device0` | an IIO sensor | **[?]** — **[I]** plausibly the ambient-light sensor behind the day/night interlock |
| `otp_agtx` | **one-time-programmable fuses** | ❌ — where the eFuse MAC lives |
| `watchdog`, `watchdog0` | hardware watchdog | ❌ — matches the `twd` thread, and the crash-and-recover behaviour observed |
| `rc` | remote-control / IR receiver | **[?]** unexamined |
| `mmcblk0` | SD card | ❌ all ONVIF storage operations return unsupported |
| `ttyAS0` | **serial console** | present, but its getty is commented out in `inittab` |

> 🔑 **Read that table as the thesis of this repo in one place.** Nearly every block is present in
> silicon and absent from the network. The camera is not short of capability; its open protocols
> are.

```
mtd0 "boot"    256 KB      mtd3 "rootfs"  1.25 MB   -> squashfs, ro
mtd1 "bootenv"  64 KB  <-  mtd4 "home"     384 KB   -> jffs2, rw, 66% full
mtd2 "linux"   1.5 MB      mtd5 "bak"      4.6 MB   -> jffs2, ro, factory backup
```

> 🔑 **The writable surface is one 384 KB partition.** `/` is read-only squashfs and `/opt`,
> `/tmp` and `/run` are tmpfs — so **everything a camera remembers lives in `/home`**, and it has
> **132 KB free**.

### 🔴 Where a camera's identity and WiFi actually live

`/home`, on `mtd4`, JFFS2, read-write — **genuinely persistent, not a RAM disk.** [M]

| file | size | what it is |
|---|---|---|
| **`wpa_supplicant.conf`** | 195 B | ✅ **the WiFi credentials** — a plain, standard wpa_supplicant file (`ssid`, `psk`, `key_mgmt`) |
| **`tange.dat`** | 66 B | binary — **[I]** the vendor/cloud binding |
| `devParam.dat` (+`_bak`) | 1004 B | binary blob, mode `000`. Not text; no readable fields |
| `extraParam.dat` (+`_bak`) | 5120 B | binary blob, mode `000` |
| `hwcfg_bak.ini` | 192 B | hardware config |
| `ptz_bak.cfg` | 127 B | **[I]** PTZ state — worth reading, given there is no position feedback over any protocol |
| **`no_cfg_reboot_time`** | 2 B | **a counter, currently `0`** |
| `no_ptz_reboot_time` | 2 B | a counter, currently `0` |
| `psp.dat` | 20 B | unknown |

> ### 🔑 This reframes the durability question the whole project has been chasing
>
> **The WiFi credentials are stored as a plain file on persistent flash.** They are not held in
> RAM, and they are not hidden inside the cloud binding — so *"the camera forgot its WiFi"* cannot
> simply mean "it was never saved."
>
> ⚠️ **And note the timestamps:** `wpa_supplicant.conf` and `tange.dat` are dated **one minute
> later** than every other file in `/home` — i.e. **written during provisioning**, not at
> manufacture. The rest predate them.
>
> 🔴 **`no_cfg_reboot_time` is the lead worth pulling.** A counter with that name, next to the WiFi
> config, on a device documented to
> [revert to AP mode after boots without a configuration](docs/provisioning.md), is very likely the
> mechanism — and it would also explain the vendor's documented multi-power-cycle factory reset.
> **[I], and now cheaply testable with a shell:** read it, power-cycle, read it again.
>
> **None of this was reachable over any network protocol.** The question drove this entire project
> and the answer was always a 195-byte text file on a 384 KB partition.

### Network and protocols

| Port | Service | Auth | |
|---|---|---|---|
| **80** | `Ginatex-HTTPServer` — ONVIF, plus a dead Hikvision-ISAPI-shaped surface | ❌ none | **[M]** |
| **554** | `TAS-Tech Streaming Server V100R001` — RTSP | ❌ none | **[M]** |
| **6670** | 🔴 **unauthenticated debug console** (`tCmdServer`) — see below | ❌ none | **[M]** |
| **8001** | `TAS-Tech IPCam` — exactly two endpoints, `/snapshot` and `/ptzctrl` | ❌ none | **[M]** |
| **20202** | `/setwifi` provisioning — **stays open after pairing** | ❌ none | **[M]** |
| 3576 | unknown. Connects, then clean EOF to everything | ❌ none | **[M]** |
| UDP **32108** | PPCS `LanSearch` | — | **[M]** |
| UDP **32100** | PPCS cloud directory | — | **[M]** |

| | | |
|---|---|---|
| WiFi | WPA2; the interface is `wlan0` and **no Ethernet is wired on these units** | **[M]** |
| WiFi band | **2.4 GHz** — the SSID these units are joined to is 2.4 GHz-only. ⚠️ **Whether the radio *also* supports 5 GHz is [?]** — vendor material advertises dual-band for *some* iCam365 models, and ONVIF cannot tell us (all three Dot11 operations decline). **Do not assume 2.4-only when planning; do not assume dual-band either** | **[M]** / **[?]** |
| ONVIF Dot11 config | ❌ `GetDot11Capabilities`, `GetDot11Status`, `ScanAvailableDot11Networks` all decline — **on a WiFi-only device** | **[M]** |
| HTTPS / TLS | ❌ **unsupported**, not merely disabled. All TLS versions `false`, `Dot1X false`, `HttpDigest false`, `DefaultAccessPolicy true` | **[M]** |
| P2P / cloud stack | **CS2 Network PPCS (PPPP family)**, `libPPCS_API.so`. **Not TUTK** — it carries a *copied* TUTK command vocabulary. UID prefix `TANGE-` | **[M]** |
| Cloud hosts | `p2p-00{1,2,3}.host.tange365.com`, `ep.tange365.com` | **[M]** |
| Local P2P control | ✅ session establishes on the LAN with the cloud firewalled; plaintext, not obfuscated | **[M]** |
| Cloud device-login | 🔴 genuinely **encrypted** (`0xF1F9`) — and the bind never completes with `userid:"0"` | **[M]** |
| DHCP / DNS / NTP | DHCP client works; DNS from DHCP is correct; **NTP `0.0.0.0`, interval 0 — no NTP** | **[M]** |
| ONVIF default gateway | reports a **wrong subnet** — do not use the field | **[M]** |
| ONVIF scopes | **empty** — so scope-filtering discovery clients will not match these | **[M]** |
| ONVIF reboot | ❌ **`SystemReboot` is a measured no-op.** A `tReboot` thread exists, so this is a wiring gap, not a missing capability | **[M]** |

> ### 🔴 `:6670` is an unauthenticated debug console, and it is the sharpest security item here
>
> Not a "vendor binary protocol". Framing is `[BE length][BE command id][payload]`, **a payload is
> mandatory**, and it answers: `id=2` → **the full task table**; `id=3` → **a semaphore table with
> live kernel addresses**; `id=5` → **`redirectionOutput`** (console output redirection, failing only
> for want of an argument); ids **6–14** recognised-but-silent. **[M]**
>
> ❌ **RETRACTED: "command ids 0–599 were swept and none is valid."** That sweep sent no payload,
> which is why everything looked invalid.
>
> **Anyone who can reach the camera VLAN can read its internal task layout and live kernel
> addresses, unauthenticated.** Whether the redirect can be made to yield a console is
> [an open question](#open-questions), deliberately not pushed.

### 🔴 Security posture

Unchanged in substance and worth restating in one place: **nothing on this camera authenticates
anything.** A single unauthenticated ONVIF `GetUsers` returns the **administrator password in
cleartext**, on both units, and changing the password does not help. Add the `:6670` console to
that surface. **The camera VLAN's isolation and its default-deny to WAN are the entire control set.
[M]** → [security.md](docs/security.md)

### Firmware — what actually differs between builds

🔴 **Do not read any of this as fleet-wide. These are per-build behaviours, and conflating the two
has already caused two errors in one day.**

| | `57.0.8.0` | `57.0.2.0` | |
|---|---|---|---|
| Units | `icam365-01` | `icam365-02`, `icam365-wall` | **[M]** |
| **Clock** | ✅ **real wall-clock time** (`2026-08-06 04:23:21`) | ❌ **epoch — a seconds-since-boot counter** | **[M]** |
| **Burnt-in OSD timestamp** | ✅ correct | 🔴 **`1970-01-01` rendered into the pixels** (one unit reads `1969-12-31 17:25` — epoch **minus 7 hours**, i.e. a timezone offset applied to a clock that was never set, so **time and timezone are separately broken**) | **[M]** |
| `SetSystemDateAndTime` | **[?]** | ❌ does not exist — the wrong date is **unfixable in place** | **[M]** |
| Reboot detection via `GetSystemDateAndTime` | ❌ **no** — the clock never resets | ✅ **yes** — the value goes backwards | **[M]** |
| Answers PPCS `LanSearch` | ❌ **no** | ✅ yes | **[M]** |
| WiFi config survives a power cut | ✅ yes — one 41-minute mains cut, unattended, came back on the same SSID | ❌ **no** — lost on a single clean flip | **[M]** |

> ❌ **RETRACTED: "the 1970 timestamp affects all units."** It is a `57.0.2.0` defect. **For a
> driveway camera that changes the answer from "live with it" to "run the newer build".**
>
> ⚠️ **But the confound is severe and unresolved.** `icam365-01` is simultaneously the **only**
> cloud-bound unit, the **only** `57.0.8.0` unit, and the **only** one that ignores `LanSearch`.
> **Nothing measured on it can be attributed to firmware or to cloud state separately.** The
> durability row above is a real controlled contrast on *effect* and **[I]** on *mechanism*; the
> leading alternative — a flash-commit bug fixed between the builds — fits every observation
> equally well. Twelve units make it separable; until then, say which of the two a conclusion rests
> on, or admit it cannot tell.
>
> ⚠️ **[I]** and unchecked: `57.0.8.0` holds real time with **no NTP**, so it must be getting it from
> the cloud binding or an RTC. If it is the binding, a `57.0.8.0` unit behind the WAN deny may drift
> back to epoch — which would make the *reason* it has the right time load-bearing.

### Identity — none of it identifies a camera

| Field | Value | |
|---|---|---|
| Manufacturer | `EYEPLUS` | **[M]** |
| Model | `EYEPLUS_DEV` (literally "dev") | **[M]** |
| Serial | `12345679890` — **identical on every unit, and on unrelated owners' cameras worldwide** | **[M]** / **[R]** |
| HardwareId | `88` — same | **[M]** / **[R]** |
| Hostname | `localhost` | **[M]** |
| ONVIF `HwAddress` / `unique_id` | 🔴 **not a MAC** — six *consecutive* values above `0xff`, i.e. a formatted pointer | **[M]** |
| HTTP server | `Ginatex-HTTPServer` | **[M]** |
| RTSP server | `TAS-Tech Streaming Server V100R001` | **[M]** |
| `:8001` server | `TAS-Tech IPCam` | **[M]** |

> #### ❌ RETRACTED 2026-08-06: "identify these cameras by ONVIF `unique_id`"
>
> **The `unique_id` is a firmware fingerprint, not a device identity — and this is measured, not
> suspected.** Two units with **different real MACs**, both on `57.0.2.0`, report a **byte-identical**
> `HwAddress`. **[M]**
>
> 🔴 **Consequence for a 12-unit fleet: adding two same-firmware cameras to Home Assistant is a
> silent takeover, not an error.** The second collides with the first.
>
> ✅ **Identify a camera by the real MAC from the DHCP reservation or the AP association list.** Not
> by serial, not by `unique_id`, not by "cam #N" — that numbering is
> [documented as inconsistent across sessions](CLAUDE.md).
>
> **The general shape, which is the reusable part:** where a device's self-report is systematically
> unreliable, **the sticker and the router outperform the API.** That has now happened three times
> on this hardware.

### What is still unmeasured

Marked **[?]** so nobody reads them as "not applicable":

| | |
|---|---|
| Lens focal length, aperture, field of view | **[?]** |
| IR illumination range | **[?]** |
| Power draw, and supply voltage/current | **[?]** |
| Weatherproofing rating (one unit is already outdoors) | **[?]** |
| Operating temperature range | **[?]** |
| Image sensor part | **[?]** |
| SoC / platform | **[?]** — the firmware stack is TAS-Tech/Ginatex, whose previous generation ran **Goke GK7102**; that part is H.264-only so **this is later silicon, unidentified** |
| Absolute PTZ directions, and total pan/tilt sweep in degrees | **[?]** |
| Whether `3576` is unit-, revision- or firmware-correlated | **[?]** |
| Microphone mute | **[?]** |

### Open questions

| | |
|---|---|
| Can `:6670`'s `redirectionOutput` be made to yield a live console? | **deliberately not pushed** — high value, real blast radius, gated on JP |
| Does the firmware execute a script from the SD card at boot? | runbook written; **[I]** ~30% |
| Is durability a property of the **cloud binding** or of the **firmware version**? | the day's central confound; separable with 12 units |
| Do two same-firmware units collide on `unique_id`? | ✅ **answered — yes, measured** |

---

## Quick start

```sh
# a frame, no credentials, no HEVC decoder needed
curl -o frame.jpg http://192.168.1.21:8001/snapshot

# the streams (H.265)
ffprobe -rtsp_transport tcp rtsp://192.168.1.21:554/0/av0    # main  1920x1080
ffprobe -rtsp_transport tcp rtsp://192.168.1.21:554/0/av1    # sub    640x360
```

> ⚠️ **Do not port-scan these to discover them.** `nmap` sweeps are
> [demonstrably unreliable here](docs/vendor-api.md#-nmap-is-unreliable-against-these-cameras) —
> one full sweep missed ports 80 and 554 while they were actively in use. Probe named ports and
> confirm by connecting.

## Documentation

| | |
|---|---|
| [docs/security.md](docs/security.md) | 🔴 **Read first** — unauthenticated credential disclosure, and the `:6670` debug console |
| [docs/driving-the-camera.md](docs/driving-the-camera.md) | 🔑 **How to actually drive one** — the PPCS session, and the three capabilities ONVIF cannot reach |
| [docs/root-access.md](docs/root-access.md) | 🔑 **Root shell via SD card** — and what the platform turned out to be |
| [docs/onvif.md](docs/onvif.md) | ONVIF support matrix, and everything it misreports |
| [docs/vendor-api.md](docs/vendor-api.md) | `:8001`, the port map, and why nmap lies here |
| [docs/ptz.md](docs/ptz.md) | PTZ — and why testing it permanently changes the aim |
| [docs/provisioning.md](docs/provisioning.md) | Local pairing with no cloud account, and the persistence blocker |
| [docs/ai-and-events.md](docs/ai-and-events.md) | Why there are no motion sensors, and the vendor feature map |
| [docs/home-assistant.md](docs/home-assistant.md) | HA integration, entities, live view, and the traps |
| [notes/](notes/) | Session logs, kept as history — **prefer `docs/` for current facts** |

## Related

* [`anyka3918-gc1084-camera`](../anyka3918-gc1084-camera/) — the other hacked camera on this
  VLAN, with a full HTTP API reference
* [`ilnk-e27-bulb-camera`](../ilnk-e27-bulb-camera/) — a P2P bulb camera, and **a genuinely
  different device**: Beken silicon running RT-Thread and **iLnkP2P**, where these are
  **CS2 Network PPCS** (`libPPCS_API.so`, PPPP family — **not TUTK**; corrected 2026-08-06 from
  the decompiled vendor app). ⚠️ They are in fact **closer relatives than this page used to
  claim**: both are PPPP derivatives, so the **transport** transfers — which is the honest reason
  a local session came up first try. **Nothing above the transport does.** Do not assume they
  share a protocol because both use UDP
  32100 — that conflation has already cost this project time twice.

## A note on addresses

Addresses, SSIDs, MACs and device UIDs throughout this repo are **generic stand-ins**. The
structure and the findings are real; only the identifiers are substituted, so the repo can be
published without further work. **Credentials are never recorded here at all**, including the
one the cameras leak.
