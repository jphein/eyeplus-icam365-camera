# icam365-01 → Home Assistant wiring (Luna) — DONE

> ## ⚠️ Historical session log — one section has since been refuted
>
> This is kept as a record of how the work went, not as current reference. **Section 3's claim
> that the ONVIF `unique_id` "changes between additions" is WRONG** — it compared values from two
> *different cameras* and read the difference as one camera drifting. The id is a stable,
> deterministic per-device value, measured across a reboot and confirmed against HA's own stored
> entry. See [`../docs/home-assistant.md`](../docs/home-assistant.md#-retracted-the-fake-mac-changes-between-additions).
>
> The rest — the routing forensics in section 2 especially — still stands, and its lessons are
> worth reading. **For current facts, prefer [`../docs/`](../docs/).**
>
> Addresses, MACs and hostnames below are generic stand-ins.

2026-08-05, 17:43 → 18:05 PDT. Commit **b1077dd**, pushed to `origin/main` in `~/Projects/ha`.

## Outcome

| | |
|---|---|
| IP used | **192.168.1.21** (the reservation landed mid-task; `.224` is dead) |
| Config entry | **`01KZA98Z98RWZD7MKA59MQRNXC`**, state `loaded`, `disabled_by: null` |
| Stale entry | `01J8DZFFMFETQJ8ZTN5W42EC4M` (host 192.168.2.106) — **deleted** |
| Live entities | `camera.icam365_01_mainstream`, `camera.icam365_01_substream` (+ 2 buttons, 3 switches) |
| mainstream proxy | **HTTP 200**, 122195 / 115103 / 140102 bytes, JPEG 1920x1080 |
| substream proxy | **HTTP 200**, 28960 / 28689 / 31411 bytes, JPEG 640x360 |
| Card | `picture-entity` on the **substream**, `camera_view: "auto"`, section 0 "Live" |
| Mirror / audit | 0 drifted · **TOTAL GHOSTS: 0** |

Byte counts differ on every fetch → genuinely live frames, not a cached placeholder.
Visually confirmed too: real scene (workbench + monitors) with the camera's own
`2026-08-05 18:00:50` overlay matching wall-clock.

## 1. The camera moved to its reserved IP mid-task

At 17:43 only `.224` answered; by 17:52 only `.21` did. the router confirms:

```
/tmp/dhcp.leases: 1786020313 AA:BB:CC:DD:EE:01 192.168.1.21 icam365-01
ip neigh:  192.168.1.21  br-lan.10 lladdr AA:BB:CC:DD:EE:01 REACHABLE
           192.168.1.224 br-lan.10 FAILED        <-- old pool lease released
```

`.224` is genuinely gone, so writing it into HA would have broken immediately.

## 2. ⚠️ My first diagnosis was WRONG — recorded so nobody trusts the wrong half

I initially reported **"HA is wedged, mid-restart or resource-starved"** and said I had
*ruled out* the workstation's routing because cross-VLAN paths failed too. **Both halves of that
were wrong.** HA was `2026.7.4 RUNNING` the entire time and never restarted.

What actually happened — two independent faults stacking into a convincing impostor:

**Fault A — the workstation had lost the on-link route for its own LAN.**

```
$ ip route get 192.168.1.10
192.168.1.10 via 192.168.1.1 dev eth0     <-- same-subnet host, routed via the gateway
```

The address carries `noprefixroute`, so the kernel does not auto-add the subnet route;
NetworkManager owns it, and NM dropped it after a **false** address conflict:

```
Aug 05 17:42:53 the workstation NetworkManager: device (eth0): conflict detected for
                                       IP address 192.168.1.50 with host AA:BB:CC:DD:EE:F0
```

That MAC is the workstation's **own wlan0**, which briefly held 192.168.2.193 at 17:42:52 before
moving to a camera setup AP (`1786020172 AA:BB:CC:DD:EE:F0 192.168.2.193` in the router's
leases). No real duplicate host — router ARP shows `192.168.1.50 → AA:BB:CC:DD:EE:F1`
(the workstation's ethernet) and nothing else.

Effect: the workstation's traffic to VLAN6 hairpinned through the router while the peer replied
*directly* on-subnet. Asymmetric, so the router's conntrack never saw the return half
and dropped the data packets — while the handshake still half-completed, which is why
`nc -z` cheerfully reported "succeeded" on every port I tried. **`nc -z` success is not
evidence of a working path.**

**Why my cross-VLAN test misled me:** HA also has a leg on VLAN6, so whichever of its
four IPs I targeted, its reply to `192.168.1.50` went out **directly on VLAN6** and
bypassed the router. Every leg was therefore broken by the same the workstation fault. The camera
worked over that same VLAN10 path only because it has *no* VLAN6 leg, so its path was
symmetric. "Cross-VLAN works for host X but not host Y" did not mean what I assumed.

**Fault B — HA serves TLS on 8123 and I was probing `http://`.**

Once the route was restored, SSH worked instantly but `http://…:8123/api/` still
returned `000`. Not a failure — the wrong scheme. `https://` → `200 {"message": "API
running."}`. `000` from curl looks identical to "host is dead," which is exactly what
sold me on the wrong story.

**What broke the tie:** testing from a host that was *not* the workstation. From the router,
HA's SSH banner came back instantly (`SSH-2.0-OpenSSH_10.3`), and the router's conntrack
showed HA actively making outbound HTTPS/DNS connections — i.e. a completely healthy
host. That single third-party observation invalidated the whole "HA is wedged" theory.
I should have reached for it before reporting a blocker.

**Fix applied** (additive, transient, reversible, restores what NM should have installed):

```
sudo ip route add 192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50
```

**⚠️ This does NOT survive a reboot or an NM reactivation** — it is a runtime route
only. JP should decide the durable fix (NM connection reactivation, or stopping the
wifi NIC from ACD-conflicting with the wired leg). Worth knowing: the camera setup AP
hands out addresses from a range that is **publicly allocated but used as if private**, so
a `NO_PROXY` rule written for `192.168/16` does not cover it and traffic you expect to
bypass a proxy quietly does not.

### ⚠️ the workstation has NOT "recovered on its own" — that route is still mine (checked 18:12)

The lead reported the route was back and the problem self-healed. It is back because I
added it, and nothing has taken ownership of it since:

```
$ journalctl -u NetworkManager --since 17:50 | grep -iE 'route|conflict|acd'
(nothing)
$ journalctl --since 17:50 | grep 'ip route'
Aug 05 17:57:13 the workstation sudo[473213]: jp : COMMAND=/usr/sbin/ip route add
                 192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50
```

NM logged **no** route activity at all — the single route-add event in the whole window
is mine. `nmcli` does now list `IP4.ROUTE[2]: dst = 192.168.1.0/24` where before it listed
only the default, but that is NM *observing* an external route in the kernel, not NM
owning one. The address still carries **`noprefixroute`**, so the kernel will never
recreate this route by itself.

Net effect: the fix is one reboot — or one `nmcli con up` — from vanishing, and the
symptom on its return is the very confusing "TCP connects, nothing comes back, `nc -z`
says the port is fine". Whoever hits it next will re-derive this from scratch. Wifi is
currently parked on a camera setup AP, so the ACD trigger is dormant, but it
re-arms the moment wifi rejoins a homelab VLAN and picks up a 10.x lease.

### Corollary: HA was never overloaded either

The lead's theory was that HA's SSH addon was refusing banner exchange under concurrent
agent load and then recovered at 18:08. The timeline rules that out:

- During the supposed wedge, the router got HA's SSH banner **instantly**
  (`SSH-2.0-OpenSSH_10.3`) and HA held 105 conntrack entries doing outbound HTTPS/DNS.
  A host too busy to answer does not answer a third party instantly.
- `ssh ha` started working at **17:57:13**, in the same command that added the route —
  eleven minutes before the 18:08 "recovery" was observed. Nothing about HA changed at
  17:57; only the workstation's routing table did.

So there is no evidence that concurrent agent load wedges this HA instance. Backing off
under contention is still fine practice, but it should not be adopted on the strength of
this incident.

I never restarted HA, per the brief.

## 3. ❌ REFUTED — "the ONVIF `unique_id` is not stable"

> **This section's central claim is false.** The `unique_id` *is* stable per device; the two
> values below are **two different cameras**, not one camera changing. Everything in this section
> that follows from "the id changed" is therefore wrong, including the prohibition on
> delete-and-re-add. The `supports_reconfigure: false` finding is unaffected and was later
> re-confirmed. Corrected in
> [`../docs/home-assistant.md`](../docs/home-assistant.md#-retracted-the-fake-mac-changes-between-additions).

`supports_reconfigure` is **`false`** for the `onvif` domain on HA 2026.7.4 — verified
via `config_entries/get`, not assumed. So option (a) in the brief does not exist and
`data.host` cannot be moved.

Option (b) then behaved worse than hoped. The brief expected re-adding to restore the
same entity_ids. It did not, because the camera reports a bogus MAC that **changes
between additions**:

```
2024-09 entry: 3ab284:3ab285:3ab286:3ab287:3ab288:3ab289
2026-08 entry: 3a80ec:3a80ed:3a80ee:3a80ef:3a80f0:3a80f1
```

Six *sequential* six-char values — a MAC is six groups of **two**. This is a pointer or
buffer address being formatted as a MAC, so it varies per boot/firmware. The unique_id
therefore did not match, no in-place update happened, and a fresh entry was created.

**Good news on the brief's specific worry:** the new entities are **not** `_2`-suffixed.
The name slug differs (`icam365_01` vs the old `icam36501`), so they are clean:
`camera.icam365_01_mainstream` / `_substream`. But the old `camera.icam36501_*` ids are
**gone for good** — I deleted that entry only after confirming (grep over `dashboards/`
and `packages/`) that nothing referenced them, so no ghosts were created. Audit agrees:
0.

It is the same physical camera, not a mix-up — the old device registry row read
`EYEPLUS / EYEPLUS_DEV / sw 57.0.2.0`, and the camera now reports firmware `57.0.8.0`.

The substream arrives `disabled_by: integration` (ONVIF's default); enabled via
`config/entity_registry/update {"disabled_by": null}` + config-entry reload,
`require_restart: false` — no HA restart needed.

## 4. Trap: both streams are H.265, and ONVIF lies about it

`GetProfiles` reports `Encoding: H264` for both encoders. False.

| Profile | `GetStreamUri` | ONVIF claims | ffprobe says |
|---|---|---|---|
| `Profile_1` mainStream | `rtsp://192.168.1.21:554/0/av0` | H264 1920x1080 | **hevc** 1920x1080 @12fps |
| `Profile_2` subStream | `rtsp://192.168.1.21:554/0/av1` | H264 640x360 | **hevc** 640x360 @12fps |

Both carry `pcm_alaw` audio. `/0/video0` also yields the mainstream (loose path
handling) but `/0/av1` *does* correctly select the substream, so paths are not fully
ignored. `/1/video1` does not exist. The mainstream emits cosmetic
`cu_qp_delta -79 outside valid range` decoder warnings.

So the brief's "prefer the substream if it is H.264" branch is unavailable — **there is
no H.264 stream on this camera at all.** And HA forwards HEVC to the browser untouched,
which I confirmed from the HLS master playlist rather than assuming:

```
icam365-01 substream : CODECS="hev1.1.6.L63"   <-- HEVC
camera.driveway      : CODECS="avc1.4d0029"    <-- H.264, and its live view works
```

Chrome and Firefox on Linux have no HEVC decoder, so `camera_view: live` would render a
black tile for JP. The card therefore uses **`camera_view: "auto"`** → `/api/camera_proxy`,
decoded to JPEG server-side by ffmpeg, which works in any browser; and the **substream**,
since 640x360 is far cheaper to transcode per frame than 1080p.

This is a deliberate deviation from section 0's `live` style. A markdown card sits next
to it saying exactly that, because the obvious tidy-up is to set it back.

## 5. Verification

- `dashboard_mirror.py --check` → **0 drifted**, 0 unmirrored
- `dashboard_audit.py --dashboard dashboard-dashboard` → **TOTAL GHOSTS: 0**
- `dashboard_assets_check.py` → my camera produces an image; the only failure is
  pre-existing `camera.uproad` (500), already documented in that view's own markdown
- Live board re-fetched over WS: card present, `camera_view: auto`, on the substream
- JSON written `indent=1, ensure_ascii=True` per the repo's encoding gotcha → clean
  13-line diff, zero formatting churn

## 6. Repo hygiene

Committed **only** `dashboards/dashboard-dashboard.dashboard.json` and
`docs/onvif-icam365.md` (new — both traps written up for the next person).

Left untouched, not mine: `dashboards/lights-tags.dashboard.json`,
`packages/anyka_camera.yaml`, `tools/vm_anyka_http.py` (untracked). Note the brief
warned about a dirty `sconce-panels.dashboard.json` — that one is actually clean; the
dirty files are the three above, two of which look like a sibling's in-flight Anyka
work, which the brief told me to stay off. Scratch build script is under
`scratch/` and gitignored, so it did not ride along.

Repo left on `main`, which is this repo's normal target (no feature branches exist).
