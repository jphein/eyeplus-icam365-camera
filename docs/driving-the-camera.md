# Driving an iCam365 / EYEPLUS camera over PPCS

**How to make these cameras do things that no open protocol on them can.** Everything here
was measured on the lab unit on 2026-08-06 unless marked otherwise.

| Label | Meaning |
|---|---|
| **[M]** | Measured on hardware |
| **[R-app]** | Read from the decompiled vendor app `com.tange365.icam365` **3.46.1** |
| **[I]** | Inference |

> ⚠️ **Constants are version-specific.** Pin the app version wherever you quote a command id.
> One id in the older repo notes (`798`/`796`) does not exist in 3.46.1 at all.

---

## 1. The stack, in one picture

```
F1 D0 <u16 BE size> | D1 <chan> <u16 BE index> | <u32 LE ioType><u32 LE len><payload>
└── PPPP session ──┘ └──── DRW sub-header ────┘ └──────── IOCTRL ────────────────────┘
      big-endian             big-endian                 LITTLE-endian
```

**Three layers, and the endianness flips at the third.** Not a typo.

* Transport is **CS2 Network "PPCS"** (`libPPCS_API.so`, `com.p2p.pppp_api`) — the **PPPP**
  family. **It is not TUTK**; the app contains no TUTK symbol at all.
* The application vocabulary (`IOTYPE_*`, `AVIOCTRLDEFs`, `Tcis_*`) is **TUTK's, copied**.
* Control is **channel 0**. Video, received audio and sent audio are other channels.

---

## 2. The session — five steps, one of which is easy to miss

```
1.  ->  F1 30 00 00                      LanSearch, UDP 32108   (NOT 32100)
2.  <-  MSG_PUNCH_PKT (0x41), 20-byte body        ** note the SOURCE PORT **
3.  ->  MSG_PUNCH_PKT, that body echoed back VERBATIM      <-- the missing step
4.  ->  MSG_P2P_RDY,   same body
5.  ->  DRW on channel 0, sequence index from 0
```

**Step 3 is load-bearing.** Without it the device never sets its session-up flag and
**drops DRW frames without even acking them**. [M]

> 🔑 **An absent `DrwAck` is the most useful diagnostic on this stack.** It separates
> *no session / wrong framing* from *session up, application layer declining*. Only the
> second makes any question about credentials meaningful.

**Echo the received 20 bytes verbatim** rather than re-encoding a parsed UID: the device
validates prefix, serial and check code with `strncmp`, and **a mismatch is dropped silently
with no reply and no error** — indistinguishable from sending nothing. [R]

⚠️ **The session dies after ~60 s of silence.** Pump `MSG_ALIVE` through every wait. A dead
session accepts commands and answers nothing, which looks exactly like *"the command had no
effect"*. **No ack, no verdict.**

⚠️ **Reply-port rotation.** The device answers from a rotating ephemeral port, *not* the port
you addressed. On-VLAN this is invisible. Across a stateful firewall the reply matches no
conntrack entry and is dropped — **the camera appears silent while answering in 2 ms.**
Workaround without touching the firewall: send a first datagram to that ephemeral port from
the same local socket to prime conntrack, then send the real request.

---

## 3. Authentication — required, and enforced device-side

Send **`32770 PASSWORD_REQ`** as the first IOCTRL. Payload is
`SMsgAVIoctrlExPassWordReq`: 60 bytes, password at **offset 8**, up to 48 bytes. The
credential is available unauthenticated over ONVIF `GetUsers`.

```
->  32770 PASSWORD_REQ      <-  32771 PASSWORD_RESP
```

### 🔑 The status decode — reusable for every command on this channel [M]

Unauthenticated, **every** command returns the generic wrapper `ioType 1`
(`TCI_CMD_SET_COMMAND_RESP`) carrying `[u32 LE echoed command][u32 LE status]`:

| status | meaning |
|---|---|
| **0** | **accepted** |
| **3** | **refused** |

Authenticated commands return **real typed `_RESP` ids** instead (`32790` → `32791`,
`32786` → `32787`, `32792` → `32793`, `1060` → `1061`).

