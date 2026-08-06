# EYEPLUS / iCam365 ONVIF camera

Notes on a cheap white-label ONVIF pan/tilt camera, running locally in Home Assistant with
its cloud blocked. Bought and first set up **2024-09-22**; revived and documented **2026-08-05**.

"iCam365" is the name on the box and the app; the hardware identifies itself as **EYEPLUS**.

## Verified configuration

Confirmed against the live camera on 2026-08-06.

| | |
|---|---|
| Address | `192.168.1.21` — camera VLAN, static DHCP reservation `icam365-01` |
| MAC | `a8:4f:a4:df:d6:3f` |
| SSID | `iot` (2.4 GHz), bridged to the camera VLAN |
| Main stream | `rtsp://192.168.1.21:554/0/av0` — **H.265** 1920×1080 @12 fps + PCM A-law |
| Sub stream | `rtsp://192.168.1.21:554/0/av1` — **H.265** 640×360 @12 fps + PCM A-law |
| ONVIF | `http://192.168.1.21/onvif/device_service` — **no authentication** |
| Open ports | 80, 554, 8001 only. No telnet, no SSH, no snapshot server |
| Cloud | PPPP on UDP 32100 — **blocked** at the firewall |

## Identity, such as it is

Every identifying field is a placeholder, which is typical of a white-label OEM that expects
the phone app to supply the identity:

| Field | Value |
|---|---|
| Manufacturer | `EYEPLUS` |
| Model | `EYEPLUS_DEV` (literally "dev") |
| Firmware | `57.0.8.0` (was `57.0.2.0` in 2024) |
| Serial | `12345679890` |
| HardwareId | `88` |
| Hostname | `localhost` |
| ONVIF scopes | empty |
| HTTP server | `Ginatex-HTTPServer` |
| RTSP server | `TAS-Tech Streaming Server V100R001` |
| API server (:8001) | `TAS-Tech IPCam` |

## ⚠️ Three traps

### ONVIF lies about the codec

`GetProfiles` reports **H264** for both encoders. Both streams are actually **H.265**. Verified
at the HLS layer, not inferred: this camera produces `CODECS="hev1.1.6.L63"` where a working
H.264 camera on the same system produces `avc1.4d0029`.

This matters because Chrome and Firefox on Linux have **no HEVC decoder**, so a Home Assistant
`picture-entity` card with `camera_view: "live"` renders a black tile. Use `camera_view: "auto"`,
which routes through `/api/camera_proxy` and is decoded server-side by ffmpeg. Getting the 1080p
stream into a Linux browser at all requires go2rtc **transcoding**, which costs real CPU per
viewer on the HA host.

### It reports a fake MAC that changes between ONVIF additions

Its ONVIF `unique_id` was `3ab284:3ab285:3ab286:3ab287:3ab288:3ab289` in 2024 and
`3a80ec:3a80ed:3a80ee:3a80ef:3a80f0:3a80f1` in 2026. Six *sequential six-character* values —
a MAC is six groups of **two**. It is a pointer formatted to look like a MAC.

Consequence: re-adding the camera to Home Assistant does **not** match the old `unique_id`, so
you get **new entity IDs** and the old ones are gone permanently. Grep your dashboards and
packages for references before deleting a config entry.

### The ONVIF integration cannot be reconfigured in place

`supports_reconfigure` is `false` for `onvif` on HA 2026.7.4 (verified, not assumed). The host
lives in the config entry's `data`, which the options flow cannot reach, and hand-editing
`.storage` on a running HA is silently overwritten by the in-memory cache. To move it to a new
address you must **delete and re-add** — which triggers the entity-ID problem above.

## Home Assistant

Entities (from the ONVIF integration):

- `camera.icam365_01_mainstream` — 1080p H.265
- `camera.icam365_01_substream` — 640×360 H.265, **this is the one on the dashboard**
- `button.icam365_01_reboot`, `button.icam365_01_set_system_date_and_time`
- `switch.icam365_01_autofocus`, `switch.icam365_01_ir_lamp`, `switch.icam365_01_wiper`

The dashboard card deliberately uses the **substream** with `camera_view: "auto"` — server-side
transcode is cheaper at 640×360, and it is a thumbnail. A markdown card sits beside it on the
board explaining this so nobody "fixes" it back to `live`.

## Cloud posture

Before being blocked it held live PPPP sessions on **UDP 32100** to Amazon, Tencent and Oracle
endpoints. The camera VLAN is now **default-deny to WAN** (the `cameras → wan` forwarding was
removed on the router), with DNS, DHCP and NTP to the router still permitted.

Local ONVIF and RTSP are unaffected. Anything that depended on the vendor cloud will not work,
which is the intended trade.

## Related

- [`anyka3918-gc1084-camera`](../anyka3918-gc1084-camera/) — the other hacked camera on this
  VLAN, with a full HTTP API reference
- [`ilnk-e27-bulb-camera`](../ilnk-e27-bulb-camera/) — an iLnkP2P bulb camera, same cloud
  protocol family (PPPP), provisioned locally without the vendor app
