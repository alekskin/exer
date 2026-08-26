# OSC sequences — Operating System Command

Commands that talk to the terminal *as an application* rather than to the screen grid:
titles, colors, clipboard, hyperlinks, notifications, shell integration.

## Support legend

| Tag | Meaning |
|---|---|
| **Universal** | Every terminal; apps assume it. Must have. |
| **Wide** | xterm, VTE, kitty, alacritty, wezterm, foot, iTerm2. Should have. |
| **Partial** | Uneven — a real convention, but several terminals ignore it. |
| **Rare** | One or two terminals, or legacy X11. Consume and discard. |
| **Obsolete** | Superseded. |

---

## 0. Form and parsing

```
OSC Ps ; Pt ST
```

- `OSC` = `ESC ]` (7-bit) or `0x9D` (8-bit, not usable in UTF-8 mode)
- `Ps` — a numeric command selector. **There is no default**: an OSC with no leading number
  is malformed, though most terminals treat a missing/empty `Ps` as 0.
- `Pt` — the payload, a text string. Its structure depends entirely on `Ps`. It may itself
  contain semicolons, so **split on the first semicolon only** — this is the single most
  common OSC bug. `OSC 0 ; a;b ST` sets the title to the literal `a;b`.
- `ST` = `ESC \` (0x9C). **BEL (0x07) is universally accepted as an alternative terminator**
  and is what most software actually emits. You must support both.

Parsing rules worth centralizing:

- Cap the payload length. An unterminated OSC otherwise swallows the rest of the session.
  xterm's limit is in the low thousands of bytes; something like 4–8 KB is reasonable, more
  if you support OSC 52 clipboard payloads (base64 of a large selection).
- `CAN`/`SUB` abort the string and discard it.
- `ESC` followed by `\` terminates; `ESC` followed by anything else aborts the string
  (xterm's behavior) — do not silently keep accumulating.
- C0 controls inside the payload: safest is to abort. Permitting raw control bytes into a
  window title is how terminal-injection tricks work.
- Unknown `Ps`: consume the whole string and discard. Never let the payload reach the screen.

### The querying convention

Many color-related OSCs accept `?` as the payload to **query** instead of set. The reply
comes back on the input stream in the same shape as the setter, terminated the same way the
request was. `OSC 11 ; ? BEL` → `OSC 11 ; rgb:1e1e/1e1e/1e1e BEL`.

Applications rely on this to detect dark vs light backgrounds, so OSC 10/11 queries are
worth implementing early.

---

## 1. Titles and window identity

| Ps | Payload | What it does | Support |
|---|---|---|---|
| 0 | text | Set **both** the window title and the icon name | Universal |
| 1 | text | Set the icon name only | Wide |
| 2 | text | Set the window title only | Universal |
| 3 | `prop=value` | Set an X11 window property. Omitting `=value` deletes the property | Rare |
| 6 | `0`/`1` | Enable/disable per-document color reporting (iTerm2) | Rare |
| 7 | `file://host/path` | Report the shell's current working directory. Terminals use it to open new tabs in the same place | Wide |

The title stack is on the CSI side: `CSI 22 ; n t` pushes, `CSI 23 ; n t` pops, where
n = 0 both, 1 icon, 2 window.

## 2. Color palette

Color specs accept X11 formats: `#rgb`, `#rrggbb`, `#rrrgggbbb`, `#rrrrggggbbbb`,
`rgb:r/g/b` with 1–4 hex digits per channel, `rgbi:f/f/f` floats, and X11 color names
(`red`, `cornflowerblue`). Replies are conventionally in `rgb:rrrr/gggg/bbbb` form.

| Ps | Payload | What it does | Support |
|---|---|---|---|
| 4 | `c ; spec` | Set palette entry `c` (0–255). `spec` = `?` queries it. Multiple `c;spec` pairs may be chained in one sequence | Wide |
| 5 | `c ; spec` | Set a *special* color by offset past the 256 palette: 0 = bold, 1 = underline, 2 = blink, 3 = reverse, 4 = italic | Rare |
| 10 | spec | Default foreground color | Wide |
| 11 | spec | Default background color | Wide |
| 12 | spec | Text cursor color | Wide |
| 13 | spec | Mouse pointer foreground | Rare |
| 14 | spec | Mouse pointer background | Rare |
| 15 | spec | Tektronix foreground | Obsolete |
| 16 | spec | Tektronix background | Obsolete |
| 17 | spec | Highlight (selection) background | Partial |
| 18 | spec | Tektronix cursor | Obsolete |
| 19 | spec | Highlight (selection) foreground | Partial |
| 104 | `c` or empty | Reset palette entry `c`. **Default when the payload is empty: reset the entire palette** | Wide |
| 105 | `c` or empty | Reset special color `c`; empty resets all | Rare |
| 110 | — | Reset foreground to default | Wide |
| 111 | — | Reset background to default | Wide |
| 112 | — | Reset cursor color | Wide |
| 113–119 | — | Reset pointer fg, pointer bg, Tek fg, Tek bg, highlight bg, Tek cursor, highlight fg — mirroring 13–19 | Partial |

Note the pattern: `10 + n` sets, `110 + n` resets. Implementing 10/11/12 plus 110/111/112
plus 4/104 covers essentially all real usage.

## 3. Clipboard — OSC 52

```
OSC 52 ; Pc ; Pd ST
```

