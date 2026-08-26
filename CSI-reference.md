# CSI sequences — a working map

A reference for implementing the CSI layer of a terminal emulator. Every table carries a
**Support** column so you can tell what you must implement from what you can safely stub.

## Support legend

| Tag | Meaning |
|---|---|
| **Universal** | Every terminal implements it; apps assume it. Must have. |
| **Wide** | xterm, VTE (gnome/tilix), kitty, alacritty, wezterm, foot, iTerm2. Should have. |
| **Partial** | Real but uneven — some terminals ignore it, or accept and no-op it. Implement if cheap. |
| **Rare** | xterm-only, DEC hardware heritage, or a niche extension. Parse and discard. |
| **Obsolete** | Superseded. Accept for compat, usually as a no-op. |

"Parse and discard" is a real implementation strategy: the important thing is that the
sequence is *consumed* by the parser so its bytes never reach the screen.

---

## 0. Parsing

**Form:** `CSI P...P I...I F`

- `CSI` = `ESC [` (7-bit) or `0x9B` (8-bit, only meaningful outside UTF-8)
- **Parameter bytes** `0x30–0x3F`: `0–9`, `;`, `:`, plus the private markers `< = > ?`
  which are only legal as the *first* parameter byte
- **Intermediate bytes** `0x20–0x2F`: `SP ! " # $ % & ' * +` — part of the command's
  identity, not decoration. `CSI 2 q` (DECLL) and `CSI 2 SP q` (DECSCUSR) are different commands.
- **Final byte** `0x40–0x7E` — dispatch on this plus the intermediates plus the private marker.

Rules worth encoding once, at the parser level:

- A missing parameter means "default", and the default differs per sequence — see the
  **Default** column on every table below, and the summary in §0.1.
- Subparameters use `:` (SGR 38/48/58, underline styles). A parameter is really a *list* of
  subparameters; retrofitting this later is painful.
- Clamp parameter values (xterm caps at 65535) and cap parameter count (16–32 typical);
  a sequence that exceeds the cap should be marked invalid and discarded whole.
- `CAN` (0x18) and `SUB` (0x1A) abort the sequence immediately; `SUB` also emits an error glyph.
- `ESC` restarts the sequence. C0 controls other than those execute *in place* mid-sequence.
- A byte outside the legal class for the current state invalidates the sequence — discard it,
  don't print the tail as text.
- Private markers appearing anywhere but the first param byte make the sequence invalid.

### 0.1 Parameter defaults

Three distinct cases, and conflating them causes real bugs:

| Case | Meaning | Examples |
|---|---|---|
| **Omitted → 1** | Movement and count-like sequences | CUU/CUD/CUF/CUB, CUP, SU/SD, ICH, DCH, IL, DL, ECH, REP, CHT, CBT |
| **Omitted → 0** | Selector-like sequences where 0 is a real mode | ED, EL, SGR, DA1, TBC, DECSCUSR, DECSCA, MC |
| **Omitted → context** | The default is a property of the screen, not a number | DECSTBM (full screen), DECSLRM (full width) |

Two further rules that are easy to get wrong:

- **An explicit 0 usually means the same as 1** for count-like sequences. `CSI 0 A` moves
  up one row, not zero rows. Clamp counts to a minimum of 1 after defaulting.
- **Empty is not zero, and position matters.** `CSI ;5H` means "default row, column 5"
  → row 1, column 5. `CSI 5H` means row 5, default column. Your parameter list must
  distinguish "absent" from "zero", so store an explicit sentinel or a presence flag —
  collapsing empty to 0 at parse time makes the two indistinguishable.
- Trailing empty parameters count: `CSI 1;H` has two parameters, the second defaulted.

---

