# ONVIF

The cameras speak ONVIF on port 80 with **no authentication at all** — see
[security.md](security.md). This page is what the ONVIF surface actually supports, as opposed to
what it claims.

Everything below was measured against live cameras on **2026-08-06**, tagged **[M]** where it
was run and read, **[I]** where it is inference.

## ⚠️ Every self-report on this device is wrong about something

This is the single most useful thing to know about the ONVIF stack here. **Cross-check every
field independently; do not trust any of them by association.**

| Field | Claims | Actually | Verified by |
|---|---|---|---|
| `GetProfiles` → `Encoding` | `H264` | **H.265 (HEVC)** | `ffprobe`, and the SDP says `a=rtpmap:99 H265/90000` outright **[M]** |
| SDP `a=framesize:99` | `1280-720` | **1920×1080** | `ffprobe` **[M]** |
| ONVIF `Width`/`Height` | `1920×1080` | correct | — |
| Serial number | `12345679890` | placeholder — **both** cameras report it | **[M]** |
| Model | `EYEPLUS_DEV` | literally "dev" | — |
| `switch.*_wiper`, `*_autofocus` | exist | this camera has no wiper | generic boilerplate |
| `SystemReboot` | `Rebooting in 90 seconds` | **does not reboot** — see below | **[M]** |

Note the codec and framesize lies point in *opposite directions*: ONVIF is right about the
resolution and wrong about the codec, while the SDP is right about the codec and wrong about the
resolution. There is no single source to trust.

> **Identify these cameras by MAC, never by serial** — both units report the same placeholder
> serial.

### `SystemReboot` is a no-op

It returns `<tds:Message>Rebooting in 90 seconds` and then does nothing. One camera served
snapshots continuously for 5.5 minutes afterwards and its DHCP lease timestamp never changed.

**Only a power cycle restarts these cameras**, which also means the HA `button.*_reboot` entity
is almost certainly ineffective. **[I]** on the HA button specifically — the underlying ONVIF
call is measured dead, and the button is a thin wrapper over it.

## The server ignores URL paths

The ONVIF server **dispatches purely on the SOAP operation name in the body**. `GetDeviceInformation`
returns an identical valid response when POSTed to `/onvif/device_service`, `/onvif/device`,
`/onvif/Device` and `/onvif/services`.

> ⚠️ **Corollary, and it costs people a wrong turn: `400 Page not found` does not mean the path
> is wrong — it means the *operation* is unimplemented.** Do not go hunting for the "real" PTZ
> endpoint. `/onvif/PTZ` is not missing; `GetNodes` simply does not exist.

## Service discovery contradicts itself

The two discovery calls disagree about whether PTZ exists:

| Call | Reports |
|---|---|
| `GetServices` (ver20) | Device, Media, Events, Imaging, DeviceIO, Analytics — **no PTZ namespace** |
| `GetCapabilities` (ver10) | **includes** `<tt:PTZ><tt:XAddr>…/onvif/PTZ</tt:XAddr>` |

Combined with `GetNodes` and `GetConfigurations` both returning HTTP 400, a well-behaved ONVIF
client has every reason to conclude there is no usable PTZ.

**It concludes wrongly** — `ContinuousMove` works and physically moves the camera. See
[ptz.md](ptz.md).

## Support matrix

### PTZ

| Operation | Result |
|---|---|
| **`ContinuousMove`** | ✅ **works — physically moves the camera** |
| `GetServiceCapabilities` | OK (stub response) |
| `GetNodes` | HTTP 400 — not implemented |
| `GetConfigurations` | HTTP 400 — not implemented |
| `RelativeMove` | HTTP 400 — not implemented |
| `AbsoluteMove` | HTTP 400 — not implemented |
| `GetStatus` | `ter:ActionNotSupported` |
| `GetPresets` / `GotoPreset` | `ter:ActionNotSupported` |
| `GotoHomePosition` | `ter:ActionNotSupported` |
| `Stop` | `ter:ActionNotSupported` |

### Analytics and events

**All negative, and structurally so** — see [ai-and-events.md](ai-and-events.md).

| Operation | Result |
|---|---|
| `GetSupportedRules` | `ter:ActionNotSupported` |
| `GetRules` | `ter:ActionNotSupported` |
| `GetAnalyticsModules` | `ter:ActionNotSupported` |
| `GetVideoAnalyticsConfigurations` | `ter:ActionNotSupported` |
| `GetMetadataConfigurations` | OK — and self-reports **`<tt:Analytics>false</tt:Analytics>`** |
| **`GetEventProperties`** | **HTTP 400 — not implemented** |
| **`CreatePullPointSubscription`** | **HTTP 400 — not implemented** |

Those last two are the reason Home Assistant can never produce motion sensors for this camera.

## The ISAPI surface on port 80 is a dead end

Port 80 also exposes an ISAPI-shaped surface — `<ResponseStatus>` in namespace
`http://www.ginatex.com/ver10/XMLSchema`, i.e. a Hikvision-ISAPI clone. **It is unusable:**

* every path returns 401, and
* the server **closes the connection on any `Authorization:` header at all** — Basic gives an
  empty reply, Digest gives 401 even with correct credentials.

Do not spend time on it.

## Streams

| Stream | Path | Measured |
|---|---|---|
| Main | `rtsp://<camera>:554/0/av0` | **HEVC 1920×1080**, `pcm_alaw` audio — ⚠️ **~9.3 fps delivered**, drops whole GOPs |
| Sub | `rtsp://<camera>:554/0/av1` | **HEVC 640×360**, `pcm_alaw` audio — ✅ **12.35 fps, zero stalls** |

> ❌ **RETRACTED: "~12 fps" for both streams.** That is the *nominal* rate. Measured across three
> 30 s wall-clock captures: the substream delivers **12.35 fps with zero stalls**, keyframes every
> 2.00 s across 14 consecutive intervals; the mainstream delivers **9.29 / 9.26 fps**, loses about a
> quarter of its frames, and **drops whole GOPs** (10.0 s and 6.0 s keyframe gaps). **[I]** the
> cause is the 92–97 KB I-frame burst over WiFi — the substream's largest frame is 10.9 KB.
> **Prefer `/0/av1`.** [M]

`/0/video0` also yields the mainstream (loose path handling), but `/0/av1` does correctly select
the substream — so RTSP paths are *not* fully ignored, unlike the ONVIF endpoint. `/1/video1`
does not exist. The mainstream emits cosmetic `cu_qp_delta -79 outside valid range` decoder
warnings.

**There is no H.264 stream on this camera at all**, which rules out the usual "just use the
substream" workaround for browsers without an HEVC decoder. See
[home-assistant.md](home-assistant.md#live-view-in-a-linux-browser).

## Reproduction

```bash
# one-shot SOAP call — the URL path is ignored, only the body matters
curl -s --noproxy '*' -X POST \
  -H 'Content-Type: application/soap+xml; charset=utf-8' \
  --data-binary '<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
 <s:Body><tds:GetDeviceInformation/></s:Body>
</s:Envelope>' \
  http://192.168.1.21/onvif/device_service
```
