# Control characters — C0, C1, and plain escape sequences

Everything below the CSI layer: single-byte controls, the C1 set and its 7-bit escape
forms, and the `ESC`-plus-final sequences that aren't CSI, OSC or DCS.

## Support legend

| Tag | Meaning |
|---|---|
| **Universal** | Every terminal; apps assume it. Must have. |
| **Wide** | xterm, VTE, kitty, alacritty, wezterm, foot, iTerm2. Should have. |
| **Partial** | Uneven — some terminals ignore or no-op it. |
| **Rare** | Niche or DEC hardware heritage. Consume and discard. |
| **Obsolete** | Superseded. Accept for compat, usually as a no-op. |

---

## 1. C0 controls (0x00–0x1F, plus DEL)

These execute immediately, **including in the middle of an escape sequence** — a `CR` that
arrives between `CSI 1` and `m` moves the cursor and the CSI sequence continues afterwards.
The exceptions are `ESC`, `CAN` and `SUB`, which affect the parser itself.

| Hex | Abbr | Name | What it does | Support |
|---|---|---|---|---|
| 0x00 | NUL | Null | Ignored. Historically padding for slow terminals. Never occupies a cell. | Universal (ignored) |
| 0x01 | SOH | Start of heading | Ignored | Rare |
| 0x02 | STX | Start of text | Ignored | Rare |
| 0x03 | ETX | End of text | Ignored by the terminal; the *line discipline* turns Ctrl-C into SIGINT, not the emulator | Rare |
| 0x04 | EOT | End of transmission | Ignored | Rare |
| 0x05 | ENQ | Enquiry | Transmits the answerback string back to the host. Default answerback is empty in xterm; a non-empty default is a security problem | Rare |
| 0x06 | ACK | Acknowledge | Ignored | Rare |
| 0x07 | BEL | Bell | Audible/visual bell. Also serves as a non-standard string terminator for OSC (and, leniently, DCS) | Universal |
| 0x08 | BS | Backspace | Cursor left one column. Does **not** erase. Stops at the left margin unless reverse-wraparound (`?45`) is set, in which case it moves to the end of the previous line | Universal |
| 0x09 | HT | Horizontal tab | Cursor to the next tab stop, or the right margin if none remains. Does not erase the cells it passes over | Universal |
| 0x0A | LF | Line feed | Cursor down one row, scrolling if at the bottom margin. Also does CR when LNM (mode 20) is set | Universal |
| 0x0B | VT | Vertical tab | Treated as LF by every terminal emulator | Universal |
| 0x0C | FF | Form feed | Treated as LF | Universal |
| 0x0D | CR | Carriage return | Cursor to column 1, or to the left margin if one is set and the cursor is inside it | Universal |
| 0x0E | SO | Shift out (LS1) | Invoke G1 into GL | Wide |
| 0x0F | SI | Shift in (LS0) | Invoke G0 into GL | Wide |
| 0x10 | DLE | Data link escape | Ignored | Rare |
| 0x11 | DC1 | XON | Resume transmission (flow control, usually handled by the tty layer) | Partial |
| 0x12 | DC2 | Device control 2 | Ignored | Rare |
| 0x13 | DC3 | XOFF | Pause transmission | Partial |
| 0x14 | DC4 | Device control 4 | Ignored | Rare |
| 0x15 | NAK | Negative acknowledge | Ignored | Rare |
| 0x16 | SYN | Synchronous idle | Ignored | Rare |
| 0x17 | ETB | End of transmission block | Ignored | Rare |
| 0x18 | CAN | Cancel | **Aborts any escape/CSI/OSC/DCS sequence in progress**; the partial sequence is discarded silently | Universal |
| 0x19 | EM | End of medium | Ignored | Rare |
| 0x1A | SUB | Substitute | Aborts a sequence like CAN, and additionally displays an error glyph (xterm draws a reverse-video `?`) | Wide |
| 0x1B | ESC | Escape | Begins an escape sequence. Inside an existing sequence it **restarts** parsing rather than aborting to ground | Universal |
| 0x1C | FS | File separator | Ignored | Rare |
| 0x1D | GS | Group separator | Ignored | Rare |
| 0x1E | RS | Record separator | Ignored | Rare |
| 0x1F | US | Unit separator | Ignored | Rare |
| 0x7F | DEL | Delete | Ignored. Historically the all-punched pattern on paper tape | Universal (ignored) |