## 1. Cursor movement

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `CSI n A` | CUU | Move cursor up n rows. Stops at the scroll top margin, or row 1 if outside the region. Does not scroll | n = 1 | Universal |
| `CSI n B` | CUD | Move down n rows, stopping at the bottom margin. Does not scroll | n = 1 | Universal |
| `CSI n C` | CUF | Move right n columns, stopping at the right margin. Never wraps | n = 1 | Universal |
| `CSI n D` | CUB | Move left n columns, stopping at the left margin | n = 1 | Universal |
| `CSI n E` | CNL | Move down n rows and to column 1 | n = 1 | Wide |
| `CSI n F` | CPL | Move up n rows and to column 1 | n = 1 | Wide |
| `CSI n G` | CHA | Move to absolute column n on the current row | n = 1 | Universal |
| `CSI r;c H` | CUP | Move to absolute row r, column c. Both are relative to the margins when DECOM is set. Clamped to the screen | r = 1, c = 1 | Universal |
| `CSI r;c f` | HVP | Identical to CUP in every emulator | r = 1, c = 1 | Wide |
| `CSI n d` | VPA | Move to absolute row n, keeping the column | n = 1 | Wide |
| `CSI n e` | VPR | Move down n rows — same effect as CUD | n = 1 | Partial |
| `` CSI n ` `` | HPA | Move to absolute column n — same effect as CHA | n = 1 | Partial |
| `CSI n a` | HPR | Move right n columns — same effect as CUF | n = 1 | Partial |
| `CSI n j` | HPB | Move left n columns | n = 1 | Rare |
| `CSI n k` | VPB | Move up n rows | n = 1 | Rare |
| `CSI n I` | CHT | Move forward to the n-th next tab stop; stops at the right margin | n = 1 | Wide |
| `CSI n Z` | CBT | Move back to the n-th previous tab stop; stops at the left margin | n = 1 | Wide |
| `CSI n Y` | CVT | Move forward n *line* tab stops | n = 1 | Rare |
| `CSI s` | SCOSC | Save cursor position only (not attributes — that's `ESC 7`). **Collides with DECSLRM**, see §3 | no params | Wide |
| `CSI u` | SCORC | Restore the position saved by SCOSC; home if nothing was saved | no params | Wide |

Not CSI, but the same subsystem: `ESC 7`/`ESC 8` (DECSC/DECRC — save/restore includes SGR,
charset, origin mode and the wrap latch), `ESC M` (RI), `ESC D` (IND), `ESC E` (NEL).

## 2. Erase & edit

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `CSI n J` | ED | Erase in display: 0 = cursor to end of screen, 1 = start of screen to cursor, 2 = whole screen, 3 = scrollback as well (xterm extension). Cursor does not move | n = 0 | Universal (3: Wide) |
| `CSI n K` | EL | Erase in line: 0 = cursor to end of line, 1 = start of line to cursor, 2 = whole line. Both endpoints inclusive. Cursor does not move | n = 0 | Universal |
| `CSI ? n J` | DECSED | Selective erase in display — same regions as ED, but skips cells marked protected by DECSCA | n = 0 | Rare |
| `CSI ? n K` | DECSEL | Selective erase in line | n = 0 | Rare |
| `CSI n X` | ECH | Erase n characters starting at the cursor, in place. Nothing shifts; the cursor does not move. Stops at the right margin | n = 1 | Wide |
| `CSI n @` | ICH | Insert n blank cells at the cursor, shifting the rest of the line right. Cells pushed past the right margin are lost. Cursor does not move | n = 1 | Universal |
| `CSI n P` | DCH | Delete n cells at the cursor, shifting the remainder left and filling the right margin with blanks | n = 1 | Universal |
| `CSI n L` | IL | Insert n blank lines at the cursor row, pushing lines below it down. Only acts when the cursor is inside the scroll region; lines pushed past the bottom margin are lost. Cursor moves to column 1 | n = 1 | Universal |
| `CSI n M` | DL | Delete n lines at the cursor row, pulling lines below it up and filling from the bottom margin with blanks. Cursor moves to column 1 | n = 1 | Universal |
| `CSI n b` | REP | Repeat the last printed graphic character n more times. Has no effect if the last output was a control sequence | n = 1 | Wide |
| `CSI n N` | EF | Erase in field | n = 0 | Rare |
| `CSI n O` | EA | Erase in area | n = 0 | Rare |

Erase semantics detail: erased cells take the *current* background color (that's why
`ESC[41m ESC[2J` paints red), but not the current foreground or attributes.

## 3. Scrolling & margins

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `CSI n S` | SU | Scroll the region up n lines; new blank lines enter at the bottom margin. Cursor does not move. Lines leaving the top go to scrollback only if the region is the full screen | n = 1 | Universal |
| `CSI n T` | SD | Scroll the region down n lines; blanks enter at the top margin | n = 1 | Universal |
| `CSI n ^` | SD | Scroll down — xterm alias for `CSI n T`. ECMA-48 assigns `^` to SIMD instead | n = 1 | Partial |
| `CSI t;b r` | DECSTBM | Set the top and bottom scroll margins. Requires b > t and at least two rows, else the sequence is ignored entirely. Homes the cursor (respecting DECOM) as a side effect | **t = 1, b = screen height** — that is, omitting both resets to the full screen | Universal |
| `CSI l;r s` | DECSLRM | Set left and right margins. **Only recognized when DECLRMM (`?69`) is set**; otherwise this is SCOSC. Requires r > l. Homes the cursor | **l = 1, r = screen width** | Partial |
| `CSI n SP @` | SL | Shift the contents of the scroll region left n columns | n = 1 | Rare |
| `CSI n SP A` | SR | Shift right n columns | n = 1 | Rare |
| `CSI n ' }` | DECIC | Insert n blank columns at the cursor column, shifting the rest right | n = 1 | Rare |
| `CSI n ' ~` | DECDC | Delete n columns at the cursor column, shifting the rest left | n = 1 | Rare |
| `CSI n U` | NP | Next page | n = 1 | Obsolete |
| `CSI n V` | PP | Preceding page | n = 1 | Obsolete |

The `CSI s` ambiguity is resolved by parameter count and by DECLRMM: no parameters →
save cursor; two parameters with `?69` set → margins. Most emulators just check
DECLRMM first.

## 4. Tabs

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `CSI n g` | TBC | Clear tab stops: 0 = the stop at the cursor column, 3 = every stop. Values 1, 2, 4, 5 are line-tabulation variants nothing implements | n = 0 | Universal |
| `CSI n W` | CTC | Cursor tabulation control — set or clear stops by a selector | n = 0 (set a stop at the cursor) | Rare |
| `CSI ? 5 W` | DECST8C | Reset tab stops to every 8 columns. **Only the parameter 5 is valid**; any other value should be ignored, not defaulted | none — 5 required | Partial |
| `CSI n I` / `CSI n Z` | CHT / CBT | Move forward/back n tab stops | n = 1 | Wide |

`ESC H` (HTS) sets a stop at the cursor. Tab stops are per-column and survive resize in
most implementations — decide your policy early.

## 5. SGR — `CSI ... m`

Parameters are a list applied left to right, each one modifying the current pen.
**Default: an omitted or empty parameter is 0 (reset)** — so `CSI m` and `CSI ;m` both
reset everything. **Support: Universal** for 0–9/22–29/30–49, **Wide** for the rest
unless noted.

| Params | Meaning | Support |
|---|---|---|
| 0 | Reset all | Universal |
| 1 / 2 | Bold / dim (faint) | Universal / Wide |
| 3 | Italic | Wide |
| 4 | Underline | Universal |
| 5 / 6 | Slow blink / rapid blink | Partial (6 usually mapped to 5) |
| 7 | Reverse video | Universal |
| 8 | Conceal | Partial |
| 9 | Strikethrough | Wide |
| 10–19 | Select primary / alternate font | Rare |
| 20 | Fraktur | Rare |
| 21 | Double underline (some terminals: bold off) | Partial |
| 22 | Normal intensity (clears both 1 and 2) | Universal |
| 23 / 24 / 25 | No italic / no underline / no blink | Universal |
| 26 | Proportional spacing | Rare |
| 27 / 28 / 29 | No reverse / reveal / no strikethrough | Universal |
| 30–37 | Foreground, 8 colors | Universal |
| 38 | Extended fg — `38;5;n` or `38;2;r;g;b`, colon form `38:2::r:g:b` | Wide |
| 39 | Default foreground | Universal |
| 40–47 | Background, 8 colors | Universal |
| 48 | Extended bg, same forms as 38 | Wide |
| 49 | Default background | Universal |
| 50 | Disable proportional spacing | Rare |
| 51 / 52 | Framed / encircled | Rare |
| 53 | Overlined | Partial |
| 54 / 55 | No frame or encircle / no overline | Rare |
| 58 | Underline color, same 5/2 forms | Partial (kitty, VTE, wezterm, foot) |
| 59 | Default underline color | Partial |
| 60–65 | Ideogram attributes | Rare |
| 73 / 74 / 75 | Superscript / subscript / neither | Rare (mintty, VTE) |
| 90–97 | Bright foreground | Wide |
| 100–107 | Bright background | Wide |

An unknown parameter should be skipped and the rest of the list applied — never abort the
whole SGR sequence because of one unrecognized attribute.

**Push/pop SGR** (xterm): `CSI # {` XTPUSHSGR, `CSI # }` / `CSI # q` XTPOPSGR,
`CSI # |` XTREPORTSGR. Support: Rare.

### 5.1 Subparameters — the colon separator

A CSI parameter list is not a flat array of integers. Each parameter is itself a list of
**subparameters**, separated by `:` (0x3A). `;` advances to the next parameter, `:`
advances to the next subparameter within the current one.

```
CSI 1 ; 4:3 ; 38:2::255:0:0 m
     └─┬─┘ └┬┘ └──────┬──────┘
       1    2         3          ← three parameters
            ↑         ↑
       2 subparams   6 subparams
```

ECMA-48 reserves 0x3A as a separator within a parameter value; ITU T.416 (ISO 8613-6)
defined the actual usage.

**Why it exists.** With the legacy semicolon form `38;2;255;0;0`, a parser must already
know that 38 followed by 2 consumes three more arguments — otherwise it cannot tell where
the color ends and the next attribute begins, and it mangles or abandons the rest of the
list. The colon form is **self-delimiting**: `38:2::255:0:0` is one parameter, so a parser
that has never heard of it skips to the next `;` and carries on correctly. That is the
entire motivation for the separator.

#### Where colons are used

**1. SGR extended colors — 38, 48, 58**

| Form | Meaning | Support |
|---|---|---|
| `38:5:n` | Indexed, 256-color | Wide |
| `38:2::r:g:b` | Direct RGB, ITU-correct — the empty slot is the colorspace id | Wide |
| `38:2:r:g:b` | Direct RGB with the colorspace slot omitted entirely | Wide (accepted in practice) |
| `38:2::r:g:b:tol:tolcs` | Full T.416 form with tolerance and tolerance colorspace | Rare |
| `38:3::c:m:y` | CMY | Rare |
| `38:4::c:m:y:k` | CMYK | Rare |
| `38:0` / `38:1` | Implementation-defined / transparent | Rare |

Identical forms apply to `48` (background) and `58` (underline color).

*The practical rule for `38:2`:* count the subparameters. Six elements means index 2 is the
colorspace id — skip it, RGB is at 3/4/5. Five elements means RGB is at 2/3/4. Both are
emitted by real software, so dispatch on length rather than assuming a shape.

**2. SGR underline style — `4:x`**

`4:0` none, `4:1` single, `4:2` double, `4:3` curly, `4:4` dotted, `4:5` dashed. A kitty
extension adopted by VTE, wezterm, foot and iTerm2. Support: Partial. Note that bare `4`
is still plain underline, and `4:0` is equivalent to `24`.

**3. Kitty keyboard protocol — `CSI ... u`**

```
CSI key:shifted:base ; modifiers:event-type ; text-codepoints u
```

Both the key field and the modifier field are subparameter groups; `event-type` is
1 press, 2 repeat, 3 release. Trailing groups may be omitted. This is input flowing
terminal → application, so a multiplexer has to parse and re-emit it.

#### Where they are not used

Nowhere else in CSI. No cursor movement, erase, scrolling, mode or report sequence takes a
colon — one appearing there is malformed.

Two adjacent uses of `:` are a different mechanism entirely: **OSC 8** hyperlink params
(`id=xyz:foo=bar`) are parsed by the OSC 8 handler, not the CSI parameter lexer, and the
kitty **graphics** protocol uses commas inside APC.

#### Implementation notes

- Store parameters as a list of lists, or as a flat array with a "continues the previous
  parameter" flag per slot. Retrofitting this touches every SGR case, so decide early.
- **Empty subparameters carry meaning** — `38:2::255:0:0` has a genuinely empty slot at
  index 2. Don't collapse empty to 0 here, for the same reason as with `;` (§0.1).
- Cap subparameters per parameter, not just total parameters.
- A colon in a sequence whose handler doesn't expect one: xterm discards the whole sequence.
  That is a defensible default, though within SGR it is friendlier to skip just that
  parameter and continue.
- **Accept both forms; emit only the semicolon form.** `38;2;r;g;b` is the safe wire format.
  The colon form is the one you must reliably parse, not the one to produce.

## 6. Modes — SM / RM (ANSI, no `?`)

`CSI n h` set · `CSI n l` reset. Multiple parameters allowed, applied left to right.
**No default: a mode sequence with no parameter is a no-op**, since 0 is not a valid mode
number in either the ANSI or the private space.

| n | Name | Effect | Support |
|---|---|---|---|
| 1 | GATM | Guarded area transfer | Obsolete |
| 2 | KAM | Keyboard action (lock) | Rare |
| 3 | CRM | Display control chars literally | Rare |
| 4 | **IRM** | **Insert / replace mode** | Wide |
| 5 | SRTM | Status report transfer | Obsolete |
| 6 | ERM | Erasure mode | Obsolete |
| 7 | VEM | Vertical editing | Obsolete |
| 8–11 | BDSM, DCSM, HEM, PUM | Bidi / device component / horizontal editing / positioning unit | Obsolete |
| 12 | SRM | Send-receive; **reset** = local echo on | Partial |
| 13–19 | FEAM…EBM | Format effector, multiple area, transfer, tab stop, editing boundary | Obsolete |
| 20 | LNM | Newline mode: LF also does CR | Wide |
| 21 | GRCM | Graphic rendition combination | Obsolete |
| 22 | ZDM | Zero default mode | Obsolete |

Only 4, 12 and 20 are worth real implementation. Note SRM's inverted sense: *set* means
no local echo.

## 7. Modes — DECSET / DECRST (private, `?`)

`CSI ? n h` set · `CSI ? n l` reset.

### Core VT

| n | Name | Effect | Support |
|---|---|---|---|
| 1 | DECCKM | Cursor keys send `SS3 A` instead of `CSI A` | Universal |
| 2 | DECANM | Reset drops to VT52 emulation | Rare |
| 3 | DECCOLM | 132/80 columns; clears screen, resets margins | Partial |
| 4 | DECSCLM | Smooth scroll (cosmetic) | Rare |
| 5 | DECSCNM | Reverse video, whole screen | Wide |
| 6 | DECOM | Origin mode — addressing relative to margins | Wide |
| 7 | DECAWM | Autowrap; drives the pending-wrap latch | Universal |
| 8 | DECARM | Auto-repeat keys | Rare |
| 9 | — | X10 mouse reporting (press only) | Obsolete |
| 10 | — | Show toolbar (rxvt) | Rare |
| 12 | — | Cursor blink (att610) | Wide |
| 13 / 14 | — | Blink control variants (xterm) | Rare |
| 18 / 19 | DECPFF / DECPEX | Print form feed / print extent | Rare |
| 25 | DECTCEM | Cursor visible | Universal |
| 30 | — | Show scrollbar (rxvt) | Rare |
| 35 | — | Enable font shifting (rxvt) | Rare |
| 38 | DECTEK | Tektronix mode | Rare |
| 40 | — | Allow 80↔132 switching (gates DECCOLM in xterm) | Partial |
| 41 | — | `more(1)` fix | Rare |
| 42 | DECNRCM | National replacement charsets | Rare |
| 44 | — | Margin bell | Rare |
| 45 | — | Reverse wraparound: BS at col 1 goes to prev line's end | Wide |
| 46 | — | Start logging | Rare |
| 47 | — | Alt screen, legacy form | Obsolete |
| 66 | DECNKM | Application keypad | Wide |
| 67 | DECBKM | Backspace sends BS instead of DEL | Partial |
| 68 | DECKBUM | Keyboard usage (typewriter/data) | Rare |
| 69 | DECLRMM | Enable left/right margins; gates DECSLRM | Partial |
| 80 | DECSDM | Sixel scrolling | Rare |
| 95 | DECNCSM | Don't clear screen on DECCOLM | Rare |

### Alt screen

| n | Effect | Support |
|---|---|---|
| 47 | Old alt buffer; no clear, no cursor save | Obsolete |
| 1047 | Alt buffer, clears on exit | Partial |
| 1048 | Save/restore cursor only | Partial |
| **1049** | Save cursor + switch to a cleared alt buffer | Universal |

1049 is what every full-screen app uses. Implement 47/1047/1048 in terms of it.

### Mouse

Two orthogonal axes — *what* gets reported, and *how* it's encoded. Setting one of each
is the normal pattern.

| n | Effect | Support |
|---|---|---|
| 9 | X10: press only, no modifiers | Obsolete |
| 1000 | Normal: press + release | Universal |
| 1001 | Highlight tracking (can hang the app) | Rare |
| 1002 | Button-event: motion while a button is held | Wide |
| 1003 | Any-event: all motion | Wide |
| 1004 | Focus in/out → `CSI I` / `CSI O` | Wide |
| 1005 | UTF-8 encoding | Obsolete |
| **1006** | SGR encoding: `CSI < b ; x ; y M` press, `m` release | Wide |
| 1015 | urxvt encoding | Partial |
| 1016 | SGR-pixel encoding | Rare |

Legacy X10 encoding breaks past column 223, which is the whole reason 1006 exists.
Implement 1000 + 1002 + 1003 + 1006 and you're done.

### Keyboard / input behavior

| n | Effect | Support |
|---|---|---|
| 1034 | Interpret Meta key, sets high bit | Partial |
| 1035 | Special modifiers for Alt and NumLock | Rare |
| 1036 | Meta sends Escape prefix | Wide |
| 1037 | Delete key sends DEL instead of `CSI 3~` | Partial |
| 1039 | Alt sends Escape prefix | Wide |
| 1040–1046 | Keep selection, select-to-clipboard, urgency/raise on bell, reverse-wrap ext, allow alt screen | Rare |
| 2004 | Bracketed paste: wraps pastes in `CSI 200~` … `CSI 201~` | Wide |
| 7727 | Application escape key | Rare |

### Modern extensions

| n | Effect | Support |
|---|---|---|
| 2026 | Synchronized output — batch a frame, then flip | Wide (kitty, wezterm, foot, alacritty, iTerm2) |
| 2027 | Grapheme clustering for width calculation | Partial |
| 2048 | In-band resize notifications | Partial, growing |
| 1070 | Private color palette for sixel | Rare |
| 8452 | Sixel cursor to the right of graphic | Rare |

### Querying and saving modes

| Seq | Name | Meaning | Support |
|---|---|---|---|
| `CSI ? n $ p` | DECRQM | Query private mode | Wide |
| `CSI n $ p` | DECRQM | Query ANSI mode | Partial |
| `CSI ? n ; v $ y` | DECRPM | Reply: v = 0 unrecognized, 1 set, 2 reset, 3 permanently set, 4 permanently reset | Wide |
| `CSI ? n s` | XTSAVE | Push mode onto the save stack | Partial |
| `CSI ? n r` | XTRESTORE | Pop mode from the save stack | Partial |

DECRQM is how apps feature-detect 2026 and 2027 — get it right for those two at minimum,
and return 0 (unrecognized) for anything you don't implement rather than lying.

## 8. Reports & queries

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `CSI c` / `CSI 0 c` | DA1 | Ask what the terminal is. Reply lists feature codes, e.g. `CSI ? 62 ; 22 c` = VT220 with ANSI color. **Any parameter other than 0 should be ignored** | n = 0 | Universal |
| `CSI > c` | DA2 | Secondary DA → `CSI > type ; version ; 0 c`. Apps use the version field for feature sniffing | n = 0 | Wide |
| `CSI = c` | DA3 | Tertiary DA → a DCS-wrapped unit identifier | n = 0 | Rare |
| `CSI 5 n` | DSR | Report operating status → `CSI 0 n` (OK) or `CSI 3 n` (malfunction) | none — 5 required | Wide |
| `CSI 6 n` | CPR | Report cursor position → `CSI r ; c R`, 1-based, **relative to the margins if DECOM is set** | none — 6 required | Universal |
| `CSI ? 6 n` | DECXCPR | Extended report including page → `CSI ? r ; c ; page R` | none | Partial |
| `CSI ? 15 n` | — | Printer status | none | Rare |
| `CSI ? 25 n` | — | User-defined key status | none | Rare |
| `CSI ? 26 n` | — | Keyboard status / language | none | Rare |
| `CSI n x` | DECREQTPARM | Request terminal parameters (baud, parity) | n = 0 | Obsolete |
| `CSI > q` | XTVERSION | Report name and version → `DCS > \| name ESC \` | n = 0 | Partial, growing |
| `CSI ? u` | — | Query the kitty keyboard flags → `CSI ? flags u` | none | Partial |
| `CSI ? 4 m` | XTQMODKEYS | Query modifyOtherKeys state | none | Rare |

DA1 is the single most important report: many apps block waiting for it, and a terminal
that never answers appears to hang. Answer it before you answer anything else.

`DECRQSS` — query the current value of a setting — is DCS, not CSI:
`DCS $ q <final> ESC \` → `DCS 1 $ r <value> <final> ESC \`.

## 9. Window operations — `CSI ... t` (XTWINOPS)

**No useful default: `CSI t` with no parameter is a no-op.** The first parameter selects
the operation; later parameters are its arguments and default to 0.

| Params | Meaning | Support |
|---|---|---|
| 1 / 2 | De-iconify / iconify | Partial |
| 3 ; x ; y | Move window | Partial |
| 4 ; h ; w | Resize in pixels | Partial |
| 5 / 6 | Raise / lower | Partial |
| 7 | Refresh | Partial |
| 8 ; r ; c | Resize in characters | Partial |
| 9 ; n | Maximize / restore | Partial |
| 10 ; n | Fullscreen control | Partial |
| 11 / 13 / 14 / 15 / 16 / 18 / 19 | Report state, position, pixel size, screen size, cell size, char size, screen chars | Wide (14, 16, 18 especially) |
| 20 / 21 | Report icon label / window title | Partial — a known security issue, many terminals disable it |
| 22 ; n | Push title onto stack | Wide |
| 23 ; n | Pop title from stack | Wide |
| ≥ 24 | Resize to n lines | Rare |

`CSI 14 t` (pixel size) and `CSI 16 t` (cell size) are how apps compute image geometry —
those two plus 18 are the ones worth implementing. Title *reporting* (20/21) lets a remote
process inject its own title back as input; treat it as opt-out by default.

## 10. Presentation / device control

| Seq | Name | What it does | Default | Support |
|---|---|---|---|---|
| `CSI n SP q` | DECSCUSR | Set cursor shape: 0 and 1 both = blinking block, 2 = steady block, 3 = blinking underline, 4 = steady underline, 5 = blinking bar, 6 = steady bar | n = 0 (blinking block) | Wide |
| `CSI n " q` | DECSCA | Set the character protection attribute for subsequently written cells: 0 or 2 = erasable, 1 = protected from DECSEL/DECSED | n = 0 | Rare |
| `CSI n " p` | DECSCL | Set conformance level (61 = VT100, 62 = VT200, 63/64/65 = VT300/400/500). A second parameter selects 7- or 8-bit C1. **Performs a hard reset as a side effect** | n = 62 in most implementations | Rare |
| `CSI ! p` | DECSTR | Soft terminal reset — see the note below | no params | Wide |
| `CSI n q` | DECLL | Load LEDs: 0 = all off, 1–4 = LED on, 21–24 = LED off | n = 0 | Rare |
| `CSI n i` | MC | Media copy (print): 0 = print the screen, 4 = printer controller off, 5 = printer controller on | n = 0 | Rare |
| `CSI ? n i` | DECMC | Private media copy: 1 = print cursor line, 4/5 = autoprint off/on, 10 = print screen, 11 = print all pages | n = 0 | Rare |
| `CSI n o` | DAQ | Define area qualification | n = 0 | Obsolete |
| `CSI n SP t` | DECSWBV | Warning bell volume | Rare |
| `CSI n SP u` | DECSMBV | Margin bell volume | Rare |
| `CSI & u` | DECRQUPSS | Request user-preferred supplemental set | Rare |
| `CSI n * \|` | DECSNLS | Set lines per screen | Rare |
| `CSI n $ \|` | DECSCPP | Set columns per page | Rare |
| `CSI n $ }` | DECSASD | Select active status display | Rare |
| `CSI n $ ~` | DECSSDT | Status display type | Rare |
| `CSI > n p` | XTSMPOINTER | Pointer visibility mode | Rare |
| `CSI > n m` | XTMODKEYS | modifyOtherKeys / modifyCursorKeys etc. | Partial |
| `CSI > n n` | — | Reset a modifyKeys resource | Partial |
| `CSI > n t` | — | Title mode flags | Rare |
| `CSI # P` / `# Q` / `# R` | XTPUSHCOLORS / XTPOPCOLORS / XTREPORTCOLORS | Color palette stack | Rare |

DECSTR is the one to get right. It resets: origin mode, DECAWM on, DECOM off, insert mode
off, cursor visible, margins to full screen, SGR to default, charsets to ASCII, saved cursor
to home, and DECSCA off. It does *not* clear the screen or reset tab stops.

## 11. Rectangular area operations (VT420, `$` family)

| Seq | Name | Meaning | Support |
|---|---|---|---|
| `CSI t;l;b;r;p;t;l;b;r;p $ v` | DECCRA | Copy rectangle | Rare |
| `CSI c;t;l;b;r $ x` | DECFRA | Fill rectangle with a character | Rare |
| `CSI t;l;b;r $ z` | DECERA | Erase rectangle | Rare |
| `CSI t;l;b;r $ {` | DECSERA | Selective erase rectangle | Rare |
| `CSI attrs;t;l;b;r $ r` | DECCARA | Change attributes in rectangle | Rare |
| `CSI attrs;t;l;b;r $ t` | DECRARA | Reverse attributes in rectangle | Rare |
| `CSI id;pg;t;l;b;r * y` | DECRQCRA | Checksum of rectangle | Rare |
| `CSI n * x` | DECSACE | Select attribute change extent (rect vs stream) | Rare |

Almost nothing uses these outside of DEC-era software and terminal test suites —
though `DECRQCRA` is how vttest and some conformance harnesses verify screen content.

## 12. Locator (DEC mouse alternative)

| Seq | Name | Meaning | Support |
|---|---|---|---|
| `CSI n ; n ' z` | DECELR | Enable locator reporting | Rare |
| `CSI n ' {` | DECSLE | Select locator events | Rare |
| `CSI n ' \|` | DECRQLP | Request locator position | Rare |
| `CSI n ; n ; n ; n ; n ' w` | DECEFR | Enable filter rectangle | Rare |

Superseded entirely by xterm mouse modes (§7). Parse and discard.

## 13. Graphics

| Seq | Name | Meaning | Support |
|---|---|---|---|
| `CSI ? i ; a ; v S` | XTSMGRAPHICS | Set/query sixel or ReGIS geometry and color registers | Partial |

Sixel image data itself arrives via DCS (`DCS q ... ST`), not CSI. Kitty's graphics
protocol uses APC. Both are outside the CSI layer but interact with it through cursor
positioning and scrolling.

## 14. Kitty keyboard protocol — final byte `u`

| Seq | Meaning | Support |
|---|---|---|
| `CSI ? u` | Query current flags → `CSI ? flags u` | Partial |
| `CSI = flags ; mode u` | Set flags (mode 1 = all, 2 = set bits, 3 = clear bits) | Partial |
| `CSI > flags u` | Push flags onto the stack | Partial |
| `CSI < n u` | Pop n entries from the stack | Partial |

Supported by kitty, foot, wezterm, ghostty, and increasingly others. Note the collision:
bare `CSI u` with no private marker is SCORC (restore cursor), an entirely different
command. Dispatch on the private marker.

## 15. Dispatch index by final byte

The table your parser actually needs. `SP` = 0x20.

| Final | No intermediate | `SP` | `!` | `"` | `#` | `$` | `'` | `*` | `>` / `?` / `<` / `=` prefix |
|---|---|---|---|---|---|---|---|---|---|
| `@` | ICH | SL | | | | | | | |
| `A` | CUU | SR | | | | | | | |
| `B` | CUD | | | | | | | | |
| `C` | CUF | | | | | | | | |
| `D` | CUB | | | | | | | | |
| `E` | CNL | | | | | | | | |
| `F` | CPL | | | | | | | | |
| `G` | CHA | | | | | | | | |
| `H` | CUP | | | | | | | | |
| `I` | CHT | | | | | | | | |
| `J` | ED | | | | | | | | `?` DECSED |
| `K` | EL | | | | | | | | `?` DECSEL |
| `L` | IL | | | | | | | | |
| `M` | DL | | | | | | | | |
| `N` | EF | | | | | | | | |
| `O` | EA | | | | | | | | |
| `P` | DCH | | | | `#` XTPUSHCOLORS | | | | |
| `Q` | SEE | | | | `#` XTPOPCOLORS | | | | |
| `R` | CPR (reply) | | | | `#` XTREPORTCOLORS | | | | |
| `S` | SU | | | | | | | | `?` XTSMGRAPHICS |
| `T` | SD | | | | | | | | |
| `U` | NP | | | | | | | | |
| `V` | PP | | | | | | | | |
| `W` | CTC | | | | | | | | `?` DECST8C |
| `X` | ECH | | | | | | | | |
| `Y` | CVT | | | | | | | | |
| `Z` | CBT | | | | | | | | |
| `^` | SD (xterm) | | | | | | | | |
| `` ` `` | HPA | | | | | | | | |
| `a` | HPR | | | | | | | | |
| `b` | REP | | | | | | | | |
| `c` | DA1 | | | | | | | | `>` DA2, `=` DA3 |
| `d` | VPA | | | | | | | | |
| `e` | VPR | | | | | | | | |
| `f` | HVP | | | | | | | | |
| `g` | TBC | | | | | | | | |
| `h` | SM | | | | | | | | `?` DECSET |
| `i` | MC | | | | | | | | `?` DECMC |
| `j` | HPB | | | | | | | | |
| `k` | VPB | | | | | | | | |
| `l` | RM | | | | | | | | `?` DECRST |
| `m` | SGR | | | | | | | | `>` XTMODKEYS, `?` XTQMODKEYS |
| `n` | DSR | | | | | | | | `?` DECDSR, `>` reset modifyKeys |
| `o` | DAQ | | | | | | | | |
| `p` | | | DECSTR | DECSCL | | DECRQM | | | `>` XTSMPOINTER, `?$` DECRQM private |
| `q` | DECLL | DECSCUSR | | DECSCA | XTPOPSGR | | | | `>` XTVERSION |
| `r` | DECSTBM | | | | | DECCARA | | | `?` XTRESTORE |
| `s` | SCOSC / DECSLRM | | | | | | | | `?` XTSAVE |
| `t` | XTWINOPS | DECSWBV | | | | DECRARA | | | `>` title modes |
| `u` | SCORC | DECSMBV | | | | | | | `?` `=` `>` `<` kitty keyboard |
| `v` | | | | | | DECCRA | | | |
| `w` | | | | | | | DECEFR | | |
| `x` | DECREQTPARM | | | | | DECFRA | | DECSACE | |
| `y` | | | | | | | | DECRQCRA | |
| `z` | | | | | | DECERA | DECELR | | |
| `{` | | | | | XTPUSHSGR | DECSERA | DECSLE | | |
| `\|` | | | | | XTREPORTSGR | DECSCPP | DECRQLP | DECSNLS | |
| `}` | | | | | XTPOPSGR | DECSASD | DECIC | | |
| `~` | | | | | | DECSSDT | DECDC | | |

---

## Implementation order

Roughly by value per unit of effort:

1. **Cursor movement** — CUU/CUD/CUF/CUB, CUP, CHA, VPA
2. **Erase and edit** — ED, EL, ICH, DCH, IL, DL, ECH
3. **SGR** — including colon subparameters from day one
4. **Scroll region** — DECSTBM, plus SU/SD
5. **DECAWM and the pending-wrap latch**
6. **Private modes** — 25 (cursor), 1049 (alt screen), 2004 (paste), 1000/1002/1003/1006 (mouse), 1 (cursor keys)
7. **Reports** — DA1, CPR, DSR
8. **DECSTR**, DECSCUSR, XTWINOPS 14/16/18
9. **Synchronized output** (2026) once you have a render loop worth batching
10. Everything tagged Rare — parse and discard

Two subtleties worth designing for before you write the grid code, because retrofitting
either one means touching every cursor operation:

- **The pending-wrap latch.** After printing into the last column the cursor stays put in a
  "wrap before next print" state rather than moving. Every cursor movement clears the latch;
  `DECSC`/`DECRC` save and restore it.
- **DECOM.** Origin mode changes what row 1 means for CUP, VPA and friends, and it also
  clamps the cursor inside the margins. It's a property of every absolute addressing
  operation, not a special case in one of them.

---

## Related references

- [Control characters (C0, C1, plain escapes)](control-characters-reference.md)
- **[CSI sequences** — you are here](CSI-reference.md)
- [OSC sequences](OSC-reference.md)
- [DCS sequences](DCS-reference.md)
- [APC, SOS and PM strings](APC-SOS-PM-reference.md)
