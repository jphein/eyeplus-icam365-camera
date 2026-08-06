# Home Assistant integration

Both cameras are in HA via the **ONVIF** integration. What works, what cannot work, and the
traps — several of which were believed and later refuted, so read the corrections rather than
older notes.

## Entities

Per camera, from the ONVIF integration:

```
camera.icam365_0N_mainstream      1080p H.265
camera.icam365_0N_substream       640x360 H.265   (arrives disabled_by: integration)
button.icam365_0N_reboot          ⚠️ ineffective — SystemReboot is a no-op
button.icam365_0N_set_system_date_and_time
switch.icam365_0N_autofocus
switch.icam365_0N_ir_lamp
switch.icam365_0N_wiper           ⚠️ this camera has no wiper
```

**No PTZ entities, and no motion binary sensors.** Neither is a fault:

* **PTZ is service-only in HA's ONVIF integration** — it never creates PTZ entities for *any*
  camera. Absence of PTZ entities was once read as evidence this camera lacked PTZ; it is not
  evidence of anything. PTZ [works fine](ptz.md#from-home-assistant-use-onvifptz).
* **Motion sensors are structurally impossible here** — see
  [ai-and-events.md](ai-and-events.md#why-home-assistant-will-never-show-motion-sensors-for-this-camera).

The substream arrives `disabled_by: integration`; enable it with
`config/entity_registry/update {"disabled_by": null}` plus a config-entry reload —
`require_restart: false`, no HA restart needed.

## PTZ

Use the native service. [Full detail and the raw-SOAP alternative in ptz.md](ptz.md#from-home-assistant-use-onvifptz).

```yaml
service: onvif.ptz
target: {entity_id: camera.icam365_02_mainstream}
data: {pan: RIGHT, move_mode: ContinuousMove, continuous_duration: 1}
```

> ⚠️ **Read the [PTZ destructiveness warning](ptz.md) before wiring buttons a person can press.**
> There is no absolute positioning: any press permanently changes the camera's aim, and nothing
> can restore it in software.

### How to tell whether `onvif.ptz` will work, without moving the camera

Useful when the camera is one you cannot afford to re-aim. HA gates `ContinuousMove` on exactly
one thing: [M, read from source]

```python
if not profile.ptz or not profile.ptz.continuous:      # -> warns and returns, sends nothing
```

and `profile.ptz.continuous` is set **only** from `GetProfiles` →
`PTZConfiguration.DefaultContinuousPanTiltVelocitySpace is not None`. So a read-only
`GetProfiles` against the camera tells you whether the service will reach it.

Two things that look like evidence and are not:

* **`capabilities.ptz` proves nothing.** It comes from `self.device.get_definition("ptz")` — a
  **local WSDL lookup that never contacts the camera** — so it is effectively always true. Its
  presence is not support and its absence is not a diagnosis.
* **`move_mode: Stop` is useless as a probe.** `Stop` is `ActionNotSupported` on this firmware,
  so it cannot move the camera — but the call returns HTTP 200 and logs **nothing at any level**
  on a camera whose PTZ works perfectly. It distinguishes nothing.

> Also worth knowing when hunting for HA-side evidence: **`/api/error_log` is 404 on HA
> 2026.7.4**, and this install writes no `home-assistant.log`. The websocket
> `system_log/list` is the only view, and it holds **WARNING and above only**.

## Availability monitoring

`binary_sensor.icam365_0N_online` and `sensor.icam365_0N_health`, driven by a helper that
TCP-connects to ports 80, 554 and 8001.

> ⚠️ **The helper must always `exit 0`.** A `command_line` sensor that exits non-zero reads as
> *unavailable* in HA, which **hides the outage it exists to report**. Put the status in the JSON
> payload instead. (Verified: the helper returns exit 0 even when all three probes fail.)

This is the same pattern proven on the other camera project on this network.

## Live view in a Linux browser

**Recommendation: `/snapshot` tiles. Do not transcode on the HA host.**

The problem: both streams are **H.265 only** — there is no H.264 stream to fall back to — and
Chrome and Firefox on Linux have **no HEVC decoder**, so `camera_view: "live"` renders a black
tile.

| Option | Verdict |
|---|---|
| **[`:8001/snapshot`](vendor-api.md#snapshot-is-the-most-useful-thing-on-these-cameras) tile** | ✅ **~70 ms, ~9.8 KB, plain JPEG, no decode anywhere.** Works in any browser. Still image, not motion. |
| `camera_view: "auto"` on the substream | Works — server-side ffmpeg via `/api/camera_proxy`. Cheaper at 640×360 than at 1080p. |
| go2rtc transcode on the HA host | ❌ **Not affordable.** See below. |
| Restream from the Frigate host | ✅ For genuine live video — keeps HEVC cost off the HA host |

**Why not transcode on the HA host:** measured load average **3.23 on 4 cores** before adding
anything. A 1080p HEVC→H.264 transcode costs roughly a full core *per viewer*, so two open tiles
would saturate it. [M] on the load figure; **[I]** on the per-viewer core estimate, which is a
rule of thumb rather than a measurement taken here.

If a dashboard card uses `camera_view: "auto"` deliberately, **put a markdown card next to it
saying why** — otherwise the obvious tidy-up is to "fix" it back to `live` and reintroduce the
black tile.

## Traps

### 🔑 The codec lie is load-bearing — it is the only reason any camera entity exists

HA's ONVIF integration builds camera entities **only** for profiles that report H.264. From
`homeassistant/components/onvif/device.py`, `async_get_profiles`: [M, read from source]

```python
# Only add H264 profiles
if (not onvif_profile.VideoEncoderConfiguration
        or onvif_profile.VideoEncoderConfiguration.Encoding != "H264"):
    continue
```

These cameras **stream H.265 and report `H264`** — one of the
[five documented self-report lies](../README.md#the-one-thing-to-know).

> **If the firmware ever told the truth about its codec, HA would skip every profile and create
> no camera entities at all** — no cameras, no PTZ service target, no dashboard, nothing. The
> integration would appear simply to stop working, with no error explaining why.

So a firmware update that *fixes* the codec reporting is a **breaking** update here. If these
entities ever vanish after an update, check `GetProfiles` for `Encoding` before assuming the
integration or the camera has failed.

This is the same shape as the
[load-bearing dead path](../README.md#the-sibling-rule-learned-on-the-anyka-camera-a-broken-thing-may-be-load-bearing)
found on the Anyka the same day: **twice, on unrelated devices, a bug was the only reason
something worked.**

### ⚠️ The ONVIF integration cannot be reconfigured in place

`supports_reconfigure` is **`false`** for the `onvif` domain — confirmed twice, once from the
config entry and again verbatim in the `create_entry` result for a new entry. [M]

The host lives in the config entry's `data`, which the options flow cannot reach, and
hand-editing `.storage` on a running HA is silently overwritten by the in-memory cache.

> **So the address a camera is added on is permanent** unless you delete and re-add. Get the
> camera onto its **reserved** address *before* adding it — adding it on a temporary pool lease
> guarantees breakage at the next renewal.

### ✅ RETRACTED: "the fake MAC changes between additions"

This repo previously carried a prominent warning that the ONVIF `unique_id` **changes between
additions**, so deleting and re-adding a camera would orphan its entity IDs permanently. **That
was a misattribution and it is now refuted.** [M]

What actually happened: two values were compared that came from **two different cameras**, and
the difference was read as one camera drifting over time.

Measured:

| Camera | `unique_id` | Stability |
|---|---|---|
| `icam365-01` | `3a80ec:3a80ed:3a80ee:3a80ef:3a80f0:3a80f1` | stable over repeated calls |
| `icam365-02` | `3ab284:3ab285:3ab286:3ab287:3ab288:3ab289` | stable over repeated calls, **and byte-identical across a reboot plus a network change 35 minutes apart** |

### ❌ RETRACTED 2026-08-06: "deterministic per-device value … there is no collision"

This section concluded **"the id is a deterministic per-device value"** and therefore **"the two
cameras have different values, so there is no collision"**. The first half is right; **the second
is false, and acting on it would break a fleet.**

The claim rested on a **two-unit sample whose firmware also differed** (`57.0.8.0` vs `57.0.2.0`)
— two variables, one conclusion. A third unit separated them: **[M]**

| unit | real MAC (DHCP) | firmware | `unique_id` |
|---|---|---|---|
| `icam365-02` | `…:f7:bf:6d` | `57.0.2.0` | `3ab284:…:3ab289` |
| `icam365-wall` | `…:df:ac:2e` | `57.0.2.0` | **identical** |
| `icam365-01` | `…:df:d6:3f` | `57.0.8.0` | `3a80ec:…:3a80f1` |

**Two physically distinct cameras on the same firmware return byte-identical ids.** It is
deterministic *per build*, not per device — consistent with
[the value being a formatted pointer rather than a MAC](../README.md#-retracted-2026-08-06-identify-these-cameras-by-unique_id).
`GetDeviceInformation` corroborates: `SerialNumber` and `HardwareId` are identical across units
too, and an unrelated owner's `EYEPLUS_DEV` reports the same serial `12345679890` on a different
firmware major. **[R]** These are firmware-family constants.

### 🔴 What a collision actually does: a silent takeover, not a rejection

**This is the operationally dangerous part, and it is the opposite of what "already configured"
sounds like.** From the HA ONVIF integration source: **[M]**

```python
await self.async_set_unique_id(self.device_id, raise_on_progress=False)
self._abort_if_unique_id_configured(
    updates={CONF_HOST, CONF_PORT, CONF_NAME, CONF_USERNAME, CONF_PASSWORD})
```

Core's `_abort_if_unique_id_configured` **applies `updates` to the existing entry, schedules a
reload, and only then raises `already_configured`.** The stored entry data is exactly those five
fields — so `updates=` overwrites **every field the entry has.**

> **Adding a second camera on the same firmware overwrites the first camera's entry with the new
> camera's address and credentials, reloads it against the new camera, and reports "already
> configured".** The old entity IDs survive and now stream the **wrong camera**.

* The takeover happens **before** the H264-profile check, so the codec gate never protects you.
* The collision is at **three** levels: config-entry `unique_id`, device-registry `identifiers`
  **and** `connections`, and every entity `unique_id`. Only the first has any override path.
* `unique_id` falls back to **`SerialNumber`** when `HwAddress` is empty — and that is
  `12345679890` on every unit, so an empty HwAddress collides *everything* unconditionally.
* Sole visible symptom: the **device renames itself while entity IDs do not**. Name/entity
  disagreement is the fingerprint.

> **Same shape as `200 OK` and `DrwAck`, one layer up: `already_configured` means "a matching
> unique_id existed", not "nothing was changed."**

🔴 **Do not add another camera through the ONVIF integration.** For a fleet, key on
user-supplied config instead — a generic camera / go2rtc stream plus raw-SOAP `ContinuousMove`
for PTZ, which is already measured working. That cannot collide at any fleet size, and it takes
[the codec lie](../README.md#-and-it-already-applies-here-the-codec-lie-is-load-bearing) off the
critical path (keep the warning documented anyway). What is lost is the `onvif.*` entity services:
`reboot` (**[M]** ineffective here), `wiper` (**[M]** none fitted), `set_date_time`, `autofocus`,
and `ir_lamp` — **the last is the only plausible real loss; test it on a spare first.**

* ⚠️ **Delete-and-re-add is NOT safe on a fleet.** On a single camera it restores the same entity
  IDs; with two same-firmware units in play it is the exact mechanism above.
* 🔑 **But "the address is permanent" is also wrong** — `updates={CONF_HOST, …}` *is* an in-place
  host update, so re-running the config flow against **the same camera** at a new address moves it
  and preserves entity IDs. One mechanism, two faces: it repairs a moved camera and hijacks a
  second one.
* **DHCP address-recovery is dead here [M]:** `async_step_dhcp` matches on the *real* MAC, and the
  registry holds the pointer value instead.

**What has *not* been tested:** nobody has actually performed a delete-and-re-add. The
cross-reboot stability makes the old claim unlikely, but the direct test has not been run.

### The pseudo-MAC shape is still real

The value genuinely is not a MAC: **six sequential six-character values**, where a real MAC is
six groups of **two**. It is a pointer or buffer address formatted to look like a MAC. Worth
recognising — but it is stable, which is the part that matters.

Related: the config entry's own `unique_id` is `None`, and entity unique_ids are
`<pseudo-MAC>_<suffix>`.

### ⚠️ A package can be silently ignored in its entirety — cause unknown

**The symptom is real, nasty, and worth being able to recognise. The cause is not known.**

Observed: a package file was **deployed to the correct path, md5-verified intact, parsed with
the expected keys**, `check_config` returned `{"result":"valid"}`, **nothing was logged at any
level** — and **not one entity from any domain in that file existed.** Not just the scripts:
`rest_command:` and `command_line:` were missing too.

> **Symptom to recognise:** package deployed, config valid, no errors anywhere, and *none* of its
> entities exist. Do not go looking for a YAML error; there isn't one.

> ⚠️ **A cause was proposed here and has been retracted.** This section previously stated that
> declaring a top-level `script:` in a package conflicts with `configuration.yaml`'s
> `script: !include scripts.yaml` and causes HA to skip the file. **That is refuted** — another
> package on the same system declares a top-level `script:` and loads fine alongside exactly that
> include.
>
> The failing package had some *other* defect, and **the mechanism is undetermined**. The
> decisive experiment — re-add the block and bisect — has not been run.
>
> It is recorded as unexplained on purpose: **a plausible-but-wrong cause is worse than none**,
> because it sends the next person down a confident wrong path. This project has already lost
> hours to exactly that.

**Practical response while the cause is unknown:** if a package vanishes this way, bisect it —
halve the file, redeploy, see which half disappears. That finds the offending key without needing
a theory about why.

> **Diagnostic note:** `states('nonexistent.entity')` returns `unknown` — exactly like a real
> sensor that has not run yet. So "is it `unknown`?" **cannot** tell you whether an entity
> exists. Enumerate `states | map(attribute='entity_id')` instead.

### Renaming entity IDs is safe; it does not touch `unique_id`

A new config entry generated inconsistent entity ids (a stray location prefix, a missing
separator — cause not determined). Renaming them via `config/entity_registry/update` changes
**only** the `entity_id` and **not** the `unique_id`, so it does not interact with the
delete/re-add question at all.

## See also

* [ptz.md](ptz.md) — PTZ, and why testing it is destructive
* [ai-and-events.md](ai-and-events.md) — why there are no motion sensors, and what to do instead
* [security.md](security.md) — these cameras are unauthenticated
