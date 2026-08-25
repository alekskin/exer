#!/usr/bin/env bash
#
# test_styles.sh — exercise SGR styling (\e[...m) and its edge cases.
# Run INSIDE your multiplexer, and in a real terminal (xterm/kitty/alacritty)
# to compare. Press ENTER to advance between groups.
#
# Every line RESETS with \e[0m at the end so a bug in one test can't bleed
# into the next.

ESC=$'\e'
CSI="${ESC}["
R="${CSI}0m"          # full reset

pause() { read -r -p "  [enter for next] " _; }
title() { printf '\n%s=== %s ===%s\n' "$CSI"'1;7m' "$1" "$R"; }
label() { printf '%-28s' "$1"; }   # left column describing the test

# ---------------------------------------------------------------------------
# title "1. Single attributes"
# label "bold (1)";        printf '%s1mBOLD%s\n'        "$CSI" "$R"
# label "dim (2)";         printf '%s2mDIM%s\n'         "$CSI" "$R"
# label "italic (3)";      printf '%s3mITALIC%s\n'      "$CSI" "$R"
# label "underline (4)";   printf '%s4mUNDER%s\n'       "$CSI" "$R"
# label "blink (5)";       printf '%s5mBLINK%s\n'       "$CSI" "$R"
# label "inverse (7)";     printf '%s7mINVERSE%s\n'     "$CSI" "$R"
# label "hidden (8)";      printf '%s8mHIDDEN(invisible)%s\n' "$CSI" "$R"
# label "strike (9)";      printf '%s9mSTRIKE%s\n'      "$CSI" "$R"
# pause

# ---------------------------------------------------------------------------
# title "2. Basic 16 foreground / background"
# label "fg 30-37";  for n in 30 31 32 33 34 35 36 37; do printf '%s%dm%d ' "$CSI" "$n" "$n"; done; printf '%s\n' "$R"
# label "fg 90-97";  for n in 90 91 92 93 94 95 96 97; do printf '%s%dm%d ' "$CSI" "$n" "$n"; done; printf '%s\n' "$R"
# label "bg 40-47";  for n in 40 41 42 43 44 45 46 47; do printf '%s%dm %d %s' "$CSI" "$n" "$n" "$R"; done; printf '\n'
# label "bg 100-107";for n in 100 101 102 103 104 105 106 107; do printf '%s%dm %d %s' "$CSI" "$n" "$n" "$R"; done; printf '\n'
# pause

# ---------------------------------------------------------------------------
# title "3. 256-color + truecolor"
# label "256 fg 38;5;N"; for n in 196 208 46 21 201; do printf '%s38;5;%dmC%d ' "$CSI" "$n" "$n"; done; printf '%s\n' "$R"
# label "256 bg 48;5;N"; for n in 196 208 46 21 201; do printf '%s48;5;%dm %d %s' "$CSI" "$n" "$n" "$R"; done; printf '\n'
# label "rgb fg 38;2";  printf '%s38;2;255;100;200mPINK%s ' "$CSI" "$R"; printf '%s38;2;100;200;255mSKY%s\n' "$CSI" "$R"
# label "rgb bg 48;2";  printf '%s48;2;40;40;40m%s38;2;255;180;0m dark-bg amber-fg %s\n' "$CSI" "$CSI" "$R"
# pause

# ---------------------------------------------------------------------------
title "4. Combined in ONE sequence (semicolon-chained)"
label "bold+underline";        printf '%s1;4mB+U%s\n' "$CSI" "$R"
label "bold+red-fg+blue-bg";   printf '%s1;31;44mmixed%s\n' "$CSI" "$R"
label "the big one";           printf '%s1;3;4;38;5;196;48;5;25mall-at-once%s\n' "$CSI" "$R"
label "italic+rgb fg+rgb bg";  printf '%s3;38;2;255;255;0;48;2;80;0;80mfancy%s\n' "$CSI" "$R"
pause

# ---------------------------------------------------------------------------
title "5. Attribute-OFF codes (should cancel just that attribute)"
label "22 cancels bold/dim"; printf '%s1;31mbold-red%s22m still-red-not-bold%s\n' "$CSI" "$CSI" "$R"
label "24 cancels underline";printf '%s4;32munder-green%s24m still-green-flat%s\n' "$CSI" "$CSI" "$R"
label "27 cancels inverse";  printf '%s7;33minverse%s27m normal-yellow%s\n' "$CSI" "$CSI" "$R"
label "29 cancels strike";   printf '%s9;36mstrike%s29m plain-cyan%s\n' "$CSI" "$CSI" "$R"
label "39 default fg";       printf '%s31;44mred/blue-bg%s39m default-fg-blue-bg%s\n' "$CSI" "$CSI" "$R"
label "49 default bg";       printf '%s31;44mred/blue-bg%s49m red-default-bg%s\n' "$CSI" "$CSI" "$R"
pause

# ---------------------------------------------------------------------------
title "6. EDGE CASES — this is where emulators disagree"

label "empty param = 0";     printf '%s1;31mBR%smreset-via-empty%s\n' "$CSI" "$CSI" "$R"
# ^ \e[m  with no number must behave exactly like \e[0m

label "0 mid-sequence";      printf '%s1;31;0;4monly-underline%s\n' "$CSI" "$R"
# ^ bold+red then 0 wipes them, then 4 applies -> should be plain underlined

label "0 at end wins";       printf '%s1;31;0mnothing-set%s\n' "$CSI" "$R"
# ^ ends cleared: not bold, default color

label "leading zeros 01;04"; printf '%s01;04mzero-padded%s\n' "$CSI" "$R"
# ^ "01" should parse as 1, "04" as 4 -> bold underline

label "bare CSI m";          printf '%smBARE-M-is-reset%s\n' "$CSI" "$R"

label "double semicolons";   printf '%s1;;4mbold--under%s\n' "$CSI" "$R"
# ^ the empty middle param is a 0 (reset) between them! result: just underline

label "unknown code 73";     printf '%s73munknown-should-ignore%s\n' "$CSI" "$R"
# ^ unassigned SGR code: ignore, don't crash, keep printing

label "huge param 999";      printf '%s999mout-of-range-ignore%s\n' "$CSI" "$R"

label "trailing semicolon";  printf '%s1;31;mtrailing-semi%s\n' "$CSI" "$R"
# ^ trailing empty param = trailing 0 -> everything reset, text plain
pause

# ---------------------------------------------------------------------------
title "7. Persistence across newlines / no reset"
printf '%s42;30m' "$CSI"   # green bg, black fg, DELIBERATELY not reset
printf 'this line has bg\n'
printf 'and this NEXT line should keep the same bg until reset\n'
printf '%s\n' "$R"
printf 'after reset: back to normal\n'
pause

# ---------------------------------------------------------------------------
title "8. 256-color ramp (visual sanity of the palette)"
for n in $(seq 0 15);  do printf '%s48;5;%dm  ' "$CSI" "$n"; done; printf '%s\n' "$R"
for n in $(seq 16 51); do printf '%s48;5;%dm ' "$CSI" "$n"; done; printf '%s\n' "$R"
for n in $(seq 232 255); do printf '%s48;5;%dm ' "$CSI" "$n"; done; printf '%s (grayscale)\n' "$R"
pause

title "done"
printf 'all style tests complete%s\n' "$R"
