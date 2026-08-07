# Method hazards — checks that pass while measuring the wrong thing

This page is not about these cameras. It is about the ways the *investigation* went wrong, which
turned out to be more transferable than anything device-specific here.

The through-line of this project is stated in the [README](../README.md): **a `200` means
"request parsed", not "request honoured".** The same distrust has to be pointed at your own
instruments, because every failure below was a check that **reported success while measuring
something other than what it appeared to measure.**

---

## 🚫 `echo > /dev/tcp/host/port` is a port **write**, not a port scan

It connects **and sends a newline**. It reads as read-only and is not. See
[security.md](security.md) for what it did to a camera.

**Use instead:** `timeout 3 bash -c "exec 3<>/dev/tcp/host/port"` (connect, write nothing), or
`nc -z`. One port at a time.

**Why it is a rule and not a caution:** two different operators reached for the identical
construct against these cameras on the same day. One also aimed it at a device this project
already documents as dying from a *bare connect*, noticed the near-miss, and did not generalise
it to the technique. A hazard each person must re-derive is not a caution.

---

## 🚫 Any `-f` pattern match can match the process doing the matching

`pgrep -f 'tcpdump.*mycapture'` **matches its own command line** and reports the process as
running. So does `pkill -f`, which is how this first bit — it killed the shell that invoked it,
silently truncating two commands and losing a file append.

**It has now caught two different tools in one session**, so it belongs here as a general rule
rather than a footnote about `pkill`.

**Use instead:** the bracket trick — `pgrep -f '[t]cpdump'` — or match on a pid.

**The deeper fix is to stop checking the invocation and check the outcome.** "Is the process
running?" is a proxy question. "Does the output file exist, and is it *growing*?" is the real
one, and it is immune to this entire class of error:

```bash
ls -l capture.pcap; sleep 6; ls -l capture.pcap   # must grow
```

---

## 🚫 Backgrounding over SSH: `nohup … &` silently never runs

```bash
ssh root@host "nohup timeout 280 tcpdump -w /tmp/out.pcap … &"    # prints nothing, does nothing
```

The backgrounded child dies with the session and **the output file is never created.** Combined
with the `pgrep -f` trap above, this produced a capture that was confidently reported as running,
was not running, and had a "confirmation" to back it up. **An entire experiment was lost and
nearly written up as a result.**

**Use instead:**

```bash
ssh root@host "setsid sh -c 'exec timeout 900 tcpdump -U -w /tmp/out.pcap …' </dev/null >/dev/null 2>&1 &"
# then VERIFY the file exists and grows before believing the capture is live
```

Also: **write the capture to a file on the remote host and fetch it afterwards.** Streaming
`tcpdump -w -` over ssh silently dropped packets here and produced an empty capture that looked
like a meaningful negative result — "HA sent nothing to the camera" — which was false.

> ⚠️ `scp` does not work against OpenWrt (`/usr/libexec/sftp-server: not found`). Use
> `ssh host "cat /tmp/out.pcap" > local.pcap`.

> ⚠️ On Ubuntu, local `tcpdump -r` on a pcap under `$HOME` fails with `Permission denied` —
> that is **AppArmor**, not a corrupt capture. Read captures with `tshark`.

---

## 🚫 An instrument that is switched off looks exactly like a negative result

A WiFi scan for a camera's setup AP returned **zero networks**, and was very nearly filed as
"the camera is not broadcasting". The radio was **soft-blocked** — `nmcli radio wifi` disabled,
the interface `DOWN`, `ip link set … up` refused with `Operation not possible due to RF-kill`.

> **A scan from a disabled radio is indistinguishable from a scan that found nothing.**

Once the radio was enabled the AP appeared at **signal 100** — it had been there the whole time.

**Precondition check before trusting any WiFi negative:** `nmcli radio all`, and confirm the
interface is up. Generalise it: before recording an absence, confirm the instrument was capable
of detecting a presence.

---