- `Pc` — selection: `c` clipboard, `p` primary, `s` select, `0`–`7` cut buffers.
  **Default when empty: `s0`**, meaning select-plus-cut-buffer-0.
- `Pd` — base64-encoded data to set the selection to. `?` requests the current contents,
  which the terminal returns in the same format.

**Support: Wide** for writing, **Partial and often disabled** for reading. Reading is a
genuine security hole — any process with terminal access, including one on the far end of an
ssh session, can exfiltrate whatever you last copied. xterm gates it behind
`allowWindowOps`; most modern terminals disable the read path by default or prompt.
Recommendation: implement write, make read opt-in, and cap the decoded size.

Invalid base64 should cause the whole sequence to be discarded, not partially applied.

## 4. Hyperlinks — OSC 8

```
OSC 8 ; params ; URI ST   text   OSC 8 ; ; ST
```

Everything printed between the opening and the empty closing sequence becomes a clickable
link. `params` is a `key=value:key=value` list; the only standardized key is `id=`, which
lets a wrapped link be treated as one hover target across multiple lines.

**Support: Wide** — VTE, kitty, wezterm, foot, iTerm2, Windows Terminal.

Implementation notes: the URI is a per-cell attribute, so it needs a slot in your cell
struct — most implementations store an interned id rather than the string. Sanitize the
scheme (allow `http`, `https`, `file`, `mailto`; reject `javascript:` and friends) and cap
the URI length. An unterminated link should not leak into the rest of the screen — closing
on a hard reset is standard.

## 5. Shell integration — OSC 133 (FinalTerm / semantic prompts)

Marks the structure of a shell session so the terminal can offer "jump to previous prompt",
"select command output", and exit-status decoration.

| Payload | Marker | Meaning |
|---|---|---|
| `A` | prompt start | The prompt begins here |
| `B` | prompt end | The command input begins here |
| `C` | output start | The command was submitted; output begins |
| `D ; exit` | command end | Command finished with the given exit code. **Default when the code is omitted: unknown/0** |

**Support: Wide** — kitty, wezterm, iTerm2, VTE, Windows Terminal, ghostty. Requires shell
cooperation, so it only fires when the user's rc files emit it.

Related: OSC 633 is Visual Studio Code's superset of the same idea, OSC 7 (above) is the
directory half of the same feature set.

## 6. Notifications and progress

| Ps | Payload | What it does | Support |
|---|---|---|---|
| 9 | text | Desktop notification (iTerm2, ConEmu) | Partial |
| 9 | `4 ; state ; progress` | Progress bar: state 0 = remove, 1 = default, 2 = error, 3 = indeterminate, 4 = paused. `progress` is 0–100 | Partial (ConEmu, Windows Terminal) |
| 99 | `key=value ; body` | kitty desktop notification protocol — supports titles, icons, urgency, and multi-chunk bodies | Rare |
| 777 | `notify ; title ; body` | urxvt extension dispatch, the older notification convention | Rare |

Notifications are outward-facing: rate-limit them and consider requiring focus or a user
setting, or a busy loop can spam the desktop.

## 7. Vendor and legacy

| Ps | Payload | What it does | Support |
|---|---|---|---|
| 22 | shape name | Set the mouse pointer shape | Rare |
| 46 | filename | Change the log file. **A remote-write primitive — xterm disables it by default** | Rare, disable |
| 50 | font spec | Set the font. `?` queries. Some terminals reuse 50 for other purposes | Rare |
| 51 | text | Emacs shell marker (reserved by xterm) | Rare |
| 60–63 | — | Query/set allowed window ops, X11 legacy | Obsolete |
| 133 | see §5 | Semantic prompt | Wide |
| 633 | key/value | VS Code shell integration | Partial |
| 1337 | `key=value` | iTerm2 proprietary: `File=` inline images, `SetUserVar=`, `CurrentDir=`, `ShellIntegrationVersion=` | Partial |

OSC 1337's `File=` is the iTerm2 inline-image protocol and carries base64 image data, which
means payloads in the megabytes. If you don't implement it, make sure your length cap
discards it cleanly rather than truncating into visible garbage.

---

## Implementation order

1. **OSC 0/1/2** — titles. Trivial and universally used.
2. **OSC 4 / 10 / 11 / 12 and 104 / 110 / 111 / 112** — palette set *and query*. Apps probe
   OSC 11 to pick a light or dark theme.
3. **OSC 7** — working directory, needed for sane new-tab behavior.
4. **OSC 8** — hyperlinks; costs you a cell attribute slot.
5. **OSC 52 write** — clipboard; leave the read path off by default.
6. **OSC 133** — shell integration, once you have somewhere to put the marks.
7. Everything else — consume to `ST` and drop.

## Security checklist

OSC is the attack surface of a terminal emulator, because it is where untrusted output
crosses into system state. Before shipping:

- Title *reporting* (`CSI 20/21 t`) lets a remote process echo an attacker-chosen string
  back as if the user typed it. Off by default.
- OSC 52 read exfiltrates the clipboard. Off by default or prompted.
- OSC 46 writes files. Never implement it.
- Sanitize control characters out of anything that lands in a title, notification, or link.
- Cap every payload length and every base64 decode.

---

## Related references

- [Control characters (C0, C1, plain escapes)](control-characters-reference.md)
- [CSI sequences](CSI-reference.md)
- **[OSC sequences** — you are here](OSC-reference.md)
- [DCS sequences](DCS-reference.md)
- [APC, SOS and PM strings](APC-SOS-PM-reference.md)