> **`3` was identified as a refusal before its meaning was known**, purely because it was
> *constant across commands of incompatible shapes*: PTZ position (three floats), `DEVINFO`
> (a struct) and a light mode cannot all be the integer 3. `818` later returning `0`
> confirmed it.

> ❌ The published claim that this camera family **never verifies the password** (the
> "LookCam" precedent) is **[M] FALSE here.** No password and a wrong password both refuse.

---

## 4. What works

### 4.1 IR-cut filter / day-night — `32792` ✅ [M]

```
SET_DAYNIGHT (32792), payload SMsgAVIoctrlSetDoubleLightReq(mode)
    ->  ack 32793
    mode 2:  saturation 50.830 -> 0.000,  RGB (108.5,107.5,107.1) -> (98.67,98.67,98.67)
```

**R = G = B to two decimals** — the filter physically swinging out. ~**110×** above the
measured idle floor (0.46). Fully reversible.

| mode | effect [M] |
|---|---|
| **0** | **AUTO** — see the warning below |
| **1** | accepted, `GET` round-trips, no visible change in daylight |
| **2** | **night — IR-cut removed, monochrome, `sat = 0.000`** |
| 3 | rejected — acked, but `GET` still reports 2 |

> ⚠️ **Mode 0 is AUTO, not "day".** A unit at mode 0 will go monochrome by itself as light
> falls, correctly. **Verify restoration with the state read (`GET_DAYNIGHT == 0`), never
> with the picture.** The picture is the right instrument for *effects* and the wrong one for
> *residue* — exactly inverted from the usual rule, and a guaranteed false alarm at dusk.

Payload note: the **request** carries the mode at offset 4 (word[1]); the **response**
reports it at offset 8 (word[2]). **Request and response layouts differ.**

### 4.2 Two-way audio — `818` ✅ [M]

🔴 **`848 SPEAKERSTART` is the DEPRECATED path.** [R-app]

```java
public void startSpeaking()    { sendIOCtrl(818, AVStream(getSendAudioChannel(), 0)); }
public void startSpeakingOld() { sendIOCtrl(848, AVStream(getSendAudioChannel(), 0)); }
```

Anyone working from the constants table reaches for `848` — it is the one *named*
`SPEAKERSTART`. **Current firmware is driven with `818`, which the table names
`IOTYPE_USER_IPCAM_SETPASSWORD_REQ`.** The right command has an actively misleading name.

```
->  818, payload SMsgAVIoctrlAVStream(channel=5, 0)     ack (1,(818,0)) = accepted
->  raw G.711A frames, DRW on channel 5                 NOT IOCTRL on channel 0
->  849 SPEAKERSTOP
```

**Channel 5** = `chIndexForSendAudio` in the app, matching `AUDIO_SPEAKER_CHANNEL 5`.

Each frame is a **16-byte `SFrameInfo` header + A-law payload**, and this is the layout as
actually transmitted:

| offset | size | field | value used |
|---|---|---|---|
| 0 | 2 | `codec_id`, **uint16 LE** | **138** (`MEDIA_CODEC_AUDIO_G711A`) |
| 2 | 1 | `flags` | 0 |
| 3 | 1 | `cam_index` | 5 (the send-audio channel) |
| 4 | 1 | `online_num` | 0 |
| 5 | 3 | reserved | 0 |
| 8 | 4 | `frame_size`, **int32 LE** | length of the A-law payload |
| 12 | 4 | `timestamp`, **int32 LE** | `millis % 1_000_000` |

**8 kHz mono, 320 samples (40 ms) per frame, paced in real time.** That matches the camera's
own RTSP audio track (`pcm_alaw` 8000 Hz mono, ptime 40 ms) — two independent sources.

> ⚠️ **Do not read the field order off the decompiled class.** jadx sorts fields
> alphabetically, and `SFrameInfo` reads `cam_index, codec_id, flags, frame_size, onlineNum,
> reserved, timestamp` — a perfect A-to-Z run, which is the tell. **The order above comes
> from the body of `parseContent`**, which is authoritative. A struct with no such method has
> **no recoverable order at all** from a decompile.

### 4.3 Illuminators — `32788 SET_DOUBLELIGHT` ✅ [M]