## 🚫 Verify a revert by observing the effect, not by grepping for what you deleted

A DNS override redirecting the vendor's cloud names to a local address was recorded as
*"reverted and verified"*. **All three entries were still live**, pointing at an address where
nothing listened, so every cloud lookup the cameras made for a day was answered with a dead host.

It was found in a packet capture — the DNS *answers* came back wrong — not by re-reading the
config.

> **A grep for what you believe you deleted will agree with you.** Resolve the name and look at
> the answer.

The same shape as the [firewall closure check](../README.md#the-same-rule-one-level-up-config-is-not-behaviour),
which was verified three ways precisely because config is not behaviour. Removal deserves the
same standard as addition.

---

## ✅ The pattern, and the habit that catches all of it

Every failure above passed a check. In each case the check tested the *invocation* rather than
the *effect*:

| the check that passed | what it actually measured |
|---|---|
| `pgrep -f` found the process | its own command line |
| the ssh command returned cleanly | that ssh exited, not that anything ran |
| the WiFi scan returned no APs | that the radio was off |
| the config grep found nothing | the wrong string, or the wrong file |
| `success: true` from the API | that the request parsed |

**Habit:** after any action, verify by observing the thing you actually wanted to change —
re-fetch and diff the config, resolve the name, watch the file grow, measure the image
difference. It costs one extra command and it is the only check the device cannot lie about.

## 🚫 A decompiled struct's field order is **not** the wire order

Found while extracting the vendor protocol from `com.tange365.icam365` 3.46.1. **[M]**

**jadx lists class fields alphabetically.** So a decompiled struct hands you a field list that
looks exactly like a wire layout and is not one:

| `SFrameInfo` as decompiled | the real wire order |
|---|---|
| `cam_index, codec_id, flags, frame_size, onlineNum, reserved, timestamp` | `codec_id` at offset 0, `cam_index` at 3, `frame_size` at 8, `timestamp` at 12 |

**The tell is that the decompiled order is a perfect A-to-Z run.** Once you see it, it is obvious;
until you see it, the list is indistinguishable from the answer, and a struct parsed in that order
produces plausible garbage rather than an error.

**Only trust a layout recovered from a *method body*** — the code that actually reads or writes the
buffer, where offsets are explicit.

> 🔴 **And the harder case: a struct with no such method has no recoverable field order at all.**
> `SAvExEvent`, the motion-event payload, is exactly that. There is nothing to be careful with —
> the information is simply not in the decompile, and any ordering you assign is a guess wearing
> the costume of a finding. It has to be settled against captured bytes.

This is the same shape as everything else on this page, one layer further from the device: **the
field list looks like the answer.** Compare the ONVIF `HwAddress` that
[looks like a MAC and is a pointer](../README.md#-retracted-2026-08-06-identify-these-cameras-by-unique_id),
and `GetServiceCapabilities` returning `200` for a service
that does not exist because the dispatcher ignores namespaces.

**Habit:** when a decoded structure comes out *almost* sensible, suspect the layout before
suspecting the data.

## 🚫 A parse failure reports as a measurement

`<tt:HwAddress >` — this firmware emits a space inside the tag. A regex for `HwAddress>` matches
**nothing**, and a script that then compares the empty result against a stored value prints
`CHANGED`. **[M]** — this happened, and the false result was one step from being written down as
a finding about the camera.

**An empty match and a changed value are different outcomes and must not share a code path.**
Assert that the extraction found *something* before comparing it, and when a result is surprising,
look at the raw bytes before believing your own parser.

## 🚫 Clustered failures accuse the instrument, not the subject

**This fired twice in one hour, on two different people, with two different tools.** [M]

| | what the tool reported | what was true |
|---|---|---|
| Link checker A | **8 broken anchors** | 6 were the checker: it indexed `line.startswith('#')`, which silently skips **every heading nested in a blockquote** — and this repo puts its retraction headings exactly there |
| Link checker B | **24 broken anchors** | **all 24** were the checker: it stripped the leading hyphen from a slug, but GitHub *keeps* it when it removes an emoji, so every `#-retracted-…` link looked broken |

In both cases the tell was available before the report was filed: **the failures clustered.**
Several pointed at the *same* heading; a whole class of link failed and no other class did. Real
breakage is scattered, because it comes from unrelated edits. **A tidy pattern of failures is a
property of the checker.**

Had either been believed, the "fix" would have **broken working links to repair imaginary ones** —
a net loss delivered with a clean report and a passing exit code.

> **The habit:** when a check reports many failures at once, spend one command confirming the
> checker can *pass* — point it at something known-good and watch it succeed. That is the
> [armed-instrument rule](#-an-instrument-that-is-switched-off-looks-exactly-like-a-negative-result)
> applied to your own tooling rather than to the device.

**A citation is an instrument too.** The same audit carried two off-by-one line references, each
pointing at a plausible-looking neighbouring row — the kind of error that survives review precisely
because the wrong line still reads sensibly. Re-read a citation against the file *after* drafting,
not while.

## 🚫 The observer was making the signal

**The hardest confound of the day, and it came from our own tooling.** [M]

A speaker command was sent to a camera and a human reported hearing sound. It was recorded as a
confirmation — **twice**, and withdrawn twice.

| what was **sent** | what the human **heard** |
|---|---|
| three 1 kHz beeps + one 440 Hz tone. Nothing else — verified by reading the generator, not from memory | music, tones, **and a spoken phrase containing his own name** |

**Three sounds reported, one emitted.** At least two other sources were live in the same room: a
*different camera* whose speaker was being worked on in a parallel session, and — the
uncomfortable one — **the agents' own text-to-speech narration playing through the workstation
speakers a few metres away.**

> ### 🔑 Occurrence is not attribution. Verify **location**, not just that the signal happened.
>
> Every version of *"did you hear it?"*, and even *"what did you hear?"*, asks the wrong question.
> The right one is **"did it come from the camera, or from the computer?"** — and the cheap
> instrument is a person putting an ear next to the device.

**What made this genuinely hard is that the second claim looked airtight.** The reported phrase was
content that had *never been described to the listener* — apparently perfect unleakable evidence.
It was still wrong, because:

> **Unleaked content is necessary and not sufficient. Evidence has to be tied to the transmitter as
> well as to the receiver — what was sent, and when.** Nobody checked that the described sound was
> the emitted sound. It wasn't.

**Three fixes, all cheap, and they compose:**

1. **Enumerate the other sources first.** Before trusting a human observer, list everything in the
   room that can produce the signal you are looking for — **including your own tooling.** An agent
   narrating its progress out loud is an experimental contaminant when the experiment is "does this
   device make a noise."
2. **Anchor in time.** These cameras expose a monotonic uptime counter, which places a transmission
   to the second. Ask the observer to say *"now"*, and *"I heard beeps"* becomes *"I heard beeps
   inside the 40-second window in which beeps were transmitted"* — which an ambient source cannot
   fake.
3. **Do not let the operator brief the content.** Whoever relays "listen for X" has leaked the
   answer key. Have the transmitter choose a pattern, withhold it from the relay, and compare
   afterwards.

**The pattern-not-yes-no protocol worked and is why this was caught at all.** The observer
volunteered the word *"music"* before any briefing — and nobody hearing three beeps and a tone
calls that music. **The mismatch was visible in his own words.** A yes/no question would have
returned "yes" both times.

⚠️ **And note who made the error: the person enforcing this rule on everyone else, twice in one
hour.** That is the argument for the guard being **procedural rather than a matter of care.**
Nobody is careful enough to catch this reliably.

## See also

* [security.md](security.md) — what the write-probe did to a camera
* [provisioning.md](provisioning.md) — the `200`-means-parsed rule at the HTTP layer
* [ai-and-events.md](ai-and-events.md) — `DrwAck`, and "an established session is not an
  authorised session"
