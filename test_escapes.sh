#!/usr/bin/env bash
#
# test_escapes.sh — exercise escape sequences one at a time.
# Run this INSIDE your multiplexer (or a real terminal to compare).
# Press ENTER to advance between tests so you can inspect each frame.
#
# ESC is 0x1B. Using $'\e' for the escape byte.

ESC=$'\e'
CSI="${ESC}["

pause() { read -r -p "  [enter for next] " _; }
title() { printf '\n=== %s ===\n' "$1"; }

# Start clean
printf '%sc' "$ESC"        # RIS: full reset (optional; comment out if unsupported)

title "1. Plain text + newline/carriage-return"
printf 'line one\r\nline two\r\n'
printf 'partial'; printf '\rOVER'    # CR should move cursor to col 0, OVER overwrites
printf '\r\n'
pause

title "2. SGR colors + attributes (m)"
printf '%s1mBOLD%s0m ' "$CSI" "$CSI"
printf '%s4mUNDERLINE%s0m ' "$CSI" "$CSI"
printf '%s7mREVERSE%s0m\r\n' "$CSI" "$CSI"
printf '%s31mRED %s32mGREEN %s34mBLUE%s0m\r\n' "$CSI" "$CSI" "$CSI" "$CSI"
printf '%s38;5;208m256-color-orange%s0m\r\n' "$CSI" "$CSI"
printf '%s38;2;255;100;200mtruecolor-pink%s0m\r\n' "$CSI" "$CSI"
pause

title "3. Cursor movement (A/B/C/D) and positioning (H)"
printf 'X'                       # print at current pos
printf '%s5CY' "$CSI"            # move right 5, print Y
printf '%s2BZ' "$CSI"            # move down 2, print Z
printf '%s10;20HAT-10-20' "$CSI" # absolute position row10 col20
printf '\r\n'
pause

title "4. Erase in line (K): 0=to-eol, 1=to-bol, 2=whole line"
printf 'aaaaaaaaaaaaaaaaaaaa'
printf '\r'
printf '%s0K' "$CSI"            # erase from cursor to end -> should clear the a's
printf 'K0-cleared-to-eol\r\n'
printf 'bbbbbbbbbbbbbbbbbbbb'
printf '%s1K' "$CSI"           # erase from start to cursor
printf '\r\n'
pause

title "5. Erase in display (J): 0=to-end, 1=to-start, 2=whole screen"
printf 'these lines should vanish\r\n'
printf 'when J2 runs\r\n'
printf '%s2J' "$CSI"          # clear whole screen
printf '%s1;1H' "$CSI"        # home
printf 'screen cleared, cursor home\r\n'
pause

title "6. Backspace (0x08) and Tab (0x09)"
printf 'abcXYZ'
printf '\b\b\b   '            # backspace 3, overwrite with spaces
printf '\r\n'
printf 'A\tB\tC\tD\r\n'      # tabs -> should align to tab stops (every 8)
pause

title "7. Bell (0x07)"
printf 'about to beep...'
printf '\a'
printf ' beeped\r\n'
pause

title "8. Wide chars / emoji (each should occupy 2 cells)"
printf 'CJK: 你好世界\r\n'
printf 'emoji: 🚀🔥😀\r\n'
printf 'mixed: a你b好c\r\n'
pause

title "9. Alternate screen (?1049h / l)"
printf '%s?1049h' "$CSI"      # enter alt screen
printf '%s2J%s1;1H' "$CSI" "$CSI"
printf 'THIS IS THE ALTERNATE SCREEN\r\n'
printf 'primary screen content should be hidden\r\n'
pause
printf '%s?1049l' "$CSI"      # leave alt screen -> primary should reappear
printf 'back on primary screen\r\n'
pause

title "10. Cursor hide/show (?25l / ?25h)"
printf 'hiding cursor'
printf '%s?25l' "$CSI"
pause
printf '%s?25h' "$CSI"
printf ' cursor shown again\r\n'
pause

title "11. Line wrap at right edge"
# print a string longer than the terminal width to test your autowrap logic
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890'
printf '1234567890\r\n'
pause

title "done"
printf 'all tests complete\r\n'