**`SET_DOUBLELIGHT` (32788) drives a visible illuminator, and it works with the IR-cut
filter IN — night mode is NOT a precondition.** [M]

Scored by an observer watching the camera during two toggle blocks he knew nothing about:

```
BLOCK A  LED_STATUS  (1058):   17:13:17 - 17:14:11
BLOCK B  DOUBLELIGHT (32788):  17:14:22 - 17:15:17     <-- "it blinked like 3 times
                                                            a minute or so ago" @17:16:37
DAYNIGHT held at 0 (filter IN) for both blocks.
```

Three blinks matching three cycles, in the block that ended ~80 s before he spoke. He also
volunteered, unprompted, that the lamp was **white** — *"white led lights just went on"* —
a word nobody had put in his mouth; he had been briefed only for infrared through a phone.
And on a follow-up: *"i think it's just white lights, not white and ir."*

> 🔴 **The name lies. "DOUBLELIGHT" does not mean "both lights at once."** On the evidence it
> is **the dual-illuminator *selector*** — it chooses *which* emitter is active. A future
> reader will assume otherwise from the name, exactly as with the codec lie and the pointer
> that looks like a MAC.

| value | **[I]** reading |
|---|---|
| 0 | off / auto |
| 1 | **white floodlight** — observed, filter IN |
| **2** | the unit's **original** value; IR was seen during a separate sweep at `DAYNIGHT` 2 |

**[M]** for "32788 drives a visible white illuminator with the filter in".
**[I]** for the value→emitter mapping — one observation per condition is not a decoded enum.

> ✅ **This refutes a prediction I registered in advance**, and that is the point of having
> registered it. Before the observer spoke I wrote: *"setting `DAYNIGHT` to mode 2 may light
> the IR LEDs by itself… he should see a glow appear near the start of the window and vanish
> near the end, largely unmoved by the toggles in between"* — i.e. an illuminator bundled
> into night mode and not independently addressable. **The blink timing refuted it.** The
> illuminator is independently controllable, which is the better outcome. A prediction staked
> before the evidence and then overturned by it is worth more to a reader than one that
> merely survived.

### 4.4 Two negatives worth their own lines

**`SET_LED_STATUS` (1058) — ACCEPTED BUT INERT.** [M] Returns the generic wrapper with
**status `0` = accepted**, every time, and produced **no observed effect** in either block.

> **`accepted` is not `honoured`.** This is the repo's founding rule — a `200` means *parsed* —
> surfacing one layer deeper, inside the vendor protocol, on a channel that has an explicit
> success code. **A status field that says `0` is still only a claim about parsing.**
> Distinguish three classes, not two: *refused* (`3`), *accepted-and-inert* (`0`, nothing
> happens), *accepted-and-honoured* (`0`, the world changes).

**`SET_ALARMLIGHT` (1090) — NO ACK AT ALL.** [M] The **only** command all day to return
nothing on a demonstrably live session; commands either side acked normally. That is a
sharper clue than a generic timeout: the session was fine and this one command *vanished*.
Either unsupported on this hardware or the payload shape is wrong. **Unproven for 1090
specifically — not a session failure.**

---

## 5. Command table — the essentials

| id | name | notes |
|---|---|---|
| 1 | `TCI_CMD_SET_COMMAND_RESP` | generic wrapper: `[echoed][status]`, 0=ok 3=refused |
| 511 / 767 | `START` / `STOP` | video |
| **818** | *(named `SETPASSWORD_REQ`)* | **the real speaker-start** |
| 848 / 849 | `SPEAKERSTART` / `STOP` | **848 is deprecated** |
| 768 / 769 | `AUDIOSTART` / `STOP` | received audio |
| 8191 | `EVENT_REPORT` | device→client push; motion. Untested |
| 32770 / 32771 | `PASSWORD_REQ` / `_RESP` | **must be first** |
| 32786 / 32787 | `GET_DOUBLELIGHT` / `_RESP` | GET takes a zero-length payload |
| 32788 / 32789 | `SET_DOUBLELIGHT` / `_RESP` | |
| 32790 / 32791 | `GET_DAYNIGHT` / `_RESP` | |
| 32792 / 32793 | `SET_DAYNIGHT` / `_RESP` | **IR-cut control** |
| 1058 / 1060 | `SET` / `GET_LED_STATUS` | |
| 1032 / 1034 | `SET` / `GET_PTZ_POS` | absolute position exists over this channel |
| 824 / 822 | `ENTER` / `LEAVE_SETUP` | modal privileged state |

