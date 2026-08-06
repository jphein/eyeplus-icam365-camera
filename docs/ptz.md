# PTZ

PTZ works. It does **not** work the way ONVIF clients expect, and testing it is destructive.

> ## ⚠️⚠️ PTZ testing permanently destroys a camera's aim
>
> There is **no absolute positioning, no presets and no home command** on this firmware. Once
> you move a camera, **there is no way to put it back** except by hand, on a ladder.
>
> This is not hypothetical — one camera was left mis-aimed by exactly this and needs physical
> re-aiming. Compensating moves in the opposite direction are *not* a return to origin; the
> steps are not calibrated.
>
> **Before testing PTZ on a camera that is aimed at something on purpose, don't.** Test on one
> whose framing does not matter yet.
>
> **Concretely, in this setup: never send PTZ to `icam365-01`.** It is the production unit going
> outside by the cars, where re-aiming means a ladder. `icam365-02` is the lab camera — do
> destructive work there.

## What works

**ONVIF `ContinuousMove`** — verified to *physically move the camera*, by image differencing
rather than by trusting an HTTP 200: mean absolute difference on a 64×36 greyscale frame was
**88.6** for a pan and **44.9** for a tilt, against a measured scene-noise floor of **2.8**. [M]

```bash
curl -s --noproxy '*' -X POST \
  -H 'Content-Type: application/soap+xml; charset=utf-8' \
  --data-binary '<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"
            xmlns:tt="http://www.onvif.org/ver10/schema">
 <s:Body>
  <tptz:ContinuousMove>
   <tptz:ProfileToken>Profile_1</tptz:ProfileToken>
   <tptz:Velocity><tt:PanTilt x="0.5" y="0.0"/></tptz:Velocity>
  </tptz:ContinuousMove>
 </s:Body>
</s:Envelope>' \
  http://192.168.1.21/onvif/device_service
# → <tptz:ContinuousMoveResponse/>

```

No authentication. `x` = pan, `y` = tilt, with standard ONVIF sign semantics (**x > 0 = right,
y > 0 = up**). Profile tokens are `Profile_1` (main) and `Profile_2` (sub). The URL path is
[ignored](onvif.md#the-server-ignores-url-paths).

### It is not actually continuous, and you must not send `Stop`

Despite the operation name, a `ContinuousMove` here is a **fixed-size step that self-terminates**.
Sampling frames after a single command gave diffs of **50.1 → 1.8 → 4.8 → 1.5** over ~14 s — it
finishes within roughly 2–5 s and then stays put.

That is fortunate, because **`Stop` returns `ter:ActionNotSupported`**. On a genuinely continuous
implementation this combination would mean a camera that spins until it hits a limit.

## No position feedback, no presets, no home

`GetStatus`, `GetPresets`, `GotoPreset` and `GotoHomePosition` are all `ActionNotSupported`;
`AbsoluteMove` and `RelativeMove` are HTTP 400. The
[full matrix is in onvif.md](onvif.md#ptz).

Consequences worth stating plainly:

* **You cannot ask where the camera is pointing.**
* **You cannot send it to a known framing.**
* If anything nudges it — wind, a knock, a curious agent — recovery is manual.

## From Home Assistant: use `onvif.ptz`

```yaml
service: onvif.ptz
target: {entity_id: camera.icam365_02_mainstream}
data: {pan: RIGHT, move_mode: ContinuousMove, continuous_duration: 1}
```

**Measured working**, again by image change rather than HTTP status: view change **59.88**
against ~3 noise. [M]

> **This corrects an earlier conclusion in this project.** It was originally reasoned that
> because `GetNodes` and `GetConfigurations` return HTTP 400, HA could not build a PTZ capability
> model and `onvif.ptz` would be unusable — so raw SOAP via `rest_command` was the recommended
> path. **That inference was wrong and was superseded by measurement.** `onvif.ptz` works.
>
> Also worth correcting, because it was used as supporting evidence: **HA's ONVIF integration
> never creates PTZ *entities* for any camera.** PTZ is service-only. "No PTZ entities appeared"
> was therefore never evidence of anything.

**Keep a raw-SOAP `rest_command` only for diagonal moves** — one call setting both `x` and `y` —
which `onvif.ptz` cannot express. Measured working at view change **68.12**. [M]

## The vendor PTZ endpoint — direction map unknown

`GET http://<camera>:8001/ptzctrl?act=<N>` returns **HTTP 200, body `OK`**, for every `N` in
0–11. Present on both cameras, no authentication. Bare `/ptzctrl` with no parameters gives
`400 Bad Request`. Codes 0, 1 and 3–11 produce large measured view changes, so they really do
move it. [M]

> ⚠️ **Which `act` code means which direction is unknown, and is deliberately not guessed here.**
>
> An attempt to recover directions by finding the pixel shift that best re-aligns before/after
> frames **saturated**: the steps are large enough that consecutive frames barely overlap, so the
> search clipped at its ±14 px bound with residuals of 33–109 against a 6.2 noise baseline. The
> resulting direction table was **discarded as untrustworthy** rather than published.
>
> The cheap reliable way to map them is a **human eyeball** — put a live view on screen, issue
> one `act=N` at a time, and have someone say what happened. About two minutes of a person's
> time, and it produces a real map.

**Until then, prefer ONVIF `ContinuousMove`**, whose x/y sign semantics are defined by the spec
and therefore directionally meaningful without any reverse engineering.

> ⚠️ **`act=99` — an invalid code — also returns `200 OK`.** On this firmware family a 200 means
> *"request parsed"*, not *"request honoured"*. This is the same trap as
> [`/setwifi` returning 200 for a setting that does not persist](provisioning.md#-a-200-does-not-mean-it-worked).

## See also

* [onvif.md](onvif.md) — full support matrix and the self-report problems
* [vendor-api.md](vendor-api.md) — the rest of the `:8001` surface
* [home-assistant.md](home-assistant.md) — wiring PTZ into HA
