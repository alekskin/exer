# DCS sequences — Device Control String

The channel for payloads too large or too structured for CSI: sixel images, soft fonts,
terminfo queries, setting-value replies, and multiplexer passthrough.

## Support legend

| Tag | Meaning |
|---|---|
| **Universal** | Every terminal. Must have. |
| **Wide** | xterm, VTE, kitty, alacritty, wezterm, foot, iTerm2. Should have. |
| **Partial** | Uneven — real but several terminals ignore it. |
| **Rare** | Niche or DEC heritage. Consume and discard. |
| **Obsolete** | Superseded. |

---

## 0. Form and parsing

```
DCS P...P I...I F <data string> ST
```

- `DCS` = `ESC P` (7-bit) or `0x90` (8-bit, unusable in UTF-8 mode)
- The header — parameters, intermediates, final byte — follows **exactly the CSI grammar**:
  params `0x30–0x3F`, intermediates `0x20–0x2F`, final `0x40–0x7E`. If you already have a
  CSI parser, reuse its parameter machinery here.
- After the final byte, everything up to `ST` is an opaque **data string** whose syntax is
  defined by that final byte. This is the key structural difference from CSI: the final
  byte selects a *sub-parser*.
- `ST` = `ESC \` or `0x9C`. BEL is accepted leniently by most terminals, though unlike OSC
  it is not the norm — accept it, don't emit it.

Parsing rules:

- Dispatch on the final byte **before** consuming the data, so you know which sub-parser (or
  the discard path) receives the bytes. Buffering the whole string first works but costs
  memory on megabyte sixels.
- Cap the payload. Sixel data is legitimately large — a full-screen image is easily several
  hundred KB — so the cap has to be generous *if* you support sixel, and tight if you don't.
- `CAN`/`SUB` abort and discard. `ESC` not followed by `\` aborts.
- Unknown final byte: consume silently to `ST`. Never print the payload.
- The reply side matters too — several DCS sequences are *responses* the terminal sends to
  the application, not commands it receives.

---

## 1. Graphics

| Seq | Name | What it does | Parameters and defaults | Support |
|---|---|---|---|---|
| `DCS P1 ; P2 ; P3 q <sixel> ST` | Sixel | Render a sixel bitmap at the cursor | **P1** aspect ratio, default 0 (= 2:1); **P2** background select, default 0 — 0 or 2 mean "unspecified pixels take the current background", 1 means "leave them untouched"; **P3** horizontal grid size, default 0, ignored by every implementation | Partial (xterm, foot, wezterm, mlterm, ghostty, contour) |
| `DCS p <ReGIS> ST` | ReGIS | Vector graphics command language | none | Rare |

Sixel interacts with the grid in ways worth deciding up front: whether the image scrolls
with text, where the cursor lands afterwards (governed by DECSDM, mode `?80`), and how
images survive a resize. `CSI ? i;a;v S` (XTSMGRAPHICS) is how apps query the maximum
supported geometry and color-register count before sending.

## 2. Queries and replies

| Seq | Name | What it does | Parameters and defaults | Support |
|---|---|---|---|---|
| `DCS $ q <name> ST` | DECRQSS | **Request status string** — ask for the current value of a setting, named by its CSI final bytes (e.g. `m` for SGR, `r` for DECSTBM, `SP q` for DECSCUSR, `"p` for DECSCL) | no numeric params | Wide |
| `DCS Ps $ r <value><name> ST` | DECRPSS | The reply. **Ps = 1 means valid/supported, 0 means invalid** — note this is the opposite polarity from DECRPM's encoding, which trips people up | — | Wide |
| `DCS + q <hex> ; <hex> ST` | XTGETTCAP | Query terminfo capabilities by hex-encoded name. Multiple names separated by `;` | none | Partial (xterm, kitty, wezterm, foot) |
| `DCS 1 + r <hex>=<hex> ST` | — | Reply, one `name=value` pair per capability, both hex-encoded. **`DCS 0 + r ... ST` means unknown capability** | — | Partial |
| `DCS + p <name> ST` | XTSETTCAP | Set a terminfo capability | none | Rare |
| `DCS > \| <text> ST` | — | The reply to `CSI > q` (XTVERSION): terminal name and version as free text | — | Partial |
| `DCS ! \| <hex id> ST` | DECRPTUI | The reply to DA3 (`CSI = c`): a hex unit identifier | — | Rare |

