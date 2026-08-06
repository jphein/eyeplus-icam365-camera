# The vendor API on port 8001, and the other ports

`Server: TAS-Tech IPCam`. Plain HTTP/1.1, **no authentication on anything**. `GET /` returns 404.

## The whole API is two endpoints

**4826 paths were fuzzed** (SecLists `common.txt` plus ~60 camera/PTZ/AI-specific guesses).
**Exactly two exist.** [M]

| Endpoint | Method | Result |
|---|---|---|
| **`/snapshot`** | GET | **200, `image/jpeg`, ~25 KB, 640×360 baseline JPEG.** No auth. Both cameras. |
| **`/ptzctrl?act=<0–11>`** | GET | **200, body `OK`.** No auth. Both cameras. [Direction map unknown](ptz.md#the-vendor-ptz-endpoint--direction-map-unknown). |

Everything else in 4826 paths returned 404 — **no AI, detection, motion, event, configuration or
authentication endpoint exists on `:8001`.** [M]

## `/snapshot` is the most useful thing on these cameras

```bash
curl -o frame.jpg http://192.168.1.21:8001/snapshot
```

**Measured cost: ~54–90 ms, ~9.8 KB per frame.** [M] Cheap enough to poll at 1–2 fps.

It matters more than a snapshot endpoint normally would, because it **sidesteps the HEVC
problem entirely**. These cameras emit H.265 only, which Chrome and Firefox on Linux cannot
decode, and transcoding costs about a core per viewer. A JPEG needs **no decoder and no
transcode** — so a dashboard tile fed from `/snapshot` works in any browser at essentially zero
CPU. See [home-assistant.md](home-assistant.md#live-view-in-a-linux-browser).

> **This corrects an earlier note** which recorded "no snapshot server" for these cameras. There
> is one, on both units.

## Port map

Measured on both cameras. A full 65535-port TCP sweep of one camera came back clean (65529
closed/reset, no ambiguous bucket); the other was confirmed by targeted probes. [M]

| Port | Service | Notes |
|---|---|---|
| 80 | `Ginatex-HTTPServer` | [ONVIF](onvif.md) + a dead [ISAPI-shaped surface](onvif.md#the-isapi-surface-on-port-80-is-a-dead-end) |
| 554 | `TAS-Tech Streaming Server V100R001` | RTSP, no auth |
| 3576 | ? | **one camera only.** Silent to everything. Purpose unknown |
| 6670 | vendor binary protocol | see below |
| 8001 | `TAS-Tech IPCam` | the two endpoints above |
| 20202 | HTTP | [`/setwifi` provisioning](provisioning.md) — **stays open after pairing** |

The two cameras have an identical surface **except 3576**, which only one has. Unexplained. [M]

> **An earlier note recorded "ports 80, 554, 8001" for one camera.** That is incomplete — it
> omits **6670** and **20202**.

## ⚠️ nmap is unreliable against these cameras

**Learned the hard way, twice.** [M]

* A `-p-` sweep of one camera returned "45226 filtered (no-response)" and reported only 6670 and
  20202 — **missing ports 80 and 554 that were actively in use minutes earlier**.
* An earlier full sweep in AP mode **missed port 20202 entirely** (retransmission cap).

These are WiFi-attached devices with a small network stack, and they drop probes under load.

**Always re-probe named ports directly and confirm by connecting. Never trust the "filtered"
bucket on this hardware** — and never conclude a port is closed from a sweep alone.

## Port 6670 — partially reverse-engineered

Framing is:

```
[4-byte big-endian total length][4-byte big-endian command id][payload]
```

It replies `unknown comd <id>` for ids it does not recognise, which confirmed the id is literally
the first 4 payload bytes read as a big-endian integer — checked against three different
payloads.

**Command ids 0–599 were swept and none is valid**, so the real ids are large or magic. Nothing
further was extracted.

This is the most likely home of the vendor's real feature set — see
[ai-and-events.md](ai-and-events.md), where the decompiled app shows IOCTRL command numbers in
the hundreds and tens of thousands, consistent with "large or magic".

## Port 3576 — no information

One camera only. Silent to connect-only, to HTTP, to length-prefixed framing, and to zero
payloads. Nothing learned.
