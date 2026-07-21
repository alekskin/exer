package main

import "core:fmt"
import "core:sys/posix"

cur_term_settings: posix.termios
save_current_terminal :: proc() {
    switch posix.tcgetattr(posix.STDIN_FILENO, &cur_term_settings) {
    case .OK: fmt.println("saved terminal settings")
    case .FAIL: panic("Failed to get terminal settings")
    }
}
restore_current_terminal :: proc() {
    switch posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &cur_term_settings) {
    case .OK: fmt.println("restored terminal settings")
    case .FAIL: panic("failed to restore terminal settings")
    }
}

put_term_rawmode :: proc() {
    new_settings: posix.termios = cur_term_settings // copy
    new_settings.c_lflag -= {.ICANON, .ECHO, .ECHOE, .ECHOK, .ECHONL, .ISIG, .IEXTEN}
    new_settings.c_iflag -= {.ISTRIP, .BRKINT, .INLCR, .IGNCR, .ICRNL, .IXON, .IXOFF, .PARMRK}
    new_settings.c_oflag -= {.OPOST}
    new_settings.c_cc[.VMIN] = 1
    new_settings.c_cc[.VTIME] = 0

    switch posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &new_settings) {
    case .OK: fmt.println("applied raw mode")
    case .FAIL: panic("failed to apply raw mode")
    }
}