XTGETTCAP is how modern applications discover truecolor support and key encodings without a
correct `TERM` entry — `kitty`, `wezterm` and `foot` all rely on it. Answering at least
`TN` (terminal name), `Co`/`colors`, and `RGB` goes a long way.

## 3. Definitions and downloads

| Seq | Name | What it does | Parameters and defaults | Support |
|---|---|---|---|---|
| `DCS P1 ; P2 \| <defs> ST` | DECUDK | Define user-defined keys. Payload is `key/hexstring` pairs separated by `;` | **P1** clear policy, default 0 = clear all keys before loading, 1 = load only the given ones; **P2** lock policy, default 0 = lock the keys against further redefinition, 1 = leave unlocked | Rare |
| `DCS P1;P2;P3;P4;P5;P6 { <name> <data> ST` | DECDLD | Download a soft character set (bitmap font glyphs) | **P1** font number, default 0; **P2** starting character, default 0; **P3** erase control, default 0 = erase only the redefined glyphs, 1 = erase all in that set, 2 = erase all sets; **P4** cell width, default 0 = device-dependent; **P5** font usage, default 0 = text; **P6** cell size, default 0 | Rare |
| `DCS Ps ! u <charset> ST` | DECAUPSS | Assign the user-preferred supplemental set. Ps 0 = 94-char set, 1 = 96-char set | default 0 | Rare |

DECUDK is a security consideration in the same family as OSC 52: it lets remote output bind
arbitrary strings to function keys, which the user then transmits by pressing one. xterm
disables it unless explicitly enabled. Recommendation: don't implement it.

## 4. Multiplexer passthrough

This is directly relevant to what you're building.

| Seq | What it does | Support |
|---|---|---|
| `DCS tmux ; <escaped payload> ST` | tmux passthrough: the inner payload is forwarded verbatim to the outer terminal. Literal `ESC` bytes inside the payload are doubled (`ESC ESC`) | Partial |
| `DCS <payload> ST` (screen form) | GNU screen's equivalent, with a 768-byte payload limit that forces senders to split long sequences across multiple DCS wrappers | Partial |

If you want programs running inside your multiplexer to be able to reach the real terminal —
for sixel images, OSC 52 clipboard, or OSC 8 hyperlinks — you need a passthrough convention
and a decision about which sequences you forward. Forwarding blindly means a program in one
pane can retitle the outer window or read the clipboard; that is exactly the escalation
tmux's `allow-passthrough` option exists to gate.

The other half of this problem is the reverse direction: replies. If a pane queries OSC 11
and you forward it, the answer arrives on the *outer* terminal's input stream and must be
routed back to the right pane. Most multiplexers answer common queries themselves rather
than forwarding, which is simpler and safer.

## 5. Synchronized output (legacy form)

| Seq | What it does | Support |
|---|---|---|
| `DCS = 1 s ST` | Begin synchronized update | Obsolete |
| `DCS = 2 s ST` | End synchronized update | Obsolete |

Superseded by DECSET mode `?2026`. Accept both if you want compatibility with older tmux
and iTerm2 versions; emit only 2026.

---

## Implementation order

1. **A correct discard path.** Consume any DCS to `ST` without printing it. This alone fixes
   the most visible failure mode, garbage on screen when a program probes a feature you lack.
2. **DECRQSS** for the handful of settings apps actually query — SGR, DECSTBM, DECSCUSR.
   Reply `0 $ r` for anything else rather than staying silent; silence makes apps block.
3. **XTGETTCAP** for `TN`, `Co`, `RGB`.
4. **Passthrough**, gated behind an option, once panes exist.
5. **Sixel**, if images are a goal — it is a large, self-contained subproject.
6. DECUDK and DECDLD — skip deliberately.

## The failure mode to design against

Every DCS an application sends is usually a *question*, and applications block waiting for
answers. A terminal that consumes DECRQSS or XTGETTCAP and says nothing looks like a hang.
The rule: if you recognize the query, answer it correctly; if you don't, answer with the
protocol's defined "unsupported" reply (`DCS 0 $ r ST`, `DCS 0 + r ST`). Never just swallow.

---

## Related references

- [Control characters (C0, C1, plain escapes)](control-characters-reference.md)
- [CSI sequences](CSI-reference.md)
- [OSC sequences](OSC-reference.md)
- **[DCS sequences** — you are here](DCS-reference.md)
- [APC, SOS and PM strings](APC-SOS-PM-reference.md)
