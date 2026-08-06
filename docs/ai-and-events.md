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

## The P2P channel — a local session works with the cloud firewalled

**This is the significant result.** A live P2P session has been established against the camera
**with `cameras → wan` denied**, i.e. entirely on the LAN, with no vendor cloud involved. [M]

The handshake that works:

```
LanSearch          ->  device replies, UID TANGE-…
PunchPkt           ->  accepted
P2pRdy             ->  accepted
Drw ConnectUser    ->  acked        (0x2010, credentials recovered via GetUsers)
Drw DevStatus      ->  acked
P2PAlive           ->  keepalives flowing
```

### The ephemeral-port problem, and its solution

The camera's P2P socket sits on an **ephemeral port that rotates every few seconds** — observed
to move between sweeps, and again between a sweep and a client start. **[I]** the churn is
probably the camera restarting its blocked cloud connection in a loop.

That rotation is what makes this device look intractable: by the time you have scanned for the
port, it has moved.

> **The fix is to stop treating discovery and connection as separate steps.** Do discovery and
> the handshake **on one socket, in one continuous flow**, and take the port from the **source
> address of the device's own reply** rather than from a scan. The port never has a chance to
> rotate, because you never go back and look for it.

### Where it stops

**Session layer works; control layer does not.** Frames are acked and keepalives flow, but **no
`Drw` payload ever comes back** — so the camera accepts the transport and answers nothing at the
application layer.

> ⚠️ **`DrwAck` means "frame accepted", not "command understood".** This is
> [the same trap as the HTTP 200s](../README.md#the-one-thing-to-know), one layer down. An acked
> frame is not evidence the command was valid, parsed, or acted on.

**[I]** the grounded inference is that the inner IOCTRL framing is **TUTK AVAPI `IOTYPE_*`**
rather than the iLnk scheme used by public cam-reverse tooling — note that `0x8020` has the
**high bit set**, which is characteristic of the AVAPI numbering rather than a plain sequential
command id.

> ### ❌ RETRACTED to unproven 2026-08-06: "this is TUTK"
>
> **It is not TUTK.** The vendor app (`com.tange365.icam365` 3.46.1, decompiled) links
> **`libPPCS_API.so`** via `com.p2p.pppp_api.PPCS_APIs` — the **CS2 Network "PPCS" SDK**, of the
> **PPPP** family. Grepping all 17 DEX files for `TUTK`, `IOTCAPIs`, `AVAPIs`, `avSendIOCtrl` or
> `avClientStart` returns **nothing**. **[R-app]**
>
> It is a hybrid: **PPPP transport carrying TUTK's copied command vocabulary** (`IOTYPE_*`,
> `AVIOCTRLDEFs`, `Tcis_*`). **That is why the session layer worked on the first attempt** — it
> was PPPP all along, which is what the public cam-reverse tooling speaks.
>
> The `0x8020` reasoning above is retracted to *unproven, not false*: `0x8020` genuinely is
> `GET_MOTION_TRACKER_REQ`, but the high bit marks the vendor's **`USEREX` extension range**, not
> AVAPI numbering. Right value, wrong reason.
>
> 🔴 **This does NOT license conflating these cameras with the E27 bulb.** The refinement is
> precise: iLnkP2P and CS2/PPCS are both PPPP derivatives, so the **transport** genuinely does
> transfer — that is the honest reason a session came up. **Nothing above the transport does.**
> A shared transport is still not a shared device.
>
> ### 🔑 And it explains "acked but silent"
>
> The app's **first** command after connecting is **`32770` PASSWORD_REQ**, before `511 START`,
> `768 AUDIOSTART` and `800 SETSTREAMCTRL`. **[I]** the sessions recorded below were never
> authenticated at the application layer, so the camera parsed the frames — hence `DrwAck` — and
> answered none of them.
>
> **Third instance of this repo's signature trap, one layer deeper again:** `200` means parsed,
> `DrwAck` means the frame was accepted, and now **an established session is not an authorised
> session.**
>
> ⚠️ **Command-id collisions [R-app]:** eight ids in **788–811** carry two unrelated meanings,
> including `GETSUPPORTSTREAM` vs **`SET_DEFENCE`**. A probe intended as a *read* in that range
> may arm the alarm. Treat the whole range as write-suspect.
>
> ⚠️ **Constants are version-specific.** `EventDetect 798/796`, recorded elsewhere on this page,
> **does not appear anywhere in 3.46.1**. Retracted to *unproven, not false* — it may come from a
> different app version. Pin the version wherever a command table is quoted.

### The LAN channel is tractable. The cloud channel is not.

This is the useful division, and it was established by measurement rather than assumed. [M]

| Channel | State |
|---|---|
| **LAN control** | In the clear. Session established, frames acked, [reverse-engineerable](#where-it-stops) |
| **Cloud device-login** | **Genuinely encrypted** |

The cloud login frame — `0xF1F9`, 84-byte body, fixed ~29-byte prefix, varying tail, almost
certainly device-login-carrying-a-key — **does not decode at XQ rot 0/4/8**. It is not TLS, but
it is not merely obfuscated either.

> **An earlier working assumption is falsified by that.** The expectation was that the PPPP
> payloads were *obfuscated rather than encrypted*, and therefore that the whole stack was the
> tractable layer. **True for the LAN side, false for the cloud side.**
>
> **[I]** The pattern suggests the vendor encrypts **account-bearing** traffic while leaving
> device-local control in the clear — which is a coherent design choice, and good news for
> anything you want to do on your own network.

> **`0xF1F9` is absent from cam-reverse's message table**, which is a useful marker: it is
> roughly where the public prior art stops covering this device.

Full cloud transcript and what it means for pairing:
[provisioning.md](provisioning.md#-the-wan-window-was-run-the-cloud-bind-does-not-complete).

**This is a real reverse-engineering project, not a configuration task** — but it is no longer
blocked on the thing that looked like a wall. Port 6670, which
[speaks a length-prefixed binary protocol with large or magic command ids](vendor-api.md#port-6670--partially-reverse-engineered),
remains a parallel unturned stone; the command numbers above (814, 32800, …) are consistent with
its "ids are large" finding.

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
