# EYEPLUS / iCam365 ONVIF camera

Notes on cheap white-label ONVIF pan/tilt cameras, run locally in Home Assistant with their
cloud blocked. First set up **2024-09-22**; revived, reverse-engineered and documented across
**2026-08-05/06**.

"iCam365" is the name on the box and the app; the hardware identifies itself as **EYEPLUS**.

> 🔴 **These cameras leak their administrator password to anyone who asks, unauthenticated.**
> VLAN isolation is the only thing protecting them. **[Read security.md first.](docs/security.md)**

## What works

| | |
|---|---|
| ✅ Video | RTSP, no auth — **H.265 only**, 1080p main / 640×360 sub, ~12 fps + PCM A-law |
| ✅ Snapshots | [`:8001/snapshot`](docs/vendor-api.md#snapshot-is-the-most-useful-thing-on-these-cameras) — 640×360 JPEG, ~70 ms, no auth. **The best thing on these cameras.** |
| ✅ PTZ | ONVIF `ContinuousMove` and HA's `onvif.ptz` — [but testing it destroys the aim](docs/ptz.md) |
| ✅ Local provisioning | [No cloud account needed](docs/provisioning.md) |
| ✅ Availability monitoring | HA binary sensor + health sensor |
| ⚠️ WiFi persistence | [A power cycle has been seen to wipe it](docs/provisioning.md#-provisioning-does-not-reliably-survive-a-power-cycle) — **unresolved, and it blocks outdoor use** |
| ❌ Position feedback / presets / home | Not implemented. **No way to restore a framing in software.** |
| ❌ Motion events | [Structurally impossible over ONVIF](docs/ai-and-events.md) — no pull-point subscription |
| ❌ AI detection / auto-tracking | Exists in hardware, [reachable only over the vendor P2P channel](docs/ai-and-events.md#where-the-features-actually-live) |
| ❌ Reboot | ONVIF `SystemReboot` is a **no-op**; only a power cycle restarts these |
| ❌ Authentication | On anything. See [security.md](docs/security.md) |

## The two cameras

| | `icam365-01` | `icam365-02` |
|---|---|---|
| Address | `192.168.1.21` | `192.168.1.23` (reservation) |
| ONVIF `unique_id` | `3a80ec:…:3a80f1` | `3ab284:…:3ab289` |
| Firmware | `57.0.8.0` | `57.0.2.0` — **older** |
| Extra open port | — | `3576`, purpose unknown |
| Aim | untouched | ⚠️ **needs physical re-aiming** after PTZ testing |

> ⚠️ **Identify these cameras by `unique_id`, never by serial or by "cam #N".**
>
> **Both units report the same placeholder serial** (`12345679890`), so the serial distinguishes
> nothing.
>
> And the informal numbering is **inconsistent across the source notes** — the same physical
> camera has been called "cam #2" and "cam #1" in different sessions, and the newly provisioned
> one has been both "cam #3" and "cam #2". The `unique_id` and the HA entry name are the only
> stable handles. This page uses those.

### ❓ Open question: which camera goes outside?

The source notes disagree, and it is not resolvable from them. One says the **existing** camera
(`icam365-01`) is going up by the cars to replace a stalling unit; another says the **newly
provisioned** one (`icam365-02`) is. They were written using the ambiguous numbering above.

It matters, because two findings land differently depending on the answer:

* **`icam365-02` is the one that currently needs re-aiming**, and the one whose WiFi config was
  seen to vanish after a power cycle.
* An outdoor camera makes both the [PTZ irreversibility](docs/ptz.md) and the
  [provisioning-persistence blocker](docs/provisioning.md#-provisioning-does-not-reliably-survive-a-power-cycle)
  much more expensive — a ladder, rather than a reach.

**Resolve this before mounting anything.**

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

## Two habits this project keeps

**1. A `200` means "request parsed", not "request honoured."** `/setwifi` returned 200 for a
setting that did not persist; `/ptzctrl?act=99` returns 200 for an invalid action code;
`SystemReboot` returns a cheerful message and does not reboot. **Verify effects independently** —
PTZ was only believed after measuring image change against a noise floor, not after an HTTP 200.

**2. Every self-report on this device is wrong about something.** ONVIF is right about the
resolution and wrong about the codec; the SDP is right about the codec and wrong about the
resolution. **Cross-check each field on its own.**

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
* [`ilnk-e27-bulb-camera`](../ilnk-e27-bulb-camera/) — a P2P bulb camera. **Different vendor and
  stack** — do not assume these share a cloud protocol just because both use UDP 32100; that
  conflation has already cost time once.

## A note on addresses

Addresses, SSIDs, MACs and device UIDs throughout this repo are **generic stand-ins**. The
structure and the findings are real; only the identifiers are substituted, so the repo can be
published without further work. **Credentials are never recorded here at all**, including the
one the cameras leak.
