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
| 3576 | ? | Open on **at least two** units. Silent to everything. Purpose unknown |
| 6670 | vendor binary protocol | see below |
| 8001 | `TAS-Tech IPCam` | the two endpoints above |
| 20202 | HTTP | [`/setwifi` provisioning](provisioning.md) — **stays open after pairing** |

⚠️ **This used to read "identical surface except 3576, which only one has. Unexplained. [M]"**
— retracted. `3576` is open on **at least two** units [M], and **which unit the original note
meant is unrecoverable**, because the informal "cam #N" numbering is documented as inconsistent
across sessions. **The `[M]` was the worse error**: it presented an unrecoverable attribution as a
measurement.

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

> ### 🔴 `:6670` IS AN UNAUTHENTICATED DEBUG CONSOLE. The sweep below was wrong.
>
> **Measured 2026-08-06. The endianness retraction that briefly sat here is LIFTED** — big-endian
> was right all along, confirmed by five matching echoes (ids 1, 300, 814, 4096, 32800); LE-framed
> probes get a TCP reset. The real defect was simpler and worse:
>
> | packet | result |
> |---|---|
> | `00000008 00000001` — header only | **TCP RST, no reply** |
> | `0000000c 00000001 00000000` — **+4 payload bytes** | ✅ `unknown comd 1.` |
>
> **A message with no payload is answered with a reset.** The original sweep sent header-only
> frames, got RST for every id, and concluded the whole range was invalid.
>
> ### ❌ RETRACTED: "command ids 0–599 were swept and none is valid"
>
> **False. [M]** `id=2` dumps the **task table**, `id=3` dumps **semaphores with live kernel
> addresses**, `id=5` is **`redirectionOutput`**. Ids **6–14** return an empty reply with a clean
> EOF — a *third* response class, meaning recognised-but-needs-arguments. All of these sit inside
> the range recorded as swept.
>
> 🔴 **This is a diagnostic surface, not a data leak, and it outranks the credential disclosure in
> kind** — see [security.md](security.md). No authentication on any of it.
>
> **The task table is the most informative thing found on these cameras:**
>
> ```
> twd  tReboot  tNetIfDeamon  ctp  sddetectTask  tStatusCtrl
> tIcrCtrlThread  tMotDet  tSpeaker  tCmdServer
> thttp_thread  tONVIF_Initiate  tDhcp          (all pid=298)
> ```
>
> | thread | what it settles |
> |---|---|
> | **`tIcrCtrlThread`** | ICR = IR-Cut Removable. **IR-cut control exists and is driven internally.** The correct wording is *"the mechanism exists and is unreachable"*, never *"it does not exist"*. |
> | **`tSpeaker`** | A speaker thread runs. Corroborates the [physical inspection](../README.md#hardware-confirmed-by-looking-at-it). |
> | **`sddetectTask`** | SD support is in the firmware, despite ONVIF storage ops being unsupported. |
> | **`tReboot`** | A reboot task exists although ONVIF `SystemReboot` is a measured no-op — a **wiring gap in the ONVIF handler**, not an absent capability. |
> | **`twd`** | A watchdog, supporting the crash-plus-watchdog reading of the `:8001` overload incident. |
>
> ### ❌ RETRACTED within the hour: "this looks like VxWorks"
>
> The `tXxx` naming and `redirectionOutput` read as VxWorks idiom, and that was written here as an
> **[I]** with a warning that it would invalidate any Linux-shaped rooting plan. **Adjudicated
> and reversed the same afternoon — the evidence says Linux, and the headline argument was
> backwards:**
>
> * 🔑 **"All 14 threads share `pid=298`" is *Linux* semantics, not VxWorks.** Every thread of a
>   POSIX process shares the TGID, which is what `getpid()` returns — so a multithreaded Linux app
>   looks exactly like this. **Classic VxWorks has no PID concept at all**, only task IDs. The
>   observation offered as proof of VxWorks is proof of the opposite.
> * **All 14 names are ≤15 characters, the longest exactly 15** (`tONVIF_Initiate`) — precisely the
>   `pthread_setname_np()` limit of 16 bytes including NUL. VxWorks imposes no such bound.
> * The dump also carries `taskid=3869112` — the shape of a **`pthread_t`**, not a task index.
> * ONVIF reports interfaces as **`wlan0`/`eth0`** (cfg80211 naming); VxWorks uses `gei0`/`fei0`.
>   Weak on its own, being a self-report, but it points the same way.
>
> **The `tXxx` names are a developer's habit, not an API's requirement** — and the names say so
> themselves: `tNetIfDeamon` is *misspelled*, and `thttp_thread` carries both a `t` prefix and a
> `_thread` suffix. An OS convention would not be inconsistent with itself.
>
> ⚠️ **Still open, and stated rather than buried:** nobody has checked externally whether any
> VxWorks camera family presents `Ginatex-HTTPServer`/`TAS-Tech`. This rests on in-repo
> measurement plus reasoning, with no external corroboration.
>
> **Worth keeping as a method case.** A single striking observation (`tXxx`, one pid) produced a
> confident cross-cutting inference that was about to redirect a physical experiment — and it
> inverted on inspection. **The tell was that nobody had checked what the observation implied
> under the *other* hypothesis**, only that it fit the first one.
>
> ### The lesson that cost four months
>
> The original note said the id was *"checked against three different payloads"* — and **recorded
> no values.** A later attempt to re-adjudicate the framing from the record found the conclusion
> preserved and the evidence discarded, so the question could not be settled without going back to
> the hardware. **Three numbers would have cost nine characters.** Where a claim rests on a
> comparison, write down what was compared.

### 🔑 The header is **12 bytes**, not 8 — measured

The framing recorded below is incomplete. Measured against `id=1`, which has a *known* reply, so a
well-formed message is positively identifiable rather than inferred from silence: **[M]**

| payload bytes | `total_len` | result |
|---|---|---|
| 0, 1, 2, 3 | 8–11 | **TCP RST** |
| **4, 5, 6** | **12–14** | ✅ `unknown comd 1.` |

**A hard cutoff at exactly four.** So:

```
[4B BE total_len][4B BE command id][4B BE arg0][... optional further payload]
total_len >= 12
```

**[I]** `arg0` is a mandatory third header field, not "payload". That explains the original failed
sweep more cleanly than *"a payload is required"* did: **an 8-byte frame is not a short message, it
is an incomplete one.**

### ❌ RETRACTED: "ids 6–14 are recognised commands that need real arguments"

**Enumerated and refuted. [M]** Ten payload shapes on `id=6` — 1/4/8 NUL bytes, BE int, LE int,
`?`, `help`, `-h`, `usage`, `0xFFFFFFFF` — plus three shapes across ids 7–14. **Every one returned
an empty reply with a clean EOF. Not one error string, not one usage line.** Interleaved `id=1`
controls returned `unknown comd 1.` before, between and after, so this is **real silence from a
live socket**, not a dead connection.

**An argument-hungry command that never complains under ten inputs, including three help tokens, is
not the simplest explanation.** Retracted to unproven.

> 🔑 **The better hypothesis, and it is evidence-backed rather than a guess: their output goes to
> the debug console, not to the socket.**
>
> * **The recognised set is sparse, not a range** — `0, 1, 4` → `unknown comd`; `2, 3, 5, 6…14` →
>   recognised. **A bounds check cannot produce holes at 0, 1 and 4**, so those nine have genuine
>   per-id handler entries. [M]
> * Writing to the socket is clearly possible — `id=2` and `id=3` do it at length. [M]
> * **`id=5` is literally `redirectionOutput`.**
>
> A console whose commands print to serial, plus one command to redirect that output, is an
> entirely ordinary design. **So `redirectionOutput` is most likely the enabler for the other nine
> rather than one more command beside them.**
>
> ⚠️ `redirectionOutput` returns `-3` for `arg0 = 0` — **[I]** an *invalid target value* rather than
> a missing argument, i.e. the call was well-formed and the value rejected. Not yet actuated.

Framing was recorded as:

```
[4-byte big-endian total length][4-byte big-endian command id][payload]
```

It replies `unknown comd <id>` for ids it does not recognise, which confirmed the id is literally
the first 4 payload bytes read as a big-endian integer — checked against three different
payloads.

❌ **This paragraph is retracted — see the box above.** It used to read *"command ids 0–599 were
swept and none is valid, so the real ids are large or magic."* The ids were fine; the probe was
sending header-only frames, which this server answers with a TCP reset. Ids 2, 3 and 5 are live
and 6–14 are recognised. **Retained rather than deleted, because the reasoning it produced —
"the real ids must be large or magic" — is a good example of a sound inference from a broken
measurement.**

This is the most likely home of the vendor's real feature set — see
[ai-and-events.md](ai-and-events.md), where the decompiled app shows IOCTRL command numbers in
the hundreds and tens of thousands. ⚠️ **Do not read that as support for "large or magic"** —
that inference is retracted above; ids 2, 3 and 5 are live and the app's table belongs to a
different daemon anyway.

## Port 3576 — no information

One camera only. Silent to connect-only, to HTTP, to length-prefixed framing, and to zero
payloads. Nothing learned.
