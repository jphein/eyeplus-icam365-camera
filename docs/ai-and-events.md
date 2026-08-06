# AI detection, auto-tracking and motion events

**Short version: the camera does all of it, and exposes none of it locally.** Every local
interface was checked and came back negative. The features exist, but only over the vendor's
cloud P2P channel.

## The measured negative

This is not "we could not find it" — it is a negative across every reachable surface, with the
camera itself declaring analytics unavailable. [M]

| Probe | Result |
|---|---|
| `GetSupportedRules` | `ter:ActionNotSupported` |
| `GetRules` | `ter:ActionNotSupported` |
| `GetAnalyticsModules` | `ter:ActionNotSupported` |
| `GetVideoAnalyticsConfigurations` | `ter:ActionNotSupported` |
| `GetMetadataConfigurations` | OK — self-reports **`<tt:Analytics>false</tt:Analytics>`** |
| **`GetEventProperties`** | **HTTP 400 — not implemented** |
| **`CreatePullPointSubscription`** | **HTTP 400 — not implemented** |
| RTSP SDP | video + audio tracks only — **no metadata/analytics track** |
| `:8001`, 4826 paths fuzzed | no AI, motion or event endpoint |

## Why Home Assistant will never show motion sensors for this camera

**HA's ONVIF integration builds motion binary sensors from an ONVIF pull-point event
subscription.** This camera returns HTTP 400 to both `GetEventProperties` and
`CreatePullPointSubscription`, so no subscription can be created.

> **This is a structural limitation, not a misconfiguration. There is no HA-side fix, and no
> amount of YAML will produce a motion sensor from this camera.**

[M] for the camera side — both calls measured. **[I]** for the exact HA code path, which was
reasoned from the integration's documented behaviour rather than instrumented.

## Where the features actually live

The vendor app does not talk HTTP to the camera for any of this. Transport is **IOCTRL messages
over a TUTK / ThroughTek P2P session** (`AVIOCTRLDEFs`), which is why nothing AI-shaped turned up
in an HTTP fuzz of 4826 paths — it was never going to.

From the decompiled app, the complete feature inventory of the hardware:

| Feature | get / set |
|---|---|
| **`AiDetect`** | 814 / 812 |
| **`MotionTrack`** (auto-tracking — the "AI frame thingy") | 32800 / 32802 |
| `MotionDetect` | 806 / 804 |
| `EventDetect` | 798 / 796 |
| `Ptz` | 4096 / 4097 get, 1032 / 1034 set |
| Preset, Cruise, Alarm, NightVision, Led, Speaker, Microphone, WiFi, Storage, Recording, Osd | — |

`AiDetectStatus` is a **`(mask, flags)` bitfield**, so detection is configurable per class rather
than a single on/off.

This table is worth keeping regardless of whether anything is built on it: it is the complete
list of what the hardware can do, and it says plainly that the camera supports far more than its
ONVIF surface admits.

## The P2P channel

The cameras **do answer a P2P LAN-search probe locally** and report a `TANGE-…` UID, so a local
client is conceivable rather than fantasy. [M]

But: the P2P socket sits on an **ephemeral port that rotates every few seconds** (observed to
move between sweeps and again between a sweep and a client start), which makes a stable client
hard to write. **[I]** the churn is probably the camera restarting its blocked cloud connection
in a loop.

**This is a real reverse-engineering project, not a configuration task.** Port 6670 — which
[speaks a length-prefixed binary protocol with large or magic command ids](vendor-api.md#port-6670--partially-reverse-engineered) —
is the most promising unturned stone, and the command numbers above (814, 32800, …) are
consistent with the "ids are large" finding there.

## What to do about driveway motion instead

Since the camera cannot provide a motion event, detection has to happen **on the consuming side,
from the video stream**. Options, honestly costed:

| Approach | Result | Cost |
|---|---|---|
| **Frigate on the substream** | Real object detection — "car", "person" — with proper HA binary sensors and snapshots | Needs CPU or an accelerator, and must decode **H.265** |
| `/snapshot` polling + image processing | Crude "something moved" | Very cheap, **no HEVC decode** (it is JPEG) — bad at ignoring trees and shadows |
| go2rtc restream → Frigate | One decode shared by several consumers | Middle |

**Recommendation: Frigate, on a host that already does this work — not on the Home Assistant
host.** Frigate already runs on a separate machine in this setup and publishes events to the HA
broker, which is where the H.265 decoding belongs. The HA host
[has no CPU headroom](home-assistant.md#live-view-in-a-linux-browser).

Use `/snapshot` polling as the fallback if that route is unavailable.
