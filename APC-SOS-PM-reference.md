# APC, SOS and PM — the ignorable string sequences

Three of ECMA-48's string-opening controls. ECMA-48 gives them no defined content: the
standard's instruction is that a terminal consumes the string and does nothing with it.
Two of them are still exactly that. The third, APC, has been claimed by modern extensions
and is where kitty's graphics protocol lives.

They share one grammar, one parser state, and one set of hazards, which is why they are
documented together here rather than in three near-empty files.

## Support legend

| Tag | Meaning |
|---|---|
| **Wide** | xterm, VTE, kitty, alacritty, wezterm, foot, iTerm2. |
| **Partial** | Uneven — real but several terminals ignore it. |
| **Rare** | One or two terminals, or standards-only. |
| **Ignored** | Correctly implemented *as* a no-op — consume and discard. |

---

## 0. Shared form

```
APC <string> ST      ESC _ ... ESC \
PM  <string> ST      ESC ^ ... ESC \
SOS <string> ST      ESC X ... ESC \
```

| Control | 7-bit | 8-bit | Name |
|---|---|---|---|
| APC | `ESC _` | 0x9F | Application Program Command |
| PM | `ESC ^` | 0x9E | Privacy Message |
| SOS | `ESC X` | 0x98 | Start of String |

There are **no parameters and no intermediates** — unlike CSI and DCS, the byte after the
introducer is already payload. There is therefore nothing to default.

`ST` = `ESC \` or `0x9C`. BEL is *not* a standard terminator for these; xterm accepts it
leniently for APC. Accept it, never emit it.

### SOS is the odd one

ECMA-48 gives SOS a different termination rule from APC and PM: its string may legitimately
contain any bytes including other control sequences, and it ends only at `ST` (or, per the
standard, another `SOS`). APC and PM strings are specified as containing only printable
characters. In practice every emulator treats all three identically — consume to `ST` — and
that is the right implementation.

---

## 1. APC — Application Program Command

**Support: Partial.** The only one of the three with live users.

| Sequence | What it does | Support |
|---|---|---|
| `APC G <control data> ; <base64 payload> ST` | **kitty graphics protocol.** Control data is a comma-separated `key=value` list — `a=` action (t transmit, T transmit-and-display, p put, d delete, q query), `f=` format, `i=` image id, `s=`/`v=` pixel dimensions, `c=`/`r=` cell dimensions, `m=` more-chunks-follow. The payload is base64 image data, split across multiple APC sequences when large | Partial (kitty, ghostty, wezterm, konsole) |
| `APC <other> ST` | Everything else — application-defined, no convention | Ignored |

The kitty protocol chunks large images across many APC sequences with `m=1` on all but the
last, which means a correct implementation needs reassembly state, not just a per-sequence
handler. If you are not implementing graphics, the discard path handles it correctly and
invisibly: an application that gets no response to `a=q` concludes the terminal has no
graphics support and falls back.

## 2. PM — Privacy Message

**Support: Ignored, universally.**

No terminal emulator implements PM as anything but a discard. It has no established
extension use. Consume to `ST`.

Historically it marked text that shouldn't be logged or printed. If you ever wanted a use
for it, that history makes it a plausible home for a private multiplexer-to-multiplexer
channel — nothing else will claim it. But treat that as a note, not a recommendation:
DCS passthrough is the convention other tools already understand.

## 3. SOS — Start of String

**Support: Ignored, universally.**

Same as PM: consume to `ST`. The only thing worth knowing is the termination quirk noted
above — because SOS strings may legally contain escape sequences, a parser that aborts SOS
on any embedded `ESC` is technically wrong. It also does not matter, because nothing emits
SOS.

---

## 4. Implementation

All three collapse to one parser state. The entire correct implementation, if you are not
doing graphics:

- On `APC`/`PM`/`SOS`, enter a string-consuming state, remembering which one opened it.
- Accumulate bytes (or, if you have no consumer, just count them) until `ST`.
- On `CAN`/`SUB`, abort and discard.
- On `ESC`: if the next byte is `\`, terminate; otherwise abort the string and restart
  parsing at the `ESC`.
- Discard the accumulated string.

Then, if you add kitty graphics later, the only change is checking for a leading `G` on APC
before discarding.

### The hazards

**Unterminated strings.** This is the real risk, and it is shared with OSC and DCS. A
process that emits `ESC _` and then never terminates puts the parser in a state where every
subsequent byte — including the user's shell prompt, their command output, everything — is
silently eaten. The terminal appears frozen while consuming input at full speed. Cap the
length: on exceeding it, discard and return to ground. A few KB is generous for APC and PM;
kitty graphics needs more like 4 MB if you support it, since a single chunk can be large.

**Buffering cost.** If you have no consumer for a string type, do not accumulate it. Count
bytes against the cap and drop them. A hostile or buggy process emitting an endless APC
should not be able to grow your memory usage.

**Do not print the payload.** The failure mode of a half-implemented string parser is the
payload leaking onto the screen — base64 image data splattered across the user's terminal.
Any string type you don't handle must be consumed, not passed through.

## 5. Relationship to the other string sequences

| Control | Has params? | Payload defined by | Real uses |
|---|---|---|---|
| OSC | Yes, numeric `Ps` | The `Ps` selector | Titles, colors, clipboard, hyperlinks, notifications |
| DCS | Yes, full CSI grammar | The final byte | Sixel, DECRQSS, XTGETTCAP, passthrough |
| APC | No | Convention only (leading `G`) | kitty graphics |
| PM | No | — | none |
| SOS | No | — | none |

The four string types plus OSC should share one buffer, one length cap, and one abort path
in your parser. The only thing that differs is which consumer gets the finished string.

---

## Related references

- [Control characters (C0, C1, plain escapes)](control-characters-reference.md)
- [CSI sequences](CSI-reference.md)
- [OSC sequences](OSC-reference.md)
- [DCS sequences](DCS-reference.md)
- **[APC, SOS and PM strings** — you are here](APC-SOS-PM-reference.md)
