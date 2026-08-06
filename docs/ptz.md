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
> whose framing does not matter yet — `icam365-02` is the lab camera, do exploratory work there.

### PTZ on `icam365-01`: allowed, deliberately (JP, 2026-08-06)

An earlier revision of this page said *"never send PTZ to `icam365-01`"*, and the HA dashboard
had its PTZ buttons removed to enforce it. **JP overrode that, and the controls are back.**

The reasoning is worth keeping, because it generalises: **a missing control does not read as
"protected", it reads as "broken".** Someone will conclude the integration failed and go
re-derive PTZ from scratch — or worse, wire up something unvetted. A working control with a
visible caution beside it is both safer and more honest than an absent one.

So the rule for `icam365-01` is **caution, not prohibition**:

* Move it **deliberately**, one step at a time, checking the snapshot tile after each step.
* Expect **no undo**. Everything in the box above still applies — re-aiming is by hand, and
  once the camera is mounted outside that means a ladder.
* Rehearse anything unfamiliar on `icam365-02` first.

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

> ### ✅ But the aim is recoverable — this page used to be too pessimistic
>
> It previously said recovery from a nudge is manual. **Measured: the camera drives to its
> mechanical limits, stops dead, and stays there** — no grind, no creep, no drift — and the
> traverse is highly repeatable: **pan 5.1 / 5.2 / 5.2 / 5.3 s, tilt 13.0 / 13.0 / 13.0 / 13.3 s.**
> [M]
>
> **So the limits are a commandable reference point, and `act=3` then `act=9` is a working "go to a
> known corner" macro.** It does not restore *your* framing, but it converts aim from
> **irreversible** to **repeatable** — which on an outdoor camera is the difference between a
> command and a ladder.
>
> ⚠️ **Timed presets remain infeasible**, now for three independent reasons: `<Timeout>` is
> ignored, ONVIF `Stop` is unsupported, and **there is no partial move to count** because every
> command runs to a stop. [M]

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
`400 Bad Request`. [M]

### ✅ The mover/non-mover map, measured properly

**Movers: `1, 3, 5, 7, 9, 10, 11`. Non-movers: `0, 2, 4, 6, 8`.** Each tested from **two opposite
corners**. [M]

**Pairs:** `act=1` ↔ `act=3` are opposite ends of **pan**; `act=7` ↔ `act=9` are opposite ends of
**tilt**. [M]

> ❌ **RETRACTED, twice, and the second retraction restored most of the first claim.**
>
> This page originally said *"codes 0, 1 and 3–11 produce large measured view changes"*. A later
> sweep reported **only 5 codes move** and retracted it. **That correction was itself wrong**, and
> the original was closer to the truth — right about `1,3,5,7,9,10,11`, wrong only about
> `0,4,6,8`.
>
> 🔴 **The mechanism is specific to this hardware and worth carrying:** *every act code drives to a
> hard mechanical limit in one command*, so **a code tested while the camera is already at that
> limit reads as "no motion" — indistinguishable from a dead code.** The flawed sweep ran the codes
> back-to-back, repeatedly testing each against a limit the previous code had just driven into.
> `act=5` is the proof: **struct-change 4.6 in the back-to-back sweep, 21.4 / 35.4 / 27.9 when
> retried from elsewhere.**
>
> **The fix is one line: re-park before every trial.** See
> [method.md](method.md) — on a device where commands saturate, a back-to-back sweep silently
> converts "at the end stop" into "does nothing".

> ❌ **Killed hypothesis, recorded because it looked right:** odd-moves/even-doesn't is exactly the
> shape of `2×direction + action` move/stop pairs, and a working vendor stop would have resurrected
> partial positioning. **Tested: `act=1` interrupted by `act=0` at 1.0 / 2.0 / 3.5 s produced
> 90 / 118 / 119 % of a full traverse** — a wrong-axis `act=2` control was identical. **Even codes
> are not stops.** [M]

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
