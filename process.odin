package main

import "core:fmt"
import "core:sys/posix"
import "core:sys/linux"
import "core:mem"
import "core:os"
import "core:strings"

log_file: ^os.File

create_logfile :: proc() {
    f, err := os.open(
        "/tmp/mux.log",
        os.File_Flags{ .Create, .Write, .Append, .Trunc },
        os.Permissions{.Execute_User, .Write_User, .Read_User, .Read_Group, .Read_Other}
    )
    if err != nil {
        fmt.eprintln("Error:", err)
    }
    assert(err == nil, "Failed to create logfile")
    log_file = f
}


create_child_process :: proc() {
    create_logfile()
    master_fd := posix.posix_openpt({.RDWR, .NOCTTY})
    assert(master_fd != -1, "Failed to open master PT")
    defer assert(posix.close(master_fd) == .OK, "Failed to close master fd from child")

    assert(posix.grantpt(master_fd) == .OK, "Failed to grant slave access to PT")
    assert(posix.unlockpt(master_fd) == .OK, "Failed to unlock master PT")

    pt_name := posix.ptsname(master_fd)
    assert(pt_name != nil, "Failed to get slave PT name")

    switch pid := posix.fork(); pid {
        case -1: panic("Failed to fork process")
        case 0: handle_child(master_fd, pt_name)
        case: handle_parent(pid, master_fd)
    }
}

handle_child :: proc(master_fd: posix.FD, pt_name: cstring) {
    sid := posix.setsid()
    if sid == -1 {
        panic("Failed to set id on child process")
    }

    slave_fd := posix.open(pt_name, {.RDWR, .NOCTTY})
    if slave_fd == -1 {
        panic("Failed to open slave PT")
    }

    assert(posix.dup2(slave_fd, posix.STDIN_FILENO) != -1, "Failed to route STDIN")
    assert(posix.dup2(slave_fd, posix.STDOUT_FILENO) != -1, "Failed to route STDOUT")
    assert(posix.dup2(slave_fd, posix.STDERR_FILENO) != -1, "Failed to route STDERR")
    assert(posix.close(master_fd) == .OK, "Failed to close master fd from child")
    assert(posix.close(slave_fd) == .OK, "Failed to close slave fd from child")

    cmd := []cstring{"sh", nil}
    ret := posix.execvp(cmd[0], raw_data(cmd))
    fmt.panicf("could not execute: %v, %v", ret, posix.strerror(posix.errno()))
}

// get win size
TIOCGWINSZ :: 0x5413
// set win size
TIOCSWINSZ :: 0x5414

winsize :: struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16
};

LEADER :: 0x02 // Ctrl+B
Q :: 0x71 // q
NL :: 0x0A // \n
CR :: 0x0D // \r
BP :: 0x08 // \b
TAB :: 0x09 // \t
BELL :: 0x07 // \b
ESC :: 0x1B
LSBR :: 0x5B // [
RSBR :: 0x5D // ]
ZERO :: 0x30
WSPACE :: 0x20

Cell :: struct {
    r: rune
}

sequence_type :: enum {
    NONE, // definitely no sequence
    UNKNOWN, // detected but don't know yet
    CSI,
    OSC,
    OTHER
}

State :: struct {
    leader_pending: bool,
    cursor_position: struct {
        row: u16,
        col: u16
    },
    esc_sequence: struct {
        type: sequence_type,
        private: bool,
        buf: [dynamic]u8
    },
    wsize: ^winsize,
    grid: [dynamic]Cell,
    bell: bool
}