Practical note: the ones you actually implement are BEL, BS, HT, LF, VT, FF, CR, SO, SI,
CAN, SUB, ESC. Everything else is `case _: // ignore`.

## 2. C1 controls (0x80–0x9F)

Each has an 8-bit form and a 7-bit `ESC` + (byte − 0x40) form. **In UTF-8 mode the 8-bit
forms are unusable** — 0x80–0x9F are continuation bytes — so the 7-bit forms are what you
will actually see. Only accept 8-bit C1 when not in UTF-8 mode, or you will corrupt
multibyte text.

| Hex | 7-bit | Abbr | Name | What it does | Support |
|---|---|---|---|---|---|
| 0x84 | `ESC D` | IND | Index | Cursor down one row, scrolling at the bottom margin. Like LF but never does CR | Wide |
| 0x85 | `ESC E` | NEL | Next line | Cursor down one row *and* to column 1 | Wide |
| 0x88 | `ESC H` | HTS | Horizontal tab set | Set a tab stop at the current column | Wide |
| 0x8D | `ESC M` | RI | Reverse index | Cursor up one row, scrolling **down** if already at the top margin | Universal |
| 0x8E | `ESC N` | SS2 | Single shift 2 | Invoke G2 for the *next character only* | Partial |
| 0x8F | `ESC O` | SS3 | Single shift 3 | Invoke G3 for one character. Also the prefix cursor keys use in DECCKM application mode | Wide |
| 0x90 | `ESC P` | DCS | Device control string | Opens a DCS — see the DCS reference | Wide |
| 0x96 | `ESC V` | SPA | Start of protected area | Begin DECSCA-protected region | Rare |
| 0x97 | `ESC W` | EPA | End of protected area | End it | Rare |
| 0x98 | `ESC X` | SOS | Start of string | Opens an ignorable string — see the APC/SOS/PM reference | Rare |
| 0x9A | `ESC Z` | DECID | Identify terminal | Same reply as DA1 (`CSI c`) | Obsolete |
| 0x9B | `ESC [` | CSI | Control sequence introducer | See the CSI reference | Universal |
| 0x9C | `ESC \` | ST | String terminator | Ends OSC/DCS/APC/SOS/PM | Universal |
| 0x9D | `ESC ]` | OSC | Operating system command | See the OSC reference | Universal |
| 0x9E | `ESC ^` | PM | Privacy message | Ignorable string | Rare |
| 0x9F | `ESC _` | APC | Application program command | Ignorable string; used by kitty's graphics protocol | Partial |

Unlisted C1 codes (0x80–0x83, 0x86–0x87, 0x89–0x8C, 0x91–0x95, 0x99) are ECMA-48 controls
no emulator implements — BPH, NBH, SSA, ESA, PU1, PU2, STS, CCH, MW, SGCI. Ignore them.

## 3. Plain escape sequences (`ESC` + final, no CSI)

`ESC I...I F` where intermediates are 0x20–0x2F and the final is 0x30–0x7E.

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `ESC 7` | DECSC | Save cursor: position, SGR attributes, charset state (G0–G3 and GL/GR), origin mode, and the pending-wrap flag | — | Universal |
| `ESC 8` | DECRC | Restore all of the above. If nothing was saved, restores to home with defaults | — | Universal |
| `ESC c` | RIS | **Hard reset.** Clears both screens and scrollback, resets all modes, margins, tab stops, charsets, colors and title | — | Wide |
| `ESC D` | IND | Index — cursor down, scroll at margin | — | Wide |
| `ESC E` | NEL | Next line — down and to column 1 | — | Wide |
| `ESC H` | HTS | Set tab stop at the cursor column | — | Wide |
| `ESC M` | RI | Reverse index — up, scroll down at top margin | — | Universal |
| `ESC N` | SS2 | Single shift G2, one character | — | Partial |
| `ESC O` | SS3 | Single shift G3, one character | — | Wide |
| `ESC Z` | DECID | Obsolete DA1 request | — | Obsolete |
| `ESC =` | DECKPAM | Keypad application mode: keypad sends `SS3 x` sequences | — | Wide |
| `ESC >` | DECKPNM | Keypad numeric mode: keypad sends plain digits | — | Wide |
| `ESC # 3` | DECDHL | Double-height line, top half | — | Partial |
| `ESC # 4` | DECDHL | Double-height line, bottom half | — | Partial |
| `ESC # 5` | DECSWL | Single-width line (the default) | — | Partial |
| `ESC # 6` | DECDWL | Double-width line | — | Partial |
| `ESC # 8` | DECALN | Screen alignment test — fills the whole screen with `E`, resets margins, homes the cursor. Used by test suites | — | Wide |
| `ESC ( C` | — | Designate charset into G0 | — | Wide |
| `ESC ) C` | — | Designate into G1 | — | Wide |
| `ESC * C` | — | Designate into G2 | — | Partial |
| `ESC + C` | — | Designate into G3 | — | Partial |
| `ESC n` | LS2 | Locking shift: G2 into GL | — | Partial |
| `ESC o` | LS3 | G3 into GL | — | Partial |
| `ESC \|` | LS3R | G3 into GR | — | Rare |
| `ESC }` | LS2R | G2 into GR | — | Rare |
| `ESC ~` | LS1R | G1 into GR | — | Rare |
| `ESC % @` | — | Select default charset (ISO 8859-1) | — | Partial |
| `ESC % G` | — | Select UTF-8 | — | Wide |
| `ESC SP F` | S7C1T | Send 7-bit C1 controls (the sane default) | — | Partial |
| `ESC SP G` | S8C1T | Send 8-bit C1 controls | — | Partial |
| `ESC SP L/M/N` | — | ANSI conformance level 1/2/3 | — | Rare |
| `ESC l` / `ESC m` | — | Memory lock / unlock (HP) | — | Rare |
| `ESC \` | ST | String terminator | — | Universal |

### Charset designators (the `C` above)

| Byte | Charset | Support |
|---|---|---|
| `B` | US ASCII | Universal |
| `0` | DEC Special Graphics — the line-drawing set | Universal |
| `A` | UK / ISO Latin-1 | Wide |
| `<` | DEC Supplemental | Rare |
| `>` | DEC Technical | Rare |
| `4` `5` `C` `R` `Q` `K` `Y` `E` `6` `Z` `H` `7` `=` | National replacement sets (Dutch, Finnish, French, etc.) | Rare |

Only `B` and `0` matter in practice. The DEC Special Graphics set is how `ncurses`,
`dialog` and friends still draw boxes on terminals that don't trust Unicode box characters,
so it is not optional.

## 4. Parser state notes

- `ESC` seen while parsing anything → restart. This is what makes a truncated sequence
  followed by a fresh one recover cleanly.
- `CAN`/`SUB` → abort to ground, discard.
- A C0 control arriving mid-CSI executes immediately and parsing resumes. A C0 control
  arriving mid-*string* (OSC/DCS/APC) is handled differently — see those references.
- Bytes 0x80–0x9F while in UTF-8 mode are continuation bytes, never C1 controls.
- An unterminated escape sequence should not consume unbounded input; cap it.

---

## Related references

- **[Control characters (C0, C1, plain escapes)** — you are here](control-characters-reference.md)
- [CSI sequences](CSI-reference.md)
- [OSC sequences](OSC-reference.md)
- [DCS sequences](DCS-reference.md)
- [APC, SOS and PM strings](APC-SOS-PM-reference.md)
