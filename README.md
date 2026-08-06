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

Five independent confirmations, all measured:

| What it said | What was true |
|---|---|
| `POST /setwifi` → `200 OK` | Config **lost at the next power cycle** — the camera returned to AP mode |
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

## What works

| | |
|---|---|
| ✅ Video | RTSP, no auth — **H.265 only**, 1080p main / 640×360 sub, ~12 fps + PCM A-law |
| ✅ Snapshots | [`:8001/snapshot`](docs/vendor-api.md#snapshot-is-the-most-useful-thing-on-these-cameras) — 640×360 JPEG, ~70 ms, no auth. **The best thing on these cameras.** |
| ✅ PTZ | ONVIF `ContinuousMove` and HA's `onvif.ptz` — [but testing it destroys the aim](docs/ptz.md) |
| ✅ Local provisioning | [No cloud account needed](docs/provisioning.md) |
| ✅ Availability monitoring | HA binary sensor + health sensor |
| 🔴 WiFi persistence | **Confirmed non-durable.** A single clean power cycle loses the config, even after cloud contact. [Every camera needs one supervised app pairing before isolation](docs/provisioning.md#-answered-it-is-not-durable-confirmed) |
| ❌ Position feedback / presets / home | Not implemented. **No way to restore a framing in software.** |
| ❌ Motion events | [Structurally impossible over ONVIF](docs/ai-and-events.md) — no pull-point subscription |
| ❌ AI detection / auto-tracking | Exists in hardware, [reachable only over the vendor P2P channel](docs/ai-and-events.md#where-the-features-actually-live) |
| ❌ Reboot | ONVIF `SystemReboot` is a **no-op**; only a power cycle restarts these |
| ❌ Authentication | On anything. See [security.md](docs/security.md) |

## The two cameras

| | `icam365-01` | `icam365-02` |
|---|---|---|
| Address | `192.168.1.21` | `192.168.1.23` (reservation) |
| MAC | `AA:BB:CC:DD:EE:01` | `AA:BB:CC:DD:EE:02` |
| ONVIF `unique_id` | `3a80ec:…:3a80f1` | `3ab284:…:3ab289` |
| Firmware | `57.0.8.0` | `57.0.2.0` — **older** |
| Paired | 2024, **phone app, with cloud access** | today, **local `/setwifi`, `userid:"0"`** |
| **Role** | 🔴 **production — going outside, by the cars** | 🧪 **lab — expendable** |
| Extra open port | — | `3576`, purpose unknown |
| Aim | untouched — **PTZ allowed, but deliberate** ([why](docs/ptz.md#ptz-on-icam365-01-allowed-deliberately-jp-2026-08-06)) | ⚠️ needs physical re-aiming after PTZ testing |

> ⚠️ **Identify these cameras by `unique_id`, never by serial or by "cam #N".**
>
> **Both units report the same placeholder serial** (`12345679890`), so the serial distinguishes
> nothing.
>
> And the informal numbering is **inconsistent across the source notes** — the same physical
> camera has been called "cam #2" and "cam #1" in different sessions, and the newly provisioned
> one has been both "cam #3" and "cam #2". The `unique_id` and the HA entry name are the only
> stable handles. This page uses those.

### 🔴 Operational rules — `icam365-01` is production

**`icam365-01` is the camera going outside, up by the cars.** `icam365-02` is the lab unit.
That division was ambiguous in the source notes and has been settled explicitly, because it
decides which unit the destructive findings apply to.

Four rules follow, and a future reader will otherwise violate all of them:

* **PTZ on `icam365-01`: deliberate, never casual.** The aim is [irreversible](docs/ptz.md) and
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
| `icam365-01` | 2024, **phone app, with cloud** | **Yes** — through every power cut since. **[I]** |
| `icam365-02` | today, **locally, no cloud bind** | **No** — [confirmed on a single clean flip](docs/provisioning.md#-answered-it-is-not-durable-confirmed). **[M]** |

So the constraint is real, and it has a usable shape:

> **These cameras need one supervised, internet-connected app pairing before they can live on an
> isolated VLAN.** Local `/setwifi` works, but produces a camera that forgets on every power cut.

> ✅ **This retroactively validates sending `icam365-01` outside.** Had the lab unit gone up by
> the cars, the first power blip would have orphaned it — at the top of a ladder, looking like
> dead hardware.

> ⚠️ **The `icam365-01` row stays inferred.** Nobody is power-cycling the production camera to
> confirm it: a negative result would mean having broken it to learn that. Its 2024 history is
> good enough to act on and is **not** a measurement.

## Identity, such as it is

Every identifying field is a placeholder, which is typical of a white-label OEM that expects the
phone app to supply identity:

| Field | Value |
|---|---|
| Manufacturer | `EYEPLUS` |
| Model | `EYEPLUS_DEV` (literally "dev") |
| Serial | `12345679890` — **the same on both units** |
| HardwareId | `88` |
| Hostname | `localhost` |
| ONVIF scopes | empty |
| HTTP server | `Ginatex-HTTPServer` |
| RTSP server | `TAS-Tech Streaming Server V100R001` |
| API server (`:8001`) | `TAS-Tech IPCam` |

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
| [docs/security.md](docs/security.md) | 🔴 **Read first** — unauthenticated credential disclosure |
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
  **Tange/ThroughTek running TUTK**. Do not assume they share a protocol because both use UDP
  32100 — that conflation has already cost this project time twice.

## A note on addresses

Addresses, SSIDs, MACs and device UIDs throughout this repo are **generic stand-ins**. The
structure and the findings are real; only the identifiers are substituted, so the repo can be
published without further work. **Credentials are never recorded here at all**, including the
one the cameras leak.
