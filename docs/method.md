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

## See also

* [security.md](security.md) — what the write-probe did to a camera
* [provisioning.md](provisioning.md) — the `200`-means-parsed rule at the HTTP layer
