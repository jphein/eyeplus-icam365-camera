# CLAUDE.md — EYEPLUS / iCam365 cameras

Operating instructions for agents working in this repo. The findings live in
`README.md` and `docs/`; this file is about **how to work here without breaking
something**.

## Read this order, before touching anything

1. **[`docs/security.md`](docs/security.md)** — these cameras disclose their admin
   password to anyone who asks, unauthenticated. VLAN isolation is the only control.
2. **`README.md` § "The one thing to know"** — on this firmware family a `200` means
   *parsed*, not *honoured*. Six measured confirmations.
3. **[`docs/method.md`](docs/method.md)** — checks that pass while measuring the wrong
   thing. Read it before designing any experiment, not after one confuses you.

## 🔴 Hard rules

**`icam365-01` is production.** It goes outside, up by the cars, on a ladder.
`icam365-02` is the lab unit and is expendable — do destructive work there.

- **No power-cycle testing on `icam365-01`.**
- **No write-probing vendor ports on `icam365-01`.** A single stray byte to `:20202`
  knocks a camera off the network. Note `echo > /dev/tcp/host/port` **connects and
  writes a newline** — it is a port *write*, not a scan. That has already
  de-provisioned a device on this network.
- **Do not re-run `/setwifi` on `icam365-01`.** It would send `userid:"0"` over that
  unit's cloud binding, and its 2024 cloud pairing is the only reason it survives power
  cuts. Also note `/setwifi` is honoured in **AP mode** and *silently ignored* in
  **station mode** — every "it just works" note predates that discovery and was true
  only for the state it was tested in.
- **PTZ on `icam365-01` is allowed but deliberate.** The aim is irreversible and there
  is no position feedback, no presets and no home. Rehearse on `icam365-02`.
  The HA controls are present on purpose — JP restored them 2026-08-06 because a
  missing control reads as *broken*, not as *protected*. Do not remove them again.
- **Do not retire the legacy SSID** (`my-iot-ssid` in these notes). Both cameras are
  still on it and can only be re-provisioned from their own setup AP — retiring it
  costs a physical visit per unit.
- **Any WAN exception is scoped to `icam365-02`'s address only**, never the camera VLAN
  and never `icam365-01`. The VLAN is default-deny to WAN **by JP's explicit decision**;
  do not open it to make a cloud feature work. A previous scoped window was approved,
  used, closed and verified — match that discipline or don't open one.

## 🔴 Do not "fix" the codec lie

These cameras report `H264` while streaming **H.265**. HA's ONVIF integration only
builds camera entities for H264 profiles — so **the lie is the only reason any camera
entity exists.** Correcting it empties the dashboard, silently, with nothing in any log
to explain it.

This is the repo's signature hazard and it generalises: **a defect can be the
load-bearing member.** On the sibling Anyka camera, fixing *both* of two wrong sysfs
strings broke the IR-cut filter — fixing *one* would have worked. Thoroughness was the
harmful choice.

**Before repairing a wrong-looking path, establish what currently depends on it
failing.** If cameras vanish from HA after a firmware update, check the ONVIF codec
string before anything else.

## Verification discipline

**Verify effects, never statuses.** This is not a style preference here; every
self-report on these devices is wrong about something, and the wrong ones look identical
to the right ones.

- A `200`, an exit code, a `DrwAck` and "Rebooting in 90 seconds" all mean *the request
  was parsed*. `SystemReboot` returns that string and never reboots.
- ONVIF is right about resolution and wrong about codec; the SDP is the other way round.
  **No field can be trusted by association with another.**
- Config is not behaviour. A firewall rule that *reads* correct was only believed after
  observing zero inbound cloud packets for 60 s.
- **`nmap` is unreliable against these cameras** — one full sweep missed ports 80 and
  554 while both were in use. Probe named ports and confirm by connecting.
- **Identify cameras by the real MAC from the DHCP reservation or the AP association
  list.** ❌ **The advice to use ONVIF `unique_id` is RETRACTED (2026-08-06)** — it decodes
  to six *consecutive* integers each larger than `0xff`, so it is a formatted pointer, not
  a MAC, and **[I]** is plausibly a per-firmware constant. If so, every camera on the same
  firmware presents the same one. The serial is a shared placeholder (`12345679890`), and
  the informal "cam #N" numbering is inconsistent across source notes — the same physical
  camera has been called #1 and #2 in different sessions.

Label every claim **measured** or **inferred**. The `icam365-01` persistence row is
inferred on purpose — confirming it would mean breaking the production camera to learn
that it broke.

## One agent per camera

A physical device is not a repo. Two agents touching one camera do **not** conflict
loudly — they produce plausible data that means nothing. This has already cost this
project two discarded datasets on the sibling Anyka unit. **Snapshot GETs count as
interference too**, not just writes.

If another agent is working a camera, coordinate or wait. Announce writes.

## Repo conventions

- **Addresses, SSIDs, MACs and UIDs in this repo are generic stand-ins**, so it can be
  published without further work. **Credentials are never recorded here at all**,
  including the one the cameras leak. When you learn a real value, use it in the
  session and write the generic form to disk. Do not undo the scrub.
- Real addresses come from the DHCP reservations on the gateway or `realmwatch/fleet.yaml`
  (gitignored, identity-of-record for all nodes) — never from this repo.
- `docs/` holds current facts. `notes/` is session history, kept deliberately —
  **prefer `docs/` and don't "reconcile" notes into it.**
- **There is no git remote.** Commits are local only; nothing is backed up off this
  machine. Don't assume a push target exists.
- Conventional commits, small and recoverable. Use **`git commit -o <path>...`** rather
  than `git add` — with concurrent agents the index is shared and another agent's work
  will ride along under your message.
- **Retract to "unproven", not to "false".** Over-erasing has cost this project as much
  as over-claiming: a correct warning was deleted as stale scaffolding shortly before
  the regression it predicted. `docs/` already carries explicit ✅ RETRACTED entries —
  follow that pattern.

## Related, and do not conflate

- [`../ilnk-e27-bulb-camera/`](../ilnk-e27-bulb-camera/) — **a genuinely different
  device.** Beken/RT-Thread running **iLnkP2P**; these are Anyka-class Linux running
  **CS2 Network PPCS** (`libPPCS_API.so`, the PPPP family — *not* TUTK; corrected
  2026-08-06 from the decompiled app). ⚠️ **This makes them closer relatives than the
  old note claimed** — both are PPPP derivatives, so the **transport** genuinely does
  transfer. **Nothing above the transport does**, and the rule stands: a shared
  transport is not a shared device. Both talk UDP 32100 and neither used the vendor app, which has
  caused this conflation **twice**. A shared port number is not a shared protocol —
  tooling, framing and command IDs transfer in neither direction.
- [`../anyka3918-gc1084-camera/`](../anyka3918-gc1084-camera/) — the other hacked camera
  on this VLAN. Root shell, full HTTP API, and the source of the load-bearing-defect
  lesson above.
- Home Assistant config lives in **`~/Projects/ha`**, a separate repo. Camera-side work
  belongs here; HA entities, packages and dashboards belong there.