handle_parent :: proc(pid: posix.pid_t, master_fd: posix.FD) {
    ws: winsize
    assert(linux.ioctl(linux.STDIN_FILENO, TIOCGWINSZ, uintptr(&ws)) == 0, "Failed to get terminal size")
    assert(linux.ioctl(linux.Fd(master_fd), TIOCSWINSZ, uintptr(&ws)) == 0, "Failed to set terminal size")
    assert(ws.ws_col > 0, "ws_col should be greater than zero")
    assert(ws.ws_row > 0, "ws_row should be greater than zero")

    fds := [?]posix.pollfd{
        {
            fd = master_fd,
            events = { .IN, .HUP },
            revents = {},
        },
        {
            fd = posix.STDIN_FILENO,
            events = { .IN },
            revents = {},
        },
    }

    state := State{
        wsize = &ws,
        grid = make([dynamic]Cell, ws.ws_row * ws.ws_col),
        leader_pending = false,
        cursor_position = {
            row = 0,
            col = 0,
        },
        esc_sequence = {
            type = .NONE,
            private = false,
            buf = make([dynamic]u8, 0, 100),
        },
    }

    // fill the grid with empty values
    for i in 0..<(ws.ws_row * ws.ws_col) {
        state.grid[i].r = WSPACE
    }
    // fill the escape sequence buffer with zeroes

    buf_arr := [1024 * 4]u8{}
    buf := buf_arr[:]


    event_loop: for {
        ready := posix.poll(raw_data(fds[:]), 2, -1)
        assert(ready != -1, "Error occured during poll")

        for fd in fds {
            if fd.revents == {} {
                continue
            }

            if .HUP in fd.revents {
                break event_loop
            }

            bytes_read := posix.read(fd.fd, raw_data(buf), len(buf))
            assert(bytes_read > -1, "Error while reading bytes")

            switch fd.fd {
            case master_fd: {
                for i in 0..<bytes_read {
                    b := buf[i]
                        fmt.fprintfln(log_file, "Conusming byte: %d (%c)", b, b)
                    switch b {
                        case ESC: {
                            fmt.fprintln(log_file, "> ESC detected")
                            state.esc_sequence.type = .UNKNOWN
                            append(&state.esc_sequence.buf, b)
                        }
                        case LSBR: {
                            if state.esc_sequence.type == .UNKNOWN {
                                fmt.fprintln(log_file, "> [ detected, set CSI")
                                state.esc_sequence.type = .CSI
                                append(&state.esc_sequence.buf, b)
                            } else {
                                fmt.fprintln(log_file, "> [ detected, clear")
                                clear_esc(&state)
                                print_and_advance(&state, b)
                            }
                        }
                        case RSBR: {
                            if state.esc_sequence.type == .UNKNOWN {
                                fmt.fprintln(log_file, "> ] detected, set OSC")
                                state.esc_sequence.type = .OSC
                                append(&state.esc_sequence.buf, b)
                            } else {
                                fmt.fprintln(log_file, "> ] detected, clear")
                                clear_esc(&state)
                                print_and_advance(&state, b)
                            }
                        }
                        case: {
                            switch state.esc_sequence.type {
                            case .CSI: {
                                fmt.fprintln(log_file, "> CSI append")
                                append(&state.esc_sequence.buf, b)
                                if b >= 0x40 && b <= 0x7e {
                                    fmt.fprintln(log_file, "> CSI end")
                                    handle_csi_sequence(&state)
                                    clear_esc(&state)
                                }
                            }
                            case .OSC: fmt.fprintln(log_file, "OSC is not supported yet")
                            case .OTHER: fmt.fprintln(log_file, "OTHER sequence type is not supported")
                            case .UNKNOWN: {
                                fmt.fprintln(log_file, "> Some unsupported sequence")
                                // TODO: support simple sequence
                                clear_esc(&state)
                            }
                            case .NONE: {
                                if b < 0x20 {
                                    fmt.fprintln(log_file, "> control char cons")
                                    handle_control_char(&state, b)
                                } else {
                                    fmt.fprintln(log_file, "> Regular byte consumption")
                                    print_and_advance(&state, b)
                                }
                            }
                            }
                        }
                    }
                }

                render_grid(&state)
            }

            case posix.STDIN_FILENO: {
                bytes_before_leader := bytes_read
                for i in 0..<bytes_read {
                    switch buf[i] {
                        case LEADER: {
                            if !state.leader_pending {
                                state.leader_pending = true
                                bytes_before_leader = max(i - 1, 0)
                            }
                        }
                        case Q: {
                            if state.leader_pending {
                                break event_loop
                            }
                        }
                        case: {
                            state.leader_pending = false
                        }
                    }
                }
                if bytes_before_leader > 0 {
                    write(master_fd, raw_data(buf), uint(bytes_before_leader))
                }
            }

            case: fmt.fprintln(log_file, "Unknown FD")
            }
        }
    }
}