Full 187-id table in `tutk-command-table.md`.

⚠️ **Eight ids in 788–811 carry two unrelated meanings**, including `GETSUPPORTSTREAM` vs
**`SET_DEFENCE`** — a probe intended as a read may arm an alarm. Treat that range as
write-suspect.

---

## 6. The lessons that cost the most

Every one of these produced a clean-looking result that was wrong.

1. **A dead session looks exactly like a command with no effect.** One complete DAYNIGHT run
   reported `|dsat| = 0.041` and "✅ restored" — a tidy negative. Both SETs had returned *no
   response*; the session had timed out in a snapshot gap. **No ack, no verdict.**

2. **A threshold nobody calibrated is not a threshold.** An IR-LED "hit" at `luma +2.398`
   cleared a bar that was never measured — the idle floor had been established for
   *saturation*, then a *luma* number was compared against an invented figure. Proper A-B-A
   gave **−0.559 and +1.453** on repeat runs. **Calibrate the floor for the metric you are
   actually using.**

3. **A metric blind to the axis the effect lives on returns a confident false negative.** An
   earlier IR sweep used **greyscale** — and the entire IR-cut effect *is the loss of colour*.
   It could not have detected this if pointed straight at it.

4. **Silence across a stateful boundary is not evidence about the device.** The camera
   answered in 2 ms and the firewall ate the reply. **Capture at both ends, and put your own
   outbound packet in the capture as a positive control** — the first attempt showed *zero*
   packets, including the outbound, which is how the broken capture was caught rather than
   being read as a missing reply.

5. **A decompiler's field order is not the wire order.** jadx sorts alphabetically. Trust only
   a layout read from a method body.

6. 🔴 **The observer was making the signal.** A human reported hearing "music" and a spoken
   phrase during a speaker test. **Neither was ever transmitted** — the only audio sent was
   beeps and a tone. A second camera in the same room was playing MP3s, and the agents
   narrating the session speak aloud through the workstation's speakers.
   **Two contaminants, both real, neither tracked.**

   > **Enumerate every device capable of producing the signal *before* the test, not after a
   > report needs explaining.** And when a human is the instrument, make the observation
   > falsifiable *before* it is made: ask for **the pattern and the source and the time**, not
   > *"did you hear it?"* — the second question invites a yes. Anchor the transmission window
   > to the device's own monotonic uptime so "I heard it" becomes "I heard it inside the
   > three seconds it existed".

7. **Over-correction is also a failure mode.** After two false positives, verification was
   escalated past usefulness — further rounds were queued for something a person standing next
   to the device had already answered. **The point of a guard is to catch errors, not to make
   evidence unacceptable.** Calibration runs in both directions.

---

## 7. Reproducing

`icam365_p2p.py` (client, 63 offline tests) · `phase2_probe.py` (gated live probe) ·
`tutk-protocol.md` (full findings) · `tutk-command-table.md` (all 187 ids) ·
`tutk-public-prior-art.md` (transport research).

**Safety, and these are executable rather than documentation:** the client uses a
**fail-closed allowlist** — nothing is reachable until `grant(<host>)` names one target,
because a denylist fails *open* and the realistic failure on a VLAN of twelve near-identical
cameras is a one-octet typo. Port `20202` is refused unconditionally. **UIDs are scrubbed on
the way *into* the transcript** — a PPCS UID plus a password reaches the camera from anywhere
on the internet through the vendor cloud.

⚠️ **The UID is not an identity.** `TANGE-<serial>-<check>` is byte-identical across three
units spanning two product families — an unbound factory placeholder. The parse is confirmed
correct against the shipped library, so this is a genuinely shared value, not a mis-read.
**Nothing in the discovery reply identifies a camera.**