clear_esc :: proc(state: ^State) {
    state.esc_sequence.type = .NONE
    state.esc_sequence.private = false
    clear(&state.esc_sequence.buf)
}

print_and_advance :: proc(state: ^State, b: u8) {
    fmt.fprintfln(log_file, "[PA] row: %d, col: %d, sym: %c", state.cursor_position.row, state.cursor_position.col, b)
    state.grid[state.cursor_position.row * state.wsize.ws_col + state.cursor_position.col].r = rune(b)

    if state.cursor_position.col + 1 == state.wsize.ws_col {
        state.cursor_position.row += 1
        if state.cursor_position.row == state.wsize.ws_row {
            state.cursor_position.row -= 1
        }
        state.cursor_position.col += 0
    } else {
        state.cursor_position.col += 1
    }

    fmt.fprintfln(log_file, "[PA] cursor advanced to: %d, col: %d, %c", state.cursor_position.row, state.cursor_position.col, state.grid[state.cursor_position.row * state.wsize.ws_col + state.cursor_position.col-1].r)
    // state.cursor_position.row += (state.cursor_position.col + 1) / state.wsize.ws_col
    // state.cursor_position.col = state.cursor_position.col % state.wsize.ws_col
}

handle_control_char :: proc(state: ^State, char: u8) {
    switch char {
    // move cursor next line
    case NL: {
        state.cursor_position.row = min(state.cursor_position.row + 1, state.wsize.ws_row - 1)
    }
    // move cursor to the beginning of the line
    case CR: {
        state.cursor_position.col = 0
    }
    // move cursor left
    case BP: {
        state.cursor_position.col = max(state.cursor_position.col - 1, 0)
    }
    // move cursor to the next multiple of 8
    case TAB: {
        // next multiple of eight
        next_multiple := (((state.cursor_position.col) | 7) + 1)
        state.cursor_position.col = max(next_multiple, state.wsize.ws_row - 1)
    }

    case BELL: state.bell = true

    case: fmt.fprintln(log_file, "Unknown control char: %d (%c)",  char, char)
    }
}

handle_csi_sequence :: proc(state: ^State) {
    fmt.fprint(log_file, "Current CSI sequence is: ")
    for b in state.esc_sequence.buf {
        if b == ESC {
            fmt.fprintf(log_file, "%d (<ESC>), ", b);
        } else {
            fmt.fprintf(log_file, "%d (%c), ", b, b);
        }
    }
    fmt.fprintf(log_file, "\n")
    assert(state.esc_sequence.type == .CSI, "Attempt to handle non-CSI sequence in CSI handler")
    assert(state.esc_sequence.buf[0] == ESC, "Escape sequence expected to start with ESC")
    assert(state.esc_sequence.buf[1] == LSBR, "CSI escape sequence expect to follow the [ symbol")

    params := [2]u16{0, 0}
    cursor := 0
    command: u8
    loop: for b in state.esc_sequence.buf {
        switch b {
            case ESC, LSBR: continue
            case 0x40..=0x7e: command = b
            case ';': cursor += 1
            case '?': {
                // TODO: handle this
                state.esc_sequence.private = true
            }
            case 0: break loop
            case: params[cursor] = params[cursor] * 10 + u16(b - ZERO);
        }
    }

    fmt.fprintfln(
        log_file,
        "Command: %c, param1: %d, param2: %d, private: %b",
        command, params[0], params[1], state.esc_sequence.private
    )


    switch command {
    // set cursor
    case 'H': {
        state.cursor_position.row = params[0]
        state.cursor_position.col = params[1]
    }
    // move cursor up
    case 'A': {
        state.cursor_position.row = max(state.cursor_position.row - min(params[0], 1), 0)
    }
    // move cursor down
    case 'B': {
        p0 := max(params[0], 1)
        state.cursor_position.row = max(state.cursor_position.row + p0, state.wsize.ws_row - 1)
    }
    // move cursor right
    case 'C': {
        state.cursor_position.col = max(state.cursor_position.col + len(params) > 0 ? params[0] : 1, state.wsize.ws_col - 1)
    }
    // move cursor left
    case 'D': {
        state.cursor_position.col = max(state.cursor_position.col - len(params) > 0 ? params[0] : 1, 0)
    }
    // line erase
    case 'K': {
        switch p := params[0]; p {
        // erase from cursor
        case 0: {
            for i in state.cursor_position.col..=(state.wsize.ws_col - 1) {
                state.grid[(state.cursor_position.row * state.wsize.ws_col) + i].r = WSPACE
            }
        }
        // erase to cursor
        case 1: {
            for i in 0..=state.cursor_position.col {
                state.grid[(state.cursor_position.row * state.wsize.ws_col) + i].r = WSPACE
            }
        }
        // entire line
        case 2: {
            for i in 0..=(state.wsize.ws_col - 1) {
                state.grid[(state.cursor_position.row * state.wsize.ws_col) + i].r = WSPACE
            }
        }
        case: fmt.panicf("[CSI] Invalid K (erase line) param: %d\n", p)
        }
    }
    // erase screen
    case 'J': {
        switch p := len(params) > 0 ? params[0] : 0; p {
        // erase from cursor
        case 0: {
            cell_under_cursor_idx := state.cursor_position.row * state.wsize.ws_col + state.cursor_position.col
            last_cell_idx := state.wsize.ws_row + state.wsize.ws_col
            for i in cell_under_cursor_idx..=last_cell_idx {
                state.grid[i].r = WSPACE
            }
        }
        // erase to cursor
        case 1: {
            cell_under_cursor_idx := state.cursor_position.row * state.wsize.ws_col + state.cursor_position.col
            for i in 0..=cell_under_cursor_idx {
                state.grid[i].r = WSPACE
            }
        }
        // entire screen
        case 2, 3: {
            last_cell_idx := state.wsize.ws_row + state.wsize.ws_col
            for i in 0..=last_cell_idx {
                state.grid[i].r = WSPACE
            }
        }
        case: fmt.panicf("[CSI] Invalid J (erase screen) param: %d\n", p)
        }
    }

    case 'm': fmt.fprintln(log_file, "m command: unhandled")
    case 'h': fmt.fprintln(log_file, "h command: unhandled")

    case: fmt.fprintfln(log_file, "Unhandled command: %c", command)
    }
}

render_grid :: proc(state: ^State) {
    assert(int(state.wsize.ws_row * state.wsize.ws_col) == len(state.grid), "Screen size and grid size mismatch")

    builder, err := strings.builder_make(len(state.grid))
    if err != nil {
        panic("Failed to allocate")
    }
    defer strings.builder_destroy(&builder)

    // move cursor to the start
    fmt.sbprintf(&builder, "\e[H")

    // write the whole screen
    for r in 0..<state.wsize.ws_row {
        for c in 0..<state.wsize.ws_col {
            strings.write_rune(&builder, state.grid[r * state.wsize.ws_col + c].r)
        }
        // move cursor to a new line
        fmt.sbprintf(&builder, "\e[%d;%dH", r + 2, 1)
    }

    if state.bell {
        strings.write_rune(&builder, BELL)
        state.bell = false
    }

    // restore cursor
    fmt.sbprintf(&builder, "\e[%d;%dH", state.cursor_position.row + 1, state.cursor_position.col + 1)
    write(posix.STDOUT_FILENO, raw_data(builder.buf[:]), uint(strings.builder_len(builder)))
}
